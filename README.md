# linux-tools-daimon

`linux-tools-daimon` 是个人自用的 Linux 服务器脚本工具箱，中文交互，快捷命令为 `d`。

本项目基于 `kejilion/sh` 二开定制，保留常用服务器管理能力，并增加 SSH、UFW、rclone、SSL/Nginx、fail2ban、WARP、GitHub 镜像源测速、journalctl 日志管理、第三方工具和编程工具管理等功能。

## 一键运行

```bash
bash <(curl -fsSL https://daimon-linux-scripts.333186.xyz/linux-toolbox.sh)
```

## 快捷命令

首次运行后可使用：

```bash
d
```

之后在服务器命令行输入 `d` 即可打开工具箱。

## 主菜单顺序

| 序号 | 一级菜单 | 作用 |
|---:|---|---|
| 1 | 系统信息查询 | 查看系统、CPU、内存、硬盘、网络、DNS、IP、运行时间等信息 |
| 2 | 系统更新 | 更新软件源并升级系统软件包 |
| 3 | 系统清理 | 清理缓存、无用依赖、日志和临时文件 |
| 4 | 一键配置 | 快速执行系统更新、清理、Swap、DNS、BBR、Docker、网络优化和第三方工具安装 |
| 5 | 系统工具 | 管理快捷键、软件源、DNS、Swap、用户、时区、主机名、hosts、网卡、日志、IPv6 等 |
| 6 | 第三方工具 | 安装/卸载 vim、cpcat、starship、bat、btop、yazi 等常用工具 |
| 7 | 编程工具 | 安装/卸载 Python、Node.js、Bun、uv、git、ClaudeCode、Codex 等开发工具 |
| 8 | Docker管理 | 安装、卸载、状态查看、镜像源、容器、镜像、网络、卷、Compose、备份迁移等 |
| 9 | SSH管理 | 修改 SSH 端口、密码登录、密钥登录、公钥私钥和 sshd_config |
| 10 | UFW管理 | 安装/卸载 UFW、开放端口、删除端口规则 |
| 11 | rclone管理 | 安装 rclone、修改配置文件、卸载 rclone |
| 12 | SSL证书申请+自动续期 & Nginx管理 | 申请证书、删除证书、配置 Nginx、测试页面管理 |
| 13 | fail2ban管理 | 安装/卸载 fail2ban，并自动配置 sshd 防护 |
| 14 | BBR管理 | 进入 BBR / 网络加速管理脚本 |
| 15 | WARP管理 | 进入 WARP 管理脚本或彻底删除 WARP |
| 16 | 常用的一键脚本 | 运行 NodeQuality、IPQuality、YABS、kejilion.sh 等脚本 |

## 主要内容

### 系统信息查询

- 展示主机名、系统版本、内核、CPU、内存、Swap、硬盘、流量、拥塞算法、队列算法、运营商、IPv4、IPv6、DNS、位置、时间、运行时长等。

### 系统更新

- 修复 apt/dpkg 中断或锁占用问题。
- 执行系统软件包更新和升级。

### 系统清理

- 清理无用依赖、软件包缓存、journal 日志、临时文件等。

### 一键配置

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 系统更新 | 执行系统更新 |
| 2 | 系统清理 | 执行系统清理 |
| 3 | 设置虚拟内存 1G | 创建/重建 1G Swap |
| 4 | 优化 DNS 地址 | 进入 DNS 优化配置 |
| 5 | 开启 BBR 加速（BBR + FQ） | 设置 BBR + FQ 加速参数 |
| 6 | 安装 Docker | 根据 `ipinfo.io` 的 `country` 字段自动选择国内镜像或 Docker 官方源 |
| 7 | 执行系统网络自适应优化 | 运行网络自适应优化脚本 |
| 8 | 安装第三方工具 | 默认预填全部第三方工具编号，用户可修改 |

