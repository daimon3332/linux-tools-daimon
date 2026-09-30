#!/bin/bash

daimon_migrate_path() {
	local old_path="$1"
	local new_path="$2"
	[ "$(id -u 2>/dev/null)" = "0" ] || return 0
	[ -e "$old_path" ] || [ -L "$old_path" ] || return 0
	[ "$old_path" != "$new_path" ] || return 0
	case "$old_path" in
		/root/daimon|/root/backup|/root/backup-sh|/root/docker-compose-update|/root/.fzf|/root/linux-toolbox.sh|/root/daimon.sh) ;;
		*) return 0 ;;
	esac
	[ ! -L "$old_path" ] && [ ! -L "$new_path" ] || return 1
	case "$(realpath -m -- "$new_path")" in
		"$(realpath -m -- "$DAIMON_ROOT_DIR")"/*) ;;
		*) return 1 ;;
	esac
	mkdir -p "$(dirname "$new_path")" || return 1
	# Legacy paths may contain user data. Copy only; never delete conflicts or sources.
	if [ -d "$old_path" ]; then
		mkdir -p "$new_path" && cp -an -- "$old_path"/. "$new_path"/
	else
		cp -an -- "$old_path" "$new_path"
	fi
}

daimon_migrate_runtime_layout() {
	[ "$(id -u 2>/dev/null)" = "0" ] || return 0
	daimon_migrate_path "/root/daimon" "$DAIMON_SCRIPT_DIR"
	daimon_migrate_path "/root/backup" "$DAIMON_BACKUP_DIR"
	daimon_migrate_path "/root/backup-sh" "$DAIMON_BACKUP_SH_DIR"
	daimon_migrate_path "/root/docker-compose-update" "$DAIMON_DOCKER_COMPOSE_UPDATE_DIR"
	daimon_migrate_path "/root/.fzf" "$DAIMON_FZF_DIR"
	daimon_migrate_path "/root/linux-toolbox.sh" "$DAIMON_LOCAL_SCRIPT"
	daimon_migrate_path "/root/daimon.sh" "$DAIMON_OLD_LOCAL_SCRIPT"

}

daimon_update_fallback_url() {
	if [ "$canshu" = "CN" ] || daimon_is_cn; then
		echo "$DAIMON_UPDATE_GITHUB_PROXY_URL"
	else
		echo "$DAIMON_UPDATE_GITHUB_URL"
	fi
}

daimon_try_download_url() {
	local url="$1"
	local target="$2"
	case "$url" in *\?*) url="${url}&_daimon=$(date +%s)" ;; *) url="${url}?_daimon=$(date +%s)" ;; esac
	echo "下载地址: $url"
	rm -f "$target" 2>/dev/null || true
	curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "$target" "$url" 2>/dev/null && [ -s "$target" ] && return 0
	if command -v wget >/dev/null 2>&1; then
		timeout 60 wget --timeout=15 --tries=1 -qO "$target" "$url" 2>/dev/null && [ -s "$target" ] && return 0
	fi
	return 1
}

daimon_validate_update_file() {
	local file="$1"
	if [ ! -s "$file" ]; then
		echo -e "${gl_hong}校验失败：下载文件为空${gl_bai}"
		return 1
	fi
	if ! head -1 "$file" 2>/dev/null | grep -q '^#!/bin/bash'; then
		echo -e "${gl_hong}校验失败：下载到的不是 linux-toolbox.sh 脚本${gl_bai}"
		echo "文件首行: $(head -1 "$file" 2>/dev/null)"
		return 1
	fi
	if ! grep -q 'DAIMON_NAME="linux-tools-daimon"' "$file" 2>/dev/null; then
		echo -e "${gl_hong}校验失败：未检测到 linux-tools-daimon 标识${gl_bai}"
		return 1
	fi
	bash -n "$file" || { echo "更新脚本语法校验失败，未安装。"; return 1; }
	return 0
}

daimon_install_script_file() {
	local source="$1" target="$2" staged
	daimon_validate_update_file "$source" || return 1
	staged=$(mktemp "${target}.XXXXXX") || return 1
	if ! command install -m 755 "$source" "$staged" || ! mv -f -- "$staged" "$target"; then
		rm -f -- "$staged"
		return 1
	fi
}

daimon_download_update_file() {
	local target="$1"
	local primary fallback="${DAIMON_UPDATE_URL:-https://daimon-linux-scripts.333186.xyz/linux-toolbox.sh}"
	primary=$(daimon_update_fallback_url)

	if daimon_try_download_url "$primary" "$target" && daimon_validate_update_file "$target"; then
		return 0
	fi

	if [ "$primary" != "$DAIMON_UPDATE_GITHUB_URL" ]; then
		echo -e "${gl_huang}指定 GitHub 代理失败，继续尝试备用 GitHub 代理...${gl_bai}"
		if daimon_download_to "$DAIMON_UPDATE_GITHUB_URL" "$target" && daimon_validate_update_file "$target"; then
			return 0
		fi
	fi
	echo -e "${gl_huang}GitHub 更新失败，尝试备用站点；备用内容可能存在同步延迟。${gl_bai}"
	if daimon_try_download_url "$fallback" "$target" && daimon_validate_update_file "$target"; then
		return 0
	fi

	rm -f "$target" 2>/dev/null || true
	return 1
}

quanju_canshu() {
    if [ "$canshu" = CN ] || daimon_is_cn; then
        zhushi=0
        gh_proxy="$DAIMON_GITHUB_PROXY_PRIMARY"https://
    elif [ "$canshu" = V6 ]; then
        zhushi=1
        gh_proxy="$DAIMON_GITHUB_PROXY_PRIMARY"https://
    else
        zhushi=1
        gh_proxy="https://"
    fi
    gh_https_url="$gh_proxy"
}

run_command() {
	if [ "$zhushi" -eq 0 ]; then
		"$@"
	fi
}

canshu_v6() { :; }

CheckFirstRun_true() { :; }

yinsiyuanquan2() { :; }

CheckFirstRun_false() {
    [ "$permission_granted" = true ] || UserLicenseAgreement
}

UserLicenseAgreement() {
	clear
	echo -e "${gl_kjlan}欢迎使用linux-tools-daimon${gl_bai}"
	echo "首次使用脚本，请先阅读并确认以下说明。"
	echo "项目名称: linux-tools-daimon"
	echo "开源仓库: ${DAIMON_REPO_URL}"
	echo "用户说明: ${DAIMON_AGREEMENT_URL}"
	echo "使用说明: 本脚本为个人开源工具，按现状提供，请在了解命令作用后自行决定是否执行。"
	echo "风险提示: 脚本中的系统配置、Docker、Nginx、证书、网络优化等操作可能修改服务器状态，请提前备份重要数据。"
	echo -e "----------------------"
	read -e -p "是否已阅读并确认继续使用？(y/n): " user_input || exit 1


	if [ "$user_input" = "y" ] || [ "$user_input" = "Y" ]; then
		send_stats "许可同意"
		daimon_preference_set permission_granted true || return 1
	else
		send_stats "许可拒绝"
		clear
		exit
	fi
}

check_disk_space() {
	local required_gb=$1
	local path=${2:-/}

	mkdir -p "$path"

	local required_space_mb=$((required_gb * 1024))
	local available_space_mb=$(df -m "$path" | awk 'NR==2 {print $4}')

	if [ "$available_space_mb" -lt "$required_space_mb" ]; then
		echo -e "${gl_huang}提示: ${gl_bai}磁盘空间不足！"
		echo "当前可用空间: $((available_space_mb/1024))G"
		echo "最小需求空间: ${required_gb}G"
		echo "无法继续安装，请清理磁盘空间后重试。"
		send_stats "磁盘空间不足"
		break_end
		kejilion
	fi
}

install_dependency() {
	switch_mirror false false
	check_port
	check_swap
	prefer_ipv4
	auto_optimize_dns
	install wget unzip tar jq grep

}

restart() {
	local RC
	systemctl restart "$@"
	RC=$?
	if [ "$RC" -ne 0 ] && [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ]; then
		systemctl reset-failed "$@" >/dev/null 2>&1 || true
		systemctl restart "$@"
		RC=$?
	fi
	if [ "$RC" -eq 0 ] && [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ] && ! systemctl is-active --quiet "$@"; then
		RC=1
	fi
	if [ "$RC" -eq 0 ]; then
		echo "$1 服务已重启。"
	else
		echo "错误：重启 $1 服务失败。"
	fi
	return "$RC"
}

start() {
	local RC
	systemctl start "$@"
	RC=$?
	if [ "$RC" -ne 0 ] && [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ]; then
		systemctl reset-failed "$@" >/dev/null 2>&1 || true
		systemctl start "$@"
		RC=$?
	fi
	if [ "$RC" -eq 0 ] && [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ] && ! systemctl is-active --quiet "$@"; then
		RC=1
	fi
	if [ "$RC" -eq 0 ]; then
		echo "$1 服务已启动。"
	else
		echo "错误：启动 $1 服务失败。"
	fi
	return "$RC"
}

stop() {
	local RC
	systemctl stop "$@"
	RC=$?
	if [ "$RC" -eq 0 ]; then
		echo "$1 服务已停止。"
	else
		echo "错误：停止 $1 服务失败。"
	fi
	return "$RC"
}

status() {
	local RC
	systemctl status "$@"
	RC=$?
	if [ "$RC" -eq 0 ]; then
		echo "$1 服务状态已显示。"
	else
		echo "错误：无法显示 $1 服务状态。"
	fi
	return "$RC"
}

enable() {
	local SERVICE_NAME="$1"
	local RC
	if command -v apk &>/dev/null; then
		rc-update add "$SERVICE_NAME" default
	else
	   /bin/systemctl enable "$SERVICE_NAME"
	fi
	RC=$?

	if [ "$RC" -eq 0 ]; then
		echo "$SERVICE_NAME 已设置为开机自启。"
	else
		echo "错误：设置 $SERVICE_NAME 开机自启失败。"
	fi
	return "$RC"
}

stop_containers_or_kill_process() {
	local port=$1
	local containers=$(docker ps --filter "publish=$port" --format "{{.ID}}" 2>/dev/null)

	if [ -n "$containers" ]; then
		docker stop $containers
	else
		install lsof
		for pid in $(lsof -t -i:$port); do
			kill -9 $pid
		done
	fi
}

check_port() {
	stop_containers_or_kill_process 80
	stop_containers_or_kill_process 443
}

iptables_open() {
	install iptables
	save_iptables_rules
	iptables -P INPUT ACCEPT
	iptables -P FORWARD ACCEPT
	iptables -P OUTPUT ACCEPT
	iptables -F

	ip6tables -P INPUT ACCEPT
	ip6tables -P FORWARD ACCEPT
	ip6tables -P OUTPUT ACCEPT
	ip6tables -F

}

open_port() {
	local ports=($@)  # 将传入的参数转换为数组
	if [ ${#ports[@]} -eq 0 ]; then
		echo "请提供至少一个端口号"
		return 1
	fi

	install iptables

	for port in "${ports[@]}"; do
		# 删除已存在的关闭规则
		iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
		iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null

		# 添加打开规则
		if ! iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null; then
			iptables -I INPUT 1 -p tcp --dport $port -j ACCEPT
		fi

		if ! iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null; then
			iptables -I INPUT 1 -p udp --dport $port -j ACCEPT
			echo "已打开端口 $port"
		fi
	done

	save_iptables_rules
	send_stats "已打开端口"
}

close_port() {
	local ports=($@)  # 将传入的参数转换为数组
	if [ ${#ports[@]} -eq 0 ]; then
		echo "请提供至少一个端口号"
		return 1
	fi

	install iptables

	for port in "${ports[@]}"; do
		# 删除已存在的打开规则
		iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
		iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null

		# 添加关闭规则
		if ! iptables -C INPUT -p tcp --dport $port -j DROP 2>/dev/null; then
			iptables -I INPUT 1 -p tcp --dport $port -j DROP
		fi

		if ! iptables -C INPUT -p udp --dport $port -j DROP 2>/dev/null; then
			iptables -I INPUT 1 -p udp --dport $port -j DROP
			echo "已关闭端口 $port"
		fi
	done

	# 删除已存在的规则（如果有）
	iptables -D INPUT -i lo -j ACCEPT 2>/dev/null
	iptables -D FORWARD -i lo -j ACCEPT 2>/dev/null

	# 插入新规则到第一条
	iptables -I INPUT 1 -i lo -j ACCEPT
	iptables -I FORWARD 1 -i lo -j ACCEPT

	save_iptables_rules
	send_stats "已关闭端口"
}

allow_ip() {
	local ips=($@)  # 将传入的参数转换为数组
	if [ ${#ips[@]} -eq 0 ]; then
		echo "请提供至少一个IP地址或IP段"
		return 1
	fi

	install iptables

	for ip in "${ips[@]}"; do
		# 删除已存在的阻止规则
		iptables -D INPUT -s $ip -j DROP 2>/dev/null

		# 添加允许规则
		if ! iptables -C INPUT -s $ip -j ACCEPT 2>/dev/null; then
			iptables -I INPUT 1 -s $ip -j ACCEPT
			echo "已放行IP $ip"
		fi
	done

	save_iptables_rules
	send_stats "已放行IP"
}

block_ip() {
	local ips=($@)  # 将传入的参数转换为数组
	if [ ${#ips[@]} -eq 0 ]; then
		echo "请提供至少一个IP地址或IP段"
		return 1
	fi

	install iptables

	for ip in "${ips[@]}"; do
		# 删除已存在的允许规则
		iptables -D INPUT -s $ip -j ACCEPT 2>/dev/null

		# 添加阻止规则
		if ! iptables -C INPUT -s $ip -j DROP 2>/dev/null; then
			iptables -I INPUT 1 -s $ip -j DROP
			echo "已阻止IP $ip"
		fi
	done

	save_iptables_rules
	send_stats "已阻止IP"
}

enable_ddos_defense() {
	# 开启防御 DDoS
	iptables -A DOCKER-USER -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT
	iptables -A DOCKER-USER -p tcp --syn -j DROP
	iptables -A DOCKER-USER -p udp -m limit --limit 3000/s -j ACCEPT
	iptables -A DOCKER-USER -p udp -j DROP
	iptables -A INPUT -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT
	iptables -A INPUT -p tcp --syn -j DROP
	iptables -A INPUT -p udp -m limit --limit 3000/s -j ACCEPT
	iptables -A INPUT -p udp -j DROP

	send_stats "开启DDoS防御"
}

disable_ddos_defense() {
	# 关闭防御 DDoS
	iptables -D DOCKER-USER -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT 2>/dev/null
	iptables -D DOCKER-USER -p tcp --syn -j DROP 2>/dev/null
	iptables -D DOCKER-USER -p udp -m limit --limit 3000/s -j ACCEPT 2>/dev/null
	iptables -D DOCKER-USER -p udp -j DROP 2>/dev/null
	iptables -D INPUT -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT 2>/dev/null
	iptables -D INPUT -p tcp --syn -j DROP 2>/dev/null
	iptables -D INPUT -p udp -m limit --limit 3000/s -j ACCEPT 2>/dev/null
	iptables -D INPUT -p udp -j DROP 2>/dev/null

	send_stats "关闭DDoS防御"
}

manage_country_rules() {
	local action="$1"
	shift  # 去掉第一个参数，剩下的全是国家代码

	install ipset

	for country_code in "$@"; do
		local ipset_name="${country_code,,}_block"
		local download_url="http://www.ipdeny.com/ipblocks/data/countries/${country_code,,}.zone"

		case "$action" in
			block)
				if ! ipset list "$ipset_name" &> /dev/null; then
					ipset create "$ipset_name" hash:net
				fi

				if ! wget -q "$download_url" -O "${country_code,,}.zone"; then
					echo "错误：下载 $country_code 的 IP 区域文件失败"
					continue
				fi

				while IFS= read -r ip; do
					ipset add "$ipset_name" "$ip" 2>/dev/null
				done < "${country_code,,}.zone"

				iptables -I INPUT -m set --match-set "$ipset_name" src -j DROP

				echo "已成功阻止 $country_code 的 IP 地址"
				rm "${country_code,,}.zone"
				;;

			allow)
				if ! ipset list "$ipset_name" &> /dev/null; then
					ipset create "$ipset_name" hash:net
				fi

				if ! wget -q "$download_url" -O "${country_code,,}.zone"; then
					echo "错误：下载 $country_code 的 IP 区域文件失败"
					continue
				fi

				ipset flush "$ipset_name"
				while IFS= read -r ip; do
					ipset add "$ipset_name" "$ip" 2>/dev/null
				done < "${country_code,,}.zone"


				iptables -P INPUT DROP
				iptables -A INPUT -m set --match-set "$ipset_name" src -j ACCEPT

				echo "已成功允许 $country_code 的 IP 地址"
				rm "${country_code,,}.zone"
				;;

			unblock)
				iptables -D INPUT -m set --match-set "$ipset_name" src -j DROP 2>/dev/null

				if ipset list "$ipset_name" &> /dev/null; then
					ipset destroy "$ipset_name"
				fi

				echo "已成功解除 $country_code 的 IP 地址限制"
				;;

			*)
				echo "用法: manage_country_rules {block|allow|unblock} <country_code...>"
				;;
		esac
	done
}

iptables_panel() {
  root_use
  install iptables
  save_iptables_rules
  while true; do
		  clear
		  echo "高级防火墙管理"
		  send_stats "高级防火墙管理"
		  echo "------------------------"
		  iptables -L INPUT
		  echo ""
		  echo "防火墙管理"
		  echo "------------------------"
		  echo "1.  开放指定端口                 2.  关闭指定端口"
		  echo "3.  开放所有端口                 4.  关闭所有端口"
		  echo "------------------------"
		  echo "5.  IP白名单                  	 6.  IP黑名单"
		  echo "7.  清除指定IP"
		  echo "------------------------"
		  echo "11. 允许PING                  	 12. 禁止PING"
		  echo "------------------------"
		  echo "13. 启动DDOS防御                 14. 关闭DDOS防御"
		  echo "------------------------"
		  echo "15. 阻止指定国家IP               16. 仅允许指定国家IP"
		  echo "17. 解除指定国家IP限制"
		  echo "------------------------"
		  echo "0. 返回上一级选单"
		  echo "------------------------"
		  read -e -p "请输入你的选择: " sub_choice || return 1
		  case $sub_choice in
			  1)
				  read -e -p "请输入开放的端口号: " o_port || return 1
				  open_port $o_port
				  send_stats "开放指定端口"
				  ;;
			  2)
				  read -e -p "请输入关闭的端口号: " c_port || return 1
				  close_port $c_port
				  send_stats "关闭指定端口"
				  ;;
			  3)
				  # 开放所有端口
				  current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}')
				  iptables -F
				  iptables -X
				  iptables -P INPUT ACCEPT
				  iptables -P FORWARD ACCEPT
				  iptables -P OUTPUT ACCEPT
				  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
				  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
				  iptables -A INPUT -i lo -j ACCEPT
				  iptables -A FORWARD -i lo -j ACCEPT
				  iptables -A INPUT -p tcp --dport $current_port -j ACCEPT
				  iptables-save > /etc/iptables/rules.v4
				  send_stats "开放所有端口"
				  ;;
			  4)
				  # 关闭所有端口
				  current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}')
				  iptables -F
				  iptables -X
				  iptables -P INPUT DROP
				  iptables -P FORWARD DROP
				  iptables -P OUTPUT ACCEPT
				  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
				  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
				  iptables -A INPUT -i lo -j ACCEPT
				  iptables -A FORWARD -i lo -j ACCEPT
				  iptables -A INPUT -p tcp --dport $current_port -j ACCEPT
				  iptables-save > /etc/iptables/rules.v4
				  send_stats "关闭所有端口"
				  ;;

			  5)
				  # IP 白名单
				  read -e -p "请输入放行的IP或IP段: " o_ip || return 1
				  allow_ip $o_ip
				  ;;
			  6)
				  # IP 黑名单
				  read -e -p "请输入封锁的IP或IP段: " c_ip || return 1
				  block_ip $c_ip
				  ;;
			  7)
				  # 清除指定 IP
				  read -e -p "请输入清除的IP: " d_ip || return 1
				  iptables -D INPUT -s $d_ip -j ACCEPT 2>/dev/null
				  iptables -D INPUT -s $d_ip -j DROP 2>/dev/null
				  iptables-save > /etc/iptables/rules.v4
				  send_stats "清除指定IP"
				  ;;
			  11)
				  # 允许 PING
				  iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
				  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
				  iptables-save > /etc/iptables/rules.v4
				  send_stats "允许PING"
				  ;;
			  12)
				  # 禁用 PING
				  iptables -D INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null
				  iptables -D OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null
				  iptables-save > /etc/iptables/rules.v4
				  send_stats "禁用PING"
				  ;;
			  13)
				  enable_ddos_defense
				  ;;
			  14)
				  disable_ddos_defense
				  ;;

			  15)
				  read -e -p "请输入阻止的国家代码（多个国家代码可用空格隔开如 CN US JP）: " country_code || return 1
				  manage_country_rules block $country_code
				  send_stats "允许国家 $country_code 的IP"
				  ;;
			  16)
				  read -e -p "请输入允许的国家代码（多个国家代码可用空格隔开如 CN US JP）: " country_code || return 1
				  manage_country_rules allow $country_code
				  send_stats "阻止国家 $country_code 的IP"
				  ;;

			  17)
				  read -e -p "请输入清除的国家代码（多个国家代码可用空格隔开如 CN US JP）: " country_code || return 1
				  manage_country_rules unblock $country_code
				  send_stats "清除国家 $country_code 的IP"
				  ;;

			  *)
				  break  # 跳出循环，退出菜单
				  ;;
		  esac
  done

}

check_swap() {

local swap_total=$(free -m | awk 'NR==3{print $2}')

# 判断是否需要创建虚拟内存
[ "$swap_total" -gt 0 ] || add_swap 1024


}

ldnmp_v() {

	  # 获取nginx版本
	  local nginx_version=$(docker exec nginx nginx -v 2>&1)
	  local nginx_version=$(echo "$nginx_version" | grep -oP "nginx/\K[0-9]+\.[0-9]+\.[0-9]+")
	  echo -n -e "nginx : ${gl_huang}v$nginx_version${gl_bai}"

	  # 获取mysql版本
	  local dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
	  local mysql_version=$(docker exec mysql mysql -u root -p"$dbrootpasswd" -e "SELECT VERSION();" 2>/dev/null | tail -n 1)
	  echo -n -e "            mysql : ${gl_huang}v$mysql_version${gl_bai}"

	  # 获取php版本
	  local php_version=$(docker exec php php -v 2>/dev/null | grep -oP "PHP \K[0-9]+\.[0-9]+\.[0-9]+")
	  echo -n -e "            php : ${gl_huang}v$php_version${gl_bai}"

	  # 获取redis版本
	  local redis_version=$(docker exec redis redis-server -v 2>&1 | grep -oP "v=+\K[0-9]+\.[0-9]+")
	  echo -e "            redis : ${gl_huang}v$redis_version${gl_bai}"

	  echo "------------------------"
	  echo ""

}

install_ldnmp_conf() {

  # 创建必要的目录和文件
  cd /home && mkdir -p web/html web/mysql web/certs web/conf.d web/stream.d web/redis web/log/nginx web/letsencrypt && touch web/docker-compose.yml
  wget -O /home/web/nginx.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/nginx10.conf
  wget -O /home/web/conf.d/default.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/default10.conf

  default_server_ssl

  # 下载 docker-compose.yml 文件并进行替换
  wget -O /home/web/docker-compose.yml ${gh_proxy}raw.githubusercontent.com/kejilion/docker/main/LNMP-docker-compose-10.yml
  dbrootpasswd=$(openssl rand -base64 16) ; dbuse=$(openssl rand -hex 4) ; dbusepasswd=$(openssl rand -base64 8)

  # 在 docker-compose.yml 文件中进行替换
  sed -i "s#webroot#$dbrootpasswd#g" /home/web/docker-compose.yml
  sed -i "s#kejilionYYDS#$dbusepasswd#g" /home/web/docker-compose.yml
  sed -i "s#kejilion#$dbuse#g" /home/web/docker-compose.yml

}

update_docker_compose_with_db_creds() {

  cp /home/web/docker-compose.yml /home/web/docker-compose1.yml

  if ! grep -q "letsencrypt" /home/web/docker-compose.yml; then
	wget -O /home/web/docker-compose.yml ${gh_proxy}raw.githubusercontent.com/kejilion/docker/main/LNMP-docker-compose-10.yml

  	dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose1.yml | tr -d '[:space:]')
  	dbuse=$(grep -oP 'MYSQL_USER:\s*\K.*' /home/web/docker-compose1.yml | tr -d '[:space:]')
  	dbusepasswd=$(grep -oP 'MYSQL_PASSWORD:\s*\K.*' /home/web/docker-compose1.yml | tr -d '[:space:]')

	sed -i "s#webroot#$dbrootpasswd#g" /home/web/docker-compose.yml
	sed -i "s#kejilionYYDS#$dbusepasswd#g" /home/web/docker-compose.yml
	sed -i "s#kejilion#$dbuse#g" /home/web/docker-compose.yml
  fi

  if grep -q "kjlion/nginx:alpine" /home/web/docker-compose1.yml; then
  	sed -i 's|kjlion/nginx:alpine|nginx:alpine|g' /home/web/docker-compose.yml  > /dev/null 2>&1
	sed -i 's|nginx:alpine|kjlion/nginx:alpine|g' /home/web/docker-compose.yml  > /dev/null 2>&1
  fi

}

auto_optimize_dns() {
	# 获取国家代码（如 CN、US 等）
	local country=$(curl -s ipinfo.io/country)

	# 根据国家设置 DNS
	if [ "$country" = "CN" ]; then
		local dns1_ipv4="223.5.5.5"
		local dns2_ipv4="119.29.29.29"
		local dns1_ipv6="2400:3200::1"
		local dns2_ipv6="2402:4e00::"
	else
		local dns1_ipv4="1.1.1.1"
		local dns2_ipv4="8.8.8.8"
		local dns1_ipv6="2606:4700:4700::1111"
		local dns2_ipv6="2001:4860:4860::8888"
	fi

	set_dns


}

install_ldnmp() {

	  update_docker_compose_with_db_creds

	  cd /home/web && docker compose up -d
	  sleep 1
  	  crontab -l 2>/dev/null | grep -v 'logrotate' | crontab -
  	  (crontab -l 2>/dev/null; echo '0 2 * * * docker exec nginx apk add logrotate && docker exec nginx logrotate -f /etc/logrotate.conf') | crontab -

	  fix_phpfpm_conf php
	  fix_phpfpm_conf php74

	  # mysql调优
	  wget -O /home/custom_mysql_config.cnf ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/custom_mysql_config-1.cnf
	  docker cp /home/custom_mysql_config.cnf mysql:/etc/mysql/conf.d/
	  rm -rf /home/custom_mysql_config.cnf



	  restart_ldnmp
	  sleep 2

	  clear
	  echo "LDNMP环境安装完毕"
	  echo "------------------------"
	  ldnmp_v

}

write_certbot_renewal_script() {
	local script_file="$DAIMON_SCRIPT_DIR/auto_cert_renewal.sh"
	mkdir -p "$DAIMON_SCRIPT_DIR" /var/log/certbot
	cat > "$script_file" <<'EOF'
#!/bin/bash
set -u
CERT_DIR="/home/web/certs"
WEBROOT="/home/web/letsencrypt"
LOG_FILE="/var/log/certbot/renew.log"
LOCK_DIR="/run/lock/daimon-certbot-renew.lock.d"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then exit 0; fi
trap 'rm -rf "$LOCK_DIR"' EXIT
status=0
{
    for cert_file in "$CERT_DIR"/*_cert.pem; do
        [ -f "$cert_file" ] || continue
        domain=$(basename "$cert_file" _cert.pem)
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2- || true)
        expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        days_left=$(( (expiry_ts - $(date +%s)) / 86400 ))
        [ "$days_left" -gt 15 ] && continue
        if ! docker inspect nginx >/dev/null 2>&1 || [ "$(docker inspect nginx --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
            echo "$domain: nginx is not running; skipped without starting it"
            status=1
            continue
        fi
        if [ ! -d "$WEBROOT" ] || ! docker exec nginx sh -c "grep -Rqs letsencrypt /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null"; then
            echo "$domain: webroot challenge configuration is missing; skipped"
            status=1
            continue
        fi
        if ! docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v "$WEBROOT:/var/www/letsencrypt" certbot/certbot certonly --webroot -w /var/www/letsencrypt -d "$domain" --email your@email.com --agree-tos --no-eff-email --key-type ecdsa; then
            echo "$domain: certbot webroot renewal failed"
            status=1
            continue
        fi
        cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$CERT_DIR/${domain}_cert.pem"
        cp "/etc/letsencrypt/live/$domain/privkey.pem" "$CERT_DIR/${domain}_key.pem"
        if ! docker exec nginx nginx -t || ! docker exec nginx nginx -s reload; then
            echo "$domain: nginx reload failed"
            status=1
        fi
    done
} >> "$LOG_FILE" 2>&1
exit "$status"
EOF
	chmod 700 "$script_file"
	cat > /etc/logrotate.d/daimon-certbot-renew <<'EOF'
/var/log/certbot/renew.log {
    daily
    rotate 30
    size 10M
    missingok
    notifempty
    compress
    copytruncate
}
EOF
}

install_certbot() {
	write_certbot_renewal_script
	check_crontab_installed
	local cron_job="0 0 * * * /bin/bash $DAIMON_SCRIPT_DIR/auto_cert_renewal.sh >> /var/log/certbot/renew.log 2>&1"
	crontab -l 2>/dev/null | grep -vF "$DAIMON_SCRIPT_DIR/auto_cert_renewal.sh" | crontab -
	(crontab -l 2>/dev/null; echo "$cron_job") | crontab -
	echo "已配置 Docker Nginx webroot 续签任务"
}

install_ssltls() {
	  mkdir -p /home/web/letsencrypt/.well-known/acme-challenge /home/web/certs
	  if ! docker inspect nginx >/dev/null 2>&1 || [ "$(docker inspect nginx --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
		  echo "Docker nginx 未运行，不会自动启动；请先配置并启动 webroot 站点。"
		  return 1
	  fi

	  local file_path="/etc/letsencrypt/live/$yuming/fullchain.pem"
	  if [ ! -f "$file_path" ]; then
		 	local ipv4_pattern='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
			local ipv6_pattern='^(([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){7,7}[0-9A-Fa-f]{1,4}|::1)$'
			if [[ ($yuming =~ $ipv4_pattern || $yuming =~ $ipv6_pattern) ]]; then
				mkdir -p /etc/letsencrypt/live/$yuming/
				if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
					openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /etc/letsencrypt/live/$yuming/privkey.pem -out /etc/letsencrypt/live/$yuming/fullchain.pem -days 5475 -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name"
				else
					openssl genpkey -algorithm Ed25519 -out /etc/letsencrypt/live/$yuming/privkey.pem
					openssl req -x509 -key /etc/letsencrypt/live/$yuming/privkey.pem -out /etc/letsencrypt/live/$yuming/fullchain.pem -days 5475 -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name"
				fi
			else
				if ! docker exec nginx sh -c "grep -Rqs letsencrypt /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null"; then
					echo "未检测到 Docker nginx 的 webroot challenge 配置，未执行签发。"
					return 1
				fi
				docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /home/web/letsencrypt:/var/www/letsencrypt certbot/certbot certonly --webroot -w /var/www/letsencrypt -d "$yuming" --email your@email.com --agree-tos --no-eff-email --key-type ecdsa
			fi
	  fi
	  mkdir -p /home/web/certs/
	  cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem > /dev/null 2>&1
	  cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem > /dev/null 2>&1

	  docker exec nginx nginx -t && docker exec nginx nginx -s reload
}

install_ssltls_text() {
	echo -e "${gl_huang}$yuming 公钥信息${gl_bai}"
	cat /etc/letsencrypt/live/$yuming/fullchain.pem
	echo ""
	echo -e "${gl_huang}$yuming 私钥信息${gl_bai}"
	cat /etc/letsencrypt/live/$yuming/privkey.pem
	echo ""
	echo -e "${gl_huang}证书存放路径${gl_bai}"
	echo "公钥: /etc/letsencrypt/live/$yuming/fullchain.pem"
	echo "私钥: /etc/letsencrypt/live/$yuming/privkey.pem"
	echo ""
}

add_ssl() {
echo -e "${gl_huang}快速申请SSL证书，过期前自动续签${gl_bai}"
yuming="${1:-}"
if [ -z "$yuming" ]; then
	add_yuming
fi
install_docker
install_certbot
docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n 2>/dev/null
install_ssltls
certs_status
install_ssltls_text
ssl_ps
}

ssl_ps() {
	echo -e "${gl_huang}已申请的证书到期情况${gl_bai}"
	echo "站点信息                      证书到期时间"
	echo "------------------------"
	for cert_dir in /etc/letsencrypt/live/*; do
	  local cert_file="$cert_dir/fullchain.pem"
	  if [ -f "$cert_file" ]; then
		local domain=$(basename "$cert_dir")
		local expire_date=$(openssl x509 -noout -enddate -in "$cert_file" | awk -F'=' '{print $2}')
		local formatted_date=$(date -d "$expire_date" '+%Y-%m-%d')
		printf "%-30s%s\n" "$domain" "$formatted_date"
	  fi
	done
	echo ""
}

default_server_ssl() {
install openssl

if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /home/web/certs/default_server.key -out /home/web/certs/default_server.crt -days 5475 -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name"
else
	openssl genpkey -algorithm Ed25519 -out /home/web/certs/default_server.key
	openssl req -x509 -key /home/web/certs/default_server.key -out /home/web/certs/default_server.crt -days 5475 -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name"
fi

openssl rand -out /home/web/certs/ticket12.key 48
openssl rand -out /home/web/certs/ticket13.key 80

}

certs_status() {

	sleep 1

	local file_path="/etc/letsencrypt/live/$yuming/fullchain.pem"
	if [ -f "$file_path" ]; then
		send_stats "域名证书申请成功"
	else
		send_stats "域名证书申请失败"
		echo -e "${gl_hong}注意: ${gl_bai}证书申请失败，请检查以下可能原因并重试："
		echo -e "1. 域名拼写错误 ➠ 请检查域名输入是否正确"
		echo -e "2. DNS解析问题 ➠ 确认域名已正确解析到本服务器IP"
		echo -e "3. 网络配置问题 ➠ 如使用Cloudflare Warp等虚拟网络请暂时关闭"
		echo -e "4. 防火墙限制 ➠ 检查80/443端口是否开放，确保验证可访问"
		echo -e "5. 申请次数超限 ➠ Let's Encrypt有每周限额(5次/域名/周)"
		echo -e "6. 国内备案限制 ➠ 中国大陆环境请确认域名是否备案"
		echo "------------------------"
		echo "1. 重新申请        2. 导入已有证书        0. 退出"
		echo "------------------------"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case $sub_choice in
	  	  1)
	  	  	send_stats "重新申请"
		  	echo "请再次尝试部署 $webname"
		  	add_yuming
		  	install_ssltls
		  	certs_status

	  		  ;;
	  	  2)
	  	  	send_stats "导入已有证书"

			# 定义文件路径
			local cert_file="/home/web/certs/${yuming}_cert.pem"
			local key_file="/home/web/certs/${yuming}_key.pem"

			mkdir -p /home/web/certs

			# 1. 输入证书 (ECC 和 RSA 证书开头都是 BEGIN CERTIFICATE)
			echo "请粘贴 证书 (CRT/PEM) 内容 (按两次回车结束)："
			local cert_content=""
			while IFS= read -r line; do
				[[ -z "$line" && "$cert_content" == *"-----BEGIN"* ]] && break
				cert_content+="${line}"$'\n'
			done

			# 2. 输入私钥 (兼容 RSA, ECC, PKCS#8)
			echo "请粘贴 证书私钥 (Private Key) 内容 (按两次回车结束)："
			local key_content=""
			while IFS= read -r line; do
				[[ -z "$line" && "$key_content" == *"-----BEGIN"* ]] && break
				key_content+="${line}"$'\n'
			done

			# 3. 智能校验
			# 只要包含 "BEGIN CERTIFICATE" 和 "PRIVATE KEY" 即可通过
			if [[ "$cert_content" == *"-----BEGIN CERTIFICATE-----"* && "$key_content" == *"PRIVATE KEY-----"* ]]; then
				echo -n "$cert_content" > "$cert_file"
				echo -n "$key_content" > "$key_file"

				chmod 644 "$cert_file"
				chmod 600 "$key_file"

				# 识别当前证书类型并显示
				if [[ "$key_content" == *"EC PRIVATE KEY"* ]]; then
					echo "检测到 ECC 证书已成功保存。"
				else
					echo "检测到 RSA 证书已成功保存。"
				fi
				auth_method="ssl_imported"
			else
				echo "错误：无效的证书或私钥格式！"
				certs_status
			fi
	  		  ;;
	  	  *)
		  	  exit
	  		  ;;
		esac
	fi

}

repeat_add_yuming() {
if [ -e /home/web/conf.d/$yuming.conf ]; then
  send_stats "域名重复使用"
  web_del "${yuming}" > /dev/null 2>&1
fi

}

add_yuming() {
	  ip_address
	  echo -e "先将域名解析到本机IP: ${gl_huang}$ipv4_address  $ipv6_address${gl_bai}"
	  read -e -p "请输入你的IP或者解析过的域名: " yuming || return 1
}

check_ip_and_get_access_port() {
	local yuming="$1"

	local ipv4_pattern='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
	local ipv6_pattern='^(([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){7,7}[0-9A-Fa-f]{1,4}|::1)$'

	if [[ "$yuming" =~ $ipv4_pattern || "$yuming" =~ $ipv6_pattern ]]; then
		read -e -p "请输入访问/监听端口，回车默认使用 80: " access_port || return 1
		access_port=${access_port:-80}
	fi
}

update_nginx_listen_port() {
	local yuming="$1"
	local access_port="$2"
	local conf="/home/web/conf.d/${yuming}.conf"

	# 如果 access_port 为空，则跳过
	[ -z "$access_port" ] && return 0

	# 删除所有 listen 行
	sed -i '/^[[:space:]]*listen[[:space:]]\+/d' "$conf"

	# 在 server { 后插入新的 listen
	sed -i "/server {/a\\
	listen ${access_port};\\
	listen [::]:${access_port};
" "$conf"
}

add_db() {
	  dbname=$(echo "$yuming" | sed -e 's/[^A-Za-z0-9]/_/g')
	  dbname="${dbname}"

	  dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
	  dbuse=$(grep -oP 'MYSQL_USER:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
	  dbusepasswd=$(grep -oP 'MYSQL_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
	  docker exec mysql mysql -u root -p"$dbrootpasswd" -e "CREATE DATABASE $dbname; GRANT ALL PRIVILEGES ON $dbname.* TO \"$dbuse\"@\"%\";"
}

restart_ldnmp() {
	  docker exec nginx chown -R nginx:nginx /var/www/html > /dev/null 2>&1
	  docker exec nginx mkdir -p /var/cache/nginx/proxy > /dev/null 2>&1
	  docker exec nginx mkdir -p /var/cache/nginx/fastcgi > /dev/null 2>&1
	  docker exec nginx chown -R nginx:nginx /var/cache/nginx/proxy > /dev/null 2>&1
	  docker exec nginx chown -R nginx:nginx /var/cache/nginx/fastcgi > /dev/null 2>&1
	  docker exec php chown -R www-data:www-data /var/www/html > /dev/null 2>&1
	  docker exec php74 chown -R www-data:www-data /var/www/html > /dev/null 2>&1
	  cd /home/web && docker compose restart


}

nginx_upgrade() {

  local ldnmp_pods="nginx"
  cd /home/web/
  docker rm -f $ldnmp_pods > /dev/null 2>&1
  docker images --filter=reference="kjlion/${ldnmp_pods}*" -q | xargs docker rmi > /dev/null 2>&1
  docker images --filter=reference="${ldnmp_pods}*" -q | xargs docker rmi > /dev/null 2>&1
  docker compose up -d --force-recreate $ldnmp_pods
  crontab -l 2>/dev/null | grep -v 'logrotate' | crontab -
  (crontab -l 2>/dev/null; echo '0 2 * * * docker exec nginx apk add logrotate && docker exec nginx logrotate -f /etc/logrotate.conf') | crontab -
  docker exec nginx chown -R nginx:nginx /var/www/html
  docker exec nginx mkdir -p /var/cache/nginx/proxy
  docker exec nginx mkdir -p /var/cache/nginx/fastcgi
  docker exec nginx chown -R nginx:nginx /var/cache/nginx/proxy
  docker exec nginx chown -R nginx:nginx /var/cache/nginx/fastcgi
  docker restart $ldnmp_pods > /dev/null 2>&1

  send_stats "更新$ldnmp_pods"
  echo "更新${ldnmp_pods}完成"

}

phpmyadmin_upgrade() {
  local ldnmp_pods="phpmyadmin"
  local docker_port=8877
  local dbuse=$(grep -oP 'MYSQL_USER:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
  local dbusepasswd=$(grep -oP 'MYSQL_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')

  cd /home/web/
  docker rm -f $ldnmp_pods > /dev/null 2>&1
  docker images --filter=reference="$ldnmp_pods*" -q | xargs docker rmi > /dev/null 2>&1
  curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/docker/refs/heads/main/docker-compose.phpmyadmin.yml
  docker compose -f docker-compose.phpmyadmin.yml up -d
  clear
  ip_address

  check_docker_app_ip
  echo "登录信息: "
  echo "用户名: $dbuse"
  echo "密码: $dbusepasswd"
  echo
  send_stats "启动$ldnmp_pods"
}

cf_purge_cache() {
  local CONFIG_FILE="/home/web/config/cf-purge-cache.txt"
  local API_TOKEN
  local EMAIL
  local ZONE_IDS

  # 检查配置文件是否存在
  if [ -f "$CONFIG_FILE" ]; then
	# 从配置文件读取 API_TOKEN 和 zone_id
	read API_TOKEN EMAIL ZONE_IDS < "$CONFIG_FILE"
	# 将 ZONE_IDS 转换为数组
	ZONE_IDS=($ZONE_IDS)
  else
	# 提示用户是否清理缓存
	read -e -p "需要清理 Cloudflare 的缓存吗？（y/n）: " answer || return 1
	if [[ "$answer" == "y" ]]; then
	  echo "CF信息保存在$CONFIG_FILE，可以后期修改CF信息"
	  read -e -p "请输入你的 API_TOKEN: " API_TOKEN || return 1
	  read -e -p "请输入你的CF用户名: " EMAIL || return 1
	  read -e -p "请输入 zone_id（多个用空格分隔）: " -a ZONE_IDS || return 1

	  mkdir -p /home/web/config/
	  echo "$API_TOKEN $EMAIL ${ZONE_IDS[*]}" > "$CONFIG_FILE"
	fi
  fi

  # 循环遍历每个 zone_id 并执行清除缓存命令
  for ZONE_ID in "${ZONE_IDS[@]}"; do
	echo "正在清除缓存 for zone_id: $ZONE_ID"
	curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/purge_cache" \
	-H "X-Auth-Email: $EMAIL" \
	-H "X-Auth-Key: $API_TOKEN" \
	-H "Content-Type: application/json" \
	--data '{"purge_everything":true}'
  done

  echo "缓存清除请求已发送完毕。"
}

web_cache() {
  send_stats "清理站点缓存"
  cf_purge_cache
  cd /home/web && docker compose restart
}

web_del() {

	send_stats "删除站点数据"
	yuming_list="${1:-}"
	if [ -z "$yuming_list" ]; then
		read -e -p "删除站点数据，请输入你的域名（多个域名用空格隔开）: " yuming_list || return 1
		if [[ -z "$yuming_list" ]]; then
			return
		fi
	fi

	for yuming in $yuming_list; do
		if ! validate_domain_name "$yuming"; then echo "跳过非法域名: $yuming"; continue; fi
		echo "正在删除域名: $yuming"
		rm -rf "/home/web/html/$yuming" "/home/web/conf.d/$yuming.conf" \
			"/home/web/certs/${yuming}_key.pem" "/home/web/certs/${yuming}_cert.pem"
		echo "已删除反代配置与证书；数据库未删除"
	done

	docker exec nginx nginx -s reload

}

nginx_waf() {
	local mode=$1

	if ! grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		wget -O /home/web/nginx.conf "${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/nginx10.conf"
	fi

	# 根据 mode 参数来决定开启或关闭 WAF
	if [ "$mode" == "on" ]; then
		# 开启 WAF：去掉注释
		sed -i 's|# load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;|load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# modsecurity on;|\1modsecurity on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;|\1modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;|' /home/web/nginx.conf > /dev/null 2>&1
	elif [ "$mode" == "off" ]; then
		# 关闭 WAF：加上注释
		sed -i 's|^load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;|# load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)modsecurity on;|\1# modsecurity on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;|\1# modsecurity_rules_file /etc/nginx/modsec/modsecurity.conf;|' /home/web/nginx.conf > /dev/null 2>&1
	else
		echo "无效的参数：使用 'on' 或 'off'"
		return 1
	fi

	# 检查 nginx 镜像并根据情况处理
	if grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		docker exec nginx nginx -s reload
	else
		sed -i 's|nginx:alpine|kjlion/nginx:alpine|g' /home/web/docker-compose.yml
		nginx_upgrade
	fi

}

check_waf_status() {
	if grep -q "^\s*#\s*modsecurity on;" /home/web/nginx.conf; then
		waf_status=""
	elif grep -q "modsecurity on;" /home/web/nginx.conf; then
		waf_status=" WAF已开启"
	else
		waf_status=""
	fi
}

check_cf_mode() {
	if [ -f "/etc/fail2ban/action.d/cloudflare-docker.conf" ]; then
		CFmessage=" cf模式已开启"
	else
		CFmessage=""
	fi
}

nginx_http_on() {

local ipv4_pattern='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
local ipv6_pattern='^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?))|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?))|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?))|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|(2[0-4][0-9]|[01]?[0-9][0-9]?))))$'
if [[ ($yuming =~ $ipv4_pattern || $yuming =~ $ipv6_pattern) ]]; then
	sed -i '/if (\$scheme = http) {/,/}/s/^/#/' /home/web/conf.d/${yuming}.conf
fi

}

patch_wp_memory_limit() {
  local MEMORY_LIMIT="${1:-256M}"      # 第一个参数，默认256M
  local MAX_MEMORY_LIMIT="${2:-256M}"  # 第二个参数，默认256M
  local TARGET_DIR="/home/web/html"    # 路径写死

  find "$TARGET_DIR" -type f -name "wp-config.php" | while read -r FILE; do
	# 删除旧定义
	sed -i "/define(['\"]WP_MEMORY_LIMIT['\"].*/d" "$FILE"
	sed -i "/define(['\"]WP_MAX_MEMORY_LIMIT['\"].*/d" "$FILE"

	# 插入新定义，放在含 "Happy publishing" 的行前
	awk -v insert="define('WP_MEMORY_LIMIT', '$MEMORY_LIMIT');\ndefine('WP_MAX_MEMORY_LIMIT', '$MAX_MEMORY_LIMIT');" \
	'
	  /Happy publishing/ {
		print insert
	  }
	  { print }
	' "$FILE" > "$FILE.tmp" && mv -f "$FILE.tmp" "$FILE"

	echo "[+] Replaced WP_MEMORY_LIMIT in $FILE"
  done
}

