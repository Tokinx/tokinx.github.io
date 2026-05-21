#!/bin/sh

###############################################################################
# 一键开启 SSH 密钥登录、关闭密码登录（兼容 Debian/Ubuntu/Alpine）
#
# 安全设计：
#  1. 使用 sshd_config.d/ drop-in，避免被 cloud-init 等覆盖
#  2. 公钥用 ssh-keygen 校验、自动补换行、检测私钥误粘
#  3. 两阶段流程：先写 key，要求新会话验证后才硬化 sshd
#  4. 保留 UsePAM yes（fail2ban / 账户锁定 / limits.conf 依赖之）
#  5. sshd -t 失败自动回滚
###############################################################################

set -eu

# ----------------------------- 基础检查 -----------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本" >&2
  exit 1
fi

TARGET_USER=${SUDO_USER:-root}

# 安全获取家目录（避免 eval）
USER_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
if [ -z "$USER_HOME" ] && [ -r /etc/passwd ]; then
  USER_HOME=$(awk -F: -v u="$TARGET_USER" '$1==u{print $6; exit}' /etc/passwd)
fi
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "无法定位用户 $TARGET_USER 的家目录" >&2
  exit 1
fi

TARGET_GROUP=$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
HARDEN_DIR="/etc/ssh/sshd_config.d"
HARDEN_FILE="$HARDEN_DIR/99-hardening.conf"
TS=$(date +%Y%m%d-%H%M%S)

if [ -r /etc/os-release ]; then
  . /etc/os-release 2>/dev/null || true
  [ -n "${ID:-}" ] && echo "系统: $ID ${VERSION_ID:-}"
fi
echo "目标用户: $TARGET_USER"
echo "用户目录: $USER_HOME"
echo

# --------------------- Phase 1: 写入并校验公钥 ----------------------

# StrictModes 要求 $HOME 不能被 group/other 写
chmod go-w "$USER_HOME" 2>/dev/null || true

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$TARGET_USER:$TARGET_GROUP" "$SSH_DIR"

echo "请粘贴 SSH 公钥（可多行；粘贴完成后按 Ctrl+D）："
echo "--------------------------------------------------"

TMPKEY=$(mktemp)
trap 'rm -f "$TMPKEY"' EXIT INT TERM
cat > "$TMPKEY"

echo "--------------------------------------------------"

# 空内容直接拒绝
if [ ! -s "$TMPKEY" ]; then
  echo "❌ 未读取到任何内容，已中止（authorized_keys 未修改）" >&2
  exit 1
fi

# 私钥误粘检测
if grep -qE 'BEGIN[[:space:]]+(OPENSSH|RSA|DSA|EC|PRIVATE)' "$TMPKEY"; then
  echo "❌ 检测到私钥内容，请只粘贴公钥（如 id_ed25519.pub）" >&2
  exit 1
fi

# 用 ssh-keygen 逐行校验
if command -v ssh-keygen >/dev/null 2>&1; then
  bad=0
  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    count=$((count + 1))
    if ! printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then
      preview=$(printf '%s' "$line" | cut -c1-60)
      echo "❌ 非法公钥行: ${preview}..." >&2
      bad=1
    fi
  done < "$TMPKEY"
  if [ "$bad" -ne 0 ] || [ "$count" -eq 0 ]; then
    echo "❌ 公钥校验失败，已中止（authorized_keys 未修改）" >&2
    exit 1
  fi
  echo "✅ 校验通过：$count 个公钥"
else
  # 兜底正则（无 ssh-keygen 时）
  if ! grep -qE '^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))[[:space:]]' "$TMPKEY"; then
    echo "❌ 未识别到合法公钥前缀，已中止" >&2
    exit 1
  fi
  echo "⚠️ 未找到 ssh-keygen，仅作了基本正则校验"
fi

# 规整 TMPKEY 末尾换行
if [ -n "$(tail -c1 "$TMPKEY" 2>/dev/null || true)" ]; then
  printf '\n' >> "$TMPKEY"
fi

# 规整目标文件末尾换行（避免与已有 key 粘连）
if [ -s "$AUTH_KEYS" ] && [ -n "$(tail -c1 "$AUTH_KEYS" 2>/dev/null || true)" ]; then
  printf '\n' >> "$AUTH_KEYS"
fi

cat "$TMPKEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_GROUP" "$AUTH_KEYS"

echo "✅ 公钥已写入: $AUTH_KEYS"
echo

# --------------- Phase 2: 要求验证密钥可登录后再硬化 ----------------
echo "================================================================"
echo "⚠️  请保持当前 SSH 会话不要断开！"
echo
echo "现在请【另开一个新终端】，用密钥登录："
echo "    ssh -i <your-private-key> $TARGET_USER@<server-ip>"
echo
echo "确认新密钥能成功登录后，回到本窗口继续。"
echo "================================================================"
printf '继续硬化 sshd（禁用密码登录等）？输入 yes 继续，其他取消: '
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "已取消硬化。authorized_keys 已写入，但 sshd 配置未修改。"
  exit 0