### 系统工具

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 设置脚本启动快捷键 | 设置 `d` 或自定义快捷命令 |
| 2 | 更换系统软件包镜像源 | 运行 `bash <(curl -sSL https://linuxmirrors.cn/main.sh)` |
| 3 | 优化 DNS 地址 | 配置国外/国内 DNS、手动编辑或恢复原配置 |
| 4 | 切换优先 ipv4/ipv6 | 修改 `/etc/gai.conf`，切换 IPv4/IPv6 优先级 |
| 5 | 修改虚拟内存大小 | 预设 1G、2G、4G，也支持自定义 Swap 大小 |
| 6 | 用户管理 | 创建普通用户/高级用户、赋予/取消 sudo 权限、删除用户 |
| 7 | 系统时区调整 | 切换亚洲、欧洲、美洲和 UTC 常用时区 |
| 8 | 修改主机名 | 修改 hostname 和 hosts 中的本机名 |
| 9 | 本机 host 解析 | 添加或删除 `/etc/hosts` 解析记录 |
| 10 | 系统变量管理工具 | 查看、添加、修改、删除环境变量 |
| 11 | github镜像源 | 显示镜像源、添加、删除、测速 |
| 12 | DD重装系统 | 下载 `/root/InstallNET.sh` 并执行 DD 重装界面 |
| 13 | 查看ssh的ip | 查看当前 SSH 连接 IP 和所有 SSH 连接地址 |
| 14 | 网卡管理工具 | 查看、启用、禁用网卡和查看网卡详细信息 |
| 15 | journalctl日志管理 | 配置日志自动清理、查看占用、查看服务日志、按时间/大小清理 |
| 16 | 系统网络自适应优化 | 执行、查看或回滚网络自适应优化 |
| 17 | 禁用IPv6 | 写入 sysctl 配置禁用 IPv6 |
| 18 | 开启IPv6 | 写入 sysctl 配置开启 IPv6 |
| 19 | 配置/删除cpcat | 写入或删除 `~/.bashrc` 中的 cpcat 复制函数 |
| 20 | 卸载daimon脚本 | 删除 daimon 本地脚本和快捷命令 |

### 第三方工具

- 支持按编号安装、按编号卸载、全部安装、全部卸载。
- “全部安装 / 全部卸载”会预填当前分类全部编号，执行前可以手动删除不需要的编号。
- 带配置的工具卸载时会同步删除脚本写入的配置。

| 序号 | 名称 | 工具的作用 |
|---:|---|---|
| 1 | vim | 文本编辑器，并设置 `EDITOR=vim`、`VISUAL=vim` |
| 2 | cpcat | 通过 OSC 52 快速复制文件内容到本地剪贴板 |
| 3 | Ctrl+D | 将 Bash 中的 `Ctrl+D` 绑定为删除下一个单词 |
| 4 | starship | 终端提示符美化 |
| 5 | bat | 终端输出高亮增强，提供 `bauto`、`blog`、`byaml`、`raw` 等命令 |
| 6 | btop | 现代化系统资源监控工具 |
| 7 | tree | 以树形结构查看目录 |
| 8 | ripgrep | 快速文本搜索工具，命令为 `rg` |
| 9 | fd | 快速文件查找工具，Ubuntu 下通过 `fd-find` 安装并配置 `fd` 别名 |
| 10 | fzf | 命令行模糊搜索工具，使用 git clone 安装 |
| 11 | ble.sh | Bash 行编辑增强、自动补全和历史补全 |
| 12 | yazi | 现代终端文件管理器 |
| 13 | fastfetch | 系统概览信息展示工具 |
| 14 | ncdu | 交互式磁盘占用分析工具 |

### 编程工具

- 支持按编号安装、按编号卸载、全部安装、全部卸载。
- “全部安装 / 全部卸载”会预填当前分类全部编号，执行前可以手动删除不需要的编号。

| 序号 | 名称 | 工具的作用 |
|---:|---|---|
| 1 | python | 安装 Python3、pip、venv 和 `python-is-python3` |
| 2 | npm | Node.js 包管理器 |
| 3 | nodejs | Node.js 运行环境 |
| 4 | bun | Bun JavaScript 运行时和包管理器 |
| 5 | uv | Python 包管理和项目管理工具 |
| 6 | git | 版本控制工具 |
| 7 | ClaudeCode | Anthropic Claude Code 命令行工具 |
| 8 | Codex | OpenAI Codex 命令行工具 |

### Docker管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 安装更新 Docker 环境 | 安装或更新 Docker |
| 2 | 查看 Docker 全局状态 | 查看 Docker 服务和版本状态 |
| 3 | Docker 容器管理 | 管理容器 |
| 4 | Docker 镜像管理 | 管理镜像 |
| 5 | Docker 网络管理 | 管理 Docker 网络 |
| 6 | Docker 卷管理 | 管理 Docker volume |
| 7 | Docker 清理 | 清理无用 Docker 资源 |
| 8 | Docker Compose 项目管理 | 管理 compose 项目 |
| 9 | Docker 镜像源管理 | 配置 Docker 镜像源 |
| 10 | Docker daemon.json 管理 | 编辑或管理 daemon 配置 |
| 11 | Docker IPv6 配置 | 配置 Docker IPv6 |
| 12 | Docker 容器端口访问控制 | 管理容器端口访问规则 |
| 13 | Docker 容器日志查看 | 查看容器日志 |
| 14 | Docker 容器资源占用查看 | 查看容器资源占用 |
| 15 | Docker 容器网络信息查看 | 查看容器网络信息 |
| 16 | Docker Compose 备份 | 备份 compose 项目 |
| 17 | Docker Compose 迁移 | 迁移 compose 项目 |
| 18 | Docker 容器备份 | 备份容器 |
| 19 | Docker 备份还原 | 还原 Docker 备份 |
| 20 | 卸载 Docker 环境 | 卸载 Docker |

