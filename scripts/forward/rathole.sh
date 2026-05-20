#!/usr/bin/env bash
# ============================================================
#  rathole 一键管理脚本
#  支持系统: Debian / Ubuntu / Alpine Linux
#  支持架构: x86_64, aarch64, armv7
#  用法: bash rathole.sh [--cdn <url>]
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 全局常量
# ────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly GITHUB_REPO="rathole-org/rathole"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/rathole"
readonly LOG_DIR="/var/log/rathole"
readonly SERVICE_NAME_SERVER="rathole-server"
readonly SERVICE_NAME_CLIENT="rathole-client"
readonly BINARY="rathole"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ────────────────────────────────────────────────────────────
# 解析命令行参数
# ────────────────────────────────────────────────────────────
CDN_PREFIX=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cdn)
                if [[ -z "${2:-}" ]]; then
                    err "参数 --cdn 需要一个 URL 值"
                    exit 1
                fi
                # 去除末尾斜杠，防止 URL 拼接双斜杠
                CDN_PREFIX="${2%/}"
                shift 2
                ;;
            --cdn=*)
                CDN_PREFIX="${1#--cdn=}"
                CDN_PREFIX="${CDN_PREFIX%/}"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

show_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --cdn <url>    指定 GitHub 下载加速前缀，例如 https://ghfast.top"
    echo "  -h, --help     显示帮助信息"
    echo ""
    echo "示例:"
    echo "  bash $0"
    echo "  bash $0 --cdn https://ghfast.top"
}

# ────────────────────────────────────────────────────────────
# 输出工具函数
# ────────────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title()   { echo -e "\n${BOLD}${CYAN}══════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════${NC}"; }
step()    { echo -e "${BLUE}  ▶${NC} $*"; }
success() { echo -e "${GREEN}  ✔${NC} $*"; }

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

detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        armv7*|armv6*) ARCH="armv7" ;;
        *)
            err "不支持的 CPU 架构: $machine"
            exit 1
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
# 依赖检查与安装
# ────────────────────────────────────────────────────────────
install_deps() {
    local deps=("curl" "wget" "unzip" "jq")
    local missing=()

    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    step "安装缺失依赖: ${missing[*]}"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}"
            ;;
        alpine)
            apk update -q
            apk add -q "${missing[@]}"
            ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 下载与安装
# ────────────────────────────────────────────────────────────
get_latest_version() {
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local version

    # 若设置了 CDN 前缀，仍通过 GitHub API 获取版本号（API 不走 CDN）
    version="$(curl -fsSL "$api_url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"

    if [[ -z "$version" ]]; then
        err "无法获取最新版本号，请检查网络连接"
        exit 1
    fi
    echo "$version"
}

build_download_url() {
    local version="$1"
    local arch="$2"

    # 架构映射到 rathole 的发布文件名
    local target
    case "$arch" in
        x86_64)  target="x86_64-unknown-linux-musl" ;;
        aarch64) target="aarch64-unknown-linux-musl" ;;
        armv7)   target="armv7-unknown-linux-musleabihf" ;;
    esac

    local filename="rathole-${target}.zip"
    local github_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"

    if [[ -n "$CDN_PREFIX" ]]; then
        # CDN 前缀拼接，安全处理 URL
        echo "${CDN_PREFIX}/${github_url}"
    else
        echo "$github_url"
    fi
}

do_install() {
    require_root
    title "安装 rathole"

    detect_os
    detect_arch
    detect_init
    install_deps

    step "检测系统: ${OS_FAMILY} / ${ARCH} / init:${INIT_SYSTEM}"

    # 获取版本
    local version
    step "获取最新版本..."
    version="$(get_latest_version)"
    success "最新版本: ${version}"

    # 构建下载地址
    local download_url
    download_url="$(build_download_url "$version" "$ARCH")"
    step "下载地址: ${download_url}"

    # 创建临时目录（在工作目录内，避免权限问题）
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/rathole-install-XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp_dir}'" EXIT

    local zip_file="${tmp_dir}/rathole.zip"

    step "下载 rathole ${version}..."
    if ! curl -fsSL -o "$zip_file" "$download_url"; then
        err "下载失败: $download_url"
        exit 1
    fi
    success "下载完成"

    step "解压并安装..."
    unzip -q "$zip_file" -d "$tmp_dir"

    # 查找二进制文件
    local binary_path
    binary_path="$(find "$tmp_dir" -type f -name "$BINARY" | head -n1)"
    if [[ -z "$binary_path" ]]; then
        err "解压后未找到 rathole 可执行文件"
        exit 1
    fi

    chmod +x "$binary_path"
    mv "$binary_path" "${INSTALL_DIR}/${BINARY}"
    success "安装到 ${INSTALL_DIR}/${BINARY}"

    # 创建目录
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    chmod 750 "$CONFIG_DIR"
    chmod 755 "$LOG_DIR"
    success "配置目录: ${CONFIG_DIR}"

    # 安装服务
    case "$INIT_SYSTEM" in
        systemd) install_systemd_services ;;
        openrc)  install_openrc_services ;;
        none)    warn "跳过服务安装（未检测到 init 系统）" ;;
    esac

    success "rathole ${version} 安装完成！"
    echo ""
    info "提示: 使用本脚本管理 rathole（运行脚本查看菜单）"
}

