# linux-tools-daimon 命令参考

按菜单列出每个选项背后的核心命令（以 Debian/Ubuntu 为例）。缺少的命令由 `daimon_require_cmd` 自动安装并复检；失败的操作显示“操作失败（返回码 N）”。

## 启动与更新

| 动作 | 核心命令 |
|---|---|
| 安装 / 启动 | `linux-toolbox.sh` → `package.py boot`：校验 `releases/<提交>` 的清单与 SHA256，输出模块和偏好后 `exec bash entry.sh` |
| 00 脚本更新 | `package.py update master`：GitHub API 解析提交 → 下载该提交 tar 包（CN 先走代理）→ 校验 → 替换 `current` 链接和 `/usr/local/bin/d` → 保留最近 3 个版本 |
| 并发 | 启动 / 查询用共享锁，更新 / 写偏好用独占锁，最长等待 120 秒 |
| 国家判断 | `curl https://ipinfo.io/json`，结果缓存到 `/root/linux-daimon/.country`（24 小时，失败 1 小时） |

## 1–3 系统信息 / 更新 / 清理

| 选项 | 核心命令 |
|---|---|
| 1 系统信息 | `lscpu` `free` `df -h` `ss -Htu` `sysctl -n net.ipv4.tcp_congestion_control` `sshd -T` `ufw status` `docker info` `rclone version`（只读，不安装） |
| 2 系统更新 | `dpkg --configure -a` → `apt update` → `apt full-upgrade -y` |
| 3 系统清理 | `apt autoremove --purge -y` `apt clean` `apt autoclean` `journalctl --vacuum-size=500M` |

## 4 一键配置

| 选项 | 核心命令 |
|---|---|
| 1 配置全部 | 依次执行所选编号，失败继续，最后汇总并 `exec bash` |
| 4 虚拟内存 1G | `fallocate`/`dd` 创建 `/swapfile` → `mkswap` → `swapon` → 写 `/etc/fstab`，记录 inode 归属标记 |
| 5 DNS | 按国家写 `nameserver`，原子替换 `/etc/resolv.conf` |
| 6 / 8 BBR + FQ | `modprobe tcp_bbr`，写 `/etc/sysctl.d/99-daimon-bbr-fq.conf`，`sysctl -p`，`tc qdisc` 核实 |
| 7 Docker | CN：`linuxmirrors.cn/docker.sh`（华为云源 + 镜像加速）；其他：官方源 |
| 9 第三方工具 | 同菜单 6 全部安装 |
| 10 时区语言 | `timedatectl set-timezone Asia/Shanghai`，`locale-gen en_US.UTF-8`，`update-locale LANG=en_US.UTF-8` |

## 5 系统工具

| 选项 | 核心命令 |
|---|---|
| 1 快捷键 | `ln -s /usr/local/bin/d /usr/local/bin/<键>`，拒绝与已有命令冲突 |
| 2 软件源 | `bash linuxmirrors-main.sh`（下载并 `bash -n` 校验后执行） |
| 3 DNS | 1 国外 / 2 国内：替换 nameserver 行；3：`vim` 编辑暂存文件并校验；4：链接回 systemd-resolved（stub 默认）/ NetworkManager / resolvconf 的配置 |
| 4 IPv4/6 优先 | 增删 `/etc/gai.conf` 中 `precedence ::ffff:0:0/96 100` |
| 5 虚拟内存 | 1G/2G/4G/自定义/删除，仅处理带归属标记的 `/swapfile` |
| 6 用户管理 | `useradd -m`、导入公钥、`/etc/sudoers.d/<用户>` + `visudo -cf` 校验、`userdel -r`（二次确认） |
| 7 时区 | `timedatectl set-timezone <区域>` |
| 8 主机名 | `hostnamectl set-hostname`，同步 `/etc/hostname` 与 `/etc/hosts` 的 `127.0.1.1` |
| 9 hosts | 校验地址和主机名后追加 / 按字面删除行 |
| 10 环境变量 | 转义后写入 `~/.bashrc` 或 `~/.profile` |
| 11 GitHub 镜像 | 编辑 `daimon/github_proxy_sources.txt`，`curl` 测速 |
| 12 SSH 来源 IP | `$SSH_CONNECTION`、`who`、`ss -tnp` |
| 13 网卡 | `ip link set <网卡> up/down`、`ip addr show` |
| 14 journal | 写 `/etc/systemd/journald.conf.d/99-daimon-journal.conf`，`journalctl --disk-usage/--vacuum-time/--vacuum-size` |
| 15 | 跳转主菜单 21 |
| 16 / 17 IPv6 | 写 `/etc/sysctl.d/99-daimon-ipv6.conf`（`disable_ipv6=1/0`），拒绝从 IPv6 SSH 连接禁用 |
| 18 语言 | 更新 `/etc/locale.gen` → `locale-gen` → `update-locale` |
| 19 Docker 镜像测速 | `timeout <秒> docker pull <镜像源>/library/python:3.12-slim`，只删除本轮新拉取的镜像 |
| 20 卸载工具箱 | 删除 `/usr/local/bin/d`、快捷键链接和 `/root/linux-daimon/linux-toolbox.sh`，保留服务、脚本和定时任务 |

