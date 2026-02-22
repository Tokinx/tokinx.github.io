#!/bin/sh

set -e

echo "== 更新系统 =="
apk update

echo "== 安装基础依赖 =="
apk add --no-cache curl tar

echo "== 下载 Caddy (带 Cloudflare DNS 插件) =="

# 使用官方 xcaddy 构建好的二进制
curl -L -o /usr/bin/caddy \
https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64

chmod +x /usr/bin/caddy

echo "== 创建 Caddy 目录 =="
mkdir -p /etc/caddy
mkdir -p /var/lib/caddy
mkdir -p /var/log/caddy

echo "== 创建 systemd 服务 (OpenRC) =="
cat > /etc/init.d/caddy <<'EOF'
#!/sbin/openrc-run
command="/usr/bin/caddy"
command_args="run --config /etc/caddy/Caddyfile --adapter caddyfile"
command_background=true
pidfile="/run/caddy.pid"
depend() {
    need net
}
EOF

chmod +x /etc/init.d/caddy
rc-update add caddy default

echo "== 安装完成 =="
echo "下一步请编辑 /etc/caddy/Caddyfile"