# 1. 停止并清理 Docker 容器
if [ $(command -v docker) ]; then
    docker stop komari-agent 2>/dev/null && docker rm komari-agent 2>/dev/null
fi

# 2. 停止并卸载 Systemd 服务
sudo systemctl stop komari-agent 2>/dev/null
sudo systemctl disable komari-agent 2>/dev/null
sudo rm -f /etc/systemd/system/komari-agent.service
sudo systemctl daemon-reload

# 3. 删除残留文件与配置
sudo rm -f /usr/local/bin/komari-agent
sudo rm -rf /etc/komari-agent
sudo rm -rf /var/log/komari-agent

echo "komari-agent 已完全卸载并清理完毕！"