## 6 第三方工具

安装后写入带起止标记的 `~/.bashrc` 配置块，卸载删除对应块；全部完成后 `exec bash`。

| 工具 | 安装 | 卸载 |
|---|---|---|
| vim | `apt install vim`，`export EDITOR=vim VISUAL=vim` | 删除 EDITOR/VISUAL 行 |
| cpcat / Ctrl+D | 写 `.bashrc` 配置块（OSC 52 复制 / `bind '"\C-d": kill-word'`） | 删除配置块 |
| starship | 非 CN：`starship.rs/install.sh`；CN：代理下载 musl 包 → `/usr/local/bin` | 删除二进制与配置 |
| bat / btop / tree / ripgrep / fd / ncdu / iperf3 | `apt install`（fd 用 `fd-find` + `alias fd=fdfind`） | `apt purge` |
| fzf | `git clone --depth 1` 到 `tools/fzf` 后 `install --no-update-rc` | 删除目录与配置块 |
| ble.sh | `git clone --recursive` → `make install`，写 `~/.blerc` | 删除目录、`~/.blerc` 与配置块 |
| yazi / NextTrace | 添加签名 APT 源后单源 `apt-get update` + 安装 | `apt purge` 并删除源和密钥 |

## 7 编程工具

| 工具 | 核心命令 |
|---|---|
| python | Debian：`apt install python3 python3-venv python3-pip`；Ubuntu：`python3.12`（缺少时 deadsnakes PPA） |
| npm / nodejs | 非 CN：nvm v0.40.6；CN：nvm-cn；`nvm install --lts` |
| bun / uv | `bun.sh/install`、`astral.sh/uv/install.sh` |
| git | `apt install git` |
| ClaudeCode | 非 CN：`claude.ai/install.sh`；CN：`npm i -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com`；写 `~/.claude/settings.json`（已存在不覆盖） |
| Codex | `npm i -g @openai/codex@latest`；写 `~/.codex/config.toml`（已存在不覆盖） |

菜单状态检测会加载 `~/.local/bin`、`~/.bun/bin` 和 nvm 环境，不依赖启动 shell 的 PATH。

## 8 Docker 管理

