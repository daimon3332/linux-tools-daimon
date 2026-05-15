# leitbogioro/Tools InstallNET.sh DD 重装原理分析

本文只基于开源源码分析，不靠猜测。分析对象是 `leitbogioro/Tools` 项目的 Linux 重装脚本，重点对应 daimon 菜单里的 DD 重装命令。

源码参考：

- `https://github.com/leitbogioro/Tools`
- `https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh`
- `https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/Alpine/alpineInit.sh`
- `https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/Ubuntu/ubuntuInit.sh`

本次分析曾临时缓存过以下源码文件（仅用于核对行号，不建议提交到仓库）：

- `_InstallNET.source.sh`
- `_alpineInit.source.sh`
- `_ubuntuInit.source.sh`

注意：下面的行号基于本次下载到本地的源码版本。上游更新后，行号可能变化，但逻辑以对应代码为准。

## 1. daimon 里当前 DD 菜单执行了什么

当前 daimon 的 DD 菜单核心命令是：

```bash
apt update -y
apt install -y wget
wget --no-check-certificate -qO /root/InstallNET.sh 'https://gitee.com/mb9e8j2/Tools/raw/master/Linux_reinstall/InstallNET.sh'
chmod a+x /root/InstallNET.sh
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'LeitboGi0ro'
reboot
```

含义：

1. 安装 `wget`。
2. 下载 `InstallNET.sh` 到 `/root/InstallNET.sh`。
3. 给脚本执行权限。
4. 以 `-ubuntu 22.04` 参数启动 Ubuntu 22.04 的镜像覆盖安装模式。
5. 设置重装后 root 密码为 `LeitboGi0ro`。
6. 用户确认后重启，让 GRUB 进入脚本准备好的临时安装环境。

## 2. 为什么可以通过命令行 DD 系统

它不是在当前运行中的 Linux 里直接把当前系统盘覆盖掉。

真实原理是：

1. 当前系统运行 `InstallNET.sh`。
2. 脚本检测当前系统、网络、磁盘、SSH 端口、GRUB、架构等信息。
3. 脚本下载一个很小的 Alpine netboot 内核和 initrd。
4. 脚本把自己的自动化配置、`ubuntuInit.sh` 等文件注入 initrd。
5. 脚本修改 GRUB，新增一个 “Install AlpineLinux ...” 的一次性启动项。
6. 服务器重启后，不再进入原系统，而是进入 Alpine 临时内存系统。
7. Alpine 临时系统运行 `ubuntuInit.sh`。
8. `ubuntuInit.sh` 下载 Ubuntu cloud image，并通过管道执行：

```bash
wget -O- "$DDURL" | xzcat | dd of="$IncDisk" status=progress
```

9. 上面这一步才是真正把 Ubuntu 镜像解压后写入系统盘。
10. 写盘完成后，脚本挂载新系统分区，写入 cloud-init、SSH、网络、密码、端口等配置。
11. 最后再次重启，机器从硬盘上的新 Ubuntu 系统启动。

所以，它能 DD 的关键不是“当前系统硬改当前硬盘”，而是“先把服务器引导进一个内存中的临时系统，然后由临时系统覆盖硬盘”。

## 3. 参数接收过程

### 3.1 `-ubuntu 22.04` 会进入 DD 模式

`_InstallNET.source.sh` 约第 109-114 行：

```bash
-ubuntu | -Ubuntu)
    shift
    ddMode='1'
    finalDIST="$1"
    targetRelese='Ubuntu'
    shift
    ;;
```

解释：

- `-ubuntu` 不是传统 Debian Installer 网络安装模式。
- 它把 `ddMode` 设置为 `1`。
- 把用户输入的 `22.04` 保存到 `finalDIST`。
- 把目标系统设置为 `Ubuntu`。

也就是说：

```bash
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'LeitboGi0ro'
```

会被解析成：

- 目标系统：Ubuntu
- 目标版本：22.04
- 模式：DD 镜像覆盖安装
- root 密码：`LeitboGi0ro`

### 3.2 SSH 端口怎么决定

`_InstallNET.source.sh` 约第 3246-3257 行：

```bash
if [[ "$sshPORT" ]]; then
    ...
else
    sshPORT=$(grep -Ei "^port|^#port" /etc/ssh/sshd_config | head -n 1 | awk -F' ' '{print $2}')
    [[ "$sshPORT" == "" ]] && sshPORT=$(netstat -anp | grep -i 'sshd: root' | grep -iw 'tcp' | awk '{print $4}' | head -n 1 | cut -d':' -f'2')
    [[ "$sshPORT" == "" ]] && sshPORT=$(netstat -anp | grep -i 'sshd: root' | grep -iw 'tcp6' | awk '{print $4}' | head -n 1 | awk -F':' '{print $NF}')
    ...
    sshPORT='22'
fi
```