patch_wp_debug() {
  local DEBUG="${1:-false}"           # 第一个参数，默认false
  local DEBUG_DISPLAY="${2:-false}"   # 第二个参数，默认false
  local DEBUG_LOG="${3:-false}"       # 第三个参数，默认false
  local TARGET_DIR="/home/web/html"   # 路径写死

  find "$TARGET_DIR" -type f -name "wp-config.php" | while read -r FILE; do
	# 删除旧定义
	sed -i "/define(['\"]WP_DEBUG['\"].*/d" "$FILE"
	sed -i "/define(['\"]WP_DEBUG_DISPLAY['\"].*/d" "$FILE"
	sed -i "/define(['\"]WP_DEBUG_LOG['\"].*/d" "$FILE"

	# 插入新定义，放在含 "Happy publishing" 的行前
	awk -v insert="define('WP_DEBUG_DISPLAY', $DEBUG_DISPLAY);\ndefine('WP_DEBUG_LOG', $DEBUG_LOG);" \
	'
	  /Happy publishing/ {
		print insert
	  }
	  { print }
	' "$FILE" > "$FILE.tmp" && mv -f "$FILE.tmp" "$FILE"

	echo "[+] Replaced WP_DEBUG settings in $FILE"
  done
}

patch_wp_url() {
  local HOME_URL="$1"
  local SITE_URL="$2"
  local TARGET_DIR="/home/web/html"

  find "$TARGET_DIR" -type f -name "wp-config-sample.php" | while read -r FILE; do
	# 删除旧定义
	sed -i "/define(['\"]WP_HOME['\"].*/d" "$FILE"
	sed -i "/define(['\"]WP_SITEURL['\"].*/d" "$FILE"

	# 生成插入内容
	INSERT="
define('WP_HOME', '$HOME_URL');
define('WP_SITEURL', '$SITE_URL');
"

	# 插入到 “Happy publishing” 之前
	awk -v insert="$INSERT" '
	  /Happy publishing/ {
		print insert
	  }
	  { print }
	' "$FILE" > "$FILE.tmp" && mv -f "$FILE.tmp" "$FILE"

	echo "[+] Updated WP_HOME and WP_SITEURL in $FILE"
  done
}