# ────────────────────────────────────────────────────────────
# Systemd 服务
# ────────────────────────────────────────────────────────────
install_systemd_services() {
    step "安装 systemd 服务..."

    # Server 服务
    cat > "/etc/systemd/system/${SERVICE_NAME_SERVER}.service" <<'SVCEOF'
[Unit]
Description=rathole Server
Documentation=https://github.com/rathole-org/rathole
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rathole /etc/rathole/server.toml
Restart=on-failure
RestartSec=5s
StandardOutput=append:/var/log/rathole/server.log
StandardError=append:/var/log/rathole/server.log
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/rathole

[Install]
WantedBy=multi-user.target
SVCEOF

    # Client 服务
    cat > "/etc/systemd/system/${SERVICE_NAME_CLIENT}.service" <<'SVCEOF'
[Unit]
Description=rathole Client
Documentation=https://github.com/rathole-org/rathole
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rathole /etc/rathole/client.toml
Restart=on-failure
RestartSec=5s
StandardOutput=append:/var/log/rathole/client.log
StandardError=append:/var/log/rathole/client.log
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/rathole

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    success "systemd 服务已安装"
}

# ────────────────────────────────────────────────────────────
# OpenRC 服务（Alpine）
# ────────────────────────────────────────────────────────────
install_openrc_services() {
    step "安装 OpenRC 服务..."

    # Server
    cat > "/etc/init.d/${SERVICE_NAME_SERVER}" <<'RCEOF'
#!/sbin/openrc-run
name="rathole-server"
description="rathole Server"
command="/usr/local/bin/rathole"
command_args="/etc/rathole/server.toml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/rathole/server.log"
error_log="/var/log/rathole/server.log"

depend() {
    need net
    after firewall
}
RCEOF
    chmod +x "/etc/init.d/${SERVICE_NAME_SERVER}"

    # Client
    cat > "/etc/init.d/${SERVICE_NAME_CLIENT}" <<'RCEOF'
#!/sbin/openrc-run
name="rathole-client"
description="rathole Client"
command="/usr/local/bin/rathole"
command_args="/etc/rathole/client.toml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/rathole/client.log"
error_log="/var/log/rathole/client.log"

depend() {
    need net
    after firewall
}
RCEOF
    chmod +x "/etc/init.d/${SERVICE_NAME_CLIENT}"

    success "OpenRC 服务已安装"
}

# ────────────────────────────────────────────────────────────
# 服务控制封装
# ────────────────────────────────────────────────────────────
svc_action() {
    local action="$1"   # start | stop | restart | enable | disable | status
    local svc="$2"      # rathole-server | rathole-client

    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start|stop|restart|status)
                    systemctl "$action" "$svc"
                    ;;
                enable)
                    systemctl enable "$svc"
                    systemctl start "$svc"
                    ;;
                disable)
                    systemctl stop "$svc" 2>/dev/null || true
                    systemctl disable "$svc"
                    ;;
            esac
            ;;
        openrc)
            case "$action" in
                start|stop|restart|status)
                    rc-service "$svc" "$action"
                    ;;
                enable)
                    rc-update add "$svc" default
                    rc-service "$svc" start
                    ;;
                disable)
                    rc-service "$svc" stop 2>/dev/null || true
                    rc-update del "$svc" default
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
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$svc" 2>/dev/null ;;
        openrc)  rc-service "$svc" status &>/dev/null ;;
        none)    return 1 ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 配置管理 - 服务端