解释：

- 如果用户传了 `-port`，优先使用用户指定端口。
- 如果没传 `-port`，脚本会尝试从 `/etc/ssh/sshd_config` 读取端口。
- 如果配置文件读不到，再尝试从当前 `sshd` 连接里判断端口。
- 如果仍然失败，才使用 `22`。

所以，当前 daimon 命令没有传 `-port`，最终端口不一定绝对是 22，而是：

1. 先看原系统 sshd 配置；
2. 再看当前连接；
3. 最后兜底为 22。

如果你想固定重装后 SSH 端口，建议后续把 daimon 的 DD 命令改成显式传参，例如：

```bash
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'LeitboGi0ro' -port 22
```

或者在菜单里让用户输入端口。

## 4. 为什么会先进入 Alpine

`_InstallNET.source.sh` 约第 3359-3376 行：

```bash
[[ "$ddMode" == '1' ]] && {
    if [[ "$targetRelese" == 'Ubuntu' ]] || [[ "$targetRelese" == 'Windows' ]] || [[ "$targetRelese" == 'AlmaLinux' ]] || [[ "$targetRelese" == 'Rocky' ]]; then
        Relese='AlpineLinux'
        tmpDIST='edge'
    fi
    linux_relese=$(echo "$Relese" | ...)
    checkVER
    checkDIST
}
```

解释：

- 只要是 `ddMode=1`，并且目标是 Ubuntu/Windows/AlmaLinux/Rocky，脚本就把临时安装环境切换为 AlpineLinux。
- 因此 VNC 里出现 `apk`、`busybox`、`eudev`、Alpine 包安装信息是正常的。
- Alpine 只是中转系统，不是最终要安装的系统。

## 5. Ubuntu 22.04 镜像 URL 怎么生成

`_InstallNET.source.sh` 约第 3582-3596 行：

```bash
[[ "$ubuntuDigital" == '22.04' ]] && finalDIST='jammy'
[[ "$ubuntuDigital" == '24.04' ]] && finalDIST='noble'
...
tmpURL="https://cloud-images.a.disk.re/$targetRelese/"
setFileType="xz"
packageName="$finalDIST-server-cloudimg-$ubuntuArchitecture"
verifyUrlValidationOfDdImages "$tmpURL$packageName.$setFileType"
```

对于当前命令：

```bash
-ubuntu 22.04
```

会得到：

- `22.04` 对应 Ubuntu 代号 `jammy`。
- x86_64/amd64 架构对应 `amd64`。
- 镜像格式是 `.xz`。

最终下载地址就是：

```text
https://cloud-images.a.disk.re/Ubuntu/jammy-server-cloudimg-amd64.xz
```

这和 VNC 截图里显示的下载地址一致。

## 6. 解压方式怎么选择

`_InstallNET.source.sh` 约第 3213-3224 行：

```bash
DDURL="$1"
if [[ "$setFileType" == "gz" ]]; then
    DEC_CMD="gunzip -dc"
elif [[ "$setFileType" == "xz" ]]; then
    DEC_CMD="xzcat"
fi
```

解释：

- Ubuntu cloud image 是 `.xz`。
- 所以解压命令 `DEC_CMD` 会被设置为：

```bash
xzcat
```

真正写盘时就是：

```bash
wget -O- 镜像地址 | xzcat | dd of=系统盘
```

## 7. 当前系统阶段：准备临时启动环境

### 7.1 下载 Alpine netboot 内核和 initrd

`_InstallNET.source.sh` 约第 3772-3780 行：

```bash
InitrdUrl="${LinuxMirror}/${DIST}/releases/${VER}/netboot/${InitrdName}"
VmLinuzUrl="${LinuxMirror}/${DIST}/releases/${VER}/netboot/${VmLinuzName}"
wget --no-check-certificate -qO '/tmp/initrd.img' "$InitrdUrl"
wget --no-check-certificate -qO '/tmp/vmlinuz' "$VmLinuzUrl"
```

解释：

- 下载 Alpine netboot 用的 `initrd.img`。
- 下载 Alpine netboot 用的 `vmlinuz`。
- 这两个文件是下一次启动进入 Alpine 临时系统的核心。

