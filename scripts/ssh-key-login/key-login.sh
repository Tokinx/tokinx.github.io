#!/bin/bash

# 一键开启 SSH 密钥登录、关闭密码登录

set -e

# 必须使用 root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 获取原始用户（防止 sudo 时写到 /root）
TARGET_USER=${SUDO_USER:-root}
USER_HOME=$(eval echo "~$TARGET_USER")
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

echo "目标用户: $TARGET_USER"
echo "用户目录: $USER_HOME"
echo

# 创建 .ssh 目录
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

echo "请粘贴 SSH 公钥（粘贴完成后按 Ctrl+D）："
echo "--------------------------------------------------"

# 读取公钥
cat >> "$AUTH_KEYS"

echo
echo "--------------------------------------------------"
echo "公钥已写入 $AUTH_KEYS"

chmod 600 "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS"

# 备份 sshd_config
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%T)"

# 修改 sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?UsePAM.*/UsePAM no/' "$SSHD_CONFIG"

# 如果不存在则追加
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"

# 重启 SSH 服务
if systemctl list-unit-files | grep -q ssh.service; then
  systemctl restart ssh
else
  systemctl restart sshd
fi

echo
echo "✅ SSH 密钥登录已启用，密码登录已关闭"
echo "⚠️ 请务必确认你可以使用密钥成功登录后再断开当前连接"
