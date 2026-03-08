#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_INIT_RULES="22,80,443/tcp"

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
  $SCRIPT_NAME [menu]
  $SCRIPT_NAME init [--rules "端口/协议,端口/协议"] [--ports "22,80,443"]
  $SCRIPT_NAME allow --rules "端口/协议,端口/协议"
  $SCRIPT_NAME deny --rules "端口/协议,端口/协议"
  $SCRIPT_NAME forward --proto tcp|udp --in-port 端口 --to-ip 目标IP --to-port 目标端口 [--masquerade]
  $SCRIPT_NAME list [--table all|filter|nat|mangle|raw]
  $SCRIPT_NAME delete --table 表 --chain 链 --line 行号
  $SCRIPT_NAME delete --rules "端口/协议,端口/协议"
  $SCRIPT_NAME help

规则输入格式:
  支持两种写法，可混用，多个规则用逗号分隔。
  写法A: 端口/协议（如 22/tcp）
  写法B: 多端口/协议（如 22,80,443/tcp）
  协议支持: tcp / udp / all / 其他协议名(如 sctp)

示例:
  $SCRIPT_NAME
  $SCRIPT_NAME init --rules "22,80,443/tcp"
  $SCRIPT_NAME allow --rules "80,443/tcp,53/udp"
  $SCRIPT_NAME deny --rules "3306/tcp,1900/udp"
  $SCRIPT_NAME allow --rules "5000/sctp"
  $SCRIPT_NAME forward --proto tcp --in-port 8080 --to-ip 192.168.1.10 --to-port 80
  $SCRIPT_NAME delete --table filter --chain INPUT --line 3
  $SCRIPT_NAME delete --rules "80/tcp,443/tcp"
USAGE
}

pause_enter() {
  read -r -p "按回车继续..." _ || true
}

