wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh && bash reinstall.sh debian 13 --password <PWD>

等待大概5-10分钟，用新密码重新连进去

# 开启 BBR & 网络优化配置
## Default, US-West
wget -O /etc/sysctl.d/99-bbr.conf https://tokinx.github.io/scripts/tiny-server/99-bbr.conf && sysctl --system
## RFCHOST
wget -O /etc/sysctl.d/99-bbr.conf https://tokinx.github.io/scripts/tiny-server/rfc-bbr.conf && sysctl --system

reboot

lsmod | grep bbr
# 应输出 = bbr
sysctl net.ipv4.tcp_congestion_control
# 应包含 bbr
sysctl net.ipv4.tcp_available_congestion_control


# V2
apt update && apt -y install curl && bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"


# 一键开启 SWAP
swapoff -a && fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab


# 开启ZRAM
curl -sS -O https://raw.githubusercontent.com/woniu336/open_shell/main/zram_manager.sh \
  && chmod +x zram_manager.sh \
  && ./zram_manager.sh



docker run --restart=always -itd --name warp_socks_v5 -p 9091:9091 ghcr.io/mon-ius/docker-warp-socks:v5