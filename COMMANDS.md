# linux-tools-daimon 命令教程

本文按脚本菜单整理每个选项背后的核心命令。说明以 Ubuntu 为例，只列关键命令，不展开 if/else、循环、颜色输出等交互细节。

## 运行与目录

```bash
bash <(curl -fsSL https://daimon-linux-scripts.333186.xyz/linux-toolbox.sh)
```
解释：在线拉取并运行主脚本。

```bash
d
```
解释：已安装快捷命令后，直接启动工具箱。

```bash
mkdir -p /root/daimon
```
解释：创建第三方脚本缓存目录。

## 一级菜单默认展示

进入主菜单主要是 `echo/read/case` 交互，不会主动修改系统。主菜单选项为：

1. 系统信息查询
2. 系统更新
3. 系统清理
4. 系统工具
5. Docker管理
6. 基础工具
7. 第三方工具
8. BBR管理
9. SSH配置
10. UFW防火墙管理
11. SSL证书申请+自动续期 & Nginx管理
12. 常用的一键脚本
13. WARP管理
00. 脚本更新
0. 退出脚本

脚本更新：

```bash
curl -fsSL --max-time 60 -o /tmp/daimon_tmp.xxxxxx "$DAIMON_UPDATE_URL"
cp -f ~/linux-toolbox.sh ~/linux-toolbox.sh.bak
mv -f /tmp/daimon_tmp.xxxxxx ~/linux-toolbox.sh
cp -f ~/linux-toolbox.sh /usr/local/bin/d
ln -sf /usr/local/bin/d /usr/bin/d
```
解释：下载新脚本、备份旧脚本、更新快捷命令。

## 1. 系统信息查询

默认展示：主机名、系统版本、内核、CPU、内存、Swap、硬盘、流量、网络算法、运营商、IPv4、IPv6、DNS、位置、时间、运行时长。

```bash
curl -s https://ipinfo.io/ip
curl -s --max-time 1 https://v6.ipinfo.io/ip
ip route get 8.8.8.8 | grep -oP 'src \K[^ ]+'
```
解释：查询公网 IPv4、公网 IPv6、本机默认出口内网 IP。

```bash
lscpu
nproc
cat /proc/cpuinfo
```
解释：查看 CPU 型号、核心数、频率等信息。

```bash
free -b
free -m
df -h
```
解释：查看内存、Swap、硬盘占用。

```bash
curl -s ipinfo.io
uptime
awk '/^nameserver/{print $2}' /etc/resolv.conf
uname -m
uname -n
uname -r
```
解释：查看 IP 地理位置、负载、DNS、架构、主机名、内核。

```bash
sysctl -n net.ipv4.tcp_congestion_control
sysctl -n net.core.default_qdisc
date "+%Y-%m-%d %I:%M %p"
cat /proc/uptime
ss -t | wc -l
ss -u | wc -l
```
解释：查看 TCP 算法、队列算法、时间、运行时长、TCP/UDP 连接数。

## 2. 系统更新

```bash
pkill -9 -f 'apt|dpkg'
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
DEBIAN_FRONTEND=noninteractive dpkg --configure -a
DEBIAN_FRONTEND=noninteractive apt update -y
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
```
解释：修复 apt/dpkg 状态，更新软件源并升级系统软件包。

## 3. 系统清理

```bash
pkill -9 -f 'apt|dpkg'
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
DEBIAN_FRONTEND=noninteractive dpkg --configure -a
apt autoremove --purge -y
apt clean -y
apt autoclean -y
journalctl --rotate
journalctl --vacuum-time=1s
journalctl --vacuum-size=500M
rm -rf /tmp/*
```
解释：修复包管理器状态，清理无用依赖、缓存、journal 日志和临时文件。

## 4. 系统工具

进入“系统工具”默认展示 1-20 号子选项，本身不修改系统。

### 4.1 设置脚本启动快捷键

```bash
find /usr/local/bin/ -type l -exec bash -c 'test "$(readlink -f {})" = "/usr/local/bin/d" && rm -f {}' \;
ln -sf /usr/local/bin/d /usr/local/bin/自定义快捷键
ln -sf /usr/local/bin/d /usr/bin/自定义快捷键
```
解释：清理旧快捷链接并创建新的快捷命令。

### 4.2 更换系统软件包镜像源

```bash
bash <(curl -sSL https://linuxmirrors.cn/main.sh)
```
解释：运行 linuxmirrors 脚本更换系统软件源。

### 4.3 优化 DNS 地址

默认展示：

```bash
cat /etc/resolv.conf
```
解释：显示当前 DNS 配置。

国外 DNS：

```bash
cp -L /etc/resolv.conf /etc/resolv.conf.daimon.bak
chattr -i /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
chattr +i /etc/resolv.conf
```
解释：写入 Cloudflare/Google DNS。

国内 DNS：

```bash
cp -L /etc/resolv.conf /etc/resolv.conf.daimon.bak
chattr -i /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 183.60.83.19
nameserver 2400:3200::1
nameserver 2400:da00::6666
EOF
chattr +i /etc/resolv.conf
```
解释：写入国内常用 DNS。

手动编辑：

```bash
apt install -y vim
cp -L /etc/resolv.conf /etc/resolv.conf.daimon.bak
chattr -i /etc/resolv.conf
vim /etc/resolv.conf
chattr +i /etc/resolv.conf
```
解释：用 vim 手动编辑 DNS。

恢复之前的 DNS 配置：

