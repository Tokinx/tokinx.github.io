#!/usr/bin/env bash
# ============================================================
#  SSH Tunnel 一键管理脚本 (基于 autossh)
#  支持系统: Debian / Ubuntu / Alpine Linux
#  功能: 服务端隧道用户管理 + 客户端隧道管理
#  用法: bash ssh_tunnel.sh
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 全局常量
# ────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_DIR="/etc/ssh-tunnel"
readonly TUNNELS_DIR="${CONFIG_DIR}/tunnels"           # 客户端隧道配置
readonly KEYS_DIR="${CONFIG_DIR}/keys"                 # 客户端 SSH 私钥目录
readonly SERVER_USERS_DIR="${CONFIG_DIR}/server-users" # 服务端隧道用户元数据
readonly SERVER_KEYS_DIR="${CONFIG_DIR}/server-keys"   # 服务端为用户生成的密钥对
readonly LOG_DIR="/var/log/ssh-tunnel"
readonly RUNNER_DIR="/usr/local/lib/ssh-tunnel"
readonly RUNNER_BIN="${RUNNER_DIR}/run.sh"
readonly SYSTEMD_TEMPLATE="/etc/systemd/system/ssh-tunnel@.service"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/ssh-tunnel.conf"
readonly SSHD_MAIN_CONFIG="/etc/ssh/sshd_config"
readonly TUNNEL_GROUP="ssh-tunnel"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────
# 输出工具函数（输出到 stderr，避免污染命令替换）
# ────────────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title()   { echo -e "\n${BOLD}${CYAN}══════════════════════════════${NC}" >&2; echo -e "${BOLD}${CYAN}  $*${NC}" >&2; echo -e "${BOLD}${CYAN}══════════════════════════════${NC}" >&2; }
step()    { echo -e "${BLUE}  ▶${NC} $*" >&2; }
success() { echo -e "${GREEN}  ✔${NC} $*" >&2; }

has_utf8_locale() {
    local active_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    [[ "$active_locale" =~ [Uu][Tt][Ff]-?8 ]]
}

run_editor_command() {
    if has_utf8_locale; then
        "$@"
        return
    fi
    warn "当前终端 locale 非 UTF-8，已临时使用 C.UTF-8 启动编辑器"
    LANG=C.UTF-8 LC_CTYPE=C.UTF-8 LC_ALL=C.UTF-8 "$@"
}

open_editor() {
    local file="$1"
    local candidate
    local -a editor_cmd=()

    if [[ -n "${EDITOR:-}" ]]; then
        read -r -a editor_cmd <<<"${EDITOR}"
        if [[ ${#editor_cmd[@]} -gt 0 ]] && command -v "${editor_cmd[0]}" &>/dev/null; then
            run_editor_command "${editor_cmd[@]}" "$file"
            return
        fi
        warn "环境变量 EDITOR 不可用: ${EDITOR}，回退到默认编辑器优先级"
    fi

    for candidate in nano vim nvim vi; do
        if command -v "$candidate" &>/dev/null; then
            run_editor_command "$candidate" "$file"
            return
        fi
    done

    err "未找到可用编辑器，请安装 nano、vim、nvim 或 vi，或设置有效的 EDITOR 环境变量"
    return 1
}

# ────────────────────────────────────────────────────────────
# 系统检测
# ────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
    else
        OS_ID="unknown"
        OS_VERSION=""
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|raspbian) OS_FAMILY="debian" ;;
        alpine)                           OS_FAMILY="alpine" ;;
        *)
            warn "未经测试的系统: $OS_ID，将尝试以 debian 模式运行"
            OS_FAMILY="debian"
            ;;
    esac
}

detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif [[ -f /sbin/openrc-run ]] || command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="none"
        warn "未检测到 systemd 或 OpenRC，服务管理功能将不可用"
    fi
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "此操作需要 root 权限，请使用 sudo 或以 root 身份运行"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────
# 依赖安装
# ────────────────────────────────────────────────────────────
install_deps_base() {
    local deps=("ssh" "ssh-keygen")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    step "安装缺失依赖: ${missing[*]}"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq openssh-client
            ;;
        alpine)
            apk update -q
            apk add -q openssh-client
            ;;
    esac
}

install_autossh_pkg() {
    if command -v autossh &>/dev/null; then
        success "autossh 已安装: $(autossh -V 2>&1 | head -n1 || echo unknown)"
        return 0
    fi

    step "通过包管理器安装 autossh..."
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq autossh
            ;;
        alpine)
            apk update -q
            apk add -q autossh openssh-client
            ;;
        *)
            err "未支持的系统，无法自动安装 autossh"
            return 1
            ;;
    esac
    success "autossh 安装完成: $(autossh -V 2>&1 | head -n1 || echo unknown)"
}

# ────────────────────────────────────────────────────────────
# 安装：目录、runner、systemd 模板
# ────────────────────────────────────────────────────────────
ensure_dirs() {
    install -d -m 750 "$CONFIG_DIR"
    install -d -m 750 "$TUNNELS_DIR"
    install -d -m 700 "$KEYS_DIR"
    install -d -m 750 "$SERVER_USERS_DIR"
    install -d -m 700 "$SERVER_KEYS_DIR"
    install -d -m 755 "$LOG_DIR"
    install -d -m 755 "$RUNNER_DIR"
    touch "${CONFIG_DIR}/known_hosts"
    chmod 644 "${CONFIG_DIR}/known_hosts"
}

