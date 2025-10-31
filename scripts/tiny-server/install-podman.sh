#!/usr/bin/env bash
set -Eeuo pipefail

# ========= 可通过环境变量覆盖的默认值 =========
MODE="${MODE:-rootless}"                 # rootless | root
USERNAME="${USERNAME:-docker_usr}"       # rootless 模式下的运行用户
USER_UID="${USER_UID:-1000}"             # 该用户的 UID
INSTALL_COMPOSE_V2="${INSTALL_COMPOSE_V2:-1}"
INSTALL_COMPOSE_V1="${INSTALL_COMPOSE_V1:-0}"   # v1 已弃用，不建议开启
SYMLINK_DOCKER_SOCK="${SYMLINK_DOCKER_SOCK:-0}" # 是否创建 /var/run/docker.sock 软链
ALLOW_LOW_PORTS="${ALLOW_LOW_PORTS:-0}"         # 是否放开 <1024 端口映射
# ============================================

# ---- 打印函数 ----
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die() { err "$@"; exit 1; }

trap 'err "脚本执行失败（行 $LINENO）。"; exit 1' ERR

# ---- 前置检查 ----
[[ "$(id -u)" -eq 0 ]] || die "请以 root 运行。"
command -v apt-get >/dev/null || die "仅支持 Debian/Ubuntu 系列（需要 apt）。"

log "模式：$MODE"
if [[ "$MODE" != "rootless" && "$MODE" != "root" ]]; then
  die "MODE 仅支持 rootless|root"
fi

export DEBIAN_FRONTEND=noninteractive

# ---- 安装 Podman 及依赖 ----
log "更新 APT 软件源并安装依赖（podman、podman-docker、rootless 依赖、常用工具）..."
apt-get update -y
apt-get install -y \
  podman podman-docker uidmap slirp4netns fuse-overlayfs \
  dbus-user-session systemd-timesyncd \
  curl wget ca-certificates jq sudo

# ---- 配置 rootless 用户（如启用 rootless）----
TARGET_SOCK=""
if [[ "$MODE" == "rootless" ]]; then
  log "校验/创建用户：$USERNAME（UID=$USER_UID）..."
  if id "$USERNAME" &>/dev/null; then
    ACT_UID="$(id -u "$USERNAME")"
    if [[ "$ACT_UID" != "$USER_UID" ]]; then
      warn "用户 $USERNAME 已存在，UID=$ACT_UID，与期望 $USER_UID 不同。将使用现有用户。"
      USER_UID="$ACT_UID"
    fi
  else
    # 若 UID=1000 已被占用，提示并自动使用现有 1000 用户
    if getent passwd "$USER_UID" >/dev/null; then
      OTHER_USER="$(getent passwd "$USER_UID" | cut -d: -f1)"
      warn "UID $USER_UID 已被用户 $OTHER_USER 占用。将创建 $USERNAME（系统自动分配 UID）。"
      useradd -m -s /bin/bash "$USERNAME"
    else
      useradd -m -u "$USER_UID" -s /bin/bash "$USERNAME"
    fi
    # 允许 sudo（可按需删除）
    usermod -aG sudo "$USERNAME" || true
  fi

  # 常见组
  groupadd -f docker || true
  groupadd -f podman || true
  usermod -aG docker,podman "$USERNAME" || true

  # 为 rootless 启用 user-level systemd（开机常驻）
  log "为 $USERNAME 启用 systemd linger（允许用户级服务开机运行）..."
  loginctl enable-linger "$USERNAME" || true

  # 启用用户级 podman.socket
  log "以 $USERNAME 启用并启动 podman.socket（用户级）..."
  runuser -l "$USERNAME" -c 'systemctl --user daemon-reload || true'
  runuser -l "$USERNAME" -c 'systemctl --user enable --now podman.socket'

  TARGET_SOCK="/run/user/$(id -u "$USERNAME")/podman/podman.sock"
  log "用户级 Podman Docker API socket: $TARGET_SOCK"

  # 为该用户设置 DOCKER_HOST
  DOCKER_HOST_LINE="export DOCKER_HOST=unix://$TARGET_SOCK"
  for f in "/home/$USERNAME/.bashrc" "/home/$USERNAME/.profile" "/home/$USERNAME/.bash_profile"; do
    [[ -f "$f" ]] || touch "$f"
    grep -q "$DOCKER_HOST_LINE" "$f" || echo "$DOCKER_HOST_LINE" >> "$f"
  done
  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

  # 可选：放开低端口映射（<1024），默认不开启
  if [[ "$ALLOW_LOW_PORTS" == "1" ]]; then
    log "放开低端口映射（net.ipv4.ip_unprivileged_port_start=0）..."
    echo "net.ipv4.ip_unprivileged_port_start=0" >/etc/sysctl.d/99-podman-unpriv-ports.conf
    sysctl --system >/dev/null
  fi
