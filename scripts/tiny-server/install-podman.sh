#!/usr/bin/env bash
set -Eeuo pipefail

# ========= 可通过环境变量覆盖的默认值 =========
MODE="${MODE:-root}"                     # rootless | root（默认 root 更稳妥）
USERNAME="${USERNAME:-docker_usr}"       # rootless 模式下的运行用户
USER_UID="${USER_UID:-1000}"             # 该用户的 UID
INSTALL_COMPOSE_V2="${INSTALL_COMPOSE_V2:-1}"
INSTALL_COMPOSE_V1="${INSTALL_COMPOSE_V1:-0}"   # v1 已弃用，不建议开启
SYMLINK_DOCKER_SOCK="${SYMLINK_DOCKER_SOCK:-1}" # 是否创建 /var/run/docker.sock 软链
ALLOW_LOW_PORTS="${ALLOW_LOW_PORTS:-0}"         # 是否放开 <1024 端口映射
INTERACTIVE="${INTERACTIVE:-1}"                 # 交互式模式
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

# ========= 交互式配置 =========
ask_bool(){
  # 用法: ask_bool "提示" 默认值(1/0) -> 回显 1/0
  local prompt="$1"; local def="$2"; local hint="[y/N]"; local def_char="n"; local ans="";
  if [[ "$def" == "1" ]]; then hint="[Y/n]"; def_char="y"; fi
  read -r -p "$prompt $hint " ans || true
  ans="${ans:-$def_char}"
  case "${ans,,}" in
    y|yes) echo 1;;
    n|no)  echo 0;;
    *) echo "$def";;
  esac
}

ask_value(){
  # 用法: ask_value "提示" 默认 -> 回显值
  local prompt="$1"; local def="$2"; local ans="";
  read -r -p "$prompt [$def] " ans || true
  echo "${ans:-$def}"
}

ask_choice(){
  # 用法: ask_choice "提示" 默认 选项1 选项2 ... -> 回显所选
  local prompt="$1"; shift; local def="$1"; shift; local opts=($@); local ans="";
  local show_opts="${opts[*]}";
  read -r -p "$prompt (${show_opts}) [$def] " ans || true
  ans="${ans:-$def}"
  for o in "${opts[@]}"; do [[ "$ans" == "$o" ]] && { echo "$ans"; return; }; done
  echo "$def"
}

if [[ "$INTERACTIVE" == "1" ]]; then
  echo "== 交互式安装配置 =="
  MODE="$(ask_choice "选择安装模式" "$MODE" rootless root)"
  if [[ "$MODE" == "rootless" ]]; then
    USERNAME="$(ask_value "rootless 模式运行用户名" "$USERNAME")"
    USER_UID="$(ask_value "该用户 UID" "$USER_UID")"
  fi
  INSTALL_COMPOSE_V2="$(ask_bool "安装 docker-compose v2?" "$INSTALL_COMPOSE_V2")"
  INSTALL_COMPOSE_V1="$(ask_bool "安装 docker-compose v1(不推荐)?" "$INSTALL_COMPOSE_V1")"
  SYMLINK_DOCKER_SOCK="$(ask_bool "创建 /var/run/docker.sock 软链?" "$SYMLINK_DOCKER_SOCK")"
  ALLOW_LOW_PORTS="$(ask_bool "允许 rootless 绑定 <1024 端口?" "$ALLOW_LOW_PORTS")"

  echo "\n== 配置摘要 =="
  echo "安装模式: $MODE"
  if [[ "$MODE" == "rootless" ]]; then
    echo "用户: $USERNAME (UID=$USER_UID)"
  fi
  echo "compose v2: $([[ "$INSTALL_COMPOSE_V2" == 1 ]] && echo 启用 || echo 关闭)"
  echo "compose v1: $([[ "$INSTALL_COMPOSE_V1" == 1 ]] && echo 启用 || echo 关闭)"
  echo "docker.sock 软链: $([[ "$SYMLINK_DOCKER_SOCK" == 1 ]] && echo 启用 || echo 关闭)"
  echo "低端口映射: $([[ "$ALLOW_LOW_PORTS" == 1 ]] && echo 允许 || echo 禁止)"
  read -r -p "确认开始安装? [Y/n] " _go || true
  _go="${_go:-y}"; [[ "${_go,,}" == y* ]] || die "用户取消。"
fi