nginx_br() {

	local mode=$1

	if ! grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		wget -O /home/web/nginx.conf "${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/nginx10.conf"
	fi

	if [ "$mode" == "on" ]; then
		# 开启 Brotli：去掉注释
		sed -i 's|# load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;|load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|# load_module /etc/nginx/modules/ngx_http_brotli_static_module.so;|load_module /etc/nginx/modules/ngx_http_brotli_static_module.so;|' /home/web/nginx.conf > /dev/null 2>&1

		sed -i 's|^\(\s*\)# brotli on;|\1brotli on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_static on;|\1brotli_static on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_comp_level \(.*\);|\1brotli_comp_level \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_buffers \(.*\);|\1brotli_buffers \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_min_length \(.*\);|\1brotli_min_length \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_window \(.*\);|\1brotli_window \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# brotli_types \(.*\);|\1brotli_types \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i '/brotli_types/,+6 s/^\(\s*\)#\s*/\1/' /home/web/nginx.conf

	elif [ "$mode" == "off" ]; then
		# 关闭 Brotli：加上注释
		sed -i 's|^load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;|# load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^load_module /etc/nginx/modules/ngx_http_brotli_static_module.so;|# load_module /etc/nginx/modules/ngx_http_brotli_static_module.so;|' /home/web/nginx.conf > /dev/null 2>&1

		sed -i 's|^\(\s*\)brotli on;|\1# brotli on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_static on;|\1# brotli_static on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_comp_level \(.*\);|\1# brotli_comp_level \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_buffers \(.*\);|\1# brotli_buffers \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_min_length \(.*\);|\1# brotli_min_length \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_window \(.*\);|\1# brotli_window \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)brotli_types \(.*\);|\1# brotli_types \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i '/brotli_types/,+6 {
			/^[[:space:]]*[^#[:space:]]/ s/^\(\s*\)/\1# /
		}' /home/web/nginx.conf

	else
		echo "无效的参数：使用 'on' 或 'off'"
		return 1
	fi

	# 检查 nginx 镜像并根据情况处理
	if grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		docker exec nginx nginx -s reload
	else
		sed -i 's|nginx:alpine|kjlion/nginx:alpine|g' /home/web/docker-compose.yml
		nginx_upgrade
	fi


}

nginx_zstd() {

	local mode=$1

	if ! grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		wget -O /home/web/nginx.conf "${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/nginx10.conf"
	fi

	if [ "$mode" == "on" ]; then
		# 开启 Zstd：去掉注释
		sed -i 's|# load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;|load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|# load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;|load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;|' /home/web/nginx.conf > /dev/null 2>&1

		sed -i 's|^\(\s*\)# zstd on;|\1zstd on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# zstd_static on;|\1zstd_static on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# zstd_comp_level \(.*\);|\1zstd_comp_level \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# zstd_buffers \(.*\);|\1zstd_buffers \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# zstd_min_length \(.*\);|\1zstd_min_length \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)# zstd_types \(.*\);|\1zstd_types \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i '/zstd_types/,+6 s/^\(\s*\)#\s*/\1/' /home/web/nginx.conf



	elif [ "$mode" == "off" ]; then
		# 关闭 Zstd：加上注释
		sed -i 's|^load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;|# load_module /etc/nginx/modules/ngx_http_zstd_filter_module.so;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;|# load_module /etc/nginx/modules/ngx_http_zstd_static_module.so;|' /home/web/nginx.conf > /dev/null 2>&1

		sed -i 's|^\(\s*\)zstd on;|\1# zstd on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)zstd_static on;|\1# zstd_static on;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)zstd_comp_level \(.*\);|\1# zstd_comp_level \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)zstd_buffers \(.*\);|\1# zstd_buffers \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)zstd_min_length \(.*\);|\1# zstd_min_length \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i 's|^\(\s*\)zstd_types \(.*\);|\1# zstd_types \2;|' /home/web/nginx.conf > /dev/null 2>&1
		sed -i '/zstd_types/,+6 {
			/^[[:space:]]*[^#[:space:]]/ s/^\(\s*\)/\1# /
		}' /home/web/nginx.conf


	else
		echo "无效的参数：使用 'on' 或 'off'"
		return 1
	fi

	# 检查 nginx 镜像并根据情况处理
	if grep -q "kjlion/nginx:alpine" /home/web/docker-compose.yml; then
		docker exec nginx nginx -s reload
	else
		sed -i 's|nginx:alpine|kjlion/nginx:alpine|g' /home/web/docker-compose.yml
		nginx_upgrade
	fi



}

nginx_gzip() {

	local mode=$1
	if [ "$mode" == "on" ]; then
		sed -i 's|^\(\s*\)# gzip on;|\1gzip on;|' /home/web/nginx.conf > /dev/null 2>&1
	elif [ "$mode" == "off" ]; then
		sed -i 's|^\(\s*\)gzip on;|\1# gzip on;|' /home/web/nginx.conf > /dev/null 2>&1
	else
		echo "无效的参数：使用 'on' 或 'off'"
		return 1
	fi

	docker exec nginx nginx -s reload

}

web_security() {
	  send_stats "LDNMP环境防御"
	  while true; do
		check_f2b_status
		check_waf_status
		check_cf_mode
			  clear
			  echo -e "服务器网站防御程序 ${check_f2b_status}${gl_lv}${CFmessage}${waf_status}${gl_bai}"
			  echo "------------------------"
			  echo "1. 安装防御程序"
			  echo "------------------------"
			  echo "5. 查看SSH拦截记录                6. 查看网站拦截记录"
			  echo "7. 查看防御规则列表               8. 查看日志实时监控"
			  echo "------------------------"
			  echo "11. 配置拦截参数                  12. 清除所有拉黑的IP"
			  echo "------------------------"
			  echo "21. cloudflare模式                22. 高负载开启5秒盾"
			  echo "------------------------"
			  echo "31. 开启WAF                       32. 关闭WAF"
			  echo "33. 开启DDOS防御                  34. 关闭DDOS防御"
			  echo "------------------------"
			  echo "9. 卸载防御程序"
			  echo "------------------------"
			  echo "0. 返回上一级选单"
			  echo "------------------------"
			  read -e -p "请输入你的选择: " sub_choice || return 1
			  case $sub_choice in
				  1)
					  f2b_install_sshd
					  cd /etc/fail2ban/filter.d
					  curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/fail2ban-nginx-cc.conf
					  wget ${gh_proxy}raw.githubusercontent.com/linuxserver/fail2ban-confs/master/filter.d/nginx-418.conf
					  wget ${gh_proxy}raw.githubusercontent.com/linuxserver/fail2ban-confs/master/filter.d/nginx-deny.conf
					  wget ${gh_proxy}raw.githubusercontent.com/linuxserver/fail2ban-confs/master/filter.d/nginx-unauthorized.conf
					  wget ${gh_proxy}raw.githubusercontent.com/linuxserver/fail2ban-confs/master/filter.d/nginx-bad-request.conf

					  cd /etc/fail2ban/jail.d/
					  curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/config/main/fail2ban/nginx-docker-cc.conf
					  sed -i "/cloudflare/d" /etc/fail2ban/jail.d/nginx-docker-cc.conf
					  f2b_status
					  ;;
				  5)
					  echo "------------------------"
					  f2b_sshd
					  echo "------------------------"
					  ;;
				  6)

					  echo "------------------------"
					  local xxx="fail2ban-nginx-cc"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-418"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-bad-request"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-badbots"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-botsearch"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-deny"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-http-auth"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="nginx-unauthorized"
					  f2b_status_xxx
					  echo "------------------------"
					  local xxx="php-url-fopen"
					  f2b_status_xxx
					  echo "------------------------"

					  ;;

				  7)
					  fail2ban-client status
					  ;;
				  8)
					  tail -f /var/log/fail2ban.log

					  ;;
				  9)
					  remove fail2ban
					  rm -rf /etc/fail2ban
					  crontab -l | grep -v "CF-Under-Attack.sh" | crontab - 2>/dev/null
					  echo "Fail2Ban防御程序已卸载"
					  break
					  ;;

				  11)
					  install vim
					  vim /etc/fail2ban/jail.d/nginx-docker-cc.conf
					  f2b_status
					  break
					  ;;

				  12)
					  fail2ban-client unban --all
					  ;;

				  21)
					  send_stats "cloudflare模式"
					  echo "到cf后台右上角我的个人资料，选择左侧API令牌，获取Global API Key"
					  echo "https://dash.cloudflare.com/login"
					  read -e -p "输入CF的账号: " cfuser || return 1
					  read -e -p "输入CF的Global API Key: " cftoken || return 1

					  wget -O /home/web/conf.d/default.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/default11.conf
					  docker exec nginx nginx -s reload

					  cd /etc/fail2ban/jail.d/
					  curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/config/main/fail2ban/nginx-docker-cc.conf

					  cd /etc/fail2ban/action.d
					  curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/config/main/fail2ban/cloudflare-docker.conf

					  sed -i "s/kejilion@outlook.com/$cfuser/g" /etc/fail2ban/action.d/cloudflare-docker.conf
					  sed -i "s/APIKEY00000/$cftoken/g" /etc/fail2ban/action.d/cloudflare-docker.conf
					  f2b_status

					  echo "已配置cloudflare模式，可在cf后台，站点-安全性-事件中查看拦截记录"
					  ;;

				  22)
					  send_stats "高负载开启5秒盾"
					  echo -e "${gl_huang}网站每5分钟自动检测，当达检测到高负载会自动开盾，低负载也会自动关闭5秒盾。${gl_bai}"
					  echo "--------------"
					  echo "获取CF参数: "
					  echo -e "到cf后台右上角我的个人资料，选择左侧API令牌，获取${gl_huang}Global API Key${gl_bai}"
					  echo -e "到cf后台域名概要页面右下方获取${gl_huang}区域ID${gl_bai}"
					  echo "https://dash.cloudflare.com/login"
					  echo "--------------"
					  read -e -p "输入CF的账号: " cfuser || return 1
					  read -e -p "输入CF的Global API Key: " cftoken || return 1
					  read -e -p "输入CF中域名的区域ID: " cfzonID || return 1

					  install jq bc
					  check_crontab_installed
					  rm -f "$DAIMON_SCRIPT_DIR/CF-Under-Attack.sh"
					  daimon_download "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/CF-Under-Attack.sh" "CF-Under-Attack.sh"
					  sed -i "s/AAAA/$cfuser/g" "$DAIMON_SCRIPT_DIR/CF-Under-Attack.sh"
					  sed -i "s/BBBB/$cftoken/g" "$DAIMON_SCRIPT_DIR/CF-Under-Attack.sh"
					  sed -i "s/CCCC/$cfzonID/g" "$DAIMON_SCRIPT_DIR/CF-Under-Attack.sh"

					  local cron_job="*/5 * * * * bash $DAIMON_SCRIPT_DIR/CF-Under-Attack.sh"

					  local existing_cron=$(crontab -l 2>/dev/null | grep -F "$cron_job")

					  if [ -z "$existing_cron" ]; then
						  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
						  echo "高负载自动开盾脚本已添加"
					  else
						  echo "自动开盾脚本已存在，无需添加"
					  fi

					  ;;

				  31)
					  nginx_waf on
					  echo "站点WAF已开启"
					  send_stats "站点WAF已开启"
					  ;;

				  32)
				  	  nginx_waf off
					  echo "站点WAF已关闭"
					  send_stats "站点WAF已关闭"
					  ;;

				  33)
					  enable_ddos_defense
					  ;;

				  34)
					  disable_ddos_defense
					  ;;

				  *)
					  break
					  ;;
			  esac
	  break_end
	  done
}

check_ldnmp_mode() {

	local MYSQL_CONTAINER="mysql"
	local MYSQL_CONF="/etc/mysql/conf.d/custom_mysql_config.cnf"

	# 检查 MySQL 配置文件中是否包含 4096M
	if docker exec "$MYSQL_CONTAINER" grep -q "4096M" "$MYSQL_CONF" 2>/dev/null; then
		mode_info=" 高性能模式"
	else
		mode_info=" 标准模式"
	fi



}

check_nginx_compression() {

	local CONFIG_FILE="/home/web/nginx.conf"

	# 检查 zstd 是否开启且未被注释（整行以 zstd on; 开头）
	if grep -qE '^\s*zstd\s+on;' "$CONFIG_FILE"; then
		zstd_status=" zstd压缩已开启"
	else
		zstd_status=""
	fi

	# 检查 brotli 是否开启且未被注释
	if grep -qE '^\s*brotli\s+on;' "$CONFIG_FILE"; then
		br_status=" br压缩已开启"
	else
		br_status=""
	fi

	# 检查 gzip 是否开启且未被注释
	if grep -qE '^\s*gzip\s+on;' "$CONFIG_FILE"; then
		gzip_status=" gzip压缩已开启"
	else
		gzip_status=""
	fi
}

web_optimization() {
		  while true; do
		  	  check_ldnmp_mode
			  check_nginx_compression
			  clear
			  send_stats "优化LDNMP环境"
			  echo -e "优化LDNMP环境${gl_lv}${mode_info}${gzip_status}${br_status}${zstd_status}${gl_bai}"
			  echo "------------------------"
			  echo "1. 标准模式              2. 高性能模式 (推荐2H4G以上)"
			  echo "------------------------"
			  echo "3. 开启gzip压缩          4. 关闭gzip压缩"
			  echo "5. 开启br压缩            6. 关闭br压缩"
			  echo "7. 开启zstd压缩          8. 关闭zstd压缩"
			  echo "------------------------"
			  echo "0. 返回上一级选单"
			  echo "------------------------"
			  read -e -p "请输入你的选择: " sub_choice || return 1
			  case $sub_choice in
				  1)
				  send_stats "站点标准模式"

				  local cpu_cores=$(nproc)
				  local connections=$((1024 * ${cpu_cores}))
				  sed -i "s/worker_processes.*/worker_processes ${cpu_cores};/" /home/web/nginx.conf
				  sed -i "s/worker_connections.*/worker_connections ${connections};/" /home/web/nginx.conf


				  # php调优
				  wget -O /home/optimized_php.ini ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/optimized_php.ini
				  docker cp /home/optimized_php.ini php:/usr/local/etc/php/conf.d/optimized_php.ini
				  docker cp /home/optimized_php.ini php74:/usr/local/etc/php/conf.d/optimized_php.ini
				  rm -rf /home/optimized_php.ini

				  # php调优
				  wget -O /home/www.conf ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/www-1.conf
				  docker cp /home/www.conf php:/usr/local/etc/php-fpm.d/www.conf
				  docker cp /home/www.conf php74:/usr/local/etc/php-fpm.d/www.conf
				  rm -rf /home/www.conf

				  patch_wp_memory_limit
				  patch_wp_debug

				  fix_phpfpm_conf php
				  fix_phpfpm_conf php74

				  # mysql调优
				  wget -O /home/custom_mysql_config.cnf ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/custom_mysql_config-1.cnf
				  docker cp /home/custom_mysql_config.cnf mysql:/etc/mysql/conf.d/
				  rm -rf /home/custom_mysql_config.cnf


				  cd /home/web && docker compose restart

				  optimize_balanced


				  echo "LDNMP环境已设置成 标准模式"

					  ;;
				  2)
				  send_stats "站点高性能模式"

				  # nginx调优
				  local cpu_cores=$(nproc)
				  local connections=$((2048 * ${cpu_cores}))
				  sed -i "s/worker_processes.*/worker_processes ${cpu_cores};/" /home/web/nginx.conf
				  sed -i "s/worker_connections.*/worker_connections ${connections};/" /home/web/nginx.conf

				  # php调优
				  wget -O /home/optimized_php.ini ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/optimized_php.ini
				  docker cp /home/optimized_php.ini php:/usr/local/etc/php/conf.d/optimized_php.ini
				  docker cp /home/optimized_php.ini php74:/usr/local/etc/php/conf.d/optimized_php.ini
				  rm -rf /home/optimized_php.ini

				  # php调优
				  wget -O /home/www.conf ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/www.conf
				  docker cp /home/www.conf php:/usr/local/etc/php-fpm.d/www.conf
				  docker cp /home/www.conf php74:/usr/local/etc/php-fpm.d/www.conf
				  rm -rf /home/www.conf

				  patch_wp_memory_limit 512M 512M
				  patch_wp_debug

				  fix_phpfpm_conf php
				  fix_phpfpm_conf php74

				  # mysql调优
				  wget -O /home/custom_mysql_config.cnf ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/custom_mysql_config.cnf
				  docker cp /home/custom_mysql_config.cnf mysql:/etc/mysql/conf.d/
				  rm -rf /home/custom_mysql_config.cnf

				  cd /home/web && docker compose restart

				  optimize_web_server

				  echo "LDNMP环境已设置成 高性能模式"

					  ;;
				  3)
				  send_stats "nginx_gzip on"
				  nginx_gzip on
					  ;;
				  4)
				  send_stats "nginx_gzip off"
				  nginx_gzip off
					  ;;
				  5)
				  send_stats "nginx_br on"
				  nginx_br on
					  ;;
				  6)
				  send_stats "nginx_br off"
				  nginx_br off
					  ;;
				  7)
				  send_stats "nginx_zstd on"
				  nginx_zstd on
					  ;;
				  8)
				  send_stats "nginx_zstd off"
				  nginx_zstd off
					  ;;
				  *)
					  break
					  ;;
			  esac
			  break_end

		  done


}

check_docker_app() {
	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$docker_name" ; then
		check_docker="${gl_lv}已安装${gl_bai}"
	else
		check_docker="${gl_hui}未安装${gl_bai}"
	fi
}

