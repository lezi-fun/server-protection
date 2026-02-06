# ssh-guard

一个轻量级的 SSH 防护脚本，支持：

- SSH 暴力破解检测与自动封禁
- 端口扫描检测（对未开放端口的 100 个不同端口在 2 分钟内扫描自动封禁）
- 邮件告警与定期报告

## 一键安装

```bash
sudo ./install.sh
```

安装后命令路径为 `/usr/local/bin/ssh-guard`。
安装脚本会提示选择 `smtp` 或 `resend` 并生成 `/etc/ssh-guard/mail.conf`。

## 使用方式

```bash
sudo /usr/local/bin/ssh-guard start
sudo /usr/local/bin/ssh-guard status
sudo /usr/local/bin/ssh-guard block 1.2.3.4 "手动封禁"
sudo /usr/local/bin/ssh-guard unblock 1.2.3.4
```

## 配置说明

在脚本顶部修改配置即可：

- `TO_EMAIL`：告警接收邮箱
- `FAILED_THRESHOLD` / `TIME_WINDOW`：SSH 失败登录封禁阈值
- `PORTSCAN_PORT_THRESHOLD` / `PORTSCAN_TIME_WINDOW`：端口扫描封禁阈值
- `PORTSCAN_BLOCK_DURATION`：端口扫描封禁时长（秒）

## 依赖

- `iptables`
- `tcpdump`（用于端口扫描检测）
- `ss` 或 `netstat`（用于刷新开放端口列表）
- `msmtp`（SMTP 发送）或 `curl`（Resend 发送）

## 注意事项

- 需要 root 权限运行。
- 如果系统未安装 `tcpdump`，端口扫描检测会自动禁用并写入状态日志。
- SMTP 模式需提前配置 `msmtp` 账号信息（如 `/etc/msmtprc`）。
