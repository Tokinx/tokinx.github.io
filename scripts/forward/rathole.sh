#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_OWNER="rathole-org"
REPO_NAME="rathole"
GITHUB_API_LATEST="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
GITHUB_RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download"
INSTALL_BIN="/usr/local/bin/rathole"
CONFIG_ROOT="/etc/rathole"
SERVER_DIR="${CONFIG_ROOT}/server"
CLIENT_DIR="${CONFIG_ROOT}/client"
SYSTEMD_DIR="/etc/systemd/system"
SERVER_UNIT_TEMPLATE="${SYSTEMD_DIR}/ratholes@.service"
CLIENT_UNIT_TEMPLATE="${SYSTEMD_DIR}/ratholec@.service"
CDN_PREFIX=""
LATEST_VERSION=""
ARCH_ASSET=""
TMP_DIR=""

info() {
	printf '[INFO] %s\n' "$*"
}

warn() {
	printf '[WARN] %s\n' "$*" >&2
}

error() {
	printf '[ERROR] %s\n' "$*" >&2
}

die() {
	error "$1"
	exit 1
}

success() {
	printf '[OK] %s\n' "$*"
}

cleanup() {
	if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
		rm -rf "${TMP_DIR}"
	fi
}

trap cleanup EXIT INT TERM

has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"
}

require_systemd() {
	has_cmd systemctl || die "当前系统未安装 systemctl，无法管理 rathole 服务"
	[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] || die "当前系统未运行 systemd，无法管理 rathole 服务"
}

trim_value() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

toml_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

validate_name() {
	local name="$1"
	[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

normalize_cdn_prefix() {
	local cdn="$1"
	case "$cdn" in
		http://*|https://*)
			CDN_PREFIX="${cdn%/}"
			;;
		*)
			die "--cdn 需要以 http:// 或 https:// 开头"
			;;
	esac
}

apply_cdn_prefix() {
	local url="$1"
	if [ -n "${CDN_PREFIX}" ]; then
		printf '%s/%s' "${CDN_PREFIX}" "${url}"
	else
		printf '%s' "${url}"
	fi
}

prompt_value() {
	local label="$1"
	local default_value="$2"
	local out_var="$3"
	local value=""

	while true; do
		if [ -n "${default_value}" ]; then
			read -r -p "${label} [${default_value}]: " value || true
		else
			read -r -p "${label}: " value || true
		fi

		value="$(trim_value "${value:-${default_value}}")"

		if [ -n "${value}" ] || [ -n "${default_value}" ]; then
			printf -v "${out_var}" '%s' "${value}"
			return 0
		fi

		warn "该项不能为空"
	done
}

prompt_name() {
	local label="$1"
	local default_value="$2"
	local out_var="$3"
	local value=""

	while true; do
		prompt_value "${label}" "${default_value}" value
		if validate_name "${value}"; then
			printf -v "${out_var}" '%s' "${value}"
			return 0
		fi
		warn "名称只能包含字母、数字、下划线和连字符，且必须以字母或数字开头"
	done
}

prompt_port() {
	local label="$1"
	local default_value="$2"
	local out_var="$3"
	local value=""

	while true; do
		prompt_value "${label}" "${default_value}" value
		if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
			printf -v "${out_var}" '%s' "${value}"
			return 0
		fi
		warn "端口必须是 1 到 65535 之间的数字"
	done
}

confirm() {
	local prompt_text="$1"
	local answer=""
	read -r -p "${prompt_text} [y/N]: " answer || true
	case "${answer}" in
		y|Y|yes|YES)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

generate_token() {
	if [ -r /proc/sys/kernel/random/uuid ]; then
		tr -d '-' < /proc/sys/kernel/random/uuid
		return 0
	fi

	if has_cmd openssl; then
		openssl rand -hex 16
		return 0
	fi

	date +%s%N
}

kind_dir() {
	case "$1" in
		server)
			printf '%s' "${SERVER_DIR}"
			;;
		client)
			printf '%s' "${CLIENT_DIR}"
			;;
		*)
			die "未知类型: $1"
			;;
	esac
}

