#!/bin/sh

set -eu

APP_NAME="gost-manager"
BASE_DIR="/etc/${APP_NAME}"
DB_FILE="${BASE_DIR}/forwards.db"
GOST_BIN="/usr/local/bin/gost"

info()  { printf "[INFO] %s\n" "$*"; }
ok()    { printf "[OK]   %s\n" "$*"; }
warn()  { printf "[WARN] %s\n" "$*"; }
err()   { printf "[ERR]  %s\n" "$*" >&2; }

pause() {
    printf "\n按回车继续..."
    read dummy
}

clear_screen() {
    command -v clear >/dev/null 2>&1 && clear || printf "\n"
}

require_root() {
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 运行此脚本"
        exit 1
    fi
}

detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY="alpine"
        INIT_SYSTEM="openrc"
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY="debian"
        INIT_SYSTEM="systemd"
    else
        err "暂不支持当前系统，仅支持 Alpine / Debian"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "${BASE_DIR}"
    touch "${DB_FILE}"
    mkdir -p "/var/log/${APP_NAME}"
}

install_deps() {
    if [ "${OS_FAMILY}" = "alpine" ]; then
        apk add --no-cache bash curl tar gzip >/dev/null
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null
        apt-get install -y bash curl tar gzip >/dev/null
    fi
}

install_gost() {
    info "未检测到 gost，开始安装最新版本..."
    install_deps

    if ! curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh | bash -s -- --install; then
        err "gost 安装失败"
        exit 1
    fi

    if command -v gost >/dev/null 2>&1; then
        GOST_BIN="$(command -v gost)"
    elif [ -x /usr/local/bin/gost ]; then
        GOST_BIN="/usr/local/bin/gost"
    elif [ -x /usr/bin/gost ]; then
        GOST_BIN="/usr/bin/gost"
    else
        err "安装完成，但未找到 gost 可执行文件"
        exit 1
    fi

    ok "gost 安装成功：${GOST_BIN}"
}

resolve_gost_bin() {
    if command -v gost >/dev/null 2>&1; then
        GOST_BIN="$(command -v gost)"
    elif [ -x /usr/local/bin/gost ]; then
        GOST_BIN="/usr/local/bin/gost"
    elif [ -x /usr/bin/gost ]; then
        GOST_BIN="/usr/bin/gost"
    else
        install_gost
    fi
}

service_name_by_id() {
    echo "gost-forward-$1"
}

next_id() {
    if [ ! -s "${DB_FILE}" ]; then
        echo 1
        return
    fi
    awk -F'|' 'BEGIN{max=0} $1+0>max{max=$1+0} END{print max+1}' "${DB_FILE}"
}