# ────────────────────────────────────────────────────────────
server_config_file="${CONFIG_DIR}/server.toml"

list_server_services() {
    if [[ ! -f "$server_config_file" ]]; then
        info "服务端配置文件不存在"
        return
    fi
    echo ""
    echo -e "${BOLD}当前服务端隧道列表:${NC}"
    # 提取 [server.services.<name>] 节名
    grep -oP '(?<=\[server\.services\.)[^\]]+' "$server_config_file" 2>/dev/null \
        | nl -ba -nrz -w3 | sed 's/^/  /' || info "  (无隧道配置)"
    echo ""
}

add_server_service() {
    mkdir -p "$CONFIG_DIR"

    # 若无配置文件，生成基础模板
    if [[ ! -f "$server_config_file" ]]; then
        local bind_port default_token
        echo -e "${CYAN}首次配置服务端${NC}"
        read -rp "  服务端监听端口 (默认 2333): " bind_port
        bind_port="${bind_port:-2333}"

        # 验证端口号是合法整数
        if ! [[ "$bind_port" =~ ^[0-9]+$ ]] || (( bind_port < 1 || bind_port > 65535 )); then
            err "端口号无效: $bind_port"
            return 1
        fi

        # 生成随机 token（使用系统随机源）
        default_token="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 2>/dev/null || echo "change_me_$(date +%s)")"

        cat > "$server_config_file" <<EOF
# rathole 服务端配置
# 由管理脚本自动生成

[server]
bind_addr = "0.0.0.0:${bind_port}"
default_token = "${default_token}"

EOF
        chmod 640 "$server_config_file"
        success "创建配置文件: $server_config_file"
        info "默认 Token: ${default_token}"
    fi

    echo -e "${CYAN}添加服务端隧道${NC}"
    local svc_name remote_addr token

    read -rp "  隧道名称 (字母/数字/下划线): " svc_name
    # 安全校验名称，只允许字母、数字、下划线、连字符
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称只能包含字母、数字、下划线和连字符"
        return 1
    fi

    # 检查是否已存在
    if grep -q "\[server\.services\.${svc_name}\]" "$server_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 已存在，请先删除后再添加"
        return 1
    fi

    read -rp "  绑定地址 (例 0.0.0.0:8080): " remote_addr
    # 简单校验格式 IP:PORT 或 *:PORT
    if ! [[ "$remote_addr" =~ ^[0-9a-zA-Z.*:]+:[0-9]+$ ]]; then
        err "地址格式无效，应为 IP:PORT 格式"
        return 1
    fi

    read -rp "  独立 Token (留空使用默认 Token): " token

    # 追加配置
    {
        echo ""
        echo "[server.services.${svc_name}]"
        echo "bind_addr = \"${remote_addr}\""
        if [[ -n "$token" ]]; then
            echo "token = \"${token}\""
        fi
    } >> "$server_config_file"

    success "隧道 '${svc_name}' 已添加"
}

edit_server_service() {
    list_server_services
    read -rp "  输入要编辑的隧道名称: " svc_name
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    if ! grep -q "\[server\.services\.${svc_name}\]" "$server_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 不存在"
        return 1
    fi
    "${EDITOR:-vi}" "$server_config_file"
    success "配置已保存，建议重启服务以生效"
}