```bash
chattr -i /etc/resolv.conf
cat /etc/resolv.conf.daimon.bak > /etc/resolv.conf
```
解释：恢复脚本第一次修改 DNS 前备份的配置。如果没有备份，则写入 Ubuntu/systemd-resolved 常见本地 DNS：

```bash
cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.53
options edns0 trust-ad
search .
EOF
```

### 4.4 切换优先 IPv4/IPv6

默认展示：

```bash
grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100\s*$' /etc/gai.conf
```
解释：判断当前是否 IPv4 优先。

```bash
echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
```
解释：设置 IPv4 优先。

```bash
rm -f /etc/gai.conf
```
解释：恢复默认 IPv6 优先。

```bash
bash /root/daimon/jhb-v6.sh
```
解释：运行 IPv6 修复工具，来源 `https://jhb.ovh/jb/v6.sh`。

### 4.5 修改虚拟内存大小

默认展示：

```bash
free -m
```
解释：显示当前 Swap。

```bash
swapoff /swapfile
rm -f /swapfile
fallocate -l 2048M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
sed -i '/\/swapfile/d' /etc/fstab
echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
```
解释：设置 1024M/2048M/4096M/自定义大小 Swap，数值按用户选择替换。

### 4.6 用户管理

默认展示：

```bash
cat /etc/passwd
groups 用户名
sudo -n -lU 用户名
```
解释：列出用户、用户组、sudo 状态。

创建普通用户：

```bash
useradd -m -s /bin/bash 用户名
passwd 用户名
mkdir -p /home/用户名/.ssh
chmod 700 /home/用户名/.ssh
echo "公钥" >> /home/用户名/.ssh/authorized_keys
chmod 600 /home/用户名/.ssh/authorized_keys
chown -R 用户名:用户名 /home/用户名/.ssh
```
解释：创建普通用户并导入 SSH 公钥。

创建高级用户：

```bash
useradd -m -s /bin/bash 用户名
apt install -y sudo
usermod -aG sudo 用户名
cat > /etc/sudoers.d/用户名 <<EOF
用户名 ALL=(ALL:ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/用户名
visudo -cf /etc/sudoers.d/用户名
```
解释：创建用户并授予免密 sudo 权限。

赋予最高权限：

```bash
cat > /etc/sudoers.d/用户名 <<EOF
用户名 ALL=(ALL:ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/用户名
```
解释：写入 sudo 授权。

取消最高权限：

```bash
rm -f /etc/sudoers.d/用户名
sed -i "/^用户名\s*ALL=(ALL)/d" /etc/sudoers
```
解释：删除 sudo 授权。

删除账号：

```bash
userdel -r 用户名
```
解释：删除用户和家目录。

### 4.7 系统时区调整

默认展示：

```bash
timedatectl
```
解释：显示当前系统时间与时区。

```bash
timedatectl set-timezone Asia/Shanghai
timedatectl set-timezone Asia/Hong_Kong
timedatectl set-timezone Asia/Tokyo
timedatectl set-timezone Asia/Seoul
timedatectl set-timezone Asia/Singapore
timedatectl set-timezone Asia/Kolkata
timedatectl set-timezone Asia/Dubai
timedatectl set-timezone Australia/Sydney
timedatectl set-timezone Asia/Bangkok
timedatectl set-timezone Europe/London
timedatectl set-timezone Europe/Paris
timedatectl set-timezone Europe/Berlin
timedatectl set-timezone Europe/Moscow
timedatectl set-timezone Europe/Amsterdam
timedatectl set-timezone Europe/Madrid
timedatectl set-timezone America/Los_Angeles
timedatectl set-timezone America/New_York
timedatectl set-timezone America/Vancouver
timedatectl set-timezone America/Mexico_City
timedatectl set-timezone America/Sao_Paulo
timedatectl set-timezone America/Argentina/Buenos_Aires
timedatectl set-timezone UTC
```
解释：切换到对应时区。

### 4.8 修改主机名

```bash
hostname
echo "新主机名" > /etc/hostname
hostnamectl set-hostname "新主机名"
sed -i "s/127.0.0.1 .*/127.0.0.1       新主机名 localhost localhost.localdomain/g" /etc/hosts
sed -i "s/^::1 .*/::1             新主机名 localhost localhost.localdomain ipv6-localhost ipv6-loopback/g" /etc/hosts
```
解释：显示并修改主机名，同步 hosts。

### 4.9 本机 hosts 解析

```bash
cat /etc/hosts
echo "110.25.5.33 example.com" >> /etc/hosts
sed -i "/关键字/d" /etc/hosts
```
解释：查看、添加、删除 hosts 解析。

### 4.10 系统变量管理工具

```bash
printenv
echo "$PATH" | tr ':' '\n' | nl -ba
grep -E '^(export )?[A-Za-z_][A-Za-z0-9_]*=' ~/.bashrc ~/.profile /etc/environment
cat ~/.bashrc
cat ~/.profile
vim ~/.bashrc
vim ~/.profile
source ~/.bashrc
source ~/.profile
```
解释：查看、编辑、重新加载环境变量。

### 4.11 github镜像源

默认展示：

```bash
cat /root/daimon/github_proxy_sources.txt
```
解释：显示当前镜像源列表。

```bash
echo "https://ghproxy.net" >> /root/daimon/github_proxy_sources.txt
sed -i "编号d" /root/daimon/github_proxy_sources.txt
curl -L --connect-timeout 4 --max-time 12 --retry 0 -o /tmp/daimon_proxy_test_xxx -w "%{http_code} %{time_total} %{speed_download} %{size_download}" -s "镜像后的测试URL"
rm -f /tmp/daimon_proxy_test_xxx
```
解释：添加、删除、测速 GitHub 镜像源，测速文件会删除。

