#!/bin/bash
# send_email.sh - 使用msmtp发送邮件的脚本
# 用法: ./send_email.sh title.txt body.txt recipient@example.com

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 帮助信息
show_help() {
    echo -e "${GREEN}邮件发送脚本${NC}"
    echo "用法: $0 [选项] <标题文件> <正文文件> <收件人邮箱>"
    echo ""
    echo "选项:"
    echo "  -h, --help         显示此帮助信息"
    echo "  -v, --verbose      显示详细输出"
    echo "  -d, --debug        启用调试模式"
    echo "  -a, --attachment   添加附件 (可多次使用)"
    echo "                     示例: -a file1.pdf -a file2.jpg"
    echo "  -c, --cc           抄送收件人 (可多次使用)"
    echo "  -b, --bcc          密送收件人 (可多次使用)"
    echo "  -s, --sender       指定发件人邮箱"
    echo "  -f, --from-name    指定发件人名称"
    echo ""
    echo "示例:"
    echo "  $0 title.txt body.txt user@example.com"
    echo "  $0 -v title.txt body.txt user@example.com"
    echo "  $0 -a report.pdf -a data.csv title.txt body.txt user@example.com"
    echo "  $0 -c cc@example.com -b bcc@example.com title.txt body.txt user@example.com"
}