fi

# ---------------- Phase 3: 写入 drop-in 硬化配置 --------------------

# 确保主配置启用 Include（旧 Debian/Alpine 可能没有）
if [ -f "$SSHD_CONFIG" ]; then
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$SSHD_CONFIG"; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$TS"
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$SSHD_CONFIG"
    echo "已在主配置启用 Include /etc/ssh/sshd_config.d/*.conf"
    echo "  备份: ${SSHD_CONFIG}.bak.$TS"
  fi
fi

mkdir -p "$HARDEN_DIR"
chmod 755 "$HARDEN_DIR"

# 备份旧的 hardening 文件（如已存在）
HARDEN_BAK=""
if [ -f "$HARDEN_FILE" ]; then
  HARDEN_BAK="${HARDEN_FILE}.bak.$TS"
  cp "$HARDEN_FILE" "$HARDEN_BAK"
fi

cat > "$HARDEN_FILE" <<EOF
# Managed by key-login.sh — generated $TS
# 公钥认证
PubkeyAuthentication yes
AuthenticationMethods publickey

# 关闭密码与键盘交互
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no

# 关闭其他认证方式
GSSAPIAuthentication no
HostbasedAuthentication no

# Root 仅允许密钥登录（密码已禁，等同 publickey-only）
PermitRootLogin prohibit-password

# 保留 PAM：fail2ban / 账户锁定 / limits.conf 依赖之
UsePAM yes

# 暴力破解防护
MaxAuthTries 3
LoginGraceTime 30

# 会话空闲超时（约 15 分钟无响应踢出）
ClientAliveInterval 300
ClientAliveCountMax 3

# 收窄登录用户（按需打开并修改）
# AllowUsers $TARGET_USER

# 禁用转发（按需打开）
# X11Forwarding no
# AllowAgentForwarding no
# AllowTcpForwarding no
EOF
chmod 644 "$HARDEN_FILE"
echo "✅ 已写入硬化配置: $HARDEN_FILE"

# ---------------- 配置校验 + 失败自动回滚 ---------------------------
rollback() {
  echo "→ 正在回滚 $HARDEN_FILE" >&2
  rm -f "$HARDEN_FILE"
  [ -n "$HARDEN_BAK" ] && [ -f "$HARDEN_BAK" ] && mv "$HARDEN_BAK" "$HARDEN_FILE"
}

if command -v sshd >/dev/null 2>&1; then
  if ! sshd -t 2>/tmp/sshd-t.err.$$; then
    echo "❌ sshd 配置检查失败：" >&2
    sed 's/^/   /' /tmp/sshd-t.err.$$ >&2
    rm -f /tmp/sshd-t.err.$$
    rollback
    exit 1
  fi
  rm -f /tmp/sshd-t.err.$$
  echo "✅ sshd 配置检查通过"
else
  if command -v dropbear >/dev/null 2>&1 || command -v dropbearmulti >/dev/null 2>&1; then
    echo "⚠️ 系统使用 dropbear，此脚本仅写入 authorized_keys。" >&2
    echo "   请在 init 脚本中给 dropbear 加 -s（禁用密码登录）。" >&2
    exit 0
  fi
  echo "⚠️ 未找到 sshd，无法校验配置" >&2
fi

# -------------------------- 重载 SSH --------------------------------
reload_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null && return 0
    systemctl reload sshd 2>/dev/null && return 0
    systemctl restart ssh 2>/dev/null && return 0
    systemctl restart sshd 2>/dev/null && return 0
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service sshd reload 2>/dev/null && return 0
    rc-service sshd restart 2>/dev/null && return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload  2>/dev/null && return 0
    service sshd reload 2>/dev/null && return 0
    service ssh restart  2>/dev/null && return 0
    service sshd restart 2>/dev/null && return 0
  fi
  [ -x /etc/init.d/ssh ]  && /etc/init.d/ssh  restart && return 0
  [ -x /etc/init.d/sshd ] && /etc/init.d/sshd restart && return 0
  if command -v pkill >/dev/null 2>&1; then
    pkill -HUP sshd 2>/dev/null && return 0
  fi
  return 1
}

if reload_ssh; then
  echo "✅ SSH 服务已重载"
else
  echo "⚠️ 无法自动重载 SSH 服务，请手动执行：systemctl reload ssh / rc-service sshd reload" >&2
fi

echo
echo "================================================================"
echo "✅ 完成：密钥登录已启用，密码/键盘交互/Root 密码均已禁用"
echo "📄 硬化配置: $HARDEN_FILE"
[ -n "$HARDEN_BAK" ] && echo "📄 旧硬化备份: $HARDEN_BAK"
echo
echo "⚠️ 请勿断开当前会话！再开一个新终端复测一次密钥登录。"
echo "   一切正常后，再退出当前会话。"
echo
echo "如需回滚：rm $HARDEN_FILE && systemctl reload ssh"
echo "================================================================"
