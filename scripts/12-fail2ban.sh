#!/bin/bash

fail2ban_manager() {
	local F2B_JAIL="/etc/fail2ban/jail.local"

	fail2ban_detect_ssh_ports() {
		local ports=""
		if command -v ss >/dev/null 2>&1; then
			ports=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -n -u | paste -sd, -)
		fi
		if [ -z "$ports" ]; then
			ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -n -u | paste -sd, - 2>/dev/null)
		fi
		if [ -z "$ports" ] && [ -f /etc/ssh/sshd_config ]; then
			ports=$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -n -u | paste -sd, -)
		fi
		echo "${ports:-22}"
	}

	fail2ban_auth_logpath() {
		if [ -f /var/log/auth.log ]; then
			echo "/var/log/auth.log"
		elif [ -f /var/log/secure ]; then
			echo "/var/log/secure"
		else
			if command -v journalctl >/dev/null 2>&1; then echo systemd; else echo "%(sshd_log)s"; fi
		fi
	}

	fail2ban_service() {
		local action="$1"
		if [ -x /bin/systemctl ]; then
			case "$action" in
				status) /bin/systemctl --no-pager --full status fail2ban ;;
				*) /bin/systemctl "$action" fail2ban ;;
			esac
		else
			service fail2ban "$action"
		fi
	}

	fail2ban_current_sshd_port() {
		[ -f "$F2B_JAIL" ] || return 0
		awk '
			/^[[:space:]]*\[sshd\][[:space:]]*$/ {in_sshd=1; next}
			/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {in_sshd=0}
			in_sshd && /^[[:space:]]*port[[:space:]]*=/ {
				sub(/^[^=]*=/, "", $0)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
				print
				exit
			}
		' "$F2B_JAIL"
	}

	fail2ban_write_sshd_jail() {
		local ports="$1"
		local logpath backend=""
		local tmp
		logpath=$(fail2ban_auth_logpath)
		if [ "$logpath" = systemd ]; then
			install python3-systemd || return 1
			backend=systemd
			logpath=""
		fi

		mkdir -p /etc/fail2ban
		if [ ! -f "$F2B_JAIL" ]; then
			cp /etc/fail2ban/jail.conf "$F2B_JAIL" 2>/dev/null || touch "$F2B_JAIL"
		fi
		tmp=$(mktemp)
		awk -v port="$ports" -v logpath="$logpath" -v backend="$backend" '
			function print_sshd_block() {
				print "[sshd]"
				print "enabled = true"
				print "port = " port
				print "filter = sshd"
				if (backend != "") print "backend = " backend
				else print "logpath = " logpath
				print "maxretry = 5"
				print "bantime = 3600"
				print "findtime = 600"
			}
			BEGIN {in_sshd=0; printed=0}
			/^[[:space:]]*\[sshd\][[:space:]]*$/ {
				if (!printed) {
					print_sshd_block()
					printed=1
				}
				in_sshd=1
				next
			}
			/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
				if (in_sshd) in_sshd=0
				print
				next
			}
			{
				if (!in_sshd) print
			}
			END {
				if (!printed) {
					print ""
					print_sshd_block()
				}
			}
		' "$F2B_JAIL" > "$tmp" && mv "$tmp" "$F2B_JAIL"

		echo "已写入 Fail2ban sshd 配置:"
		echo "  配置文件: $F2B_JAIL"
		echo "  SSH 端口: $ports"
		echo "  日志路径: $logpath"
	}

	fail2ban_reload_checked() {
		if command -v fail2ban-client >/dev/null 2>&1; then
			if ! fail2ban-client -t; then
				echo -e "${gl_hong}Fail2ban 配置检查失败，未重启服务。${gl_bai}"
				return 1
			fi
		fi
		fail2ban_service enable 2>/dev/null || true
		fail2ban_service restart 2>/dev/null || fail2ban_service start 2>/dev/null || true
		sleep 1
		fail2ban-client status sshd 2>/dev/null || fail2ban-client status 2>/dev/null || fail2ban_service status
	}

	fail2ban_install_sshd() {
		root_use
		if command -v apt-get >/dev/null 2>&1; then
			apt-get update -y || return 1
			apt-get install -y fail2ban || return 1
		else
			install fail2ban || return 1
		fi
		fail2ban_service start 2>/dev/null || true
		fail2ban_service enable 2>/dev/null || true
		fail2ban_write_sshd_jail "$(fail2ban_detect_ssh_ports)" || return 1
		fail2ban_reload_checked
	}

	fail2ban_uninstall_all() {
		root_use
		fail2ban_service stop 2>/dev/null || true
		fail2ban_service disable 2>/dev/null || true
		remove fail2ban
		rm -rf /etc/fail2ban /var/lib/fail2ban /var/log/fail2ban.log
		echo "Fail2ban 已卸载，相关配置和状态目录已删除。"
	}

	fail2ban_check_sshd_jail() {
		root_use
		if ! command -v fail2ban-client >/dev/null 2>&1; then
			echo "未检测到 fail2ban-client，请先选择 1 安装 Fail2ban。"
			return 1
		fi
		local detected_ports
		local configured_ports
		detected_ports=$(fail2ban_detect_ssh_ports)
		configured_ports=$(fail2ban_current_sshd_port)
		echo "当前 SSH 实际端口: $detected_ports"
		echo "Fail2ban sshd 当前端口: ${configured_ports:-未配置}"
		if [ "$configured_ports" != "$detected_ports" ]; then
			echo "端口不一致，正在自动修正 Fail2ban sshd 配置..."
			fail2ban_write_sshd_jail "$detected_ports"
		else
			echo "端口一致，无需修改。"
		fi
		fail2ban_reload_checked
	}

	while true; do
		clear
		echo "Fail2ban 管理"
		echo "------------------------"
		echo -e "当前 SSH 端口: ${gl_huang}$(fail2ban_detect_ssh_ports)${gl_bai}"
		if command -v fail2ban-client >/dev/null 2>&1; then
			fail2ban-client status sshd 2>/dev/null || fail2ban-client status 2>/dev/null || echo "Fail2ban 已安装但服务未运行"
		else
			echo -e "当前状态: ${gl_huang}未安装${gl_bai}"
		fi
		echo "------------------------"
		echo -e "${gl_kjlan}1.   ${gl_bai}安装 Fail2ban（自动配置 sshd，端口按当前 SSH 检测）"
		echo -e "${gl_kjlan}2.   ${gl_bai}卸载 Fail2ban（停止服务并删除配置/状态目录）"
		echo -e "${gl_kjlan}3.   ${gl_bai}检查 sshd 配置（端口不对自动修正）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1) fail2ban_install_sshd ;;
			2) fail2ban_uninstall_all ;;
			3) fail2ban_check_sshd_jail ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