| 选项 | 核心命令 |
|---|---|
| 1 安装 | 同一键配置 7 |
| 2 状态 | `docker version` `docker ps -a` `docker images` `docker network ls` `docker volume ls` |
| 3 容器 | `docker run` / `start` / `stop` / `rm` / `restart` / `exec -it` / `logs` |
| 4 镜像 | `docker pull`（1 获取、2 更新）/ `docker rmi`（3 删除、4 全部删除） |
| 5 网络 / 6 卷 | `docker network create/connect/disconnect/rm`、`docker volume create/rm/prune` |
| 7 清理 | `docker system prune -af --volumes`（确认后） |
| 8 镜像源 | `jq` 合并 `registry-mirrors` → `dockerd --validate` → 原子写 `/etc/docker/daemon.json` → 仅在原本运行时 `systemctl restart docker` |
| 9 编辑 daemon.json | `vim` 暂存副本 → 同上校验与提交 |
| 10 Compose 自动更新 | 按项目生成 `docker-compose-update/compose_update_*.sh` 与错峰 cron；更新时 `docker compose pull` → 镜像变化才 `up -d --no-deps --no-build --wait`，失败恢复原镜像；已停止的服务不启动 |
| 11 / 12 IPv6 | `.ipv6 = true`、`fixed-cidr-v6` 默认 `fd42:da10:6::/64` / 删除后 `.ipv6 = false`，同 8 提交 |
| 19 备份 / 迁移 / 还原 | 备份：`STOP_BACKUP` → 停止所选项目 → `docker commit`/`save` + 挂载数据 → `/tmp/docker_backup_*` → 恢复运行；迁移：`rsync` 到目标主机；还原：`RESTORE` → 空目录 + 快照镜像 |
| 20 卸载 | 确认后删除全部容器 → `apt purge docker docker-compose docker-ce docker-ce-cli containerd.io` → 删除 `/etc/docker` `/var/lib/docker` `/var/lib/containerd`（**镜像、卷数据一并删除**） |

## 9 SSH 管理

所有修改经 `ssh_transaction_apply`：候选配置 `sshd -t` 校验 → 启动 180 秒回滚定时器与开机恢复单元 → 原子写入 → `systemctl reload ssh` → 从新连接执行 `d ssh-confirm TOKEN`。`ssh.socket` 启用时先确认切换为 `ssh.service`（`disable --now ssh.socket` → `daemon-reload` → `restart ssh.service`）。

| 选项 | 写入的配置 |
|---|---|
| 1 端口 | `Port <端口>`（UFW 启用时临时新增放行规则） |
| 2 密码登录 | `PasswordAuthentication` / `KbdInteractiveAuthentication` / `PermitRootLogin` |
| 3 密钥登录 | `PubkeyAuthentication`，可同时追加公钥 |
| 4 安全配置 | 新端口 + 仅密钥 + `PermitRootLogin prohibit-password`；UFW 启用时联动放行 |
| 5 公钥私钥 | 追加 / 删除 `authorized_keys` 行（删除走事务）；`ssh-keygen -t ed25519` 生成 / 删除私钥 |
| 6 编辑配置 | `vim` 编辑 `/run` 下暂存副本，校验后走事务 |

## 10 UFW / 12 fail2ban

| 选项 | 核心命令 |
|---|---|
| UFW 1 安装 | `apt install ufw` → 放行当前 SSH 端口 → `ufw --force enable` |
| UFW 2 卸载 | `ufw disable` → `apt purge ufw` → 删除 `/etc/ufw` |
| UFW 3 / 4 | `ufw allow <规则>` / `ufw delete allow <规则>` |
| fail2ban 1 安装 | `apt install fail2ban`（无 auth.log 时用 systemd 后端 + `python3-systemd`），写 sshd jail（端口取自 `sshd -T`）→ `systemctl enable --now fail2ban` |
| fail2ban 2 卸载 | `systemctl disable --now fail2ban` → `apt purge` → 删除 `/etc/fail2ban` `/var/lib/fail2ban` |
| fail2ban 3 检查 | 比较 jail 端口与 SSH 端口，不一致则修正并 `fail2ban-client reload` |

## 11 Nginx + 域名

由 `daimon/cert_nginx.sh` 执行：acme.sh webroot（`/var/www/acme-challenge`），证书位于 `/root/domain/<域名>`，续期脚本 `/root/linux-daimon/cert-renew.sh`（每天 03:00）。