# 检查依赖
check_dependencies() {
    if ! command -v msmtp &> /dev/null; then
        echo -e "${RED}错误: 未找到 msmtp 命令${NC}"
        echo "请安装 msmtp:"
        echo "  Ubuntu/Debian: sudo apt install msmtp msmtp-mta"
        echo "  CentOS/RHEL: sudo yum install msmtp"
        exit 1
    fi
    
    if ! command -v mutt &> /dev/null && [[ ${#attachments[@]} -gt 0 ]]; then
        echo -e "${YELLOW}警告: 未找到 mutt 命令，将无法发送附件${NC}"
        echo "请安装 mutt 以支持附件功能:"
        echo "  Ubuntu/Debian: sudo apt install mutt"
        echo "  CentOS/RHEL: sudo yum install mutt"
    fi
}

# 初始化变量
verbose=false
debug=false
attachments=()
cc_recipients=()
bcc_recipients=()
sender=""
from_name=""

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -d|--debug)
                debug=true
                verbose=true
                shift
                ;;
            -a|--attachment)
                attachments+=("$2")
                shift 2
                ;;
            -c|--cc)
                cc_recipients+=("$2")
                shift 2
                ;;
            -b|--bcc)
                bcc_recipients+=("$2")
                shift 2
                ;;
            -s|--sender)
                sender="$2"
                shift 2
                ;;
            -f|--from-name)
                from_name="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                show_help
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # 获取必需参数
    if [[ $# -lt 3 ]]; then
        echo -e "${RED}错误: 参数不足${NC}"
        show_help
        exit 1
    fi
    
    title_file="$1"
    body_file="$2"
    recipient="$3"
}

# 验证文件存在
validate_files() {
    if [[ ! -f "$title_file" ]]; then
        echo -e "${RED}错误: 标题文件不存在: $title_file${NC}"
        exit 1
    fi
    
    if [[ ! -f "$body_file" ]]; then
        echo -e "${RED}错误: 正文文件不存在: $body_file${NC}"
        exit 1
    fi
    
    # 验证附件文件
    for attachment in "${attachments[@]}"; do
        if [[ ! -f "$attachment" ]]; then
            echo -e "${RED}错误: 附件文件不存在: $attachment${NC}"
            exit 1
        fi
    done
    
    # 验证邮箱格式
    if ! [[ "$recipient" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo -e "${YELLOW}警告: 收件人邮箱格式可能不正确: $recipient${NC}"
    fi
}

# 创建临时邮件文件
create_email_file() {
    # 创建临时文件
    email_file=$(mktemp /tmp/email_XXXXXXXXXX.eml)
    
    # 读取标题和正文
    subject=$(cat "$title_file" | tr -d '\n\r')
    body=$(cat "$body_file")
    
    # 构建发件人字符串
    if [[ -n "$from_name" && -n "$sender" ]]; then
        from_header="From: \"$from_name\" <$sender>"
    elif [[ -n "$sender" ]]; then
        from_header="From: $sender"
    else
        from_header=""
    fi
    
    # 构建邮件头
    {
        echo "To: $recipient"
        if [[ -n "$from_header" ]]; then
            echo "$from_header"
        fi
        if [[ ${#cc_recipients[@]} -gt 0 ]]; then
            echo "Cc: ${cc_recipients[@]}"
        fi
        echo "Subject: $subject"
        echo "Date: $(date -R)"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
    } > "$email_file"
    
    # 添加正文
    echo "$body" >> "$email_file"
    
    echo "$email_file"
}

# 使用msmtp发送邮件
send_with_msmtp() {
    local email_file="$1"
    local all_recipients=("$recipient" "${cc_recipients[@]}" "${bcc_recipients[@]}")
    
    if $debug; then
        echo -e "${BLUE}调试信息:${NC}"
        echo "标题文件: $title_file"
        echo "正文文件: $body_file"
        echo "收件人: $recipient"
        echo "抄送: ${cc_recipients[*]}"
        echo "密送: ${bcc_recipients[*]}"
        echo "附件: ${attachments[*]}"
        echo "发件人: $sender"
        echo "发件人名称: $from_name"
        echo ""
        echo -e "${BLUE}邮件内容预览:${NC}"
        cat "$email_file"
        echo ""
    fi
    
    # 发送邮件
    if $verbose; then
        echo -e "${BLUE}正在发送邮件...${NC}"
    fi
    
    # 构建收件人列表
    recipients_arg=""
    for r in "${all_recipients[@]}"; do
        if [[ -n "$r" ]]; then
            recipients_arg="$recipients_arg $r"
        fi
    done
    
    # 发送命令
    if $debug; then
        msmtp --debug $recipients_arg < "$email_file"
    else
        msmtp $recipients_arg < "$email_file"
    fi
    
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}✓ 邮件发送成功！${NC}"
        if $verbose; then
            echo "收件人: $recipient"
            echo "标题: $subject"
            echo "时间: $(date)"
        fi
    else
        echo -e "${RED}✗ 邮件发送失败！错误码: $result${NC}"
    fi
    
    return $result
}

# 使用mutt发送带附件的邮件
send_with_mutt() {
    local subject=$(cat "$title_file" | tr -d '\n\r')
    local body=$(cat "$body_file")
    local all_recipients="$recipient"
    
    # 添加抄送
    if [[ ${#cc_recipients[@]} -gt 0 ]]; then
        for cc in "${cc_recipients[@]}"; do
            all_recipients="$all_recipients -c $cc"
        done
    fi
    
    # 构建附件参数
    local attach_args=""
    for attachment in "${attachments[@]}"; do
        attach_args="$attach_args -a \"$attachment\""
    done
    
    # 发送邮件
    if $verbose; then
        echo -e "${BLUE}使用mutt发送带附件的邮件...${NC}"
    fi
    
    # 使用临时文件存储正文
    local body_file_tmp=$(mktemp /tmp/body_XXXXXXXXXX.txt)
    echo "$body" > "$body_file_tmp"
    
    # 构建发件人参数
    local from_arg=""
    if [[ -n "$sender" ]]; then
        if [[ -n "$from_name" ]]; then
            from_arg="-e \"set from=\\\"$from_name\\\" <$sender>\""
        else
            from_arg="-e \"set from=$sender\""
        fi
    fi
    
    # 发送命令
    if $debug; then
        echo "调试命令:"
        echo "mutt $from_arg -s \"$subject\" $attach_args $all_recipients < \"$body_file_tmp\""
    fi
    
    eval "mutt $from_arg -s \"$subject\" $attach_args $all_recipients" < "$body_file_tmp"
    
    local result=$?
    rm -f "$body_file_tmp"
    
    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}✓ 邮件发送成功！${NC}"
        if $verbose; then
            echo "收件人: $recipient"
            echo "标题: $subject"
            echo "附件数量: ${#attachments[@]}"
        fi
    else
        echo -e "${RED}✗ 邮件发送失败！错误码: $result${NC}"
    fi
    
    return $result
}

# 主函数
main() {
    parse_args "$@"
    check_dependencies
    validate_files
    
    # 记录开始时间
    local start_time=$(date +%s)
    
    # 根据是否有附件选择发送方式
    if [[ ${#attachments[@]} -gt 0 ]] && command -v mutt &> /dev/null; then
        send_with_mutt
    else
        if [[ ${#attachments[@]} -gt 0 ]]; then
            echo -e "${YELLOW}警告: 检测到附件但未安装mutt，将发送不带附件的邮件${NC}"
        fi
        
        email_file=$(create_email_file)
        
        # 确保临时文件被清理
        trap "rm -f '$email_file'" EXIT
        
        send_with_msmtp "$email_file"
        local result=$?
        
        # 清理临时文件
        rm -f "$email_file"
    fi
    
    # 计算执行时间
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if $verbose; then
        echo -e "${BLUE}执行时间: ${duration}秒${NC}"
    fi
    
    return $result
}

# 运行主函数
main "$@"
