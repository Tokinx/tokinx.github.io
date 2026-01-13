#!/bin/bash

SLICE_PATH="/sys/fs/cgroup/user.slice"
SERVICE_FILE="/etc/systemd/system/cpu-limit-user.service"
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

# CPU 核心数
CPU_CORES=$(nproc)
[ "$CPU_CORES" -le 0 ] && exit 1

echo "======================================"
echo " Debian 13 CPU 限制（user.slice 版）"
echo "======================================"
echo " CPU 核心数 : $CPU_CORES"
echo " 限制对象   : 用户进程（user.slice）"
echo " 输入范围   : 10 ~ 100"
echo " 100 = 取消限制"
echo "======================================"
read -p "请输入 CPU 限制百分比: " PERCENT

# 校验
if ! [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
  echo "❌ 请输入数字"
  exit 1
fi

if [ "$PERCENT" -lt 10 ] || [ "$PERCENT" -gt 100 ]; then
  echo "❌ 范围必须是 10 ~ 100"
  exit 1
fi

# 取消限制
if [ "$PERCENT" -eq 100 ]; then
  echo "▶ 取消 user.slice CPU 限制..."

  systemctl disable cpu-limit-user.service 2>/dev/null
  rm -f "$SERVICE_FILE"

  echo "max $PERIOD" > "$SLICE_PATH/cpu.max"

  echo "✅ user.slice CPU 限制已取消"
  exit 0
fi

# 计算 quota
TOTAL_QUOTA=$(( CPU_CORES * PERIOD ))
QUOTA=$(( TOTAL_QUOTA * PERCENT / 100 ))

echo "▶ 设置 user.slice CPU 限制为 ${PERCENT}%"
echo "▶ 等效可用 CPU：$(awk "BEGIN {printf \"%.2f\", $CPU_CORES * $PERCENT / 100}") 核"

# 立即生效
echo "$QUOTA $PERIOD" > "$SLICE_PATH/cpu.max"

# 写 systemd 开机生效
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Limit user.slice CPU to ${PERCENT}%
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "$QUOTA $PERIOD" > $SLICE_PATH/cpu.max'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-limit-user.service

echo "✅ user.slice CPU 已限制为 ${PERCENT}%"
echo "ℹ️ systemd / SSH / 内核不受影响"