### 4.12 DD重装系统

默认展示：脚本来源、默认 Ubuntu 22.04、默认登录 `root / Tgadw2145qewO / 41000 端口`。

```bash
apt update -y
apt install -y wget
wget --no-check-certificate -qO /root/InstallNET.sh 'https://gitee.com/mb9e8j2/Tools/raw/master/Linux_reinstall/InstallNET.sh'
chmod a+x /root/InstallNET.sh
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'Tgadw2145qewO' -port 41000
reboot
```
解释：下载 leitbogioro/Tools 的 InstallNET 脚本到 `/root`，执行 Ubuntu DD 重装；默认指定 SSH 端口为 41000，除非用户在菜单中另行输入。

### 4.13 查看 ssh 的 ip

```bash
echo "$SSH_CONNECTION" | awk '{print $1,$2}'
echo "$SSH_CLIENT" | awk '{print $1,$2}'
who | awk -F'[()]' '/\(/ {print $2}' | awk '{print $1}' | sort -u
ss -Htnp | awk '$1=="ESTAB" && $0 ~ /(sshd|ssh)/ {print $5}'
```
解释：查看当前 SSH 来源 IP、登录会话来源 IP、已建立 SSH 连接 IP。

### 4.14 网卡管理工具

默认展示：

```bash
ls /sys/class/net
cat /sys/class/net/网卡/operstate
ip -4 addr show 网卡
cat /sys/class/net/网卡/address
```
解释：列出网卡、状态、IPv4、MAC。

```bash
ip link set 网卡 up
ip link set 网卡 down
ip addr show 网卡
ip route
```
解释：启用网卡、禁用网卡、查看详情、查看路由。

### 4.15 journalctl日志管理

```bash
cp /etc/systemd/journald.conf /etc/systemd/journald.conf.bak.$(date +%Y%m%d%H%M%S)
cat > /etc/systemd/journald.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald
```
解释：配置 journal 自动清理并重启 journald。

```bash
journalctl --disk-usage
journalctl -u nginx.service -n 200 --no-pager
journalctl --vacuum-time=7d
journalctl --vacuum-size=500M
```
解释：查看日志占用、服务日志、按时间清理、按大小清理。

### 4.16 系统网络自适应优化

默认展示：

```bash
sysctl -n net.ipv4.tcp_congestion_control
sysctl -n net.core.default_qdisc
[ -f /etc/sysctl.d/99-network-optimize.conf ]
```
解释：显示当前拥塞算法、队列算法、是否已安装自动优化配置。

执行自适应优化：

```bash
bash /root/daimon/network-optimize.sh
```
解释：运行 kejilion 的 `network-optimize.sh`，自动检测链路速率、延迟、丢包、内存、内核版本，并写入 `/etc/sysctl.d/99-network-optimize.conf`。

查看优化状态：

```bash
bash /root/daimon/network-optimize.sh status
```
解释：查看当前网络内核参数和优化配置状态。

回滚自适应优化：

```bash
bash /root/daimon/network-optimize.sh restore
```
解释：调用脚本内置回滚逻辑，恢复备份或删除自动优化配置。

### 4.17 禁用 IPv6

```bash
cat > /etc/sysctl.d/99-daimon-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-daimon-ipv6.conf
for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo 1 > "$f"; done
ip -6 addr show scope global
```
解释：通过 sysctl 配置禁用 IPv6，并同步当前所有网卡的 IPv6 状态。

### 4.18 开启 IPv6

```bash
cat > /etc/sysctl.d/99-daimon-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
sysctl -p /etc/sysctl.d/99-daimon-ipv6.conf
for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo 0 > "$f"; done
ip -6 addr show scope global
```
解释：通过 sysctl 配置开启 IPv6，并同步当前所有网卡的 IPv6 状态。

### 4.19 配置/删除cpcat

默认展示：

```bash
grep -q '^# ========== cpcat clipboard setup ==========$' ~/.bashrc
```
解释：检测 `~/.bashrc` 中是否已经写入 cpcat 配置块，并显示已配置/未配置状态。

配置 cpcat：

```bash
awk '/^# ========== cpcat clipboard setup ==========$/ {skip=1; next} /^[[:space:]]*# ========== end cpcat clipboard setup ==========$/ {skip=0; next} !skip {print}' ~/.bashrc > /tmp/daimon_bashrc
cat /tmp/daimon_bashrc > ~/.bashrc
cat >> ~/.bashrc <<'EOF'

# ========== cpcat clipboard setup ==========
# 一键复制文件内容到剪贴板（OSC 52）
cpcat() {
    if [ -f "$1" ]; then
        printf "\033]52;c;$(base64 < "$1" | tr -d '\n')\a"
        echo "✅ 已复制到剪贴板: $1"
    else
        echo "❌ 文件不存在: $1"
    fi
}
# ========== end cpcat clipboard setup ==========
EOF
source ~/.bashrc
```
解释：写入 `cpcat 文件路径` 命令，通过 OSC 52 把文件内容复制到本地终端剪贴板。

删除 cpcat：

```bash
awk '/^# ========== cpcat clipboard setup ==========$/ {skip=1; next} /^[[:space:]]*# ========== end cpcat clipboard setup ==========$/ {skip=0; next} !skip {print}' ~/.bashrc > /tmp/daimon_bashrc
cat /tmp/daimon_bashrc > ~/.bashrc
source ~/.bashrc
```
解释：只删除 `# ========== cpcat clipboard setup ==========` 到 `# ========== end cpcat clipboard setup ==========` 之间的内容。