check_docker_image_update() {
	local container_name=$1
	update_status=""

	# 1. 区域检查
	local country=$(curl -s --max-time 2 ipinfo.io/country)
	[[ "$country" == "CN" ]] && return

	# 2. 获取本地镜像信息
	local container_info=$(docker inspect --format='{{.Created}},{{.Config.Image}}' "$container_name" 2>/dev/null)
	[[ -z "$container_info" ]] && return

	local container_created=$(echo "$container_info" | cut -d',' -f1)
	local full_image_name=$(echo "$container_info" | cut -d',' -f2)
	local container_created_ts=$(date -d "$container_created" +%s 2>/dev/null)

	# 3. 智能路由判断
	if [[ "$full_image_name" == ghcr.io* ]]; then
		# --- 场景 A: 镜像在 GitHub (ghcr.io) ---
		# 提取仓库路径，例如 ghcr.io/onexru/oneimg -> onexru/oneimg
		local repo_path=$(echo "$full_image_name" | sed 's/ghcr.io\///' | cut -d':' -f1)
		# 注意：ghcr.io 的 API 比较复杂，通常最快的方法是查 GitHub Repo 的 Release
		local api_url="https://api.github.com/repos/$repo_path/releases/latest"
		local remote_date=$(curl -s "$api_url" | jq -r '.published_at' 2>/dev/null)

	elif [[ "$full_image_name" == *"oneimg"* ]]; then
		# --- 场景 B: 特殊指定 (即便在 Docker Hub，也想通过 GitHub Release 判断) ---
		local api_url="https://api.github.com/repos/onexru/oneimg/releases/latest"
		local remote_date=$(curl -s "$api_url" | jq -r '.published_at' 2>/dev/null)

	else
		# --- 场景 C: 标准 Docker Hub ---
		local image_repo=${full_image_name%%:*}
		local image_tag=${full_image_name##*:}
		[[ "$image_repo" == "$image_tag" ]] && image_tag="latest"
		[[ "$image_repo" != */* ]] && image_repo="library/$image_repo"

		local api_url="https://hub.docker.com/v2/repositories/$image_repo/tags/$image_tag"
		local remote_date=$(curl -s "$api_url" | jq -r '.last_updated' 2>/dev/null)
	fi

	# 4. 时间戳对比
	if [[ -n "$remote_date" && "$remote_date" != "null" ]]; then
		local remote_ts=$(date -d "$remote_date" +%s 2>/dev/null)
		if [[ $container_created_ts -lt $remote_ts ]]; then
			update_status="${gl_huang}发现新版本!${gl_bai}"
		fi
	fi
}

block_host_port() {
	local port=$1
	local allowed_ip=$2

	if [[ -z "$port" || -z "$allowed_ip" ]]; then
		echo "错误：请提供端口号和允许访问的 IP。"
		echo "用法: block_host_port <端口号> <允许的IP>"
		return 1
	fi

	install iptables


	# 拒绝其他所有 IP 访问
	if ! iptables -C INPUT -p tcp --dport "$port" -j DROP &>/dev/null; then
		iptables -I INPUT -p tcp --dport "$port" -j DROP
	fi

	# 允许指定 IP 访问
	if ! iptables -C INPUT -p tcp --dport "$port" -s "$allowed_ip" -j ACCEPT &>/dev/null; then
		iptables -I INPUT -p tcp --dport "$port" -s "$allowed_ip" -j ACCEPT
	fi

	# 允许本机访问
	if ! iptables -C INPUT -p tcp --dport "$port" -s 127.0.0.0/8 -j ACCEPT &>/dev/null; then
		iptables -I INPUT -p tcp --dport "$port" -s 127.0.0.0/8 -j ACCEPT
	fi





	# 拒绝其他所有 IP 访问
	if ! iptables -C INPUT -p udp --dport "$port" -j DROP &>/dev/null; then
		iptables -I INPUT -p udp --dport "$port" -j DROP
	fi

	# 允许指定 IP 访问
	if ! iptables -C INPUT -p udp --dport "$port" -s "$allowed_ip" -j ACCEPT &>/dev/null; then
		iptables -I INPUT -p udp --dport "$port" -s "$allowed_ip" -j ACCEPT
	fi

	# 允许本机访问
	if ! iptables -C INPUT -p udp --dport "$port" -s 127.0.0.0/8 -j ACCEPT &>/dev/null; then
		iptables -I INPUT -p udp --dport "$port" -s 127.0.0.0/8 -j ACCEPT
	fi

	# 允许已建立和相关连接的流量
	if ! iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT &>/dev/null; then
		iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
	fi

	echo "已阻止IP+端口访问该服务"
	save_iptables_rules
}

clear_host_port_rules() {
	local port=$1
	local allowed_ip=$2

	if [[ -z "$port" || -z "$allowed_ip" ]]; then
		echo "错误：请提供端口号和允许访问的 IP。"
		echo "用法: clear_host_port_rules <端口号> <允许的IP>"
		return 1
	fi

	install iptables


	# 清除封禁所有其他 IP 访问的规则
	if iptables -C INPUT -p tcp --dport "$port" -j DROP &>/dev/null; then
		iptables -D INPUT -p tcp --dport "$port" -j DROP
	fi

	# 清除允许本机访问的规则
	if iptables -C INPUT -p tcp --dport "$port" -s 127.0.0.0/8 -j ACCEPT &>/dev/null; then
		iptables -D INPUT -p tcp --dport "$port" -s 127.0.0.0/8 -j ACCEPT
	fi

	# 清除允许指定 IP 访问的规则
	if iptables -C INPUT -p tcp --dport "$port" -s "$allowed_ip" -j ACCEPT &>/dev/null; then
		iptables -D INPUT -p tcp --dport "$port" -s "$allowed_ip" -j ACCEPT
	fi


	# 清除封禁所有其他 IP 访问的规则
	if iptables -C INPUT -p udp --dport "$port" -j DROP &>/dev/null; then
		iptables -D INPUT -p udp --dport "$port" -j DROP
	fi

	# 清除允许本机访问的规则
	if iptables -C INPUT -p udp --dport "$port" -s 127.0.0.0/8 -j ACCEPT &>/dev/null; then
		iptables -D INPUT -p udp --dport "$port" -s 127.0.0.0/8 -j ACCEPT
	fi

	# 清除允许指定 IP 访问的规则
	if iptables -C INPUT -p udp --dport "$port" -s "$allowed_ip" -j ACCEPT &>/dev/null; then
		iptables -D INPUT -p udp --dport "$port" -s "$allowed_ip" -j ACCEPT
	fi


	echo "已允许IP+端口访问该服务"
	save_iptables_rules

}

setup_docker_dir() {

	mkdir -p /home /home/docker 2>/dev/null

	if [ -d "/vol1/1000/" ] && [ ! -d "/vol1/1000/docker" ]; then
		cp -f /home/docker /home/docker1 2>/dev/null
		rm -rf /home/docker 2>/dev/null
		mkdir -p /vol1/1000/docker 2>/dev/null
		ln -s /vol1/1000/docker /home/docker 2>/dev/null
	fi

	if [ -d "/volume1/" ] && [ ! -d "/volume1/docker" ]; then
		cp -f /home/docker /home/docker1 2>/dev/null
		rm -rf /home/docker 2>/dev/null
		mkdir -p /volume1/docker 2>/dev/null
		ln -s /volume1/docker /home/docker 2>/dev/null
	fi


}

add_app_id() {
mkdir -p /home/docker
touch /home/docker/appno.txt
grep -qxF "${app_id}" /home/docker/appno.txt || echo "${app_id}" >> /home/docker/appno.txt

}

prometheus_install() {

local PROMETHEUS_DIR="/home/docker/monitoring/prometheus"
local GRAFANA_DIR="/home/docker/monitoring/grafana"
local NETWORK_NAME="monitoring"

# Create necessary directories
mkdir -p $PROMETHEUS_DIR
mkdir -p $GRAFANA_DIR

# Set correct ownership for Grafana directory
chown -R 472:472 $GRAFANA_DIR

if [ ! -f "$PROMETHEUS_DIR/prometheus.yml" ]; then
	curl -o "$PROMETHEUS_DIR/prometheus.yml" ${gh_proxy}raw.githubusercontent.com/kejilion/config/refs/heads/main/prometheus/prometheus.yml
fi

# Create Docker network for monitoring
docker network create $NETWORK_NAME

# Run Node Exporter container
docker run -d \
  --name=node-exporter \
  --network $NETWORK_NAME \
  --restart=always \
  prom/node-exporter

# Run Prometheus container
docker run -d \
  --name prometheus \
  -v $PROMETHEUS_DIR/prometheus.yml:/etc/prometheus/prometheus.yml \
  -v $PROMETHEUS_DIR/data:/prometheus \
  --network $NETWORK_NAME \
  --restart=always \
  --user 0:0 \
  prom/prometheus:latest

# Run Grafana container
docker run -d \
  --name grafana \
  -p ${docker_port}:3000 \
  -v $GRAFANA_DIR:/var/lib/grafana \
  --network $NETWORK_NAME \
  --restart=always \
  grafana/grafana:latest

}

tmux_run() {
	# Check if the session already exists
	tmux has-session -t $SESSION_NAME 2>/dev/null
	# $? is a special variable that holds the exit status of the last executed command
	if [ $? != 0 ]; then
	  # Session doesn't exist, create a new one
	  tmux new -s $SESSION_NAME
	else
	  # Session exists, attach to it
	  tmux attach-session -t $SESSION_NAME
	fi
}

tmux_run_d() {

local base_name="tmuxd"
local tmuxd_ID=1

# 检查会话是否存在的函数
session_exists() {
  tmux has-session -t $1 2>/dev/null
}

# 循环直到找到一个不存在的会话名称
while session_exists "$base_name-$tmuxd_ID"; do
  local tmuxd_ID=$((tmuxd_ID + 1))
done

# 创建新的 tmux 会话
tmux new -d -s "$base_name-$tmuxd_ID" "$tmuxd"


}

f2b_status() {
	 fail2ban-client reload
	 sleep 3
	 fail2ban-client status
}

f2b_status_xxx() {
	fail2ban-client status $xxx
}

check_f2b_status() {
	if command -v fail2ban-client >/dev/null 2>&1; then
		check_f2b_status="${gl_lv}已安装${gl_bai}"
	else
		check_f2b_status="${gl_hui}未安装${gl_bai}"
	fi
}

f2b_install_sshd() {

	docker rm -f fail2ban >/dev/null 2>&1
	install fail2ban
	start fail2ban
	enable fail2ban

	if command -v dnf &>/dev/null; then
		cd /etc/fail2ban/jail.d/
		curl -sS -O ${gh_proxy}raw.githubusercontent.com/kejilion/config/main/fail2ban/centos-ssh.conf
	fi

	if command -v apt &>/dev/null; then
		install rsyslog
		systemctl start rsyslog
		systemctl enable rsyslog
	fi

}

f2b_sshd() {
	if grep -q 'Alpine' /etc/issue; then
		xxx=alpine-sshd
		f2b_status_xxx
	else
		xxx=sshd
		f2b_status_xxx
	fi
}

f2b_basic_config() {
	root_use
	install vim

	if ! command -v fail2ban-client >/dev/null 2>&1; then
		echo -e "${gl_hui}未检测到 fail2ban-client，请先安装 fail2ban。${gl_bai}"
		return
	fi

	local jail_name="sshd"
	if grep -qi 'Alpine' /etc/issue 2>/dev/null; then
		# Alpine 默认 jail 通常为 sshd；仅当检测到自定义 alpine-sshd 规则时才切换
		if [ -f /etc/fail2ban/filter.d/alpine-sshd.conf ] || [ -f /etc/fail2ban/jail.d/alpine-ssh.conf ] || [ -f /etc/fail2ban/jail.d/alpine-sshd.local ]; then
			jail_name="alpine-sshd"
		fi
	fi

	echo "即将配置 SSH jail：$jail_name"
	read -e -p "封禁时长 bantime (秒/分钟/小时，如 3600 或 1h) [默认 1h]: " bantime || return 1
	read -e -p "时间窗口 findtime (秒/分钟/小时，如 600 或 10m) [默认 10m]: " findtime || return 1
	read -e -p "重试次数 maxretry (整数) [默认 5]: " maxretry || return 1

	bantime=${bantime:-1h}
	findtime=${findtime:-10m}
	maxretry=${maxretry:-5}

	mkdir -p /etc/fail2ban/jail.d
	cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[$jail_name]
# Managed by kejilion.sh
# Note: enable the jail so these parameters take effect
enabled = true
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
EOF

	# Ensure a logfile exists for sshd jail on Debian/Ubuntu minimal images
	# (without it, fail2ban-server may refuse to start)
	if [ "$jail_name" = "sshd" ]; then
		if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
			if daimon_is_debian && [ ! -f /var/log/auth.log ]; then
				install python3-systemd || return 1
				echo 'backend = systemd' >> /etc/fail2ban/jail.d/sshd.local
			else
				echo 'logpath = /var/log/auth.log' >> /etc/fail2ban/jail.d/sshd.local
			fi
		fi
	fi

	echo -e "${gl_lv}已写入配置${gl_bai}: /etc/fail2ban/jail.d/sshd.local"
	fail2ban-client reload >/dev/null 2>&1 || true
	sleep 2
	fail2ban-client status $jail_name || true
}

f2b_edit_config() {
	root_use
	install vim

	if [ ! -d /etc/fail2ban ]; then
		echo -e "${gl_hui}/etc/fail2ban 不存在，请先安装 fail2ban。${gl_bai}"
		return
	fi

	mkdir -p /etc/fail2ban/jail.d
	local cfg="/etc/fail2ban/jail.d/sshd.local"
	[ -f "$cfg" ] || printf "[sshd]\n# bantime/findtime/maxretry\n" > "$cfg"

	vim "$cfg"
	echo -e "${gl_lv}已保存${gl_bai}，正在 reload fail2ban..."
	fail2ban-client reload >/dev/null 2>&1 || true
}

server_reboot() {

	read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}现在重启服务器吗？(Y/N): ")" rboot || return 1
	case "$rboot" in
	  [Yy])
		echo "已重启"
		reboot
		;;
	  *)
		echo "已取消"
		;;
	esac


}

ldnmp_install_status_one() {

   if docker inspect "php" &>/dev/null; then
	clear
	send_stats "无法再次安装LDNMP环境"
	echo -e "${gl_huang}提示: ${gl_bai}建站环境已安装。无需再次安装！"
	break_end
	linux_ldnmp
   fi

}

ldnmp_install_all() {
cd ~
send_stats "安装LDNMP环境"
root_use
clear
echo -e "${gl_huang}LDNMP环境未安装，开始安装LDNMP环境...${gl_bai}"
check_disk_space 3 /home
install_dependency
install_docker
install_certbot
install_ldnmp_conf
install_ldnmp

}

nginx_install_all() {
cd ~
send_stats "安装nginx环境"
root_use
clear
echo -e "${gl_huang}nginx未安装，开始安装nginx环境...${gl_bai}"
install_dependency
install_docker
install_certbot
install_ldnmp_conf
nginx_upgrade
clear
local nginx_version=$(docker exec nginx nginx -v 2>&1)
local nginx_version=$(echo "$nginx_version" | grep -oP "nginx/\K[0-9]+\.[0-9]+\.[0-9]+")
echo "nginx已安装完成"
echo -e "当前版本: ${gl_huang}v$nginx_version${gl_bai}"
echo ""

}

ldnmp_install_status() {

	if ! docker inspect "php" &>/dev/null; then
		send_stats "请先安装LDNMP环境"
		ldnmp_install_all
	fi

}

nginx_install_status() {

	if ! docker inspect "nginx" &>/dev/null; then
		send_stats "请先安装nginx环境"
		nginx_install_all
	fi

}

ldnmp_web_on() {
	  clear
	  echo "您的 $webname 搭建好了！"
	  echo "https://$yuming"
	  echo "------------------------"
	  echo "$webname 安装信息如下: "

}

nginx_web_on() {
	clear

	local ipv4_pattern='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
	local ipv6_pattern='^(([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){7,7}[0-9A-Fa-f]{1,4}|::1)$'

	echo "您的 $webname 搭建好了！"

	if [[ "$yuming" =~ $ipv4_pattern || "$yuming" =~ $ipv6_pattern ]]; then
		mv /home/web/conf.d/"$yuming".conf /home/web/conf.d/"${yuming}_${access_port}".conf
		echo "http://$yuming:$access_port"
	elif grep -q '^[[:space:]]*#.*if (\$scheme = http)' "/home/web/conf.d/"$yuming".conf"; then
		echo "http://$yuming"
	else
		echo "https://$yuming"
	fi
}

ldnmp_wp() {
  clear
  # wordpress
  webname="WordPress"
  yuming="${1:-}"
  send_stats "安装$webname"
  echo "开始部署 $webname"
  if [ -z "$yuming" ]; then
	add_yuming
  fi
  repeat_add_yuming
  ldnmp_install_status


  install_ssltls
  certs_status
  add_db

  wget -O /home/web/conf.d/map.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/map.conf
  wget -O /home/web/conf.d/$yuming.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/wordpress.com.conf
  sed -i "s/yuming.com/$yuming/g" /home/web/conf.d/$yuming.conf
  nginx_http_on


  cd /home/web/html
  mkdir $yuming
  cd $yuming
  wget -O latest.zip ${gh_proxy}github.com/kejilion/Website_source_code/raw/refs/heads/main/wp-latest.zip
  unzip latest.zip
  rm latest.zip
  echo "define('FS_METHOD', 'direct'); define('WP_REDIS_HOST', 'redis'); define('WP_REDIS_PORT', '6379'); define('WP_REDIS_MAXTTL', 86400); define('WP_CACHE_KEY_SALT', '${yuming}_');" >> /home/web/html/$yuming/wordpress/wp-config-sample.php
  sed -i "s|database_name_here|$dbname|g" /home/web/html/$yuming/wordpress/wp-config-sample.php
  sed -i "s|username_here|$dbuse|g" /home/web/html/$yuming/wordpress/wp-config-sample.php
  sed -i "s|password_here|$dbusepasswd|g" /home/web/html/$yuming/wordpress/wp-config-sample.php
  sed -i "s|localhost|mysql|g" /home/web/html/$yuming/wordpress/wp-config-sample.php
  patch_wp_url "https://$yuming" "https://$yuming"
  cp /home/web/html/$yuming/wordpress/wp-config-sample.php /home/web/html/$yuming/wordpress/wp-config.php


  restart_ldnmp
  nginx_web_on

}

ldnmp_Proxy() {
	clear
	webname="反向代理-IP+端口"
	yuming="${1:-}"
	reverseproxy="${2:-}"
	port="${3:-}"

	send_stats "安装$webname"
	echo "开始部署 $webname"
	if [ -z "$yuming" ]; then
		add_yuming
	fi

	check_ip_and_get_access_port "$yuming"

	if [ -z "$reverseproxy" ]; then
		read -e -p "请输入你的反代IP (回车默认本机IP 127.0.0.1): " reverseproxy || return 1
		reverseproxy=${reverseproxy:-127.0.0.1}
	fi

	if [ -z "$port" ]; then
		read -e -p "请输入你的反代端口: " port || return 1
	fi
	nginx_install_status


	install_ssltls
	certs_status

	wget -O /home/web/conf.d/map.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/map.conf
	wget -O /home/web/conf.d/$yuming.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/reverse-proxy-backend.conf

	backend=$(tr -dc 'A-Za-z' < /dev/urandom | head -c 8)
	sed -i "s/backend_yuming_com/backend_$backend/g" /home/web/conf.d/"$yuming".conf


	sed -i "s/yuming.com/$yuming/g" /home/web/conf.d/$yuming.conf

	reverseproxy_port="$reverseproxy:$port"
	upstream_servers=""
	for server in $reverseproxy_port; do
		upstream_servers="$upstream_servers    server $server;\n"
	done

	sed -i "s/# 动态添加/$upstream_servers/g" /home/web/conf.d/$yuming.conf
	sed -i '/remote_addr/d' /home/web/conf.d/$yuming.conf

	update_nginx_listen_port "$yuming" "$access_port"

	nginx_http_on
	docker exec nginx nginx -s reload
	nginx_web_on
}

ldnmp_Proxy_backend() {
	clear
	webname="反向代理-负载均衡"

	send_stats "安装$webname"
	echo "开始部署 $webname"
	if [ -z "$yuming" ]; then
		add_yuming
	fi

	check_ip_and_get_access_port "$yuming"

	if [ -z "$reverseproxy_port" ]; then
		read -e -p "请输入你的多个反代IP+端口用空格隔开（例如 127.0.0.1:3000 127.0.0.1:3002）： " reverseproxy_port || return 1
	fi

	nginx_install_status

	install_ssltls
	certs_status

	wget -O /home/web/conf.d/map.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/map.conf
	wget -O /home/web/conf.d/$yuming.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/reverse-proxy-backend.conf

	backend=$(tr -dc 'A-Za-z' < /dev/urandom | head -c 8)
	sed -i "s/backend_yuming_com/backend_$backend/g" /home/web/conf.d/"$yuming".conf


	sed -i "s/yuming.com/$yuming/g" /home/web/conf.d/$yuming.conf

	upstream_servers=""
	for server in $reverseproxy_port; do
		upstream_servers="$upstream_servers    server $server;\n"
	done

	sed -i "s/# 动态添加/$upstream_servers/g" /home/web/conf.d/$yuming.conf


	update_nginx_listen_port "$yuming" "$access_port"

	nginx_http_on
	docker exec nginx nginx -s reload
	nginx_web_on
}

list_stream_services() {

	STREAM_DIR="/home/web/stream.d"
	printf "%-25s %-18s %-25s %-20s\n" "服务名" "通信类型" "本机地址" "后端地址"

	if [ -z "$(ls -A "$STREAM_DIR")" ]; then
		return
	fi

	for conf in "$STREAM_DIR"/*; do
		# 服务名取文件名
		service_name=$(basename "$conf" .conf)

		# 获取 upstream 块中的 server 后端 IP:端口
		backend=$(grep -Po '(?<=server )[^;]+' "$conf" | head -n1)

		# 获取 listen 端口
		listen_port=$(grep -Po '(?<=listen )[^;]+' "$conf" | head -n1)

		# 默认本地 IP
		ip_address
		local_ip="$ipv4_address"

		# 获取通信类型，优先从文件名后缀或内容判断
		if grep -qi 'udp;' "$conf"; then
			proto="udp"
		else
			proto="tcp"
		fi

		# 拼接监听 IP:端口
		local_addr="$local_ip:$listen_port"

		printf "%-22s %-14s %-21s %-20s\n" "$service_name" "$proto" "$local_addr" "$backend"
	done
}

stream_panel() {
	send_stats "Stream四层代理"
	local app_id="104"
	local docker_name="nginx"

	while true; do
		clear
		check_docker_app
		check_docker_image_update $docker_name
		echo -e "Stream四层代理转发工具 $check_docker $update_status"
		echo "NGINX Stream 是 NGINX 的 TCP/UDP 代理模块，用于实现高性能的 传输层流量转发和负载均衡。"
		echo "------------------------"
		if [ -d "/home/web/stream.d" ]; then
			list_stream_services
		fi
		echo ""
		echo "------------------------"
		echo "1. 安装               2. 更新               3. 卸载"
		echo "------------------------"
		echo "4. 添加转发服务       5. 修改转发服务       6. 删除转发服务"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "输入你的选择: " choice || return 1
		case $choice in
			1)
				nginx_install_status
				add_app_id
				send_stats "安装Stream四层代理"
				;;
			2)
				update_docker_compose_with_db_creds
				nginx_upgrade
				add_app_id
				send_stats "更新Stream四层代理"
				;;
			3)
				read -e -p "确定要删除 nginx 容器吗？这可能会影响网站功能！(y/N): " confirm || return 1
				if [[ "$confirm" =~ ^[Yy]$ ]]; then
					docker rm -f nginx
					sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
					send_stats "更新Stream四层代理"
					echo "nginx 容器已删除。"
				else
					echo "操作已取消。"
				fi

				;;

			4)
				ldnmp_Proxy_backend_stream
				add_app_id
				send_stats "添加四层代理"
				;;
			5)
				send_stats "编辑转发配置"
				read -e -p "请输入你要编辑的服务名: " stream_name || return 1
				install vim
				vim /home/web/stream.d/$stream_name.conf
				docker restart nginx
				send_stats "修改四层代理"
				;;
			6)
				send_stats "删除转发配置"
				read -e -p "请输入你要删除的服务名: " stream_name || return 1
				rm /home/web/stream.d/$stream_name.conf > /dev/null 2>&1
				docker restart nginx
				send_stats "删除四层代理"
				;;
			*)
				break
				;;
		esac
		break_end
	done
}

ldnmp_Proxy_backend_stream() {
	clear
	webname="Stream四层代理-负载均衡"

	send_stats "安装$webname"
	echo "开始部署 $webname"

	# 获取代理名称
	read -erp "请输入代理转发名称 (如 mysql_proxy): " proxy_name || return 1
	if [ -z "$proxy_name" ]; then
		echo "名称不能为空"; return 1
	fi

	# 获取监听端口
	read -erp "请输入本机监听端口 (如 3306): " listen_port || return 1
	if ! [[ "$listen_port" =~ ^[0-9]+$ ]]; then
		echo "端口必须是数字"; return 1
	fi

	echo "请选择协议类型："
	echo "1. TCP    2. UDP"
	read -erp "请输入序号 [1-2]: " proto_choice || return 1

	case "$proto_choice" in
		1) proto="tcp"; listen_suffix="" ;;
		2) proto="udp"; listen_suffix=" udp" ;;
		*) echo "无效选择"; return 1 ;;
	esac

	read -e -p "请输入你的一个或者多个后端IP+端口用空格隔开（例如 10.13.0.2:3306 10.13.0.3:3306）： " reverseproxy_port || return 1

	nginx_install_status
	cd /home && mkdir -p web/stream.d
	grep -q '^[[:space:]]*stream[[:space:]]*{' /home/web/nginx.conf || echo -e '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}' | tee -a /home/web/nginx.conf
	wget -O /home/web/stream.d/$proxy_name.conf ${gh_proxy}raw.githubusercontent.com/kejilion/nginx/main/reverse-proxy-backend-stream.conf

	backend=$(tr -dc 'A-Za-z' < /dev/urandom | head -c 8)
	sed -i "s/backend_yuming_com/${proxy_name}_${backend}/g" /home/web/stream.d/"$proxy_name".conf
	sed -i "s|listen 80|listen $listen_port $listen_suffix|g" /home/web/stream.d/$proxy_name.conf
	sed -i "s|listen \[::\]:|listen [::]:${listen_port} ${listen_suffix}|g" "/home/web/stream.d/${proxy_name}.conf"

	upstream_servers=""
	for server in $reverseproxy_port; do
		upstream_servers="$upstream_servers    server $server;\n"
	done

	sed -i "s/# 动态添加/$upstream_servers/g" /home/web/stream.d/$proxy_name.conf

	docker exec nginx nginx -s reload
	clear
	echo "您的 $webname 搭建好了！"
	echo "------------------------"
	echo "访问地址:"
	ip_address
	if [ -n "$ipv4_address" ]; then
		echo "$ipv4_address:${listen_port}"
	fi
	if [ -n "$ipv6_address" ]; then
		echo "$ipv6_address:${listen_port}"
	fi
	echo ""
}

find_container_by_host_port() {
	port="$1"
	docker_name=$(docker ps --format '{{.ID}} {{.Names}}' | while read id name; do
		if docker port "$id" | grep -q ":$port"; then
			echo "$name"
			break
		fi
	done)
}

ldnmp_web_status() {
	root_use
	while true; do
		local cert_count=$(ls /home/web/certs/*_cert.pem 2>/dev/null | wc -l)
		local output="${gl_lv}${cert_count}${gl_bai}"

		local dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
		local db_count=$(docker exec mysql mysql -u root -p"$dbrootpasswd" -e "SHOW DATABASES;" 2> /dev/null | grep -Ev "Database|information_schema|mysql|performance_schema|sys" | wc -l)
		local db_output="${gl_lv}${db_count}${gl_bai}"

		clear
		send_stats "LDNMP站点管理"
		echo "LDNMP环境"
		echo "------------------------"
		ldnmp_v

		echo -e "站点: ${output}                      证书到期时间"
		echo -e "------------------------"
		for cert_file in /home/web/certs/*_cert.pem; do
		  local domain=$(basename "$cert_file" | sed 's/_cert.pem//')
		  if [ -n "$domain" ]; then
			local expire_date=$(openssl x509 -noout -enddate -in "$cert_file" | awk -F'=' '{print $2}')
			local formatted_date=$(date -d "$expire_date" '+%Y-%m-%d')
			printf "%-30s%s\n" "$domain" "$formatted_date"
		  fi
		done

		for conf_file in /home/web/conf.d/*_*.conf; do
		  [ -e "$conf_file" ] || continue
		  basename "$conf_file" .conf
		done

		for conf_file in /home/web/conf.d/*.conf; do
		  [ -e "$conf_file" ] || continue

		  filename=$(basename "$conf_file")

		  if [ "$filename" = "map.conf" ] || [ "$filename" = "default.conf" ]; then
			continue
		  fi

		  if ! grep -q "ssl_certificate" "$conf_file"; then
			basename "$conf_file" .conf
		  fi
		done

		echo "------------------------"
		echo ""
		echo -e "数据库: ${db_output}"
		echo -e "------------------------"
		local dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose.yml | tr -d '[:space:]')
		docker exec mysql mysql -u root -p"$dbrootpasswd" -e "SHOW DATABASES;" 2> /dev/null | grep -Ev "Database|information_schema|mysql|performance_schema|sys"

		echo "------------------------"
		echo ""
		echo "站点目录"
		echo "------------------------"
		echo -e "数据 ${gl_hui}/home/web/html${gl_bai}     证书 ${gl_hui}/home/web/certs${gl_bai}     配置 ${gl_hui}/home/web/conf.d${gl_bai}"
		echo "------------------------"
		echo ""
		echo "操作"
		echo "------------------------"
		echo "1.  申请/更新域名证书               2.  克隆站点域名"
		echo "3.  清理站点缓存                    4.  创建关联站点"
		echo "5.  查看访问日志                    6.  查看错误日志"
		echo "7.  编辑全局配置                    8.  编辑站点配置"
		echo "9.  管理站点数据库                  10. 查看站点分析报告"
		echo "------------------------"
		echo "20. 删除指定站点数据"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case $sub_choice in
			1)
				send_stats "申请域名证书"
				read -e -p "请输入你的域名: " yuming || return 1
				install_certbot
				docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n 2>/dev/null
				install_ssltls
				certs_status

				;;

			2)
				send_stats "克隆站点域名"
				read -e -p "请输入旧域名: " oddyuming || return 1
				read -e -p "请输入新域名: " yuming || return 1
				install_certbot
				install_ssltls
				certs_status


				add_db
				local odd_dbname=$(echo "$oddyuming" | sed -e 's/[^A-Za-z0-9]/_/g')
				local odd_dbname="${odd_dbname}"

				docker exec mysql mysqldump -u root -p"$dbrootpasswd" $odd_dbname | docker exec -i mysql mysql -u root -p"$dbrootpasswd" $dbname

				local tables=$(docker exec mysql mysql -u root -p"$dbrootpasswd" -D $dbname -e "SHOW TABLES;" | awk '{ if (NR>1) print $1 }')
				for table in $tables; do
					columns=$(docker exec mysql mysql -u root -p"$dbrootpasswd" -D $dbname -e "SHOW COLUMNS FROM $table;" | awk '{ if (NR>1) print $1 }')
					for column in $columns; do
						docker exec mysql mysql -u root -p"$dbrootpasswd" -D $dbname -e "UPDATE $table SET $column = REPLACE($column, '$oddyuming', '$yuming') WHERE $column LIKE '%$oddyuming%';"
					done
				done

				# 网站目录替换
				cp -r /home/web/html/$oddyuming /home/web/html/$yuming

				find /home/web/html/$yuming -type f -exec sed -i "s/$odd_dbname/$dbname/g" {} +
				find /home/web/html/$yuming -type f -exec sed -i "s/$oddyuming/$yuming/g" {} +

				cp /home/web/conf.d/$oddyuming.conf /home/web/conf.d/$yuming.conf
				sed -i "s/$oddyuming/$yuming/g" /home/web/conf.d/$yuming.conf

				cd /home/web && docker compose restart

				;;


			3)
				web_cache
				;;
			4)
				send_stats "创建关联站点"
				echo -e "为现有的站点再关联一个新域名用于访问"
				read -e -p "请输入现有的域名: " oddyuming || return 1
				read -e -p "请输入新域名: " yuming || return 1
				install_certbot
				install_ssltls
				certs_status

				cp /home/web/conf.d/$oddyuming.conf /home/web/conf.d/$yuming.conf
				sed -i "s|server_name $oddyuming|server_name $yuming|g" /home/web/conf.d/$yuming.conf
				sed -i "s|/etc/nginx/certs/${oddyuming}_cert.pem|/etc/nginx/certs/${yuming}_cert.pem|g" /home/web/conf.d/$yuming.conf
				sed -i "s|/etc/nginx/certs/${oddyuming}_key.pem|/etc/nginx/certs/${yuming}_key.pem|g" /home/web/conf.d/$yuming.conf

				docker exec nginx nginx -s reload

				;;
			5)
				send_stats "查看访问日志"
				tail -n 200 /home/web/log/nginx/access.log
				break_end
				;;
			6)
				send_stats "查看错误日志"
				tail -n 200 /home/web/log/nginx/error.log
				break_end
				;;
			7)
				send_stats "编辑全局配置"
				install vim
				vim /home/web/nginx.conf
				docker exec nginx nginx -s reload
				;;

			8)
				send_stats "编辑站点配置"
				read -e -p "编辑站点配置，请输入你要编辑的域名: " yuming || return 1
				install vim
				vim /home/web/conf.d/$yuming.conf
				docker exec nginx nginx -s reload
				;;
			9)
				phpmyadmin_upgrade
				break_end
				;;
			10)
				send_stats "查看站点数据"
				install goaccess
				goaccess --log-format=COMBINED /home/web/log/nginx/access.log
				;;

			20)
				web_del
				docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n 2>/dev/null

				;;
			*)
				break  # 跳出循环，退出菜单
				;;
		esac
	done


}

check_panel_app() {
if $lujing > /dev/null 2>&1; then
	check_panel="${gl_lv}已安装${gl_bai}"
else
	check_panel=""
fi
}

install_panel() {
send_stats "${panelname}管理"
while true; do
	clear
	check_panel_app
	echo -e "$panelname $check_panel"
	echo "${panelname}是一款时下流行且强大的运维管理面板。"
	echo "官网介绍: $panelurl "

	echo ""
	echo "------------------------"
	echo "1. 安装            2. 管理            3. 卸载"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "请输入你的选择: " choice || return 1
	 case $choice in
		1)
			check_disk_space 1
			install wget
			iptables_open
			panel_app_install

			add_app_id
			send_stats "${panelname}安装"
			;;
		2)
			panel_app_manage

			add_app_id
			send_stats "${panelname}控制"

			;;
		3)
			panel_app_uninstall

			sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
			send_stats "${panelname}卸载"
			;;
		*)
			break
			;;
	 esac
	 break_end
done

}

check_frp_app() {

if [ -d "/home/frp/" ]; then
	check_frp="${gl_lv}已安装${gl_bai}"
else
	check_frp="${gl_hui}未安装${gl_bai}"
fi

}

donlond_frp() {
  role="$1"
  config_file="/home/frp/${role}.toml"

  docker run -d \
	--name "$role" \
	--restart=always \
	--network host \
	-v "$config_file":"/frp/${role}.toml" \
	kjlion/frp:alpine \
	"/frp/${role}" -c "/frp/${role}.toml"

}

generate_frps_config() {

	send_stats "安装frp服务端"
	# 生成随机端口和凭证
	local bind_port=8055
	local dashboard_port=8056
	local token=$(openssl rand -hex 16)
	local dashboard_user="user_$(openssl rand -hex 4)"
	local dashboard_pwd=$(openssl rand -hex 8)

	mkdir -p /home/frp
	touch /home/frp/frps.toml
	cat <<EOF > /home/frp/frps.toml
[common]
bind_port = $bind_port
authentication_method = token
token = $token
dashboard_port = $dashboard_port
dashboard_user = $dashboard_user
dashboard_pwd = $dashboard_pwd
EOF

	donlond_frp frps

	# 输出生成的信息
	ip_address
	echo "------------------------"
	echo "客户端部署时需要用的参数"
	echo "服务IP: $ipv4_address"
	echo "token: $token"
	echo
	echo "FRP面板信息"
	echo "FRP面板地址: http://$ipv4_address:$dashboard_port"
	echo "FRP面板用户名: $dashboard_user"
	echo "FRP面板密码: $dashboard_pwd"
	echo

	open_port 8055 8056

}

configure_frpc() {
	send_stats "安装frp客户端"
	read -e -p "请输入外网对接IP: " server_addr || return 1
	read -e -p "请输入外网对接token: " token || return 1
	echo

	mkdir -p /home/frp
	touch /home/frp/frpc.toml
	cat <<EOF > /home/frp/frpc.toml
[common]
server_addr = ${server_addr}
server_port = 8055
token = ${token}

EOF

	donlond_frp frpc

	open_port 8055

}

add_forwarding_service() {
	send_stats "添加frp内网服务"
	# 提示用户输入服务名称和转发信息
	read -e -p "请输入服务名称: " service_name || return 1
	read -e -p "请输入转发类型 (tcp/udp) [回车默认tcp]: " service_type || return 1
	local service_type=${service_type:-tcp}
	read -e -p "请输入内网IP [回车默认127.0.0.1]: " local_ip || return 1
	local local_ip=${local_ip:-127.0.0.1}
	read -e -p "请输入内网端口: " local_port || return 1
	read -e -p "请输入外网端口: " remote_port || return 1

	# 将用户输入写入配置文件
	cat <<EOF >> /home/frp/frpc.toml
[$service_name]
type = ${service_type}
local_ip = ${local_ip}
local_port = ${local_port}
remote_port = ${remote_port}

EOF

	# 输出生成的信息
	echo "服务 $service_name 已成功添加到 frpc.toml"

	docker restart frpc

	open_port $local_port

}

delete_forwarding_service() {
	send_stats "删除frp内网服务"
	# 提示用户输入需要删除的服务名称
	read -e -p "请输入需要删除的服务名称: " service_name || return 1
	# 使用 sed 删除该服务及其相关配置
	sed -i "/\[$service_name\]/,/^$/d" /home/frp/frpc.toml
	echo "服务 $service_name 已成功从 frpc.toml 删除"

	docker restart frpc

}

list_forwarding_services() {
	local config_file="$1"

	# 打印表头
	printf "%-20s %-25s %-30s %-10s\n" "服务名称" "内网地址" "外网地址" "协议"

	awk '
	BEGIN {
		server_addr=""
		server_port=""
		current_service=""
	}

	/^server_addr = / {
		gsub(/"|'"'"'/, "", $3)
		server_addr=$3
	}

	/^server_port = / {
		gsub(/"|'"'"'/, "", $3)
		server_port=$3
	}

	/^\[.*\]/ {
		# 如果已有服务信息，在处理新服务之前打印当前服务
		if (current_service != "" && current_service != "common" && local_ip != "" && local_port != "") {
			printf "%-16s %-21s %-26s %-10s\n", \
				current_service, \
				local_ip ":" local_port, \
				server_addr ":" remote_port, \
				type
		}

		# 更新当前服务名称
		if ($1 != "[common]") {
			gsub(/[\[\]]/, "", $1)
			current_service=$1
			# 清除之前的值
			local_ip=""
			local_port=""
			remote_port=""
			type=""
		}
	}

	/^local_ip = / {
		gsub(/"|'"'"'/, "", $3)
		local_ip=$3
	}

	/^local_port = / {
		gsub(/"|'"'"'/, "", $3)
		local_port=$3
	}

	/^remote_port = / {
		gsub(/"|'"'"'/, "", $3)
		remote_port=$3
	}

	/^type = / {
		gsub(/"|'"'"'/, "", $3)
		type=$3
	}

	END {
		# 打印最后一个服务的信息
		if (current_service != "" && current_service != "common" && local_ip != "" && local_port != "") {
			printf "%-16s %-21s %-26s %-10s\n", \
				current_service, \
				local_ip ":" local_port, \
				server_addr ":" remote_port, \
				type
		}
	}' "$config_file"
}

get_frp_ports() {
	mapfile -t ports < <(ss -tulnape | grep frps | awk '{print $5}' | awk -F':' '{print $NF}' | sort -u)
}

generate_access_urls() {
	# 首先获取所有端口
	get_frp_ports

	# 检查是否有非 8055/8056 的端口
	local has_valid_ports=false
	for port in "${ports[@]}"; do
		if [[ $port != "8055" && $port != "8056" ]]; then
			has_valid_ports=true
			break
		fi
	done

	# 只在有有效端口时显示标题和内容
	if [ "$has_valid_ports" = true ]; then
		echo "FRP服务对外访问地址:"

		# 处理 IPv4 地址
		for port in "${ports[@]}"; do
			if [[ $port != "8055" && $port != "8056" ]]; then
				echo "http://${ipv4_address}:${port}"
			fi
		done

		# 处理 IPv6 地址（如果存在）
		if [ -n "$ipv6_address" ]; then
			for port in "${ports[@]}"; do
				if [[ $port != "8055" && $port != "8056" ]]; then
					echo "http://[${ipv6_address}]:${port}"
				fi
			done
		fi

		# 处理 HTTPS 配置
		for port in "${ports[@]}"; do
			if [[ $port != "8055" && $port != "8056" ]]; then
				local frps_search_pattern="${ipv4_address}:${port}"
				local frps_search_pattern2="127.0.0.1:${port}"
				for file in /home/web/conf.d/*.conf; do
					if [ -f "$file" ]; then
						if grep -q "$frps_search_pattern" "$file" 2>/dev/null || grep -q "$frps_search_pattern2" "$file" 2>/dev/null; then
							echo "https://$(basename "$file" .conf)"
						fi
					fi
				done
			fi
		done
	fi
}

frps_main_ports() {
	ip_address
	generate_access_urls
}

frps_panel() {
	send_stats "FRP服务端"
	local app_id="55"
	local docker_name="frps"
	local docker_port=8056
	while true; do
		clear
		check_frp_app
		check_docker_image_update $docker_name
		echo -e "FRP服务端 $check_frp $update_status"
		echo "构建FRP内网穿透服务环境，将无公网IP的设备暴露到互联网"
		echo "官网介绍: ${gh_https_url}github.com/fatedier/frp/"
		echo "视频教学: https://www.bilibili.com/video/BV1yMw6e2EwL?t=124.0"
		if [ -d "/home/frp/" ]; then
			check_docker_app_ip
			frps_main_ports
		fi
		echo ""
		echo "------------------------"
		echo "1. 安装                  2. 更新                  3. 卸载"
		echo "------------------------"
		echo "5. 内网服务域名访问      6. 删除域名访问"
		echo "------------------------"
		echo "7. 允许IP+端口访问       8. 阻止IP+端口访问"
		echo "------------------------"
		echo "00. 刷新服务状态         0. 返回上一级选单"
		echo "------------------------"
		read -e -p "输入你的选择: " choice || return 1
		case $choice in
			1)
				install jq grep ss
				install_docker
				generate_frps_config

				add_app_id
				echo "FRP服务端已经安装完成"
				;;
			2)
				crontab -l | grep -v 'frps' | crontab - > /dev/null 2>&1
				tmux kill-session -t frps >/dev/null 2>&1
				docker rm -f frps && docker rmi kjlion/frp:alpine >/dev/null 2>&1
				[ -f /home/frp/frps.toml ] || cp /home/frp/frp_0.61.0_linux_amd64/frps.toml /home/frp/frps.toml
				donlond_frp frps

				add_app_id
				echo "FRP服务端已经更新完成"
				;;
			3)
				crontab -l | grep -v 'frps' | crontab - > /dev/null 2>&1
				tmux kill-session -t frps >/dev/null 2>&1
				docker rm -f frps && docker rmi kjlion/frp:alpine
				rm -rf /home/frp

				close_port 8055 8056

				sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
				echo "应用已卸载"
				;;
			5)
				echo "将内网穿透服务反代成域名访问"
				send_stats "FRP对外域名访问"
				add_yuming
				read -e -p "请输入你的内网穿透服务端口: " frps_port || return 1
				ldnmp_Proxy ${yuming} 127.0.0.1 ${frps_port}
				block_host_port "$frps_port" "$ipv4_address"
				;;
			6)
				echo "域名格式 example.com 不带https://"
				web_del
				;;

			7)
				send_stats "允许IP访问"
				read -e -p "请输入需要放行的端口: " frps_port || return 1
				clear_host_port_rules "$frps_port" "$ipv4_address"
				;;

			8)
				send_stats "阻止IP访问"
				echo "如果你已经反代域名访问了，可用此功能阻止IP+端口访问，这样更安全。"
				read -e -p "请输入需要阻止的端口: " frps_port || return 1
				block_host_port "$frps_port" "$ipv4_address"
				;;

			00)
				send_stats "刷新FRP服务状态"
				echo "已经刷新FRP服务状态"
				;;

			*)
				break
				;;
		esac
		break_end
	done
}

frpc_panel() {
	send_stats "FRP客户端"
	local app_id="56"
	local docker_name="frpc"
	local docker_port=8055
	while true; do
		clear
		check_frp_app
		check_docker_image_update $docker_name
		echo -e "FRP客户端 $check_frp $update_status"
		echo "与服务端对接，对接后可创建内网穿透服务到互联网访问"
		echo "官网介绍: ${gh_https_url}github.com/fatedier/frp/"
		echo "视频教学: https://www.bilibili.com/video/BV1yMw6e2EwL?t=173.9"
		echo "------------------------"
		if [ -d "/home/frp/" ]; then
			[ -f /home/frp/frpc.toml ] || cp /home/frp/frp_0.61.0_linux_amd64/frpc.toml /home/frp/frpc.toml
			list_forwarding_services "/home/frp/frpc.toml"
		fi
		echo ""
		echo "------------------------"
		echo "1. 安装               2. 更新               3. 卸载"
		echo "------------------------"
		echo "4. 添加对外服务       5. 删除对外服务       6. 手动配置服务"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "输入你的选择: " choice || return 1
		case $choice in
			1)
				install jq grep ss
				install_docker
				configure_frpc

				add_app_id
				echo "FRP客户端已经安装完成"
				;;
			2)
				crontab -l | grep -v 'frpc' | crontab - > /dev/null 2>&1
				tmux kill-session -t frpc >/dev/null 2>&1
				docker rm -f frpc && docker rmi kjlion/frp:alpine >/dev/null 2>&1
				[ -f /home/frp/frpc.toml ] || cp /home/frp/frp_0.61.0_linux_amd64/frpc.toml /home/frp/frpc.toml
				donlond_frp frpc

				add_app_id
				echo "FRP客户端已经更新完成"
				;;

			3)
				crontab -l | grep -v 'frpc' | crontab - > /dev/null 2>&1
				tmux kill-session -t frpc >/dev/null 2>&1
				docker rm -f frpc && docker rmi kjlion/frp:alpine
				rm -rf /home/frp
				close_port 8055

				sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
				echo "应用已卸载"
				;;

			4)
				add_forwarding_service
				;;

			5)
				delete_forwarding_service
				;;

			6)
				install vim
				vim /home/frp/frpc.toml
				docker restart frpc
				;;

			*)
				break
				;;
		esac
		break_end
	done
}

yt_menu_pro() {

	local app_id="66"
	local VIDEO_DIR="/home/yt-dlp"
	local URL_FILE="$VIDEO_DIR/urls.txt"
	local ARCHIVE_FILE="$VIDEO_DIR/archive.txt"

	mkdir -p "$VIDEO_DIR"

	while true; do

		if [ -x "/usr/local/bin/yt-dlp" ]; then
		   local YTDLP_STATUS="${gl_lv}已安装${gl_bai}"
		else
		   local YTDLP_STATUS="${gl_hui}未安装${gl_bai}"
		fi

		clear
		send_stats "yt-dlp 下载工具"
		echo -e "yt-dlp $YTDLP_STATUS"
		echo -e "yt-dlp 是一个功能强大的视频下载工具，支持 YouTube、Bilibili、Twitter 等数千站点。"
		echo -e "官网地址：${gh_https_url}github.com/yt-dlp/yt-dlp"
		echo "-------------------------"
		echo "已下载视频列表:"
		ls -td "$VIDEO_DIR"/*/ 2>/dev/null || echo "（暂无）"
		echo "-------------------------"
		echo "1.  安装               2.  更新               3.  卸载"
		echo "-------------------------"
		echo "5.  单个视频下载       6.  批量视频下载       7.  自定义参数下载"
		echo "8.  下载为MP3音频      9.  删除视频目录       10. Cookie管理（开发中）"
		echo "-------------------------"
		echo "0. 返回上一级选单"
		echo "-------------------------"
		read -e -p "请输入选项编号: " choice || return 1

		case $choice in
			1)
				send_stats "正在安装 yt-dlp..."
				echo "正在安装 yt-dlp..."
				install ffmpeg
				daimon_download_to "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" "/usr/local/bin/yt-dlp"
				chmod a+rx /usr/local/bin/yt-dlp

				add_app_id
				echo "安装完成。按任意键继续..."
				read ;;
			2)
				send_stats "正在更新 yt-dlp..."
				echo "正在更新 yt-dlp..."
				yt-dlp -U

				add_app_id
				echo "更新完成。按任意键继续..."
				read ;;
			3)
				send_stats "正在卸载 yt-dlp..."
				echo "正在卸载 yt-dlp..."
				rm -f /usr/local/bin/yt-dlp

				sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
				echo "卸载完成。按任意键继续..."
				read ;;
			5)
				send_stats "单个视频下载"
				read -e -p "请输入视频链接: " url || return 1
				yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
					--write-subs --sub-langs all \
					--write-thumbnail --embed-thumbnail \
					--write-info-json \
					-o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
					--no-overwrites --no-post-overwrites "$url"
				read -e -p "下载完成，按任意键继续..." ;;
			6)
				send_stats "批量视频下载"
				install vim
				if [ ! -f "$URL_FILE" ]; then
				  echo -e "# 输入多个视频链接地址\n# https://www.bilibili.com/bangumi/play/ep733316?spm_id_from=333.337.0.0&from_spmid=666.25.episode.0" > "$URL_FILE"
				fi
				vim $URL_FILE
				echo "现在开始批量下载..."
				yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
					--write-subs --sub-langs all \
					--write-thumbnail --embed-thumbnail \
					--write-info-json \
					-a "$URL_FILE" \
					-o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
					--no-overwrites --no-post-overwrites
				read -e -p "批量下载完成，按任意键继续..." ;;
			7)
				send_stats "自定义视频下载"
				read -e -p "请输入完整 yt-dlp 参数（不含 yt-dlp）: " custom || return 1
				yt-dlp -P "$VIDEO_DIR" $custom \
					--write-subs --sub-langs all \
					--write-thumbnail --embed-thumbnail \
					--write-info-json \
					-o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
					--no-overwrites --no-post-overwrites
				read -e -p "执行完成，按任意键继续..." ;;
			8)
				send_stats "MP3下载"
				read -e -p "请输入视频链接: " url || return 1
				yt-dlp -P "$VIDEO_DIR" -x --audio-format mp3 \
					--write-subs --sub-langs all \
					--write-thumbnail --embed-thumbnail \
					--write-info-json \
					-o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
					--no-overwrites --no-post-overwrites "$url"
				read -e -p "音频下载完成，按任意键继续..." ;;

			9)
				send_stats "删除视频"
				read -e -p "请输入删除视频名称: " rmdir || return 1
				if [ -z "$rmdir" ] || [ "$rmdir" = "." ] || [ "$rmdir" = ".." ] || [[ "$rmdir" == */* ]]; then
					echo -e "${gl_hong}名称无效，未删除任何内容。${gl_bai}"
				elif [ ! -e "$VIDEO_DIR/$rmdir" ]; then
					echo -e "${gl_huang}未找到 $rmdir，未删除任何内容。${gl_bai}"
				else
					rm -rf "$VIDEO_DIR/$rmdir"
					echo -e "${gl_lv}已删除 $rmdir${gl_bai}"
				fi
				;;
			*)
				break ;;
		esac
	done
}

bbr_on() {

# 统一写入到 sysctl.d 以防与内核调优模块打架
local CONF="/etc/sysctl.d/99-kejilion-bbr.conf"
mkdir -p /etc/sysctl.d
echo "net.core.default_qdisc=fq" > "$CONF"
echo "net.ipv4.tcp_congestion_control=bbr" >> "$CONF"

# 清理可能导致冲突的旧版 sysctl.conf 残留
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null

sysctl -p "$CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1

}

new_ssh_port() {
	ssh_transaction_apply Port "$1"
}

add_sshkey() {
	chmod 700 "${HOME}"
	mkdir -p "${HOME}/.ssh"
	chmod 700 "${HOME}/.ssh"
	touch "${HOME}/.ssh/authorized_keys"

	ssh-keygen -t ed25519 -C "xxxx@gmail.com" -f "${HOME}/.ssh/sshkey" -N "" || return 1

	cat "${HOME}/.ssh/sshkey.pub" >> "${HOME}/.ssh/authorized_keys" || return 1
	chmod 600 "${HOME}/.ssh/authorized_keys" || return 1

	ip_address
	echo -e "私钥信息已生成，务必复制保存，可保存成 ${gl_huang}${ipv4_address}_ssh.key${gl_bai} 文件，用于以后的SSH登录"

	echo "--------------------------------"
	cat "${HOME}/.ssh/sshkey"
	echo "--------------------------------"

	sshkey_on
}

fetch_github_ssh_keys() {

	local username="$1"
	local base_dir="${2:-$HOME}"

	echo "操作前，请确保您已在 GitHub 账户中添加了 SSH 公钥："
	echo "  1. 登录 ${gh_https_url}github.com/settings/keys"
	echo "  2. 点击 New SSH key 或 Add SSH key"
	echo "  3. Title 可随意填写（例如：Home Laptop 2026）"
	echo "  4. 将本地公钥内容（通常是 ~/.ssh/id_ed25519.pub 或 id_rsa.pub 的全部内容）粘贴到 Key 字段"
	echo "  5. 点击 Add SSH key 完成添加"
	echo ""
	echo "添加完成后，GitHub 会公开提供您的所有公钥，地址为："
	echo "  ${gh_https_url}github.com/您的用户名.keys"
	echo ""


	if [[ -z "${username}" ]]; then
		read -e -p "请输入您的 GitHub 用户名（username，不含 @）： " username || return 1
	fi

	if [[ -z "${username}" ]]; then
		echo "错误：GitHub 用户名不能为空" >&2
		return 1
	fi

	keys_url="${gh_https_url}github.com/${username}.keys"

	fetch_remote_ssh_keys "${keys_url}" "${base_dir}"

}

add_sshpasswd() {

	root_use
	send_stats "设置密码登录模式"
	echo "设置密码登录模式"

	local target_user="$1"

	# 如果没有通过参数传入，则交互输入
	if [[ -z "$target_user" ]]; then
		read -e -p "请输入要修改密码的用户名（默认 root）: " target_user || return 1
	fi

	# 回车不输入，默认 root
	target_user=${target_user:-root}

	# 校验用户是否存在
	if ! id "$target_user" >/dev/null 2>&1; then
		echo "错误：用户 $target_user 不存在"
		return 1
	fi

	[ ! -e /var/lib/daimon/ssh-change ] || { echo "SSH 事务尚未确认，暂不修改密码。" >&2; return 1; }
	passwd "$target_user" || { echo "密码修改失败，SSH 配置未变更。" >&2; return 1; }
	local -a policy=(PasswordAuthentication yes)
	[ "$target_user" != root ] || policy+=(PermitRootLogin yes)
	if ! ssh_transaction_apply "${policy[@]}"; then
		echo "密码已修改，但 SSH 策略未完成应用；请按上方错误处理。" >&2
		return 1
	fi

}

bbrv3() {
		  root_use
		  send_stats "bbrv3管理"

		  xanmod_add_repo() {
				local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
				local list_file="/etc/apt/sources.list.d/xanmod-release.list"
				local key_url="https://dl.xanmod.org/archive.key"
				local fallback_key_url="${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key"
				local os_codename=""

				if command -v lsb_release >/dev/null 2>&1; then
					os_codename=$(lsb_release -sc)
				elif [ -r /etc/os-release ]; then
					os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
				fi
				
				# 兼容官方已移除的老系统代号（回退使用 releases 尝试旧包库）
				if ! echo "bookworm trixie forky sid noble plucky questing resolute faye gigi wilma xia zara zena" | grep -qw "$os_codename"; then
					os_codename="releases"
				fi
				
				# 官方已彻底移除对 jammy, focal, bullseye 等老系统的 apt 支持
				if echo "jammy focal bullseye buster" | grep -qw "$os_codename" || [ "$os_codename" = "releases" ]; then
					echo -e "${gl_hong}XanMod 官方已停止对当前系统($os_codename)的 APT 源支持，请升级至 Debian12 / Ubuntu24 或更高版本。${gl_bai}"
					return 1
				fi

				if [ -z "$os_codename" ]; then
					echo "无法获取系统代号，无法配置XanMod源"
					return 1
				fi

				install wget gnupg ca-certificates
				mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
				if ! wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes; then
					echo "官方密钥下载失败，尝试备用下载源..."
					wget -qO - "$fallback_key_url" | gpg --dearmor -o "$keyring" --yes || return 1
				fi
				chmod 644 "$keyring"
				echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
		  }

		  xanmod_detect_psabi_level() {
				local psabi_output=""
				psabi_output=$(awk 'BEGIN {
					while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
					if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
					if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
					if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
					if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
					if (level > 0) { print level; exit }
					exit 1
				}' /proc/cpuinfo 2>/dev/null) || return 1
				printf '%s' "$psabi_output" | tr -dc '0-9' | head -c 1
		  }

		  xanmod_package_available() {
				local package="$1"
				apt-cache policy "$package" 2>/dev/null | grep -q 'Candidate: [^ ]'
		  }

		  xanmod_detect_package() {
				local psabi_level=""
				local level=""
				local package=""
				local prefix_list="linux-xanmod linux-xanmod-lts"

				psabi_level=$(xanmod_detect_psabi_level) || return 1
				[ -n "$psabi_level" ] || return 1
				[ "$psabi_level" -gt 3 ] && psabi_level=3

				apt update -y >/dev/null 2>&1

				for prefix in $prefix_list; do
					level="$psabi_level"
					while [ "$level" -ge 1 ]; do
						package="${prefix}-x64v${level}"
						if xanmod_package_available "$package"; then
							if [ "$level" != "$psabi_level" ] || [ "$prefix" = "linux-xanmod-lts" ]; then
								echo "已自动匹配合适安装包: $package" >&2
							fi
							printf '%s\n' "$package"
							return 0
						fi
						level=$((level - 1))
					done
				done

				echo "软件源中未找到适配此CPU的XanMod内核包" >&2
				return 1
		  }

		  xanmod_installed() {
				dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'
		  }

		  xanmod_install_or_update() {
				local action="$1"
				local package=""

				check_disk_space 3
				check_swap
				xanmod_add_repo || {
					echo "XanMod官方仓库配置失败，请稍后重试"
					return 1
				}

				package=$(xanmod_detect_package) || {
					echo "无法识别当前CPU或找不到匹配内核包，已取消安装"
					return 1
				}

				apt update -y
				if [ "$action" = "update" ]; then
					apt install -y --only-upgrade "$package" || apt install -y "$package" || {
						echo "XanMod内核更新失败，请检查软件源或稍后重试"
						return 1
					}
				else
					apt install -y "$package" || {
						echo "XanMod内核安装失败，请检查软件源或稍后重试"
						return 1
					}
				fi

				bbr_on || {
					echo "BBR3参数写入失败，请检查系统配置"
					return 1
				}
				echo "XanMod BBRv3内核处理完成。重启后生效"
				server_reboot
		  }

		  xanmod_uninstall() {
				apt purge -y 'linux-*xanmod*'
				apt autoremove -y
				update-grub 2>/dev/null || true
				rm -f /etc/apt/sources.list.d/xanmod-release.list
				rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
				echo "XanMod内核已卸载。重启后生效"
				server_reboot
		  }

		  local cpu_arch=$(uname -m)
		  if [ "$cpu_arch" = "aarch64" ]; then
			daimon_run_cached_script "https://jhb.ovh/jb/bbrv3arm.sh" "bbrv3arm.sh"
			break_end
			linux_Settings
		  fi

		  if [ -r /etc/os-release ]; then
			. /etc/os-release
			if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
				echo "当前环境不支持，仅支持Debian和Ubuntu系统"
				break_end
				linux_Settings
			fi
		  else
			echo "无法确定操作系统类型"
			break_end
			linux_Settings
		  fi

		  if xanmod_installed; then
			while true; do
				  clear
				  local kernel_version=$(uname -r)
				  echo "您已安装xanmod的BBRv3内核"
				  echo "当前内核版本: $kernel_version"

				  echo ""
				  echo "内核管理"
				  echo "------------------------"
				  echo "1. 更新BBRv3内核              2. 卸载BBRv3内核"
				  echo "------------------------"
				  echo "0. 返回上一级选单"
				  echo "------------------------"
				  read -e -p "请输入你的选择: " sub_choice || return 1

				  case $sub_choice in
					  1)
						xanmod_install_or_update update
						;;
					  2)
						xanmod_uninstall
						;;
					  *)
						break
						;;

				  esac
			done
		else

		  clear
		  echo "设置BBR3加速"
		  echo "视频介绍: https://www.bilibili.com/video/BV14K421x7BS?t=0.1"
		  echo "------------------------------------------------"
		  echo "仅支持Debian/Ubuntu"
		  echo "请备份数据，将为你升级Linux内核开启BBR3"
		  echo "------------------------------------------------"
		  read -e -p "确定继续吗？(Y/N): " choice || return 1

		  case "$choice" in
			[Yy])
			xanmod_install_or_update install
			  ;;
			[Nn])
			  echo "已取消"
			  ;;
			*)
			  echo "无效的选择，请输入 Y 或 N。"
			  ;;
		  esac
		fi

}

elrepo_install() {
	# 导入 ELRepo GPG 公钥
	echo "导入 ELRepo GPG 公钥..."
	rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
	# 检测系统版本
	local os_version=$(rpm -q --qf "%{VERSION}" $(rpm -qf /etc/os-release) 2>/dev/null | awk -F '.' '{print $1}')
	local os_name=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
	# 确保我们在一个支持的操作系统上运行
	if [[ "$os_name" != *"Red Hat"* && "$os_name" != *"AlmaLinux"* && "$os_name" != *"Rocky"* && "$os_name" != *"Oracle"* && "$os_name" != *"CentOS"* ]]; then
		echo "不支持的操作系统：$os_name"
		break_end
		linux_Settings
	fi
	# 打印检测到的操作系统信息
	echo "检测到的操作系统: $os_name $os_version"
	# 根据系统版本安装对应的 ELRepo 仓库配置
	if [[ "$os_version" == 8 ]]; then
		echo "安装 ELRepo 仓库配置 (版本 8)..."
		yum -y install https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm
	elif [[ "$os_version" == 9 ]]; then
		echo "安装 ELRepo 仓库配置 (版本 9)..."
		yum -y install https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm
	elif [[ "$os_version" == 10 ]]; then
		echo "安装 ELRepo 仓库配置 (版本 10)..."
		yum -y install https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm
	else
		echo "不支持的系统版本：$os_version"
		break_end
		linux_Settings
	fi
	# 启用 ELRepo 内核仓库并安装最新的主线内核
	echo "启用 ELRepo 内核仓库并安装最新的主线内核..."
	# yum -y --enablerepo=elrepo-kernel install kernel-ml
	yum --nogpgcheck -y --enablerepo=elrepo-kernel install kernel-ml
	echo "已安装 ELRepo 仓库配置并更新到最新主线内核。"
	server_reboot

}

elrepo() {
		  root_use
		  send_stats "红帽内核管理"
		  if uname -r | grep -q 'elrepo'; then
			while true; do
				  clear
				  kernel_version=$(uname -r)
				  echo "您已安装elrepo内核"
				  echo "当前内核版本: $kernel_version"

				  echo ""
				  echo "内核管理"
				  echo "------------------------"
				  echo "1. 更新elrepo内核              2. 卸载elrepo内核"
				  echo "------------------------"
				  echo "0. 返回上一级选单"
				  echo "------------------------"
				  read -e -p "请输入你的选择: " sub_choice || return 1

				  case $sub_choice in
					  1)
						dnf remove -y elrepo-release
						rpm -qa | grep elrepo | grep kernel | xargs rpm -e --nodeps
						elrepo_install
						send_stats "更新红帽内核"
						server_reboot

						  ;;
					  2)
						dnf remove -y elrepo-release
						rpm -qa | grep elrepo | grep kernel | xargs rpm -e --nodeps
						echo "elrepo内核已卸载。重启后生效"
						send_stats "卸载红帽内核"
						server_reboot

						  ;;
					  *)
						  break  # 跳出循环，退出菜单
						  ;;

				  esac
			done
		else

		  clear
		  echo "请备份数据，将为你升级Linux内核"
		  echo "视频介绍: https://www.bilibili.com/video/BV1mH4y1w7qA?t=529.2"
		  echo "------------------------------------------------"
		  echo "仅支持红帽系列发行版 CentOS/RedHat/Alma/Rocky/oracle "
		  echo "升级Linux内核可提升系统性能和安全，建议有条件的尝试，生产环境谨慎升级！"
		  echo "------------------------------------------------"
		  read -e -p "确定继续吗？(Y/N): " choice || return 1

		  case "$choice" in
			[Yy])
			  check_swap
			  elrepo_install
			  send_stats "升级红帽内核"
			  server_reboot
			  ;;
			[Nn])
			  echo "已取消"
			  ;;
			*)
			  echo "无效的选择，请输入 Y 或 N。"
			  ;;
		  esac
		fi

}

clamav_freshclam() {
	echo -e "${gl_kjlan}正在更新病毒库...${gl_bai}"
	docker run --rm \
		--name clamav \
		--mount source=clam_db,target=/var/lib/clamav \
		clamav/clamav-debian:latest \
		freshclam
}

clamav_scan() {
	if [ $# -eq 0 ]; then
		echo "请指定要扫描的目录。"
		return
	fi

	echo -e "${gl_kjlan}正在扫描目录 $*... ${gl_bai}"

	# 构建 mount 参数
	local MOUNT_PARAMS=""
	for dir in "$@"; do
		MOUNT_PARAMS+="--mount type=bind,source=${dir},target=/mnt/host${dir} "
	done

	# 构建 clamscan 命令参数
	local SCAN_PARAMS=""
	for dir in "$@"; do
		SCAN_PARAMS+="/mnt/host${dir} "
	done

	mkdir -p /home/docker/clamav/log/ > /dev/null 2>&1
	> /home/docker/clamav/log/scan.log > /dev/null 2>&1

	# 执行 Docker 命令
	docker run --rm \
		--name clamav \
		--mount source=clam_db,target=/var/lib/clamav \
		$MOUNT_PARAMS \
		-v /home/docker/clamav/log/:/var/log/clamav/ \
		clamav/clamav-debian:latest \
		clamscan -r --log=/var/log/clamav/scan.log $SCAN_PARAMS

	echo -e "${gl_lv}$* 扫描完成，病毒报告存放在${gl_huang}/home/docker/clamav/log/scan.log${gl_bai}"
	echo -e "${gl_lv}如果有病毒请在${gl_huang}scan.log${gl_lv}文件中搜索FOUND关键字确认病毒位置 ${gl_bai}"

}

clamav() {
		  root_use
		  send_stats "病毒扫描管理"
		  while true; do
				clear
				echo "clamav病毒扫描工具"
				echo "视频介绍: https://www.bilibili.com/video/BV1TqvZe4EQm?t=0.1"
				echo "------------------------"
				echo "是一个开源的防病毒软件工具，主要用于检测和删除各种类型的恶意软件。"
				echo "包括病毒、特洛伊木马、间谍软件、恶意脚本和其他有害软件。"
				echo "------------------------"
				echo -e "${gl_lv}1. 全盘扫描 ${gl_bai}             ${gl_huang}2. 重要目录扫描 ${gl_bai}            ${gl_kjlan} 3. 自定义目录扫描 ${gl_bai}"
				echo "------------------------"
				echo "0. 返回上一级选单"
				echo "------------------------"
				read -e -p "请输入你的选择: " sub_choice || return 1
				case $sub_choice in
					1)
					  send_stats "全盘扫描"
					  install_docker
					  docker volume create clam_db > /dev/null 2>&1
					  clamav_freshclam
					  clamav_scan /
					  break_end

						;;
					2)
					  send_stats "重要目录扫描"
					  install_docker
					  docker volume create clam_db > /dev/null 2>&1
					  clamav_freshclam
					  clamav_scan /etc /var /usr /home /root
					  break_end
						;;
					3)
					  send_stats "自定义目录扫描"
					  read -e -p "请输入要扫描的目录，用空格分隔（例如：/etc /var /usr /home /root）: " directories || return 1
					  install_docker
					  clamav_freshclam
					  clamav_scan $directories
					  break_end
						;;
					*)
					  break  # 跳出循环，退出菜单
						;;
				esac
		  done

}

_get_mem_mb() {
	awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

_kernel_optimize_core() {
	local mode_name="$1"
	local scene="${2:-high}"
	local CONF="/etc/sysctl.d/99-kejilion-optimize.conf"
	local MEM_MB=$(_get_mem_mb)

	echo -e "${gl_lv}切换到${mode_name}...${gl_bai}"

	# ── 根据场景设定参数 ──
	local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
	local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
	local SOMAXCONN BACKLOG SYN_BACKLOG
	local PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
	local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES

	case "$scene" in
		high|stream|game)
			# 高性能/直播/低延迟：激进参数
			SWAPPINESS=10
			DIRTY_RATIO=15
			DIRTY_BG_RATIO=5
			OVERCOMMIT=1
			VFS_PRESSURE=50
			RMEM_MAX=67108864
			WMEM_MAX=67108864
			TCP_RMEM="4096 262144 67108864"
			TCP_WMEM="4096 262144 67108864"
			SOMAXCONN=8192
			BACKLOG=250000
			SYN_BACKLOG=8192
			PORT_RANGE="1024 65535"
			SCHED_AUTOGROUP=0
			THP="never"
			NUMA=0
			FIN_TIMEOUT=10
			KEEPALIVE_TIME=300
			KEEPALIVE_INTVL=30
			KEEPALIVE_PROBES=5
			;;
		web)
			# 网站服务器：高并发优先
			SWAPPINESS=10
			DIRTY_RATIO=20
			DIRTY_BG_RATIO=10
			OVERCOMMIT=1
			VFS_PRESSURE=50
			RMEM_MAX=33554432
			WMEM_MAX=33554432
			TCP_RMEM="4096 131072 33554432"
			TCP_WMEM="4096 131072 33554432"
			SOMAXCONN=16384
			BACKLOG=10000
			SYN_BACKLOG=16384
			PORT_RANGE="1024 65535"
			SCHED_AUTOGROUP=0
			THP="never"
			NUMA=0
			FIN_TIMEOUT=15
			KEEPALIVE_TIME=600
			KEEPALIVE_INTVL=60
			KEEPALIVE_PROBES=5
			;;
		balanced)
			# 均衡模式：适度优化
			SWAPPINESS=30
			DIRTY_RATIO=20
			DIRTY_BG_RATIO=10
			OVERCOMMIT=0
			VFS_PRESSURE=75
			RMEM_MAX=16777216
			WMEM_MAX=16777216
			TCP_RMEM="4096 87380 16777216"
			TCP_WMEM="4096 65536 16777216"
			SOMAXCONN=4096
			BACKLOG=5000
			SYN_BACKLOG=4096
			PORT_RANGE="1024 49151"
			SCHED_AUTOGROUP=1
			THP="always"
			NUMA=1
			FIN_TIMEOUT=30
			KEEPALIVE_TIME=600
			KEEPALIVE_INTVL=60
			KEEPALIVE_PROBES=5
			;;
	esac

	# ── 根据内存大小自适应调整 ──
	if [ "$MEM_MB" -ge 16384 ]; then
		MIN_FREE_KB=131072
		[ "$scene" != "balanced" ] && SWAPPINESS=5
	elif [ "$MEM_MB" -ge 4096 ]; then
		MIN_FREE_KB=65536
	elif [ "$MEM_MB" -ge 1024 ]; then
		MIN_FREE_KB=32768
		# 小内存缩小缓冲区
		if [ "$scene" != "balanced" ]; then
			RMEM_MAX=16777216
			WMEM_MAX=16777216
			TCP_RMEM="4096 87380 16777216"
			TCP_WMEM="4096 65536 16777216"
		fi
	else
		MIN_FREE_KB=16384
		SWAPPINESS=30
		OVERCOMMIT=0
		RMEM_MAX=4194304
		WMEM_MAX=4194304
		TCP_RMEM="4096 32768 4194304"
		TCP_WMEM="4096 32768 4194304"
		SOMAXCONN=1024
		BACKLOG=1000
	fi

	# ── 直播场景额外：UDP 缓冲区加大 ──
	local STREAM_EXTRA=""
	if [ "$scene" = "stream" ]; then
		STREAM_EXTRA="
# 直播推流 UDP 优化
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384"
	fi

	# ── 低延迟场景额外：低延迟优先 ──
	local GAME_EXTRA=""
	if [ "$scene" = "game" ]; then
		GAME_EXTRA="
# 低延迟优化
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0"
	fi

	# ── 加载 BBR 模块 ──
	local CC="bbr"
	local QDISC="fq"
	local KVER
	KVER=$(uname -r | grep -oP '^\d+\.\d+')
	if printf '%s\n%s' "4.9" "$KVER" | sort -V -C; then
		if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
			modprobe tcp_bbr 2>/dev/null
		fi
		if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
			CC="cubic"
			QDISC="fq_codel"
		fi
	else
		CC="cubic"
		QDISC="fq_codel"
	fi

	# ── 写入配置文件（持久化） ──
	echo -e "${gl_lv}写入优化配置...${gl_bai}"
	cat > "$CONF" << SYSCTL
# kejilion 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ── TCP 拥塞控制 ──
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC

# ── TCP 缓冲区 ──
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

# ── 连接队列 ──
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# ── TCP 连接优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1

# ── 端口与内存 ──
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $((MEM_MB * 1024 / 8)) $((MEM_MB * 1024 / 4)) $((MEM_MB * 1024 / 2))
net.ipv4.tcp_max_orphans = 32768

# ── 虚拟内存 ──
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

# ── CPU/内核调度 ──
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
$([ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa_balancing 不支持")

# ── 安全防护 ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# ── 文件描述符 ──
fs.file-max = 1048576
fs.nr_open = 1048576

# ── 连接跟踪 ──
$(if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))"
echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
else
echo "# conntrack 未启用"
fi)
$STREAM_EXTRA
$GAME_EXTRA
SYSCTL

	# ── 应用配置（逐行，跳过不支持的参数） ──
	echo -e "${gl_lv}应用优化参数...${gl_bai}"
	local applied=0 skipped=0
	while IFS= read -r line; do
		# 跳过注释和空行
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// /}" ]] && continue
		if sysctl -w "$line" >/dev/null 2>&1; then
			applied=$((applied + 1))
		else
			skipped=$((skipped + 1))
		fi
	done < "$CONF"
	echo -e "${gl_lv}已应用 ${applied} 项参数${skipped:+，跳过 ${skipped} 项不支持的参数}${gl_bai}"

	# ── 透明大页面 ──
	if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
		echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
	fi

	# ── 文件描述符限制 ──
	if ! grep -q "# kejilion-optimize" /etc/security/limits.conf 2>/dev/null; then
		cat >> /etc/security/limits.conf << 'LIMITS'

# kejilion-optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
	fi

	# ── BBR 持久化 ──
	if [ "$CC" = "bbr" ]; then
		echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
		# 清理旧的 sysctl.conf 里的 bbr 配置（避免冲突）
		sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
	fi

	echo -e "${gl_lv}${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
	echo -e "${gl_lv}内存: ${MEM_MB}MB | 拥塞算法: ${CC} | 队列: ${QDISC}${gl_bai}"
}

optimize_high_performance() {
	_kernel_optimize_core "${tiaoyou_moshi:-高性能优化模式}" "high"
}

optimize_balanced() {
	_kernel_optimize_core "均衡优化模式" "balanced"
}

optimize_web_server() {
	_kernel_optimize_core "网站搭建优化模式" "web"
}

restore_defaults() {
	echo -e "${gl_lv}还原到默认设置...${gl_bai}"

	local CONF="/etc/sysctl.d/99-kejilion-optimize.conf"

	# 删除优化配置文件（含外链自动调优配置）
	rm -f "$CONF"
	rm -f /etc/sysctl.d/99-network-optimize.conf

	# 清理 sysctl.conf 里可能残留的 bbr 配置
	sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null

	# 重新加载系统默认配置
	sysctl --system 2>/dev/null | tail -1

	# 还原透明大页面
	[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && \
		echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null

	# 清理文件描述符配置
	if grep -q "# kejilion-optimize" /etc/security/limits.conf 2>/dev/null; then
		sed -i '/# kejilion-optimize/,+4d' /etc/security/limits.conf
	fi

	# 清理 BBR 持久化
	rm -f /etc/modules-load.d/bbr.conf 2>/dev/null

	echo -e "${gl_lv}系统已还原到默认设置${gl_bai}"
}

Kernel_optimize() {
	root_use
	while true; do
	  clear
	  send_stats "Linux内核调优管理"
	  local current_mode=$(grep "^# 模式:" /etc/sysctl.d/99-kejilion-optimize.conf 2>/dev/null | sed 's/# 模式: //' | awk -F'|' '{print $1}' | xargs)
	  [ -z "$current_mode" ] && [ -f /etc/sysctl.d/99-network-optimize.conf ] && current_mode="自动调优模式"
	  echo "Linux系统内核参数优化"
	  if [ -n "$current_mode" ]; then
		  echo -e "当前模式: ${gl_lv}${current_mode}${gl_bai}"
	  else
		  echo -e "当前模式: ${gl_hui}未优化${gl_bai}"
	  fi
	  echo "视频介绍: https://www.bilibili.com/video/BV1Kb421J7yg?t=0.1"
	  echo "------------------------------------------------"
	  echo "提供多种系统参数调优模式，用户可以根据自身使用场景进行选择切换。"
	  echo -e "${gl_huang}提示: ${gl_bai}生产环境请谨慎使用！"
	  echo -e "--------------------"
	  echo -e "1. 高性能优化模式：     最大化系统性能，激进的内存和网络参数。"
	  echo -e "2. 均衡优化模式：       在性能与资源消耗之间取得平衡，适合日常使用。"
	  echo -e "3. 网站优化模式：       针对网站服务器优化，超高并发连接队列。"
	  echo -e "4. 直播优化模式：       针对直播推流优化，UDP 缓冲区加大，减少延迟。"
	  echo -e "5. 低延迟优化模式：     针对低延迟服务优化。"
	  echo -e "6. 还原默认设置：       将系统设置还原为默认配置。"
	  echo -e "7. 自动调优：           根据测试数据自动调优内核参数。"
	  echo "--------------------"
	  echo "0. 返回上一级选单"
	  echo "--------------------"
	  read -e -p "请输入你的选择: " sub_choice || return 1
	  case $sub_choice in
		  1)
			  cd ~
			  clear
			  local tiaoyou_moshi="高性能优化模式"
			  optimize_high_performance
			  send_stats "高性能模式优化"
			  ;;
		  2)
			  cd ~
			  clear
			  optimize_balanced
			  send_stats "均衡模式优化"
			  ;;
		  3)
			  cd ~
			  clear
			  optimize_web_server
			  send_stats "网站优化模式"
			  ;;
		  4)
			  cd ~
			  clear
			  _kernel_optimize_core "直播优化模式" "stream"
			  send_stats "直播推流优化"
			  ;;
		  5)
			  cd ~
			  clear
			  _kernel_optimize_core "低延迟优化模式" "game"
			  send_stats "低延迟优化"
			  ;;
		  6)
			  cd ~
			  clear
			  restore_defaults
			  daimon_download "${gh_proxy}raw.githubusercontent.com/kejilion/sh/refs/heads/main/network-optimize.sh" "network-optimize.sh" && source "$DAIMON_SCRIPT_DIR/network-optimize.sh" && restore_network_defaults
			  send_stats "还原默认设置"
			  ;;

		  7)
			  cd ~
			  clear
			  daimon_run_cached_script "${gh_proxy}raw.githubusercontent.com/kejilion/sh/refs/heads/main/network-optimize.sh" "network-optimize.sh"
			  send_stats "内核自动调优"
			  ;;

		  *)
			  break
			  ;;
	  esac
	  break_end
	done
}

shell_bianse_profile() {

if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
	sed -i '/^PS1=/d' ~/.bashrc
	echo "${bianse}" >> ~/.bashrc
	source ~/.bashrc >/dev/null 2>&1 || true
else
	sed -i '/^PS1=/d' ~/.profile
	echo "${bianse}" >> ~/.profile
	source ~/.profile >/dev/null 2>&1 || true
fi
echo -e "${gl_lv}变更完成，已尝试重新加载 shell 配置；重新连接 SSH 后完全生效。${gl_bai}"

hash -r
break_end

}

shell_bianse() {
  root_use
  send_stats "命令行美化工具"
  while true; do
	clear
	echo "命令行美化工具"
	echo "------------------------"
	echo -e "1. \033[1;32mroot \033[1;34mlocalhost \033[1;31m~ \033[0m${gl_bai}#"
	echo -e "2. \033[1;35mroot \033[1;36mlocalhost \033[1;33m~ \033[0m${gl_bai}#"
	echo -e "3. \033[1;31mroot \033[1;32mlocalhost \033[1;34m~ \033[0m${gl_bai}#"
	echo -e "4. \033[1;36mroot \033[1;33mlocalhost \033[1;37m~ \033[0m${gl_bai}#"
	echo -e "5. \033[1;37mroot \033[1;31mlocalhost \033[1;32m~ \033[0m${gl_bai}#"
	echo -e "6. \033[1;33mroot \033[1;34mlocalhost \033[1;35m~ \033[0m${gl_bai}#"
	echo -e "7. root localhost ~ #"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "输入你的选择: " choice || return 1

	case $choice in
	  1)
		local bianse="PS1='\[\033[1;32m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\] \[\033[1;31m\]\w\[\033[0m\] # '"
		shell_bianse_profile

		;;
	  2)
		local bianse="PS1='\[\033[1;35m\]\u\[\033[0m\]@\[\033[1;36m\]\h\[\033[0m\] \[\033[1;33m\]\w\[\033[0m\] # '"
		shell_bianse_profile
		;;
	  3)
		local bianse="PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;32m\]\h\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\] # '"
		shell_bianse_profile
		;;
	  4)
		local bianse="PS1='\[\033[1;36m\]\u\[\033[0m\]@\[\033[1;33m\]\h\[\033[0m\] \[\033[1;37m\]\w\[\033[0m\] # '"
		shell_bianse_profile
		;;
	  5)
		local bianse="PS1='\[\033[1;37m\]\u\[\033[0m\]@\[\033[1;31m\]\h\[\033[0m\] \[\033[1;32m\]\w\[\033[0m\] # '"
		shell_bianse_profile
		;;
	  6)
		local bianse="PS1='\[\033[1;33m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\] \[\033[1;35m\]\w\[\033[0m\] # '"
		shell_bianse_profile
		;;
	  7)
		local bianse=""
		shell_bianse_profile
		;;
	  *)
		break
		;;
	esac

  done
}

linux_trash() {
  root_use
  send_stats "系统回收站"

  local bashrc_profile="/root/.bashrc"
  local TRASH_DIR="$HOME/.local/share/Trash/files"

  while true; do

	local trash_status
	if ! grep -q "trash-put" "$bashrc_profile"; then
		trash_status="${gl_hui}未启用${gl_bai}"
	else
		trash_status="${gl_lv}已启用${gl_bai}"
	fi

	clear
	echo -e "当前回收站 ${trash_status}"
	echo -e "启用后rm删除的文件先进入回收站，防止误删重要文件！"
	echo "------------------------------------------------"
	ls -l --color=auto "$TRASH_DIR" 2>/dev/null || echo "回收站为空"
	echo "------------------------"
	echo "1. 启用回收站          2. 关闭回收站"
	echo "3. 还原内容            4. 清空回收站"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "输入你的选择: " choice || return 1

	case $choice in
	  1)
		install trash-cli
		sed -i '/alias rm/d' "$bashrc_profile"
		echo "alias rm='trash-put'" >> "$bashrc_profile"
		source "$bashrc_profile"
		echo "回收站已启用，删除的文件将移至回收站。"
		sleep 2
		;;
	  2)
		remove trash-cli
		sed -i '/alias rm/d' "$bashrc_profile"
		echo "alias rm='rm -i'" >> "$bashrc_profile"
		source "$bashrc_profile"
		echo "回收站已关闭，文件将直接删除。"
		sleep 2
		;;
	  3)
		read -e -p "输入要还原的文件名: " file_to_restore || return 1
		if [ -e "$TRASH_DIR/$file_to_restore" ]; then
		  mv "$TRASH_DIR/$file_to_restore" "$HOME/"
		  echo "$file_to_restore 已还原到主目录。"
		else
		  echo "文件不存在。"
		fi
		;;
	  4)
		read -e -p "确认清空回收站？[y/n]: " confirm || return 1
		if [[ "$confirm" == "y" ]]; then
		  trash-empty
		  echo "回收站已清空。"
		fi
		;;
	  *)
		break
		;;
	esac
  done
}

linux_fav() {
send_stats "命令收藏夹"
		daimon_run_cached_script "${gh_proxy}raw.githubusercontent.com/byJoey/cmdbox/refs/heads/main/install.sh" "cmdbox-install.sh"
}

create_backup() {
	send_stats "创建备份"
	local TIMESTAMP=$(date +"%Y%m%d%H%M%S")

	# 提示用户输入备份目录
	echo "创建备份示例："
	echo "  - 备份单个目录: /var/www"
	echo "  - 备份多个目录: /etc /home /var/log"
	echo "  - 直接回车将使用默认目录 (/etc /usr /home)"
	read -e -p "请输入要备份的目录（多个目录用空格分隔，直接回车则使用默认目录）：" input || return 1

	# 如果用户没有输入目录，则使用默认目录
	if [ -z "$input" ]; then
		BACKUP_PATHS=(
			"/etc"              # 配置文件和软件包配置
			"/usr"              # 已安装的软件文件
			"/home"             # 用户数据
		)
	else
		# 将用户输入的目录按空格分隔成数组
		IFS=' ' read -r -a BACKUP_PATHS <<< "$input"
	fi

	# 生成备份文件前缀
	local PREFIX=""
	for path in "${BACKUP_PATHS[@]}"; do
		# 提取目录名称并去除斜杠
		dir_name=$(basename "$path")
		PREFIX+="${dir_name}_"
	done

	# 去除最后一个下划线
	local PREFIX=${PREFIX%_}

	# 生成备份文件名
	local BACKUP_NAME="${PREFIX}_$TIMESTAMP.tar.gz"

	# 打印用户选择的目录
	echo "您选择的备份目录为："
	for path in "${BACKUP_PATHS[@]}"; do
		echo "- $path"
	done

	# 创建备份
	echo "正在创建备份 $BACKUP_NAME..."
	install tar
	tar -czvf "$BACKUP_DIR/$BACKUP_NAME" "${BACKUP_PATHS[@]}"

	# 检查命令是否成功
	if [ $? -eq 0 ]; then
		echo "备份创建成功: $BACKUP_DIR/$BACKUP_NAME"
	else
		echo "备份创建失败！"
		exit 1
	fi
}

daimon_backup_extract_safe() {
	python3 - "$1" "$2" <<'PY'
import fcntl, os, shutil, stat, sys, tarfile
from contextlib import ExitStack

def require(condition, message):
    if not condition:
        raise ValueError(message)

def directory(path, stack):
    require(path.startswith('/') and '\\' not in path, 'Destination must be an absolute directory')
    parts = path.split('/')[1:]
    require(all(part not in ('.', '..') for part in parts), 'Unsafe directory path')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    stack.callback(os.close, fd)
    for part in filter(None, parts):
        fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        stack.callback(os.close, fd)
    info = os.fstat(fd)
    require(info.st_uid == os.geteuid() and not info.st_mode & 0o022, 'Destination ownership or permissions are unsafe')
    return fd

try:
    with ExitStack() as stack:
        destination = directory(sys.argv[2], stack)
        fcntl.flock(destination, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(not os.listdir(destination), 'Destination must be empty')
        source = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        stream = stack.enter_context(os.fdopen(source, 'rb'))
        original = os.fstat(source)
        require(stat.S_ISREG(original.st_mode) and original.st_uid == os.geteuid() and
                original.st_nlink == 1 and not original.st_mode & 0o022, 'Unsafe archive file')
        archive = stack.enter_context(tarfile.open(fileobj=stream, mode='r:gz'))
        entries = {}
        for member in archive:
            name = member.name
            require(not name.startswith('/') and '\\' not in name and
                    not any(ord(char) < 32 or ord(char) == 127 for char in name), 'Unsafe archive path')
            parts = name.split('/')
            require('..' not in parts, 'Archive path traversal refused')
            parts = tuple(part for part in parts if part not in ('', '.'))
            require(member.isdir() or (member.isfile() and not member.sparse), 'Only regular files and directories are supported')
            if not parts:
                require(member.isdir(), 'Invalid archive root entry')
                continue
            require(parts not in entries, 'Duplicate archive path')
            entries[parts] = member
        require(entries, 'Archive is empty')
        for parts in entries:
            for depth in range(1, len(parts)):
                parent = entries.get(parts[:depth])
                require(parent is None or parent.isdir(), 'Archive file/directory conflict')
        space = os.fstatvfs(destination)
        require(sum(member.size for member in entries.values()) <= space.f_bavail * space.f_frsize,
                'Insufficient free space')
        require(not os.listdir(destination), 'Destination changed during validation')
        directories = {(): destination}
        for parts, member in sorted(entries.items()):
            count = len(parts) if member.isdir() else len(parts) - 1
            for depth in range(1, count + 1):
                key = parts[:depth]
                if key not in directories:
                    parent = directories[key[:-1]]
                    os.mkdir(key[-1], mode=0o700, dir_fd=parent)
                    fd = os.open(key[-1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    stack.callback(os.close, fd)
                    directories[key] = fd
            if member.isfile():
                fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directories[parts[:-1]])
                with os.fdopen(fd, 'wb') as output, archive.extractfile(member) as data:
                    shutil.copyfileobj(data, output)
                    output.flush()
                    require(output.tell() == member.size, 'Incomplete archive member')
                    os.fchmod(output.fileno(), member.mode & 0o777)
        current = os.fstat(source)
        require((original.st_size, original.st_mtime_ns, original.st_ctime_ns) ==
                (current.st_size, current.st_mtime_ns, current.st_ctime_ns), 'Archive changed during extraction')
        for parts, fd in sorted(directories.items(), reverse=True):
            if parts:
                member = entries.get(parts)
                os.fchmod(fd, member.mode & 0o777 if member else 0o755)
except (OSError, ValueError, tarfile.TarError, EOFError) as error:
    print('ERROR: Restore failed; any partial output remains only in the selected directory: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

restore_backup() {
	local name archive destination confirm
	send_stats "恢复备份"
	command -v python3 >/dev/null 2>&1 || { echo "需要 python3，未恢复任何文件。"; return 1; }
	read -r -e -p "请输入要恢复的备份文件名: " name || return 1
	archive=$(daimon_backup_delete_target "$name") || { echo "备份不存在或路径、类型、归属不安全。"; return 1; }
	read -r -e -p "请输入已存在的空目录绝对路径（不覆盖原位置）: " destination || return 1
	printf '将仅向 %s 恢复普通文件和目录；不恢复链接、设备、属主或特殊权限。\n' "$destination"
	read -r -e -p "确认恢复？(y/N): " confirm || return 1
	[[ "$confirm" = y || "$confirm" = Y ]] || { echo "已取消"; return 0; }
	daimon_backup_extract_safe "$archive" "$destination" || return 1
	echo "备份已恢复到指定目录；未覆盖系统原位置。"
}

list_backups() {
	echo "可用的备份："
	ls -1 "$BACKUP_DIR"
}

daimon_backup_delete_target() {
	local name="$1" root target mode
	[[ "$name" = *.tar.gz && "$name" != */* && "$name" != *\\* && "$name" != -* && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || return 1
	[ -d "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ] && [ -O "$BACKUP_DIR" ] || return 1
	root=$(realpath -e -- "$BACKUP_DIR") || return 1
	mode=$(stat -c %a -- "$root") || return 1
	(( (8#${mode} & 022) == 0 )) || return 1
	target="$root/$name"
	[ -f "$target" ] && [ ! -L "$target" ] && [ -O "$target" ] &&
		[ "$(stat -c %h -- "$target")" = 1 ] || return 1
	printf '%s\n' "$target"
}

delete_backup() {
	local name target checked identity confirm
	send_stats "删除备份"
	read -r -e -p "请输入要删除的备份文件名: " name || return 1
	target=$(daimon_backup_delete_target "$name") || { echo "备份不存在或路径、类型、归属不安全，未删除。"; return 1; }
	identity=$(stat -c '%d:%i:%s:%Y:%Z' -- "$target") || return 1
	read -r -e -p "确认永久删除 $target？(y/N): " confirm || return 1
	[[ "$confirm" = y || "$confirm" = Y ]] || { echo "已取消"; return 0; }
	checked=$(daimon_backup_delete_target "$name") || return 1
	[ "$checked" = "$target" ] && [ "$(stat -c '%d:%i:%s:%Y:%Z' -- "$target")" = "$identity" ] || {
		echo "备份在确认期间发生变化，未删除。"; return 1
	}
	rm -- "$target" && [ ! -e "$target" ] && [ ! -L "$target" ] || { echo "备份删除失败！"; return 1; }
	echo "备份删除成功！"
}

linux_backup() {
	BACKUP_DIR="/backups"
	mkdir -p "$BACKUP_DIR"
	while true; do
		clear
		send_stats "系统备份功能"
		echo "系统备份功能"
		echo "------------------------"
		list_backups
		echo "------------------------"
		echo "1. 创建备份        2. 恢复备份        3. 删除备份"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case $choice in
			1) create_backup ;;
			2) restore_backup ;;
			3) delete_backup ;;
			*) break ;;
		esac
		read -e -p "按回车键继续..."
	done
}

kj_ssh_parse_remote() {
	local remote_raw="$1"
	local default_user="${2:-root}"
	local remote_user remote_host

	if [[ "$remote_raw" == *@* ]]; then
		remote_user="${remote_raw%@*}"
		remote_host="${remote_raw#*@}"
	else
		remote_user="$default_user"
		remote_host="$remote_raw"
	fi

	if ! kj_ssh_validate_user "$remote_user"; then
		echo "错误: SSH 用户名格式不正确。"
		return 1
	fi

	if ! kj_ssh_validate_host "$remote_host"; then
		echo "错误: SSH 主机地址格式不正确。"
		return 1
	fi

	KJ_SSH_USER="$remote_user"
	KJ_SSH_HOST="$remote_host"
	KJ_SSH_REMOTE="$remote_user@$remote_host"
}

kj_ssh_read_auth() {
	local key_file="$1"
	local password_or_key=""

	echo "请选择身份验证方式:"
	echo "1. 密码"
	echo "2. 密钥"
	read -e -p "请输入选择 (1/2): " auth_choice || return 1

	case $auth_choice in
		1)
			read -s -p "请输入密码: " password_or_key || return 1
			echo
			if [ -z "$password_or_key" ]; then
				echo "错误: 密码不能为空。"
				return 1
			fi
			KJ_SSH_AUTH_METHOD="password"
			KJ_SSH_AUTH_SECRET="$password_or_key"
			;;
		2)
			echo "请粘贴密钥内容 (粘贴完成后按两次回车)："
			while IFS= read -r line; do
				if [[ -z "$line" && "$password_or_key" == *"-----BEGIN"* ]]; then
					break
				fi
				if [[ -n "$line" || "$password_or_key" == *"-----BEGIN"* ]]; then
					password_or_key+="${line}"$'\n'
				fi
			done

			if [[ "$password_or_key" != *"-----BEGIN"* || "$password_or_key" != *"PRIVATE KEY-----"* ]]; then
				echo "无效的密钥内容！"
				return 1
			fi

			mkdir -p "$(dirname "$key_file")"
			echo -n "$password_or_key" > "$key_file"
			chmod 600 "$key_file"
			KJ_SSH_AUTH_METHOD="key"
			KJ_SSH_AUTH_SECRET="$key_file"
			;;
		*)
			echo "无效的选择！"
			return 1
			;;
	esac
}

