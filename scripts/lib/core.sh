#!/bin/bash

send_stats() {
	if [ "$ENABLE_STATS" == "false" ]; then
		return
	fi

	local country=$(curl -s --connect-timeout 3 --max-time 5 ipinfo.io/country)
	local os_info=$(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')
	local cpu_arch=$(uname -m)

	(
		curl -s --connect-timeout 3 --max-time 5 -X POST "https://api.kejilion.pro/api/log" \
			-H "Content-Type: application/json" \
			-d "{\"action\":\"$1\",\"timestamp\":\"$(date -u '+%Y-%m-%d %H:%M:%S')\",\"country\":\"$country\",\"os_info\":\"$os_info\",\"cpu_arch\":\"$cpu_arch\",\"version\":\"$sh_v\"}" \
		&>/dev/null
	) &

}

install() {
	if [ $# -eq 0 ]; then
		echo "未提供软件包参数!"
		return 1
	fi

	local package apt_updated=0
	for package in "$@"; do
		if command -v apt >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1 &&
			[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = "install ok installed" ]; then
			continue
		fi
		if ! command -v "$package" &>/dev/null; then
			echo -e "${gl_kjlan}正在安装 $package...${gl_bai}"
			if command -v dnf &>/dev/null; then
				dnf makecache || return 1
				dnf install -y epel-release || return 1
				dnf install -y "$package" || return 1
			elif command -v yum &>/dev/null; then
				yum makecache || return 1
				yum install -y epel-release || return 1
				yum install -y "$package" || return 1
			elif command -v apt &>/dev/null; then
				if [ "$apt_updated" -eq 0 ]; then
					DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l APT_LISTCHANGES_FRONTEND=none apt update -y ||
						echo -e "${gl_huang}部分软件源更新失败，继续使用现有索引安装 $package。${gl_bai}" >&2
					apt_updated=1
				fi
				DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l APT_LISTCHANGES_FRONTEND=none apt install -y \
					-o Dpkg::Options::="--force-confdef" \
					-o Dpkg::Options::="--force-confold" \
					"$package" || return 1
			elif command -v apk &>/dev/null; then
				apk update || return 1
				apk add "$package" || return 1
			elif command -v pacman &>/dev/null; then
				pacman -Syu --noconfirm "$package" || return 1
			elif command -v zypper &>/dev/null; then
				zypper refresh || return 1
				zypper install -y "$package" || return 1
			elif command -v opkg &>/dev/null; then
				opkg update || return 1
				opkg install "$package" || return 1
			elif command -v pkg &>/dev/null; then
				pkg update || return 1
				pkg install -y "$package" || return 1
			else
				echo "未知的包管理器!"
				return 1
			fi
		fi
	done
}

daimon_require_cmd() {
	local tool="$1" package="${2:-}"
	command -v "$tool" >/dev/null 2>&1 && return 0
	if [ -z "$package" ]; then
		case "$tool" in
			ss|tc|ip) package=iproute2 ;;
			flock|nsenter) package=util-linux ;;
			script) command -v apt-get >/dev/null 2>&1 && package=bsdutils || package=util-linux ;;
			timeout|stdbuf) package=coreutils ;;
			crontab) command -v apt-get >/dev/null 2>&1 && package=cron || package=cronie ;;
			*) package="$tool" ;;
		esac
	fi
	echo -e "${gl_kjlan}缺少 $tool，正在自动安装 $package...${gl_bai}"
	if ! install "$package"; then
		echo -e "${gl_hong}$package 安装失败，操作未执行；请检查上方软件源错误。${gl_bai}" >&2
		return 1
	fi
	hash -r
	command -v "$tool" >/dev/null 2>&1 || { echo -e "${gl_hong}$package 已安装但仍找不到 $tool，操作未执行。${gl_bai}" >&2; return 1; }
}

remove() {
	if [ $# -eq 0 ]; then
		echo "未提供软件包参数!"
		return 1
	fi

	for package in "$@"; do
		echo -e "${gl_kjlan}正在卸载 $package...${gl_bai}"
		if command -v dnf &>/dev/null; then
			dnf remove -y "$package"
		elif command -v yum &>/dev/null; then
			yum remove -y "$package"
		elif command -v apt &>/dev/null; then
			apt purge -y "$package"
		elif command -v apk &>/dev/null; then
			apk del "$package"
		elif command -v pacman &>/dev/null; then
			pacman -Rns --noconfirm "$package"
		elif command -v zypper &>/dev/null; then
			zypper remove -y "$package"
		elif command -v opkg &>/dev/null; then
			opkg remove "$package"
		elif command -v pkg &>/dev/null; then
			pkg delete -y "$package"
		else
			echo "未知的包管理器!"
			return 1
		fi
	done
	hash -r
}

break_end() {
	  local status=$?
	  [ "${DAIMON_BATCH_MODE:-0}" = 1 ] && return 0
	  if [ "$status" -eq 0 ]; then
		  echo -e "${gl_lv}操作完成${gl_bai}"
	  else
		  echo -e "${gl_hong}操作失败（返回码 $status），请查看上方输出${gl_bai}"
	  fi
	  echo "按任意键继续..."
	  read -n 1 -s -r -p ""
	  echo ""
	  clear
}

break_end_unless() {
	local status=${3:-$?}
	[ "$1" = "$2" ] && return "$status"
	(exit "$status")
	break_end
}

kejilion() {
			cd ~
			kejilion_sh
}

root_use() {
clear
[ "$EUID" -ne 0 ] && echo -e "${gl_huang}提示: ${gl_bai}该功能需要root用户才能运行！" && break_end && kejilion
}

kejilion_update() {
    root_use
    echo "linux-tools-daimon 完整组件更新"
    if ! python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" update "${DAIMON_UPDATE_REVISION:-master}"; then
        echo "更新失败，原完整版本保留。" >&2
        return 1
    fi
    if [ -f "$DAIMON_SCRIPT_DIR/cert_nginx.sh" ] || [ -f "$DAIMON_ROOT_DIR/cert-renew.sh" ]; then
        : > "$DAIMON_CERT_HELPER_MARKER" || return 1
    fi
    echo "完整版本已校验并更新。"
    exec "${DAIMON_INSTALL_BIN:-/usr/local/bin/d}"
}