delete_server_service() {
    list_server_services
    read -rp "  输入要删除的隧道名称: " svc_name
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    if ! grep -q "\[server\.services\.${svc_name}\]" "$server_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 不存在"
        return 1
    fi

    # 删除该 [server.services.NAME] 节及其后续属性行（直到下一个 [ 节或文件结尾）
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v name="${svc_name}" '
        BEGIN { skip=0 }
        /^\[server\.services\./ {
            if ($0 ~ "\\[server\\.services\\." name "\\]") {
                skip=1; next
            } else {
                skip=0
            }
        }
        /^\[/ && !/^\[server\.services\./ { skip=0 }
        !skip { print }
    ' "$server_config_file" > "$tmp_file"
    mv "$tmp_file" "$server_config_file"
    success "隧道 '${svc_name}' 已删除"
}

# ────────────────────────────────────────────────────────────
# 配置管理 - 客户端
# ────────────────────────────────────────────────────────────
client_config_file="${CONFIG_DIR}/client.toml"

list_client_services() {
    if [[ ! -f "$client_config_file" ]]; then
        info "客户端配置文件不存在"
        return
    fi
    echo ""
    echo -e "${BOLD}当前客户端隧道列表:${NC}"
    grep -oP '(?<=\[client\.services\.)[^\]]+' "$client_config_file" 2>/dev/null \
        | nl -ba -nrz -w3 | sed 's/^/  /' || info "  (无隧道配置)"
    echo ""
}

add_client_service() {
    mkdir -p "$CONFIG_DIR"

    if [[ ! -f "$client_config_file" ]]; then
        local server_addr default_token
        echo -e "${CYAN}首次配置客户端${NC}"
        read -rp "  服务端地址 (例 1.2.3.4:2333): " server_addr
        if ! [[ "$server_addr" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
            err "地址格式无效"
            return 1
        fi

        read -rp "  默认 Token: " default_token
        if [[ -z "$default_token" ]]; then
            err "Token 不能为空"
            return 1
        fi

        cat > "$client_config_file" <<EOF
# rathole 客户端配置
# 由管理脚本自动生成

[client]
remote_addr = "${server_addr}"
default_token = "${default_token}"

EOF
        chmod 640 "$client_config_file"
        success "创建配置文件: $client_config_file"
    fi

    echo -e "${CYAN}添加客户端隧道${NC}"
    local svc_name local_addr token

    read -rp "  隧道名称 (需与服务端一致): " svc_name
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称只能包含字母、数字、下划线和连字符"
        return 1
    fi

    if grep -q "\[client\.services\.${svc_name}\]" "$client_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 已存在"
        return 1
    fi

    read -rp "  本地转发地址 (例 127.0.0.1:80): " local_addr
    if ! [[ "$local_addr" =~ ^[0-9a-zA-Z._*:-]+:[0-9]+$ ]]; then
        err "地址格式无效"
        return 1
    fi

    read -rp "  独立 Token (留空使用默认 Token): " token

    {
        echo ""
        echo "[client.services.${svc_name}]"
        echo "local_addr = \"${local_addr}\""
        if [[ -n "$token" ]]; then
            echo "token = \"${token}\""
        fi
    } >> "$client_config_file"

    success "隧道 '${svc_name}' 已添加"
}

edit_client_service() {
    list_client_services
    read -rp "  输入要编辑的隧道名称: " svc_name
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    if ! grep -q "\[client\.services\.${svc_name}\]" "$client_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 不存在"
        return 1
    fi
    "${EDITOR:-vi}" "$client_config_file"
    success "配置已保存，建议重启服务以生效"
}

delete_client_service() {
    list_client_services
    read -rp "  输入要删除的隧道名称: " svc_name
    if ! [[ "$svc_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "名称格式无效"
        return 1
    fi
    if ! grep -q "\[client\.services\.${svc_name}\]" "$client_config_file" 2>/dev/null; then
        err "隧道 '${svc_name}' 不存在"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    awk -v name="${svc_name}" '
        BEGIN { skip=0 }
        /^\[client\.services\./ {
            if ($0 ~ "\\[client\\.services\\." name "\\]") {
                skip=1; next
            } else {
                skip=0
            }
        }
        /^\[/ && !/^\[client\.services\./ { skip=0 }
        !skip { print }
    ' "$client_config_file" > "$tmp_file"
    mv "$tmp_file" "$client_config_file"
    success "隧道 '${svc_name}' 已删除"
}

# ────────────────────────────────────────────────────────────
# 状态显示
# ────────────────────────────────────────────────────────────
show_status() {
    detect_init
    title "运行状态"

    local version="N/A"
    if command -v "$BINARY" &>/dev/null; then
        version="$("${INSTALL_DIR}/${BINARY}" --version 2>/dev/null | head -n1 || echo "N/A")"
    fi
    echo -e "  ${BOLD}版本:${NC} ${version}"
    echo ""

    for svc in "$SERVICE_NAME_SERVER" "$SERVICE_NAME_CLIENT"; do
        local label="服务端"
        [[ "$svc" == "$SERVICE_NAME_CLIENT" ]] && label="客户端"

        echo -ne "  ${BOLD}${label}${NC} (${svc}): "
        if svc_is_active "$svc"; then
            echo -e "${GREEN}● 运行中${NC}"
        else
            echo -e "${RED}○ 已停止${NC}"
        fi
    done
    echo ""
}

# ────────────────────────────────────────────────────────────
# 日志查看
# ────────────────────────────────────────────────────────────
show_logs() {
    local role="${1:-}"
    local lines="${2:-50}"

    local log_file
    if [[ "$role" == "server" ]]; then
        log_file="${LOG_DIR}/server.log"
    elif [[ "$role" == "client" ]]; then
        log_file="${LOG_DIR}/client.log"
    else
        echo "1) 服务端日志"
        echo "2) 客户端日志"
        read -rp "  选择 [1/2]: " choice
        case "$choice" in
            1) log_file="${LOG_DIR}/server.log" ;;
            2) log_file="${LOG_DIR}/client.log" ;;
            *) err "无效选择"; return 1 ;;
        esac
    fi

    if [[ ! -f "$log_file" ]]; then
        warn "日志文件不存在: $log_file"
        return
    fi

    echo -e "${DIM}── 显示最近 ${lines} 行 (${log_file}) ──${NC}"
    tail -n "$lines" "$log_file"
    echo ""
    read -rp "  按 f 实时跟踪日志，其他键返回: " follow_choice
    if [[ "$follow_choice" == "f" || "$follow_choice" == "F" ]]; then
        echo -e "${DIM}(Ctrl+C 退出跟踪)${NC}"
        tail -f "$log_file"
    fi
}

# ────────────────────────────────────────────────────────────
# 重启
# ────────────────────────────────────────────────────────────
do_restart() {
    require_root
    detect_init
    title "重启服务"

    echo "1) 重启服务端"
    echo "2) 重启客户端"
    echo "3) 重启全部"
    read -rp "  选择 [1-3]: " choice

    case "$choice" in
        1)
            step "重启服务端..."
            svc_action restart "$SERVICE_NAME_SERVER"
            success "服务端已重启"
            ;;
        2)
            step "重启客户端..."
            svc_action restart "$SERVICE_NAME_CLIENT"
            success "客户端已重启"
            ;;
        3)
            step "重启服务端..."
            svc_action restart "$SERVICE_NAME_SERVER"
            step "重启客户端..."
            svc_action restart "$SERVICE_NAME_CLIENT"
            success "全部已重启"
            ;;
        *)
            err "无效选择"
            ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 启用/禁用服务
# ────────────────────────────────────────────────────────────
manage_service_enable() {
    require_root
    detect_init
    title "服务管理"

    echo "1) 启动并开机自启 - 服务端"
    echo "2) 启动并开机自启 - 客户端"
    echo "3) 停止并取消自启 - 服务端"
    echo "4) 停止并取消自启 - 客户端"
    echo "5) 仅启动服务端"
    echo "6) 仅启动客户端"
    echo "7) 仅停止服务端"
    echo "8) 仅停止客户端"
    read -rp "  选择 [1-8]: " choice

    case "$choice" in
        1) svc_action enable "$SERVICE_NAME_SERVER"; success "服务端已启用" ;;
        2) svc_action enable "$SERVICE_NAME_CLIENT"; success "客户端已启用" ;;
        3) svc_action disable "$SERVICE_NAME_SERVER"; success "服务端已禁用" ;;
        4) svc_action disable "$SERVICE_NAME_CLIENT"; success "客户端已禁用" ;;
        5) svc_action start "$SERVICE_NAME_SERVER"; success "服务端已启动" ;;
        6) svc_action start "$SERVICE_NAME_CLIENT"; success "客户端已启动" ;;
        7) svc_action stop "$SERVICE_NAME_SERVER"; success "服务端已停止" ;;
        8) svc_action stop "$SERVICE_NAME_CLIENT"; success "客户端已停止" ;;
        *) err "无效选择" ;;
    esac
}

