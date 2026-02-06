# ssh-guard

一个轻量级的 SSH 防护脚本，支持：

- SSH 暴力破解检测与自动封禁
- 端口扫描检测（对未开放端口的 100 个不同端口在 2 分钟内扫描自动封禁）
- 邮件告警与定期报告

## 一键安装

```bash
wget https://raw.githubusercontent.com/lezi-fun/server-protection/refs/heads/main/ssh-guard.sh
sudo ./install.sh
```

安装后命令路径为 `/usr/local/bin/ssh-guard`。
安装脚本会提示选择 `smtp` 或 `resend` 并生成 `/etc/ssh-guard/mail.conf`。
安装脚本也支持选择 `docker` 部署（可通过环境变量 `SSH_GUARD_IMAGE` 指定镜像地址）。

也可以从 Release 下载一键安装脚本：

```bash
curl -L https://github.com/lezi-fun/server-protection/releases/latest/download/install-ssh-guard.sh -o install-ssh-guard.sh
chmod +x install-ssh-guard.sh
sudo ./install-ssh-guard.sh
```

## 使用方式

```bash
sudo /usr/local/bin/ssh-guard start
sudo /usr/local/bin/ssh-guard status
sudo /usr/local/bin/ssh-guard block 1.2.3.4 "手动封禁"
sudo /usr/local/bin/ssh-guard blacklist 1.2.3.4 "永久拉黑"
sudo /usr/local/bin/ssh-guard whitelist 1.2.3.4
sudo /usr/local/bin/ssh-guard unblock 1.2.3.4
```

## 容器运行示例

> 说明：封禁和抓包需要访问宿主机网络与防火墙规则，建议使用 `--privileged` 与 `--net=host`。

镜像拉取与运行示例（GHCR）：

```bash
docker pull ghcr.io/lezi-fun/server-protection:latest
```

```bash
docker run --rm -it \
  --privileged \
  --net=host \
  -v /var/log:/var/log \
  -v /etc/ssh-guard:/etc/ssh-guard \
  ghcr.io/lezi-fun/server-protection:latest
```

```bash
docker build -t ssh-guard:local .
```

```bash
docker run --rm -it \\
  --privileged \\
  --net=host \\
  -v /var/log:/var/log \\
  -v /etc/ssh-guard:/etc/ssh-guard \\
  ssh-guard:local
```

如果需要进入容器手动执行命令，可覆盖默认入口：

```bash
docker run --rm -it \\
  --privileged \\
  --net=host \\
  -v /var/log:/var/log \\
  -v /etc/ssh-guard:/etc/ssh-guard \\
  --entrypoint bash \\
  ssh-guard:local
```

## 配置说明

支持通过 `install.sh` 一键配置（推荐），也可在脚本顶部手动修改：

- `TO_EMAIL`：告警接收邮箱
- `FAILED_THRESHOLD` / `TIME_WINDOW`：SSH 失败登录封禁阈值
- `PORTSCAN_PORT_THRESHOLD` / `PORTSCAN_TIME_WINDOW`：端口扫描封禁阈值
- `PORTSCAN_BLOCK_DURATION`：端口扫描封禁时长（秒）
- `REPORT_INTERVAL`：邮件报告发送频率（秒）
- `WHITELIST_IPS_EXTRA`：额外白名单（空格分隔，或写入 `/etc/ssh-guard/whitelist.list`）

## 依赖

- `iptables`
- `tcpdump`（用于端口扫描检测）
- `ss` 或 `netstat`（用于刷新开放端口列表）
- `msmtp`（SMTP 发送）或 `curl`（Resend 发送）

## 注意事项

- 需要 root 权限运行。
- 如果系统未安装 `tcpdump`，端口扫描检测会自动禁用并写入状态日志。
- 如果系统未安装 `ss`/`netstat`，端口扫描封禁逻辑会自动停用，避免误封正常流量。
- 每次 IP 解封（手动/自动）都会发送邮件提醒。
- SMTP 模式需提前配置 `msmtp` 账号信息（如 `/etc/msmtprc`）。
