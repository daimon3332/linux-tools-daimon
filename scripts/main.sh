#!/bin/bash

kejilion_sh() {
crontab_sync_upgrade_installed || echo 'ERROR: 已安装备份任务升级未完成，请检查 cronsync'
crontab_sync_reconcile_legacy || true
if [ -f "$DAIMON_CERT_HELPER_MARKER" ]; then
	 rm -f "$DAIMON_CERT_HELPER_MARKER"
	 DAIMON_UPDATE_CERT_HELPER_ONLY=1 ssl_nginx_manager
fi
while true; do
clear
echo -e "${gl_kjlan}"
echo "╔╦╗╔═╗╦╔╦╗╔═╗╔╗╔"
echo " ║║╠═╣║║║║║ ║║║║"
echo "═╩╝╩ ╩╩╩ ╩╚═╝╝╚╝"
echo -e "linux-tools-daimon v$sh_v"
echo -e "命令行输入${gl_huang}d${gl_kjlan}可快速启动脚本${gl_bai}"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}1.   ${gl_bai}系统信息查询"
echo -e "${gl_kjlan}2.   ${gl_bai}系统更新"
echo -e "${gl_kjlan}3.   ${gl_bai}系统清理"
echo -e "${gl_kjlan}4.   ${gl_bai}一键配置"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}5.   ${gl_bai}系统工具"
echo -e "${gl_kjlan}6.   ${gl_bai}第三方工具"
echo -e "${gl_kjlan}7.   ${gl_bai}编程工具"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}8.   ${gl_bai}Docker管理"
echo -e "${gl_kjlan}9.   ${gl_bai}SSH管理"
echo -e "${gl_kjlan}10.  ${gl_bai}UFW管理"
echo -e "${gl_kjlan}11.  ${gl_bai}Nginx + 域名管理"
echo -e "${gl_kjlan}12.  ${gl_bai}fail2ban管理"
echo -e "${gl_kjlan}13.  ${gl_bai}BBR管理"
echo -e "${gl_kjlan}14.  ${gl_bai}WARP管理"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}15.  ${gl_bai}rclone管理"
echo -e "${gl_kjlan}16.  ${gl_bai}Bitwarden管理"
echo -e "${gl_kjlan}17.  ${gl_bai}crontab同步脚本管理"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}18.  ${gl_bai}常用的一键脚本"
echo -e "${gl_kjlan}19.  ${gl_bai}服务器退役"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}20.  ${gl_bai}Debian 基础工具"
echo -e "${gl_kjlan}21.  ${gl_bai}网络自适应优化"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}00.  ${gl_bai}脚本更新"
echo -e "${gl_kjlan}------------------------${gl_bai}"
echo -e "${gl_kjlan}0.   ${gl_bai}退出脚本"
echo -e "${gl_kjlan}------------------------${gl_bai}"
read -e -p "请输入你的选择: " choice || return 0
pause_after=true
case $choice in
  1) linux_info ;;
  2) clear ; send_stats "系统更新" ; linux_update ;;
  3) clear ; send_stats "系统清理" ; linux_clean ;;
  4) one_click_config_manager; pause_after=false ;;
  5) linux_Settings; pause_after=false ;;
  6) linux_thirdparty_tools; pause_after=false ;;
  7) linux_programming_tools; pause_after=false ;;
  8) linux_docker; pause_after=false ;;
  9) ssh_config_manager; pause_after=false ;;
  10) ufw_manager; pause_after=false ;;
  11) ssl_nginx_manager; pause_after=false ;;
  12) fail2ban_manager; pause_after=false ;;
  13) linux_bbr; pause_after=false ;;
  14) warp_manager; pause_after=false ;;
  15) rclone_manager; pause_after=false ;;
  16) bitwarden_manager; pause_after=false ;;
  17) crontab_sync_manager; pause_after=false ;;
  18) common_one_click_scripts; pause_after=false ;;
  19) server_retire_menu; pause_after=false ;;
  20) debian_basics_menu; pause_after=false ;;
  21) daimon_tcp_tune_menu; pause_after=false ;;
  00) kejilion_update; pause_after=false ;;
  0) clear ; exit ;;
  *) echo "无效的输入!" ;;
