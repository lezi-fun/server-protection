#!/bin/bash
# /usr/local/bin/ssh-guard.sh

# ==================== 配置区域 ====================
# 这里修改配置即可，不需要修改系统配置
TO_EMAIL="admin@568131.xyz"          # 接收警报的邮箱
HOSTNAME=$(hostname)                 # 主机名
SCRIPT_NAME=$(basename "$0")         # 脚本名

# 防护配置
FAILED_THRESHOLD=5      # 触发封禁的失败次数
TIME_WINDOW=600          # 统计时间窗口（秒）
BLOCK_DURATION=86400     # 封禁时长（秒），86400=24小时
REPORT_INTERVAL=60       # 报告间隔（秒）
CLEANUP_INTERVAL=3600    # 清理间隔（秒）

# 端口扫描防护配置
PORTSCAN_PORT_THRESHOLD=100   # 触发封禁的不同端口数量
PORTSCAN_TIME_WINDOW=120      # 端口扫描时间窗口（秒）
PORTSCAN_BLOCK_DURATION=120   # 端口扫描封禁时长（秒）
PORTSCAN_OPEN_PORT_REFRESH=300 # 开放端口刷新间隔（秒）

# 白名单IP（不会被封禁）
WHITELIST_IPS=("127.0.0.1" "::1" "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12")

# 日志目录
LOG_DIR="/var/log/ssh-guardian"
LOCK_DIR="/tmp/ssh-guardian"
# ==================== 配置结束 ====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 初始化函数
init_system() {
    echo -e "${BLUE}[*] 初始化SSH防护系统...${NC}"
    
    # 创建目录
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOCK_DIR"
    
    # 创建日志文件
    touch "$LOG_DIR/failed.log"      # 失败登录记录
    touch "$LOG_DIR/blocked.log"     # 封禁记录
    touch "$LOG_DIR/report.log"      # 报告记录
    touch "$LOG_DIR/email.log"       # 邮件发送记录
    touch "$LOG_DIR/status.log"      # 状态记录
    touch "$LOG_DIR/portscan.log"    # 端口扫描记录
    
    # 创建封禁列表文件
    touch "$LOG_DIR/blocked.list"
    
    echo -e "${GREEN}[✓] 初始化完成${NC}"
}

# 发送邮件函数（使用您的sendmail.sh）
send_email() {
    local subject="$1"
    local body="$2"
    local priority="${3:-normal}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local temp_dir="/tmp/ssh-guardian-mail"
    
    mkdir -p "$temp_dir"
    
    # 创建临时文件
    local title_file="$temp_dir/title_$(date +%s).txt"
    local body_file="$temp_dir/body_$(date +%s).txt"
    
    # 写入标题和内容
    echo "$subject" > "$title_file"
    echo -e "$body" > "$body_file"
    
    # 发送邮件
    if /usr/local/bin/sendmail.sh "$title_file" "$body_file" "$TO_EMAIL" 2>/dev/null; then
        echo "$timestamp - 邮件发送成功: $subject" >> "$LOG_DIR/email.log"
        
        # 清理临时文件
        rm -f "$title_file" "$body_file"
        return 0
    else
        echo "$timestamp - 邮件发送失败: $subject" >> "$LOG_DIR/email.log"
        
        # 清理临时文件
        rm -f "$title_file" "$body_file"
        return 1
    fi
}

# 发送测试邮件
send_test_email() {
    local subject="🔧 SSH防护系统测试 - $HOSTNAME"
    local body="这是一封测试邮件\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')\n服务器: $HOSTNAME\n如果收到此邮件，说明SSH防护系统配置成功！"
    
    send_email "$subject" "$body"
}