kj_ssh_read_password() {
	local prompt="${1:-请输入密码: }"
	while true; do
		read -e -s -p "$prompt" KJ_SSH_PASSWORD || return 1
		echo
		[ -n "$KJ_SSH_PASSWORD" ] && break
		echo "错误: 密码不能为空。"
	done
}

kj_ssh_read_port() {
	local port_prompt="$1"
	local default_port="${2:-22}"
	while true; do
		read -e -p "$port_prompt" KJ_SSH_PORT || return 1
		KJ_SSH_PORT=${KJ_SSH_PORT:-$default_port}
		if kj_ssh_validate_port "$KJ_SSH_PORT"; then
			return 0
		fi
		echo "错误: 端口必须是 1-65535 之间的数字。"
	done
}

list_connections() {
	echo "已保存的连接:"
	echo "------------------------"
	cat "$CONFIG_FILE" | awk -F'|' '{print NR " - " $1 " (" $2 ")"}'
	echo "------------------------"
}

add_connection() {
	send_stats "添加新连接"
	echo "创建新连接示例："
	echo "  - 连接名称: my_server"
	echo "  - IP地址: 192.168.1.100"
	echo "  - 用户名: root"
	echo "  - 端口: 22"
	echo "------------------------"
	read -e -p "请输入连接名称: " name || return 1

	kj_ssh_read_host_user_port "请输入IP地址: " "请输入用户名 (默认: root): " "请输入端口号 (默认: 22): " "root" "22"
	if ! kj_ssh_read_auth "$KEY_DIR/$name.key"; then
		return
	fi

	echo "$name|$KJ_SSH_HOST|$KJ_SSH_USER|$KJ_SSH_PORT|$KJ_SSH_AUTH_SECRET" >> "$CONFIG_FILE"
	echo "连接已保存!"
}