kind_label() {
	case "$1" in
		server)
			printf '服务端'
			;;
		client)
			printf '客户端'
			;;
		*)
			printf '%s' "$1"
			;;
	esac
}

config_path() {
	local kind="$1"
	local name="$2"
	printf '%s/%s.toml' "$(kind_dir "${kind}")" "${name}"
}

unit_name() {
	local kind="$1"
	local name="$2"
	case "$kind" in
		server)
			printf 'ratholes@%s.service' "${name}"
			;;
		client)
			printf 'ratholec@%s.service' "${name}"
			;;
		*)
			die "未知类型: $1"
			;;
	esac
}

service_stack_ready() {
	[ -x "${INSTALL_BIN}" ] && [ -f "${SERVER_UNIT_TEMPLATE}" ] && [ -f "${CLIENT_UNIT_TEMPLATE}" ]
}

unit_active_state() {
	systemctl is-active "$1" 2>/dev/null || true
}

unit_enabled_state() {
	systemctl is-enabled "$1" 2>/dev/null || true
}

unit_load_state() {
	systemctl show -p LoadState --value "$1" 2>/dev/null || true
}

ensure_packages() {
	local -a packages=("$@")

	if ((${#packages[@]} == 0)); then
		return 0
	fi

	if has_cmd apt-get; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get install -y "${packages[@]}"
	elif has_cmd dnf; then
		dnf install -y "${packages[@]}"
	elif has_cmd yum; then
		yum install -y "${packages[@]}"
	elif has_cmd apk; then
		apk add --no-cache "${packages[@]}"
	else
		die "缺少 curl 或 unzip，且未找到可用的包管理器，请手动安装后重试"
	fi
}

ensure_download_tools() {
	local -a missing=()
	has_cmd curl || missing+=(curl)
	has_cmd unzip || missing+=(unzip)
	if ((${#missing[@]} > 0)); then
		info "检测到缺少基础工具，正在安装: ${missing[*]}"
		ensure_packages "${missing[@]}"
	fi
}

detect_arch_asset() {
	local machine
	machine="$(uname -m)"

	case "${machine}" in
		x86_64|amd64)
			ARCH_ASSET="rathole-x86_64-unknown-linux-gnu.zip"
			;;
		aarch64|arm64)
			ARCH_ASSET="rathole-aarch64-unknown-linux-musl.zip"
			;;
		armv7l|armv7|armhf)
			ARCH_ASSET="rathole-armv7-unknown-linux-musleabihf.zip"
			;;
		armv6l|armv6|arm*)
			warn "检测到 ARM 架构 ${machine}，将尝试使用通用 hard-float 包"
			ARCH_ASSET="rathole-arm-unknown-linux-musleabihf.zip"
			;;
		*)
			die "暂不支持当前架构: ${machine}"
			;;
	esac

	info "检测到系统架构: ${machine}"
	info "对应安装包: ${ARCH_ASSET}"
}

fetch_release_json() {
	local json=""

	if [ -n "${CDN_PREFIX}" ]; then
		json="$(curl -fsSL --retry 3 --connect-timeout 10 "$(apply_cdn_prefix "${GITHUB_API_LATEST}")" 2>/dev/null || true)"
		if printf '%s' "${json}" | grep -q '"tag_name"'; then
			printf '%s' "${json}"
			return 0
		fi
		warn "CDN 获取 release 信息失败，回退直连 GitHub API"
	fi

	curl -fsSL --retry 3 --connect-timeout 10 "${GITHUB_API_LATEST}"
}

fetch_latest_version() {
	if [ -n "${RATHOLE_VERSION:-}" ] && [ "${RATHOLE_VERSION}" != "latest" ]; then
		case "${RATHOLE_VERSION}" in
			v*)
				LATEST_VERSION="${RATHOLE_VERSION}"
				;;
			*)
				LATEST_VERSION="v${RATHOLE_VERSION}"
				;;
		esac
		info "使用指定版本: ${LATEST_VERSION}"
		return 0
	fi

	local json=""
	local version=""

	json="$(fetch_release_json)"
	version="$(printf '%s' "${json}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

	[ -n "${version}" ] || die "无法获取 rathole 最新版本号"

	LATEST_VERSION="${version}"
	info "获取到最新版本: ${LATEST_VERSION}"
}

