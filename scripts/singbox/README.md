这个配置原理是：
- Reality 只监听 127.0.0.1，20443 端口不需要开放。
- 开放 21443 端口，reality-guard 作为入口。
- 通过 rules 的 action sniff 先判断握手的 SNI（伪装的域名）。
- 只有跟设置的 SNI 匹配放行到 reality-guard，不匹配的的 SNI 会直接丢弃。
- reality-guard 的流量会发到真正的 Reality。

这样做不需要额外配置 Nginx 或 Caddy 做 SNI 过滤，可以把绝大数非目标 SNI 的探测 / 滥用流量挡在 Reality 入站之前，风险从“任意 SNI”缩小为“仅白名单 SNI”，大大降低被当作通用 CDN 中转的概率（**所以尽量不要偷套了 CDN 的站**）

```json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "direct",
      "tag": "reality-guard",
      "listen": "::",
      "listen_port": 21443,
      "network": "tcp",
      "override_address": "127.0.0.1",
      "override_port": 20443
    },
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "127.0.0.1",
      "listen_port": 20443,
      "users": [{ "uuid": "⭕️YOUR UUID HERE", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "www.icloud.com",
        "alpn": ["h2", "http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.icloud.com", "server_port": 443 },
          "private_key": "⭕️YOUR PRIVATE KEY HERE",
          "short_id": ["⭕️YOUR SHORT ID HERE"],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "action": "sniff", "inbound": ["reality-guard"], "sniffer": ["tls"], "timeout": "300ms" },
      { "action": "route", "inbound": ["reality-guard"], "domain": ["www.icloud.com"], "outbound": "direct" },
      { "action": "reject", "inbound": ["reality-guard"], "method": "drop" }
    ],
    "final": "direct"
  }
}
```

## 结尾再分享一个 docker 一键部署 singbox 的 docker compose，祝佬友们使用愉快：
```yaml
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    restart: always
    network_mode: host
    volumes:
      # 这是上面的配置文件
      - $PWD/config.json:/etc/sing-box/config.json
      # 如果需要 hy2 或需要证书的协议，可以映射进容器
      # - $PWD/server.pem:/etc/sing-box/server.pem
      # - $PWD/server.key:/etc/sing-box/server.key
    environment:
      - TZ=Asia/Shanghai
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
```

此配置原理参考 Xray-reality 最佳实践：[github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-REALITY (without being stolen)](https://github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-REALITY%20(without%20being%20stolen))