# 检查IP是否在白名单
is_whitelisted() {
    local ip="$1"
    
    # 检查精确匹配
    for white_ip in "${WHITELIST_IPS[@]}"; do
        if [ "$ip" = "$white_ip" ]; then
            return 0
        fi
        
        # 检查CIDR范围
        if [[ "$white_ip" == *"/"* ]]; then
            if [[ "$ip" == 192.168.* ]] && [[ "$white_ip" == "192.168.0.0/16" ]]; then
                return 0
            fi
            if [[ "$ip" == 10.* ]] && [[ "$white_ip" == "10.0.0.0/8" ]]; then
                return 0
            fi
            if [[ "$ip" == 172.1[6-9].* ]] || [[ "$ip" == 172.2[0-9].* ]] || [[ "$ip" == 172.3[0-1].* ]] && [[ "$white_ip" == "172.16.0.0/12" ]]; then
                return 0
            fi
        fi
    done
    
    return 1
}

# 检查IP是否已被封禁
is_ip_blocked() {
    local ip="$1"
    
    # 检查iptables规则
    if iptables -L INPUT -n 2>/dev/null | grep -q "DROP.*$ip"; then
        return 0
    fi
    
    # 检查封禁记录文件
    if [ -f "$LOG_DIR/blocked.list" ] && grep -q "^$ip|" "$LOG_DIR/blocked.list" 2>/dev/null; then
        # 检查是否过期
        local line=$(grep "^$ip|" "$LOG_DIR/blocked.list" 2>/dev/null)
        if [ -n "$line" ]; then
            local block_until=$(echo "$line" | cut -d'|' -f3)
            local current_time=$(date +%s)
            
            if [ "$block_until" = "permanent" ] || [ "$block_until" -gt "$current_time" ]; then
                return 0
            else
                # 已过期，解封
                unblock_ip "$ip" "过期自动解封"
                return 1
            fi
        fi
    fi
    
    return 1
}

# 封禁IP
block_ip() {
    local ip="$1"
    local reason="$2"
    local count="$3"
    local block_duration="${4:-$BLOCK_DURATION}"
    
    # 检查白名单
    if is_whitelisted "$ip"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 跳过白名单IP: $ip" >> "$LOG_DIR/skipped.log"
        return 1
    fi
    
    # 检查是否已封禁
    if is_ip_blocked "$ip"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - IP已封禁: $ip" >> "$LOG_DIR/skipped.log"
        return 1
    fi
    
    # 计算解封时间
    local block_until="permanent"
    if [ "$block_duration" -gt 0 ]; then
        block_until=$(($(date +%s) + block_duration))
    fi
    
    # 添加到封禁列表
    echo "$ip|$(date '+%Y-%m-%d %H:%M:%S')|$block_until|$reason|$count" >> "$LOG_DIR/blocked.list"
    
    # 添加到iptables
    iptables -I INPUT -s "$ip" -j DROP 2>/dev/null
    
    # 记录日志
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - 封禁IP: $ip (原因: $reason, 失败次数: $count)" >> "$LOG_DIR/blocked.log"
    
    echo -e "${RED}[!] 已封禁IP: $ip${NC}"
    
    # 发送邮件通知
    local subject="🚨 安全警报 - $ip 已被封禁"
    local body="IP地址: $ip\n封禁时间: $timestamp\n封禁原因: $reason\n触发次数: $count\n服务器: $HOSTNAME\n\n"
    
    if [ "$block_until" != "permanent" ]; then
        body+="解封时间: $(date -d @"$block_until" '+%Y-%m-%d %H:%M:%S')\n"
    else
        body+="封禁类型: 永久封禁\n"
    fi
    
    body+="\n建议操作:\n1. 检查是否有合法用户被误封\n2. 如需解封，请使用命令: ${SCRIPT_NAME} unblock $ip"
    
    # 异步发送邮件，不阻塞主进程
    ( send_email "$subject" "$body" "high" ) &
    
    return 0
}