write_runner_script() {
    cat > "$RUNNER_BIN" <<'RUNNER_EOF'
#!/usr/bin/env bash
# SSH Tunnel runner - 由 ssh-tunnel@<name>.service 调用
# 读取 /etc/ssh-tunnel/tunnels/<name>.conf 并启动 autossh
set -euo pipefail

name="${1:?usage: run.sh <tunnel-name>}"
conf="/etc/ssh-tunnel/tunnels/${name}.conf"

if [[ ! -f "$conf" ]]; then
    echo "[ssh-tunnel] config not found: $conf" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$conf"

: "${TYPE:?TYPE not set (reverse|local|dynamic)}"
: "${REMOTE_USER:?REMOTE_USER not set}"
: "${REMOTE_HOST:?REMOTE_HOST not set}"
: "${REMOTE_PORT:=22}"
: "${IDENTITY_FILE:?IDENTITY_FILE not set}"
: "${FORWARDS:?FORWARDS not set}"
: "${SERVER_ALIVE_INTERVAL:=30}"
: "${SERVER_ALIVE_COUNT_MAX:=3}"
: "${EXTRA_OPTS:=}"

if [[ ! -r "$IDENTITY_FILE" ]]; then
    echo "[ssh-tunnel] identity file not readable: $IDENTITY_FILE" >&2
    exit 1
fi

forward_args=()
for fwd in $FORWARDS; do
    case "$TYPE" in
        reverse) forward_args+=("-R" "$fwd") ;;
        local)   forward_args+=("-L" "$fwd") ;;
        dynamic) forward_args+=("-D" "$fwd") ;;
        *)
            echo "[ssh-tunnel] unknown TYPE: $TYPE" >&2
            exit 1
            ;;
    esac
done

ssh_opts=(
    -N
    -T
    -o "ServerAliveInterval=${SERVER_ALIVE_INTERVAL}"
    -o "ServerAliveCountMax=${SERVER_ALIVE_COUNT_MAX}"
    -o "ExitOnForwardFailure=yes"
    -o "StrictHostKeyChecking=accept-new"
    -o "UserKnownHostsFile=/etc/ssh-tunnel/known_hosts"
    -o "TCPKeepAlive=yes"
    -o "ConnectTimeout=15"
    -o "IdentitiesOnly=yes"
    -p "${REMOTE_PORT}"
    -i "${IDENTITY_FILE}"
)

# 用 SSH 自身的 ServerAliveInterval 做健康检查，无需 autossh 的 monitoring port
export AUTOSSH_GATETIME=0
export AUTOSSH_PORT=0
export AUTOSSH_LOGLEVEL="${AUTOSSH_LOGLEVEL:-1}"

# shellcheck disable=SC2086
exec autossh -M 0 "${ssh_opts[@]}" "${forward_args[@]}" ${EXTRA_OPTS} \
    "${REMOTE_USER}@${REMOTE_HOST}"
RUNNER_EOF
    chmod +x "$RUNNER_BIN"
}

write_systemd_template() {
    [[ "$INIT_SYSTEM" != "systemd" ]] && return 0
    cat > "$SYSTEMD_TEMPLATE" <<'SVCEOF'
[Unit]
Description=SSH Tunnel (%i) via autossh
Documentation=https://www.harding.motd.ca/autossh/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
ExecStart=/usr/local/lib/ssh-tunnel/run.sh %i
Restart=always
RestartSec=10s
StandardOutput=append:/var/log/ssh-tunnel/%i.log
StandardError=append:/var/log/ssh-tunnel/%i.log
LimitNOFILE=65536
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
}

# ────────────────────────────────────────────────────────────
# 服务端：sshd 配置 + tunnel 用户组
# ────────────────────────────────────────────────────────────
ensure_tunnel_group() {
    if ! getent group "$TUNNEL_GROUP" &>/dev/null; then
        step "创建用户组: $TUNNEL_GROUP"
        case "$OS_FAMILY" in
            alpine) addgroup -S "$TUNNEL_GROUP" 2>/dev/null || groupadd --system "$TUNNEL_GROUP" ;;
            *)      groupadd --system "$TUNNEL_GROUP" ;;
        esac
    fi
}

ensure_sshd_dropin() {
    local marker_begin="# >>> ssh-tunnel managed config >>>"
    local marker_end="# <<< ssh-tunnel managed config <<<"
    local block
    block="$(cat <<EOF
${marker_begin}
Match Group ${TUNNEL_GROUP}
    # 认证方式：协议层强制只允许公钥，杜绝任何密码/键盘交互登录
    # (即使该用户被设了密码、或全局开启了密码认证，也不会生效)
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    # 仅允许端口转发，禁用 shell/X11/agent 等会话能力
    AllowTcpForwarding yes
    GatewayPorts clientspecified
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /usr/sbin/nologin
${marker_end}
EOF
)"

    local use_dropin=0
    if [[ -d /etc/ssh/sshd_config.d ]] && \
       grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN_CONFIG" 2>/dev/null; then
        use_dropin=1
    fi

    if [[ $use_dropin -eq 1 ]]; then
        step "写入 SSHD 配置: $SSHD_DROPIN"
        printf '%s\n' "$block" > "$SSHD_DROPIN"
        chmod 644 "$SSHD_DROPIN"
    else
        step "追加 SSHD 配置到主配置文件: $SSHD_MAIN_CONFIG"
        if grep -qF "$marker_begin" "$SSHD_MAIN_CONFIG" 2>/dev/null; then
            return 0
        fi
        printf '\n%s\n' "$block" >> "$SSHD_MAIN_CONFIG"
    fi

    if command -v sshd &>/dev/null; then
        if ! sshd -t 2>/dev/null; then
            err "sshd 配置校验失败，请手动检查 ${SSHD_MAIN_CONFIG} 或 ${SSHD_DROPIN}"
            return 1
        fi
    fi

    case "$INIT_SYSTEM" in
        systemd)
            local ssh_unit="ssh"
            systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' && ssh_unit="sshd"
            systemctl reload "$ssh_unit" 2>/dev/null || systemctl restart "$ssh_unit" 2>/dev/null || true
            ;;
        openrc)
            rc-service sshd reload 2>/dev/null || rc-service sshd restart 2>/dev/null || true
            ;;
    esac
    success "SSHD 配置已生效"
}

