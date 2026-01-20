#!/bin/sh

###############################################################################
# 一键开启 SSH 密钥登录、关闭密码登录（兼容 Debian/Alpine）
# - 使用 POSIX sh，避免对 bash 的依赖
# - 自动识别并重启 SSH 服务：systemd、OpenRC、SysV init 兼容
# - 仅修改必要项，保留其他配置不变
###############################################################################

set -e

# 必须使用 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 获取原始用户（防止 sudo 时写到 /root）
TARGET_USER=${SUDO_USER:-root}
USER_HOME=$(eval echo "~$TARGET_USER")
TARGET_GROUP=$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# 打印系统信息（用于诊断）
if [ -r /etc/os-release ]; then
  . /etc/os-release 2>/dev/null || true
  [ -n "$ID" ] && echo "系统: $ID ${VERSION_ID:-}" || true
fi

echo "目标用户: $TARGET_USER"
echo "用户目录: $USER_HOME"
echo

# 创建 .ssh 目录
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$TARGET_USER:$TARGET_GROUP" "$SSH_DIR"

echo "请粘贴 SSH 公钥（粘贴完成后按 Ctrl+D）："
echo "--------------------------------------------------"

# 读取公钥
cat >> "$AUTH_KEYS"

echo
echo "--------------------------------------------------"
echo "公钥已写入 $AUTH_KEYS"

chmod 600 "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_GROUP" "$AUTH_KEYS"

# 备份 sshd_config
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%T)"

# 修改 sshd_config（BusyBox sed 兼容写法）
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG" || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG" || true
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG" || true
sed -i 's/^#\?UsePAM.*/UsePAM no/' "$SSHD_CONFIG" || true

# 如果不存在则追加（尽量幂等）
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
grep -q "^ChallengeResponseAuthentication" "$SSHD_CONFIG" || echo "ChallengeResponseAuthentication no" >> "$SSHD_CONFIG"
grep -q "^UsePAM" "$SSHD_CONFIG" || echo "UsePAM no" >> "$SSHD_CONFIG"

# 验证配置（若支持）
if command -v sshd >/dev/null 2>&1; then
  if sshd -t >/dev/null 2>&1; then
    echo "sshd 配置检查通过"
  else
    echo "⚠️ sshd 配置检查失败，请检查 $SSHD_CONFIG" >&2
    exit 1
  fi
else
  if command -v dropbear >/dev/null 2>&1 || command -v dropbearmulti >/dev/null 2>&1; then
    echo "⚠️ 检测到未找到 OpenSSH（sshd），但系统可能使用 dropbear。此脚本未自动配置 dropbear，请手动在服务参数中禁用密码登录（通常添加 -s 选项）并确保 authorized_keys 生效。" >&2
  else
    echo "⚠️ 未找到 sshd，可继续写入 authorized_keys，但无法自动验证/重启 SSH 服务" >&2
  fi
fi

# 重启 SSH 服务（兼容 systemd / OpenRC / SysV init）
restart_ssh() {
  # 优先使用 systemd
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null && return 0
  fi

  # OpenRC（Alpine 常见）
  if command -v rc-service >/dev/null 2>&1; then
    rc-service sshd restart && return 0
  fi

  # SysV init / BusyBox service
  if command -v service >/dev/null 2>&1; then
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null && return 0
  fi

  # 直接调用 init 脚本
  if [ -x /etc/init.d/ssh ]; then
    /etc/init.d/ssh restart && return 0
  fi
  if [ -x /etc/init.d/sshd ]; then
    /etc/init.d/sshd restart && return 0
  fi

  # 兜底：向进程发送 HUP（仅在其他方式不可用时）
  if command -v pkill >/dev/null 2>&1; then
    pkill -HUP sshd 2>/dev/null && return 0
  fi
  if command -v pidof >/dev/null 2>&1; then
    PID="$(pidof sshd 2>/dev/null || true)"
    [ -n "$PID" ] && kill -HUP "$PID" 2>/dev/null && return 0
  fi

  return 1
}

if restart_ssh; then
  :
else
  echo "⚠️ 无法自动重启 SSH 服务，请手动重启（systemctl/rc-service/service）" >&2
fi

echo
echo "✅ SSH 密钥登录已启用，密码登录已关闭"
echo "⚠️ 请务必确认你可以使用密钥成功登录后再断开当前连接"
