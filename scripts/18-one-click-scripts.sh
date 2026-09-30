#!/bin/bash

daimon_exec_cached_script() {
	local url="$1"
	local name="$2"
	shift 2
	daimon_download "$url" "$name" || exit 1
	bash -n "$DAIMON_SCRIPT_DIR/$name" || { echo "脚本语法校验失败，未执行。"; return 1; }
	clear
	echo -e "${gl_kjlan}已退出 daimon，正在运行: bash $DAIMON_SCRIPT_DIR/$name $*${gl_bai}"
	exec bash "$DAIMON_SCRIPT_DIR/$name" "$@"
}

common_one_click_scripts() {
	while true; do
		clear
		echo "常用的一键脚本"
		echo "------------------------"
		echo -e "${gl_kjlan}1.   ${gl_bai}NodeQuality"
		echo -e "${gl_kjlan}2.   ${gl_bai}IPQuality"
		echo -e "${gl_kjlan}3.   ${gl_bai}融合怪"
		echo -e "${gl_kjlan}4.   ${gl_bai}NetQuality"
		echo -e "${gl_kjlan}5.   ${gl_bai}RegionRestrictionCheck"
		echo -e "${gl_kjlan}6.   ${gl_bai}bench.sh"
		echo -e "${gl_kjlan}7.   ${gl_bai}YABS"
		echo -e "${gl_kjlan}8.   ${gl_bai}HardwareQuality"
		echo -e "${gl_kjlan}9.   ${gl_bai}勇哥脚本"
		echo -e "${gl_kjlan}10.  ${gl_bai}kejilion.sh 脚本"
		echo -e "${gl_kjlan}11.  ${gl_bai}sing-box安装"
		echo -e "${gl_kjlan}12.  ${gl_bai}TcpQuality"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1) daimon_exec_cached_script "https://run.NodeQuality.com" "NodeQuality.sh" ;;
			2) daimon_exec_cached_script "https://IP.Check.Place" "IPQuality.sh" ;;
			3) daimon_exec_cached_script "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh" "ecs.sh" ;;
			4) daimon_exec_cached_script "https://Net.Check.Place" "NetQuality.sh" ;;
			5) daimon_exec_cached_script "https://check.unlock.media" "RegionRestrictionCheck.sh" ;;
			6) daimon_exec_cached_script "https://bench.sh" "bench.sh" ;;
			7) daimon_exec_cached_script "https://yabs.sh" "yabs.sh" ;;
			8) daimon_download "https://Check.Place" "HardwareQuality.sh" && exec bash "$DAIMON_SCRIPT_DIR/HardwareQuality.sh" -H ;;
			9) daimon_exec_cached_script "https://raw.githubusercontent.com/yonggekkk/x-ui-yg/main/install.sh" "x-ui-yg-install.sh" ;;
			10) exec bash -c 'bash <(curl -sL kejilion.sh)' ;;
			11) daimon_exec_cached_script "https://raw.githubusercontent.com/daimon3332/sing-box-daimon/main/sb.sh" "sing-box-daimon.sh" ;;
			12) daimon_exec_cached_script "https://raw.githubusercontent.com/daimon3332/TcpQuality/main/runTcpQuality.sh" "runTcpQuality.sh" ;;
			0) return ;;
			*) echo "无效的输入!"; break_end ;;
		esac
	done
}
