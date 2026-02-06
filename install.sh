#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="/usr/local/bin/ssh-guard"
SENDMAIL_PATH="/usr/local/bin/sendmail.sh"
CONFIG_DIR="/etc/ssh-guard"
CONFIG_FILE="$CONFIG_DIR/mail.conf"
SSH_GUARD_CONF_FILE="$CONFIG_DIR/ssh-guard.conf"
DEFAULT_IMAGE="ghcr.io/<owner>/<repo>:latest"
IMAGE="${SSH_GUARD_IMAGE:-$DEFAULT_IMAGE}"
CONTAINER_NAME="${SSH_GUARD_CONTAINER_NAME:-ssh-guard}"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

read_with_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "$prompt [$default]: " value
    if [ -z "$value" ]; then
        value="$default"
    fi
    echo "$value"
}


choose_option() {
    local prompt="$1"
    shift
    local -a options=("$@")

    while true; do
        echo "$prompt"
        for opt in "${options[@]}"; do
            echo "  $opt"
        done
        read -r -p "请输入选项字母: " choice
        choice="${choice,,}"
        case "$choice" in
            a|b|c)
                echo "$choice"
                return 0
                ;;
            *)
                echo "[!] 无效选项: $choice，请重新输入。"
                ;;
        esac
    done
}


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

    if ! docker pull "$IMAGE"; then
        echo "[x] 拉取镜像失败: $IMAGE"
        exit 1
    fi
    mkdir -p "$CONFIG_DIR"

    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        --privileged \
        --net=host \
        -v /var/log:/var/log \
        -v "$CONFIG_DIR":"$CONFIG_DIR" \
        "$IMAGE"; then
        echo "[x] Docker 容器启动失败，请检查 Docker 日志。"
        exit 1
    fi
    echo "[✓] Docker 部署完成"
    echo "查看状态: docker logs -f $CONTAINER_NAME"
    echo "停止容器: docker stop $CONTAINER_NAME"
    exit 0
}

DEPLOY_OPTION=$(choose_option "请选择部署方式" "a) host (本机安装)" "b) docker (容器部署)" "c) 退出安装")
case "$DEPLOY_OPTION" in
    a)
        DEPLOY_MODE="host"
        ;;
    b)
        DEPLOY_MODE="docker"
        ;;
    c)
        echo "[!] 已取消安装"
        exit 0
        ;;
esac

if [ "$DEPLOY_MODE" = "docker" ]; then
    deploy_with_docker
fi

echo "[*] 安装 ssh-guard..."
if ! install -m 755 "$SCRIPT_DIR/ssh-guard.sh" "$INSTALL_PATH"; then
    echo "[x] 安装 ssh-guard 失败"
    exit 1
fi

if [ -f "$SCRIPT_DIR/sendmail.sh" ]; then
    echo "[*] 安装 sendmail.sh..."
    if ! install -m 755 "$SCRIPT_DIR/sendmail.sh" "$SENDMAIL_PATH"; then
        echo "[x] 安装 sendmail.sh 失败"
        exit 1
    fi
fi

echo "[*] 配置邮件服务"
MAIL_OPTION=$(choose_option "请选择邮件服务" "a) smtp" "b) resend" "c) 跳过邮件配置")
case "$MAIL_OPTION" in
    a)
        MAIL_PROVIDER="smtp"
        ;;
    b)
        MAIL_PROVIDER="resend"
        ;;
    c)
        MAIL_PROVIDER="none"
        ;;
esac

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
elif [ "$MAIL_PROVIDER" = "smtp" ]; then
    read -r -p "请输入 SMTP 发件人邮箱 (用于 From 头): " SMTP_FROM
    cat > "$CONFIG_FILE" <<EOF
MAIL_PROVIDER=smtp
SMTP_FROM=${SMTP_FROM}
EOF
    echo "[✓] SMTP 配置已写入 $CONFIG_FILE"
    echo "请确保已配置 msmtp 账号信息（例如 /etc/msmtprc 或 ~/.msmtprc）"
else
    cat > "$CONFIG_FILE" <<EOF
MAIL_PROVIDER=none
EOF
    echo "[!] 已跳过邮件配置，可稍后手动编辑 $CONFIG_FILE"
fi

echo "[*] 配置 ssh-guard 自定义参数（可直接回车使用默认值）"
TO_EMAIL=$(read_with_default "告警接收邮箱 TO_EMAIL" "admin@example.com")
FAILED_THRESHOLD=$(read_with_default "失败封禁阈值 FAILED_THRESHOLD" "5")
TIME_WINDOW=$(read_with_default "失败统计窗口(秒) TIME_WINDOW" "600")
BLOCK_DURATION=$(read_with_default "默认封禁时长(秒,0=永久) BLOCK_DURATION" "86400")
REPORT_INTERVAL=$(read_with_default "报告发送频率(秒) REPORT_INTERVAL" "60")
PORTSCAN_PORT_THRESHOLD=$(read_with_default "端口扫描阈值(端口数) PORTSCAN_PORT_THRESHOLD" "100")
PORTSCAN_TIME_WINDOW=$(read_with_default "端口扫描统计窗口(秒) PORTSCAN_TIME_WINDOW" "120")
PORTSCAN_BLOCK_DURATION=$(read_with_default "端口扫描封禁时长(秒,0=永久) PORTSCAN_BLOCK_DURATION" "120")
PORTSCAN_OPEN_PORT_REFRESH=$(read_with_default "开放端口刷新间隔(秒) PORTSCAN_OPEN_PORT_REFRESH" "300")
WHITELIST_IPS_EXTRA=$(read_with_default "额外白名单(空格分隔，可留空) WHITELIST_IPS_EXTRA" "")

cat > "$SSH_GUARD_CONF_FILE" <<EOF
TO_EMAIL=${TO_EMAIL}
FAILED_THRESHOLD=${FAILED_THRESHOLD}
TIME_WINDOW=${TIME_WINDOW}
BLOCK_DURATION=${BLOCK_DURATION}
REPORT_INTERVAL=${REPORT_INTERVAL}
PORTSCAN_PORT_THRESHOLD=${PORTSCAN_PORT_THRESHOLD}
PORTSCAN_TIME_WINDOW=${PORTSCAN_TIME_WINDOW}
PORTSCAN_BLOCK_DURATION=${PORTSCAN_BLOCK_DURATION}
PORTSCAN_OPEN_PORT_REFRESH=${PORTSCAN_OPEN_PORT_REFRESH}
WHITELIST_IPS_EXTRA="${WHITELIST_IPS_EXTRA}"
EOF

touch "$CONFIG_DIR/whitelist.list"

echo "[✓] ssh-guard 配置已写入 $SSH_GUARD_CONF_FILE"
echo "[✓] 可在 $CONFIG_DIR/whitelist.list 中维护额外白名单IP（每行一个）"
echo "[✓] 安装完成"
echo "使用方式: $INSTALL_PATH start"
