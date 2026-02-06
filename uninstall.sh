#!/bin/bash

set -euo pipefail

INSTALL_PATH="/usr/local/bin/ssh-guard"
SENDMAIL_PATH="/usr/local/bin/sendmail.sh"
CONFIG_DIR="/etc/ssh-guard"
CONTAINER_NAME="${SSH_GUARD_CONTAINER_NAME:-ssh-guard}"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

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

remove_if_exists() {
    local path="$1"
    if [ -e "$path" ]; then
        rm -rf "$path"
        echo "[✓] 已删除: $path"
    else
        echo "[-] 未找到: $path"
    fi
}

uninstall_host() {
    echo "[*] 卸载 host 安装..."
    remove_if_exists "$INSTALL_PATH"
    remove_if_exists "$SENDMAIL_PATH"
    remove_if_exists "$CONFIG_DIR"
    echo "[✓] host 模式卸载完成"
}

uninstall_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "[-] 未检测到 docker，跳过容器删除"
        return 0
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        docker rm -f "$CONTAINER_NAME"
        echo "[✓] 已删除容器: $CONTAINER_NAME"
    else
        echo "[-] 未找到容器: $CONTAINER_NAME"
    fi

    read -r -p "是否删除本地配置目录 $CONFIG_DIR ? [y/N]: " answer
    answer="${answer,,}"
    if [ "$answer" = "y" ] || [ "$answer" = "yes" ]; then
        remove_if_exists "$CONFIG_DIR"
    else
        echo "[*] 保留配置目录: $CONFIG_DIR"
    fi

    echo "[✓] docker 模式卸载完成"
}

UNINSTALL_OPTION=$(choose_option "请选择卸载方式" "a) host (本机安装)" "b) docker (容器部署)" "c) 全部卸载")
case "$UNINSTALL_OPTION" in
    a)
        uninstall_host
        ;;
    b)
        uninstall_docker
        ;;
    c)
        uninstall_host
        uninstall_docker
        ;;
esac