screen_clear() {
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033c'
  fi
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

log_prefix() {
  local raw="$1"
  printf '%s' "${raw:0:29}"
}

split_csv_ports() {
  local ports_csv="$1"
  local -n out_arr="$2"

  IFS=',' read -r -a raw_ports <<<"$ports_csv"
  out_arr=()

  local p
  for p in "${raw_ports[@]}"; do
    p="${p//[[:space:]]/}"
    [[ -n "$p" ]] || continue
    is_valid_port "$p" || error "无效端口: $p"
    out_arr+=("$p")
  done

  ((${#out_arr[@]} > 0)) || error "端口列表为空。"
}

parse_port_proto_specs() {
  local rules_csv="$1"
  local -n out_specs="$2"

  IFS=',' read -r -a raw_specs <<<"$rules_csv"
  out_specs=()

  local item port proto_raw
  local -a pending_ports=()

  for item in "${raw_specs[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue

    if [[ "$item" == */* ]]; then
      port="${item%%/*}"
      proto_raw="${item#*/}"
      proto_raw="${proto_raw,,}"

      is_valid_port "$port" || error "无效端口: $port"

      case "$proto_raw" in
        tcp|udp|all) ;;
        *)
          # 其他协议直接写协议名，例如 5000/sctp
          [[ "$proto_raw" =~ ^[a-z0-9._-]+$ ]] || error "无效协议: $proto_raw（支持 tcp/udp/all/其他协议名）"
          ;;
      esac

      pending_ports+=("$port")

      local p
      for p in "${pending_ports[@]}"; do
        out_specs+=("${p}/${proto_raw}")
      done
      pending_ports=()
    else
      is_valid_port "$item" || error "无效端口: $item"
      pending_ports+=("$item")
    fi
  done

  if ((${#pending_ports[@]} > 0)); then
    error "以下端口缺少协议: ${pending_ports[*]}（示例: 22,80,443/tcp）"
  fi

  ((${#out_specs[@]} > 0)) || error "规则列表为空。"
}

expand_protocols() {
  local proto_spec="$1"
  local -n out_protocols="$2"

  case "$proto_spec" in
    tcp|udp)
      out_protocols=("$proto_spec")
      ;;
    all)
      out_protocols=("tcp" "udp")
      ;;
    *)
      out_protocols=("$proto_spec")
      ;;
  esac
}

ports_csv_to_rules_csv() {
  local ports_csv="$1"
  local ports=()
  split_csv_ports "$ports_csv" ports

  local rules=()
  local p
  for p in "${ports[@]}"; do
    rules+=("${p}/tcp")
  done

  local IFS=','
  echo "${rules[*]}"
}

add_allow_rule() {
  local proto="$1"
  local port="$2"
  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
}

add_deny_rule() {
  local proto="$1"
  local port="$2"
  local prefix

  prefix="$(log_prefix "IPTMGR-DENY-${proto}-${port} ")"
  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -m conntrack --ctstate NEW -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "$prefix" --log-level 4
  append_rule_if_missing filter INPUT -p "$proto" --dport "$port" -j DROP
}

apply_allow_rules_csv() {
  local rules_csv="$1"
  local specs=()
  parse_port_proto_specs "$rules_csv" specs

  local spec port proto_spec protocols proto
  for spec in "${specs[@]}"; do
    port="${spec%%/*}"
    proto_spec="${spec#*/}"
    protocols=()
    expand_protocols "$proto_spec" protocols

    for proto in "${protocols[@]}"; do
      add_allow_rule "$proto" "$port"
    done
  done
}

apply_deny_rules_csv() {
  local rules_csv="$1"
  local specs=()
  parse_port_proto_specs "$rules_csv" specs

  local spec port proto_spec protocols proto
  for spec in "${specs[@]}"; do
    port="${spec%%/*}"
    proto_spec="${spec#*/}"
    protocols=()
    expand_protocols "$proto_spec" protocols

    for proto in "${protocols[@]}"; do
      add_deny_rule "$proto" "$port"
    done
  done
}

flush_all_tables() {
  local t
  for t in filter nat mangle raw; do
    iptables -t "$t" -F
    iptables -t "$t" -X
  done
}

cmd_init() {
  local rules_csv="$DEFAULT_INIT_RULES"
  local ports_csv=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rules)
        rules_csv="${2:-}"
        shift 2
        ;;
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

  if [[ -n "$ports_csv" ]]; then
    rules_csv="$(ports_csv_to_rules_csv "$ports_csv")"
  fi

  flush_all_tables

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  append_rule_if_missing filter INPUT -i lo -j ACCEPT
  append_rule_if_missing filter INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  apply_allow_rules_csv "$rules_csv"

  info "初始化完成：已默认拒绝所有入站端口，仅放行指定规则。"
}

cmd_allow() {
  local rules_csv=""
  local proto=""
  local port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rules)
        rules_csv="${2:-}"
        shift 2
        ;;
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

  if [[ -n "$proto" || -n "$port" ]]; then
    [[ -n "$proto" && -n "$port" ]] || error "使用 --proto/--port 时必须同时提供两者"
    rules_csv="${port}/${proto}"
  fi

  [[ -n "$rules_csv" ]] || error "allow 命令缺少 --rules"

  apply_allow_rules_csv "$rules_csv"
}

cmd_deny() {
  local rules_csv=""
  local proto=""
  local port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rules)
        rules_csv="${2:-}"
        shift 2
        ;;
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

  if [[ -n "$proto" || -n "$port" ]]; then
    [[ -n "$proto" && -n "$port" ]] || error "使用 --proto/--port 时必须同时提供两者"
    rules_csv="${port}/${proto}"
  fi

  [[ -n "$rules_csv" ]] || error "deny 命令缺少 --rules"

  apply_deny_rules_csv "$rules_csv"
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

  is_valid_protocol "$proto" || error "无效协议: $proto（forward 仅支持 tcp/udp）"
  is_valid_port "$in_port" || error "无效入站端口: $in_port"
  is_valid_port "$to_port" || error "无效目标端口: $to_port"
  is_valid_ipv4 "$to_ip" || error "无效目标 IP: $to_ip"

  command -v sysctl >/dev/null 2>&1 || error "未找到 sysctl 命令。"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  local prefix
  prefix="$(log_prefix "IPTMGR-FWD-${proto}-${in_port} ")"

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

delete_matching_rules_in_chain() {
  local table="$1"
  local chain="$2"
  local proto="$3"
  local port="$4"
  local mode="$5" # dport|any

  iptables -t "$table" -S "$chain" >/dev/null 2>&1 || {
    echo 0
    return
  }

  local deleted=0
  local line

  while true; do
    line="$(iptables -t "$table" -S "$chain" | nl -ba | awk -v proto="$proto" -v port="$port" -v mode="$mode" '
      {
        ln=$1
        has_proto=0
        has_dport=0
        has_sport=0

        for (i=2; i<=NF; i++) {
          if ($i=="-p" && i+1<=NF && $(i+1)==proto) has_proto=1
          if ($i=="--dport" && i+1<=NF && $(i+1)==port) has_dport=1
          if ($i=="--sport" && i+1<=NF && $(i+1)==port) has_sport=1
        }

        matched=0
        if (mode=="dport" && has_proto && has_dport) matched=1
        if (mode=="any" && has_proto && (has_dport || has_sport)) matched=1

        if (matched) last_line=ln
      }
      END {
        if (last_line!="") print last_line
      }
    ' )"

    [[ -n "$line" ]] || break
    iptables -t "$table" -D "$chain" "$line"
    ((deleted++))
  done

  echo "$deleted"
}

delete_by_rules_csv() {
  local rules_csv="$1"
  local specs=()
  parse_port_proto_specs "$rules_csv" specs

  local total_deleted=0
  local spec port proto_spec protocols proto
  local c

  for spec in "${specs[@]}"; do
    port="${spec%%/*}"
    proto_spec="${spec#*/}"
    protocols=()
    expand_protocols "$proto_spec" protocols

    for proto in "${protocols[@]}"; do
      c="$(delete_matching_rules_in_chain filter INPUT "$proto" "$port" dport)"
      total_deleted=$((total_deleted + c))

      c="$(delete_matching_rules_in_chain nat PREROUTING "$proto" "$port" dport)"
      total_deleted=$((total_deleted + c))

      c="$(delete_matching_rules_in_chain nat POSTROUTING "$proto" "$port" dport)"
      total_deleted=$((total_deleted + c))

      c="$(delete_matching_rules_in_chain filter FORWARD "$proto" "$port" any)"
      total_deleted=$((total_deleted + c))
    done
  done

  if (( total_deleted == 0 )); then
    warn "未匹配到可删除规则。"
  else
    info "已删除规则数量: $total_deleted"
  fi
}

cmd_delete() {
  local table="filter"
  local chain=""
  local line=""
  local rules_csv=""

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
      --rules)
        rules_csv="${2:-}"
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

  if [[ -n "$rules_csv" ]]; then
    [[ -z "$line" && -z "$chain" ]] || error "使用 --rules 删除时，不要同时提供 --chain/--line"
    delete_by_rules_csv "$rules_csv"
    return
  fi

  [[ -n "$chain" ]] || error "delete 命令缺少 --chain（或使用 --rules）"
  [[ -n "$line" ]] || error "delete 命令缺少 --line（或使用 --rules）"

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
      proto=""; dport=""; jump=""
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1)
        if ($i == "--dport" && i+1<=NF) dport=$(i+1)
        if ($i == "-j" && i+1<=NF) jump=$(i+1)
      }
      if (dport != "" && jump == "ACCEPT") {
        printf "%s %s\n", toupper(proto), dport
      }
    }
  ' | sort -u)"

  deny_lines="$(iptables -S INPUT | awk '
    {
      proto=""; dport=""; jump=""
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1)
        if ($i == "--dport" && i+1<=NF) dport=$(i+1)
        if ($i == "-j" && i+1<=NF) jump=$(i+1)
      }
      if (dport != "" && jump == "DROP") {
        printf "%s %s\n", toupper(proto), dport
      }
    }
  ' | sort -u)"

  echo "当前放行端口信息:"
  if [[ -n "$allow_lines" ]]; then
    echo "$allow_lines" | sed 's/^/  - /'
  else
    echo "  - 无"
  fi

  echo "当前禁用端口信息:"
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
      proto=""; dport=""; jump=""; target=""
      for (i=1; i<=NF; i++) {
        if ($i == "-p" && i+1<=NF) proto=$(i+1)
        if ($i == "--dport" && i+1<=NF) dport=$(i+1)
        if ($i == "-j" && i+1<=NF) jump=$(i+1)
        if ($i == "--to-destination" && i+1<=NF) target=$(i+1)
      }
      if (jump == "DNAT" && proto != "" && dport != "" && target != "") {
        printf "%s %s -> %s\n", toupper(proto), dport, target
      }
    }
  ' | sort -u)"

  echo "当前转发配置信息:"
  if [[ -n "$fwd_lines" ]]; then
    echo "$fwd_lines" | sed 's/^/  - /'
  else
    echo "  - 无"
  fi
}