download_archive() {
	local url="$1"
	local dest="$2"
	local prefixed_url=""

	if [ -n "${CDN_PREFIX}" ]; then
		prefixed_url="$(apply_cdn_prefix "${url}")"
		if curl -fL --retry 3 --connect-timeout 10 -o "${dest}" "${prefixed_url}"; then
			if unzip -tq "${dest}" >/dev/null 2>&1; then
				return 0
			fi
			warn "CDN 返回的内容不是有效压缩包，回退直连下载"
		else
			warn "CDN 下载失败，回退直连下载"
		fi
		rm -f "${dest}"
	fi

	curl -fL --retry 3 --connect-timeout 10 -o "${dest}" "${url}"
	unzip -tq "${dest}" >/dev/null 2>&1 || die "下载包损坏: ${url}"
}

write_systemd_templates() {
	cat > "${SERVER_UNIT_TEMPLATE}" <<EOF
[Unit]
Description=Rathole Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=${INSTALL_BIN} -s ${SERVER_DIR}/%i.toml

[Install]
WantedBy=multi-user.target
EOF

	cat > "${CLIENT_UNIT_TEMPLATE}" <<EOF
[Unit]
Description=Rathole Client Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=${INSTALL_BIN} -c ${CLIENT_DIR}/%i.toml

[Install]
WantedBy=multi-user.target
EOF

	chmod 644 "${SERVER_UNIT_TEMPLATE}" "${CLIENT_UNIT_TEMPLATE}"
}

prepare_install_dirs() {
	mkdir -p "${CONFIG_ROOT}" "${SERVER_DIR}" "${CLIENT_DIR}"
	chmod 755 "${CONFIG_ROOT}" "${SERVER_DIR}" "${CLIENT_DIR}" 2>/dev/null || true
}

install_rathole() {
	require_root
	require_systemd
	ensure_download_tools
	detect_arch_asset
	fetch_latest_version
	prepare_install_dirs
	write_systemd_templates

	TMP_DIR="$(mktemp -d)"
	local archive="${TMP_DIR}/${ARCH_ASSET}"
	local extract_dir="${TMP_DIR}/extract"
	local download_url="${GITHUB_RELEASE_BASE}/${LATEST_VERSION}/${ARCH_ASSET}"

	mkdir -p "${extract_dir}"

	info "开始下载 rathole ${LATEST_VERSION}"
	download_archive "${download_url}" "${archive}"

	unzip -oq "${archive}" -d "${extract_dir}"

	local binary_path=""
	binary_path="$(find "${extract_dir}" -type f -name rathole | head -n 1)"
	[ -n "${binary_path}" ] || die "压缩包中未找到 rathole 可执行文件"

	install -m 755 "${binary_path}" "${INSTALL_BIN}"
	systemctl daemon-reload

	success "rathole ${LATEST_VERSION} 安装完成"
	info "二进制路径: ${INSTALL_BIN}"
	info "服务模板: ${SERVER_UNIT_TEMPLATE} 和 ${CLIENT_UNIT_TEMPLATE}"
	info "配置目录: ${SERVER_DIR} 和 ${CLIENT_DIR}"
}

ensure_service_stack() {
	if service_stack_ready; then
		return 0
	fi
	install_rathole
}

require_service_stack() {
	service_stack_ready || die "rathole 尚未安装，请先执行 install"
}