### 7.2 注入自动化脚本

`_InstallNET.source.sh` 约第 3971-3984 行：

```bash
elif [[ "$linux_relese" == 'alpinelinux' ]]; then
    ...
    alpineInstallOrDdAdditionalFiles \
      ".../Alpine/alpineInit.sh" \
      ".../Ubuntu/ubuntuInit.sh" \
      ...
fi
```

解释：

- 脚本会把 `alpineInit.sh`、`ubuntuInit.sh` 等自动化文件注入 Alpine initrd。
- 这样重启进 Alpine 后，临时系统就知道应该下载哪个 Ubuntu 镜像、写入哪个磁盘、设置什么密码和 SSH 端口。

### 7.3 重新打包 initrd

`_InstallNET.source.sh` 约第 4501-4504 行：

```bash
find . | cpio -o -H newc | gzip -1 >/tmp/initrd.img
```

解释：

- 前面已经把配置和初始化脚本塞进了 initrd 解包目录。
- 这里重新打包成新的 `/tmp/initrd.img`。
- 新 initrd 启动后会自动执行 DD 流程。

### 7.4 写入 GRUB 一次性启动项

`_InstallNET.source.sh` 约第 4837-4850 行：

```bash
cat >>/etc/grub.d/40_custom <<EOF
menuentry 'Install $Relese $DIST $VER' ...
  linux$BootHex $BootDIR/vmlinuz $BOOT_OPTION
  initrd$BootHex $BootDIR/initrd.img
}
EOF

grub2-mkconfig -o $GRUBDIR/$GRUBFILE
grub2-set-default "Install $Relese $DIST $VER"
grub2-reboot "Install $Relese $DIST $VER"
```

解释：

- 添加一个新的 GRUB 菜单项。
- 这个菜单项启动的是脚本准备好的 `/boot/vmlinuz` 和 `/boot/initrd.img`。
- `grub2-reboot` 表示下一次重启优先进入这个安装环境。
- 所以你执行脚本并重启后，VNC 会进入 Alpine 临时系统，而不是原系统。

### 7.5 把临时内核和 initrd 放到 `/boot`

`_InstallNET.source.sh` 约第 4863-4866 行：

```bash
cp -f /tmp/initrd.img /boot/initrd.img
cp -f /tmp/vmlinuz /boot/vmlinuz
```

解释：

- 把准备好的 initrd 和内核复制到 `/boot`。
- GRUB 菜单项会引用这两个文件。

## 8. Alpine 临时环境阶段

`_alpineInit.source.sh` 是 Alpine 临时系统里的初始化脚本。

### 8.1 为什么 VNC 能看到输出

`_alpineInit.source.sh` 第 5 行：

```bash
exec >/dev/tty0 2>&1
```

解释：

- 标准输出和错误输出都重定向到 `/dev/tty0`。
- 所以 VNC 控制台可以看到脚本输出。

`_ubuntuInit.source.sh` 第 5 行也有同样逻辑，因此下载 Ubuntu 镜像和 `dd` 进度也会显示在 VNC。

### 8.2 Alpine 会安装必要工具

`_alpineInit.source.sh` 约第 180-190 行：

```bash
apk update
apk add bind-tools curl e2fsprogs fail2ban grub lsblk lsof net-tools util-linux vim wget
```

`_ubuntuInit.source.sh` 约第 70-71 行：

```bash
apk update
apk add hdparm multipath-tools util-linux wget xz
```

解释：

- `apk` 是 Alpine 的包管理器。
- `wget` 用于下载 Ubuntu cloud image。
- `xz` 提供 `xzcat`，用于解压 `.xz` 镜像。
- `util-linux`、`kpartx`、`losetup` 等用于识别、映射、挂载写入后的磁盘分区。

## 9. 真正 DD 写盘发生在哪里

真正写盘不在 `InstallNET.sh` 主脚本里，而在 `Ubuntu/ubuntuInit.sh`。

`_ubuntuInit.source.sh` 约第 48-49 行读取配置：

```bash
DDURL=$(grep "DDURL" $confFile | awk '{print $2}')
DEC_CMD=$(grep "DEC_CMD" $confFile | awk '{print $2}')
```

`_ubuntuInit.source.sh` 约第 74 行执行真正写盘：

```bash
wget --no-check-certificate --report-speed=bits --tries=0 --timeout=10 --wait=5 -O- "$DDURL" | $DEC_CMD | dd of="$IncDisk" status=progress
```

解释：