print_main_menu() {
  cat <<'EOF'
================ iptables 管理 ================
功能说明:
  - 本页面展示当前放行/禁用端口与转发配置总览。
  - 请选择编号进入子菜单进行配置。
  - 输入 0 退出脚本。
EOF
  echo
  show_port_status
  echo
  show_forward_status
  echo
  echo "操作菜单指引，选择编号进入子菜单或配置页面"
  echo "1) 端口规则管理"
  echo "2) 端口转发管理"
  echo "3) 规则查看与删除"
  echo "4) 帮助"
  echo "0) 退出"
}

menu_port_rules() {
  local choice rules

  while true; do
    screen_clear
    cat <<'EOF'
-------------- 端口规则管理 --------------
功能说明:
  - 初始化: 清空现有规则，默认拒绝所有入站端口，只放行你指定的规则。
  - 放行: 按“端口/协议”批量放行。
  - 禁用: 按“端口/协议”批量禁用，并自动写入日志规则。

输入格式:
  - 支持两种写法，可混用，多个规则用逗号分隔:
    1) 端口/协议（如 80/tcp）
    2) 多端口/协议（如 80,443/tcp）
  - 协议支持: tcp / udp / all / 其他协议名(如 sctp)

示例:
  - 22,80,443/tcp
  - 53,67/udp
  - 8080/all
  - 5000/sctp