### 4.20 卸载 daimon 脚本

```bash
rm -f /usr/local/bin/d /usr/bin/d ~/daimon.sh
```
解释：删除脚本和快捷命令，不影响其他已安装服务。

## 5. Docker 管理

进入 Docker 管理默认展示：

```bash
docker ps -a -q | wc -l
docker images -q | wc -l
docker network ls -q | wc -l
docker volume ls -q | wc -l
```
解释：统计容器、镜像、网络、卷数量。

### 5.1 安装更新 Docker 环境

```bash
bash /root/daimon/linuxmirrors-docker.sh --source mirrors.huaweicloud.com/docker-ce --source-registry docker.1ms.run --protocol http --use-intranet-source false --install-latest true --close-firewall false --ignore-backup-tips
apt install -y docker docker-compose
systemctl enable docker
systemctl start docker
systemctl restart docker
```
解释：优先通过 linuxmirrors 安装 Docker，失败时用包管理器兜底安装。

### 5.2 查看 Docker 全局状态

```bash
docker -v
docker compose version
docker image ls
docker ps -a
docker volume ls
docker network ls
```
解释：查看 Docker 版本、镜像、容器、卷、网络。

### 5.3 Docker 容器管理

默认展示：

```bash
docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
```
解释：显示容器列表。

```bash
docker run ...
docker start 容器名
docker stop 容器名
docker rm -f 容器名
docker restart 容器名
docker start $(docker ps -a -q)
docker stop $(docker ps -q)
docker rm -f $(docker ps -a -q)
docker restart $(docker ps -q)
```
解释：创建容器、启动/停止/删除/重启指定容器或全部容器。

```bash
docker exec -it 容器名 /bin/sh
docker logs 容器名
docker inspect --format '{{ .Name }}{{ range $network, $config := .NetworkSettings.Networks }} {{ $network }} {{ $config.IPAddress }}{{ end }}' 容器ID
docker stats --no-stream
```
解释：进入容器、查看日志、查看容器网络、查看资源占用。

```bash
docker port 容器名
iptables -I INPUT -p tcp --dport 端口 -j ACCEPT
iptables -I INPUT -p udp --dport 端口 -j ACCEPT
iptables -I INPUT -p tcp --dport 端口 -j DROP
iptables -I INPUT -p udp --dport 端口 -j DROP
```
解释：读取容器映射端口，并开放或关闭端口访问。

### 5.4 Docker 镜像管理

默认展示：

```bash
docker image ls
```
解释：显示镜像列表。

```bash
docker pull 镜像名
docker rmi -f 镜像名
docker rmi -f $(docker images -q)
```
解释：获取/更新镜像、删除指定镜像、删除全部镜像。

### 5.5 Docker 网络管理

默认展示：

```bash
docker network ls
docker inspect --format '{{ .Name }}{{ range $network, $config := .NetworkSettings.Networks }} {{ $network }} {{ $config.IPAddress }}{{ end }}' 容器ID
```
解释：显示 Docker 网络和容器 IP。

```bash
docker network create 网络名
docker network connect 网络名 容器名
docker network disconnect 网络名 容器名
docker network rm 网络名
```
解释：创建网络、加入网络、退出网络、删除网络。

### 5.6 Docker 卷管理

默认展示：

```bash
docker volume ls
```
解释：显示 Docker 卷。

```bash
docker volume create 卷名
docker volume rm 卷名
docker volume prune -f
```
解释：创建卷、删除指定卷、清理未使用卷。

### 5.7 清理无用 Docker 数据

```bash
docker system prune -af --volumes
```
解释：清理停止容器、无用镜像、网络、卷。

### 5.8 更换 Docker 源

默认回车写入前 5 个镜像源：

```json
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.1panel.live",
    "https://hub.rat.dev",
    "https://dockerproxy.net",
    "https://docker-registry.nmqu.com"
  ]
}
```

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json
systemctl restart docker
```
解释：写入 Docker daemon 镜像源并重启 Docker；选择官方源时写入 `https://registry-1.docker.io`。

### 5.9 编辑 daemon.json 文件

```bash
mkdir -p /etc/docker
vim /etc/docker/daemon.json
systemctl restart docker
```
解释：手动编辑 Docker daemon 配置并重启。

### 5.11 开启 Docker IPv6 访问

```bash
jq '. + {ipv6: true, "fixed-cidr-v6": "2001:db8:1::/64"}' /etc/docker/daemon.json > /etc/docker/daemon.json.tmp
mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
systemctl restart docker
```
解释：启用 Docker IPv6 配置。

### 5.12 关闭 Docker IPv6 访问

```bash
jq 'del(.["fixed-cidr-v6"]) | .ipv6 = false' /etc/docker/daemon.json > /etc/docker/daemon.json.tmp
mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
systemctl restart docker
```
解释：关闭 Docker IPv6 配置。

### 5.19 备份/迁移/还原 Docker 环境

默认展示：

```bash
ls -1dt /tmp/docker_backup_* 2>/dev/null
```
解释：显示已有备份。

```bash
docker ps --format '{{.Names}}'
docker inspect 容器名 > /tmp/docker_backup_时间/容器名_inspect.json
tar -czf /tmp/docker_backup_时间/compose_project_项目名.tar.gz -C compose目录 .
tar -czpf /tmp/docker_backup_时间/容器名_卷名.tar.gz -C / 卷路径
```
解释：备份容器 inspect、compose 目录、挂载卷。