- `wget -O- "$DDURL"`：下载镜像，但不保存成文件，而是输出到标准输出。
- `$DEC_CMD`：对下载流进行解压，Ubuntu 22.04 这里是 `xzcat`。
- `dd of="$IncDisk"`：把解压后的完整磁盘镜像写入系统盘。
- `status=progress`：显示 `dd` 写入进度。

这个命令等价于：

```bash
wget -O- https://cloud-images.a.disk.re/Ubuntu/jammy-server-cloudimg-amd64.xz | xzcat | dd of=/dev/xxx status=progress
```

其中 `/dev/xxx` 是脚本检测到的系统盘，例如 `/dev/vda`、`/dev/sda`、`/dev/nvme0n1` 等。

## 10. 写盘之后做了什么

### 10.1 映射并挂载新系统分区

`_ubuntuInit.source.sh` 约第 76-87 行：

```bash
loopDevice=$(echo $(losetup -f))
losetup $loopDevice $IncDisk
mapperDevice=$(kpartx -av $loopDevice | grep "$loopDeviceNum" | head -n 1 | awk '{print $3}')
mount /dev/mapper/$mapperDevice /mnt
```

解释：

- 把刚写好的整块磁盘绑定到 loop 设备。
- 用 `kpartx` 识别里面的分区。
- 把 Ubuntu 系统分区挂载到 `/mnt`。
- 后续才能修改新系统里的配置文件。

### 10.2 写入 cloud-init 配置

`_ubuntuInit.source.sh` 约第 127-157 行：

```bash
wget --no-check-certificate -qO $cloudInitFile "$cloudInitUrl"
sed -ri 's/sshPORT/'${sshPORT}'/g' $cloudInitFile
sed -ri 's/HostName/'${HostName}'/g' $cloudInitFile
sed -ri 's/tmpWORD/'${tmpWORD}'/g' $cloudInitFile
...
```

解释：

- 下载 cloud-init 模板。
- 替换 SSH 端口、主机名、root 密码、时区、软件源、IPv4/IPv6、DNS、网关等占位符。
- 新系统首次启动时 cloud-init 会应用这些配置。

### 10.3 修改 SSH 配置

`_ubuntuInit.source.sh` 约第 169-176 行：

```bash
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /mnt/etc/ssh/sshd_config
sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /mnt/etc/ssh/sshd_config
sed -ri 's/^#?Port.*/Port '${sshPORT}'/g' /mnt/etc/ssh/sshd_config
sed -ri 's/^ListenStream=.*/ListenStream='${sshPORT}'/g' /mnt/lib/systemd/system/ssh.socket
sed -ri 's/^Accept=.*/Accept=yes/g' /mnt/lib/systemd/system/ssh.socket
```

解释：

- 允许 root 登录。
- 开启密码登录。
- 设置 SSH 端口。
- 同时修改 `ssh.socket`，因为 Ubuntu 22.10 之后部分版本可能通过 systemd socket 激活 SSH。

### 10.4 规避外置 cloud-init 干扰

`_ubuntuInit.source.sh` 约第 160-161 行：

```bash
echo 'datasource_list: [ NoCloud, None ]' >/mnt/etc/cloud/cloud.cfg.d/90_dpkg.cfg
```

`_ubuntuInit.source.sh` 约第 309-311 行：

```bash
utilProgram=$(find /mnt/usr/lib/python* -name "util.py" | grep "cloudinit" | head -n 1)
sed -ri 's/iso9660/osi9876/g' $utilProgram
sed -ri 's#"blkid"#"echo"#g' $utilProgram
```

解释：

- 脚本会限制 cloud-init 数据源，优先用它自己写入的 NoCloud 配置。
- 同时修改 cloud-init 的部分检测逻辑，避免云厂商挂载的 ISO/配置盘覆盖脚本配置。

### 10.5 清理挂载并重启

`_ubuntuInit.source.sh` 约第 313-319 行：

```bash
umount /mnt
kpartx -dv $loopDevice
losetup -d $loopDevice
exec reboot
```

解释：

- 卸载新系统分区。
- 移除分区映射。
- 释放 loop 设备。
- 重启进入新写入的 Ubuntu 系统。

## 11. VNC 截图内容逐行解释

你截图里的界面不是最终 Ubuntu 系统，而是 Alpine 临时系统正在执行 `ubuntuInit.sh`。

下面按截图中出现的典型行解释。

### 11.1 `(52/60) Installing ...` 到 `(60/60) Installing xz ...`

含义：

