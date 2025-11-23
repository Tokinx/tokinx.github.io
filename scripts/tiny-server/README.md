<center>

# 小内存服务器配置指南

</center>

## 重装系统

仓库：https://github.com/bin456789/reinstall

```
# 下载 DD 脚本
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O ${_##*/} $_

# 安装 Debian
bash reinstall.sh debian 13 --password <你的密码>

# 开启 BBR
echo "net.core.default_qdisc = fq" > /etc/sysctl.d/99-bbr.conf && echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-bbr.conf && echo "tcp_bbr" > /etc/modules-load.d/bbr.conf && sysctl --system

# 开启 BBR & 网络优化配置
wget -O /etc/sysctl.d/99-bbr.conf https://tokinx.github.io/scripts/tiny-server/99-bbr.conf && sysctl --system

reboot

lsmod | grep bbr
# 应输出 = bbr
sysctl net.ipv4.tcp_congestion_control
# 应包含 bbr
sysctl net.ipv4.tcp_available_congestion_control
```

## 安装 Podman

小内存可以 Podman 代替 Docker，节省约 90M 内存。

```
apt update && apt -y install curl

# 默认 root 模式
bash -c "$(curl -sSL http://tokinx.github.io/scripts/tiny-server/install-podman.sh)"

# 交互安装：
INTERACTIVE=1 bash -c "$(curl -sSL http://tokinx.github.io/scripts/tiny-server/install-podman.sh)"
```

## 环境变量

