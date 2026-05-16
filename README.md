# linux-tools-daimon

`linux-tools-daimon` 是个人自用的 Linux 服务器脚本工具箱，中文交互，快捷命令为 `d`。

本项目基于 kejilion/sh 二开定制，删除了个人不需要的模块，增加了 SSH、UFW、rclone、SSL/Nginx、常用一键脚本、GitHub 镜像源测速、journalctl 日志管理等个人常用功能。

## 一键运行

```bash
bash <(curl -sSL https://daimon-linux-scripts.333186.xyz/linux-toolbox.sh)
```

## 快捷命令

首次运行后脚本会把快捷命令配置为：

```bash
d
```

之后可以直接在服务器命令行输入 `d` 打开工具箱。

## 主要内容

1. 系统信息查询
   - 展示主机名、系统版本、内核、CPU、内存、Swap、硬盘、流量、网络算法、运营商、IPv4、IPv6、DNS、位置、时间、运行时长等信息。

2. 系统更新
   - 修复 apt/dpkg 锁和未完成配置。
   - 更新软件源并执行系统软件包升级。

3. 系统清理
   - 清理无用依赖、apt 缓存、journal 日志、临时文件。

4. 系统工具
   1. 设置脚本启动快捷键
   2. 更换系统软件包镜像源
   3. 优化 DNS 地址
   4. IPv4 / IPv6 优先级调整
   5. Swap 管理
   6. 用户密码管理
   7. 系统时区调整
   8. 修改主机名
   9. hosts 文件管理
   10. 环境变量管理
   11. github 镜像源
   12. DD 重装系统
   13. 查看 ssh 的 ip
   14. 网卡管理工具
   15. journalctl 日志管理
   16. 系统网络自适应优化
   17. 禁用 IPv6
   18. 开启 IPv6
   19. bat 终端高亮配置
   20. 卸载 daimon 脚本

5. Docker 管理
   1. 安装更新 Docker 环境
   2. 查看 Docker 全局状态
   3. Docker 容器管理
   4. Docker 镜像管理
   5. Docker 网络管理
   6. Docker 卷管理
   7. Docker 清理
   8. Docker Compose 项目管理
   9. Docker 镜像源管理
   10. Docker daemon.json 管理
   11. Docker IPv6 配置
   12. Docker 容器端口访问控制
   13. Docker 容器日志查看
   14. Docker 容器资源占用查看
   15. Docker 容器网络信息查看
   16. Docker Compose 备份
   17. Docker Compose 迁移
   18. Docker 容器备份
   19. Docker 备份还原
   20. 卸载 Docker 环境

6. 基础工具
   - 按编号安装或卸载常用基础工具，支持多选、全部安装、全部卸载。
   - 工具顺序包括：python、npm、nodejs、bun、uv、git、curl、iptables-persistent、ufw、firewalld、fail2ban、tree、fzf、ranger、neofetch、vim、Claude Code、Codex CLI 等。

7. BBR 管理
   - 下载并运行 `tcpx.sh`，进入 BBR / 网络加速管理菜单。

8. SSH 配置
   1. 修改 SSH 端口
   2. 禁用 / 开启密码登录
   3. 开启 / 禁用密钥登录
   4. 一键配置
   5. 公钥和私钥管理
      - 添加公钥
      - 删除公钥
      - 添加私钥
      - 删除私钥
   6. 修改 `sshd_config` 配置文件

9. UFW 防火墙管理
   1. 安装 UFW
   2. 卸载 UFW
   3. 开放端口
   4. 删除端口规则

10. SSL 证书申请 + 自动续期 & Nginx 管理
    1. 申请证书 + 配置 nginx
    2. 删除 nginx 配置 + 证书
    3. 申请证书
    4. 移除证书
    5. 查看证书列表
    6. 配置 nginx
    7. 删除 nginx 配置
    8. 创建测试页面
    9. 删除测试页面

11. 常用的一键脚本
    1. NodeQuality
    2. IPQuality
    3. 融合怪
    4. NetQuality
    5. RegionRestrictionCheck
    6. bench.sh
    7. YABS
    8. HardwareQuality
    9. 勇哥脚本

12. 测试脚本合集
    - IP / 流媒体解锁检测
    - 三网回程、路由追踪、测速
    - YABS、GeekBench、bench、融合怪、NodeQuality 等性能测试

13. WARP 管理
    - 调用 fscarmen WARP 菜单脚本。

14. 甲骨文云脚本合集
    1. 安装闲置机器活跃脚本
    2. 卸载闲置机器活跃脚本
    3. 开启 ROOT 密码登录模式
    4. IPv6 恢复工具

15. 应用市场
    - 宝塔面板、aaPanel、1Panel、NginxProxyManager、OpenList、哪吒探针、qBittorrent、青龙面板、Cloudreve、Emby、Portainer、VSCode 网页版、Uptime Kuma、Nextcloud、WireGuard、Gitea、FileBrowser 等 Docker 应用安装、更新、卸载、备份和还原。

附加菜单：rclone 配置

- 显示 rclone 版本和配置文件状态。
- 安装 rclone。
- 修改 `/root/.config/rclone/rclone.conf`。
- 卸载 rclone。

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