```bash
tar -czf /tmp/docker_backup_xxx.tar.gz /tmp/docker_backup_xxx
scp -P SSH端口 -o StrictHostKeyChecking=no -r /tmp/docker_backup_xxx.tar.gz 用户@目标IP:/tmp/
```
解释：迁移备份到目标服务器。

```bash
tar -xzf compose_project_项目名.tar.gz -C 原目录
cd 原目录 && docker compose down && docker compose up -d
docker run -d --name 容器名 -p 主机端口:容器端口 -v 主机路径:容器路径 -e 环境变量 镜像
```
解释：还原 compose 项目或普通容器。

```bash
rm -rf /tmp/docker_backup_时间
```
解释：删除备份目录。

### 5.20 卸载 Docker 环境

```bash
docker ps -a -q | xargs -r docker rm -f
docker images -q | xargs -r docker rmi
docker network prune -f
docker volume prune -f
apt purge -y docker docker-compose docker-ce docker-ce-cli containerd.io
rm -f /etc/docker/daemon.json
```
解释：删除 Docker 数据并卸载 Docker。

## 6. 基础工具

基础工具默认展示每个工具编号、说明、是否已安装，当前顺序为：

1. python
2. npm
3. nodejs
4. bun
5. uv
6. git
7. ClaudeCode
8. Codex

```bash
command -v python3 || command -v python
command -v npm
command -v node
command -v bun
command -v uv
command -v git
command -v claude
command -v codex
```
解释：判断基础/编程工具是否存在。

菜单操作：

```bash
apt install -y 工具名
apt purge -y 工具名
read -e -i "1 2 3 ... 最后编号" -p "请确认/修改要安装或卸载的工具编号: " nums
```
解释：安装/卸载当前分类中选择的工具，支持多选；“全部安装 / 全部卸载”会先预填当前分类的全部编号，执行前可手动删除不需要的编号。

编程工具安装核心命令：

```bash
apt install -y python3 python3-pip python3-venv python-is-python3
apt install -y npm
apt install -y nodejs
apt install -y git
bash /root/daimon/bun-install.sh
bash /root/daimon/uv-install.sh
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
```
解释：安装 Python、Node/npm、Bun、uv、Git、ClaudeCode、Codex。Bun 和 uv 安装时会内部安装/使用 curl，但 curl 不再作为第三方工具列表项显示。

## 7. 第三方工具

第三方工具默认展示每个工具编号、说明、是否已安装，当前顺序为：

1. vim
2. cpcat
3. Ctrl+D
4. starship
5. bat
6. btop
7. tree
8. ripgrep
9. fd
10. fzf
11. ble.sh
12. ranger
13. fastfetch
14. wget
15. sudo
16. socat
17. htop
18. iftop
19. unzip
20. tar
21. tmux
22. ffmpeg
23. ncdu
24. fail2ban
25. iptables-persistent
26. ufw
27. firewalld

```bash
command -v 工具名
grep -qxF 'export EDITOR=vim' ~/.bashrc
grep -q '^# ========== cpcat clipboard setup ==========$' ~/.bashrc
grep -q '^# ==================== Ctrl+D 改为删除下一个单词 ====================$' ~/.bashrc
command -v starship
command -v batcat || command -v bat
command -v rg
command -v fd || command -v fdfind
test -x ~/.fzf/bin/fzf
grep -q '^# ========== fzf 核心配置 ==========$' ~/.bashrc
test -f ~/.local/share/blesh/ble.sh
grep -q '^# ========== ble.sh setup ==========$' ~/.bashrc
command -v netfilter-persistent || dpkg -s iptables-persistent
command -v firewall-cmd
```
解释：判断第三方工具是否存在。

菜单操作：

```bash
apt install -y 工具名
apt purge -y 工具名
read -e -i "1 2 3 ... 最后编号" -p "请确认/修改要安装或卸载的工具编号: " nums
```
解释：安装/卸载当前分类中选择的工具，支持多选；“全部安装 / 全部卸载”会先预填当前分类的全部编号，执行前可手动删除不需要的编号。

第三方工具安装核心命令：