| 变量                        | 默认值         | 可选值               | 备注                                                                                                                                                                                                                                                                                         |
| --------------------------- | -------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `INTERACTIVE`               | `0`            | `0/1`                | 是否启用交互式配置。默认关闭，适合无人值守。                                                                                                                                                                                                                                                 |
| `INSTALL_COMPOSE_V2`        | `1`            | `0/1`                | 是否安装 docker-compose v2（独立二进制）。                                                                                                                                                                                                                                                   |
| `INSTALL_COMPOSE_V1`        | `0`            | `0/1`                | 是否安装 docker-compose v1（1.29.2，兼容老项目，不建议同时启用）。                                                                                                                                                                                                                           |
| `SYMLINK_DOCKER_SOCK`       | `0`            | `0/1`                | 创建 `/var/run/docker.sock` → Podman socket 的软链；<br />仅在 socket 有效时创建；可能与将来 Docker Engine 冲突。                                                                                                                                                                            |
| `ENABLE_SWAP`               | `1`            | `0/1`                | 安装前创建并启用 Swap，低内存环境建议开启。                                                                                                                                                                                                                                                  |
| `SWAP_SIZE_MB`              | `2048`         | 正整数（MB）         | Swap 大小，默认 2G。                                                                                                                                                                                                                                                                         |
| `SWAPFILE_PATH`             | `/swapfile`    | 绝对路径             | Swap 文件路径；未显式设置时使用默认值。                                                                                                                                                                                                                                                      |
| `INSTALL_COMMON_PKGS`       | `1`            | `0/1`                | 是否安装常用工具包：`vim`, `gzip`, `tar`, `less`, `htop`, `net-tools`, `unzip`。                                                                                                                                                                                                             |
| `DOCKER_SERVICE_SHIM`       | `1`            | `0/1`                | 创建 `docker.service` 兼容层（实际启动/停止 `podman.socket`）<br />创建 `docker.socket` → `podman.socket` 别名<br />兼容 `systemctl restart docker`/`docker.socket`。<br />若检测到真实 Docker（二进制 `/usr/bin/dockerd`），将自动移除上述兼容层与别名（systemd path 监控触发）。           |
| `DOCKER_CLI_HACKS`          | `1`            | `0/1`                | 启用 Docker CLI 兼容 hack：创建 `/etc/containers/nodocker` 静默提示；<br />安装 `docker` 包装器修复 `docker logs` 在容器名后的选项顺序问题。                                                                                                                                                 |
| `PODMAN_WRAPPER_STRIP`      | `1`            | `0/1`                | 安装 `/usr/local/bin/podman` 与 `/usr/local/bin/docker` 包装器，剥离 Podman 不支持的 Docker 参数，避免容器因不支持参数无法启动。                                                                                                                                                             |
| `PODMAN_STRIP_FLAGS`        | 见下           | 以空格分隔的长选项名 | 需剥离的参数名列表（仅名称，不含值），包装器同时支持 `--flag value` 和 `--flag=value` 两种形式；<br />默认：`--memory-swappiness --kernel-memory --cpu-rt-runtime --cpu-rt-period --device-read-bps --device-write-bps --device-read-iops --device-write-iops --oom-score-adj --init-path`。 |
| `DOCKER_ABS_PATH_DIVERT`    | `1`            | `0/1`                | 使用 `dpkg-divert` 拦截绝对路径 `/usr/bin/docker` 调用，重定向到我们的 `/usr/local/bin/docker` 包装器；<br />检测到真实 Docker（`/usr/bin/dockerd`）时会自动撤销。                                                                                                                           |
| `DOCKER_API_FILTER_PROXY`   | `1`            | `0/1`                | 在 `/var/run/docker.sock` 启动轻量代理，转发到 Podman socket 并过滤 Docker API 中的不支持字段（如 Create/Update 的 `MemorySwappiness` 等），解决第三方直接调用 Docker API 的报错。需要 `python3`。                                                                                           |
| `AUTOGEN_SYSTEMD_UNITS`     | `1`            | `0/1`                | 是否自动为容器生成并启用 systemd 单元。仅对带有 `tss.autounit=1` 标签的容器生效（默认开启，按标签纳管）。                                                                                                                                                                                    |
| `ENABLE_PERIODIC_AUTOUNIT`  | `1`            | `0/1`                | 是否安装定时扫描器，周期性为带标签的容器生成/更新单元（默认开启）。                                                                                                                                                                                                                          |
| `AUTOUNIT_INTERVAL_MIN`     | `5`            | 正整数（分钟）       | 定时扫描间隔。仅当 `ENABLE_PERIODIC_AUTOUNIT=1` 时有效。                                                                                                                                                                                                                                     |
| `AUTOUNIT_FILTER_LABEL_KEY` | `tss.autounit` | 字符串键名           | 作为纳管开关的标签键，值为 `1/true/yes` 视为开启。                                                                                                                                                                                                                                           |
| `CGROUP_MODE`               | `v1`           | `v1`/`v2`            | 目标 cgroup 版本（默认 v1 兼容性更好）；<br />若与当前内核不一致，将修改 GRUB 启动参数并提示/执行重启。                                                                                                                                                                                      |
| `CGROUP_AUTO_REBOOT`        | `1`            | `0/1`                | 当需要切换 cgroup 版本时是否自动重启以生效。 `1`=自动重启，`0`=仅写入 GRUB 并退出提示手动重启。                                                                                                                                                                                              |

## UFW 放行 DNS（53 端口）

若容器能 ping IP 但无法解析域名，且使用了 UFW，可用下面“一键命令”放行经 `podman0` 转发到外网接口的 DNS（53/udp 与 53/tcp）：

```
WAN_IF=$(ip route | awk '/default/ {print $5; exit}'); \
  ufw route allow in on podman0 out on "$WAN_IF" to any port 53 proto udp; \
  ufw route allow in on podman0 out on "$WAN_IF" to any port 53 proto tcp; \
  ufw reload
```

说明：需要 UFW 已安装并处于 active 状态。上述规则仅放行容器经 `podman0` 发往外网 DNS 的转发流量。

## 安装 1Panel

```
# V2，512M 机器需要 Podman，1G 可正常安装
bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"

# V1，小内存推荐，节省约 100M 内存
curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
```

### 其它

```
# 测试容器 DNS
podman run --rm alpine ping -c 3 chatgpt.com

# 查看 podman 网络配置
podman network inspect podman | jq .[]
```
