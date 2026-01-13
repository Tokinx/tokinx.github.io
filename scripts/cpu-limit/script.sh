#!/bin/bash

CGROUP_PATH="/sys/fs/cgroup/cpu_limit_global"
SERVICE_FILE="/etc/systemd/system/cpu-limit.service"
PERIOD=100000

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 运行"
  exit 1
fi

# 检查 cgroups v2
if ! stat -fc %T /sys/fs/cgroup | grep -q cgroup2fs; then
  echo "❌ 当前系统未启用 cgroups v2"
  exit 1
fi

# 自动识别 CPU 核心数
CPU_CORES=$(nproc)

if [ "$CPU_CORES" -le 0 ]; then
  echo "❌ 无法识别 CPU 核心数"
  exit 1
fi

echo "======================================"
echo " Debian 13 VPS 全局 CPU 限制工具"
echo "======================================"
echo " CPU 核心数 : $CPU_CORES"
echo " 输入范围   : 10 ~ 100"
echo " 说明       :"
echo "   - 百分比 = 整台 VPS 的 CPU 百分比"
echo "   - 100 = 取消限制"
echo "======================================"
read -p "请输入 CPU 限制百分比: " PERCENT

# 校验输入
if ! [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
  echo "❌ 请输入数字"
  exit 1
fi

if [ "$PERCENT" -lt 10 ] || [ "$PERCENT" -gt 100 ]; then
  echo "❌ 范围必须是 10 ~ 100"
  exit 1
fi

# 100% = 取消限制
if [ "$PERCENT" -eq 100 ]; then
  echo "▶ 取消 CPU 限制..."

  systemctl disable cpu-limit.service 2>/dev/null
  rm -f "$SERVICE_FILE"

  # systemd 回到根 cgroup
  echo 1 > /sys/fs/cgroup/cgroup.procs

  echo "✅ CPU 限制已取消"
  echo "ℹ️ 重启后不再生效"
  exit 0
fi

# 计算 quota（关键）
TOTAL_QUOTA=$(( CPU_CORES * PERIOD ))
QUOTA=$(( TOTAL_QUOTA * PERCENT / 100 ))

echo "▶ 设置 CPU 限制为 ${PERCENT}%（${CPU_CORES} 核）"
echo "▶ 等效可用 CPU：$(awk "BEGIN {printf \"%.2f\", $CPU_CORES * $PERCENT / 100}") 核"

# 创建 cgroup
mkdir -p "$CGROUP_PATH"
echo "$QUOTA $PERIOD" > "$CGROUP_PATH/cpu.max"

# 先放当前 shell
echo $$ > "$CGROUP_PATH/cgroup.procs"

# 再放 systemd（全局生效）
echo 1 > "$CGROUP_PATH/cgroup.procs"

# 写 systemd 开机服务
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Global CPU limit (${PERCENT}% of ${CPU_CORES} cores)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'mkdir -p $CGROUP_PATH && echo "$QUOTA $PERIOD" > $CGROUP_PATH/cpu.max && echo 1 > $CGROUP_PATH/cgroup.procs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-limit.service

echo "✅ CPU 已限制为 ${PERCENT}%（整机）"
echo "ℹ️ 重启后仍然生效"
exit 0