# 解封IP
unblock_ip() {
    local ip="$1"
    local reason="$2"
    
    # 从iptables移除
    iptables -D INPUT -s "$ip" -j DROP 2>/dev/null
    
    # 从封禁列表移除
    if [ -f "$LOG_DIR/blocked.list" ]; then
        grep -v "^$ip|" "$LOG_DIR/blocked.list" > "$LOG_DIR/blocked.list.tmp"
        mv "$LOG_DIR/blocked.list.tmp" "$LOG_DIR/blocked.list"
    fi
    
    # 记录日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 解封IP: $ip (原因: $reason)" >> "$LOG_DIR/unblocked.log"
    
    echo -e "${GREEN}[✓] 已解封IP: $ip${NC}"
    
    return 0
}

# 清理过期封禁
cleanup_expired_blocks() {
    local current_time=$(date +%s)
    local cleaned=0
    
    if [ -f "$LOG_DIR/blocked.list" ]; then
        while IFS='|' read -r ip timestamp block_until reason count; do
            if [ -n "$ip" ] && [ "$block_until" != "permanent" ] && [ "$block_until" -lt "$current_time" ]; then
                unblock_ip "$ip" "过期自动解封"
                cleaned=$((cleaned + 1))
            fi
        done < "$LOG_DIR/blocked.list"
    fi
    
    if [ "$cleaned" -gt 0 ]; then
        echo "$(date) - 清理了 $cleaned 个过期封禁" >> "$LOG_DIR/status.log"
    fi
}

# 生成并发送报告
generate_report() {
    local report_file="$1"
    
    if [ ! -s "$report_file" ]; then
        return 0
    fi
    
    # 清理过期封禁
    cleanup_expired_blocks
    
    # 生成报告标题
    local timestamp=$(date '+%Y年%m月%d日 %H:%M')
    local subject="📊 SSH防护报告 - $HOSTNAME ($timestamp)"
    
    # 生成报告内容
    local body="SSH防护系统报告\n"
    body+="================\n"
    body+="报告时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    body+="服务器: $HOSTNAME\n"
    body+="运行时长: $(get_uptime)\n\n"
    
    # 添加报告内容
    body+=$(cat "$report_file")
    
    # 添加封禁统计
    body+="\n📈 封禁统计:\n"
    if [ -f "$LOG_DIR/blocked.list" ]; then
        local blocked_count=$(wc -l < "$LOG_DIR/blocked.list" 2>/dev/null || echo 0)
        body+="当前封禁IP数: $blocked_count\n"
    else
        body+="当前封禁IP数: 0\n"
    fi
    
    # 添加系统状态
    body+="\n🔧 系统状态:\n"
    body+="内存使用: $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2}')\n"
    body+="磁盘使用: $(df -h / | awk 'NR==2{print $5}')\n"
    body+="负载平均: $(uptime | awk -F'load average:' '{print $2}')\n"
    
    # 发送报告
    send_email "$subject" "$body"
    
    # 记录报告发送
    echo "$(date) - 发送报告" >> "$LOG_DIR/report.log"
    
    # 清空报告文件
    > "$report_file"
}

# 获取系统运行时间
get_uptime() {
    if [ -f /proc/uptime ]; then
        local uptime_seconds=$(awk '{print $1}' /proc/uptime)
        local days=$((uptime_seconds / 86400))
        local hours=$((uptime_seconds % 86400 / 3600))
        local minutes=$((uptime_seconds % 3600 / 60))
        
        if [ "$days" -gt 0 ]; then
            echo "${days}天${hours}小时${minutes}分钟"
        else
            echo "${hours}小时${minutes}分钟"
        fi
    else
        echo "未知"
    fi
}

# 刷新本机IP列表
refresh_local_ips() {
    LOCAL_IPS=()
    while read -r ip; do
        [ -n "$ip" ] && LOCAL_IPS+=("$ip")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    LOCAL_IPS+=("127.0.0.1")
}

# 判断是否为本机IP
is_local_ip() {
    local ip="$1"

    for local_ip in "${LOCAL_IPS[@]}"; do
        if [ "$ip" = "$local_ip" ]; then
            return 0
        fi
    done

    return 1
}

