#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="/usr/local/bin/ssh-guard"
SENDMAIL_PATH="/usr/local/bin/sendmail.sh"
CONFIG_DIR="/etc/ssh-guard"
CONFIG_FILE="$CONFIG_DIR/mail.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

echo "[*] 安装 ssh-guard..."
install -m 755 "$SCRIPT_DIR/ssh-guard.sh" "$INSTALL_PATH"

if [ -f "$SCRIPT_DIR/sendmail.sh" ]; then
    echo "[*] 安装 sendmail.sh..."
    install -m 755 "$SCRIPT_DIR/sendmail.sh" "$SENDMAIL_PATH"
fi

echo "[*] 配置邮件服务 (smtp/resend)"
read -r -p "请选择邮件服务 [smtp/resend]: " MAIL_PROVIDER
MAIL_PROVIDER="${MAIL_PROVIDER,,}"

mkdir -p "$CONFIG_DIR"

if [ "$MAIL_PROVIDER" = "resend" ]; then
    read -r -p "请输入 Resend API Key: " RESEND_API_KEY
    read -r -p "请输入 Resend 发件人邮箱 (如 noreply@yourdomain.com): " RESEND_FROM
    cat > "$CONFIG_FILE" <<EOF
MAIL_PROVIDER=resend
RESEND_API_KEY=${RESEND_API_KEY}
RESEND_FROM=${RESEND_FROM}
EOF
    echo "[✓] Resend 配置已写入 $CONFIG_FILE"
else
    read -r -p "请输入 SMTP 发件人邮箱 (用于 From 头): " SMTP_FROM
    cat > "$CONFIG_FILE" <<EOF
MAIL_PROVIDER=smtp
SMTP_FROM=${SMTP_FROM}
EOF
    echo "[✓] SMTP 配置已写入 $CONFIG_FILE"
    echo "请确保已配置 msmtp 账号信息（例如 /etc/msmtprc 或 ~/.msmtprc）"
fi

echo "[✓] 安装完成"
echo "使用方式: $INSTALL_PATH start"