- Alpine 正在通过 `apk` 安装依赖包。
- 这些工具用于下载、解压、映射磁盘和写盘。

对应源码：`_ubuntuInit.source.sh` 约第 70-71 行：

```bash
apk update
apk add hdparm multipath-tools util-linux wget xz
```

其中：

- `wget`：下载 Ubuntu 镜像。
- `xz`：解压 `.xz` 镜像。
- `util-linux`：提供 `losetup` 等工具。
- `multipath-tools`：提供/配合分区映射相关工具。

### 11.2 `Executing busybox...trigger`

含义：

- Alpine 包安装后的触发器。
- `busybox` 是 Alpine 临时系统里的基础命令集合。
- 这是正常安装过程，不是错误。

### 11.3 `Executing eudev...trigger`

含义：

- `eudev` 负责设备节点管理。
- 写盘需要识别 `/dev/vda`、`/dev/sda`、`/dev/nvme0n1` 等块设备。
- 这是正常安装过程。

### 11.4 `OK: 24.8 MiB in 99 packages`

含义：

- Alpine 依赖包安装完成。
- 临时环境已经具备下载、解压和写盘工具。

### 11.5 `https://cloud-images.a.disk.re/Ubuntu/jammy-server-cloudimg-amd64.xz`

含义：

- 开始下载 Ubuntu 22.04 amd64 cloud image。
- `jammy` 是 Ubuntu 22.04 的发行代号。
- `.xz` 是压缩格式。

对应源码：`_InstallNET.source.sh` 约第 3582-3596 行。

### 11.6 `Resolving cloud-images.a.disk.re...`

含义：

- 正在 DNS 解析镜像域名。
- 如果这里卡住，通常是 DNS 或网络问题。

### 11.7 `Connecting to ... connected`

含义：

- 已经连接到镜像服务器。
- TCP 连接成功。

### 11.8 `HTTP request sent, awaiting response... 200 OK`

含义：

- 镜像服务器接受请求，返回完整文件下载。
- `200 OK` 表示从文件开头开始下载。

### 11.9 `Length: 581861224 (555M) [application/octet-stream]`

含义：

- 压缩镜像大小约 555MB。
- 注意这是 `.xz` 压缩包大小，不是解压后的磁盘镜像大小。

### 11.10 `Saving to: 'STDOUT'`

含义：

- 因为源码使用了 `wget -O-`。
- 文件不会保存到磁盘，而是直接输出到管道。

对应源码：`_ubuntuInit.source.sh` 约第 74 行：

```bash
wget ... -O- "$DDURL" | $DEC_CMD | dd of="$IncDisk" status=progress
```

也就是说数据流是：

```text
下载流 -> xzcat 解压 -> dd 写入磁盘
```

### 11.11 `0% ... 1.30M ... in 2m20s`

含义：

- 下载速度很慢。
- 这是下载压缩包的进度，不是最终写盘进度。
- 如果镜像源到服务器网络很差，就会长时间停在这里。

### 11.12 `Read error at byte ... Operation timed out. Retrying`

含义：

- `wget` 下载超时。
- 源码参数允许它自动重试。

对应源码：`_ubuntuInit.source.sh` 约第 74 行：

```bash
--tries=0 --timeout=10 --wait=5
```

解释：

- `--tries=0`：无限重试。
- `--timeout=10`：10 秒超时。
- `--wait=5`：失败后等 5 秒再试。

所以看到重试不一定代表失败，只是网络慢或中途断流。

### 11.13 `(try: 2)`

含义：

- 第二次下载尝试。
- 因为上一次超时。

### 11.14 `206 Partial Content`

含义：

- HTTP 断点续传。
- `wget` 不是从 0 开始重新下载，而是从已下载位置继续。
- 这是正常现象。

### 11.15 `Length: 581861224 (555M), 580501654 (554M) remaining`

含义：

- 总大小还是 555MB。
- 剩余约 554MB。
- 说明前面只下载了很少一部分。

### 11.16 `230597120 bytes ... copied ...`

含义：

- 这是 `dd status=progress` 打印的写盘进度。
- 它显示的是解压后的数据写入量。
- 因为 `.xz` 解压后会变大，所以 `dd` 的 bytes 数字可能明显大于 wget 已下载的压缩包大小。

### 11.17 `23% ... 130.34M 306KB/s eta 5h 15m`

含义：

- 这是 `wget` 的下载进度。
- 已下载压缩包约 23%。
- 当前速度约 306KB/s。
- 预计还要 5 小时 15 分。