```bash
apt install -y vim
echo 'export EDITOR=vim' >> ~/.bashrc
echo 'export VISUAL=vim' >> ~/.bashrc
cat >> ~/.bashrc <<'EOF'
# ========== cpcat clipboard setup ==========
# 一键复制文件内容到剪贴板
cpcat() {
    if [ -f "$1" ]; then
        printf "\033]52;c;$(base64 < "$1" | tr -d '\n')\a"
        echo "✅ 已复制到剪贴板: $1"
    else
        echo "❌ 文件不存在: $1"
    fi
}
# ========== end cpcat clipboard setup ==========
EOF
cat >> ~/.bashrc <<'EOF'
# ==================== Ctrl+D 改为删除下一个单词 ====================
bind '"\C-d": kill-word'
# ==================== end Ctrl+D 改为删除下一个单词 ====================
EOF
source ~/.bashrc
curl -fsSL https://starship.rs/install.sh -o /root/daimon/starship-install.sh
sh /root/daimon/starship-install.sh -y
cat >> ~/.bashrc <<'EOF'
# ========== starship prompt setup ==========
eval "$(starship init bash)"
# ========== end starship prompt setup ==========
EOF
cat >> ~/.zshrc <<'EOF'
# ========== starship prompt setup ==========
eval "$(starship init zsh)"
# ========== end starship prompt setup ==========
EOF
mkdir -p ~/.config
vim ~/.config/starship.toml
apt install -y bat btop
cat > ~/.bat.sh <<'EOF'
# 写入 bauto、blog、byaml、bjson、bhttp、raw 以及 docker/ping/systemctl/git 等查看类命令包装函数
EOF
cat >> ~/.bashrc <<'EOF'
# ========== bat 终端着色增强 ==========
if [ -f ~/.bat.sh ]; then
    source ~/.bat.sh
fi
EOF
apt install -y tree ripgrep fd-find ranger fastfetch wget sudo socat htop iftop unzip tar tmux ffmpeg ncdu
echo "alias fd='fdfind'" >> ~/.bashrc
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --key-bindings --completion --no-update-rc
cat >> ~/.bashrc <<'EOF'
# ========== fzf 核心配置 ==========
[ -d "$HOME/.fzf/bin" ] && export PATH="$HOME/.fzf/bin:$PATH"
command -v fzf >/dev/null 2>&1 || return
if command -v fdfind >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fdfind --type f --strip-cwd-prefix --hidden --follow --exclude .git'
elif command -v fd >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
fi
if command -v batcat >/dev/null 2>&1; then
  BAT_PREVIEW='batcat --color=always --style=numbers --line-range=:500 {}'
elif command -v bat >/dev/null 2>&1; then
  BAT_PREVIEW='bat --color=always --style=numbers --line-range=:500 {}'
else
  BAT_PREVIEW='sed -n "1,500p" {}'
fi
export FZF_DEFAULT_OPTS="
  --height 50%
  --layout=reverse
  --border
  --inline-info
  --preview '$BAT_PREVIEW'
  --preview-window=right:50%
  --bind 'ctrl-/:toggle-preview'
"
export FZF_CTRL_T_OPTS="--preview '$BAT_PREVIEW'"
if command -v tree >/dev/null 2>&1; then
  export FZF_ALT_C_OPTS="--preview 'tree -C {} | head -200'"
else
  export FZF_ALT_C_OPTS="--preview 'ls -la {} | head -200'"
fi
# ========== end fzf 核心配置 ==========
EOF
source ~/.bashrc
git clone --recursive https://github.com/akinomyoga/ble.sh.git ~/ble.sh
cd ~/ble.sh
apt update -y && apt install -y make
make install
cat >> ~/.bashrc <<'EOF'
# ========== ble.sh setup ==========
[ -f ~/.local/share/blesh/ble.sh ] && source ~/.local/share/blesh/ble.sh
# ========== end ble.sh setup ==========
EOF
cat > ~/.blerc <<'EOF'
# 自动补全
bleopt complete_auto_complete=1
# history 自动补全
bleopt complete_auto_history=1
# 如果已安装 fzf，则启用 fzf 快捷键
if command -v fzf >/dev/null 2>&1 || [ -x "$HOME/.fzf/bin/fzf" ]; then
  ble-import -d integration/fzf-key-bindings
fi
EOF
source ~/.bashrc
apt install -y fail2ban
systemctl enable fail2ban && systemctl start fail2ban
apt install -y iptables-persistent
apt install -y ufw
ufw status
apt install -y firewalld
systemctl enable firewalld && systemctl start firewalld
firewall-cmd --state
```
解释：安装第三方常用工具；vim 会同时设置 `EDITOR=vim` 和 `VISUAL=vim`；cpcat、Ctrl+D、starship、bat 通过写入 `~/.bashrc` 或配置文件完成；btop、tree、ripgrep、fd 使用 apt 安装；Ubuntu 上 fd 对应包名通常是 fd-find，脚本会在 `~/.bashrc` 中补充 `alias fd='fdfind'`；fzf 使用 git clone 安装到 `~/.fzf`，并在缺少 fd/bat/tree 时自动安装依赖；fzf 配置会自动兼容 `fd/fdfind`、`bat/batcat`，没有 bat 时回退到 `sed`，没有 tree 时回退到 `ls`；ble.sh 会写入 `~/.bashrc` 和 `~/.blerc`，只有检测到 fzf 时才启用 fzf 快捷键；防火墙相关工具排在第三方工具列表最后。

特殊卸载：

```bash
sed -i '/^export EDITOR=vim$/d;/^export VISUAL=vim$/d' ~/.bashrc
# 删除 ~/.bashrc 中 cpcat clipboard setup 配置块
# 删除 ~/.bashrc 中 Ctrl+D 改为删除下一个单词配置块
# 删除 ~/.bashrc / ~/.zshrc 中 starship prompt setup 配置块
rm -f ~/.config/starship.toml /root/daimon/starship-install.sh /usr/local/bin/starship /usr/bin/starship ~/.local/bin/starship ~/.cargo/bin/starship
rm -f ~/.bat.sh
# 删除 ~/.bashrc 中 fzf 核心配置块
rm -rf ~/.fzf
# 删除 ~/.bashrc 中 ble.sh setup 配置块
rm -rf ~/ble.sh ~/.local/share/blesh ~/.blerc
rm -rf ~/.config/btop ~/.config/ranger ~/.local/share/ranger ~/.config/fastfetch ~/.config/htop ~/.htoprc
systemctl stop fail2ban ufw firewalld netfilter-persistent 2>/dev/null
systemctl disable fail2ban ufw firewalld netfilter-persistent 2>/dev/null
ufw disable
rm -rf /etc/fail2ban /var/lib/fail2ban /var/log/fail2ban.log /etc/iptables /etc/ufw /var/lib/ufw /etc/firewalld
apt purge -y bat batcat btop ripgrep fd-find fzf ranger fastfetch htop fail2ban iptables-persistent netfilter-persistent ufw firewalld
sed -i "/^alias fd='fdfind'$/d;/^alias fd=fdfind$/d;/^alias fd=\"fdfind\"$/d" ~/.bashrc
npm uninstall -g @anthropic-ai/claude-code
npm uninstall -g @openai/codex
rm -rf ~/.bun
rm -f ~/.local/bin/uv ~/.local/bin/uvx
```
解释：卸载第三方工具中的配置类内容，以及 ClaudeCode、Codex、Bun、uv 等特殊安装项。

