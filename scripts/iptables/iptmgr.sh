#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_INIT_PORTS="22,80,443"

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}

usage() {
  cat <<USAGE
用法:
  $SCRIPT_NAME <command> [options]

命令:
  menu      显示当前状态并进入交互菜单（默认）
  init      初始化防火墙，放行默认端口（默认: 22,80,443）
  allow     允许访问指定端口（TCP/UDP）
  deny      禁止访问指定端口（TCP/UDP，含日志）
  forward   端口转发到内网服务器（TCP/UDP，含日志）
  list      查看当前 iptables 规则
  delete    删除指定 iptables 规则（按表/链/行号）
  help      显示帮助信息

全局示例:
  $SCRIPT_NAME
  $SCRIPT_NAME menu
  $SCRIPT_NAME init
  $SCRIPT_NAME init --ports 22,80,443,8443
  $SCRIPT_NAME allow --proto tcp --port 8080
  $SCRIPT_NAME allow --proto udp --port 51820
  $SCRIPT_NAME deny --proto tcp --port 3306
  $SCRIPT_NAME deny --proto udp --port 1900
  $SCRIPT_NAME forward --proto tcp --in-port 8081 --to-ip 192.168.1.10 --to-port 80
  $SCRIPT_NAME forward --proto udp --in-port 6000 --to-ip 10.0.0.5 --to-port 6000 --masquerade
  $SCRIPT_NAME list
  $SCRIPT_NAME list --table nat
  $SCRIPT_NAME delete --table filter --chain INPUT --line 3
  $SCRIPT_NAME delete --table nat --chain PREROUTING --line 2
USAGE
}

pause_enter() {
  read -r -p "按回车继续..." _ || true
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "请使用 root 权限运行。"
  fi
}

require_iptables() {
  command -v iptables >/dev/null 2>&1 || error "未找到 iptables 命令。"
}

is_valid_protocol() {
  local proto="$1"
  [[ "$proto" == "tcp" || "$proto" == "udp" ]]
}

is_valid_port() {
  local port="$1"
  if [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
    (( port >= 1 && port <= 65535 ))
    return
  fi

  if [[ "$port" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
    local start="${BASH_REMATCH[1]}"
    local end="${BASH_REMATCH[2]}"
    (( start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end ))
    return
  fi

  return 1
}

is_valid_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    (( oct >= 0 && oct <= 255 )) || return 1
  done
}

rule_exists() {
  local table="$1"
  local chain="$2"
  shift 2
  iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1
}

append_rule_if_missing() {
  local table="$1"
  local chain="$2"
  shift 2
  if rule_exists "$table" "$chain" "$@"; then
    info "规则已存在: -t $table -A $chain $*"
  else
    iptables -t "$table" -A "$chain" "$@"
    info "已添加规则: -t $table -A $chain $*"
  fi
}

split_csv_ports() {
  local ports_csv="$1"
  local -n out_arr="$2"

  IFS=',' read -r -a raw_ports <<<"$ports_csv"
  out_arr=()
  for p in "${raw_ports[@]}"; do
    p="${p// /}"
    [[ -n "$p" ]] || continue
    is_valid_port "$p" || error "无效端口: $p"
    out_arr+=("$p")
  done

  ((${#out_arr[@]} > 0)) || error "端口列表为空。"
}

cmd_init() {
  local ports_csv="$DEFAULT_INIT_PORTS"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ports)
        ports_csv="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  local ports=()
  split_csv_ports "$ports_csv" ports

  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  append_rule_if_missing filter INPUT -i lo -j ACCEPT
  append_rule_if_missing filter INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  local p
  for p in "${ports[@]}"; do
    append_rule_if_missing filter INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
  done

  info "初始化完成。已放行 TCP 端口: ${ports[*]}"
}

cmd_allow() {
  local proto=""
  local port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto)
        proto="${2:-}"
        shift 2
        ;;
      --port)
        port="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  [[ -n "$proto" ]] || error "allow 命令缺少 --proto"
  [[ -n "$port" ]] || error "allow 命令缺少 --port"

  is_valid_protocol "$proto" || error "无效协议: $proto（仅支持 tcp/udp）"
  is_valid_port "$port" || error "无效端口: $port"

  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
}

cmd_deny() {
  local proto=""
  local port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto)
        proto="${2:-}"
        shift 2
        ;;
      --port)
        port="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  [[ -n "$proto" ]] || error "deny 命令缺少 --proto"
  [[ -n "$port" ]] || error "deny 命令缺少 --port"

  is_valid_protocol "$proto" || error "无效协议: $proto（仅支持 tcp/udp）"
  is_valid_port "$port" || error "无效端口: $port"

  local prefix="IPTMGR-DENY-${proto}-${port} "

  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "$prefix" --log-level 4
  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -j DROP
}