这个说明：当前最大问题是镜像源下载速度慢，不是 SSH 端口本身的问题。

## 12. 为什么现在 SSH 22 和 64400 都连不上

根据源码流程，在 VNC 还显示下载和 `dd` 进度时，系统处于中间态：

```text
原系统已经不在运行
↓
Alpine 临时系统正在内存中运行
↓
Ubuntu 镜像还没有完整写入并配置完成
↓
最终 Ubuntu 还没有启动
```

这个阶段 SSH 不通是正常的，原因包括：

1. 原系统已经被 GRUB 切换走了。
2. Alpine 临时系统可能没有按你预期开放 SSH。
3. 正在写盘时，最终 Ubuntu 系统还没有启动。
4. 端口配置要等 `ubuntuInit.sh` 写入新系统并重启后才生效。
5. 如果下载速度极慢，整个阶段会持续很久。

所以：

- VNC 里还在下载 `jammy-server-cloudimg-amd64.xz` 时，不要判断为安装完成。
- 要等它完成下载、完成 `dd`、完成配置、自动重启。
- 重启后再尝试 SSH。

## 13. 这个 DD 流程的风险点

### 13.1 镜像源慢会导致长时间中间态

当前源码默认 Ubuntu cloud image 地址是：

```text
https://cloud-images.a.disk.re/Ubuntu/jammy-server-cloudimg-amd64.xz
```

如果这条线路很慢，就会出现 VNC 中 ETA 很长的情况。

### 13.2 中断会导致系统盘处于半写入状态

真正写盘命令是：

```bash
wget -O- "$DDURL" | xzcat | dd of="$IncDisk" status=progress
```

如果中途断电、强制重启、控制台关闭导致流程中断，系统盘可能只写入了一部分镜像。这时原系统也可能已经被破坏，新系统也没有完整写好。

### 13.3 SSH 端口最好显式指定

当前 daimon 没有传 `-port`，脚本会自动检测原 SSH 端口，失败才用 22。

为了减少不确定性，建议后续 DD 菜单改成：

```bash
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'LeitboGi0ro' -port 22
```

或者菜单询问：

```text
请输入重装后 SSH 端口，默认 22：
```

### 13.4 云厂商网络环境可能影响最终登录

虽然脚本会写入网络配置，但云厂商环境可能存在：

- 网卡名差异；
- DHCP/静态网络差异；
- 安全组没放行；
- 防火墙规则；
- cloud-init 数据源覆盖；
- 串口控制台和 GRUB 参数差异。

这些都可能导致最终系统启动后 SSH 不通。

## 14. 当前情况下建议怎么做

如果 VNC 仍然显示正在下载或正在 `dd`：

1. 不要反复重启。
2. 等待下载完成。
3. 观察是否出现卸载分区、重启等动作。
4. 等自动重启后，再测试 SSH。

如果长时间卡在下载，例如 ETA 数小时：

1. 优先继续等，避免半写盘。
2. 如果确认无法完成，只能通过云厂商控制台重装系统或重新挂载救援系统。
3. 后续修改 daimon DD 菜单，支持更快镜像源，或者使用云厂商官方重装系统。

## 15. 后续对 daimon 脚本的改进建议

建议把 DD 菜单改得更明确：

1. 执行前提示：该功能会清空系统盘，不可逆。
2. 显示原理：先进入 Alpine 临时系统，再下载 Ubuntu cloud image 并写盘。
3. 让用户输入 SSH 端口，默认 22，并显式传 `-port`。
4. 让用户输入 root 密码，不要写死。
5. 显示镜像地址，并允许选择备用镜像。
6. DD 前提示：VNC 出现 Alpine、apk、wget、dd 进度是正常现象。
7. DD 过程中不要随意重启，否则可能半写盘。

推荐命令模板：

```bash
bash /root/InstallNET.sh -ubuntu 22.04 -pwd '用户输入的密码' -port '用户输入的端口'
```

如果仍使用默认值：

```bash
bash /root/InstallNET.sh -ubuntu 22.04 -pwd 'LeitboGi0ro' -port 22
```

## 16. 一句话总结

`InstallNET.sh -ubuntu 22.04` 的核心不是传统安装器，而是：当前系统准备一个 Alpine 临时启动环境，重启进入内存 Alpine，然后由 `ubuntuInit.sh` 下载 Ubuntu cloud image，执行 `wget | xzcat | dd` 覆盖系统盘，再挂载新系统写入 SSH、密码、网络和 cloud-init 配置，最后重启进入新 Ubuntu。
