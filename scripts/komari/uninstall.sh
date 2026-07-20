#!/bin/sh

echo "开始清理 komari-agent..."

# 1. 处理 Systemd 系统 (Debian, Ubuntu, CentOS 等)
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    systemctl stop komari-agent 2>/dev/null
    systemctl disable komari-agent 2>/dev/null
    rm -f /etc/systemd/system/komari-agent.service
    systemctl daemon-reload 2>/dev/null
fi

# 2. 处理 OpenRC 系统 (Alpine Linux)
if command -v rc-service >/dev/null 2>&1; then
    rc-service komari-agent stop 2>/dev/null
    rc-update del komari-agent default 2>/dev/null
    rm -f /etc/init.d/komari-agent
fi

# 3. 兜底清理可能残存的孤儿进程
PID=$(ps aux | grep -E 'komari|agent' | grep -v grep | awk '{print $1}')
if [ -n "$PID" ]; then
    kill -9 $PID 2>/dev/null
fi

# 4. 清理所有可能的物理路径
rm -rf /opt/komari
rm -rf /etc/komari-agent
rm -f /usr/local/bin/komari-agent

echo "komari-agent 已完全卸载并清理完毕！"