# linux-tools-daimon

`linux-tools-daimon` 是个人自用的 Linux 服务器脚本工具箱，中文交互，快捷命令为 `d`。

本项目基于 kejilion/sh 二开定制，删除了个人不需要的模块，增加了 SSH、UFW、rclone、SSL/Nginx、常用一键脚本、GitHub 镜像源测速、journalctl 日志管理等个人常用功能。

## 一键运行

```bash
bash <(curl -sSL https://daimon-linux-scripts.333186.xyz/tools-linux.sh)
```

如果 CDN 路径映射成 `daimon.sh`，也可以使用：

```bash
bash <(curl -sSL https://daimon-linux-scripts.333186.xyz/daimon.sh)
```

注意：`<(` 中间不能有空格。

## 快捷命令

首次运行后脚本会把快捷命令配置为：

```bash
d
```

之后可以直接在服务器命令行输入 `d` 打开工具箱。

## 主要功能

- 系统信息查询：CPU、内存、硬盘、网络、IPv4/IPv6、DNS、系统版本、运行时长等。
- 系统更新与清理：更新软件包、清理缓存、清理 journal 日志。
- 系统工具：快捷键、软件源、DNS、IPv4/IPv6 优先级、Swap、用户、时区、主机名、hosts、环境变量、GitHub 镜像源、DD 重装、SSH IP、网卡、journalctl、系统网络自适应优化、禁用/开启 IPv6、bat 终端高亮配置。
- Docker 管理：安装、状态、容器、镜像、网络、卷、清理、镜像源、daemon.json、IPv6、备份迁移还原、卸载。
- 基础工具：python、npm、nodejs、bun、uv、git、curl、iptables-persistent、ufw、firewalld、fail2ban、tree、fzf、ranger、neofetch、vim、Claude Code、Codex CLI 等。
- BBR 管理：调用 `tcpx.sh` 进行网络优化管理。
- SSH 配置：端口、密码登录、密钥登录、一键加固、公钥/私钥管理、编辑 sshd_config。
- UFW 防火墙管理：安装、卸载、开放端口、删除端口规则。
- SSL 证书申请 + 自动续期 & Nginx 管理：acme.sh 申请证书、配置反向代理、删除证书和配置、测试页管理。
- 常用一键脚本：NodeQuality、IPQuality、融合怪、NetQuality、RegionRestrictionCheck、bench.sh、YABS、HardwareQuality、勇哥脚本。
- 测试脚本合集：IP/解锁、回程路由、测速、性能测试。
- WARP 管理：调用 fscarmen WARP 菜单脚本。
- 甲骨文云脚本合集：闲置机器活跃、ROOT 密码登录、IPv6 恢复等。
- 应用市场：调用 Docker 应用部署菜单。
- rclone 配置：安装、配置文件编辑、卸载。

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

## 致谢

- 上游项目：<https://github.com/kejilion/sh>
- 本项目仓库：<https://github.com/daimon3332/daimon-linux-scripts>