cmd_forward() {
  local proto=""
  local in_port=""
  local to_ip=""
  local to_port=""
  local masquerade="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto)
        proto="${2:-}"
        shift 2
        ;;
      --in-port)
        in_port="${2:-}"
        shift 2
        ;;
      --to-ip)
        to_ip="${2:-}"
        shift 2
        ;;
      --to-port)
        to_port="${2:-}"
        shift 2
        ;;
      --masquerade)
        masquerade="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  [[ -n "$proto" ]] || error "forward 命令缺少 --proto"
  [[ -n "$in_port" ]] || error "forward 命令缺少 --in-port"
  [[ -n "$to_ip" ]] || error "forward 命令缺少 --to-ip"
  [[ -n "$to_port" ]] || error "forward 命令缺少 --to-port"

  is_valid_protocol "$proto" || error "无效协议: $proto（仅支持 tcp/udp）"
  is_valid_port "$in_port" || error "无效入站端口: $in_port"
  is_valid_port "$to_port" || error "无效目标端口: $to_port"
  is_valid_ipv4 "$to_ip" || error "无效目标 IP: $to_ip"

  command -v sysctl >/dev/null 2>&1 || error "未找到 sysctl 命令。"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  local prefix="IPTMGR-FWD-${proto}-${in_port} "

  append_rule_if_missing nat PREROUTING -p "$proto" --dport "$in_port" -m limit --limit 20/min --limit-burst 40 -j LOG --log-prefix "$prefix" --log-level 4
  append_rule_if_missing nat PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "${to_ip}:${to_port}"

  append_rule_if_missing filter FORWARD -p "$proto" -d "$to_ip" --dport "$to_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  append_rule_if_missing filter FORWARD -p "$proto" -s "$to_ip" --sport "$to_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  if [[ "$masquerade" == "true" ]]; then
    append_rule_if_missing nat POSTROUTING -p "$proto" -d "$to_ip" --dport "$to_port" -j MASQUERADE
  fi

  info "转发已配置: ${proto} ${in_port} -> ${to_ip}:${to_port}"
}

cmd_list() {
  local table="all"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --table)
        table="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  case "$table" in
    all)
      local t
      for t in filter nat mangle raw; do
        echo "===== TABLE: $t ====="
        iptables -t "$t" -L -n -v --line-numbers
        echo
      done
      ;;
    filter|nat|mangle|raw)
      echo "===== TABLE: $table ====="
      iptables -t "$table" -L -n -v --line-numbers
      ;;
    *)
      error "无效 table: $table（支持 all/filter/nat/mangle/raw）"
      ;;
  esac
}

cmd_delete() {
  local table="filter"
  local chain=""
  local line=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --table)
        table="${2:-}"
        shift 2
        ;;
      --chain)
        chain="${2:-}"
        shift 2
        ;;
      --line)
        line="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        ;;
    esac
  done

  [[ -n "$chain" ]] || error "delete 命令缺少 --chain"
  [[ -n "$line" ]] || error "delete 命令缺少 --line"

  case "$table" in
    filter|nat|mangle|raw) ;;
    *) error "无效 table: $table（支持 filter/nat/mangle/raw）" ;;
  esac

  [[ "$line" =~ ^[0-9]+$ ]] || error "line 必须是正整数"
  (( line > 0 )) || error "line 必须大于 0"

  iptables -t "$table" -D "$chain" "$line"
  info "已删除规则: -t $table -D $chain $line"
}

show_port_status() {
  local allow_lines deny_lines
  allow_lines="$(iptables -S INPUT | awk '
    {
      proto=""; dport=""; jump="";
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1);
        if ($i == "--dport" && i+1<=NF) dport=$(i+1);
        if ($i == "-j" && i+1<=NF) jump=$(i+1);
      }
      if (dport != "" && jump == "ACCEPT" && (proto == "tcp" || proto == "udp")) {
        printf "%s %s\n", toupper(proto), dport;
      }
    }
  ' | sort -u)"

  deny_lines="$(iptables -S INPUT | awk '
    {
      proto=""; dport=""; jump="";
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1);
        if ($i == "--dport" && i+1<=NF) dport=$(i+1);
        if ($i == "-j" && i+1<=NF) jump=$(i+1);
      }
      if (dport != "" && jump == "DROP" && (proto == "tcp" || proto == "udp")) {
        printf "%s %s\n", toupper(proto), dport;
      }
    }
  ' | sort -u)"

  echo "当前放行端口:"
  if [[ -n "$allow_lines" ]]; then
    echo "$allow_lines" | sed 's/^/  - /'
  else
    echo "  - 无"
  fi

  echo "当前禁用端口:"
  if [[ -n "$deny_lines" ]]; then
    echo "$deny_lines" | sed 's/^/  - /'
  else
    echo "  - 无"
  fi
}

