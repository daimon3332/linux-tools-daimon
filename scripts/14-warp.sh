#!/bin/bash

warp_manager() {
	while true; do
		clear
		echo -e "WARP 管理"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		if command -v warp >/dev/null 2>&1; then
			echo -e "快捷命令: ${gl_lv}已安装${gl_bai} ($(command -v warp))"
		else
			echo -e "快捷命令: ${gl_huang}未检测到${gl_bai}"
		fi
		if ip link show warp >/dev/null 2>&1; then
			echo -e "WARP 网络接口: ${gl_lv}存在${gl_bai}"
		else
			echo -e "WARP 网络接口: ${gl_huang}未检测到${gl_bai}"
		fi
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo -e "${gl_kjlan}1.   ${gl_bai}进入 WARP 官方管理脚本"
		echo -e "${gl_kjlan}2.   ${gl_bai}彻底删除 WARP（删除 WARP 网络接口、Linux Client 和 WireProxy）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case $sub_choice in
			1)
				clear
				send_stats "warp管理"
				install wget curl
				daimon_run_cached_script "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" "warp-menu.sh"
				;;
			2)
				clear
				echo -e "${gl_hong}警告：此操作会永久关闭并彻底删除 WARP 网络接口、WARP Linux Client 和 WireProxy。${gl_bai}"
				read -e -p "确认彻底删除 WARP？(y/N): " confirm || return 1
				if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
					send_stats "彻底删除warp"
					install wget curl
					daimon_run_cached_script "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" "warp-menu.sh" u
				else
					echo "已取消"
				fi
				;;
			0)
				return
				;;
			*)
				echo "无效的输入!"
				;;
		esac
		break_end
	done
}
