#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
批量 ping DigitalOcean Spaces 各区域对象存储端点，次数可配置（见文件顶部常量），输出 CSV，并按平均延迟排序输出 fast.txt。

输出文件：
- results.csv  位于当前脚本目录
- fast.txt     位于当前脚本目录

用法：
  python3 ping_endpoints.py

说明：
- 若某个主机 100% 丢包，平均延迟记为无穷大，排序置底。
- 解析支持 Linux/Unix 常见 `ping -q` 汇总格式（rtt min/avg/max/mdev），以及 Windows（英文/中文）汇总输出。
"""

import csv
import math
import os
import re
import subprocess
import sys
import platform
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

ENDPOINTS = [
    # 北美地区
    ("北美地区", "美国东部", "纽约 (NYC3)", "nyc3.digitaloceanspaces.com"),
    ("北美地区", "美国西部", "旧金山 (SFO2)", "sfo2.digitaloceanspaces.com"),
    ("北美地区", "美国西部", "旧金山 (SFO3)", "sfo3.digitaloceanspaces.com"),
    ("北美地区", "加拿大东部", "多伦多 (TOR1)", "tor1.digitaloceanspaces.com"),
    # 欧洲地区
    ("欧洲地区", "荷兰北部", "阿姆斯特丹 (AMS3)", "ams3.digitaloceanspaces.com"),
    ("欧洲地区", "英国南部", "伦敦 (LON1)", "lon1.digitaloceanspaces.com"),
    ("欧洲地区", "德国中部", "法兰克福 (FRA1)", "fra1.digitaloceanspaces.com"),
    # 亚太地区
    ("亚太地区", "东南亚", "新加坡 (SGP1)", "sgp1.digitaloceanspaces.com"),
    ("亚太地区", "南亚", "班加罗尔 (BLR1)", "blr1.digitaloceanspaces.com"),
]


# 运行参数（可按需修改）
# 每主机 ping 次数
PING_COUNT = 30
# 单次响应超时（秒）
PING_TIMEOUT_S = 2
# 包与包之间的间隔（秒），非特权用户通常最小允许 0.2s
PING_INTERVAL_S = 0.2
# 并发 worker 数量上限
MAX_WORKERS = 8


def run_ping(host: str, count: int = PING_COUNT, timeout: int = PING_TIMEOUT_S, interval: float = PING_INTERVAL_S) -> str:
    """执行 ping 命令，返回原始输出文本。

    - 在 Windows 上：使用 `ping -n <count> -w <timeout_ms>`（不支持 `-i` 间隔）。
    - 在 Linux/Unix 上：使用 `ping -n -q -c <count> -W <timeout_s> -i <interval>`。
    """
    sysname = platform.system().lower()
    if sysname.startswith("win"):
        # Windows `ping` 语法：-n 次数；-w 超时(毫秒)。不支持 -q/-i。
        timeout_ms = max(1, int(timeout * 1000))
        cmd = [
            "ping",
            "-n", str(count),
            "-w", str(timeout_ms),
            host,
        ]
    else:
        # POSIX 风格（Linux 等）：-n 不做反代；-q 汇总输出；-c 次数；-W 超时(秒)；-i 间隔(秒)
        cmd = [
            "ping",
            "-n",
            "-q",
            "-c", str(count),
            "-W", str(timeout),
            "-i", str(interval),
            host,
        ]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        return out.strip()
    except FileNotFoundError:
        print("未找到 ping 命令，请在系统中安装 ping。", file=sys.stderr)
        sys.exit(1)


def parse_ping_output(output: str):
    """解析 ping 汇总输出，返回 metrics 字典。

    返回字段：sent, received, loss_percent, min_ms, avg_ms, max_ms, mdev_ms
    若无法解析 RTT，则对应值为 None。
    """
    # 解析收发与丢包率
    # Linux 例：10 packets transmitted, 10 received, 0% packet loss, time 9009ms
    sent = received = None
    loss_percent = None
    m = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+received,\s+([0-9.]+)%\s+packet loss", output)
    if m:
        sent = int(m.group(1))
        received = int(m.group(2))
        loss_percent = float(m.group(3))
    else:
        # Windows 英文：Packets: Sent = 4, Received = 4, Lost = 0 (0% loss)
        m_win_en = re.search(
            r"Packets:\s*Sent\s*=\s*(\d+),\s*Received\s*=\s*(\d+),\s*Lost\s*=\s*(\d+)\s*\((\d+)%\s*loss\)",
            output,
            re.IGNORECASE,
        )
        if m_win_en:
            sent = int(m_win_en.group(1))
            received = int(m_win_en.group(2))
            # lost = int(m_win_en.group(3))  # 未直接使用
            loss_percent = float(m_win_en.group(4))
        else:
            # Windows 中文（常见）：数据包: 已发送 = 4，已接收 = 4，丢失 = 0 (0% 丢失)
            m_win_zh = re.search(
                r"数据包[:：]\s*.*?已发送\s*=\s*(\d+).*?已接收\s*=\s*(\d+).*?丢失\s*=\s*(\d+)\s*\((\d+)%",
                output,
                re.IGNORECASE | re.DOTALL,
            )
            if m_win_zh:
                sent = int(m_win_zh.group(1))
                received = int(m_win_zh.group(2))
                loss_percent = float(m_win_zh.group(4))

    # 解析 RTT 汇总：
    # Linux：rtt min/avg/max/mdev = 20.971/21.672/23.089/0.759 ms
    min_ms = avg_ms = max_ms = mdev_ms = None
    m2 = re.search(r"=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)\s*ms", output)
    if m2:
        min_ms = float(m2.group(1))
        avg_ms = float(m2.group(2))
        max_ms = float(m2.group(3))
        mdev_ms = float(m2.group(4))
    else:
        # 兼容部分系统：round-trip min/avg/max/stddev = ...
        m3 = re.search(r"round-trip\s+min/avg/max/(?:stddev|mdev)\s*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)\s*ms", output)
        if m3:
            min_ms = float(m3.group(1))
            avg_ms = float(m3.group(2))
            max_ms = float(m3.group(3))
            mdev_ms = float(m3.group(4))
        else:
            # Windows 英文：Minimum = 11ms, Maximum = 49ms, Average = 25ms
            m4 = re.search(
                r"Minimum\s*=\s*(\d+)ms,\s*Maximum\s*=\s*(\d+)ms,\s*Average\s*=\s*(\d+)ms",
                output,
                re.IGNORECASE,
            )
            if m4:
                min_ms = float(m4.group(1))
                max_ms = float(m4.group(2))
                avg_ms = float(m4.group(3))
            else:
                # Windows 中文：最短 = 11ms，最长 = 49ms，平均 = 25ms
                m5 = re.search(
                    r"最短\s*=\s*(\d+)ms.*?最长\s*=\s*(\d+)ms.*?平均\s*=\s*(\d+)ms",
                    output,
                    re.IGNORECASE | re.DOTALL,
                )
                if m5:
                    min_ms = float(m5.group(1))
                    max_ms = float(m5.group(2))
                    avg_ms = float(m5.group(3))

    return {
        "sent": sent,
        "received": received,
        "loss_percent": loss_percent,
        "min_ms": min_ms,
        "avg_ms": avg_ms,
        "max_ms": max_ms,
        "mdev_ms": mdev_ms,
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(here, "results.csv")
    fast_path = os.path.join(here, "fast.txt")

    rows = []

    def task(item):
        region, area, city, host = item
        print(f"[PING] {region} / {area} / {city} -> {host}")
        out = run_ping(host, count=PING_COUNT, timeout=PING_TIMEOUT_S, interval=PING_INTERVAL_S)
        metrics = parse_ping_output(out)
        sort_avg = metrics["avg_ms"] if (metrics["avg_ms"] is not None and (metrics["loss_percent"] is not None and metrics["loss_percent"] < 100.0)) else math.inf
        return {
            "大区": region,
            "区域": area,
            "城市": city,
            "主机": host,
            "发送": metrics["sent"],
            "接收": metrics["received"],
            "丢包率(%)": metrics["loss_percent"],
            "最小(ms)": metrics["min_ms"],
            "平均(ms)": metrics["avg_ms"],
            "最大(ms)": metrics["max_ms"],
            "抖动(ms)": metrics["mdev_ms"],
            "_排序平均": sort_avg,
        }

    # 限制并发度，兼顾速度与稳定性
    max_workers = min(MAX_WORKERS, len(ENDPOINTS))
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futures = {ex.submit(task, item): item for item in ENDPOINTS}
        for fut in as_completed(futures):
            rows.append(fut.result())

    # 写 CSV
    fieldnames = ["大区", "区域", "城市", "主机", "发送", "接收", "丢包率(%)", "最小(ms)", "平均(ms)", "最大(ms)", "抖动(ms)"]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: r.get(k) for k in fieldnames})

    # 排序并写 fast.txt
    rows_sorted = sorted(rows, key=lambda r: (r["_排序平均"], r["丢包率(%)"] if r["丢包率(%)"] is not None else 100.0))
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(fast_path, "w", encoding="utf-8") as f:
        f.write(f"生成时间: {ts}\n")
        f.write("按平均延迟(升序)排序，单位 ms；100% 丢包置底\n")
        for r in rows_sorted:
            avg = r["平均(ms)"]
            loss = r["丢包率(%)"]
            avg_str = f"{avg:.3f}" if isinstance(avg, (int, float)) and not math.isinf(avg) else "NA"
            loss_str = f"{loss:.1f}%" if isinstance(loss, (int, float)) else "NA"
            line = f"{avg_str}\t丢包:{loss_str}\t{r['大区']} / {r['区域']} / {r['城市']}\t{r['主机']}"
            f.write(line + "\n")

    print(f"已写入: {csv_path}")
    print(f"已写入: {fast_path}")


if __name__ == "__main__":
    main()