# 刷新开放端口列表
refresh_open_tcp_ports() {
    OPEN_TCP_PORTS=()
    if command -v ss >/dev/null 2>&1; then
        while read -r port; do
            [ -n "$port" ] && OPEN_TCP_PORTS["$port"]=1
        done < <(ss -tuln | awk 'NR>1 {print $5}' | awk -F':' '{print $NF}' | sort -u)
    elif command -v netstat >/dev/null 2>&1; then
        while read -r port; do
            [ -n "$port" ] && OPEN_TCP_PORTS["$port"]=1
        done < <(netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | awk -F':' '{print $NF}' | sort -u)
    else
        echo "$(date) - 警告: 未找到 ss 或 netstat，无法刷新开放端口列表" >> "$LOG_DIR/status.log"
    fi
}

# 监控端口扫描
monitor_port_scans() {
    local report_file="$1"

    if ! command -v tcpdump >/dev/null 2>&1; then
        echo "$(date) - 警告: 未找到 tcpdump，无法启用端口扫描监控" >> "$LOG_DIR/status.log"
        return 0
    fi

    declare -A scan_port_times
    declare -A OPEN_TCP_PORTS
    declare -a LOCAL_IPS
    local last_cleanup_time=$(date +%s)
    local last_port_refresh=0
    local last_local_refresh=0

    refresh_open_tcp_ports
    refresh_local_ips
    last_port_refresh=$(date +%s)
    last_local_refresh=$(date +%s)

    tcpdump -l -nn -i any 'tcp[tcpflags] & (tcp-syn) != 0 and tcp[tcpflags] & (tcp-ack) == 0' 2>/dev/null | while read -r line; do
        local current_time
        current_time=$(date +%s)

        if [ $((current_time - last_port_refresh)) -ge "$PORTSCAN_OPEN_PORT_REFRESH" ]; then
            refresh_open_tcp_ports
            last_port_refresh=$current_time
        fi

        if [ $((current_time - last_local_refresh)) -ge "$PORTSCAN_OPEN_PORT_REFRESH" ]; then
            refresh_local_ips
            last_local_refresh=$current_time
        fi

        if [ $((current_time - last_cleanup_time)) -ge "$PORTSCAN_TIME_WINDOW" ]; then
            for key in "${!scan_port_times[@]}"; do
                if [ $((current_time - scan_port_times[$key])) -gt "$PORTSCAN_TIME_WINDOW" ]; then
                    unset scan_port_times["$key"]
                fi
            done
            last_cleanup_time=$current_time
        fi

        local src
        local dst_port
        src=$(echo "$line" | awk '{print $3}' | sed 's/\.[0-9]*$//')
        dst_port=$(echo "$line" | awk '{print $5}' | sed 's/.*\.//; s/://')

        if [ -z "$src" ] || [ -z "$dst_port" ]; then
            continue
        fi

        if is_local_ip "$src"; then
            continue
        fi

        if is_whitelisted "$src"; then
            continue
        fi

        if is_ip_blocked "$src"; then
            continue
        fi

        if [ -n "${OPEN_TCP_PORTS[$dst_port]}" ]; then
            continue
        fi

        local key="${src}|${dst_port}"
        if [ -z "${scan_port_times[$key]}" ]; then
            scan_port_times["$key"]=$current_time
        fi

        local count=0
        for k in "${!scan_port_times[@]}"; do
            if [[ "$k" == "$src|"* ]]; then
                if [ $((current_time - scan_port_times[$k])) -le "$PORTSCAN_TIME_WINDOW" ]; then
                    count=$((count + 1))
                else
                    unset scan_port_times["$k"]
                fi
            fi
        done

        if [ "$count" -ge "$PORTSCAN_PORT_THRESHOLD" ]; then
            if block_ip "$src" "端口扫描" "$count" "$PORTSCAN_BLOCK_DURATION"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 端口扫描封禁: IP=$src, 端口数=$count" >> "$LOG_DIR/portscan.log"
                echo "🚫 封禁IP: $src" >> "$report_file"
                echo "   原因: 端口扫描" >> "$report_file"
                echo "   扫描端口数: $count" >> "$report_file"
                echo "   封禁时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$report_file"
                echo "" >> "$report_file"

                for k in "${!scan_port_times[@]}"; do
                    if [[ "$k" == "$src|"* ]]; then
                        unset scan_port_times["$k"]
                    fi
                done
            fi
        fi
    done
}