# ────────────────────────────────────────────────────────────
# 卸载
# ────────────────────────────────────────────────────────────
do_uninstall() {
    require_root
    detect_init
    title "卸载 rathole"

    warn "此操作将删除 rathole 二进制、服务和日志"
    read -rp "  确认卸载？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消"
        return
    fi

    read -rp "  是否同时删除配置文件？[y/N]: " del_config

    # 停止并卸载服务
    for svc in "$SERVICE_NAME_SERVER" "$SERVICE_NAME_CLIENT"; do
        step "停止服务: $svc"
        case "$INIT_SYSTEM" in
            systemd)
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "/etc/systemd/system/${svc}.service"
                ;;
            openrc)
                rc-service "$svc" stop 2>/dev/null || true
                rc-update del "$svc" default 2>/dev/null || true
                rm -f "/etc/init.d/${svc}"
                ;;
        esac
    done

    [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload

    # 删除二进制
    rm -f "${INSTALL_DIR}/${BINARY}"
    success "已删除二进制文件"

    # 删除日志
    rm -rf "$LOG_DIR"
    success "已删除日志目录"

    # 可选删除配置
    if [[ "$del_config" == "y" || "$del_config" == "Y" ]]; then
        rm -rf "$CONFIG_DIR"
        success "已删除配置目录"
    else
        info "配置文件保留在: ${CONFIG_DIR}"
    fi

    success "rathole 已成功卸载"
}