## 8. BBR 管理

```bash
apt install -y wget curl
mkdir -p /root/daimon
curl -fsSL https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh -o /root/daimon/tcpx.sh
chmod +x /root/daimon/tcpx.sh
bash /root/daimon/tcpx.sh
```
解释：下载并运行 `tcpx.sh`，进入 BBR/加速管理菜单。

## 9. SSH 配置

进入 SSH 配置默认展示：

```bash
ss -tlnp | awk '/sshd/ {print $4}'
sshd -T | awk '$1 == "passwordauthentication" {print $2}'
sshd -T | awk '$1 == "pubkeyauthentication" {print $2}'
```
解释：显示当前 SSH 端口、密码登录状态、密钥登录状态。

### 8.1 修改 SSH 端口

```bash
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
sed -i 's|^[#[:space:]]*Port[[:space:]].*|Port 64400|' /etc/ssh/sshd_config
sshd -t
systemctl stop ssh.socket sshd.socket
systemctl disable ssh.socket sshd.socket
systemctl restart sshd || systemctl restart ssh
ufw allow 64400/tcp
```
解释：备份配置、修改端口、校验配置、重启 SSH、放行新端口。

### 8.2 禁用/开启密码登录

```bash
sed -i 's|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*|KbdInteractiveAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*ChallengeResponseAuthentication[[:space:]].*|ChallengeResponseAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*PermitEmptyPasswords[[:space:]].*|PermitEmptyPasswords no|' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```
解释：关闭密码和交互式认证。

```bash
sed -i 's|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*|KbdInteractiveAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*ChallengeResponseAuthentication[[:space:]].*|ChallengeResponseAuthentication yes|' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```
解释：开启密码登录。

### 8.3 开启/禁用密钥登录

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "你的公钥" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i 's|^[#[:space:]]*PubkeyAuthentication[[:space:]].*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*AuthorizedKeysFile[[:space:]].*|AuthorizedKeysFile .ssh/authorized_keys|' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```
解释：写入公钥并开启密钥登录。

```bash
sed -i 's|^[#[:space:]]*PubkeyAuthentication[[:space:]].*|PubkeyAuthentication no|' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```
解释：禁用密钥登录。

### 8.4 一键配置

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "你的公钥" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i 's|^[#[:space:]]*Port[[:space:]].*|Port 64400|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*PubkeyAuthentication[[:space:]].*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*AuthorizedKeysFile[[:space:]].*|AuthorizedKeysFile .ssh/authorized_keys|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^[#[:space:]]*PermitRootLogin[[:space:]].*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
apt install -y ufw
ufw allow 64400/tcp
yes | ufw delete allow 22/tcp
ufw deny 22/tcp
ufw --force enable
ufw reload
```
解释：端口改为 64400、关闭密码、开启密钥、root 只允许密钥、UFW 放行新端口并关闭 22。

### 8.5 公钥和私钥管理

默认展示：

```bash
nl -ba /root/.ssh/authorized_keys
find /root/.ssh -maxdepth 1 -type f ! -name '*.pub' ! -name 'authorized_keys' ! -name 'known_hosts' ! -name 'config' -printf '%f\n' | nl -ba
```
解释：显示公钥和私钥文件。

```bash
echo "你的公钥" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i '行号d' /root/.ssh/authorized_keys
cat > /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519
rm -f /root/.ssh/私钥文件名
```
解释：添加公钥、删除公钥、添加私钥、删除私钥。

### 8.6 修改 sshd_config 配置文件

```bash
vim /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```
解释：手动编辑 SSH 服务端配置，并校验重启。

## 10. UFW 防火墙管理

默认展示：

```bash
ufw status | head -n 12
```
解释：显示 UFW 当前状态。

```bash
apt install -y ufw
ufw --force enable
ufw status
```
解释：安装并启用 UFW。

```bash
ufw disable
apt purge -y ufw
```
解释：禁用并卸载 UFW。

```bash
ufw allow 80
ufw allow 80/tcp
ufw status numbered
```
解释：开放端口。

```bash
ufw delete allow 80
ufw delete allow 80/tcp
ufw status numbered
```
解释：删除端口 allow 规则。

## 11. SSL 证书申请+自动续期 & Nginx 管理

进入菜单前会确保 acme.sh：

```bash
apt install -y curl socat lsof dnsutils ufw openssl nginx
curl -fsSL https://get.acme.sh -o /root/daimon/acme-install.sh
sh /root/daimon/acme-install.sh email=asdad@163.com
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
```
解释：安装依赖、安装 acme.sh，并设置默认 CA。

默认菜单：1 申请证书+配置 nginx；2 删除 nginx 配置+证书；3 申请证书；4 移除证书；5 查看证书列表；6 配置 nginx；7 删除 nginx 配置；8 创建测试页面；9 删除测试页面。

申请证书：

