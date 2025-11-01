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
DOCKER_SERVICE_SHIM="${DOCKER_SERVICE_SHIM:-1}" # 是否创建 docker.service 兼容层（映射到 podman.socket）
DOCKER_CLI_HACKS="${DOCKER_CLI_HACKS:-1}"       # Docker CLI 兼容 hack：静默提示与 logs 参数重排
# Podman wrapper：剥离 Docker 专用但 Podman 不支持的参数（默认移除 --memory-swappiness）
PODMAN_WRAPPER_STRIP="${PODMAN_WRAPPER_STRIP:-1}"
# 以空格分隔的需要剥离的长选项名（仅名称，不含值），支持 --flag value 与 --flag=value 两种形式
# 默认列表以常见 Docker-only 或在 Podman/CGroups v2 下无效的选项为主
PODMAN_STRIP_FLAGS="${PODMAN_STRIP_FLAGS:---memory-swappiness --kernel-memory --cpu-rt-runtime --cpu-rt-period --device-read-bps --device-write-bps --device-read-iops --device-write-iops --oom-score-adj --init-path}"
# 拦截绝对路径 /usr/bin/docker（dpkg-divert）以强制走 wrapper
DOCKER_ABS_PATH_DIVERT="${DOCKER_ABS_PATH_DIVERT:-1}"
# 在 /var/run/docker.sock 上部署 API 过滤代理，剥离 Docker API 请求中的不支持字段
DOCKER_API_FILTER_PROXY="${DOCKER_API_FILTER_PROXY:-1}"
# 是否自动为容器生成并启用 systemd 单元（安装时对现有容器；运行时由代理对新容器）
AUTOGEN_SYSTEMD_UNITS="${AUTOGEN_SYSTEMD_UNITS:-1}"
# 仅对这些重启策略的容器生成单元（空格分隔）
AUTOGEN_MATCH_POLICY="${AUTOGEN_MATCH_POLICY:-always unless-stopped}"
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

  DOCKER_SERVICE_SHIM="$(ask_bool "创建 docker.service 兼容层(指向 podman.socket)?" "$DOCKER_SERVICE_SHIM")"

  DOCKER_CLI_HACKS="$(ask_bool "启用 Docker CLI 兼容 hack（静默兼容提示、修复 logs 参数顺序）?" "$DOCKER_CLI_HACKS")"

  PODMAN_WRAPPER_STRIP="$(ask_bool "安装 Podman wrapper 以剥离不支持的参数（如 --memory-swappiness）?" "$PODMAN_WRAPPER_STRIP")"
  if [[ "$PODMAN_WRAPPER_STRIP" == "1" ]]; then
    PODMAN_STRIP_FLAGS="$(ask_value "需剥离的参数名（空格分隔）" "$PODMAN_STRIP_FLAGS")"
  fi

  DOCKER_ABS_PATH_DIVERT="$(ask_bool "拦截绝对路径 /usr/bin/docker（dpkg-divert）?" "$DOCKER_ABS_PATH_DIVERT")"
  DOCKER_API_FILTER_PROXY="$(ask_bool "在 /var/run/docker.sock 部署 API 过滤代理?" "$DOCKER_API_FILTER_PROXY")"
  AUTOGEN_SYSTEMD_UNITS="$(ask_bool "自动为容器生成并启用 systemd 单元?" "$AUTOGEN_SYSTEMD_UNITS")"
  if [[ "$AUTOGEN_SYSTEMD_UNITS" == "1" ]]; then
    AUTOGEN_MATCH_POLICY="$(ask_value "匹配重启策略（空格分隔）" "$AUTOGEN_MATCH_POLICY")"
  fi

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
  echo "docker.service 兼容层: $([[ "$DOCKER_SERVICE_SHIM" == 1 ]] && echo 启用 || echo 关闭)"
  echo "Docker CLI 兼容 hack: $([[ "$DOCKER_CLI_HACKS" == 1 ]] && echo 启用 || echo 关闭)"
  echo "Podman 参数剥离 wrapper: $([[ "$PODMAN_WRAPPER_STRIP" == 1 ]] && echo 启用 || echo 关闭)（剥离: $PODMAN_STRIP_FLAGS）"
  echo "拦截 /usr/bin/docker: $([[ "$DOCKER_ABS_PATH_DIVERT" == 1 ]] && echo 启用 || echo 关闭)"
  echo "Docker API 过滤代理: $([[ "$DOCKER_API_FILTER_PROXY" == 1 ]] && echo 启用 || echo 关闭)"
  echo "自动生成 systemd 单元: $([[ "$AUTOGEN_SYSTEMD_UNITS" == 1 ]] && echo 启用 || echo 关闭)（策略: $AUTOGEN_MATCH_POLICY）"
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
  dbus-user-session curl wget ca-certificates jq sudo python3)
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

