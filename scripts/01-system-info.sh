#!/bin/bash

output_status() {
	output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
		$1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
			rx_total += $2
			tx_total += $10
		}
		END {
			rx_units = "Bytes";
			tx_units = "Bytes";
			if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
			if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
			if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }

			if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
			if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
			if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }

			printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
		}' /proc/net/dev)

	rx=$(echo "$output" | awk '{print $1}')
	tx=$(echo "$output" | awk '{print $2}')

}

service_status_text() {
	local service_name="$1"
	shift || true
	local unit state found=false
	if command -v systemctl >/dev/null 2>&1; then
		for unit in "$service_name" "$service_name.service" "$@"; do
			[ -z "$unit" ] && continue
			state=$(command systemctl is-active "$unit" 2>/dev/null | head -n 1)
			if [ "$state" = "active" ]; then
				echo "运行中"
				return
			fi
			if command systemctl status "$unit" 2>/dev/null | grep -q 'Active: active'; then
				echo "运行中"
				return
			fi
			if command systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q . || command systemctl status "$unit" >/dev/null 2>&1; then
				found=true
			fi
		done
		if [ "$found" = "true" ]; then
			echo "未运行"
		else
			echo "未检测到服务"
		fi
		return
	fi
	echo "无法检测"
}

sshd_effective_value() {
	local key="$1"
	local value="" sshd_bin config
	sshd_bin=$(sshd_bin_path)
	if [ -n "$sshd_bin" ] && config=$("$sshd_bin" -T 2>/dev/null); then
		value=$(printf '%s\n' "$config" | awk -v k="$key" '$1==k {print $2; exit}')
	fi
	normalize_ssh_bool "$value"
}

sshd_bin_path() {
	local bin
	bin=$(command -v sshd 2>/dev/null || true)
	if [ -n "$bin" ]; then
		echo "$bin"
	elif [ -x /usr/sbin/sshd ]; then
		echo "/usr/sbin/sshd"
	fi
}

normalize_ssh_bool() {
	local value
	value=$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')
	case "$value" in
		yes|true|on) echo "yes" ;;
		no|false|off) echo "no" ;;
		*) echo "$1" ;;
	esac
}

system_info_ssh() {
	local service ports listening_ports password_auth kbd_auth pubkey_auth password_login sshd_bin config
	service=$(service_status_text ssh sshd ssh.service sshd.service)
	listening_ports=$(ss -ltnp 2>/dev/null | awk '/sshd/ {p=$4; sub(/.*:/,"",p); if (p ~ /^[0-9]+$/) print p}' | sort -nu | xargs 2>/dev/null)
	if [ -n "$listening_ports" ]; then
		service="运行中"
		ports="$listening_ports"
	fi
	sshd_bin=$(sshd_bin_path)
	if [ -z "$ports" ] && [ -n "$sshd_bin" ] && config=$("$sshd_bin" -T 2>/dev/null); then
		ports=$(printf '%s\n' "$config" | awk '$1=="port"{print $2}' | xargs)
	fi
	[ -z "$ports" ] && ports="未知"
	password_auth=$(sshd_effective_value passwordauthentication)
	kbd_auth=$(sshd_effective_value kbdinteractiveauthentication)
	[ -z "$kbd_auth" ] && kbd_auth=$(sshd_effective_value challengeresponseauthentication)
	pubkey_auth=$(sshd_effective_value pubkeyauthentication)
	if [ "$password_auth" = "yes" ] || [ "$kbd_auth" = "yes" ]; then
		password_login="yes"
	elif [ "$password_auth" = "no" ] && [ "$kbd_auth" = "no" ]; then
		password_login="no"
	else
		password_login="未知"
	fi
	[ -z "$pubkey_auth" ] && pubkey_auth="未知"
	echo "服务: $service | 端口: $ports | 密码登录: $password_login | 密钥登录: $pubkey_auth（认证项为全局配置，未评估 Match）"
}

system_info_ufw() {
	local status
	if ! command -v ufw >/dev/null 2>&1; then
		echo "未安装"
		return
	fi
	status=$(ufw status 2>/dev/null | head -n 1 | sed 's/^Status: /状态: /')
	[ -z "$status" ] && status="已安装，状态无法读取"
	echo "$status"
}

system_info_docker() {
	local version daemon_status containers images service
	if ! command -v docker >/dev/null 2>&1; then
		echo "未安装"
		return
	fi
	version=$(docker --version 2>/dev/null | sed 's/,.*//')
	if docker info >/dev/null 2>&1; then
		daemon_status="运行中"
		containers=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
		images=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
		echo "${version:-Docker 已安装} | Daemon: $daemon_status | 运行容器: ${containers:-0} | 镜像: ${images:-0}"
	else
		service=$(service_status_text docker)
		echo "${version:-Docker 已安装} | Daemon: 不可用 | systemd: $service"
	fi
}

