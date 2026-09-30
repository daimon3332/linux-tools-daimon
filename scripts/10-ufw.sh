#!/bin/bash

ufw_allow_current_ssh() {
	local ports port
	command -v ufw >/dev/null 2>&1 || return 1
	ports=$(ssh_current_ports) || return 1
	for port in $ports "$@"; do
		validate_tcp_port "$port" && ufw allow "$port/tcp" || {
			echo "SSH 端口放行失败，未启用防火墙。" >&2
			return 1
		}
	done
}

ufw_delete_allow_safe() {
	local rule="$1" start end protocol ports port
	[ "$(id -u)" = 0 ] || return 1
	if ! [[ "$rule" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?(/(tcp|udp))?$ ]]; then
		echo "仅支持数字端口或带协议的端口范围，未删除规则。"; return 1
	fi
	start=$((10#${BASH_REMATCH[1]}))
	end=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
	protocol=${BASH_REMATCH[5]:-}
	if (( start < 1 || end > 65535 || start > end )) || { [[ "$rule" = *:* ]] && [ -z "$protocol" ]; }; then
		echo "端口范围无效，未删除规则。"; return 1
	fi
	ports=$(ssh_current_ports) || return 1
	[ -n "$ports" ] || return 1
	for port in $ports; do
		[[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
		port=$((10#$port))
		(( port >= 1 && port <= 65535 )) || return 1
		if [ "$protocol" != udp ] && (( port >= start && port <= end )); then
			echo "拒绝删除当前 SSH 端口 $port 的放行规则，请先验证其他管理连接。"; return 1
		fi
	done
	ufw delete allow "$rule" || { echo "规则删除失败，请核查 UFW 状态。"; return 1; }
}

ufw_manager() {
	while true; do
		clear
		echo "UFW 防火墙管理"
		echo "------------------------"
		if command -v ufw >/dev/null 2>&1; then
			ufw status | head -n 12
		else
			echo -e "当前状态: ${gl_huang}未安装${gl_bai}"
		fi
		echo "------------------------"
		echo -e "${gl_kjlan}1.   ${gl_bai}安装 UFW（apt install -y ufw，并启用）"
		echo -e "${gl_kjlan}2.   ${gl_bai}卸载 UFW（禁用后 apt purge -y ufw）"
		echo -e "${gl_kjlan}3.   ${gl_bai}开放端口（例如 80 或 80/tcp，对应 ufw allow）"
		echo -e "${gl_kjlan}4.   ${gl_bai}删除端口规则（例如 80 或 80/tcp，对应 ufw delete allow）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1)
				root_use
				if install ufw && ufw_allow_current_ssh; then
					ufw --force enable && ufw status
				fi
				;;
			2) root_use; ufw disable 2>/dev/null || true; remove ufw; rm -rf /etc/ufw /var/lib/ufw ;;
			3) root_use; read -e -p "请输入要开放的端口/协议: " port_rule || return 1; [ -n "$port_rule" ] && ufw allow "$port_rule"; ufw status numbered ;;
			4) root_use; read -e -p "请输入要删除的端口/协议: " port_rule || return 1; ufw_delete_allow_safe "$port_rule" && ufw status numbered ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