# Docker CLI 兼容 hack：静默兼容提示与 logs 参数顺序修复
if [[ "$DOCKER_CLI_HACKS" == "1" ]]; then
  install -d -m 0755 /etc/containers
  : >/etc/containers/nodocker
  install -d -m 0755 /usr/local/bin
  cat >/usr/local/bin/docker <<'EOWRAP'
#!/usr/bin/env bash
set -Eeuo pipefail

# Strip unsupported Docker flags before delegating to Podman
STRIP_FLAGS_DEFAULT=(--memory-swappiness --kernel-memory --cpu-rt-runtime --cpu-rt-period --device-read-bps --device-write-bps --device-read-iops --device-write-iops --oom-score-adj --init-path)
if [[ -n "${PODMAN_STRIP_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  STRIP_FLAGS=( ${PODMAN_STRIP_FLAGS} )
else
  STRIP_FLAGS=("${STRIP_FLAGS_DEFAULT[@]}")
fi

strip_args() {
  local out=()
  local skip_next=0
  for arg in "$@"; do
    if [[ "$skip_next" -eq 1 ]]; then
      skip_next=0
      continue
    fi
    local matched=0
    for f in "${STRIP_FLAGS[@]}"; do
      if [[ "$arg" == "$f" ]]; then
        matched=1
        skip_next=1
        break
      fi
      if [[ "$arg" == "$f"=* ]]; then
        matched=1
        break
      fi
    done
    [[ "$matched" -eq 1 ]] && continue
    out+=("$arg")
  done
  printf '%s\n' "${out[@]}"
}

if [[ "${1:-}" == "logs" ]]; then
  shift
  # Clean unsupported flags first (usually none for logs, but consistent)
  mapfile -t _cleaned < <(strip_args "$@")
  flags=()
  containers=()
  with_val=(--tail -n --since --until)
  needs_val=""
  for arg in "${_cleaned[@]}"; do
    if [[ -n "$needs_val" ]]; then
      flags+=("$arg"); needs_val=""; continue
    fi
    if [[ "$arg" == --* ]]; then
      if [[ "$arg" == *=* ]]; then
        flags+=("$arg")
      else
        flags+=("$arg")
        for w in "${with_val[@]}"; do
          if [[ "$arg" == "$w" ]]; then needs_val=1; break; fi
        done
      fi
      continue
    fi
    if [[ "$arg" == -n* && "$arg" != "-n" ]]; then
      flags+=("$arg"); continue
    fi
    if [[ "$arg" == -* ]]; then
      flags+=("$arg"); continue
    fi
    containers+=("$arg")
  done
  exec podman logs "${flags[@]}" "${containers[@]}"
else
  mapfile -t _cleaned < <(strip_args "$@")
  exec podman "${_cleaned[@]}"
fi
EOWRAP
  chmod +x /usr/local/bin/docker
  log "已启用 Docker CLI 兼容 hack：创建 /etc/containers/nodocker 与 /usr/local/bin/docker 包装器。"

  # 可选：拦截绝对路径 /usr/bin/docker 调用（dpkg-divert）
  if [[ "$DOCKER_ABS_PATH_DIVERT" == "1" ]]; then
    if ! dpkg-divert --list /usr/bin/docker 2>/dev/null | grep -q 'docker\.distrib'; then
      if dpkg-divert --local --rename --add /usr/bin/docker; then
        ln -sf /usr/local/bin/docker /usr/bin/docker
        log "已启用 dpkg-divert: /usr/bin/docker -> /usr/local/bin/docker"
      else
        warn "dpkg-divert /usr/bin/docker 失败，可能已被其它软件占用。"
      fi
    else
      ln -sf /usr/local/bin/docker /usr/bin/docker || true
      log "检测到已存在 divert，已更新 /usr/bin/docker -> /usr/local/bin/docker"
    fi

    # 安装自动清理：若未来安装真实 Docker（/usr/bin/dockerd 存在），撤销 divert
    cat >/usr/local/sbin/podman-docker-divert-cleanup.sh <<'EOSH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -x /usr/bin/dockerd ]]; then
  if dpkg-divert --list /usr/bin/docker 2>/dev/null | grep -q 'local'; then
    dpkg-divert --rename --remove /usr/bin/docker || true
  fi
fi
exit 0
EOSH
    chmod +x /usr/local/sbin/podman-docker-divert-cleanup.sh
    cat >/etc/systemd/system/podman-docker-divert-cleanup.service <<'EOF'
[Unit]
Description=Cleanup docker divert when real Docker is installed
ConditionPathExists=/usr/bin/dockerd

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/podman-docker-divert-cleanup.sh
EOF
    cat >/etc/systemd/system/podman-docker-divert-cleanup.path <<'EOF'
[Unit]
Description=Watch for /usr/bin/dockerd to cleanup docker divert

[Path]
PathExists=/usr/bin/dockerd

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable --now podman-docker-divert-cleanup.path || true
  else
    log "跳过 /usr/bin/docker divert（DOCKER_ABS_PATH_DIVERT=0）。"
  fi
else
  log "跳过 Docker CLI 兼容 hack（DOCKER_CLI_HACKS=0）。"
fi

# Podman wrapper：剥离 Docker 专用但 Podman 不支持的参数（默认移除 --memory-swappiness）
if [[ "$PODMAN_WRAPPER_STRIP" == "1" ]]; then
    install -d -m 0755 /usr/local/bin
    ts="$(date +%Y%m%d%H%M%S)"
    if [[ -e /usr/local/bin/podman && ! -L /usr/local/bin/podman ]]; then
      cp -f /usr/local/bin/podman "/usr/local/bin/podman.bak-${ts}" 2>/dev/null || true
    fi
    cat >/usr/local/bin/podman <<'EOWRAP'
#!/usr/bin/env bash
set -Eeuo pipefail

# Wrapper to strip unsupported Docker flags for Podman
# Default list covers common Docker-only/unsupported flags; extend via env PODMAN_STRIP_FLAGS
STRIP_FLAGS_DEFAULT=(--memory-swappiness --kernel-memory --cpu-rt-runtime --cpu-rt-period --device-read-bps --device-write-bps --device-read-iops --device-write-iops --oom-score-adj --init-path)

# If PODMAN_STRIP_FLAGS is set, use it; otherwise use default
if [[ -n "${PODMAN_STRIP_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  STRIP_FLAGS=( ${PODMAN_STRIP_FLAGS} )
else
  STRIP_FLAGS=("${STRIP_FLAGS_DEFAULT[@]}")
fi

args=()
skip_next=0
for arg in "$@"; do
  if [[ "$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi

  stripped=0
  for f in "${STRIP_FLAGS[@]}"; do
    # Match --flag and remove following value
    if [[ "$arg" == "$f" ]]; then
      stripped=1
      skip_next=1
      break
    fi
    # Match --flag=value form and drop
    if [[ "$arg" == "$f"=* ]]; then
      stripped=1
      break
    fi
  done
  if [[ "$stripped" -eq 1 ]]; then
    continue
  fi

  args+=("$arg")
done

exec /usr/bin/podman "${args[@]}"
EOWRAP
    chmod +x /usr/local/bin/podman
    log "已安装 Podman wrapper：剥离参数 ${PODMAN_STRIP_FLAGS}（可通过 PODMAN_STRIP_FLAGS 调整）。"
  else
    log "跳过 Podman wrapper（PODMAN_WRAPPER_STRIP=0）。"
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

# 安装时为现有容器自动生成并启用 systemd 单元（可选）
if [[ "$AUTOGEN_SYSTEMD_UNITS" == "1" ]]; then
  log "为现有容器生成并启用 systemd 单元（策略匹配：$AUTOGEN_MATCH_POLICY）..."
  gen_for_list(){
    local list_cmd="$1"; local mode="$2"; local user="$3"; local uid="$4";
    local names
    names=$(bash -lc "$list_cmd" 2>/dev/null || true)
    [[ -n "$names" ]] || return 0
    for c in $names; do
      local pol
      if [[ "$mode" == "rootless" ]]; then
        pol=$(sudo -u "$user" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" podman inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || true)
      else
        pol=$(podman inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || true)
      fi
      for want in $AUTOGEN_MATCH_POLICY; do
        if [[ "$pol" == "$want" ]]; then
          if [[ "$mode" == "rootless" ]]; then
            sudo -u "$user" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" podman generate systemd --new --name "$c" --files --restart-policy=always >/dev/null 2>&1 || true
            if [[ -f "container-$c.service" ]]; then
              install -D -m 0644 "container-$c.service" "/home/$user/.config/systemd/user/container-$c.service"
              chown "$user:$user" "/home/$user/.config/systemd/user/container-$c.service"
              rm -f "container-$c.service"
              sudo -u "$user" systemctl --user daemon-reload || true
              sudo -u "$user" systemctl --user enable --now "container-$c.service" || true
            fi
          else
            podman generate systemd --new --name "$c" --files --restart-policy=always >/dev/null 2>&1 || true
            if [[ -f "container-$c.service" ]]; then
              install -D -m 0644 "container-$c.service" "/etc/systemd/system/container-$c.service"
              rm -f "container-$c.service"
              systemctl daemon-reload || true
              systemctl enable --now "container-$c.service" || true
            fi
          fi
          break
        fi
      done
    done
  }
  if [[ "$MODE" == "rootless" ]]; then
    gen_for_list "sudo -u $USERNAME podman ps -a --format '{{.Names}}'" "rootless" "$USERNAME" "$USER_UID"
  else
    gen_for_list "podman ps -a --format '{{.Names}}'" "root" "" ""
  fi
else
  log "跳过现有容器 systemd 单元生成（AUTOGEN_SYSTEMD_UNITS=0）。"
fi

# ========== systemd docker.service 兼容层（可选） ==========
if [[ "$DOCKER_SERVICE_SHIM" == "1" ]]; then
  if [[ "$(ps -p 1 -o comm= --no-headers)" == "systemd" ]] && command -v systemctl >/dev/null; then
    if systemctl list-unit-files | grep -q '^podman\.socket'; then
      if ! systemctl list-unit-files | grep -q '^docker\.service'; then
        log "创建 docker.service 兼容层（映射到 podman.socket）..."
        cat >/etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker compatibility shim (via Podman socket)
Documentation=https://docs.podman.io/
Wants=podman.socket
After=network-online.target
ConditionPathExists=!/usr/bin/dockerd

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/systemctl start podman.socket
ExecStop=/bin/systemctl stop podman.socket
ExecReload=/bin/systemctl restart podman.socket

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable docker.service || true
      else
        warn "已存在 docker.service，跳过创建兼容层。"
      fi
      # 为 docker.socket 创建到 podman.socket 的别名（symlink），兼容 `systemctl restart docker.socket`
      if [[ ! -e /etc/systemd/system/docker.socket ]]; then
        frag_path="$(systemctl show -p FragmentPath podman.socket 2>/dev/null | sed -E 's/^FragmentPath=//')"
        target=""
        if [[ -n "$frag_path" && -f "$frag_path" ]]; then
          target="$frag_path"
        else
          for p in /lib/systemd/system/podman.socket /usr/lib/systemd/system/podman.socket /etc/systemd/system/podman.socket; do
            if [[ -f "$p" ]]; then target="$p"; break; fi
          done
        fi
        if [[ -n "$target" ]]; then
          ln -s "$target" /etc/systemd/system/docker.socket
          systemctl daemon-reload
          log "已创建 docker.socket -> $(basename "$target") 别名。"
        else
          warn "未找到 podman.socket 单元文件路径，无法创建 docker.socket 别名。"
        fi
      else
        warn "已存在 /etc/systemd/system/docker.socket，跳过创建。"
      fi
    else
      warn "未发现 podman.socket 单元，跳过 docker.service 兼容层创建。"
    fi
    # 安装自动清理逻辑：若未来安装了真实 Docker，则移除兼容层与别名
    log "安装 docker shim 自动清理逻辑（检测 /usr/bin/dockerd）..."
    cat >/usr/local/sbin/podman-docker-shim-cleanup.sh <<'EOSH'
#!/usr/bin/env bash
set -Eeuo pipefail

is_systemd(){ [[ "$(ps -p 1 -o comm= --no-headers)" == "systemd" ]] && command -v systemctl >/dev/null; }

if [[ ! -x /usr/bin/dockerd ]]; then
  exit 0
fi

if ! is_systemd; then
  exit 0
fi

# 只清理本脚本创建的 docker.service（位于 /etc/systemd/system 且指向 podman.socket 的 oneshot）
if [[ -f /etc/systemd/system/docker.service ]]; then
  if grep -q "Docker compatibility shim (via Podman socket)" /etc/systemd/system/docker.service 2>/dev/null \
     || grep -q "ExecStart=/bin/systemctl start podman.socket" /etc/systemd/system/docker.service 2>/dev/null; then
    systemctl disable --now docker.service 2>/dev/null || true
    rm -f /etc/systemd/system/docker.service || true
  fi
fi

# 只清理到 podman.socket 的 docker.socket 别名（符号链接且目标包含 podman.socket）
if [[ -L /etc/systemd/system/docker.socket ]]; then
  target="$(readlink -f /etc/systemd/system/docker.socket || true)"
  if [[ "$target" == *"podman.socket"* ]]; then
    systemctl stop docker.socket 2>/dev/null || true
    rm -f /etc/systemd/system/docker.socket || true
  fi
fi

systemctl daemon-reload || true
exit 0
EOSH
    chmod +x /usr/local/sbin/podman-docker-shim-cleanup.sh

    # systemd path 单元：监控 /usr/bin/dockerd 的出现并触发清理
    cat >/etc/systemd/system/podman-docker-shim-cleanup.service <<'EOF'
[Unit]
Description=Cleanup docker shim when real Docker is installed
ConditionPathExists=/usr/bin/dockerd

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/podman-docker-shim-cleanup.sh
EOF

    cat >/etc/systemd/system/podman-docker-shim-cleanup.path <<'EOF'
[Unit]
Description=Watch for /usr/bin/dockerd to cleanup docker shim

[Path]
PathExists=/usr/bin/dockerd

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || true
    systemctl enable --now podman-docker-shim-cleanup.path || true
    # 若已存在 dockerd，立即清理一次
    /usr/local/sbin/podman-docker-shim-cleanup.sh || true
  else
    warn "非 systemd 环境或 systemctl 不可用，跳过 docker.service 兼容层。"
  fi
else
  log "已禁用 docker.service 兼容层创建（DOCKER_SERVICE_SHIM=0）。"
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

# Docker API 过滤代理或软链
if [[ "$DOCKER_API_FILTER_PROXY" == "1" ]]; then
  if [[ -z "$TARGET_SOCK" ]]; then
    warn "无有效的 Podman socket，跳过 API 过滤代理部署。"
  else
    log "部署 Docker API 过滤代理：/var/run/docker.sock -> $TARGET_SOCK（剥离 MemorySwappiness 等不支持字段）..."
    install -d -m 0755 /usr/local/lib
    cat >/usr/local/lib/podman-docker-filter-proxy.py <<'PY'
#!/usr/bin/env python3
import os, sys, socket, threading, json, re, grp, subprocess, urllib.parse, tempfile, shutil

UPSTREAM = os.environ.get('UPSTREAM_SOCK', '')
LISTEN = '/var/run/docker.sock'
MODE = os.environ.get('PODMAN_MODE', 'root')
USERNAME = os.environ.get('PODMAN_USER', '')
USER_UID = os.environ.get('USER_UID', '')
AUTO_UNIT = os.environ.get('AUTO_UNIT', '1') == '1'
PROXY_LOG = os.environ.get('PROXY_LOG', '0') == '1'

STRIP_CREATE = {
    'HostConfig': [
        'MemorySwappiness','KernelMemory','CpuRealtimeRuntime','CpuRealtimePeriod',
        'BlkioDeviceReadBps','BlkioDeviceWriteBps','BlkioDeviceReadIOps','BlkioDeviceWriteIOps',
        'OomScoreAdj','InitPath'
    ]
}
STRIP_UPDATE = [
    'MemorySwappiness','KernelMemory','CpuRealtimeRuntime','CpuRealtimePeriod',
    'BlkioDeviceReadBps','BlkioDeviceWriteBps','BlkioDeviceReadIOps','BlkioDeviceWriteIOps'
]

def read_headers(conn):
    data = b''
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    request = lines[0].decode('latin-1') if lines else ''
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            k,v = line.split(b":",1)
            headers[k.strip().lower()] = v.strip()
    return request, headers, rest

def read_body(conn, headers, buf):
    body = buf
    te = headers.get(b'transfer-encoding')
    if te and b'chunked' in te:
        # naive chunked reader
        while True:
            line = b''
            while not line.endswith(b'\r\n'):
                c = conn.recv(1)
                if not c: break
                line += c
            size = int(line.strip().split(b';')[0], 16)
            if size == 0:
                # read trailer CRLF
                _ = conn.recv(2)
                break
            chunk = b''
            while len(chunk) < size:
                chunk += conn.recv(size - len(chunk))
            body += chunk
            _ = conn.recv(2)  # CRLF
    else:
        cl = headers.get(b'content-length')
        if cl:
            need = int(cl)
            while len(body) < need:
                more = conn.recv(need - len(body))
                if not more: break
                body += more
    return body

def rewrite(path, body):
    try:
        obj = json.loads(body.decode('utf-8') or 'null')
    except Exception:
        return body
    changed = False
    if obj is None:
        return body
    if re.search(r"/containers/create(?=$|\?)", path):
        hc = obj.get('HostConfig')
        if isinstance(hc, dict):
            for k in STRIP_CREATE['HostConfig']:
                if k in hc:
                    hc.pop(k, None); changed = True
    elif re.search(r"/containers/[^/]+/update(?=$|\?)", path):
        if isinstance(obj, dict):
            for k in STRIP_UPDATE:
                if k in obj:
                    obj.pop(k, None); changed = True
    if changed:
        return json.dumps(obj, separators=(',',':')).encode('utf-8')
    return body

def forward(reqline, headers, body):
    # build request to upstream
    m, p, v = reqline.split(' ', 2)
    # remove TE, set CL
    headers.pop(b'transfer-encoding', None)
    headers[b'content-length'] = str(len(body)).encode('ascii')
    # ensure connection close
    headers[b'connection'] = b'close'
    # compose raw request
    out = (f"{m} {p} {v}\r\n").encode('latin-1')
    for k, v in headers.items():
        out += k + b": " + v + b"\r\n"
    out += b"\r\n" + body
    # send to upstream unix socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(UPSTREAM)
    s.sendall(out)
    # stream back
    chunks = []
    while True:
        chunk = s.recv(8192)
        if not chunk: break
        chunks.append(chunk)
    s.close()
    return b''.join(chunks)

def _run(cmd, env=None):
    try:
        if PROXY_LOG:
            sys.stderr.write('[proxy] run: %s\n' % ' '.join(cmd))
        subprocess.run(cmd, check=True, env=env)
    except Exception as e:
        if PROXY_LOG:
            sys.stderr.write('[proxy] cmd failed: %s\n' % e)

def _inspect_name_root(cid):
    out = subprocess.check_output(['/usr/bin/podman','inspect','--format','{{.Name}}',cid])
    return out.decode().strip().lstrip('/')

def _inspect_name_user(cid, username, uid):
    env = os.environ.copy()
    env.update({
        'XDG_RUNTIME_DIR': f'/run/user/{uid}',
        'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{uid}/bus'
    })
    out = subprocess.check_output(['sudo','-u',username,'/usr/bin/podman','inspect','--format','{{.Name}}',cid], env=env)
    return out.decode().strip().lstrip('/')

def autounit_async(cid, name_hint=None):
    def worker():
        try:
            if MODE == 'rootless' and USERNAME and USER_UID:
                uid = USER_UID
                name = name_hint or _inspect_name_user(cid, USERNAME, uid)
                tmpd = tempfile.mkdtemp(prefix='podman-autounit-')
                envu = {
                    'XDG_RUNTIME_DIR': f'/run/user/{uid}',
                    'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{uid}/bus'
                }
                _run(['sudo','-u',USERNAME,'/usr/bin/podman','generate','systemd','--new','--name',name,'--files','--restart-policy=always'], env=envu)
                svc_cand = f'container-{name}.service'
                # move to user systemd dir
                outdir = f'/home/{USERNAME}/.config/systemd/user'
                os.makedirs(outdir, exist_ok=True)
                if os.path.exists(svc_cand):
                    shutil.move(svc_cand, os.path.join(outdir, svc_cand))
                _run(['sudo','-u',USERNAME,'systemctl','--user','daemon-reload'])
                _run(['sudo','-u',USERNAME,'systemctl','--user','enable','--now',svc_cand])
            else:
                name = name_hint or _inspect_name_root(cid)
                _run(['/usr/bin/podman','generate','systemd','--new','--name',name,'--files','--restart-policy=always'])
                svc_cand = f'container-{name}.service'
                if os.path.exists(svc_cand):
                    shutil.move(svc_cand, os.path.join('/etc/systemd/system', svc_cand))
                _run(['systemctl','daemon-reload'])
                _run(['systemctl','enable','--now',svc_cand])
        except Exception as e:
            if PROXY_LOG:
                sys.stderr.write('[proxy] autounit failed: %s\n' % e)
    threading.Thread(target=worker, daemon=True).start()

def handle(c):
    try:
        reqline, headers, rest = read_headers(c)
        if not reqline:
            c.close(); return
        parts = reqline.split(' ')
        method = parts[0]
        path = parts[1] if len(parts) > 1 else '/'
        body = read_body(c, headers, rest)
        # only rewrite for create/update
        if method in ('POST','PUT','PATCH'):
            body = rewrite(path, body)
        resp = forward(reqline, headers, body)
        # autounit on successful create
        if AUTO_UNIT and method == 'POST' and re.search(r"/containers/create(?=$|\?)", path):
            try:
                head, _, tail = resp.partition(b"\r\n\r\n")
                status = head.split(b"\r\n",1)[0]
                if b" 201 " in status:
                    j = json.loads(tail.decode('utf-8'))
                    cid = j.get('Id') or j.get('id')
                    parsed = urllib.parse.urlparse(path)
                    q = urllib.parse.parse_qs(parsed.query or '')
                    name_hint = q.get('name',[None])[0]
                    if cid:
                        autounit_async(cid, name_hint)
            except Exception as e:
                if PROXY_LOG:
                    sys.stderr.write('[proxy] parse create resp failed: %s\n' % e)
        c.sendall(resp)
    except Exception as e:
        try:
            msg = ("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 21\r\n\r\nproxy error: failed").encode('latin-1')
            c.sendall(msg)
        except Exception:
            pass
    finally:
        try: c.close()
        except Exception: pass

def main():
    if not UPSTREAM:
        sys.stderr.write('UPSTREAM_SOCK not set\n'); sys.exit(1)
    # cleanup any existing sock
    try: os.unlink(LISTEN)
    except FileNotFoundError: pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(LISTEN)
    try:
        gid = grp.getgrnam('docker').gr_gid
        os.chmod(LISTEN, 0o660)
        os.chown(LISTEN, 0, gid)
    except Exception:
        os.chmod(LISTEN, 0o660)
    s.listen(64)
    while True:
        c,_ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == '__main__':
    main()
PY
    chmod +x /usr/local/lib/podman-docker-filter-proxy.py

    cat >/etc/systemd/system/docker-proxy.service <<EOF
[Unit]
Description=Docker API filter proxy (docker.sock -> podman.sock)
After=network.target
Wants=podman.socket

[Service]
Type=simple
Environment=UPSTREAM_SOCK=$TARGET_SOCK
Environment=PODMAN_MODE=$MODE
Environment=PODMAN_USER=$USERNAME
Environment=USER_UID=$USER_UID
Environment=AUTO_UNIT=$AUTOGEN_SYSTEMD_UNITS
ExecStart=/usr/bin/python3 -u /usr/local/lib/podman-docker-filter-proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || true
    systemctl enable --now docker-proxy.service || true
  fi
else
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
