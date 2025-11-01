#!/usr/bin/env bash
set -Eeuo pipefail

# ========= 可通过环境变量覆盖的默认值 =========
MODE="${MODE:-root}"                     # rootless | root（默认 root 更稳妥）
USERNAME="${USERNAME:-docker_usr}"       # rootless 模式下的运行用户
USER_UID="${USER_UID:-1000}"             # 该用户的 UID
INSTALL_COMPOSE_V2="${INSTALL_COMPOSE_V2:-1}"
INSTALL_COMPOSE_V1="${INSTALL_COMPOSE_V1:-0}"   # v1 已弃用，不建议开启
SYMLINK_DOCKER_SOCK="${SYMLINK_DOCKER_SOCK:-0}" # 是否创建 /var/run/docker.sock 软链
ALLOW_LOW_PORTS="${ALLOW_LOW_PORTS:-0}"         # 是否放开 <1024 端口映射
INTERACTIVE="${INTERACTIVE:-0}"                 # 交互式模式
ENABLE_SWAP="${ENABLE_SWAP:-1}"                 # 是否创建/启用 Swap（默认开启）
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"           # Swap 大小（MB），默认 2048=2G
INSTALL_COMMON_PKGS="${INSTALL_COMMON_PKGS:-1}" # 是否安装常用工具（curl vim gzip tar bash less htop net-tools unzip）
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
  ENABLE_SWAP="$(ask_bool "创建并启用 Swap?" "$ENABLE_SWAP")"
  if [[ "$ENABLE_SWAP" == "1" ]]; then
    SWAP_SIZE_MB="$(ask_value "Swap 大小(MB)" "$SWAP_SIZE_MB")"
  fi

  INSTALL_COMMON_PKGS="$(ask_bool "安装常用工具包(curl vim gzip tar bash less htop net-tools unzip)?" "$INSTALL_COMMON_PKGS")"

  echo "\n== 配置摘要 =="
  echo "安装模式: $MODE"
  if [[ "$MODE" == "rootless" ]]; then
    echo "用户: $USERNAME (UID=$USER_UID)"
  fi
  echo "compose v2: $([[ "$INSTALL_COMPOSE_V2" == 1 ]] && echo 启用 || echo 关闭)"
  echo "compose v1: $([[ "$INSTALL_COMPOSE_V1" == 1 ]] && echo 启用 || echo 关闭)"
  echo "docker.sock 软链: $([[ "$SYMLINK_DOCKER_SOCK" == 1 ]] && echo 启用 || echo 关闭)"
  echo "低端口映射: $([[ "$ALLOW_LOW_PORTS" == 1 ]] && echo 允许 || echo 禁止)"
  echo "Swap: $([[ "$ENABLE_SWAP" == 1 ]] && echo 启用 || echo 关闭)，大小 ${SWAP_SIZE_MB}MB"
  echo "常用工具包: $([[ "$INSTALL_COMMON_PKGS" == 1 ]] && echo 启用 || echo 关闭)"
  read -r -p "确认开始安装? [Y/n] " _go || true
  _go="${_go:-y}"; [[ "${_go,,}" == y* ]] || die "用户取消。"
fi

# ========= 提前配置 Swap（在安装 Podman 之前） =========
setup_swap(){
  local size_mb="$1"
  local swapfile="${SWAPFILE_PATH:-/swapfile}"
  # 如果已有任何 swap，跳过
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    log "检测到已有 Swap，跳过创建。"
    return 0
  fi
  # 所需工具检查
  if ! command -v mkswap >/dev/null || ! command -v swapon >/dev/null; then
    warn "系统缺少 mkswap/swapon，跳过配置 Swap。"
    return 0
  fi
  log "正在创建 ${size_mb}MB Swap 文件：$swapfile ..."
  set +e
  fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=progress 2>/dev/null
  fi
  local alloc_rc=$?
  set -e
  if [[ $alloc_rc -ne 0 ]]; then
    warn "分配 Swap 文件失败，可能磁盘空间不足或文件系统不支持。"
    return 0
  fi
  chmod 600 "$swapfile"
  if ! mkswap "$swapfile" >/dev/null 2>&1; then
    warn "mkswap 失败，清理并跳过。"
    rm -f "$swapfile" || true
    return 0
  fi
  if ! swapon "$swapfile" >/dev/null 2>&1; then
    warn "启用 Swap 失败，清理并跳过。"
    swapoff "$swapfile" 2>/dev/null || true
    rm -f "$swapfile" || true
    return 0
  fi
  if ! grep -qF "$swapfile none swap sw 0 0" /etc/fstab 2>/dev/null; then
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
  fi
  log "Swap 已启用：$(swapon --show --noheadings || true)"
}

if [[ "$ENABLE_SWAP" == "1" ]]; then
  setup_swap "$SWAP_SIZE_MB"
else
  log "跳过 Swap 配置（ENABLE_SWAP=0）。"
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
if [[ "$INSTALL_COMMON_PKGS" == "1" ]]; then
  PKGS+=(curl vim gzip tar bash less htop net-tools unzip)
fi
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

# 为 Netavark 后端开启默认网络 DNS 解析
# 说明：部分环境下新建容器出现域名无法解析的问题，需为默认网络开启 dns_enabled
# 仅在 NetworkBackend=netavark 且存在默认网络 'podman' 时执行
NET_BACKEND="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
if [[ "${NET_BACKEND,,}" == "netavark" ]]; then
  log "检测到 NetworkBackend=netavark，设置默认网络 dns_enabled=true..."
  install -d -m 0755 /etc/containers/networks
  if podman network inspect podman >/dev/null 2>&1; then
    ts="$(date +%Y%m%d%H%M%S)"
    if [[ -f /etc/containers/networks/podman.json ]]; then
      cp -f /etc/containers/networks/podman.json "/etc/containers/networks/podman.json.bak-${ts}" || true
    fi
    # 以当前网络配置为基准，打开 dns_enabled
    podman network inspect podman \
      | jq '.[] | .dns_enabled = true' \
      > /etc/containers/networks/podman.json
  else
    warn "未找到默认网络 'podman'，跳过 dns_enabled 配置。"
  fi
else
  log "NetworkBackend=${NET_BACKEND:-unknown}（非 netavark），跳过 dns_enabled 配置。"
fi

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

# 重启 Podman 以使配置（如 registries.conf）生效
if [[ "$(ps -p 1 -o comm= --no-headers)" == "systemd" ]] && command -v systemctl >/dev/null; then
  if [[ "$MODE" == "rootless" ]]; then
    log "重启用户级 Podman（socket/service）..."
    sudo -u "$USERNAME" \
      XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
      bash -lc 'systemctl --user restart podman 2>/dev/null || true; systemctl --user restart podman.socket 2>/dev/null || true'
    # 回退方式（机器作用域）
    systemctl --user -M "${USERNAME}@.host" restart podman 2>/dev/null || true
    systemctl --user -M "${USERNAME}@.host" restart podman.socket 2>/dev/null || true
  else
    log "重启系统级 Podman（socket/service）..."
    systemctl restart podman 2>/dev/null || true
    systemctl restart podman.socket 2>/dev/null || true
  fi
else
  warn "非 systemd 环境或 systemctl 不可用，跳过重启 Podman。"
fi

if [[ -n "$TARGET_SOCK" ]]; then
  log "完成。DOCKER_HOST=unix://$TARGET_SOCK"
else
  log "完成。未设置 DOCKER_HOST（在无 systemd 环境下仍可直接使用 podman/docker 兼容命令）"
fi