# 监控SSH登录
monitor_ssh() {
    echo -e "${BLUE}[*] 开始监控SSH登录...${NC}"
    echo "接收邮箱: $TO_EMAIL"
    echo "报告间隔: ${REPORT_INTERVAL}秒"
    echo "封禁阈值: ${FAILED_THRESHOLD}次/${TIME_WINDOW}秒"
    echo "端口扫描阈值: ${PORTSCAN_PORT_THRESHOLD}个端口/${PORTSCAN_TIME_WINDOW}秒"
    
    # 找到认证日志文件
    local log_file="/var/log/auth.log"
    [ ! -f "$log_file" ] && log_file="/var/log/secure"
    
    if [ ! -f "$log_file" ]; then
        echo -e "${RED}[!] 错误: 找不到认证日志文件${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[✓] 监控日志: $log_file${NC}"
    
    # 初始化变量
    declare -A fail_count
    declare -A first_fail_time
    local last_report_time=$(date +%s)
    local last_cleanup_time=$(date +%s)
    local report_file="/tmp/ssh_report_$$.txt"
    local portscan_pid=""
    
    # 清理函数
    cleanup() {
        echo -e "\n${YELLOW}[!] 正在停止监控...${NC}"
        if [ -n "$portscan_pid" ]; then
            kill "$portscan_pid" 2>/dev/null
        fi
        rm -f "$report_file"
        echo -e "${GREEN}[✓] 监控已停止${NC}"
        exit 0
    }
    
    trap cleanup SIGINT SIGTERM
    
    # 开始监控
    echo -e "${GREEN}[✓] 开始监控，按 Ctrl+C 停止${NC}"

    monitor_port_scans "$report_file" &
    portscan_pid=$!
    
    tail -n 0 -F "$log_file" | while read line; do
        local current_time=$(date +%s)
        
        # 定期清理
        if [ $((current_time - last_cleanup_time)) -ge "$CLEANUP_INTERVAL" ]; then
            # 清理过期的失败记录
            for ip in "${!first_fail_time[@]}"; do
                if [ $((current_time - first_fail_time["$ip"])) -gt "$TIME_WINDOW" ]; then
                    unset fail_count["$ip"]
                    unset first_fail_time["$ip"]
                fi
            done
            last_cleanup_time=$current_time
        fi
        
        # 检查是否需要发送报告
        if [ $((current_time - last_report_time)) -ge "$REPORT_INTERVAL" ]; then
            if [ -s "$report_file" ]; then
                generate_report "$report_file"
            fi
            last_report_time=$current_time
        fi
        
        # 检测失败登录
        if echo "$line" | grep -qi "Failed password\|authentication failure"; then
            local ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            local user=$(echo "$line" | grep -o "for .* from" | sed 's/for //; s/ from//' | awk '{print $1}' 2>/dev/null || echo "unknown")
            
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "::1" ]; then
                # 记录失败日志
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 失败登录: IP=$ip, 用户=$user" >> "$LOG_DIR/failed.log"
                
                # 更新失败计数
                if [ -z "${first_fail_time[$ip]}" ]; then
                    first_fail_time["$ip"]=$current_time
                    fail_count["$ip"]=1
                else
                    fail_count["$ip"]=$((fail_count["$ip"] + 1))
                fi
                
                local count=${fail_count["$ip"]}
                
                # 检查是否需要封禁
                if [ "$count" -ge "$FAILED_THRESHOLD" ]; then
                    # 检查时间窗口
                    local first_time=${first_fail_time["$ip"]}
                    local time_diff=$((current_time - first_time))
                    
                    if [ "$time_diff" -le "$TIME_WINDOW" ]; then
                        # 封禁IP
                        if block_ip "$ip" "SSH暴力破解" "$count"; then
                            # 添加到报告
                            echo "🚫 封禁IP: $ip" >> "$report_file"
                            echo "   原因: SSH暴力破解" >> "$report_file"
                            echo "   失败次数: $count" >> "$report_file"
                            echo "   封禁时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$report_file"
                            echo "" >> "$report_file"
                            
                            # 重置计数器
                            unset fail_count["$ip"]
                            unset first_fail_time["$ip"]
                        fi
                    fi
                elif [ "$count" -eq 5 ]; then
                    # 警告级别，添加到报告
                    echo "⚠️ 警告: IP $ip 有 $count 次失败登录" >> "$report_file"
                fi
            fi
        fi
        
        # 检测成功登录（重置计数器）
        if echo "$line" | grep -qi "Accepted password\|session opened"; then
            local ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            
            if [ -n "$ip" ] && [ -n "${fail_count[$ip]}" ]; then
                # 成功登录，重置该IP的失败计数
                unset fail_count["$ip"]
                unset first_fail_time["$ip"]
                echo "$(date) - 成功登录，重置IP: $ip 的计数器" >> "$LOG_DIR/reset.log"
            fi
        fi
    done
}