# 安装
log "安装 Podman 与依赖..."
apt-get update -y
# 根据发行版可用性选择 logind 相关包（Debian/Ubuntu: systemd 内含 logind；部分发行版为 elogind）
LOGIND_PKG=""
if apt-cache show systemd-logind >/dev/null 2>&1; then
  LOGIND_PKG="systemd-logind"
elif apt-cache show systemd >/dev/null 2>&1; then
  LOGIND_PKG="systemd"
elif apt-cache show elogind >/dev/null 2>&1; then
  LOGIND_PKG="elogind"
else
  warn "未找到可安装的 logind 包（systemd/elogind），将跳过安装。"
fi

# 组装安装包列表
PKGS=(podman podman-docker uidmap slirp4netns fuse-overlayfs \
  dbus-user-session curl wget ca-certificates jq sudo)
if [[ -n "$LOGIND_PKG" ]]; then
  PKGS+=("$LOGIND_PKG")
fi
apt-get install -y "${PKGS[@]}"

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
  # 自适应启用 logind 服务（systemd-logind 或 elogind）
  LOGIND_SVC=""
  if systemctl list-unit-files | grep -q '^systemd-logind\.service'; then
    LOGIND_SVC="systemd-logind"
  elif systemctl list-unit-files | grep -q '^elogind\.service'; then
    LOGIND_SVC="elogind"
  fi
  if [[ -n "$LOGIND_SVC" ]]; then
    systemctl enable --now "$LOGIND_SVC"
  else
    warn "未发现 logind 服务单元，跳过启用。"
  fi
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
  # root 模式（更稳妥）：仅在 systemd 存在且有 podman.socket 时启用 socket
  SOCKET_ENABLED=0
  if [[ "$(ps -p 1 -o comm= --no-headers)" == "systemd" ]] && command -v systemctl >/dev/null; then
    if systemctl list-unit-files | grep -q '^podman\.socket'; then
      log "启用系统级 podman.socket（root 模式）..."
      if systemctl enable --now podman.socket; then
        SOCKET_ENABLED=1
      else
        warn "启用 podman.socket 失败，跳过设置 DOCKER_HOST。"
      fi
    else
      warn "未发现 podman.socket 单元，跳过设置 DOCKER_HOST。"
    fi
  else
    warn "PID1 非 systemd 或 systemctl 不可用，跳过启用 podman.socket。"
  fi

  if [[ "$SOCKET_ENABLED" == "1" ]]; then
    TARGET_SOCK="/run/podman/podman.sock"
    DOCKER_HOST_LINE="export DOCKER_HOST=unix://$TARGET_SOCK"
    grep -q "$DOCKER_HOST_LINE" /root/.bashrc || echo "$DOCKER_HOST_LINE" >>/root/.bashrc
    echo "$DOCKER_HOST_LINE" >/etc/profile.d/podman-docker-host.sh
  else
    TARGET_SOCK=""  # 不设置 DOCKER_HOST，避免误导
  fi
fi

# 配置默认搜索仓库
log "配置默认搜索仓库 /etc/containers/registries.conf -> docker.io ..."
install -d -m 0755 /etc/containers
if [[ -f /etc/containers/registries.conf ]]; then
  ts="$(date +%Y%m%d%H%M%S)"
  cp -f /etc/containers/registries.conf "/etc/containers/registries.conf.bak-${ts}" || true
fi
cat >/etc/containers/registries.conf <<'EOF'
# Generated by install-podman.sh
[registries.search]
registries = ['docker.io']
EOF

# 可选软链
if [[ "$SYMLINK_DOCKER_SOCK" == "1" ]]; then
  log "创建 /var/run/docker.sock -> $TARGET_SOCK 软链..."
  install -d -m 0775 /var/run
  if [[ -n "$TARGET_SOCK" ]]; then
    [[ -e /var/run/docker.sock && ! -L /var/run/docker.sock ]] || ln -sfn "$TARGET_SOCK" /var/run/docker.sock
  else
    warn "无有效的 Podman socket，跳过 docker.sock 软链创建。"
  fi
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

if [[ -n "$TARGET_SOCK" ]]; then
  log "完成。DOCKER_HOST=unix://$TARGET_SOCK"
else
  log "完成。未设置 DOCKER_HOST（在无 systemd 环境下仍可直接使用 podman/docker 兼容命令）"
fi