delete_connection() {
	send_stats "删除连接"
	read -e -p "请输入要删除的连接编号: " num || return 1

	local connection=$(sed -n "${num}p" "$CONFIG_FILE")
	if [[ -z "$connection" ]]; then
		echo "错误：未找到对应的连接。"
		return
	fi

	IFS='|' read -r name ip user port password_or_key <<< "$connection"

	# 如果连接使用的是密钥文件，则删除该密钥文件
	if [[ "$password_or_key" == "$KEY_DIR"* ]]; then
		rm -f "$password_or_key"
	fi

	sed -i "${num}d" "$CONFIG_FILE"
	echo "连接已删除!"
}

use_connection() {
	send_stats "使用连接"
	read -e -p "请输入要使用的连接编号: " num || return 1

	local connection=$(sed -n "${num}p" "$CONFIG_FILE")
	if [[ -z "$connection" ]]; then
		echo "错误：未找到对应的连接。"
		return
	fi

	IFS='|' read -r name ip user port password_or_key <<< "$connection"

	echo "正在连接到 $name ($ip)..."
	if [[ -f "$password_or_key" ]]; then
		# 使用密钥连接
		ssh -o StrictHostKeyChecking=no -i "$password_or_key" -p "$port" "$user@$ip"
		if [[ $? -ne 0 ]]; then
			echo "连接失败！请检查以下内容："
			echo "1. 密钥文件路径是否正确：$password_or_key"
			echo "2. 密钥文件权限是否正确（应为 600）。"
			echo "3. 目标服务器是否允许使用密钥登录。"
		fi
	else
		# 使用密码连接
		if ! command -v sshpass &> /dev/null; then
			echo "错误：未安装 sshpass，请先安装 sshpass。"
			echo "安装方法："
			echo "  - Ubuntu/Debian: apt install sshpass"
			echo "  - CentOS/RHEL: yum install sshpass"
			return
		fi
		sshpass -p "$password_or_key" ssh -o StrictHostKeyChecking=no -p "$port" "$user@$ip"
		if [[ $? -ne 0 ]]; then
			echo "连接失败！请检查以下内容："
			echo "1. 用户名和密码是否正确。"
			echo "2. 目标服务器是否允许密码登录。"
			echo "3. 目标服务器的 SSH 服务是否正常运行。"
		fi
	fi
}