# 显示状态
show_status() {
    echo -e "${BLUE}=== SSH防护系统状态 ===${NC}"
    echo ""
    
    # 系统信息
    echo -e "${YELLOW}[系统信息]${NC}"
    echo "服务器: $HOSTNAME"
    echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "运行时长: $(get_uptime)"
    echo "接收邮箱: $TO_EMAIL"
    echo "封禁阈值: ${FAILED_THRESHOLD}次/${TIME_WINDOW}秒"
    
    echo ""
    
    # 当前封禁列表
    echo -e "${YELLOW}[当前封禁的IP]${NC}"
    if [ -f "$LOG_DIR/blocked.list" ] && [ -s "$LOG_DIR/blocked.list" ]; then
        while IFS='|' read -r ip timestamp block_until reason count; do
            if [ -n "$ip" ]; then
                echo -n "IP: $ip, 原因: $reason, 失败次数: $count"
                if [ "$block_until" = "permanent" ]; then
                    echo ", 永久封禁"
                else
                    echo ", 解封时间: $(date -d @"$block_until" '+%Y-%m-%d %H:%M:%S')"
                fi
            fi
        done < "$LOG_DIR/blocked.list"
    else
        echo "无封禁IP"
    fi
    
    echo ""
    
    # iptables规则
    echo -e "${YELLOW}[iptables封禁规则]${NC}"
    iptables -L INPUT -n 2>/dev/null | grep DROP | grep -v "0.0.0.0/0" | while read line; do
        echo "  $line"
    done || echo "  无法访问iptables或没有规则"
    
    echo ""
    
    # 最近日志
    echo -e "${YELLOW}[最近失败登录]${NC}"
    tail -5 "$LOG_DIR/failed.log" 2>/dev/null || echo "无失败记录"
    
    echo ""
    
    # 邮件发送状态
    echo -e "${YELLOW}[邮件发送状态]${NC}"
    tail -3 "$LOG_DIR/email.log" 2>/dev/null || echo "无邮件记录"
}

