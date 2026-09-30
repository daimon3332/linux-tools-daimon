#!/bin/bash

linux_clean() {
	echo -e "${gl_kjlan}正在系统清理...${gl_bai}"
	local -a orphaned_packages=()
	if command -v dnf &>/dev/null; then
		rpm --rebuilddb || return 1
		dnf autoremove -y || return 1
		dnf clean all || return 1
		dnf makecache || return 1

	elif command -v yum &>/dev/null; then
		rpm --rebuilddb || return 1
		yum autoremove -y || return 1
		yum clean all || return 1
		yum makecache || return 1

	elif command -v apt &>/dev/null; then
		fix_dpkg || return 1
		DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt autoremove --purge -y || return 1
		DEBIAN_FRONTEND=noninteractive apt clean -y || return 1
		DEBIAN_FRONTEND=noninteractive apt autoclean -y || return 1

	elif command -v apk &>/dev/null; then
		echo "清理包管理器缓存..."
		apk cache clean || return 1

	elif command -v pacman &>/dev/null; then
		mapfile -t orphaned_packages < <(pacman -Qdtq)
		if [ "${#orphaned_packages[@]}" -gt 0 ]; then
			pacman -Rns "${orphaned_packages[@]}" --noconfirm || return 1
		fi
		pacman -Scc --noconfirm || return 1

	elif command -v zypper &>/dev/null; then
		zypper clean --all || return 1
		zypper refresh || return 1

	elif command -v opkg &>/dev/null; then
		echo "opkg 没有统一的安全缓存清理入口，跳过。"

	elif command -v pkg &>/dev/null; then
		echo "清理未使用的依赖..."
		pkg autoremove -y || return 1
		echo "清理包管理器缓存..."
		pkg clean -y || return 1

	else
		echo "未知的包管理器!"
		return 1
	fi
	if command -v journalctl >/dev/null 2>&1; then
		journalctl --rotate || return 1
		journalctl --vacuum-size=500M || return 1
	fi
	echo "已保留共享日志目录和临时文件，不自动清空 /var/log 或 /tmp。"
	return 0
}