| 选项 | 核心命令 |
|---|---|
| 1 / 3 申请证书 | `acme.sh --issue -w /var/www/acme-challenge -d <域名>` → `--install-cert --reloadcmd "systemctl reload nginx"` |
| 2 / 4 / 7 删除 | 核查共享引用后删除证书 / 站点配置，`nginx -t` 失败回滚 |
| 5 证书列表 | `acme.sh --list` |
| 6 配置 nginx | 生成反向代理站点 → `nginx -t` → `systemctl reload nginx` |
| 8 / 9 测试页 | 创建 / 删除带归属标记的测试站点 |
| 10 安装 | `apt install nginx` → `systemctl enable --now nginx` |
| 11 / 12 备份恢复 | 打包 `sites-available`、`/root/domain` 到 `backup/nginx-domain/auto_latest`；恢复时合并并重建 `sites-enabled` |
| 13 迁移证书 | 把现有 acme.sh 证书切到 webroot 模式 |

## 13 BBR / 14 WARP / 18 一键脚本

下载到 `/root/linux-daimon/daimon` 并 `bash -n` 校验后执行；下载或校验失败会提示并返回菜单。来源见 [README](./README.md#第三方脚本引用)。

## 15 rclone 管理

| 选项 | 核心命令 |
|---|---|
| 1 安装 | 非 CN：`rclone.org/install.sh`；CN：代理下载发行包并校验 SHA256；`chmod 600 rclone.conf` |
| 2 修改配置 | `vim ~/.config/rclone/rclone.conf` |
| 3 卸载 | 删除 rclone 二进制，保留配置 |
| 4 恢复文件夹 | 选 remote → 服务器目录 → 子目录 → 同名策略 → `rclone copy` 到暂存目录 → `rclone check --download` → 合并到 `/root` |
| 5 恢复 Nginx | 下载并校验备份 → 安装 Nginx/OpenSSL/UFW → 应用站点和证书 → `nginx -t` → 放行 80/443 |
| 6 Compose 恢复 | 扫描 `/root` 下 Compose 项目 → 检查挂载 → 确认后 `docker compose up -d --wait` |
| 7 同步记录 | 读取 `/var/cache/daimon/rclone-sync-status.tsv` 与 `/var/log/rclone/runs` |

## 16 Bitwarden / 17 同步脚本

| 选项 | 核心命令 |
|---|---|
| 16-1 rclone.conf | 用 `vaultwarden-backup` 镜像内的 rclone 验证后，只替换卷内 `[BitwardenBackup]` 段 |
| 16-2 备份 | `docker exec vaultwarden-backup /app/backup.sh`，检查上传成功字段 |
| 16-3 还原 | 下载并校验 ZIP → 隔离解密 → 校验 SQLite → 替换数据卷 |
| 16-4 / 17 安装脚本 | 写 `backup-sh/<脚本>.sh` 并添加 cron：`* * * * * [ "$(TZ=Asia/Shanghai date +%H:%M)" = "HH:MM" ] && bash .rclone-runner.sh <类型> <脚本>` |
| 17-5 立即 `/root` 备份 | 输入 `RUN_ROOT_BACKUP` → 冻结相关容器 → `rclone sync /root` 到 `qq3303338052@outlook:<名称>` → 校验 → 恢复容器 → 复制到 `kissska1:<名称>` |
| 17-6 迁移旧脚本 | 输入 `MIGRATE` 后把 `Infini-cloud:` 替换为 `kissska1:` |

## 19 服务器退役

只读展示后按选择执行：`docker stop` + `docker rm`（不删卷、镜像、项目文件）、删除托管 Nginx 站点并 `nginx -t`、从 crontab 精确删除同步 / 自动更新 / 续期任务及脚本。

## 20 Debian 基础工具

`apt-get install -y --no-install-recommends ca-certificates curl wget jq`（仅缺失项）。

## 21 网络自适应优化

| 选项 | 核心命令 |
|---|---|
| 1 动态调优 | 启动 `iperf3 -s` 与临时控制接口（放行 50280/50281）→ 本地粘贴 PowerShell 命令运行 `iperf3 -c -R` → A→B→A 对照调整 `net.core.wmem_max` 与 `net.ipv4.tcp_wmem` → 两次确认通过才写入 `/etc/sysctl.d/zzzz-daimon-tcp-tuning.conf` |
| 2 恢复 | 恢复到菜单显示时间点的快照，保留 BBR + FQ |
| 3 只测速 | 同 1 的测速流程，不修改参数 |