system_info_nginx() {
	local info service docker_nginx
	info=""
	if command -v nginx >/dev/null 2>&1; then
		info=$(nginx -v 2>&1 | sed 's#nginx version: ##')
		service=$(service_status_text nginx)
		info="${info:-Nginx 已安装} | 服务: $service"
	fi
	if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
		docker_nginx="Docker容器: nginx 运行中"
	fi
	if [ -n "$info" ] && [ -n "$docker_nginx" ]; then
		echo "$info | $docker_nginx"
	elif [ -n "$info" ]; then
		echo "$info"
	elif [ -n "$docker_nginx" ]; then
		echo "$docker_nginx"
	else
		echo "未安装/未检测到 nginx 容器"
	fi
}

system_info_fail2ban() {
	local service status
	if ! command -v fail2ban-client >/dev/null 2>&1 && [ ! -d /etc/fail2ban ]; then
		echo "未安装"
		return
	fi
	if fail2ban-client status >/dev/null 2>&1; then
		service="运行中"
	else
		service=$(service_status_text fail2ban)
	fi
	status=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/^[ \t]+/,"",$2); print $2}')
	[ -z "$status" ] && status="无 jail 或无法读取"
	echo "服务: $service | Jail: $status"
}

system_info_rclone() {
	if ! command -v rclone >/dev/null 2>&1; then
		echo "未安装"
		return
	fi
	rclone version 2>/dev/null | head -n 1
}

system_info_bitwarden() {
	local result="" names config_status config_path
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		names=$(docker ps -a --format '{{.Names}}:{{.Status}}' 2>/dev/null | grep -Ei '(vaultwarden|bitwarden)' | xargs)
		[ -n "$names" ] && result="$names"
	fi
	config_path="/var/lib/docker/volumes/vaultwarden-rclone-data/_data/rclone/rclone.conf"
	if grep -q '^\[BitwardenBackup\]' "$config_path" 2>/dev/null; then
		config_status="备份rclone配置: 已配置"
	elif [ -f "$config_path" ]; then
		config_status="备份rclone配置: 文件存在但缺少 [BitwardenBackup]"
	else
		config_status="备份rclone配置: 未配置"
	fi
	if [ -n "$result" ]; then
		echo "$result | $config_status"
	else
		echo "未检测到 vaultwarden/bitwarden 相关容器 | $config_status"
	fi
}

system_info_language() {
	local lang
	lang=$(locale 2>/dev/null | awk -F= '$1=="LANG"{print $2; exit}' | tr -d '"')
	[ -z "$lang" ] && lang="${LANG:-未知}"
	echo "$lang"
}

