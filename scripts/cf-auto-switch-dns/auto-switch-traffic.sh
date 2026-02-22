#!/bin/bash

# ================= 配置区 =================
# Cloudflare 认证信息
CF_TOKEN="你的_API_TOKEN"
ZONE_ID="你的_ZONE_ID"

# 域名全称 (如 test.example.com)
RECORD_NAME="test.example.com"

# 流量 API
TRAFFIC_API_URL="https://tz.example/api/recent/05a99567-039e-432e-95d1-5d9d7c63840f"

# 服务器总流量 (GB) 与切换阈值 (GB)
TOTAL_TRAFFIC_GB=1000
SWITCH_THRESHOLD_GB=900

# 默认与切换 IP (逗号分隔, 支持 IPv6)
DEFAULT_IPS="1.1.1.1,2.2.2.2"
SWITCH_IPS="2606:4700:4700::1111,2.2.2.2"

# 是否开启 Cloudflare 代理 (true/false)
PROXIED=false
# ==========================================

# 检查是否安装了 jq
if ! command -v jq &> /dev/null; then
    echo "错误: 未检测到 jq 工具，请先安装 (sudo apt install jq 或 yum install jq)"
    exit 1
fi

if [ "$TOTAL_TRAFFIC_GB" -le 0 ] || [ "$SWITCH_THRESHOLD_GB" -le 0 ]; then
    echo "❌ 配置错误: TOTAL_TRAFFIC_GB 与 SWITCH_THRESHOLD_GB 必须大于 0"
    exit 1
fi

if [ "$SWITCH_THRESHOLD_GB" -gt "$TOTAL_TRAFFIC_GB" ]; then
    echo "⚠️ 警告: SWITCH_THRESHOLD_GB 大于 TOTAL_TRAFFIC_GB，阈值可能不合理"
fi

# 获取实时流量
TRAFFIC_JSON=$(curl -s --max-time 15 "$TRAFFIC_API_URL")
if [ -z "$TRAFFIC_JSON" ]; then
    echo "❌ 错误: 无法获取流量数据 (请求失败或返回为空)"
    exit 1
fi

STATUS=$(echo "$TRAFFIC_JSON" | jq -r '.status')
if [ "$STATUS" != "success" ]; then
    echo "❌ 错误: 流量接口返回失败状态: $STATUS"
    exit 1
fi

DATA_LEN=$(echo "$TRAFFIC_JSON" | jq -r '.data | length')
if [ "$DATA_LEN" == "0" ]; then
    echo "❌ 错误: 流量接口返回 data 为空"
    exit 1
fi

TOTAL_UP=$(echo "$TRAFFIC_JSON" | jq -r '.data[-1].network.totalUp // 0')
TOTAL_DOWN=$(echo "$TRAFFIC_JSON" | jq -r '.data[-1].network.totalDown // 0')
TOTAL_BYTES=$((TOTAL_UP + TOTAL_DOWN))
THRESHOLD_BYTES=$((SWITCH_THRESHOLD_GB * 1024 * 1024 * 1024))

USED_GB=$(awk -v b="$TOTAL_BYTES" 'BEGIN {printf "%.2f", b/1024/1024/1024}')
USAGE_PERCENT=$(awk -v b="$TOTAL_BYTES" -v t="$TOTAL_TRAFFIC_GB" 'BEGIN {printf "%.2f", (b/1024/1024/1024)/t*100}')

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已用流量: ${USED_GB}GB (${USAGE_PERCENT}%), 阈值: ${SWITCH_THRESHOLD_GB}GB"

if [ "$TOTAL_BYTES" -ge "$THRESHOLD_BYTES" ]; then
    TARGET_IPS="$SWITCH_IPS"
    echo "🚦 已达到切换阈值，准备切换到备用 IP 列表"
else
    TARGET_IPS="$DEFAULT_IPS"
    echo "✅ 未达到阈值，保持默认 IP 列表"
fi

# 逗号分隔字符串 -> 数组
split_ips() {
    local raw="$1"
    IFS=',' read -r -a TMP_ARR <<< "$raw"
    for item in "${TMP_ARR[@]}"; do
        item=$(echo "$item" | xargs)
        if [ -n "$item" ]; then
            echo "$item"
        fi
    done
}

# 生成 A / AAAA 目标数组
TARGET_A_IPS=()
TARGET_AAAA_IPS=()
while IFS= read -r ip; do
    if [[ "$ip" == *:* ]]; then
        TARGET_AAAA_IPS+=("$ip")
    else
        TARGET_A_IPS+=("$ip")
    fi
done < <(split_ips "$TARGET_IPS")

# 同步指定类型记录
sync_records() {
    local type="$1"
    local -n target_ips_ref="$2"

    local resp
    resp=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME&type=$type" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json")

    local success
    success=$(echo "$resp" | jq -r '.success')
    if [ "$success" != "true" ]; then
        echo "❌ 获取 $type 记录失败: $(echo "$resp" | jq -r '.errors[0].message')"
        return 1
    fi

    mapfile -t records < <(echo "$resp" | jq -r '.result[] | "\(.id)|\(.content)"')

    declare -A target_counts=()
    for ip in "${target_ips_ref[@]}"; do
        target_counts["$ip"]=$(( ${target_counts["$ip"]:-0} + 1 ))
    done

    local changed=0

    for rec in "${records[@]}"; do
        local id="${rec%%|*}"
        local ip="${rec#*|}"
        if [ "${target_counts["$ip"]:-0}" -gt 0 ]; then
            target_counts["$ip"]=$(( ${target_counts["$ip"]} - 1 ))
        else
            local del
            del=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
                 -H "Authorization: Bearer $CF_TOKEN" \
                 -H "Content-Type: application/json")
            if [ "$(echo "$del" | jq -r '.success')" == "true" ]; then
                echo "🗑️ 删除 $type 记录: $ip"
                changed=1
            else
                echo "❌ 删除 $type 记录失败: $ip, $(echo "$del" | jq -r '.errors[0].message')"
                return 1
            fi
        fi
    done

    for ip in "${!target_counts[@]}"; do
        local count=${target_counts[$ip]}
        while [ "$count" -gt 0 ]; do
            local create
            create=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                 -H "Authorization: Bearer $CF_TOKEN" \
                 -H "Content-Type: application/json" \
                 --data "{\"type\":\"$type\",\"name\":\"$RECORD_NAME\",\"content\":\"$ip\",\"proxied\":$PROXIED}")
            if [ "$(echo "$create" | jq -r '.success')" == "true" ]; then
                echo "➕ 新增 $type 记录: $ip"
                changed=1
            else
                echo "❌ 新增 $type 记录失败: $ip, $(echo "$create" | jq -r '.errors[0].message')"
                return 1
            fi
            count=$((count - 1))
        done
    done

    if [ "$changed" -eq 0 ]; then
        echo "✅ $type 记录无需调整"
    fi

    return 0
}

# 同步 A / AAAA 记录
sync_records "A" TARGET_A_IPS || exit 1
sync_records "AAAA" TARGET_AAAA_IPS || exit 1