show_forward_status() {
  local fwd_lines
  fwd_lines="$(iptables -t nat -S PREROUTING | awk '
    {
      proto=""; dport=""; jump=""; target="";
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1);
        if ($i == "--dport" && i+1<=NF) dport=$(i+1);
        if ($i == "-j" && i+1<=NF) jump=$(i+1);
        if ($i == "--to-destination" && i+1<=NF) target=$(i+1);
      }
      if (jump == "DNAT" && proto != "" && dport != "" && target != "") {
        printf "%s %s -> %s\n", toupper(proto), dport, target;
      }
    }
  ' | sort -u)"

  echo "当前转发配置:"
  if [[ -n "$fwd_lines" ]]; then
    echo "$fwd_lines" | sed 's/^/  - /'
  else
    echo "  - 无"
  fi
}

print_menu_header() {
  echo "========================================"
  echo "iptables 管理菜单"
  echo "========================================"
  show_port_status
  echo
  show_forward_status
  echo
  echo "操作菜单指引，选择编号进入子菜单或配置页面"
  echo "1) 初始化默认端口放行"
  echo "2) 允许访问指定端口"
  echo "3) 禁止访问指定端口"
  echo "4) 配置端口转发"
  echo "5) 查看当前规则"
  echo "6) 删除指定规则"
  echo "7) 查看帮助"
  echo "0) 退出"
}

menu_action_init() {
  local ports
  read -r -p "请输入要放行的端口列表（逗号分隔，留空则默认 22,80,443）: " ports
  if [[ -z "${ports// }" ]]; then
    cmd_init
  else
    cmd_init --ports "$ports"
  fi
}

menu_action_allow() {
  local proto port
  read -r -p "请输入协议（tcp/udp）: " proto
  read -r -p "请输入端口（如 8080 或 10000:10100）: " port
  cmd_allow --proto "$proto" --port "$port"
}

menu_action_deny() {
  local proto port
  read -r -p "请输入协议（tcp/udp）: " proto
  read -r -p "请输入端口（如 3306 或 2000:2100）: " port
  cmd_deny --proto "$proto" --port "$port"
}

menu_action_forward() {
  local proto in_port to_ip to_port yn
  read -r -p "请输入协议（tcp/udp）: " proto
  read -r -p "请输入外部访问端口: " in_port
  read -r -p "请输入目标内网 IP: " to_ip
  read -r -p "请输入目标端口: " to_port
  read -r -p "是否启用 MASQUERADE（y/N）: " yn

  if [[ "$yn" =~ ^[Yy]$ ]]; then
    cmd_forward --proto "$proto" --in-port "$in_port" --to-ip "$to_ip" --to-port "$to_port" --masquerade
  else
    cmd_forward --proto "$proto" --in-port "$in_port" --to-ip "$to_ip" --to-port "$to_port"
  fi
}

menu_action_list() {
  local table
  read -r -p "请输入 table（all/filter/nat/mangle/raw，留空默认 all）: " table
  if [[ -z "${table// }" ]]; then
    cmd_list
  else
    cmd_list --table "$table"
  fi
}

menu_action_delete() {
  local table chain line
  read -r -p "请输入 table（filter/nat/mangle/raw，默认 filter）: " table
  read -r -p "请输入 chain（如 INPUT、FORWARD、PREROUTING）: " chain
  read -r -p "请输入要删除的行号: " line

  if [[ -z "${table// }" ]]; then
    cmd_delete --chain "$chain" --line "$line"
  else
    cmd_delete --table "$table" --chain "$chain" --line "$line"
  fi
}

cmd_menu() {
  while true; do
    print_menu_header
    read -r -p "请输入：" choice
    echo
    case "${choice:-}" in
      1)
        if ! (menu_action_init); then
          warn "初始化操作失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      2)
        if ! (menu_action_allow); then
          warn "放行操作失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      3)
        if ! (menu_action_deny); then
          warn "禁用操作失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      4)
        if ! (menu_action_forward); then
          warn "转发操作失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      5)
        if ! (menu_action_list); then
          warn "查看规则失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      6)
        if ! (menu_action_delete); then
          warn "删除规则失败，请检查输入后重试。"
        fi
        pause_enter
        ;;
      7)
        usage
        pause_enter
        ;;
      0)
        info "已退出。"
        break
        ;;
      *)
        warn "无效编号，请重新输入。"
        pause_enter
        ;;
    esac
    echo
  done
}

main() {
  local cmd="${1:-menu}"
  shift || true

  case "$cmd" in
    menu)
      require_root
      require_iptables
      cmd_menu
      ;;
    help|-h|--help)
      usage
      ;;
    init)
      require_root
      require_iptables
      cmd_init "$@"
      ;;
    allow)
      require_root
      require_iptables
      cmd_allow "$@"
      ;;
    deny)
      require_root
      require_iptables
      cmd_deny "$@"
      ;;
    forward)
      require_root
      require_iptables
      cmd_forward "$@"
      ;;
    list)
      require_root
      require_iptables
      cmd_list "$@"
      ;;
    delete)
      require_root
      require_iptables
      cmd_delete "$@"
      ;;
    *)
      error "未知命令: $cmd（使用 $SCRIPT_NAME help 查看帮助）"
      ;;
  esac
}

main "$@"