# 管理命令
manage_commands() {
    case "$1" in
        "start")
            init_system
            echo -e "${GREEN}[✓] 启动监控...${NC}"
            monitor_ssh
            ;;
        "stop")
            pkill -f "${SCRIPT_NAME} start"
            echo -e "${YELLOW}[!] 已停止监控${NC}"
            ;;
        "status")
            show_status
            ;;
        "test")
            echo -e "${BLUE}[*] 发送测试邮件...${NC}"
            send_test_email
            echo -e "${GREEN}[✓] 测试邮件已发送到: $TO_EMAIL${NC}"
            ;;
        "block")
            if [ -z "$2" ]; then
                echo "用法: $0 block <IP地址> [原因]"
                return 1
            fi
            local ip="$2"
            local reason="${3:-手动封禁}"
            block_ip "$ip" "$reason" "manual"
            ;;
        "unblock")
            if [ -z "$2" ]; then
                echo "用法: $0 unblock <IP地址>"
                return 1
            fi
            local ip="$2"
            unblock_ip "$ip" "手动解封"
            ;;
        "list")
            echo -e "${YELLOW}封禁列表:${NC}"
            if [ -f "$LOG_DIR/blocked.list" ] && [ -s "$LOG_DIR/blocked.list" ]; then
                cat "$LOG_DIR/blocked.list"
            else
                echo "无封禁记录"
            fi
            ;;
        "clear")
            echo -e "${YELLOW}[!] 清除所有封禁...${NC}"
            if [ -f "$LOG_DIR/blocked.list" ]; then
                while read -r line; do
                    local ip=$(echo "$line" | cut -d'|' -f1)
                    [ -n "$ip" ] && unblock_ip "$ip" "批量清除"
                done < "$LOG_DIR/blocked.list"
            fi
            echo -e "${GREEN}[✓] 已清除所有封禁${NC}"
            ;;
        "logs")
            echo -e "${BLUE}查看实时日志...${NC}"
            tail -f "$LOG_DIR/failed.log"
            ;;
        "config")
            echo -e "${YELLOW}当前配置:${NC}"
            echo "TO_EMAIL: $TO_EMAIL"
            echo "HOSTNAME: $HOSTNAME"
            echo "FAILED_THRESHOLD: $FAILED_THRESHOLD"
            echo "TIME_WINDOW: $TIME_WINDOW"
            echo "BLOCK_DURATION: $BLOCK_DURATION"
            echo "REPORT_INTERVAL: $REPORT_INTERVAL"
            echo "PORTSCAN_PORT_THRESHOLD: $PORTSCAN_PORT_THRESHOLD"
            echo "PORTSCAN_TIME_WINDOW: $PORTSCAN_TIME_WINDOW"
            echo "PORTSCAN_BLOCK_DURATION: $PORTSCAN_BLOCK_DURATION"
            echo "PORTSCAN_OPEN_PORT_REFRESH: $PORTSCAN_OPEN_PORT_REFRESH"
            echo "WHITELIST_IPS: ${WHITELIST_IPS[*]}"
            echo "LOG_DIR: $LOG_DIR"
            echo "LOCK_DIR: $LOCK_DIR"
            ;;
        "help")
            echo -e "${BLUE}=== SSH防护系统帮助 ===${NC}"
            echo ""
            echo "用法: $0 {start|stop|status|test|block|unblock|list|clear|logs|config|help}"
            echo ""
            echo "命令说明:"
            echo "  start     启动监控"
            echo "  stop      停止监控"
            echo "  status    查看系统状态"
            echo "  test      发送测试邮件"
            echo "  block     手动封禁IP (示例: $0 block 1.2.3.4 '恶意扫描')"
            echo "  unblock   手动解封IP (示例: $0 unblock 1.2.3.4)"
            echo "  list      查看封禁列表"
            echo "  clear     清除所有封禁"
            echo "  logs      查看实时日志"
            echo "  config    查看配置"
            echo "  help      显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0 start              # 启动监控"
            echo "  $0 test               # 测试邮件发送"
            echo "  $0 status             # 查看系统状态"
            echo "  $0 block 1.2.3.4      # 封禁IP"
            echo "  $0 logs               # 查看实时日志"
            ;;
        *)
            echo "未知命令: $1"
            echo "使用: $0 help 查看帮助"
            ;;
    esac
}

# 主函数
main() {
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[!] 错误: 此脚本需要root权限运行${NC}"
        exit 1
    fi
    
    if [ $# -eq 0 ]; then
        manage_commands "help"
        exit 1
    fi
    
    manage_commands "$@"
}

# 运行主函数
main "$@"
