#!/bin/bash

debian_basics_install() {
	daimon_is_debian || { echo "仅支持 Debian。"; return 1; }
	[ "$EUID" -eq 0 ] || { echo "请以 root 身份安装基础工具。"; return 1; }
	command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || {
		echo "缺少 apt-get 或 dpkg-query，无法安装。"
		return 1
	}
	local package
	local -a selected=() missing=()
	for package in "$@"; do
		case "$package" in
			ca-certificates|curl|wget|jq) ;;
			*) echo "无效的 Debian 软件包: $package"; return 1 ;;
		esac
		[[ " ${selected[*]} " == *" $package "* ]] || selected+=("$package")
	done
	[ "${#selected[@]}" -gt 0 ] || { echo "没有选择软件包。"; return 0; }
	for package in "${selected[@]}"; do
		[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = "install ok installed" ] || missing+=("$package")
	done
	if [ "${#missing[@]}" -eq 0 ]; then
		echo "所选基础工具均已安装，无需更改。"
		return 0
	fi
	echo "将安装缺失的软件包: ${missing[*]}"
	DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get update -y || return 1
	DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none \
		apt-get install -y --no-install-recommends --no-remove \
		-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${missing[@]}" || return 1
	for package in "${selected[@]}"; do
		[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = "install ok installed" ] || {
			echo "安装后验证失败: $package"
			return 1
		}
	done
	hash -r
	echo "Debian 基础工具安装完成: ${selected[*]}"
}

debian_basics_menu() {
	daimon_is_debian || { echo "仅支持 Debian。"; break_end; return 1; }
	local -a packages=(ca-certificates curl wget jq)
	local -a descriptions=(HTTPS证书 下载工具 备用下载 JSON解析)
	local i package missing=0 answer
	clear
	echo "Debian 基础工具"
	echo "仅安装所选的缺失软件包；不升级系统、修复依赖或更改服务。"
	for ((i=0; i<${#packages[@]}; i++)); do
		package="${packages[i]}"
		if [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = "install ok installed" ]; then
			printf '%2d. %-18s %-12s 已安装\n' "$((i+1))" "$package" "${descriptions[i]}"
		else
			printf '%2d. %-18s %-12s 未安装\n' "$((i+1))" "$package" "${descriptions[i]}"
			missing=$((missing+1))
		fi
	done
	[ "$missing" -gt 0 ] || { echo "Debian 基础工具均已安装。"; break_end; return 0; }
	read -e -p "安装以上缺失项？(Y/n): " answer || return 1
	case "$answer" in ''|y|Y) ;; *) echo "已取消"; return 0 ;; esac
	debian_basics_install "${packages[@]}"
	local status=$?
	break_end
	return "$status"
}