# ────────────────────────────────────────────────────────────
# 配置管理菜单
# ────────────────────────────────────────────────────────────
menu_server_config() {
    require_root
    while true; do
        title "服务端配置管理"
        list_server_services
        echo "1) 添加隧道"
        echo "2) 编辑隧道"
        echo "3) 删除隧道"
        echo "4) 直接编辑配置文件"
        echo "5) 查看配置文件"
        echo "0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-5]: " choice
        case "$choice" in
            1) add_server_service ;;
            2) edit_server_service ;;
            3) delete_server_service ;;
            4) "${EDITOR:-vi}" "$server_config_file" ;;
            5)
                if [[ -f "$server_config_file" ]]; then
                    echo ""
                    cat "$server_config_file"
                    echo ""
                else
                    warn "配置文件不存在"
                fi
                ;;
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
        list_client_services
        echo "1) 添加隧道"
        echo "2) 编辑隧道"
        echo "3) 删除隧道"
        echo "4) 直接编辑配置文件"
        echo "5) 查看配置文件"
        echo "0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-5]: " choice
        case "$choice" in
            1) add_client_service ;;
            2) edit_client_service ;;
            3) delete_client_service ;;
            4) "${EDITOR:-vi}" "$client_config_file" ;;
            5)
                if [[ -f "$client_config_file" ]]; then
                    echo ""
                    cat "$client_config_file"
                    echo ""
                else
                    warn "配置文件不存在"
                fi
                ;;
            0) return ;;
            *) err "无效选择" ;;
        esac
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ────────────────────────────────────────────────────────────
# 主菜单
# ────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ██████╗  █████╗ ████████╗██╗  ██╗ ██████╗ ██╗     ███████╗"
        echo "  ██╔══██╗██╔══██╗╚══██╔══╝██║  ██║██╔═══██╗██║     ██╔════╝"
        echo "  ██████╔╝███████║   ██║   ███████║██║   ██║██║     █████╗  "
        echo "  ██╔══██╗██╔══██║   ██║   ██╔══██║██║   ██║██║     ██╔══╝  "
        echo "  ██║  ██║██║  ██║   ██║   ██║  ██║╚██████╔╝███████╗███████╗"
        echo "  ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝"
        echo -e "${NC}"
        echo -e "  ${DIM}rathole 管理脚本 v${SCRIPT_VERSION}${NC}"
        echo ""

        show_status

        echo -e "  ${BOLD}── 安装 ──────────────────────────────${NC}"
        echo "  1) 安装 / 更新 rathole"
        echo ""
        echo -e "  ${BOLD}── 配置管理 ──────────────────────────${NC}"
        echo "  2) 服务端配置管理"
        echo "  3) 客户端配置管理"
        echo ""
        echo -e "  ${BOLD}── 服务控制 ──────────────────────────${NC}"
        echo "  4) 启动 / 停止 / 开机自启"
        echo "  5) 重启服务"
        echo ""
        echo -e "  ${BOLD}── 监控 ──────────────────────────────${NC}"
        echo "  6) 查看日志"
        echo ""
        echo -e "  ${BOLD}── 其他 ──────────────────────────────${NC}"
        echo "  7) 卸载 rathole"
        echo "  0) 退出"
        echo ""
        read -rp "  请选择 [0-7]: " choice

        case "$choice" in
            1) do_install ;;
            2) menu_server_config ;;
            3) menu_client_config ;;
            4) manage_service_enable ;;
            5) do_restart ;;
            6) show_logs ;;
            7) do_uninstall ;;
            0)
                echo ""
                info "再见！"
                exit 0
                ;;
            *)
                err "无效选择，请重试"
                ;;
        esac

        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ────────────────────────────────────────────────────────────
# 入口
# ────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    detect_os
    detect_arch
    detect_init
    main_menu
}

main "$@"