list_partitions() {
	echo "可用的硬盘分区："
	lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "sr\|loop"
}

mount_partition() {
	send_stats "挂载分区"
	read -e -p "请输入要挂载的分区名称（例如 sda1）: " PARTITION || return 1

	DEVICE="/dev/$PARTITION"
	MOUNT_POINT="/mnt/$PARTITION"

	# 检查分区是否存在
	if ! lsblk -no NAME | grep -qw "$PARTITION"; then
		echo "分区不存在！"
		return 1
	fi

	# 检查是否已挂载
	if mount | grep -qw "$DEVICE"; then
		echo "分区已经挂载！"
		return 1
	fi

	# 获取 UUID
	UUID=$(blkid -s UUID -o value "$DEVICE")
	if [ -z "$UUID" ]; then
		echo "无法获取 UUID！"
		return 1
	fi

	# 获取文件系统类型
	FSTYPE=$(blkid -s TYPE -o value "$DEVICE")
	if [ -z "$FSTYPE" ]; then
		echo "无法获取文件系统类型！"
		return 1
	fi

	# 创建挂载点
	mkdir -p "$MOUNT_POINT"

	# 挂载
	if ! mount "$DEVICE" "$MOUNT_POINT"; then
		echo "分区挂载失败！"
		rmdir "$MOUNT_POINT"
		return 1
	fi

	echo "分区已成功挂载到 $MOUNT_POINT"

	# 检查 /etc/fstab 是否已经存在 UUID 或挂载点
	if awk -v uuid="UUID=$UUID" -v point="$MOUNT_POINT" '$1 == uuid || $2 == point {found=1} END {exit !found}' /etc/fstab; then
		echo "/etc/fstab 中已存在该分区记录，跳过写入"
		return 0
	fi

	# 写入 /etc/fstab
	echo "UUID=$UUID $MOUNT_POINT $FSTYPE defaults,nofail 0 2" >> /etc/fstab

	echo "已写入 /etc/fstab，实现持久化挂载"
}

unmount_partition() {
	send_stats "卸载分区"
	read -e -p "请输入要卸载的分区名称（例如 sda1）: " PARTITION || return 1
	[[ "$PARTITION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
	local MOUNT_POINT
	MOUNT_POINT=$(findmnt -rn -S "/dev/$PARTITION" -o TARGET)
	if [ -z "$MOUNT_POINT" ]; then
		echo "分区未挂载！"
		return
	fi

	# 卸载分区
	umount "/dev/$PARTITION"

	if [ $? -eq 0 ]; then
		echo "分区卸载成功: $MOUNT_POINT"
	else
		echo "分区卸载失败！"
		return 1
	fi
}

list_mounted_partitions() {
	echo "已挂载的分区："
	df -h | grep -v "tmpfs\|udev\|overlay"
}

disk_partition_unmounted() {
	local partition="$1" mounts
	[[ "$partition" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -b "/dev/$partition" ] || {
		echo "分区名称无效或设备不存在！" >&2; return 1
	}
	mounts=$(lsblk -nr -o MOUNTPOINT -- "/dev/$partition") || {
		echo "无法确认分区挂载状态，已取消操作。" >&2; return 1
	}
	if [[ "$mounts" =~ [^[:space:]] ]]; then
		echo "分区或其子设备正在使用，请先卸载！" >&2
		return 1
	fi
}

format_partition() {
	local PARTITION FS_CHOICE FS_TYPE CONFIRM
	send_stats "格式化分区"
	read -e -p "请输入要格式化的分区名称（例如 sda1）: " PARTITION || return 1
	disk_partition_unmounted "$PARTITION" || return 1

	# 选择文件系统类型
	echo "请选择文件系统类型："
	echo "1. ext4"
	echo "2. xfs"
	echo "3. ntfs"
	echo "4. vfat"
	read -e -p "请输入你的选择: " FS_CHOICE || return 1

	case $FS_CHOICE in
		1) FS_TYPE="ext4" ;;
		2) FS_TYPE="xfs" ;;
		3) FS_TYPE="ntfs" ;;
		4) FS_TYPE="vfat" ;;
		*) echo "无效的选择！"; return 1 ;;
	esac

	# 确认格式化
	read -e -p "确认格式化分区 /dev/$PARTITION 为 $FS_TYPE 吗？(y/n): " CONFIRM || return 1
	if [ "$CONFIRM" != "y" ]; then
		echo "操作已取消。"
		return
	fi

	# 格式化分区
	disk_partition_unmounted "$PARTITION" || return 1
	echo "正在格式化分区 /dev/$PARTITION 为 $FS_TYPE ..."
	if "mkfs.$FS_TYPE" "/dev/$PARTITION"; then
		echo "分区格式化成功！"
	else
		echo "分区格式化失败！"
		return 1
	fi
}

check_partition() {
	local PARTITION
	send_stats "检查分区状态"
	read -e -p "请输入要检查的分区名称（例如 sda1）: " PARTITION || return 1
	disk_partition_unmounted "$PARTITION" || return 1

	# 检查分区状态
	echo "检查分区 /dev/$PARTITION 的状态："
	fsck -n "/dev/$PARTITION"
}

disk_manager() {
	send_stats "硬盘管理功能"
	while true; do
		clear
		echo "硬盘分区管理"
		echo -e "${gl_huang}该功能内部测试阶段，请勿在生产环境使用。${gl_bai}"
		echo "------------------------"
		list_partitions
		echo "------------------------"
		echo "1. 挂载分区        2. 卸载分区        3. 查看已挂载分区"
		echo "4. 格式化分区      5. 检查分区状态"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case $choice in
			1) mount_partition ;;
			2) unmount_partition ;;
			3) list_mounted_partitions ;;
			4) format_partition ;;
			5) check_partition ;;
			*) break ;;
		esac
		read -e -p "按回车键继续..."
	done
}