collect_kind_names() {
	local dir="$1"
	local file=""
	local name=""

	for file in "${dir}"/*.toml; do
		[ -e "${file}" ] || continue
		name="$(basename "${file}" .toml)"
		printf '%s\n' "${name}"
	done
}

config_exists() {
	[ -f "$(config_path "$1" "$2")" ]
}

choose_kind_name() {
	local kind="$1"
	local dir
	local -a names=()
	local index=1
	local choice=""

	dir="$(kind_dir "${kind}")"
	mapfile -t names < <(collect_kind_names "${dir}")

	if ((${#names[@]} == 0)); then
		die "${kind_label "${kind}"} 暂无配置"
	fi

	if ((${#names[@]} == 1)); then
		printf '%s\n' "${names[0]}"
		return 0
	fi

	info "请选择 ${kind_label "${kind}"} 配置"
	for name in "${names[@]}"; do
		printf '  %d) %s\n' "${index}" "${name}"
		index=$((index + 1))
	done

	while true; do
		read -r -p "请输入序号: " choice || true
		if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
			printf '%s\n' "${names[$((choice - 1))]}"
			return 0
		fi
		warn "无效选择"
	done
}

list_kind_summary() {
	local kind="$1"
	local dir
	local -a names=()
	local name=""
	local unit=""
	local file=""
	local active=""
	local enabled=""

	dir="$(kind_dir "${kind}")"
	mapfile -t names < <(collect_kind_names "${dir}")

	if ((${#names[@]} == 0)); then
		info "${kind_label "${kind}"} 暂无配置"
		return 0
	fi

	printf '%-8s %-24s %-12s %-12s %s\n' "TYPE" "NAME" "ACTIVE" "ENABLED" "CONFIG"

	for name in "${names[@]}"; do
		unit="$(unit_name "${kind}" "${name}")"
		file="$(config_path "${kind}" "${name}")"

		active="$(unit_active_state "${unit}")"
		enabled="$(unit_enabled_state "${unit}")"

		printf '%-8s %-24s %-12s %-12s %s\n' "${kind}" "${name}" "${active:-unknown}" "${enabled:-unknown}" "${file}"
	done
}

show_binary_status() {
	if [ -x "${INSTALL_BIN}" ]; then
		local version_text=""
		version_text="$("${INSTALL_BIN}" --version 2>/dev/null || true)"
		if [ -n "${version_text}" ]; then
			info "当前版本: ${version_text}"
		else
			info "rathole 已安装: ${INSTALL_BIN}"
		fi
	else
		warn "rathole 尚未安装"
	fi
}

show_global_status() {
	local target="${1:-}"

	show_binary_status
	printf '\n'

	if [ -z "${target}" ] || [ "${target}" = "all" ]; then
		list_kind_summary server
		printf '\n'
		list_kind_summary client
		return 0
	fi

	show_target_status "${target}"
}

show_target_status() {
	local target="$1"
	local -a matches=()
	local kind=""
	local unit=""
	local file=""
	local active=""
	local enabled=""

	if [ -f "$(config_path server "${target}")" ]; then
		matches+=("server")
	fi
	if [ -f "$(config_path client "${target}")" ]; then
		matches+=("client")
	fi

	if ((${#matches[@]} == 0)); then
		die "未找到配置: ${target}"
	fi

	for kind in "${matches[@]}"; do
		unit="$(unit_name "${kind}" "${target}")"
		file="$(config_path "${kind}" "${target}")"
		active="$(unit_active_state "${unit}")"
		enabled="$(unit_enabled_state "${unit}")"
		printf '%-8s %-24s %-12s %-12s %s\n' "${kind}" "${target}" "${active:-unknown}" "${enabled:-unknown}" "${file}"
		if [ "$(unit_load_state "${unit}")" = "loaded" ]; then
			systemctl status --no-pager --full "${unit}"
		else
			warn "系统中未加载单元: ${unit}"
		fi
		printf '\n'
	done
}

collect_matching_units() {
	local target="${1:-}"
	local -a units=()
	local kind=""
	local name=""
	local dir=""
	local file=""

	if [ -z "${target}" ] || [ "${target}" = "all" ]; then
		for kind in server client; do
			dir="$(kind_dir "${kind}")"
			for file in "${dir}"/*.toml; do
				[ -e "${file}" ] || continue
				name="$(basename "${file}" .toml)"
				units+=("$(unit_name "${kind}" "${name}")")
			done
		done
	else
		if [ -f "$(config_path server "${target}")" ]; then
			units+=("$(unit_name server "${target}")")
		fi
		if [ -f "$(config_path client "${target}")" ]; then
			units+=("$(unit_name client "${target}")")
		fi
	fi

	if ((${#units[@]} == 0)); then
		return 1
	fi

	printf '%s\n' "${units[@]}"
}

restart_units() {
	local target="${1:-}"
	local -a units=()
	local unit=""

	require_service_stack

	mapfile -t units < <(collect_matching_units "${target}" ) || true
	if ((${#units[@]} == 0)); then
		die "未找到可重启的配置"
	fi

	for unit in "${units[@]}"; do
		systemctl restart "${unit}"
		success "已重启: ${unit}"
	done
}

show_logs() {
	local target="${1:-}"
	local -a units=()
	local journal_args=()
	local unit=""

	require_service_stack

	mapfile -t units < <(collect_matching_units "${target}") || true
	if ((${#units[@]} == 0)); then
		die "未找到可查看日志的配置"
	fi

	for unit in "${units[@]}"; do
		journal_args+=("-u" "${unit}")
	done

	journalctl "${journal_args[@]}" -n 100 --no-pager
}

write_server_config() {
	local name="$1"
	local service_name="$2"
	local listen_port="$3"
	local expose_port="$4"
	local token="$5"
	local file

	file="$(config_path server "${name}")"

	cat > "${file}" <<EOF
# 由 rathole 管理脚本生成
[server]
bind_addr = "0.0.0.0:${listen_port}"
default_token = "$(toml_escape "${token}")"

[server.services.${service_name}]
bind_addr = "0.0.0.0:${expose_port}"
EOF

	chmod 600 "${file}"
}

write_client_config() {
	local name="$1"
	local service_name="$2"
	local remote_addr="$3"
	local local_addr="$4"
	local token="$5"
	local file

	file="$(config_path client "${name}")"

	cat > "${file}" <<EOF
# 由 rathole 管理脚本生成
[client]
remote_addr = "$(toml_escape "${remote_addr}")"
default_token = "$(toml_escape "${token}")"

[client.services.${service_name}]
local_addr = "$(toml_escape "${local_addr}")"
EOF

	chmod 600 "${file}"
}

create_config() {
	local kind="$1"
	local default_name="$2"
	local name=""
	local service_name=""
	local token=""
	local file=""

	ensure_service_stack

	prompt_name "配置文件名" "${default_name}" name
	file="$(config_path "${kind}" "${name}")"

	[ ! -e "${file}" ] || die "配置已存在: ${file}，请先编辑或删除后重试"

	prompt_name "服务名" "${name}" service_name
	token="$(generate_token)"
	prompt_value "token" "${token}" token

	case "${kind}" in
		server)
			local listen_port=""
			local expose_port=""
			prompt_port "rathole 监听端口" "2333" listen_port
			prompt_port "对外暴露端口" "5202" expose_port
			write_server_config "${name}" "${service_name}" "${listen_port}" "${expose_port}" "${token}"
			;;
		client)
			local remote_addr=""
			local local_addr=""
			prompt_value "远端服务器地址" "" remote_addr
			prompt_value "本地转发地址" "127.0.0.1:22" local_addr
			write_client_config "${name}" "${service_name}" "${remote_addr}" "${local_addr}" "${token}"
			;;
		*)
			die "未知类型: ${kind}"
			;;
	esac

	systemctl daemon-reload
	systemctl enable --now "$(unit_name "${kind}" "${name}")"
	success "已创建并启动 ${kind_label "${kind}"}配置: ${name}"
	info "配置文件: ${file}"
}

edit_config() {
	local kind="$1"
	local requested_name="${2:-}"
	local name=""
	local file=""
	local unit=""
	local editor=""

	if [ -z "${requested_name}" ] || [ "${requested_name}" = "all" ]; then
		name="$(choose_kind_name "${kind}")"
	else
		name="${requested_name}"
	fi

	file="$(config_path "${kind}" "${name}")"
	[ -f "${file}" ] || die "配置不存在: ${file}"

	editor="${VISUAL:-${EDITOR:-vi}}"
	if has_cmd "${editor}"; then
		"${editor}" "${file}"
	elif has_cmd vi; then
		vi "${file}"
	else
		die "未找到可用编辑器，请先设置 EDITOR 或安装 vi"
	fi

	if service_stack_ready; then
		unit="$(unit_name "${kind}" "${name}")"
		systemctl daemon-reload
		systemctl restart "${unit}"
		success "已保存并重启: ${unit}"
	else
		warn "rathole 服务尚未安装，已保存配置但未重启"
	fi
}

delete_config() {
	local kind="$1"
	local requested_name="${2:-}"
	local name=""
	local file=""
	local unit=""
	local dir=""

	if [ -z "${requested_name}" ] || [ "${requested_name}" = "all" ]; then
		name="$(choose_kind_name "${kind}")"
	else
		name="${requested_name}"
	fi

	file="$(config_path "${kind}" "${name}")"
	[ -f "${file}" ] || die "配置不存在: ${file}"

	if ! confirm "确认删除 ${kind_label "${kind}"}配置 ${name} 吗"; then
		info "已取消"
		return 0
	fi

	unit="$(unit_name "${kind}" "${name}")"
	systemctl stop "${unit}" >/dev/null 2>&1 || true
	systemctl disable "${unit}" >/dev/null 2>&1 || true
	systemctl daemon-reload

	rm -f "${file}"
	dir="$(kind_dir "${kind}")"
	rmdir "${dir}" 2>/dev/null || true
	rmdir "${CONFIG_ROOT}" 2>/dev/null || true

	success "已删除配置: ${file}"
}

list_configs() {
	local kind="$1"
	list_kind_summary "${kind}"
}

status_kind() {
	local kind="$1"
	local target="${2:-}"

	if [ -z "${target}" ] || [ "${target}" = "all" ]; then
		list_kind_summary "${kind}"
		return 0
	fi

	if [ ! -f "$(config_path "${kind}" "${target}")" ]; then
		die "配置不存在: ${target}"
	fi

	show_target_status "${target}"
}

restart_kind() {
	local kind="$1"
	local target="${2:-}"
	local -a units=()
	local unit=""
	local names_dir=""
	local name=""
	local -a names=()

	require_service_stack

	if [ -z "${target}" ] || [ "${target}" = "all" ]; then
		names_dir="$(kind_dir "${kind}")"
		mapfile -t names < <(collect_kind_names "${names_dir}")
		if ((${#names[@]} == 0)); then
			die "${kind_label "${kind}"} 暂无可重启的配置"
		fi
		for name in "${names[@]}"; do
			units+=("$(unit_name "${kind}" "${name}")")
		done
	else
		[ -f "$(config_path "${kind}" "${target}")" ] || die "配置不存在: ${target}"
		units+=("$(unit_name "${kind}" "${target}")")
	fi

	for unit in "${units[@]}"; do
		systemctl restart "${unit}"
		success "已重启: ${unit}"
	done
}

logs_kind() {
	local kind="$1"
	local target="${2:-}"
	local -a units=()
	local journal_args=()
	local names_dir=""
	local -a names=()
	local name=""
	local unit=""

	require_service_stack

	if [ -z "${target}" ] || [ "${target}" = "all" ]; then
		names_dir="$(kind_dir "${kind}")"
		mapfile -t names < <(collect_kind_names "${names_dir}")
		if ((${#names[@]} == 0)); then
			die "${kind_label "${kind}"} 暂无可查看日志的配置"
		fi
		for name in "${names[@]}"; do
			units+=("$(unit_name "${kind}" "${name}")")
		done
	else
		[ -f "$(config_path "${kind}" "${target}")" ] || die "配置不存在: ${target}"
		units+=("$(unit_name "${kind}" "${target}")")
	fi

	for unit in "${units[@]}"; do
		journal_args+=("-u" "${unit}")
	done

	journalctl "${journal_args[@]}" -n 100 --no-pager
}

global_restart() {
	local target="${1:-}"
	local -a units=()
	local unit=""

	require_service_stack

	if ! mapfile -t units < <(collect_matching_units "${target}"); then
		die "未找到可重启的配置"
	fi

	if ((${#units[@]} == 0)); then
		die "未找到可重启的配置"
	fi

	for unit in "${units[@]}"; do
		systemctl restart "${unit}"
		success "已重启: ${unit}"
	done
}

global_logs() {
	local target="${1:-}"
	local -a units=()
	local journal_args=()
	local unit=""

	require_service_stack

	if ! mapfile -t units < <(collect_matching_units "${target}"); then
		die "未找到可查看日志的配置"
	fi

	if ((${#units[@]} == 0)); then
		die "未找到可查看日志的配置"
	fi

	for unit in "${units[@]}"; do
		journal_args+=("-u" "${unit}")
	done

	journalctl "${journal_args[@]}" -n 100 --no-pager
}

global_list() {
	list_kind_summary server
	printf '\n'
	list_kind_summary client
}

show_help() {
	cat <<EOF
用法:
	${SCRIPT_NAME} [--cdn URL] [command]

命令:
	install                         安装或更新 rathole
	status [all|name]               查看运行状态
	restart [all|name]              重启所有或指定配置
	logs [all|name]                 查看最近 100 行日志
	list                            列出所有配置
	uninstall                       卸载 rathole
	server <action> [name]          管理服务端配置
	client <action> [name]          管理客户端配置
	menu                            打开交互菜单

服务端或客户端 action:
	add                             交互式创建配置并启动
	edit                            打开编辑器修改配置并重启
	delete                          删除配置并停止服务
	status                          查看配置状态
	restart                         重启该类型下所有配置
	logs                            查看该类型下所有配置的日志
	list                            列出该类型下所有配置

配置文件位置:
	${SERVER_DIR}/*.toml
	${CLIENT_DIR}/*.toml

示例:
	${SCRIPT_NAME} install
	${SCRIPT_NAME} --cdn https://ghfast.top install
	${SCRIPT_NAME} server add
	${SCRIPT_NAME} client edit mynas
	${SCRIPT_NAME} status
EOF
}

show_menu() {
	local choice=""
	local target=""
	local name=""

	while true; do
		printf '\n'
		printf 'rathole 一键管理脚本\n'
		printf '1) 安装或更新 rathole\n'
		printf '2) 添加服务端配置\n'
		printf '3) 编辑服务端配置\n'
		printf '4) 删除服务端配置\n'
		printf '5) 添加客户端配置\n'
		printf '6) 编辑客户端配置\n'
		printf '7) 删除客户端配置\n'
		printf '8) 查看状态\n'
		printf '9) 重启服务\n'
		printf '10) 查看日志\n'
		printf '11) 卸载 rathole\n'
		printf '0) 退出\n'
		read -r -p '请选择: ' choice || true

		case "${choice}" in
			1)
				install_rathole
				;;
			2)
				create_config server server
				;;
			3)
				edit_config server ""
				;;
			4)
				delete_config server ""
				;;
			5)
				create_config client client
				;;
			6)
				edit_config client ""
				;;
			7)
				delete_config client ""
				;;
			8)
				show_global_status
				;;
			9)
				restart_units all
				;;
			10)
				show_logs all
				;;
			11)
				uninstall_rathole
				;;
			0|q|Q|quit|exit)
				exit 0
				;;
			*)
				warn "无效选择"
				;;
		esac

		printf '\n'
		read -r -p '按回车返回菜单...' _ || true
	done
}

uninstall_rathole() {
	local remove_configs=""
	local -a units=()
	local kind=""
	local name=""
	local dir=""
	local file=""

	if ! confirm "确认卸载 rathole 吗"; then
		info "已取消"
		return 0
	fi

	if service_stack_ready; then
		for kind in server client; do
			dir="$(kind_dir "${kind}")"
			for file in "${dir}"/*.toml; do
				[ -e "${file}" ] || continue
				name="$(basename "${file}" .toml)"
				units+=("$(unit_name "${kind}" "${name}")")
			done
		done

		for unit in "${units[@]}"; do
			systemctl stop "${unit}" >/dev/null 2>&1 || true
			systemctl disable "${unit}" >/dev/null 2>&1 || true
		done
	fi

	rm -f "${SERVER_UNIT_TEMPLATE}" "${CLIENT_UNIT_TEMPLATE}"
	systemctl daemon-reload

	if [ -e "${INSTALL_BIN}" ]; then
		rm -f "${INSTALL_BIN}"
	fi

	if [ -d "${CONFIG_ROOT}" ] && confirm "是否同时删除 ${CONFIG_ROOT} 下的全部配置文件"; then
		rm -rf "${CONFIG_ROOT}"
		remove_configs="yes"
	fi

	if [ "${remove_configs}" != "yes" ]; then
		rmdir "${SERVER_DIR}" 2>/dev/null || true
		rmdir "${CLIENT_DIR}" 2>/dev/null || true
		rmdir "${CONFIG_ROOT}" 2>/dev/null || true
	fi

	success "rathole 已卸载"
}

main_server() {
	local action="${1:-status}"
	local name="${2:-}"

	case "${action}" in
		add)
			create_config server "${name:-server}"
			;;
		edit)
			edit_config server "${name}"
			;;
		delete)
			delete_config server "${name}"
			;;
		status)
			status_kind server "${name}"
			;;
		restart)
			restart_kind server "${name}"
			;;
		logs)
			logs_kind server "${name}"
			;;
		list)
			list_configs server
			;;
		help|-h|--help)
			show_help
			;;
		*)
			die "未知服务端命令: ${action}"
			;;
	esac
}

main_client() {
	local action="${1:-status}"
	local name="${2:-}"

	case "${action}" in
		add)
			create_config client "${name:-client}"
			;;
		edit)
			edit_config client "${name}"
			;;
		delete)
			delete_config client "${name}"
			;;
		status)
			status_kind client "${name}"
			;;
		restart)
			restart_kind client "${name}"
			;;
		logs)
			logs_kind client "${name}"
			;;
		list)
			list_configs client
			;;
		help|-h|--help)
			show_help
			;;
		*)
			die "未知客户端命令: ${action}"
			;;
	esac
}

parse_global_args() {
	local -a remaining=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--cdn)
				[ "$#" -ge 2 ] || die "--cdn 需要提供 URL"
				normalize_cdn_prefix "$2"
				shift 2
				;;
			--cdn=*)
				normalize_cdn_prefix "${1#--cdn=}"
				shift
				;;
			-h|--help)
				show_help
				exit 0
				;;
			--)
				shift
				remaining+=("$@")
				break
				;;
			-*)
				die "未知参数: $1"
				;;
			*)
				remaining+=("$@")
				break
				;;
		esac
	done

	if ((${#remaining[@]} == 0)); then
		PARSED_ARGS=()
	else
		PARSED_ARGS=("${remaining[@]}")
	fi
}

PARSED_ARGS=()

main() {
	local command=""
	local action=""
	local name=""

	parse_global_args "$@"
	set -- "${PARSED_ARGS[@]}"

	if [ "$#" -eq 0 ]; then
		if [ -t 0 ]; then
			show_menu
			exit 0
		fi
		show_help
		exit 0
	fi

	command="$1"
	shift || true

	if [ "${command}" != "help" ] && [ "${command}" != "-h" ] && [ "${command}" != "--help" ]; then
		require_root
		require_systemd
	fi

	case "${command}" in
		install)
			install_rathole
			;;
		status)
			show_global_status "${1:-all}"
			;;
		restart)
			global_restart "${1:-all}"
			;;
		logs)
			global_logs "${1:-all}"
			;;
		list)
			global_list
			;;
		uninstall)
			uninstall_rathole
			;;
		server)
			main_server "${1:-status}" "${2:-}"
			;;
		client)
			main_client "${1:-status}" "${2:-}"
			;;
		menu)
			show_menu
			;;
		help|-h|--help)
			show_help
			;;
		*)
			die "未知命令: ${command}"
			;;
	esac
}

main "$@"