remove_sshd_dropin() {
    local marker_begin="# >>> ssh-tunnel managed config >>>"
    local marker_end="# <<< ssh-tunnel managed config <<<"

    if [[ -f "$SSHD_DROPIN" ]]; then
        rm -f "$SSHD_DROPIN"
        success "已删除 $SSHD_DROPIN"
    fi

    if grep -qF "$marker_begin" "$SSHD_MAIN_CONFIG" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk -v b="$marker_begin" -v e="$marker_end" '
            $0 ~ b { skip=1; next }
            $0 ~ e { skip=0; next }
            !skip
        ' "$SSHD_MAIN_CONFIG" > "$tmp"
        mv "$tmp" "$SSHD_MAIN_CONFIG"
        chmod 644 "$SSHD_MAIN_CONFIG"
        success "已从 $SSHD_MAIN_CONFIG 清理 ssh-tunnel 配置块"
    fi

    case "$INIT_SYSTEM" in
        systemd)
            local ssh_unit="ssh"
            systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' && ssh_unit="sshd"
            systemctl reload "$ssh_unit" 2>/dev/null || true
            ;;
        openrc)
            rc-service sshd reload 2>/dev/null || true
            ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 服务端：隧道用户管理
# ────────────────────────────────────────────────────────────
list_server_users() {
    echo ""
    echo -e "${BOLD}当前服务端隧道用户:${NC}"
    local found=0
    if [[ -d "$SERVER_USERS_DIR" ]]; then
        for meta in "$SERVER_USERS_DIR"/*.conf; do
            [[ -f "$meta" ]] || continue
            local username
            username="$(basename "$meta" .conf)"
            local exists="否"
            id "$username" &>/dev/null && exists="是"
            local in_group="否"
            id -nG "$username" 2>/dev/null | grep -qw "$TUNNEL_GROUP" && in_group="是"
            printf "  - %-20s [系统用户: %s] [组成员: %s]\n" "$username" "$exists" "$in_group"
            found=1
        done
    fi
    [[ $found -eq 0 ]] && echo -e "  ${DIM}(无)${NC}"
    echo ""
}

create_system_user() {
    local username="$1"
    case "$OS_FAMILY" in
        alpine)
            adduser -S -D -H -s /sbin/nologin -g "ssh-tunnel managed user" "$username" 2>/dev/null \
                || adduser -S -s /sbin/nologin -g "ssh-tunnel" "$username"
            # 确保 home 存在
            local home
            home="$(getent passwd "$username" | cut -d: -f6)"
            [[ -d "$home" ]] || install -d -m 755 -o "$username" -g "$username" "$home"
            ;;
        *)
            useradd --system \
                    --create-home \
                    --shell /usr/sbin/nologin \
                    --comment "ssh-tunnel managed user" \
                    "$username"
            ;;
    esac
    # 解除"账号锁定"状态：
    # useradd 默认将 shadow 密码字段写为 '!'，被 PAM 的 account 阶段视为 locked，
    # 即使使用公钥认证也会被拒绝（"User xxx not allowed because account is locked"）。
    # usermod -p '*' 在部分 Debian 版本上仍被 PAM 判为锁定，passwd -d 才彻底生效。
    # 清空密码字段后状态变为 NP (no password)，由 sshd 的 PermitEmptyPasswords no
    # 拦住密码登录，公钥认证可正常通过。
    passwd -d "$username" &>/dev/null || true
}

add_user_to_tunnel_group() {
    local username="$1"
    case "$OS_FAMILY" in
        alpine) addgroup "$username" "$TUNNEL_GROUP" 2>/dev/null || true ;;
        *)      usermod -aG "$TUNNEL_GROUP" "$username" ;;
    esac
}

add_server_user() {
    require_root
    ensure_tunnel_group
    ensure_sshd_dropin

    echo -e "${CYAN}添加服务端隧道用户${NC}"
    local username
    read -rp "  用户名 (字母开头, 字母/数字/下划线/连字符): " username
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "用户名格式无效"
        return 1
    fi

    if id "$username" &>/dev/null; then
        warn "系统用户 '$username' 已存在，将复用并加入 $TUNNEL_GROUP 组"
    else
        step "创建系统用户: $username"
        create_system_user "$username"
    fi
    add_user_to_tunnel_group "$username"

    # 自愈：复用已存在用户时，如 shadow 密码字段为锁定状态 ('!'/'!!')，清空之，
    # 否则 PAM account 阶段会拒绝公钥登录
    if getent shadow "$username" 2>/dev/null | awk -F: '{exit !($2=="!" || $2=="!!" || $2=="*")}'; then
        step "解除账号锁定: $username"
        passwd -d "$username" &>/dev/null || true
    fi

    local home
    home="$(getent passwd "$username" | cut -d: -f6)"
    if [[ -z "$home" || ! -d "$home" ]]; then
        err "无法定位用户 $username 的家目录"
        return 1
    fi
    install -d -m 700 -o "$username" -g "$username" "$home/.ssh"

    echo ""
    echo "  密钥配置方式:"
    echo "    1) 自动生成密钥对 (服务端保留公钥, 输出私钥供客户端使用)"
    echo "    2) 粘贴客户端已有公钥 (推荐, 私钥不离开客户端)"
    local key_choice
    read -rp "  选择 [1/2]: " key_choice

    local pubkey="" generated_privkey=""
    case "$key_choice" in
        1)
            local keyfile="${SERVER_KEYS_DIR}/${username}"
            if [[ -f "$keyfile" ]]; then
                warn "密钥文件已存在: $keyfile，将覆盖"
                rm -f "$keyfile" "${keyfile}.pub"
            fi
            step "生成 ed25519 密钥对..."
            ssh-keygen -t ed25519 -N "" -C "ssh-tunnel:${username}" -f "$keyfile" >/dev/null
            chmod 600 "$keyfile" "${keyfile}.pub"
            pubkey="$(cat "${keyfile}.pub")"
            generated_privkey="$keyfile"
            ;;
        2)
            echo "  请粘贴客户端的 SSH 公钥 (单行, 以 ssh-ed25519/ssh-rsa 等开头):"
            read -r pubkey
            if ! [[ "$pubkey" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+)[[:space:]] ]]; then
                err "公钥格式无效"
                return 1
            fi
            ;;
        *)
            err "无效选择"
            return 1
            ;;
    esac

    local auth_keys="$home/.ssh/authorized_keys"
    touch "$auth_keys"
    chown "$username:$username" "$auth_keys"
    chmod 600 "$auth_keys"

    local key_body
    key_body="$(awk '{print $2}' <<<"$pubkey")"
    if grep -qF "$key_body" "$auth_keys" 2>/dev/null; then
        warn "公钥已在 authorized_keys 中，跳过追加"
    else
        echo "no-pty,no-X11-forwarding,no-agent-forwarding,no-user-rc ${pubkey}" >> "$auth_keys"
        success "公钥已写入 $auth_keys"
    fi

    cat > "${SERVER_USERS_DIR}/${username}.conf" <<EOF
USERNAME=${username}
CREATED_AT=$(date -Iseconds 2>/dev/null || date)
EOF
    chmod 640 "${SERVER_USERS_DIR}/${username}.conf"

    success "用户 '${username}' 已就绪"
    echo ""
    if [[ -n "$generated_privkey" ]]; then
        echo -e "${YELLOW}══════════ 客户端私钥 (请妥善保存) ══════════${NC}"
        cat "$generated_privkey"
        echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
        echo ""
        echo -e "  服务端公钥: ${BOLD}${generated_privkey}.pub${NC}"
        echo -e "  ${DIM}在客户端将以上私钥保存为 /etc/ssh-tunnel/keys/<隧道名>，权限 600${NC}"
    fi
    echo ""
    echo -e "  连接信息:"
    echo -e "    用户: ${BOLD}${username}${NC}"
    echo -e "    主机: ${BOLD}$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')${NC}"
    echo -e "    端口: ${BOLD}$(awk '/^[[:space:]]*Port[[:space:]]/ {p=$2} END {print (p?p:22)}' "$SSHD_MAIN_CONFIG" 2>/dev/null || echo 22)${NC}"
}

edit_server_user() {
    require_root
    list_server_users
    local username
    read -rp "  输入要编辑的用户名: " username
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "用户名格式无效"
        return 1
    fi
    if ! id "$username" &>/dev/null; then
        err "用户 '$username' 不存在"
        return 1
    fi

    local home
    home="$(getent passwd "$username" | cut -d: -f6)"
    local auth_keys="$home/.ssh/authorized_keys"
    if [[ ! -f "$auth_keys" ]]; then
        warn "authorized_keys 不存在，将创建"
        install -d -m 700 -o "$username" -g "$username" "$home/.ssh"
        touch "$auth_keys"
        chown "$username:$username" "$auth_keys"
        chmod 600 "$auth_keys"
    fi

    info "即将打开 $auth_keys 进行编辑"
    open_editor "$auth_keys"
    chown "$username:$username" "$auth_keys"
    chmod 600 "$auth_keys"
    success "授权密钥已更新"
}

delete_server_user() {
    require_root
    list_server_users
    local username
    read -rp "  输入要删除的用户名: " username
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "用户名格式无效"
        return 1
    fi
    if ! id "$username" &>/dev/null && [[ ! -f "${SERVER_USERS_DIR}/${username}.conf" ]]; then
        err "用户 '$username' 不存在"
        return 1
    fi

    read -rp "  确认删除用户 '$username' (含家目录与密钥)? [y/N]: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "已取消"; return; }

    if id "$username" &>/dev/null; then
        case "$OS_FAMILY" in
            debian) userdel --remove "$username" 2>/dev/null || userdel "$username" 2>/dev/null || true ;;
            alpine) deluser --remove-home "$username" 2>/dev/null || deluser "$username" 2>/dev/null || true ;;
        esac
        success "系统用户 '$username' 已删除"
    fi

    rm -f "${SERVER_USERS_DIR}/${username}.conf"
    rm -f "${SERVER_KEYS_DIR}/${username}" "${SERVER_KEYS_DIR}/${username}.pub"
    success "用户元数据与密钥已清理"
}

# ────────────────────────────────────────────────────────────
# 客户端：隧道配置管理
# ────────────────────────────────────────────────────────────
tunnel_conf_file() {
    echo "${TUNNELS_DIR}/$1.conf"
}

list_client_tunnels() {
    echo ""
    echo -e "${BOLD}当前客户端隧道列表:${NC}"
    local found=0
    if [[ -d "$TUNNELS_DIR" ]]; then
        for conf in "$TUNNELS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local name
            name="$(basename "$conf" .conf)"
            (
                # shellcheck disable=SC1090
                . "$conf" 2>/dev/null
                local status="${RED}○ 停止${NC}"
                if svc_is_active "ssh-tunnel@${name}"; then
                    status="${GREEN}● 运行${NC}"
                fi
                printf "  - %-20s [类型: %-7s] [远端: %s@%s:%s] %b\n" \
                    "$name" "${TYPE:-?}" "${REMOTE_USER:-?}" "${REMOTE_HOST:-?}" "${REMOTE_PORT:-22}" "$status"
            )
            found=1
        done
    fi
    [[ $found -eq 0 ]] && echo -e "  ${DIM}(无)${NC}"
    echo ""
}

validate_forward_spec() {
    local type="$1" spec="$2"
    case "$type" in
        reverse|local)
            [[ "$spec" =~ ^(\[?[a-zA-Z0-9.:_-]+\]?:)?[0-9]+:[a-zA-Z0-9.:_-]+:[0-9]+$ ]] && return 0
            ;;
        dynamic)
            [[ "$spec" =~ ^(\[?[a-zA-Z0-9.:_-]+\]?:)?[0-9]+$ ]] && return 0
            ;;
    esac
    return 1
}

write_openrc_init() {
    local name="$1"
    local init_file="/etc/init.d/ssh-tunnel-${name}"
    cat > "$init_file" <<RCEOF
#!/sbin/openrc-run
name="ssh-tunnel-${name}"
description="SSH Tunnel (${name}) via autossh"
command="${RUNNER_BIN}"
command_args="${name}"
command_background=true
pidfile="/run/ssh-tunnel-${name}.pid"
output_log="${LOG_DIR}/${name}.log"
error_log="${LOG_DIR}/${name}.log"
respawn_delay=10
respawn_max=0

depend() {
    need net
    after firewall
}
RCEOF
    chmod +x "$init_file"
}

remove_openrc_init() {
    local name="$1"
    rm -f "/etc/init.d/ssh-tunnel-${name}"
}

add_client_tunnel() {
    require_root

    echo -e "${CYAN}添加客户端隧道${NC}"
    local name
    read -rp "  隧道名称 (字母/数字/下划线/连字符): " name
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    local conf
    conf="$(tunnel_conf_file "$name")"
    if [[ -f "$conf" ]]; then
        err "隧道 '$name' 已存在"
        return 1
    fi

    echo ""
    echo "  隧道类型:"
    echo "    1) reverse (-R) 反向隧道：将本地服务暴露到远端"
    echo "    2) local   (-L) 正向隧道：通过远端访问目标"
    echo "    3) dynamic (-D) SOCKS5 代理"
    local t_choice type
    read -rp "  选择 [1-3]: " t_choice
    case "$t_choice" in
        1) type="reverse" ;;
        2) type="local" ;;
        3) type="dynamic" ;;
        *) err "无效选择"; return 1 ;;
    esac

    local remote_user remote_host remote_port
    read -rp "  远端 SSH 用户: " remote_user
    if ! [[ "$remote_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "用户名格式无效"
        return 1
    fi
    read -rp "  远端 SSH 主机 (IP 或域名): " remote_host
    [[ -z "$remote_host" ]] && { err "主机不能为空"; return 1; }
    read -rp "  远端 SSH 端口 [默认 22]: " remote_port
    remote_port="${remote_port:-22}"
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || (( remote_port < 1 || remote_port > 65535 )); then
        err "端口无效"
        return 1
    fi

    echo ""
    echo "  SSH 私钥来源:"
    echo "    1) 现有私钥文件路径 (将复制到 ${KEYS_DIR}/${name})"
    echo "    2) 粘贴私钥内容 (PEM/OpenSSH 格式)"
    echo "    3) 已存在于 ${KEYS_DIR}/${name}，直接使用"
    local k_choice
    read -rp "  选择 [1-3]: " k_choice
    local identity_file="${KEYS_DIR}/${name}"
    case "$k_choice" in
        1)
            local src
            read -rp "  现有私钥路径: " src
            if [[ ! -f "$src" ]]; then
                err "文件不存在: $src"
                return 1
            fi
            install -m 600 "$src" "$identity_file"
            ;;
        2)
            echo "  请粘贴私钥内容，结束后输入仅含 'EOF' 的行:"
            local line
            : > "$identity_file"
            chmod 600 "$identity_file"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$identity_file"
            done
            if ! grep -q "PRIVATE KEY" "$identity_file"; then
                err "私钥格式不正确"
                rm -f "$identity_file"
                return 1
            fi
            ;;
        3)
            if [[ ! -f "$identity_file" ]]; then
                err "私钥不存在: $identity_file"
                return 1
            fi
            ;;
        *)
            err "无效选择"
            return 1
            ;;
    esac
    chmod 600 "$identity_file"

    # 自检：用 ssh-keygen 反推公钥，能成功才说明私钥格式真正可用
    # 可识别：CRLF 换行、首尾行缺失、内容截断、libcrypto 解析失败等
    if ! ssh-keygen -y -f "$identity_file" >/dev/null 2>&1; then
        err "私钥校验失败 (ssh-keygen -y 报错)，可能原因："
        err "  - 粘贴时丢失首尾行 (BEGIN/END PRIVATE KEY)"
        err "  - 换行符为 CRLF (Windows 格式)，需转 LF"
        err "  - 内容截断或包含额外字符"
        err "建议改用 base64 方式传输: 在源端执行 base64 -w0 <privkey> 后再解码写入"
        rm -f "$identity_file"
        return 1
    fi
    local key_fp
    key_fp="$(ssh-keygen -lf "$identity_file" 2>/dev/null | awk '{print $2}')"
    success "私钥校验通过, 指纹: ${key_fp}"
    info "请确认服务端 authorized_keys 中已包含相同指纹的公钥"

    echo ""
    case "$type" in
        reverse)
            echo "  转发规格 (反向): [bind_addr:]remote_port:local_host:local_port"
            echo "  示例: 8080:localhost:80  (将本机 80 暴露到远端 8080)"
            ;;
        local)
            echo "  转发规格 (正向): [bind_addr:]local_port:remote_host:remote_port"
            echo "  示例: 9000:127.0.0.1:3306  (通过隧道访问远端 3306)"
            ;;
        dynamic)
            echo "  转发规格 (动态): [bind_addr:]local_port"
            echo "  示例: 1080  (本机 SOCKS5 代理端口)"
            ;;
    esac
    echo "  多条规则用空格分隔"
    local forwards
    read -rp "  转发规格: " forwards
    [[ -z "$forwards" ]] && { err "转发规格不能为空"; return 1; }
    for f in $forwards; do
        if ! validate_forward_spec "$type" "$f"; then
            err "转发规格无效: $f"
            return 1
        fi
    done

    # reverse 隧道默认只在服务端 127.0.0.1 监听 (即使服务端 GatewayPorts clientspecified
    # 也需要客户端显式指定 bind 地址). 主动询问是否对外暴露, 自动补 0.0.0.0: 前缀,
    # 避免新手以为反向隧道"已通"但其他机器访问不到
    if [[ "$type" == "reverse" ]]; then
        # 检测用户是否已自行指定 bind 地址 (任何一条规则带 'IP:port:host:port' 形式即视为已指定)
        local has_bind=0
        for f in $forwards; do
            if [[ "$(awk -F: '{print NF}' <<<"$f")" -ge 4 ]]; then
                has_bind=1
                break
            fi
        done

        if [[ $has_bind -eq 0 ]]; then
            echo ""
            warn "反向隧道默认只在服务端 127.0.0.1 监听，其他机器无法访问"
            read -rp "  是否对外暴露 (绑定到 0.0.0.0)？[y/N]: " expose
            if [[ "$expose" == "y" || "$expose" == "Y" ]]; then
                local new_forwards=""
                for f in $forwards; do
                    new_forwards="${new_forwards}0.0.0.0:${f} "
                done
                forwards="${new_forwards% }"
                success "已自动添加 0.0.0.0: 前缀: ${forwards}"
                info "请确保服务端防火墙/安全组放行对应端口"
            else
                info "保持仅本地监听 (127.0.0.1)"
            fi
        fi
    fi

    local extra_opts
    read -rp "  额外 SSH 选项 (可选, 例 -o ServerAliveInterval=60): " extra_opts

    cat > "$conf" <<EOF
# SSH Tunnel: ${name}
# 由管理脚本自动生成 - $(date -Iseconds 2>/dev/null || date)

TYPE=${type}
REMOTE_USER=${remote_user}
REMOTE_HOST=${remote_host}
REMOTE_PORT=${remote_port}
IDENTITY_FILE=${identity_file}
FORWARDS="${forwards}"
EXTRA_OPTS="${extra_opts}"
SERVER_ALIVE_INTERVAL=30
SERVER_ALIVE_COUNT_MAX=3
EOF
    chmod 640 "$conf"
    success "隧道 '$name' 配置已写入 $conf"

    [[ "$INIT_SYSTEM" == "openrc" ]] && write_openrc_init "$name"

    read -rp "  立即启用并启动该隧道？[Y/n]: " enable_now
    if [[ "$enable_now" != "n" && "$enable_now" != "N" ]]; then
        svc_action enable "ssh-tunnel@${name}"
        success "隧道 '${name}' 已启动并设置开机自启"
    else
        info "可稍后通过 [服务控制] 菜单启动"
    fi
}

edit_client_tunnel() {
    require_root
    list_client_tunnels
    local name
    read -rp "  输入要编辑的隧道名称: " name
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    local conf
    conf="$(tunnel_conf_file "$name")"
    if [[ ! -f "$conf" ]]; then
        err "隧道 '$name' 不存在"
        return 1
    fi
    open_editor "$conf"
    chmod 640 "$conf"
    success "配置已保存"
    read -rp "  立即重启该隧道以生效？[Y/n]: " do_restart_now
    if [[ "$do_restart_now" != "n" && "$do_restart_now" != "N" ]]; then
        svc_action restart "ssh-tunnel@${name}"
        success "已重启"
    fi
}

delete_client_tunnel() {
    require_root
    list_client_tunnels
    local name
    read -rp "  输入要删除的隧道名称: " name
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    local conf
    conf="$(tunnel_conf_file "$name")"
    if [[ ! -f "$conf" ]]; then
        err "隧道 '$name' 不存在"
        return 1
    fi

    read -rp "  确认删除隧道 '$name'？[y/N]: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "已取消"; return; }

    svc_action disable "ssh-tunnel@${name}" 2>/dev/null || true
    [[ "$INIT_SYSTEM" == "openrc" ]] && remove_openrc_init "$name"

    rm -f "$conf"
    rm -f "${KEYS_DIR}/${name}" "${KEYS_DIR}/${name}.pub" 2>/dev/null || true
    rm -f "${LOG_DIR}/${name}.log" 2>/dev/null || true
    success "隧道 '$name' 已删除"
}

# ────────────────────────────────────────────────────────────
# 服务控制封装（per-tunnel）
# ────────────────────────────────────────────────────────────
svc_action() {
    local action="$1"  # start|stop|restart|enable|disable|status
    local svc="$2"     # ssh-tunnel@<name>
    local rc_svc="${svc/@/-}"

    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start|stop|restart|status)
                    systemctl "$action" "$svc"
                    ;;
                enable)
                    systemctl enable "$svc" 2>/dev/null || true
                    systemctl restart "$svc"
                    ;;
                disable)
                    systemctl stop "$svc" 2>/dev/null || true
                    systemctl disable "$svc" 2>/dev/null || true
                    ;;
            esac
            ;;
        openrc)
            case "$action" in
                start|stop|restart|status) rc-service "$rc_svc" "$action" ;;
                enable)
                    rc-update add "$rc_svc" default 2>/dev/null || true
                    rc-service "$rc_svc" restart
                    ;;
                disable)
                    rc-service "$rc_svc" stop 2>/dev/null || true
                    rc-update del "$rc_svc" default 2>/dev/null || true
                    ;;
            esac
            ;;
        none)
            warn "未检测到 init 系统，无法执行服务操作"
            ;;
    esac
}

svc_is_active() {
    local svc="$1"
    local rc_svc="${svc/@/-}"
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$svc" 2>/dev/null ;;
        openrc)  rc-service "$rc_svc" status &>/dev/null ;;
        none)    return 1 ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 状态显示
# ────────────────────────────────────────────────────────────
show_status() {
    detect_init
    local autossh_ver="未安装"
    command -v autossh &>/dev/null && autossh_ver="$(autossh -V 2>&1 | head -n1 || echo unknown)"

    echo -e "  ${BOLD}autossh:${NC} ${autossh_ver}"
    echo -e "  ${BOLD}init 系统:${NC} ${INIT_SYSTEM}"
    echo -e "  ${BOLD}配置目录:${NC} ${CONFIG_DIR}"

    local total=0 running=0
    if [[ -d "$TUNNELS_DIR" ]]; then
        for conf in "$TUNNELS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            total=$((total+1))
            local name
            name="$(basename "$conf" .conf)"
            svc_is_active "ssh-tunnel@${name}" && running=$((running+1))
        done
    fi
    echo -e "  ${BOLD}客户端隧道:${NC} ${running}/${total} 运行中"

    local user_count=0
    if [[ -d "$SERVER_USERS_DIR" ]]; then
        user_count="$(find "$SERVER_USERS_DIR" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l | tr -d ' ')"
    fi
    echo -e "  ${BOLD}服务端用户:${NC} ${user_count}"
    echo ""
}

# ────────────────────────────────────────────────────────────
# 日志
# ────────────────────────────────────────────────────────────
show_logs() {
    list_client_tunnels
    local name
    read -rp "  输入要查看日志的隧道名称: " name
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    local log_file="${LOG_DIR}/${name}.log"
    if [[ ! -f "$log_file" ]]; then
        warn "日志文件不存在: $log_file"
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            info "尝试通过 journalctl 查看:"
            journalctl -u "ssh-tunnel@${name}" -n 50 --no-pager 2>/dev/null || true
        fi
        return
    fi

    local lines=50
    echo -e "${DIM}── 显示最近 ${lines} 行 (${log_file}) ──${NC}"
    tail -n "$lines" "$log_file"
    echo ""
    read -rp "  按 f 实时跟踪日志，其他键返回: " follow
    if [[ "$follow" == "f" || "$follow" == "F" ]]; then
        echo -e "${DIM}(Ctrl+C 退出跟踪)${NC}"
        tail -f "$log_file"
    fi
}

# ────────────────────────────────────────────────────────────
# 启停/自启管理
# ────────────────────────────────────────────────────────────
select_tunnel_or_all() {
    list_client_tunnels >&2
    echo "  输入隧道名称，或输入 'all' 选择全部" >&2
    local name
    read -rp "  > " name
    if [[ "$name" == "all" || "$name" == "ALL" ]]; then
        echo "__ALL__"
        return
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    if [[ ! -f "$(tunnel_conf_file "$name")" ]]; then
        err "隧道 '$name' 不存在"
        return 1
    fi
    echo "$name"
}

iter_tunnels_action() {
    local action="$1" target="$2"
    if [[ "$target" == "__ALL__" ]]; then
        local count=0
        for conf in "$TUNNELS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local name
            name="$(basename "$conf" .conf)"
            step "${action} ${name}..."
            svc_action "$action" "ssh-tunnel@${name}" || warn "${name} ${action} 失败"
            count=$((count+1))
        done
        success "已对 ${count} 条隧道执行 ${action}"
    else
        svc_action "$action" "ssh-tunnel@${target}"
        success "${target} ${action} 完成"
    fi
}

manage_service_control() {
    require_root
    detect_init
    title "服务控制"

    echo "  1) 启动 (并设置开机自启)"
    echo "  2) 停止"
    echo "  3) 重启"
    echo "  4) 取消开机自启 (停止 + disable)"
    echo "  0) 返回"
    local op
    read -rp "  选择 [0-4]: " op

    local action=""
    case "$op" in
        1) action="enable" ;;
        2) action="stop" ;;
        3) action="restart" ;;
        4) action="disable" ;;
        0) return ;;
        *) err "无效选择"; return ;;
    esac

    local target
    target="$(select_tunnel_or_all)" || return
    iter_tunnels_action "$action" "$target"
}

do_restart() {
    require_root
    detect_init
    title "重启隧道"
    local target
    target="$(select_tunnel_or_all)" || return
    iter_tunnels_action restart "$target"
}

# ────────────────────────────────────────────────────────────
# 安装 / 卸载
# ────────────────────────────────────────────────────────────
do_install() {
    require_root
    title "安装 / 初始化 SSH Tunnel"

    detect_os
    detect_init
    install_deps_base
    install_autossh_pkg
    ensure_dirs
    write_runner_script
    write_systemd_template
    ensure_tunnel_group

    info "基础组件已就绪"
    info "服务端 SSHD 配置将在 [服务端配置管理 > 添加用户] 时自动写入"
    success "初始化完成"
}

do_uninstall() {
    require_root
    detect_init
    title "卸载 SSH Tunnel"

    warn "此操作将停止所有隧道、删除 runner 与服务模板"
    read -rp "  确认卸载？[y/N]: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { info "已取消"; return; }

    read -rp "  是否同时删除配置目录 ${CONFIG_DIR}？[y/N]: " del_config
    read -rp "  是否同时卸载 autossh 软件包？[y/N]: " del_pkg
    read -rp "  是否同时删除服务端隧道用户 (含家目录)？[y/N]: " del_users
    read -rp "  是否同时移除 SSHD 中的 ssh-tunnel 配置块？[y/N]: " del_sshd

    if [[ -d "$TUNNELS_DIR" ]]; then
        for conf in "$TUNNELS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local name
            name="$(basename "$conf" .conf)"
            step "停止隧道: $name"
            svc_action disable "ssh-tunnel@${name}" 2>/dev/null || true
            [[ "$INIT_SYSTEM" == "openrc" ]] && remove_openrc_init "$name"
        done
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        rm -f "$SYSTEMD_TEMPLATE"
        systemctl daemon-reload
    fi

    rm -rf "$RUNNER_DIR"
    success "已删除 runner 与服务模板"

    if [[ "$del_users" == "y" || "$del_users" == "Y" ]]; then
        if [[ -d "$SERVER_USERS_DIR" ]]; then
            for meta in "$SERVER_USERS_DIR"/*.conf; do
                [[ -f "$meta" ]] || continue
                local username
                username="$(basename "$meta" .conf)"
                step "删除用户: $username"
                case "$OS_FAMILY" in
                    debian) userdel --remove "$username" 2>/dev/null || true ;;
                    alpine) deluser --remove-home "$username" 2>/dev/null || deluser "$username" 2>/dev/null || true ;;
                esac
            done
        fi
        getent group "$TUNNEL_GROUP" &>/dev/null && groupdel "$TUNNEL_GROUP" 2>/dev/null || true
    fi

    if [[ "$del_sshd" == "y" || "$del_sshd" == "Y" ]]; then
        remove_sshd_dropin
    fi

    rm -rf "$LOG_DIR"
    success "已删除日志目录"

    if [[ "$del_config" == "y" || "$del_config" == "Y" ]]; then
        rm -rf "$CONFIG_DIR"
        success "已删除配置目录"
    else
        info "配置目录保留在 ${CONFIG_DIR}"
    fi

    if [[ "$del_pkg" == "y" || "$del_pkg" == "Y" ]]; then
        case "$OS_FAMILY" in
            debian) apt-get purge -y -qq autossh 2>/dev/null || true ;;
            alpine) apk del autossh 2>/dev/null || true ;;
        esac
        success "autossh 已卸载"
    fi

    success "SSH Tunnel 已卸载完成"
}

# ────────────────────────────────────────────────────────────
# 菜单
# ────────────────────────────────────────────────────────────
menu_server_config() {
    require_root
    while true; do
        title "服务端配置管理"
        list_server_users
        echo "  1) 添加隧道用户"
        echo "  2) 编辑用户授权密钥"
        echo "  3) 删除隧道用户"
        echo "  4) 重新写入 SSHD 配置"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-4]: " choice
        case "$choice" in
            1) add_server_user ;;
            2) edit_server_user ;;
            3) delete_server_user ;;
            4) ensure_tunnel_group; ensure_sshd_dropin ;;
            0) return ;;
            *) err "无效选择" ;;
        esac
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

menu_client_config() {
    require_root
    while true; do
        title "客户端配置管理"
        list_client_tunnels
        echo "  1) 添加隧道"
        echo "  2) 编辑隧道"
        echo "  3) 删除隧道"
        echo "  4) 查看隧道配置详情"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-4]: " choice
        case "$choice" in
            1) add_client_tunnel ;;
            2) edit_client_tunnel ;;
            3) delete_client_tunnel ;;
            4)
                local name
                read -rp "  输入隧道名称: " name
                local conf
                conf="$(tunnel_conf_file "$name")"
                if [[ -f "$conf" ]]; then
                    echo ""
                    cat "$conf"
                    echo ""
                else
                    err "隧道不存在"
                fi
                ;;
            0) return ;;
            *) err "无效选择" ;;
        esac
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ███████╗███████╗██╗  ██╗   ████████╗██╗   ██╗███╗   ██╗"
        echo "  ██╔════╝██╔════╝██║  ██║   ╚══██╔══╝██║   ██║████╗  ██║"
        echo "  ███████╗███████╗███████║      ██║   ██║   ██║██╔██╗ ██║"
        echo "  ╚════██║╚════██║██╔══██║      ██║   ██║   ██║██║╚██╗██║"
        echo "  ███████║███████║██║  ██║      ██║   ╚██████╔╝██║ ╚████║"
        echo "  ╚══════╝╚══════╝╚═╝  ╚═╝      ╚═╝    ╚═════╝ ╚═╝  ╚═══╝"
        echo -e "${NC}"
        echo -e "  ${DIM}SSH Tunnel 管理脚本 v${SCRIPT_VERSION} (基于 autossh)${NC}"
        echo ""

        show_status

        echo -e "  ${BOLD}── 安装 ──────────────────────────────${NC}"
        echo "  1) 安装 / 初始化 (含 autossh)"
        echo ""
        echo -e "  ${BOLD}── 配置管理 ──────────────────────────${NC}"
        echo "  2) 服务端配置 (隧道用户)"
        echo "  3) 客户端配置 (隧道)"
        echo ""
        echo -e "  ${BOLD}── 服务控制 ──────────────────────────${NC}"
        echo "  4) 启动 / 停止 / 开机自启"
        echo "  5) 重启隧道"
        echo ""
        echo -e "  ${BOLD}── 监控 ──────────────────────────────${NC}"
        echo "  6) 查看日志"
        echo ""
        echo -e "  ${BOLD}── 其他 ──────────────────────────────${NC}"
        echo "  7) 卸载"
        echo "  0) 退出"
        echo ""
        read -rp "  请选择 [0-7]: " choice

        case "$choice" in
            1) do_install ;;
            2) menu_server_config ;;
            3) menu_client_config ;;
            4) manage_service_control ;;
            5) do_restart ;;
            6) show_logs ;;
            7) do_uninstall ;;
            0) echo ""; info "再见！"; exit 0 ;;
            *) err "无效选择，请重试" ;;
        esac

        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ────────────────────────────────────────────────────────────
# 入口
# ────────────────────────────────────────────────────────────
main() {
    detect_os
    detect_init
    main_menu
}

main "$@"
