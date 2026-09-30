#!/bin/bash

linux_bbr() {
	clear
	send_stats "bbr管理"
	daimon_require_cmd wget && daimon_require_cmd curl || return 1
	mkdir -p "$DAIMON_SCRIPT_DIR"
	local tcpx="$DAIMON_SCRIPT_DIR/tcpx.sh" tmp
	local tcpx_url="https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh"
	tmp=$(mktemp "$DAIMON_SCRIPT_DIR/tcpx.sh.tmp.XXXXXX") || return 1
	if daimon_download_to "$tcpx_url" "$tmp" && [ -s "$tmp" ] && bash -n "$tmp"; then
		chmod +x "$tmp"
		mv -f "$tmp" "$tcpx"
		echo -e "${gl_lv}BBR 管理脚本已更新到上游最新版${gl_bai}"
	else
		rm -f "$tmp"
		if [ ! -s "$tcpx" ] || ! bash -n "$tcpx"; then
			echo -e "${gl_hong}BBR 管理脚本下载失败，且没有可用缓存${gl_bai}"
			return 1
		fi
		echo -e "${gl_huang}上游更新失败，继续使用本地缓存: $tcpx${gl_bai}"
	fi
	chmod +x "$tcpx"
	bash "$tcpx"
}