------------------------------------------
EOF
    echo "1) 初始化（禁用全部后放行指定规则）"
    echo "2) 放行端口规则"
    echo "3) 禁用端口规则"
    echo "0) 返回上级"
    read -r -p "请输入：" choice

    case "${choice:-}" in
      1)
        read -r -p "请输入初始化放行规则（留空默认 ${DEFAULT_INIT_RULES}）: " rules
        if [[ -z "${rules//[[:space:]]/}" ]]; then
          if ! (cmd_init); then
            warn "初始化失败，请检查输入。"
          fi
        else
          if ! (cmd_init --rules "$rules"); then
            warn "初始化失败，请检查输入。"
          fi
        fi
        pause_enter
        ;;
      2)
        read -r -p "请输入放行规则（如 80,443/tcp 或 80/tcp,53/udp）: " rules
        if ! (cmd_allow --rules "$rules"); then
          warn "放行失败，请检查输入。"
        fi
        pause_enter
        ;;
      3)
        read -r -p "请输入禁用规则（如 3306,5432/tcp 或 1900/udp）: " rules
        if ! (cmd_deny --rules "$rules"); then
          warn "禁用失败，请检查输入。"
        fi
        pause_enter
        ;;
      0)
        break
        ;;
      *)
        warn "无效编号，请重新输入。"
        pause_enter
        ;;
    esac
  done
}

