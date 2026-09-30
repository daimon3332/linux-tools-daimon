# linux-tools-daimon

个人自用的 Linux 服务器工具箱，中文交互，快捷命令 `d`。基于 [kejilion/sh](https://github.com/kejilion/sh) 定制，主要面向 Ubuntu / Debian。

## 安装与更新

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daimon3332/linux-tools-daimon/master/linux-toolbox.sh)
# 中国大陆
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/daimon3332/linux-tools-daimon/master/linux-toolbox.sh)
```

- 首次运行自动补齐 `python3`、`curl`，安装完整版本到 `/root/linux-daimon`，之后输入 `d` 启动。
- 主菜单 `00` 更新：解析最新提交 → 下载同一提交的完整包 → 校验文件清单、SHA256 和语法 → 原子切换；失败保留旧版本，只保留最近 3 个版本。
- 国内（`ipinfo.io` 返回 `CN`，香港不算）自动走 GitHub 代理和国内镜像；国家结果缓存 24 小时，启动不联网。
- 任何选项缺少依赖命令时自动安装并复检，安装失败会明确提示；缺少配置、凭据或运行中的服务时给出说明，不擅自安装大型组件。

## 快捷命令

| 命令 | 作用 |
|---|---|
| `d` | 打开主菜单 |
| `d install/remove 包名` | 安装 / 卸载软件包 |
| `d update` / `d clean` | 系统更新 / 系统清理 |
| `d swap 2048` / `d time Asia/Shanghai` | 设置虚拟内存 / 时区 |
| `d docker [install\|ps\|img]` | Docker 管理 |
| `d ssh` / `d sshkey [公钥\|URL\|github 用户]` | 远程连接管理 / 导入 root 公钥 |
| `d f2b` `d rc` `d bw` `d cronsync` `d retire` `d info` | fail2ban / rclone / Bitwarden / 同步脚本 / 退役 / 系统信息 |
| `d status\|start\|stop\|restart\|enable 服务` | 服务管理 |
| `d ssh-confirm TOKEN` / `d ssh-rollback TOKEN` | 确认 / 回滚待确认的 SSH 修改 |

## 主菜单

| 序号 | 菜单 | 说明 |
|---:|---|---|
| 1 | 系统信息查询 | 只读显示系统、资源、网络、SSH、UFW、Docker、Nginx、fail2ban、rclone、Bitwarden 状态 |
| 2 | 系统更新 | 修复中断的 dpkg 后更新并升级软件包，不强杀进程 |
| 3 | 系统清理 | 清理无用依赖、软件包缓存、journal（500M 上限） |
| 4 | 一键配置 | 下表各项可单选，或“配置全部”后删减编号批量执行 |
| 5 | 系统工具 | 快捷键、软件源、DNS、IPv4/6 优先、Swap、用户、时区、主机名、hosts、环境变量、GitHub 镜像、网卡、journal、IPv6 开关、语言、Docker 镜像测速、卸载工具箱 |
| 6 | 第三方工具 | vim、cpcat、Ctrl+D、starship、bat、btop、tree、ripgrep、fd、fzf、ble.sh、yazi、ncdu、NextTrace、iperf3 的安装 / 卸载 |
| 7 | 编程工具 | Python、npm、Node.js、Bun、uv、git、ClaudeCode、Codex 的安装 / 卸载 |
| 8 | Docker 管理 | 安装、状态、容器、镜像、网络、卷、清理、镜像源、daemon.json、Compose 自动更新、IPv6、备份 / 迁移 / 还原、卸载 |
| 9 | SSH 管理 | 端口、密码 / 密钥登录、安全配置、公钥私钥、编辑 sshd_config（事务化，需新连接确认） |
| 10 | UFW 管理 | 安装（先放行 SSH 端口）、卸载、开放 / 删除端口 |
| 11 | Nginx + 域名管理 | acme.sh webroot 证书、Nginx 站点、测试页、本地备份 / 恢复、证书迁移 |
| 12 | fail2ban 管理 | 安装并按当前 SSH 端口配置 sshd jail、卸载、检查修正 |
| 13 | BBR 管理 | 运行 Linux-NetSpeed `tcpx.sh`（内核需用户在其中明确选择） |
| 14 | WARP 管理 | 运行 fscarmen WARP 脚本、彻底删除 WARP |
| 15 | rclone 管理 | 安装、编辑配置、卸载、恢复远程文件夹、恢复 Nginx + 域名、Compose 恢复、同步记录 |
| 16 | Bitwarden 管理 | 配置 vaultwarden-backup 的 rclone.conf、备份、还原、同步脚本 |
| 17 | crontab 同步脚本 | Bitwarden、图床、Via、域名 Nginx、Emby、`/root` 一致性备份脚本的安装 / 卸载 / 立即执行 |
| 18 | 常用一键脚本 | NodeQuality、IPQuality、融合怪、NetQuality、流媒体检测、bench、YABS、HardwareQuality、勇哥、kejilion、sing-box、TcpQuality |
| 19 | 服务器退役 | 只读检测后按选择停止 Compose、删除托管 Nginx 配置、同步 / 更新脚本和续期任务 |
| 20 | Debian 基础工具 | 仅 Debian：补齐 ca-certificates、curl、wget、jq |
| 21 | 网络自适应优化 | 本地 PowerShell 客户端配合 iperf3 多轮对照调优发送缓冲、恢复调优前参数、只测速 |

### 第三方工具（菜单 6）

| 序号 | 名称 | 作用 |
|---:|---|---|
| 1 | vim | 文本编辑器，设为默认编辑器 |
| 2 | cpcat | 通过 OSC 52 复制文件内容到本地剪贴板 |
| 3 | Ctrl+D | Bash 中 Ctrl+D 改为删除下一个单词 |
| 4 | starship | 终端提示符美化 |
| 5 | bat | 终端输出高亮，提供 bauto、blog 等命令 |
| 6 | btop | 系统资源监控 |
| 7 | tree | 树形查看目录 |
| 8 | ripgrep | 快速文本搜索（rg） |
| 9 | fd | 快速文件查找 |
| 10 | fzf | 命令行模糊搜索 |
| 11 | ble.sh | Bash 行编辑与自动补全 |
| 12 | yazi | 终端文件管理器 |
| 13 | ncdu | 磁盘占用分析 |
| 14 | NextTrace | 可视化路由追踪 |
| 15 | iperf3 | 网络性能测试 |

### 编程工具（菜单 7）

| 序号 | 名称 | 作用 |
|---:|---|---|
| 1 | python | Python 运行环境（Debian 使用发行版 Python，不替换系统解释器） |
| 2 | npm | 通过 nvm 安装 Node.js LTS 提供 npm |
| 3 | nodejs | Node.js LTS |
| 4 | bun | Bun 运行时与包管理器 |
| 5 | uv | Python 包与项目管理 |
| 6 | git | 版本控制 |
| 7 | ClaudeCode | Claude Code 命令行工具 |
| 8 | Codex | Codex 命令行工具 |

### 一键配置（菜单 4）

| 序号 | 选项 | 说明 |
|---:|---|---|
| 1 | 配置全部 | 预填 2–10，可删减；失败项记录后继续，最后汇总并 `exec bash` |
| 2 / 3 | 系统更新 / 清理 | 同主菜单 2 / 3 |
| 4 | 虚拟内存 1G | 创建带归属标记的 `/swapfile` |
| 5 | DNS | CN 用 223.5.5.5、119.29.29.29，其他用 1.1.1.1、8.8.8.8 |
| 6 / 8 | BBR + FQ | 内核支持时启用并验证；缓冲参数到菜单 21 实测后调整 |
| 7 | Docker | CN 用 linuxmirrors + 国内镜像，其他用官方源 |
| 9 | 第三方工具 | 安装菜单 6 全部工具 |
| 10 | 时区和语言 | `Asia/Shanghai` + `en_US.UTF-8` |

### 使用要点

- **SSH**：修改先写入候选配置并启动 180 秒回滚计时，必须从新连接执行 `d ssh-confirm TOKEN`，否则自动恢复。Ubuntu 22.10+ 默认的 `ssh.socket` 会在确认后切换为常规 `ssh.service`。安全配置只在 UFW 已启用时联动放行新端口；fail2ban 运行中不允许改端口。
- **Docker 备份**（菜单 8-19）：输入 `STOP_BACKUP` 后停止所选容器（Compose 整个项目），保存镜像、可写层、挂载和配置到 `/tmp/docker_backup_*`，再恢复原运行状态；还原需要空目录并输入 `RESTORE`，同名资源拒绝。
- **Compose 自动更新**（菜单 8-10）：按上海时间错峰拉取，镜像变化才重建并等待健康，失败恢复原镜像；已停止的服务不启动。
- **迁移到新服务器**：rclone 菜单 4 恢复 `/root` 下所需目录 → 菜单 5 恢复 Nginx 和证书 → 菜单 6 启动 Compose 项目 → 自行切换 DNS 并验证。
- **同步脚本**（菜单 17）：统一经 `.rclone-runner.sh` 运行，状态写入 `/var/cache/daimon/rclone-sync-status.tsv`，日志在 `/var/log/rclone`；`/root` 备份按服务器名同步 `qq3303338052@outlook:<名称>` → `kissska1:<名称>`，备份期间冻结相关容器。排除规则写入任务目录 `.root-backup.exclude`。
- **网络优化**（菜单 21）：每次预算 20 GB；候选采用 A→B→A 对照并两次确认，无可靠收益保留原参数。“恢复调优前参数”回到菜单显示的快照时间点。测速端口 50280 保持放行，控制端口用后删除；云平台安全组需自行放行。

## 第三方脚本引用

只列下载后执行、`source`、`exec bash` 或通过管道执行的外部脚本。国内机器访问 GitHub 时依次尝试 `gh-proxy.com`、`ghproxy.net`、`testingcf.jsdelivr.net`、`ghfast.top`。

| 菜单 | 名称 | 来源 |
|---|---|---|
| 系统工具 | LinuxMirrors 换源 | `https://linuxmirrors.cn/main.sh` |
| 系统工具 | jhb IPv6 修复 | `https://jhb.ovh/jb/v6.sh` |
| Docker | LinuxMirrors Docker 安装（CN） | `https://linuxmirrors.cn/docker.sh` |
| BBR | Linux-NetSpeed | `https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh` |
| WARP | fscarmen WARP | `https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh` |
| rclone（非 CN） | rclone 官方安装器 | `https://rclone.org/install.sh` |
| Nginx | acme.sh | `https://get.acme.sh` |
| 第三方工具 | starship（非 CN） | `https://starship.rs/install.sh` |
| 第三方工具 | fzf / ble.sh 源码 | `https://github.com/junegunn/fzf.git`、`https://github.com/akinomyoga/ble.sh.git` |
| 编程工具 | nvm / nvm-cn | `https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh`、`https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh` |
| 编程工具 | Bun / uv / ClaudeCode | `https://bun.sh/install`、`https://astral.sh/uv/install.sh`、`https://claude.ai/install.sh` |
| 一键脚本 | NodeQuality / IPQuality / NetQuality / HardwareQuality | `https://run.NodeQuality.com`、`https://IP.Check.Place`、`https://Net.Check.Place`、`https://Check.Place` |
| 一键脚本 | 融合怪 | `https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh` |
| 一键脚本 | RegionRestrictionCheck | `https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh` |
| 一键脚本 | bench.sh / YABS | `https://bench.sh`、`https://yabs.sh` |
| 一键脚本 | 勇哥 x-ui-yg | `https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh` |
| 一键脚本 | kejilion.sh | `https://kejilion.sh` |
| 一键脚本 | sing-box-daimon / TcpQuality | `https://raw.githubusercontent.com/daimon3332/sing-box-daimon/main/sb.sh`、`https://raw.githubusercontent.com/daimon3332/TcpQuality/main/runTcpQuality.sh` |
| 网络优化 | TCPquality 参考测速 | `https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh` |

## 目录

| 路径 | 用途 |
|---|---|
| `/root/linux-daimon/releases/<提交>` | 已校验的完整版本（`current` 指向当前版本） |
| `/root/linux-daimon/preferences.json` | 许可与偏好 |
| `/root/linux-daimon/daimon` | 第三方脚本缓存 |
| `/root/linux-daimon/backup` | 本地备份（Nginx + 域名） |
| `/root/linux-daimon/backup-sh` | crontab 同步脚本 |
| `/root/linux-daimon/docker-compose-update` | Compose 自动更新脚本 |
| `/root/linux-daimon/tcp-tuning` | 网络调优快照与记录 |
| `/root/domain` | 证书目录 |

源码：`scripts/01-*.sh`～`21-*.sh` 对应一级菜单，`scripts/main.sh` 为主菜单与快捷命令，`scripts/lib` 为共享函数，`scripts/network` 为调优组件。修改前阅读 [CODING_GUIDELINES.md](./CODING_GUIDELINES.md)。

## 风险提示

本工具会修改 SSH、防火墙、Docker、Nginx、证书、Swap、DNS、sysctl 等系统配置。请只在自己有管理权限的服务器上使用，并提前备份重要数据。

MIT License，见 [LICENSE](../LICENSE)。
