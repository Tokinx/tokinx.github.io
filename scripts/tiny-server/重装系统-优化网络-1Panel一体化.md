wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh && bash reinstall.sh debian 13 --password <PWD>

# 开启 BBR & 网络优化配置
wget -O /etc/sysctl.d/99-bbr.conf https://tokinx.github.io/scripts/tiny-server/99-bbr.conf && sysctl --system

reboot

lsmod | grep bbr
# 应输出 = bbr
sysctl net.ipv4.tcp_congestion_control
# 应包含 bbr
sysctl net.ipv4.tcp_available_congestion_control


# V2，512M 机器需要 Podman，1G 可正常安装
apt update && apt -y install curl && bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"