menu_forward_rules() {
  local choice proto in_port to_ip to_port yn

  while true; do
    screen_clear
    cat <<'EOF'
-------------- 端口转发管理 --------------
功能说明:
  - 将外部访问端口转发到内网服务器指定端口。
  - 自动启用内核转发 net.ipv4.ip_forward=1。
  - 支持 TCP / UDP，并记录转发日志。

示例:
  - tcp, 8080 -> 192.168.1.10:80
  - udp, 6000 -> 10.0.0.5:6000
EOF
    echo
    show_forward_status
    echo "------------------------------------------"
    echo "1) 新增端口转发"
    echo "0) 返回上级"
    read -r -p "请输入：" choice

    case "${choice:-}" in
      1)
        read -r -p "请输入协议（tcp/udp）: " proto
        read -r -p "请输入外部端口: " in_port
        read -r -p "请输入目标内网 IP: " to_ip
        read -r -p "请输入目标端口: " to_port
        read -r -p "是否启用 MASQUERADE（y/N）: " yn

        if [[ "$yn" =~ ^[Yy]$ ]]; then
          if ! (cmd_forward --proto "$proto" --in-port "$in_port" --to-ip "$to_ip" --to-port "$to_port" --masquerade); then
            warn "转发配置失败，请检查输入。"
          fi
        else
          if ! (cmd_forward --proto "$proto" --in-port "$in_port" --to-ip "$to_ip" --to-port "$to_port"); then
            warn "转发配置失败，请检查输入。"
          fi
        fi
        pause_enter
        ;;
      0)
        break
        ;;
      *)
        warn "无效编号，请重新输入。"
        pause_enter
        ;;
    esac
  done
}

menu_rule_manage() {
  local choice table chain line rules

  while true; do
    screen_clear
    cat <<'EOF'
-------------- 规则查看与删除 --------------
功能说明:
  - 查看当前规则: 按表查看或全部查看。
  - 删除规则(序号): 按 table + chain + line 精确删除。
  - 删除规则(端口/协议): 按“端口/协议”批量删除相关规则。

删除(端口/协议)示例:
  - 80/tcp
  - 80,443/tcp
  - 8080/all
EOF
    echo "------------------------------------------"
    echo "1) 查看当前规则"
    echo "2) 按序号删除规则"
    echo "3) 按端口/协议删除规则"
    echo "0) 返回上级"
    read -r -p "请输入：" choice

    case "${choice:-}" in
      1)
        read -r -p "请输入 table（all/filter/nat/mangle/raw，留空默认 all）: " table
        if [[ -z "${table//[[:space:]]/}" ]]; then
          if ! (cmd_list); then
            warn "查看失败，请检查输入。"
          fi
        else
          if ! (cmd_list --table "$table"); then
            warn "查看失败，请检查输入。"
          fi
        fi
        pause_enter
        ;;
      2)
        read -r -p "请输入 table（filter/nat/mangle/raw）: " table
        read -r -p "请输入 chain（如 INPUT/FORWARD/PREROUTING）: " chain
        read -r -p "请输入行号: " line
        if ! (cmd_delete --table "$table" --chain "$chain" --line "$line"); then
          warn "删除失败，请检查输入。"
        fi
        pause_enter
        ;;
      3)
        read -r -p "请输入要删除的规则（如 80,443/tcp 或 80/tcp,53/udp）: " rules
        if ! (cmd_delete --rules "$rules"); then
          warn "删除失败，请检查输入。"
        fi
        pause_enter
        ;;
      0)
        break
        ;;
      *)
        warn "无效编号，请重新输入。"
        pause_enter
        ;;
    esac
  done
}

cmd_menu() {
  local choice

  while true; do
    screen_clear
    print_main_menu
    read -r -p "请输入：" choice

    case "${choice:-}" in
      1)
        menu_port_rules
        ;;
      2)
        menu_forward_rules
        ;;
      3)
        menu_rule_manage
        ;;
      4)
        screen_clear
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