else
  # ---- root 模式 ----
  log "启用系统级 podman.socket（root 模式）..."
  systemctl enable --now podman.socket
  TARGET_SOCK="/run/podman/podman.sock"

  # 为 root 设置 DOCKER_HOST，并写入全局 profile
  DOCKER_HOST_LINE="export DOCKER_HOST=unix://$TARGET_SOCK"
  grep -q "$DOCKER_HOST_LINE" /root/.bashrc || echo "$DOCKER_HOST_LINE" >>/root/.bashrc
  echo "$DOCKER_HOST_LINE" >/etc/profile.d/podman-docker-host.sh
fi

# ---- docker.sock 兼容软链（可选）----
if [[ "$SYMLINK_DOCKER_SOCK" == "1" ]]; then
  log "创建 /var/run/docker.sock -> $TARGET_SOCK 的软链接（兼容部分工具）..."
  install -d -m 0775 /var/run
  if [[ -e /var/run/docker.sock && ! -L /var/run/docker.sock ]]; then
    warn "/var/run/docker.sock 存在且不是软链接，已跳过。"
  else
    ln -sfn "$TARGET_SOCK" /var/run/docker.sock
  fi
else
  log "已跳过创建 /var/run/docker.sock 软链（SYMLINK_DOCKER_SOCK=0）。建议优先使用 DOCKER_HOST。"
fi

# ---- 安装 docker-compose ----
# v2（推荐，独立二进制）
if [[ "$INSTALL_COMPOSE_V2" == "1" ]]; then
  log "安装 docker-compose v2（独立二进制）..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) compose_arch="x86_64" ;;
    aarch64|arm64) compose_arch="aarch64" ;;
    armv7l) compose_arch="armv7" ;;
    *) die "不支持的架构：$arch（无法获取 compose v2 二进制）" ;;
  esac
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}"
  install -d /usr/local/bin
  curl -fsSL "$url" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  log "docker-compose v2 已安装到 /usr/local/bin/docker-compose"
fi

# v1（可选，不建议）
if [[ "$INSTALL_COMPOSE_V1" == "1" ]]; then
  log "安装 docker-compose v1（1.29.2，已弃用，仅为兼容老项目）..."
  curl -fsSL \
    "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose-v1
  chmod +x /usr/local/bin/docker-compose-v1
  ln -sfn /usr/local/bin/docker-compose-v1 /usr/local/bin/docker-compose-1
fi

# ---- 基本自检 ----
log "自检：Podman 与 Compose 版本..."
podman --version || true
if command -v docker-compose >/dev/null; then
  if [[ "$MODE" == "rootless" ]]; then
    runuser -l "$USERNAME" -c 'docker-compose version' || true
  else
    docker-compose version || true
  fi
else
  warn "未检测到 docker-compose（可能 INSTALL_COMPOSE_V2/INSTALL_COMPOSE_V1 都为 0）。"
fi

# ---- 结尾提示 ----
log "设置完成。关键点："
echo "  1) 已安装 podman 和 podman-docker；可直接用 'docker' 命令（由 Podman 接管）。"
if [[ "$MODE" == "rootless" ]]; then
  echo "  2) rootless 模式用户：$USERNAME（UID=$USER_UID），其 DOCKER_HOST 已设置为："
  echo "     unix://$TARGET_SOCK"
  echo "     使用示例："
  echo "       su - $USERNAME"
  echo "       docker-compose up -d   # 将由 Podman 接管执行"
else
  echo "  2) root 模式 DOCKER_HOST：unix://$TARGET_SOCK"
  echo "     使用示例：docker-compose up -d"
fi
if [[ "$SYMLINK_DOCKER_SOCK" == "1" ]]; then
  echo "  3) 兼容软链已创建：/var/run/docker.sock -> $TARGET_SOCK"
else
  echo "  3) 未创建 /var/run/docker.sock 软链（更推荐依赖 DOCKER_HOST）。"
fi
echo "  4) 如果你的 compose 工程需要低端口（<1024），可在执行前将 ALLOW_LOW_PORTS=1 重新运行本脚本。"
log "全部完成 ✅"
