#!/usr/bin/env bash
set -Eeuo pipefail

# ========= 可通过环境变量覆盖的默认值 =========
MODE="${MODE:-rootless}"                 # rootless | root
USERNAME="${USERNAME:-docker_usr}"       # rootless 模式下的运行用户
USER_UID="${USER_UID:-1000}"             # 该用户的 UID
INSTALL_COMPOSE_V2="${INSTALL_COMPOSE_V2:-1}"
INSTALL_COMPOSE_V1="${INSTALL_COMPOSE_V1:-0}"   # v1 已弃用，不建议开启
SYMLINK_DOCKER_SOCK="${SYMLINK_DOCKER_SOCK:-1}" # 是否创建 /var/run/docker.sock 软链
ALLOW_LOW_PORTS="${ALLOW_LOW_PORTS:-0}"         # 是否放开 <1024 端口映射
# ============================================

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die(){ err "$@"; exit 1; }
trap 'err "脚本执行失败（行 $LINENO）。"; exit 1' ERR

[[ "$(id -u)" -eq 0 ]] || die "请以 root 运行。"
command -v apt-get >/dev/null || die "需要基于 apt 的系统（Debian/Ubuntu）。"
[[ "$MODE" == "rootless" || "$MODE" == "root" ]] || die "MODE 仅支持 rootless|root"

export DEBIAN_FRONTEND=noninteractive

# 安装
log "安装 Podman 与依赖..."
apt-get update -y
apt-get install -y podman podman-docker uidmap slirp4netns fuse-overlayfs \
  dbus-user-session systemd-logind curl wget ca-certificates jq sudo

# 确认 PID1 为 systemd
if [[ "$(ps -p 1 -o comm= --no-headers)" != "systemd" ]]; then
  warn "当前系统 PID1 非 systemd，user@UID 与 --user 功能可能不可用。建议改用 MODE=root。"
fi

TARGET_SOCK=""
if [[ "$MODE" == "rootless" ]]; then
  # 用户
  log "校验/创建用户：$USERNAME（期望 UID=$USER_UID）..."
  if id "$USERNAME" &>/dev/null; then
    USER_UID="$(id -u "$USERNAME")"
  else
    if getent passwd "$USER_UID" >/dev/null; then
      useradd -m -s /bin/bash "$USERNAME"
    else
      useradd -m -u "$USER_UID" -s /bin/bash "$USERNAME"
    fi
    usermod -aG sudo "$USERNAME" || true
  fi
  groupadd -f docker || true
  groupadd -f podman || true
  usermod -aG docker,podman "$USERNAME" || true

  # 让 user@UID 与 user-bus 就绪
  log "启用 logind 与 linger..."
  systemctl enable --now systemd-logind
  loginctl enable-linger "$USERNAME" || true

  log "启动 user@${USER_UID}.service（创建 /run/user/${USER_UID} 与 user bus）..."
  systemctl start "user@${USER_UID}.service" || true

  # 等待 user bus
  for i in {1..15}; do
    [[ -S "/run/user/${USER_UID}/bus" ]] && break
    sleep 1
  done
  if [[ ! -S "/run/user/${USER_UID}/bus" ]]; then
    warn "user bus 尚未就绪：/run/user/${USER_UID}/bus 不存在，稍后将尝试 --machine 方式。"
  fi

  # 尝试用两种方式启动用户级 podman.socket
  TARGET_SOCK="/run/user/${USER_UID}/podman/podman.sock"
  log "尝试以 $USERNAME 启用/启动 podman.socket..."
  if ! sudo -u "$USERNAME" \
      XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
      systemctl --user enable --now podman.socket; then
    warn "直接 --user 方式失败，改用 --machine=${USERNAME}@.host 再试..."
    systemctl --user -M "${USERNAME}@.host" enable --now podman.socket
  fi

  # 写入 DOCKER_HOST
  DOCKER_HOST_LINE="export DOCKER_HOST=unix://$TARGET_SOCK"
  for f in "/home/$USERNAME/.bashrc" "/home/$USERNAME/.profile" "/home/$USERNAME/.bash_profile"; do
    [[ -f "$f" ]] || touch "$f"
    grep -q "$DOCKER_HOST_LINE" "$f" || echo "$DOCKER_HOST_LINE" >> "$f"
  done
  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

  if [[ "$ALLOW_LOW_PORTS" == "1" ]]; then
    echo "net.ipv4.ip_unprivileged_port_start=0" >/etc/sysctl.d/99-podman-unpriv-ports.conf
    sysctl --system >/dev/null
  fi
else
  # root 模式
  log "启用系统级 podman.socket（root 模式）..."
  systemctl enable --now podman.socket
  TARGET_SOCK="/run/podman/podman.sock"
  DOCKER_HOST_LINE="export DOCKER_HOST=unix://$TARGET_SOCK"
  grep -q "$DOCKER_HOST_LINE" /root/.bashrc || echo "$DOCKER_HOST_LINE" >>/root/.bashrc
  echo "$DOCKER_HOST_LINE" >/etc/profile.d/podman-docker-host.sh
fi

# 可选软链
if [[ "$SYMLINK_DOCKER_SOCK" == "1" ]]; then
  log "创建 /var/run/docker.sock -> $TARGET_SOCK 软链..."
  install -d -m 0775 /var/run
  [[ -e /var/run/docker.sock && ! -L /var/run/docker.sock ]] || ln -sfn "$TARGET_SOCK" /var/run/docker.sock
else
  log "跳过 /var/run/docker.sock 软链（更推荐依赖 DOCKER_HOST）。"
fi

# 安装 compose
if [[ "$INSTALL_COMPOSE_V2" == "1" ]]; then
  log "安装 docker-compose v2（独立二进制）..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) compose_arch="x86_64" ;;
    aarch64|arm64) compose_arch="aarch64" ;;
    armv7l) compose_arch="armv7" ;;
    *) die "不支持的架构：$arch" ;;
  esac
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}"
  install -d /usr/local/bin
  curl -fsSL "$url" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi
if [[ "$INSTALL_COMPOSE_V1" == "1" ]]; then
  log "安装 docker-compose v1（1.29.2，兼容老项目）..."
  curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose-v1
  chmod +x /usr/local/bin/docker-compose-v1
  ln -sfn /usr/local/bin/docker-compose-v1 /usr/local/bin/docker-compose-1
fi

# 自检
log "版本信息："
podman --version || true
if command -v docker-compose >/dev/null; then
  if [[ "$MODE" == "rootless" ]]; then
    sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/${USER_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" docker-compose version || true
  else
    docker-compose version || true
  fi
fi

log "完成。DOCKER_HOST=unix://$TARGET_SOCK"