linux_info() {



	clear
	echo -e "${gl_kjlan}正在查询系统信息……${gl_bai}"

	ip_address

	local cpu_info=$(LC_ALL=C lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}')

	local cpu_usage_percent=$(awk '{t=0; for (i=2;i<=9;i++) t+=$i; idle=$5+$6; if (NR==1){t1=t; idle1=idle;} else {dt=t-t1; busy=dt-(idle-idle1); printf "%.0f\n", (dt>0 && busy>=0 && busy<=dt ? busy*100/dt : 0)}}' \
		<(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

	local cpu_cores=$(nproc)

	local cpu_freq=$(cat /proc/cpuinfo | grep "MHz" | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')
	[ -z "$cpu_freq" ] && cpu_freq="未知"

	local mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')

	local disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')

	local ipinfo country city isp_info
	local -a location=()
	ipinfo=$(curl -fsS --connect-timeout 3 --max-time 5 https://ipinfo.io/json 2>/dev/null) || ipinfo=""
	if [ -n "$ipinfo" ]; then
		if command -v jq >/dev/null 2>&1; then
			mapfile -t location < <(printf '%s' "$ipinfo" | jq -r '[.country, .city, .org][] | if type == "string" then gsub("[[:cntrl:]]"; " ") else "" end' 2>/dev/null)
		elif command -v python3 >/dev/null 2>&1; then
			mapfile -t location < <(printf '%s' "$ipinfo" | python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
    for key in ("country", "city", "org"):
        value = data.get(key)
        print("".join(c if c.isprintable() else " " for c in value) if isinstance(value, str) else "")
except (ValueError, AttributeError):
    pass' 2>/dev/null)
		fi
	fi
	country="${location[0]:-未知}"
	city="${location[1]:-未知}"
	isp_info="${location[2]:-未知}"

	local load=$(LC_ALL=C uptime | awk '{print $(NF-2), $(NF-1), $NF}')
	local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)


	local cpu_arch=$(uname -m)

	local hostname=$(uname -n)

	local kernel_version=$(uname -r)

	local congestion_algorithm queue_algorithm
	congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || congestion_algorithm="未知"
	queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null) || queue_algorithm="未知"

	local os_info=$(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')

	output_status

	local current_time=$(date "+%Y-%m-%d %I:%M %p")


	local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')

	local runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')

	local timezone=$(current_timezone)
	local language_info=$(system_info_language)
	local ssh_info=$(system_info_ssh)
	local ufw_info=$(system_info_ufw)
	local docker_info=$(system_info_docker)
	local nginx_info=$(system_info_nginx)
	local fail2ban_info=$(system_info_fail2ban)
	local rclone_info=$(system_info_rclone)
	local bitwarden_info=$(system_info_bitwarden)

	local tcp_count="未知" udp_count="未知" sockets
	if sockets=$(ss -H -t 2>/dev/null); then
		tcp_count=$(printf '%s\n' "$sockets" | awk 'NF {n++} END {print n+0}')
	fi
	if sockets=$(ss -H -u 2>/dev/null); then
		udp_count=$(printf '%s\n' "$sockets" | awk 'NF {n++} END {print n+0}')
	fi

	clear
	echo -e "系统信息查询"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}主机名:         ${gl_bai}$hostname"
	echo -e "${gl_kjlan}系统版本:       ${gl_bai}$os_info"
	echo -e "${gl_kjlan}Linux版本:      ${gl_bai}$kernel_version"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}CPU架构:        ${gl_bai}$cpu_arch"
	echo -e "${gl_kjlan}CPU型号:        ${gl_bai}$cpu_info"
	echo -e "${gl_kjlan}CPU核心数:      ${gl_bai}$cpu_cores"
	echo -e "${gl_kjlan}CPU频率:        ${gl_bai}$cpu_freq"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}CPU占用:        ${gl_bai}$cpu_usage_percent%"
	echo -e "${gl_kjlan}系统负载:       ${gl_bai}$load"
	echo -e "${gl_kjlan}TCP|UDP连接数:  ${gl_bai}$tcp_count|$udp_count"
	echo -e "${gl_kjlan}物理内存:       ${gl_bai}$mem_info"
	echo -e "${gl_kjlan}虚拟内存:       ${gl_bai}$swap_info"
	echo -e "${gl_kjlan}硬盘占用:       ${gl_bai}$disk_info"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}总接收:         ${gl_bai}$rx"
	echo -e "${gl_kjlan}总发送:         ${gl_bai}$tx"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}网络算法:       ${gl_bai}$congestion_algorithm $queue_algorithm"
	echo -e "${gl_kjlan}-------------"
	printf '%b%s\n' "${gl_kjlan}运营商:         ${gl_bai}" "$isp_info"
	if [ -n "$ipv4_address" ]; then
		echo -e "${gl_kjlan}IPv4地址:       ${gl_bai}$ipv4_address"
	fi

	if [ -n "$ipv6_address" ]; then
		echo -e "${gl_kjlan}IPv6地址:       ${gl_bai}$ipv6_address"
	else
		echo -e "${gl_kjlan}IPv6地址:       ${gl_bai}无"
	fi
	echo -e "${gl_kjlan}DNS地址:        ${gl_bai}$dns_addresses"
	printf '%b%s\n' "${gl_kjlan}地理位置:       ${gl_bai}" "$country $city"
	echo -e "${gl_kjlan}系统时间:       ${gl_bai}$timezone $current_time"
	echo -e "${gl_kjlan}本地语言:       ${gl_bai}$language_info"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}SSH信息:        ${gl_bai}$ssh_info"
	echo -e "${gl_kjlan}UFW状态:        ${gl_bai}$ufw_info"
	echo -e "${gl_kjlan}Docker:         ${gl_bai}$docker_info"
	echo -e "${gl_kjlan}Nginx:          ${gl_bai}$nginx_info"
	echo -e "${gl_kjlan}Fail2ban:       ${gl_bai}$fail2ban_info"
	echo -e "${gl_kjlan}rclone:         ${gl_bai}$rclone_info"
	echo -e "${gl_kjlan}Bitwarden:      ${gl_bai}$bitwarden_info"
	echo -e "${gl_kjlan}-------------"
	echo -e "${gl_kjlan}运行时长:       ${gl_bai}$runtime"
	echo



}