esac
	[ "$pause_after" = "true" ] && break_end
done
}

k_info() {
send_stats "d命令参考用例"
echo "-------------------"
echo "以下是 d 命令参考用例："
echo "启动脚本            d"
echo "安装软件包          d install vim wget | d add vim wget | d 安装 vim wget"
echo "卸载软件包          d remove vim wget | d del vim wget | d uninstall vim wget | d 卸载 vim wget"
echo "更新系统            d update | d 更新"
echo "清理系统垃圾        d clean | d 清理"
echo "设置虚拟内存        d swap 2048"
echo "设置虚拟时区        d time Asia/Shanghai | d 时区 Asia/Shanghai"
echo "Docker管理面板      d docker"
echo "fail2ban管理        d fail2ban | d f2b"
echo "rclone管理          d rclone | d rc"
echo "Bitwarden管理       d bitwarden | d bw"
echo "crontab同步脚本管理 d cronsync | d syncscripts"
echo "服务器退役        d retire | d 退役"
echo "显示系统信息        d info"
echo "ROOT密钥管理        d sshkey"
}

daimon_dispatch() {
if [ "$#" -eq 0 ]; then
	kejilion_sh
	return
fi
case $1 in
	install|add|安装) shift; send_stats "安装软件"; install "$@" ;;
	remove|del|uninstall|卸载) shift; send_stats "卸载软件"; remove "$@" ;;
	update|更新) linux_update ;;
	clean|清理) linux_clean ;;
	ssh|远程连接) ssh_manager ;;
	swap) shift; send_stats "快速设置虚拟内存"; add_swap "$@" ;;
	time|时区) shift; send_stats "快速设置时区"; set_timedate "$@" ;;
	status|状态) shift; send_stats "软件状态查看"; status "$@" ;;
	start|启动) shift; send_stats "软件启动"; start "$@" ;;
	stop|停止) shift; send_stats "软件暂停"; stop "$@" ;;
	restart|重启) shift; send_stats "软件重启"; restart "$@" ;;
	enable|autostart|开机启动) shift; send_stats "软件开机自启"; enable "$@" ;;
	docker)
		shift
		case $1 in
			install|安装) send_stats "快捷安装docker"; install_docker ;;
			ps|容器) send_stats "快捷容器管理"; docker_ps ;;
			img|镜像) send_stats "快捷镜像管理"; docker_image ;;
			*) linux_docker ;;
		esac
		;;
	info) linux_info ;;
	fail2ban|f2b) fail2ban_manager ;;
	rclone|rc) rclone_manager ;;
	bitwarden|bw) bitwarden_manager ;;
	cronsync|syncscripts|cron-sync) crontab_sync_manager ;;
	retire|退役) server_retire_menu ;;
	sshkey)
		shift
		case "$1" in
			"") send_stats "SSHKey 交互菜单"; sshkey_panel ;;
			github) shift; send_stats "从 GitHub 导入 SSH 公钥"; fetch_github_ssh_keys "$1" ;;
			http://*|https://*) send_stats "从 URL 导入 SSH 公钥"; fetch_remote_ssh_keys "$1" ;;
			ssh-rsa*|ssh-ed25519*|ssh-ecdsa*) send_stats "公钥直接导入"; import_sshkey "$1" ;;
			*)
				echo "错误：未知参数 '$1'"
				echo "用法："
				echo "  d sshkey                  进入交互菜单"
				echo "  d sshkey \"<pubkey>\"     直接导入 SSH 公钥"
				echo "  d sshkey <url>            从 URL 导入 SSH 公钥"
				echo "  d sshkey github <user>    从 GitHub 导入 SSH 公钥"
				;;
		esac
		;;
	*) k_info ;;
esac
}