rsync_task_get() {
	[[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "任务编号无效" >&2; return 1; }
	awk -v number="$1" 'NR == number {print; found=1; exit} END {exit !found}' "${CONFIG_FILE:-$HOME/.rsync_tasks}"
}

rsync_cron_filter() {
	awk -v action="$1" -v number="${2:-0}" '
		/^[[:space:]]*#/ {if (action != "query" && action != "list") print; next}
		{
			cmd = ($1 ~ /^@/ ? 2 : 6)
			owned = ($cmd ~ /^(k|d|\/usr\/(local\/)?bin\/(k|d))$/ && $(cmd+1) == "rsync_run" && $(cmd+2) ~ /^[1-9][0-9]*$/)
			match_number = owned && $(cmd+2) == number
			if (action == "query") {if (match_number) found=1; next}
			if (action == "list") {if (owned) print; next}
			if (match_number) next
			if (action == "reindex" && owned && $(cmd+2) > number) $(cmd+2)--
			print
		}
		END {if (action == "query") exit !found}'
}

list_tasks() {
	echo "已保存的同步任务:"
	echo "---------------------------------"
	awk -F'|' '{print NR " - " $1 " ( " $2 " -> " $3":"$4 " )"}' "$CONFIG_FILE"
	echo "---------------------------------"
}

add_task() {
	local name local_path remote_path remote port mode options auth_method password_or_key path
	local CONFIG_FILE="${CONFIG_FILE:-$HOME/.rsync_tasks}"
	local KEY_DIR="$HOME/.ssh/rsync_manager_keys"
	send_stats "添加新同步任务"
	echo "创建新同步任务示例："
	echo "  - 任务名称: backup_www"
	echo "  - 本地目录: /var/www"
	echo "  - 远程地址: user@192.168.1.100"
	echo "  - 远程目录: /backup/www"
	echo "  - 端口号 (默认 22)"
	echo "---------------------------------"
	read -r -e -p "请输入任务名称: " name || return 1
	validate_config_name "$name" || { echo "任务名称无效"; return 1; }
	[ ! -L "$CONFIG_FILE" ] || return 1
	if [ -f "$CONFIG_FILE" ] && awk -F'|' -v name="$name" '$1 == name {found=1} END {exit !found}' "$CONFIG_FILE"; then
		echo "任务名称已存在"; return 1
	fi
	read -r -e -p "请输入本地目录: " local_path || return 1
	read -r -e -p "请输入远程目录: " remote_path || return 1
	for path in "$local_path" "$remote_path"; do
		[[ "$path" = /* && "$path" != *'|'* && "$path" != *$'\r'* ]] || { echo "请输入不含分隔符的绝对路径"; return 1; }
	done

	while true; do
		read -e -p "请输入远程用户@IP: " remote || return 1
		if kj_ssh_parse_remote "$remote" "root"; then
			remote="$KJ_SSH_REMOTE"
			break
		fi
	done

	kj_ssh_read_port "请输入 SSH 端口 (默认 22): " "22" || return 1
	port="$KJ_SSH_PORT"

	[ ! -e "$KEY_DIR/${name}_sync.key" ] && [ ! -L "$KEY_DIR/${name}_sync.key" ] || return 1
	[ ! -L "$KEY_DIR" ] || return 1
	mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR" || return 1
	if ! kj_ssh_read_auth "$KEY_DIR/${name}_sync.key"; then
		return 1
	fi
	auth_method="$KJ_SSH_AUTH_METHOD"
	password_or_key="$KJ_SSH_AUTH_SECRET"
	[[ "$password_or_key" != *'|'* && "$password_or_key" != *$'\n'* && "$password_or_key" != *$'\r'* ]] || return 1

	echo "请选择同步模式:"
	echo "1. 标准模式 (-avz)"
	echo "2. 删除目标文件 (-avz --delete)"
	read -e -p "请选择 (1/2): " mode || return 1
	case $mode in
		1) options="-avz" ;;
		2) options="-avz --delete" ;;
		*) echo "无效选择，使用默认 -avz"; options="-avz" ;;
	esac

	install rsync || return 1
	[ "$auth_method" != password ] || install sshpass || return 1
	(umask 077; printf '%s\n' "$name|$local_path|$remote|$remote_path|$port|$options|$auth_method|$password_or_key" >> "$CONFIG_FILE") || return 1
	chmod 600 "$CONFIG_FILE" || return 1

	echo "任务已保存!"
}

delete_task() {
	local num task current next staged key_dir real_key
	local name local_path remote remote_path port options auth_method password_or_key
	send_stats "删除同步任务"
	read -e -p "请输入要删除的任务编号: " num || return 1

	if ! task=$(rsync_task_get "$num"); then
		echo "错误：未找到对应的任务。"
		return 1
	fi
	[ ! -L "$CONFIG_FILE" ] || return 1
	current=$(rsync_cron_read) || return 1
	next=$(printf '%s\n' "$current" | rsync_cron_filter reindex "$num") || return 1
	staged=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
	if ! sed "${num}d" "$CONFIG_FILE" > "$staged" || ! printf '%s\n' "$next" | crontab -; then
		rm -f -- "$staged"; return 1
	fi
	if ! mv -f -- "$staged" "$CONFIG_FILE"; then
		printf '%s\n' "$current" | crontab - || echo "定时任务回滚失败，请手动检查" >&2
		rm -f -- "$staged"; return 1
	fi

	IFS='|' read -r name local_path remote remote_path port options auth_method password_or_key <<< "$task"

	# 如果任务使用的是密钥文件，则删除该密钥文件
	if [[ "$auth_method" == key && ! -L "$password_or_key" ]] && validate_config_name "$name"; then
		real_key=$(realpath -m -- "$password_or_key") || return 1
		for key_dir in "$HOME/.ssh/rsync_manager_keys" "$HOME/.ssh/ssh_manager_keys"; do
			[ ! -L "$key_dir" ] || continue
			if [ "$real_key" = "$(realpath -m -- "$key_dir")/${name}_sync.key" ] &&
				! awk -F'|' -v key="$password_or_key" '$8 == key {found=1} END {exit !found}' "$CONFIG_FILE"; then
				rm -f -- "$real_key" || return 1
			fi
		done
	fi

	echo "任务已删除!"
}

run_task() {
	local name local_path remote remote_path port options auth_method password_or_key source destination task rc
	local -a rsync_options
	send_stats "执行同步任务"

	CONFIG_FILE="$HOME/.rsync_tasks"
	CRON_FILE="$HOME/.rsync_cron"

	# 解析参数
	local direction="push"  # 默认是推送到远端
	local num

	if [[ "$1" == "push" || "$1" == "pull" ]]; then
		direction="$1"
		num="$2"
	else
		num="$1"
	fi

	# 如果没有传入任务编号，提示用户输入
	if [[ -z "$num" ]]; then
		read -e -p "请输入要执行的任务编号: " num || return 1
	fi

	if ! task=$(rsync_task_get "$num"); then
		echo "错误: 未找到该任务!"
		return 1
	fi

	IFS='|' read -r name local_path remote remote_path port options auth_method password_or_key <<< "$task"
	validate_tcp_port "$port" || return 1
	[ -n "$local_path" ] && [ -n "$remote_path" ] && [ -n "$remote" ] || return 1
	case "$options" in '-avz'|'-avz --delete') ;; *) echo "同步选项无效"; return 1 ;; esac
	read -r -a rsync_options <<< "$options"

	# 根据同步方向调整源和目标路径
	if [[ "$direction" == "pull" ]]; then
		echo "正在拉取同步到本地: $remote:$remote_path -> $local_path"
		source="$remote:$remote_path"
		destination="$local_path"
	else
		echo "正在推送同步到远端: $local_path -> $remote:$remote_path"
		source="$local_path"
		destination="$remote:$remote_path"
	fi

	# 添加 SSH 连接通用参数
	local ssh_options="-p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

	if [[ "$auth_method" == "password" ]]; then
		if ! command -v sshpass &> /dev/null; then
			echo "错误：未安装 sshpass，请先安装 sshpass。"
			echo "安装方法："
			echo "  - Ubuntu/Debian: apt install sshpass"
			echo "  - CentOS/RHEL: yum install sshpass"
			return 1
		fi
		SSHPASS="$password_or_key" sshpass -e rsync "${rsync_options[@]}" -e "ssh $ssh_options" -- "$source" "$destination"
		rc=$?
	elif [ "$auth_method" = key ]; then
		# 检查密钥文件是否存在和权限是否正确
		if [[ ! -f "$password_or_key" ]]; then
			echo "错误：密钥文件不存在：$password_or_key"
			return 1
		fi

		if [[ "$(stat -c %a "$password_or_key")" != "600" ]]; then
			echo "警告：密钥文件权限不正确，正在修复..."
			chmod 600 "$password_or_key" || return 1
		fi

		rsync "${rsync_options[@]}" -e "ssh -i \"${password_or_key//\"/\"\"}\" $ssh_options" -- "$source" "$destination"
		rc=$?
	else
		echo "身份验证方式无效"; return 1
	fi

	if [ "$rc" -eq 0 ]; then
		echo "同步完成!"
	else
		echo "同步失败! 请检查以下内容："
		echo "1. 网络连接是否正常"
		echo "2. 远程主机是否可访问"
		echo "3. 认证信息是否正确"
		echo "4. 本地和远程目录是否有正确的访问权限"
	fi
	return "$rc"
}

schedule_task() {
	local num interval random_minute cron_time cron_job current
	send_stats "添加同步定时任务"

	read -e -p "请输入要定时同步的任务编号: " num || return 1
	if ! rsync_task_get "$num" >/dev/null; then
		echo "错误: 请输入有效的任务编号！"
		return 1
	fi

	echo "请选择定时执行间隔："
	echo "1) 每小时执行一次"
	echo "2) 每天执行一次"
	echo "3) 每周执行一次"
	read -e -p "请输入选项 (1/2/3): " interval || return 1

	local random_minute=$(shuf -i 0-59 -n 1)  # 生成 0-59 之间的随机分钟数
	local cron_time=""
	case "$interval" in
		1) cron_time="$random_minute * * * *" ;;  # 每小时，随机分钟执行
		2) cron_time="$random_minute 0 * * *" ;;  # 每天，随机分钟执行
		3) cron_time="$random_minute 0 * * 1" ;;  # 每周，随机分钟执行
		*) echo "错误: 请输入有效的选项！" ; return ;;
	esac

	cron_job="$cron_time /usr/local/bin/d rsync_run $num"
	current=$(rsync_cron_read) || return 1

	# 检查是否已存在相同任务
	if printf '%s\n' "$current" | rsync_cron_filter query "$num"; then
		echo "错误: 该任务的定时同步已存在！"
		return 1
	fi

	# 创建到用户的 crontab
	printf '%s\n' "$current" "$cron_job" | crontab - || return 1
	echo "定时任务已创建: $cron_job"
}

view_tasks() {
	echo "当前的定时任务:"
	echo "---------------------------------"
	local current
	current=$(rsync_cron_read) || return 1
	printf '%s\n' "$current" | rsync_cron_filter list
	echo "---------------------------------"
}

delete_task_schedule() {
	local num current next
	send_stats "删除同步定时任务"
	read -e -p "请输入要删除的任务编号: " num || return 1
	if ! [[ "$num" =~ ^[1-9][0-9]*$ ]]; then
		echo "错误: 请输入有效的任务编号！"
		return 1
	fi

	current=$(rsync_cron_read) || return 1
	next=$(printf '%s\n' "$current" | rsync_cron_filter delete "$num") || return 1
	printf '%s\n' "$next" | crontab - || return 1
	echo "已删除任务编号 $num 的定时任务"
}

rsync_manager() {
	CONFIG_FILE="$HOME/.rsync_tasks"
	CRON_FILE="$HOME/.rsync_cron"

	while true; do
		clear
		echo "Rsync 远程同步工具"
		echo "远程目录之间同步，支持增量同步，高效稳定。"
		echo "---------------------------------"
		list_tasks
		echo
		view_tasks
		echo
		echo "1. 创建新任务                 2. 删除任务"
		echo "3. 执行本地同步到远端         4. 执行远端同步到本地"
		echo "5. 创建定时任务               6. 删除定时任务"
		echo "---------------------------------"
		echo "0. 返回上一级选单"
		echo "---------------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case $choice in
			1) add_task ;;
			2) delete_task ;;
			3) run_task push;;
			4) run_task pull;;
			5) schedule_task ;;
			6) delete_task_schedule ;;
			0) break ;;
			*) echo "无效的选择，请重试。" ;;
		esac
		read -e -p "按回车键继续..."
	done
}

daimon_network_verify_sysctl_file() {
	local file="$1" line key expected actual failed=0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		key=${line%%=*}
		expected=${line#*=}
		key=$(printf '%s' "$key" | xargs)
		expected=$(printf '%s' "$expected" | xargs)
		actual=$(sysctl -n "$key" 2>/dev/null | xargs)
		if [ "$actual" != "$expected" ]; then
			echo -e "${gl_hong}参数验证失败: $key，期望 $expected，实际 ${actual:-不可用}${gl_bai}"
			failed=1
		fi
	done < "$file"
	[ "$failed" -eq 0 ]
}

daimon_network_show_conflicting_sysctl_configs() {
	local managed_file="$1" line key expected key_pattern match source rest line_number definition other found=0
	[ -f "$managed_file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		key=${line%%=*}
		expected=${line#*=}
		key=$(printf '%s' "$key" | xargs)
		expected=$(printf '%s' "$expected" | xargs)
		key_pattern=${key//./\\.}
		while IFS= read -r match; do
			source=${match%%:*}
			[ "$source" = "$managed_file" ] && continue
			rest=${match#*:}
			line_number=${rest%%:*}
			definition=${rest#*:}
			other=${definition#*=}
			other=$(printf '%s' "$other" | xargs)
			[ "$other" = "$expected" ] && continue
			if [ "$found" -eq 0 ]; then
				echo -e "${gl_huang}检测到其他 sysctl 配置定义了不同值：${gl_bai}"
			fi
			printf '  %s:%s: %s=%s（本模块=%s）\n' "$source" "$line_number" "$key" "$other" "$expected"
			found=1
		done < <(grep -HnE "^[[:space:]]*${key_pattern}[[:space:]]*=" \
			/etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null || true)
	done < "$managed_file"
	[ "$found" -eq 0 ] || echo -e "${gl_huang}原配置已保留；应用优化时 daimon 的末尾覆盖块和 zz-daimon-network.conf 负责重载/开机优先级。${gl_bai}"
}

daimon_network_cleanup_old_qdisc_service() {
	if command -v systemctl >/dev/null 2>&1; then
		command systemctl disable --now daimon-network-optimize.service >/dev/null 2>&1 || true
	fi
	rm -f /etc/systemd/system/daimon-network-optimize.service /usr/local/bin/daimon-network-optimize-apply.sh
	rm -f /etc/sysctl.d/99-network-restore-before-daimon.conf
	command -v systemctl >/dev/null 2>&1 && command systemctl daemon-reload >/dev/null 2>&1 || true
}

daimon_network_apply_custom_optimize() {
	root_use
	local tmp snapshot key value actual file unsupported=0 rollback_failed=0
	local DAIMON_NETWORK_DEFER_PERSIST=1
	daimon_network_bbr_supported || { echo "当前内核不支持 BBR，未修改配置。"; return 2; }
	daimon_network_verify_active_fq || return 1
	snapshot=$(mktemp -d) || return 1
	tmp="$snapshot/new.conf"
	for file in "$DAIMON_BBR_FQ_CONF" "$DAIMON_NETWORK_OPTIMIZE_CONF"; do
		if [ -e "$file" ]; then
			cp -a "$file" "$snapshot/$(basename "$file")" || { rm -rf "$snapshot"; return 1; }
		fi
	done
	for key in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
		actual=$(sysctl -n "$key") || { rm -rf "$snapshot"; return 1; }
		printf '%s=%s\n' "$key" "$actual" >> "$snapshot/runtime.conf"
	done
	cat > "$tmp" <<'EOF'
# linux-tools-daimon custom network optimization
EOF
	while IFS='|' read -r key value; do
		[ -n "$key" ] || continue
		if actual=$(sysctl -n "$key" 2>/dev/null); then
			printf '%s=%s\n' "$key" "$value" >> "$tmp"
			printf '%s=%s\n' "$key" "$actual" >> "$snapshot/runtime.conf"
		else
			echo -e "${gl_huang}跳过当前内核不支持的参数: $key${gl_bai}"
			unsupported=$((unsupported + 1))
		fi
	done <<'EOF'
net.core.rmem_max|134217728
net.core.wmem_max|134217728
net.core.netdev_max_backlog|300000
net.ipv4.tcp_rmem|4096 131072 134217728
net.ipv4.tcp_wmem|4096 131072 134217728
fs.file-max|2097152
net.ipv4.tcp_tw_reuse|1
net.ipv4.tcp_fastopen|3
net.ipv4.tcp_window_scaling|1
net.ipv4.tcp_max_syn_backlog|262144
net.core.somaxconn|65535
net.ipv4.ip_local_port_range|1024 65535
vm.swappiness|10
net.ipv4.tcp_slow_start_after_idle|0
net.ipv4.tcp_limit_output_bytes|4194304
net.ipv4.tcp_mtu_probing|1
EOF
	if ! daimon_network_enable_bbr_fq ||
		! command install -m 644 "$tmp" "$DAIMON_NETWORK_OPTIMIZE_CONF" ||
		! sysctl -p "$DAIMON_NETWORK_OPTIMIZE_CONF" >/dev/null ||
		! daimon_network_verify_sysctl_file "$DAIMON_NETWORK_OPTIMIZE_CONF" ||
		! daimon_network_verify_bbr_fq ||
		! daimon_network_persist "$DAIMON_BBR_FQ_CONF" "$DAIMON_NETWORK_OPTIMIZE_CONF"; then
		for file in "$DAIMON_BBR_FQ_CONF" "$DAIMON_NETWORK_OPTIMIZE_CONF"; do
			if [ -f "$snapshot/$(basename "$file")" ]; then
				cp -a "$snapshot/$(basename "$file")" "$file" || rollback_failed=1
			else
				rm -f "$file" || rollback_failed=1
			fi
		done
		sysctl -p "$snapshot/runtime.conf" >/dev/null || rollback_failed=1
		daimon_network_verify_sysctl_file "$snapshot/runtime.conf" || rollback_failed=1
		if [ "$rollback_failed" -eq 0 ]; then
			rm -rf "$snapshot"
			echo -e "${gl_hong}网络优化失败，原配置和运行态参数已恢复。${gl_bai}"
		else
			echo -e "${gl_hong}网络优化失败且回滚不完整，快照保留在: $snapshot${gl_bai}"
		fi
		return 1
	fi
	rm -rf "$snapshot"
	rm -f "$DAIMON_NETWORK_LEGACY_CONF"
	echo -e "${gl_lv}自定义网络优化已应用，重载与开机覆盖配置已同步。参数文件: $DAIMON_NETWORK_OPTIMIZE_CONF${gl_bai}"
	[ "$unsupported" -gt 0 ] && echo -e "${gl_huang}已自适应跳过 $unsupported 个不受支持的参数。${gl_bai}"
	daimon_network_show_conflicting_sysctl_configs "$DAIMON_NETWORK_OPTIMIZE_CONF"
	send_stats "自定义网络优化"
}

daimon_network_show_custom_status() {
	local key
	echo "内核版本: $(uname -r)"
	if daimon_network_bbr_supported; then
		echo -e "BBR 内核支持: ${gl_lv}支持${gl_bai}"
	else
		echo -e "BBR 内核支持: ${gl_hong}不支持${gl_bai}"
	fi
	echo "sysctl 配置："
	for key in \
		net.core.default_qdisc \
		net.ipv4.tcp_congestion_control \
		net.core.rmem_max \
		net.core.wmem_max \
		net.core.netdev_max_backlog \
		net.ipv4.tcp_rmem \
		net.ipv4.tcp_wmem \
		fs.file-max \
		net.ipv4.tcp_tw_reuse \
		net.ipv4.tcp_fastopen \
		net.ipv4.tcp_window_scaling \
		net.ipv4.tcp_max_syn_backlog \
		net.core.somaxconn \
		net.ipv4.ip_local_port_range \
		vm.swappiness \
		net.ipv4.tcp_slow_start_after_idle \
		net.ipv4.tcp_limit_output_bytes \
		net.ipv4.tcp_mtu_probing
	do
		printf "  %-38s %s\n" "$key" "$(sysctl -n "$key" 2>/dev/null || echo 未支持)"
	done
	echo "实际网卡队列："
	tc qdisc show 2>/dev/null || echo "  无法读取（需要 tc）"
	echo "------------------------------------------------"
	echo "BBR 模块信息："
	modinfo tcp_bbr 2>/dev/null | grep -E '^(filename|version|description):' || echo "  未检测到 tcp_bbr 模块信息"
	echo "------------------------------------------------"
	if [ -f "$DAIMON_BBR_FQ_CONF" ]; then
		echo -e "BBR/FQ 配置: ${gl_lv}已安装${gl_bai} ($DAIMON_BBR_FQ_CONF)"
	else
		echo -e "BBR/FQ 配置: ${gl_hui}未由 daimon 管理${gl_bai}"
	fi
	if [ -f "$DAIMON_NETWORK_OPTIMIZE_CONF" ]; then
		echo -e "自定义优化配置: ${gl_lv}已安装${gl_bai} ($DAIMON_NETWORK_OPTIMIZE_CONF)"
	else
		echo -e "自定义优化配置: ${gl_hui}未安装${gl_bai}"
	fi
	daimon_network_show_other_bbr_configs
	daimon_network_show_conflicting_sysctl_configs "$DAIMON_NETWORK_OPTIMIZE_CONF"
}

daimon_network_clear_custom_optimize() {
	root_use
	daimon_network_persist "$DAIMON_BBR_FQ_CONF" || return 1
	daimon_network_cleanup_old_qdisc_service
	if ! rm -f "$DAIMON_NETWORK_OPTIMIZE_CONF" "$DAIMON_NETWORK_LEGACY_CONF"; then
		daimon_network_persist "$DAIMON_BBR_FQ_CONF" "$DAIMON_NETWORK_OPTIMIZE_CONF"
		return 1
	fi
	sysctl --system >/dev/null 2>&1 || { echo "优化配置已清除，但系统参数重载失败，请检查 sysctl 配置。"; return 1; }
	echo "已清除自定义网络优化配置，BBR/FQ 保持不变；其他运行态参数可能需要重启后恢复系统默认值。"
	send_stats "清除自定义网络优化"
}

cpcat_manager() {
	while true; do
		clear
		local bashrc_file="$HOME/.bashrc"
		local cpcat_status="${gl_hong}未配置${gl_bai}"
		if [ -f "$bashrc_file" ] && grep -q '^# ========== cpcat clipboard setup ==========$' "$bashrc_file"; then
			cpcat_status="${gl_lv}已配置${gl_bai}"
		fi
		echo "配置/删除cpcat"
		echo "------------------------------------------------"
		echo -e "当前状态: $cpcat_status"
		echo "功能说明: cpcat 文件路径，可通过 OSC 52 快速复制文件内容到剪贴板"
		echo "示例: cpcat /root/test.txt"
		echo "------------------------------------------------"
		echo "1. 配置 cpcat 到 ~/.bashrc"
		echo "2. 删除 ~/.bashrc 中的 cpcat 配置"
		echo "0. 返回上一级菜单"
		echo "------------------------------------------------"
		read -e -p "请输入你的选择: " cpcat_choice || return 1
		case "$cpcat_choice" in
			1)
				local tmp_file
				touch "$bashrc_file"
				tmp_file=$(mktemp)
				awk '/^# ========== cpcat clipboard setup ==========$/ {skip=1; next} /^[[:space:]]*# ========== end cpcat clipboard setup ==========$/ {skip=0; next} !skip {print}' "$bashrc_file" > "$tmp_file"
				cat "$tmp_file" > "$bashrc_file"
				rm -f "$tmp_file"
				cat >> "$bashrc_file" <<'EOF'

# ========== cpcat clipboard setup ==========
# 一键复制文件内容到剪贴板
cpcat() {
    if [ -f "$1" ]; then
        printf "\033]52;c;$(base64 < "$1" | tr -d '\n')\a"
        echo "✅ 已复制到剪贴板: $1"
    else
        echo "❌ 文件不存在: $1"
    fi
}
# ========== end cpcat clipboard setup ==========
EOF
				source "$bashrc_file" >/dev/null 2>&1 || true
				echo "已配置 cpcat。已执行 source ~/.bashrc。"
				;;
			2)
				[ -f "$bashrc_file" ] || { echo "~/.bashrc 不存在"; break_end; continue; }
				local tmp_file
				tmp_file=$(mktemp)
				awk '/^# ========== cpcat clipboard setup ==========$/ {skip=1; next} /^[[:space:]]*# ========== end cpcat clipboard setup ==========$/ {skip=0; next} !skip {print}' "$bashrc_file" > "$tmp_file"
				cat "$tmp_file" > "$bashrc_file"
				rm -f "$tmp_file"
				source "$bashrc_file" >/dev/null 2>&1 || true
				echo "已删除 cpcat 配置。"
				;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

ldnmp_tato() {
local cert_count=$(ls /home/web/certs/*_cert.pem 2>/dev/null | wc -l)
local output="${gl_lv}${cert_count}${gl_bai}"

local dbrootpasswd=$(grep -oP 'MYSQL_ROOT_PASSWORD:\s*\K.*' /home/web/docker-compose.yml 2>/dev/null | tr -d '[:space:]')
if [ -n "$dbrootpasswd" ]; then
	local db_count=$(docker exec mysql mysql -u root -p"$dbrootpasswd" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "Database|information_schema|mysql|performance_schema|sys" | wc -l)
fi

local db_output="${gl_lv}${db_count}${gl_bai}"


if command -v docker &>/dev/null; then
	if docker ps --filter "name=nginx" --filter "status=running" | grep -q nginx; then
		echo -e "${gl_huang}------------------------"
		echo -e "${gl_lv}环境已安装${gl_bai}  站点: $output  数据库: $db_output"
	fi
fi

}

fix_phpfpm_conf() {
	local container_name=$1
	docker exec "$container_name" sh -c "mkdir -p /run/$container_name && chmod 777 /run/$container_name"
	docker exec "$container_name" sh -c "sed -i '1i [global]\\ndaemonize = no' /usr/local/etc/php-fpm.d/www.conf"
	docker exec "$container_name" sh -c "sed -i '/^listen =/d' /usr/local/etc/php-fpm.d/www.conf"
	docker exec "$container_name" sh -c "echo -e '\nlisten = /run/$container_name/php-fpm.sock\nlisten.owner = www-data\nlisten.group = www-data\nlisten.mode = 0777' >> /usr/local/etc/php-fpm.d/www.conf"
	docker exec "$container_name" sh -c "rm -f /usr/local/etc/php-fpm.d/zz-docker.conf"

	find /home/web/conf.d/ -type f -name "*.conf" -exec sed -i "s#fastcgi_pass ${container_name}:9000;#fastcgi_pass unix:/run/${container_name}/php-fpm.sock;#g" {} \;

}

linux_ldnmp() {
	clear
	echo "LDNMP建站模块已从 linux-tools-daimon 个人版移除。"
	break_end
}
