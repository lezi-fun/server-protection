#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="/usr/local/bin/ssh-guard"
SENDMAIL_PATH="/usr/local/bin/sendmail.sh"
CONFIG_DIR="/etc/ssh-guard"
CONFIG_FILE="$CONFIG_DIR/mail.conf"
DEFAULT_IMAGE="ghcr.io/<owner>/<repo>:latest"
IMAGE="${SSH_GUARD_IMAGE:-$DEFAULT_IMAGE}"
CONTAINER_NAME="${SSH_GUARD_CONTAINER_NAME:-ssh-guard}"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

deploy_with_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未找到 docker 命令，请先安装 Docker。"
        exit 1
    fi

    echo "[*] 使用 Docker 部署 ssh-guard..."
    echo "镜像: $IMAGE"
    echo "容器名: $CONTAINER_NAME"

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "[*] 发现已存在的容器 $CONTAINER_NAME，正在替换..."
        docker rm -f "$CONTAINER_NAME"
    fi

    docker pull "$IMAGE"
    mkdir -p "$CONFIG_DIR"

    docker run -d \
        --name "$CONTAINER_NAME" \
        --privileged \
        --net=host \
        -v /var/log:/var/log \
        -v "$CONFIG_DIR":"$CONFIG_DIR" \
        "$IMAGE"

    echo "[✓] Docker 部署完成"
    echo "查看状态: docker logs -f $CONTAINER_NAME"
    echo "停止容器: docker stop $CONTAINER_NAME"
    exit 0
}

read -r -p "请选择部署方式 [host/docker]: " DEPLOY_MODE
DEPLOY_MODE="${DEPLOY_MODE,,}"

if [ "$DEPLOY_MODE" = "docker" ]; then
    deploy_with_docker
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