```bash
dig +short example.com A
dig +short example.com AAAA
ufw allow 80/tcp
ufw allow 443/tcp
systemctl stop nginx
systemctl stop apache2
systemctl stop httpd
systemctl stop caddy
lsof -t -iTCP:80 -sTCP:LISTEN | xargs kill -9
~/.acme.sh/acme.sh --issue -d example.com --standalone --server letsencrypt --force
~/.acme.sh/acme.sh --install-cert -d example.com --fullchain-file /root/domain/example/fullchain.pem --key-file /root/domain/example/privkey.pem --force
```
解释：检查 DNS、释放 80 端口、申请并安装证书。

自动续期：

```bash
(crontab -l 2>/dev/null | grep -v "$HOME/.acme.sh/acme.sh --cron" ; echo "0 3 * * * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh >/dev/null 2>&1") | crontab -
```
解释：每天凌晨 3 点自动续期。

配置 Nginx：

```bash
apt install -y nginx
systemctl start nginx
systemctl enable nginx
cat > /etc/nginx/sites-available/配置名
ln -sf /etc/nginx/sites-available/配置名 /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```
解释：生成 Nginx 配置并重载。配置核心包括 `listen 80` 跳转 HTTPS、`listen 443 ssl http2`、`ssl_certificate`、`proxy_pass http://127.0.0.1:端口`。

删除 nginx 配置 + 证书：

```bash
rm -f /etc/nginx/sites-available/配置名 /etc/nginx/sites-enabled/配置名
rm -rf /root/domain/example
~/.acme.sh/acme.sh --remove -d example.com
nginx -t && systemctl reload nginx
```
解释：删除站点配置、证书目录和 acme 记录。

查看/移除证书：

```bash
~/.acme.sh/acme.sh --list
ls -la /root/domain/
~/.acme.sh/acme.sh --remove -d example.com
rm -rf /root/domain/example
```
解释：查看证书列表或移除指定证书。

测试页面：

```bash
mkdir -p /var/www/测试名
cat > /var/www/测试名/index.html
cat > /etc/nginx/sites-available/测试名
ln -sf /etc/nginx/sites-available/测试名 /etc/nginx/sites-enabled/
nginx -t && nginx -s reload
curl http://127.0.0.1:端口
rm -f /etc/nginx/sites-enabled/测试名 /etc/nginx/sites-available/测试名
rm -rf /var/www/测试名
nginx -t && nginx -s reload
```
解释：创建或删除 Nginx 测试页面。

## 12. 常用的一键脚本

这些脚本会先退出当前脚本，再运行目标脚本，避免输出被主菜单覆盖。

```bash
bash /root/daimon/NodeQuality.sh
```
解释：NodeQuality 网络质量测试，来源 `https://run.NodeQuality.com`。

```bash
bash /root/daimon/IPQuality.sh
bash /root/daimon/IPQuality.sh -i eth0
bash /root/daimon/IPQuality.sh -x socks5://username:password@socksproxy:port
```
解释：IPQuality IP 纯净度和流媒体解锁检测，来源 `https://IP.Check.Place`。

```bash
bash /root/daimon/ecs.sh
```
解释：融合怪综合测评，来源 `https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh`。

```bash
bash /root/daimon/NetQuality.sh
```
解释：NetQuality 三网回程路由和延迟，来源 `https://Net.Check.Place`。

```bash
bash /root/daimon/RegionRestrictionCheck.sh
```
解释：RegionRestrictionCheck 流媒体解锁测试，来源 `https://check.unlock.media`。

```bash
bash /root/daimon/bench.sh
```
解释：bench.sh 系统信息、I/O、网络测速，来源 `https://bench.sh`。

```bash
bash /root/daimon/yabs.sh
```
解释：YABS 综合性能测试，来源 `https://yabs.sh`。

```bash
bash /root/daimon/HardwareQuality.sh -H
```
解释：HardwareQuality 硬件质量检测，来源 `https://Check.Place`。

```bash
bash /root/daimon/x-ui-yg-install.sh
```
解释：勇哥 x-ui-yg 脚本，来源 `https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh`。

```bash
bash <(curl -sL kejilion.sh)
```
解释：运行 kejilion.sh 一键脚本。

## 13. WARP 管理

进入 WARP 管理默认展示：是否存在 `warp` 快捷命令、是否存在 `warp` 网络接口。

进入 WARP 官方管理脚本：

```bash
apt install -y wget curl
bash /root/daimon/warp-menu.sh
```
解释：下载并运行 fscarmen WARP 菜单脚本，来源 `https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh`。

彻底删除 WARP：

```bash
apt install -y wget curl
bash /root/daimon/warp-menu.sh u
```
解释：调用 fscarmen 脚本的 `warp u` 逻辑，永久关闭并删除 WARP 网络接口、WARP Linux Client 和 WireProxy。

## rclone 配置菜单

进入 rclone 菜单默认展示：

```bash
rclone --version
ls -l /root/.config/rclone/rclone.conf
```
解释：显示 rclone 版本和配置文件路径；未安装时显示未安装。

安装 rclone：

```bash
curl https://rclone.org/install.sh | bash
mkdir -p /root/.config/rclone
touch /root/.config/rclone/rclone.conf
chmod 600 /root/.config/rclone/rclone.conf
rclone --version
```
解释：安装 rclone，创建空配置文件并设置权限。

修改配置文件：

```bash
mkdir -p /root/.config/rclone
touch /root/.config/rclone/rclone.conf
chmod 600 /root/.config/rclone/rclone.conf
vim /root/.config/rclone/rclone.conf
```
解释：用 vim 编辑 rclone 配置。

卸载 rclone：

```bash
rm -f /usr/bin/rclone /usr/local/bin/rclone
```
解释：删除 rclone 可执行文件，配置文件不自动删除。