### SSH管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 修改 SSH 端口 | 修改 sshd 监听端口 |
| 2 | 禁用 / 开启密码登录 | 控制 `PasswordAuthentication` |
| 3 | 开启 / 禁用密钥登录 | 控制 `PubkeyAuthentication`，开启时可粘贴公钥 |
| 4 | 一键配置 | 一键改端口、关密码、开密钥、配置防火墙 |
| 5 | 公钥和私钥管理 | 添加/删除公钥，添加/删除私钥 |
| 6 | 修改 sshd_config 配置文件 | 直接修改 SSH 配置文件 |

### UFW管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 安装 UFW | 安装并启用 UFW |
| 2 | 卸载 UFW | 禁用并彻底卸载 UFW |
| 3 | 开放端口 | 用户输入 `80` 执行 `ufw allow 80`，输入 `80/tcp` 执行 `ufw allow 80/tcp` |
| 4 | 删除端口规则 | 用户输入 `80` 执行 `ufw delete allow 80`，输入 `80/tcp` 执行 `ufw delete allow 80/tcp` |
| 0 | 返回主菜单 | 返回上一级菜单 |

### rclone管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 安装 rclone | 安装 rclone |
| 2 | 修改配置文件 | 打开 rclone 配置 |
| 3 | 卸载 rclone | 卸载 rclone |

### SSL证书申请+自动续期 & Nginx管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 申请证书 + 配置 nginx | 申请证书并生成 Nginx 配置 |
| 2 | 删除 nginx 配置 + 证书 | 删除站点配置和证书 |
| 3 | 申请证书 | 只申请证书 |
| 4 | 移除证书 | 删除证书 |
| 5 | 查看证书列表 | 查看已申请证书 |
| 6 | 配置 nginx | 只生成 Nginx 配置 |
| 7 | 删除 nginx 配置 | 删除 Nginx 配置 |
| 8 | 创建测试页面 | 创建测试页面 |
| 9 | 删除测试页面 | 删除测试页面 |

### fail2ban管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 安装 Fail2ban | 自动检测当前 SSH 端口并配置 sshd 防护 |
| 2 | 卸载 Fail2ban | 停止服务并删除配置/状态目录 |
| 3 | 检查 sshd 配置 | 检查 jail 中的 sshd 端口，不一致则自动修正 |
| 0 | 返回主菜单 | 返回上一级菜单 |

### BBR管理

- 下载并运行 `tcpx.sh`，进入 BBR / 网络加速管理菜单。

### WARP管理

| 序号 | 选项 | 作用 |
|---:|---|---|
| 1 | 进入 WARP 官方管理脚本 | 运行 WARP 管理脚本 |
| 2 | 彻底删除 WARP | 删除 WARP 网络接口、Linux Client 和 WireProxy |

### 常用的一键脚本

| 序号 | 名称 | 命令 |
|---:|---|---|
| 1 | NodeQuality | `bash <(curl -sL https://run.NodeQuality.com)` |
| 2 | IPQuality | `bash <(curl -Ls https://IP.Check.Place)` |
| 3 | 融合怪 | `curl -L https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh -o ecs.sh && chmod +x ecs.sh && bash ecs.sh` |
| 4 | NetQuality | `bash <(curl -Ls https://Net.Check.Place)` |
| 5 | RegionRestrictionCheck | `bash <(curl -L -s check.unlock.media)` |
| 6 | bench.sh | `wget -qO- bench.sh | bash` |
| 7 | YABS | `curl -sL https://yabs.sh | bash` |
| 8 | HardwareQuality | `bash <(curl -Ls https://Check.Place) -H` |
| 9 | 勇哥脚本 | 进入脚本后运行 |
| 10 | kejilion.sh | `bash <(curl -sL kejilion.sh)` |

## 目录约定

脚本运行过程中需要额外下载的第三方脚本，默认缓存到：

```bash
/root/daimon
```

DD 重装脚本按个人要求单独下载到：

```bash
/root/InstallNET.sh
```

## 风险提示

本脚本会修改系统配置、SSH、UFW、Docker、Nginx、SSL 证书、Swap、软件源等内容。请只在自己拥有管理权限的服务器上使用，并提前备份重要数据。

## 开源协议

本项目基于 MIT License 开源，详见 [LICENSE](./LICENSE)。

## 致谢

- 上游项目：<https://github.com/kejilion/sh>
- 本项目仓库：<https://github.com/daimon3332/daimon-linux-scripts>
