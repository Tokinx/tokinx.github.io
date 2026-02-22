#!/bin/bash

# ================= 配置区 =================
# Cloudflare 认证信息
CF_TOKEN="你的_API_TOKEN"
ZONE_ID="你的_ZONE_ID"

# 域名全称 (如 test.example.com)
RECORD_NAME="test.example.com"

# 时间与 IP 对应关系 (格式: "HH:MM@IP")
# 脚本会按时间顺序自动匹配当前应生效的 IP
SCHEDULE=(
    "08:00@1.1.1.1"
    "20:00@2.2.2.2"
    "23:30@3.3.3.3"
)

# 是否开启 Cloudflare 代理 (true/false)
PROXIED=false
# ==========================================

# 检查是否安装了 jq
if ! command -v jq &> /dev/null; then
    echo "错误: 未检测到 jq 工具，请先安装 (sudo apt install jq 或 yum install jq)"
    exit 1
fi

# 获取当前时间 (HH:MM)
CURRENT_TIME=$(date +"%H:%M")

# 获取目标 IP 的逻辑
TARGET_IP=""
# 将数组按时间排序处理
SORTED_SCHEDULE=$(printf "%s\n" "${SCHEDULE[@]}" | sort)

for entry in $SORTED_SCHEDULE; do
    CONF_TIME=$(echo $entry | cut -d'@' -f1)
    CONF_IP=$(echo $entry | cut -d'@' -f2)
    
    # 只要当前时间大于等于配置时间，就更新目标IP（循环到最后就是当前最匹配的）
    if [[ "$CURRENT_TIME" > "$CONF_TIME" ]] || [[ "$CURRENT_TIME" == "$CONF_TIME" ]]; then
        TARGET_IP=$CONF_IP
    fi
done

# 边界情况：如果当前时间比列表里最早的时间还早（比如凌晨），则取列表最后一个 IP (即前一天最后的时段)
if [ -z "$TARGET_IP" ]; then
    TARGET_IP=$(echo "$SORTED_SCHEDULE" | tail -n 1 | cut -d'@' -f2)
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 当前时间: $CURRENT_TIME, 目标 IP 应为: $TARGET_IP"

# 1. 获取该域名在 CF 上的 Record ID 和当前 IP
RECORD_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME&type=A" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json")

RECORD_ID=$(echo $RECORD_INFO | jq -r '.result[0].id')
CURRENT_CF_IP=$(echo $RECORD_INFO | jq -r '.result[0].content')

if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
    echo "❌ 错误: 无法在 Cloudflare 上找到域名 $RECORD_NAME 的 A 记录。"
    exit 1
fi

# 2. 判断是否需要执行更新
if [ "$TARGET_IP" == "$CURRENT_CF_IP" ]; then
    echo "✅ 当前 CF 记录 IP 已是 $TARGET_IP，无需改动。"
    exit 0
fi

# 3. 调用 API 执行更新
echo "🔄 正在将 $RECORD_NAME 指向 $TARGET_IP..."
UPDATE_RESULT=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"content\": \"$TARGET_IP\", \"proxied\": $PROXIED}")

if [[ $(echo $UPDATE_RESULT | jq -r '.success') == "true" ]]; then
    echo "🚀 切换成功！"
else
    echo "❌ 切换失败，错误信息: $(echo $UPDATE_RESULT | jq -r '.errors[0].message')"
fi