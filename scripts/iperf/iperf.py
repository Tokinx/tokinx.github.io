#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iPerf3 网络测试脚本：运行测试并转为易懂描述。
用法: python iperf_test.py <server_ip> [options]
示例: python iperf_test.py 192.168.1.100 -t 10 -P 1 -u False

python iperf_test.py 192.168.1.100  # TCP 测试，默认 10s
python iperf_test.py 192.168.1.100 -u -t 20  # UDP 测试，20s
python iperf_test.py 192.168.1.100 -P 4  # 4 并行流，测最大带宽
"""

import subprocess
import json
import sys
import argparse
from typing import Dict, Any

def run_iperf_test(server_ip: str, duration: int = 10, parallel: int = 1, udp: bool = False) -> str:
    """
    运行 iPerf3 测试，返回 JSON 输出。
    """
    cmd = [
        'iperf3', '-c', server_ip,
        '-t', str(duration),  # 测试时长 (秒)
        '-P', str(parallel),  # 并行流数
        '-J',  # JSON 输出
        '-f', 'm'  # Mbps 单位
    ]
    if udp:
        cmd.extend(['-u', '-b', '100M'])  # UDP 模式，带宽 100Mbps
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(f"iPerf3 错误: {result.stderr}")
        return result.stdout
    except FileNotFoundError:
        raise RuntimeError("未找到 iPerf3，请安装: sudo apt install iperf3")
    except subprocess.TimeoutExpired:
        raise RuntimeError("测试超时，请检查服务器连接")

def parse_iperf_output(output: str) -> str:
    """
    解析 JSON 输出，转为易懂描述。
    """
    try:
        data = json.loads(output)
        end = data['end']
        streams = end['streams'][0]  # 取第一个流
        receiver = streams['receiver']
        sender = streams['sender']
        
        # 提取关键指标
        bandwidth_mbps = round(receiver['bits_per_second'] / 1e6, 2)
        lost_percent = receiver.get('lost_percent', 0)
        jitter_ms = receiver.get('jitter_ms', 0)
        rtt_ms = sender.get('rtt', 0) * 1000  # 转为 ms
        
        # 速度评级
        if bandwidth_mbps >= 100:
            speed_desc = "超快（适合 4K 视频和游戏）"
        elif bandwidth_mbps >= 50:
            speed_desc = "很快（适合 HD 视频和下载）"
        elif bandwidth_mbps >= 10:
            speed_desc = "中等（适合浏览和 SD 视频）"
        else:
            speed_desc = "较慢（建议检查网络或升级带宽）"
        
        # 丢包评级
        if lost_percent < 1:
            loss_desc = "优秀（网络稳定）"
        elif lost_percent < 5:
            loss_desc = "一般（轻微波动）"
        else:
            loss_desc = "差（可能影响视频/游戏）"
        
        # 抖动评级
        if jitter_ms < 1:
            jitter_desc = "极低（完美实时体验）"
        elif jitter_ms < 5:
            jitter_desc = "低（适合 VoIP）"
        else:
            jitter_desc = "高（建议优化路由）"
        
        # RTT 评级
        if rtt_ms < 50:
            rtt_desc = "极低（本地级响应）"
        elif rtt_ms < 100:
            rtt_desc = "低（跨城优秀）"
        elif rtt_ms < 200:
            rtt_desc = "中等（跨国可接受）"
        else:
            rtt_desc = "高（延迟明显，游戏需注意）"
        
        # 生成描述
        desc = f"🎉 测试完成！（协议: {'UDP' if udp else 'TCP'}，时长: {duration}s）\n\n"
        desc += f"📡 下载速度: {bandwidth_mbps} Mbps - {speed_desc}\n"
        desc += f"📉 丢包率: {lost_percent}% - {loss_desc}\n"
        if udp:  # UDP 才有抖动
            desc += f"📊 抖动: {jitter_ms} ms - {jitter_desc}\n"
        desc += f"⏱️  RTT 延迟: {rtt_ms:.1f} ms - {rtt_desc}\n\n"
        desc += "💡 建议: 如果速度低，检查 WiFi/路由器；丢包高，试有线连接。"
        
        return desc
    except json.JSONDecodeError:
        return "❌ 输出解析失败！请确保 iPerf3 支持 -J（版本 3.1+），或检查服务器运行 iperf3 -s。"
    except KeyError as e:
        return f"❌ 数据缺失: {e}。尝试更新 iPerf3 或检查输出。"

def main():
    parser = argparse.ArgumentParser(description="iPerf3 简单测试脚本")
    parser.add_argument("server_ip", help="服务器 IP 或主机名")
    parser.add_argument("-t", "--duration", type=int, default=10, help="测试时长 (秒，默认10)")
    parser.add_argument("-P", "--parallel", type=int, default=1, help="并行流数 (默认1)")
    parser.add_argument("-u", "--udp", action="store_true", help="UDP 模式")
    args = parser.parse_args()
    
    try:
        print("🚀 开始 iPerf3 测试...")
        output = run_iperf_test(args.server_ip, args.duration, args.parallel, args.udp)
        description = parse_iperf_output(output)
        print(description)
    except Exception as e:
        print(f"❌ 错误: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()