is_valid_spec() {
    spec="$1"
    case "${spec}" in
        tcp://:*/*:*|udp://:*/*:*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

parse_spec_proto() {
    echo "$1" | cut -d':' -f1
}

parse_spec_listen_port() {
    echo "$1" | sed -n 's#^[a-z]\+://:\([0-9]\+\)/.*#\1#p'
}

check_port_used() {
    proto="$1"
    port="$2"

    if command -v ss >/dev/null 2>&1; then
        if [ "${proto}" = "tcp" ]; then
            ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
        else
            ss -lnu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
        fi
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        if [ "${proto}" = "tcp" ]; then
            netstat -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
        else
            netstat -lnu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
        fi
        return $?
    fi

    return 1
}

service_status() {
    svc="$1"

    if [ "${INIT_SYSTEM}" = "openrc" ]; then
        if rc-service "${svc}" status >/dev/null 2>&1; then
            echo "Running"
        else
            echo "Stopped"
        fi
    else
        if systemctl is-active --quiet "${svc}.service"; then
            echo "Running"
        else
            echo "Stopped"
        fi
    fi
}

service_enabled() {
    svc="$1"

    if [ "${INIT_SYSTEM}" = "openrc" ]; then
        if [ -L "/etc/runlevels/default/${svc}" ] || [ -e "/etc/runlevels/default/${svc}" ]; then
            echo "Enabled"
        else
            echo "Disabled"
        fi
    else
        if systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
            echo "Enabled"
        else
            echo "Disabled"
        fi
    fi
}

create_openrc_service() {
    id="$1"
    spec="$2"
    svc="$(service_name_by_id "${id}")"
    init_file="/etc/init.d/${svc}"

    cat > "${init_file}" <<EOF
#!/sbin/openrc-run

description="GOST forward ${svc}"
command="${GOST_BIN}"
command_args="-L ${spec}"
command_background="yes"
pidfile="/run/${svc}.pid"
output_log="/var/log/${APP_NAME}/${svc}.log"
error_log="/var/log/${APP_NAME}/${svc}.err"

depend() {
    need net
}

start_pre() {
    checkpath -d -m 0755 /run
    checkpath -d -m 0755 /var/log/${APP_NAME}
}
EOF

    chmod +x "${init_file}"
    rc-update add "${svc}" default >/dev/null 2>&1 || true
    rc-service "${svc}" restart >/dev/null 2>&1 || rc-service "${svc}" start >/dev/null 2>&1

    if [ ! -e "/etc/runlevels/default/${svc}" ]; then
        err "服务创建成功，但加入开机自启失败：${svc}"
        exit 1
    fi
}

create_systemd_service() {
    id="$1"
    spec="$2"
    svc="$(service_name_by_id "${id}")"
    unit_file="/etc/systemd/system/${svc}.service"

    cat > "${unit_file}" <<EOF
[Unit]
Description=GOST forward ${svc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -L ${spec}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${svc}.service" >/dev/null 2>&1

    if ! systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
        err "服务创建成功，但加入开机自启失败：${svc}"
        exit 1
    fi
}

create_forward() {
    spec="$1"

    if ! is_valid_spec "${spec}"; then
        err "转发格式错误"
        echo "示例：tcp://:1234/1.1.1.1:1234"
        exit 1
    fi

    if awk -F'|' -v s="${spec}" '$2==s {found=1} END{exit !found}' "${DB_FILE}"; then
        warn "该转发已存在：${spec}"
        exit 0
    fi

    proto="$(parse_spec_proto "${spec}")"
    listen_port="$(parse_spec_listen_port "${spec}")"

    if [ -z "${listen_port}" ]; then
        err "无法解析监听端口"
        exit 1
    fi

    if check_port_used "${proto}" "${listen_port}"; then
        err "监听端口已被占用：${proto} ${listen_port}"
        exit 1
    fi

    resolve_gost_bin

    id="$(next_id)"
    svc="$(service_name_by_id "${id}")"

    if [ "${INIT_SYSTEM}" = "openrc" ]; then
        create_openrc_service "${id}" "${spec}"
    else
        create_systemd_service "${id}" "${spec}"
    fi

    echo "${id}|${spec}|${svc}" >> "${DB_FILE}"

    ok "创建成功：${spec}"
    ok "服务名：${svc}"
    ok "开机自启：$(service_enabled "${svc}")"
}

delete_openrc_service() {
    svc="$1"
    rc-service "${svc}" stop >/dev/null 2>&1 || true
    rc-update del "${svc}" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${svc}"
    rm -f "/var/log/${APP_NAME}/${svc}.log" "/var/log/${APP_NAME}/${svc}.err"
}

delete_systemd_service() {
    svc="$1"
    systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service"
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true
    rm -f "/var/log/${APP_NAME}/${svc}.log" "/var/log/${APP_NAME}/${svc}.err"
}

delete_forward_by_id() {
    id="$1"

    if ! awk -F'|' -v target="${id}" '$1==target {found=1} END{exit !found}' "${DB_FILE}"; then
        err "未找到编号：${id}"
        exit 1
    fi

    svc="$(awk -F'|' -v target="${id}" '$1==target {print $3}' "${DB_FILE}")"
    spec="$(awk -F'|' -v target="${id}" '$1==target {print $2}' "${DB_FILE}")"

    if [ "${INIT_SYSTEM}" = "openrc" ]; then
        delete_openrc_service "${svc}"
    else
        delete_systemd_service "${svc}"
    fi

    awk -F'|' -v target="${id}" '$1!=target' "${DB_FILE}" > "${DB_FILE}.tmp"
    mv "${DB_FILE}.tmp" "${DB_FILE}"

    ok "已删除：${spec}"
}

uninstall_all() {
    clear_screen
    printf "%s一键卸载%s\n\n" "$C_BOLD" "$C_RESET"
    echo "此操作将会："
    echo "1. 删除所有已创建的转发"
    echo "2. 删除所有开机自启服务"
    echo "3. 删除日志与管理文件"
    echo "4. 删除 gost 可执行文件"
    echo
    printf "是否继续？(Y/n): "
    read ans

    case "${ans:-Y}" in
        Y|y|"")
            ;;
        *)
            warn "已取消"
            return
            ;;
    esac

    if [ -s "${DB_FILE}" ]; then
        while IFS='|' read -r id spec svc; do
            [ -n "${id}" ] || continue
            if [ "${INIT_SYSTEM}" = "openrc" ]; then
                delete_openrc_service "${svc}"
            else
                delete_systemd_service "${svc}"
            fi
        done < "${DB_FILE}"
    fi

    rm -rf "${BASE_DIR}"
    rm -rf "/var/log/${APP_NAME}"
    rm -f /usr/local/bin/gost /usr/bin/gost

    if [ "${OS_FAMILY}" = "alpine" ]; then
        apk del gost >/dev/null 2>&1 || true
    else
        apt-get remove -y gost >/dev/null 2>&1 || true
        apt-get purge -y gost >/dev/null 2>&1 || true
    fi

    ok "已完成卸载"
    exit 0
}

show_header() {
    echo "系统类型：${OS_FAMILY} (${INIT_SYSTEM})"

    if command -v gost >/dev/null 2>&1; then
        echo "GOST路径：$(command -v gost)"
        echo "GOST版本：$(gost -V 2>/dev/null || echo 未知)"
    elif [ -x /usr/local/bin/gost ]; then
        echo "GOST路径：/usr/local/bin/gost"
        echo "GOST版本：$(/usr/local/bin/gost -V 2>/dev/null || echo 未知)"
    else
        echo "GOST状态：${C_RED}未安装${C_RESET}"
    fi
    echo
}

show_forwards_table() {
    if [ ! -s "${DB_FILE}" ]; then
        echo "当前没有已创建的转发"
        return
    fi

    printf "%-4s %-22s %-8s %-8s %s\n" "ID" "SERVICE" "STATUS" "AUTO" "RULE"
    printf "%-4s %-22s %-8s %-8s %s\n" "----" "----------------------" "--------" "--------" "------------------------------"

    while IFS='|' read -r id spec svc; do
        [ -n "${id}" ] || continue
        status="$(service_status "${svc}")"
        enabled="$(service_enabled "${svc}")"
        printf "%-4s %-22s %-8s %-8s %s\n" "${id}" "${svc}" "${status}" "${enabled}" "${spec}"
    done < "${DB_FILE}"
}

show_menu() {
    echo
    echo "1) 添加转发"
    echo "2) 删除转发"
    echo "3) 查看日志"
    echo "4) 重启指定转发"
    echo "5) 一键卸载"
    echo "0) 退出"
    echo
    printf "请选择："
}

add_menu() {
    clear_screen
    echo "添加转发"
    echo
    echo "请输入转发规则，例如："
    echo "tcp://:1234/1.1.1.1:1234"
    echo "udp://:1234/1.1.1.1:1234"
    echo
    printf "请输入："
    read spec

    [ -n "${spec}" ] || { warn "未输入内容"; return; }
    create_forward "${spec}"
}

delete_menu() {
    clear_screen
    echo "删除转发"
    echo
    show_forwards_table
    echo
    printf "请输入要删除的编号："
    read id
    [ -n "${id}" ] || { warn "未输入编号"; return; }
    delete_forward_by_id "${id}"
}

show_logs_menu() {
    clear_screen
    echo "查看日志"
    echo
    show_forwards_table
    echo
    printf "请输入编号："
    read id
    [ -n "${id}" ] || { warn "未输入编号"; return; }

    svc="$(awk -F'|' -v target="${id}" '$1==target {print $3}' "${DB_FILE}")"
    if [ -z "${svc:-}" ]; then
        err "未找到编号：${id}"
        return
    fi

    log_file="/var/log/${APP_NAME}/${svc}.log"
    err_file="/var/log/${APP_NAME}/${svc}.err"

    echo
    echo "1) 查看标准日志"
    echo "2) 查看错误日志"
    printf "请选择："
    read c

    case "${c}" in
        1)
            [ -f "${log_file}" ] && tail -n 50 "${log_file}" || warn "日志文件不存在"
            ;;
        2)
            [ -f "${err_file}" ] && tail -n 50 "${err_file}" || warn "错误日志文件不存在"
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

restart_menu() {
    clear_screen
    echo "重启转发"
    echo
    show_forwards_table
    echo
    printf "请输入编号："
    read id
    [ -n "${id}" ] || { warn "未输入编号"; return; }

    svc="$(awk -F'|' -v target="${id}" '$1==target {print $3}' "${DB_FILE}")"
    if [ -z "${svc:-}" ]; then
        err "未找到编号：${id}"
        return
    fi

    if [ "${INIT_SYSTEM}" = "openrc" ]; then
        rc-service "${svc}" restart
    else
        systemctl restart "${svc}.service"
    fi

    ok "已重启：${svc}"
}

interactive_menu() {
    while :; do
        clear_screen
        show_header
        show_forwards_table
        show_menu
        read choice

        case "${choice}" in
            1) add_menu; pause ;;
            2) delete_menu; pause ;;
            3) show_logs_menu; pause ;;
            4) restart_menu; pause ;;
            5) uninstall_all ;;
            0) exit 0 ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

main() {
    require_root
    detect_system
    ensure_dirs

    if [ "${1:-}" != "" ]; then
        create_forward "$1"
        exit 0
    fi

    interactive_menu
}

main "$@"