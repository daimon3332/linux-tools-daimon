#!/bin/bash

daimon_tcp_key_path() {
	printf '/proc/sys/%s\n' "${1//./\/}"
}

daimon_tcp_key_supported() {
	[ -e "$(daimon_tcp_key_path "$1")" ]
}

daimon_tcp_read_key() {
	tr -s '[:space:]' ' ' < "$(daimon_tcp_key_path "$1")" 2>/dev/null | sed 's/^ //; s/ $//'
}

daimon_tcp_write_key() {
	local path
	path=$(daimon_tcp_key_path "$1")
	[ -e "$path" ] || return 1
	printf '%s' "$2" > "$path" 2>/dev/null
}

daimon_tcp_ram_mb() {
	awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo
}

daimon_tcp_detect_role() {
	if pgrep -x sing-box >/dev/null 2>&1 || pgrep -x xray >/dev/null 2>&1 ||
		pgrep -x v2ray >/dev/null 2>&1 || pgrep -x hysteria >/dev/null 2>&1 ||
		pgrep -x mihomo >/dev/null 2>&1 || pgrep -x clash >/dev/null 2>&1; then
		echo proxy
	elif pgrep -x nginx >/dev/null 2>&1 || pgrep -x apache2 >/dev/null 2>&1 ||
		pgrep -x caddy >/dev/null 2>&1; then
		echo web
	else
		echo mixed
	fi
}

daimon_tcp_median() {
	sort -n | awk '{v[NR]=$1} END {if (NR==0) exit 1; if (NR%2) printf "%.1f\n", v[(NR+1)/2]; else printf "%.1f\n", (v[NR/2]+v[NR/2+1])/2}'
}

daimon_tcp_record_family() {
	local family="$1" bw="$2" rtt="$3" retr="$4" tmp
	[ -n "$bw" ] || return 0
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	tmp=$(mktemp) || return 1
	if [ -f "$DAIMON_TCP_FAMILY_RECORD" ]; then
		grep -v "^${family}=" "$DAIMON_TCP_FAMILY_RECORD" > "$tmp" 2>/dev/null || : > "$tmp"
	else
		: > "$tmp"
	fi
	printf '%s=%s %s %s %s %s %s %s\n' "$family" "$bw" "${rtt:-0}" "${retr:-0}" "$(date +%s)" "${5:--}" "${6:--}" "${7:--}" >> "$tmp"
	mv -f "$tmp" "$DAIMON_TCP_FAMILY_RECORD" 2>/dev/null || rm -f "$tmp"
}

daimon_tcp_family_speed_block() {
	[ -s "$DAIMON_TCP_FAMILY_RECORD" ] || return 0
	local f line when v4="" v6="" session4="" session6="" profile4="" profile6="" client4="" client6="" stamp4=0 stamp6=0 now
	echo "线路速度记录（最近一次实测）:"
	for f in 4 6; do
		line=$(sed -n "s/^$f=//p" "$DAIMON_TCP_FAMILY_RECORD" | tail -n 1)
		[ -n "$line" ] || continue
		set -- $line
		when=$(date -d "@${4:-0}" '+%m-%d %H:%M' 2>/dev/null || echo "-")
		[ "$f" = 4 ] && v4="$1" || v6="$1"
		if [ "$f" = 4 ]; then
			session4="${5:--}"; profile4="${6:--}"; client4="${7:--}"
			stamp4="${4:-0}"
		else
			session6="${5:--}"; profile6="${6:--}"; client6="${7:--}"
			stamp6="${4:-0}"
		fi
		printf '  IPv%s: %s Mbps（RTT %s ms，重传 %s，%s）\n' "$f" "$1" "${2:-?}" "${3:-?}" "$when"
	done
	if [ -n "$v4" ] && [ -n "$v6" ]; then
		now=$(date +%s)
		if [ "$((now - stamp4))" -gt 86400 ] || [ "$((now - stamp6))" -gt 86400 ]; then
			echo "  → 历史记录已超过一天，建议重新同时测速，不据此推荐节点协议。"
			return 0
		fi
		if [ "$session4" = - ] || [ "$session4" != "$session6" ] || [ "$profile4" != "$profile6" ] || [ "$client4" != "$client6" ]; then
			echo "  → 两条历史记录不是同一会话/配置，不据此推荐协议；使用 3 → 3 同时补测。"
			return 0
		fi
		if awk -v a="$v4" -v b="$v6" 'BEGIN{exit !(a > b * 1.10)}'; then
			echo -e "  → ${gl_lv}IPv4 更快${gl_bai}（$v4 vs $v6 Mbps），节点优先用 IPv4"
		elif awk -v a="$v6" -v b="$v4" 'BEGIN{exit !(a > b * 1.10)}'; then
			echo -e "  → ${gl_lv}IPv6 更快${gl_bai}（$v6 vs $v4 Mbps），节点优先用 IPv6"
		else
			echo "  → IPv4 与 IPv6 接近（$v4 vs $v6 Mbps），按客户端支持情况选择"
		fi
	elif [ -n "$v4" ]; then
		echo "  → 还没有 IPv6 记录，可用 1 → iperf3 → 2（只测 IPv6）或 3（两个都测）"
	else
		echo "  → 还没有 IPv4 记录，可用 1 → iperf3 → 1（只测 IPv4）或 3（两个都测）"
	fi
}

daimon_tcp_prune_logs() {
	local file
	for file in $(ls -1t "$DAIMON_TCP_STATE_DIR"/iperf3-*.log "$DAIMON_TCP_STATE_DIR"/tcpquality-*.log 2>/dev/null | tail -n +11); do
		rm -f "$file"
	done
}

daimon_tcp_restore() {
	root_use
	if [ ! -s "$DAIMON_TCP_SNAPSHOT" ]; then
		echo "没有找到调优前快照，本机可能没有执行过动态调优，未做任何修改。"
		echo "如只是想去掉历史遗留的 daimon 网络覆盖，可直接删除 /etc/sysctl.d/99-daimon-network-optimize.conf 后执行 sysctl --system。"
		return 0
	fi
	local tmp key value failed=0
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	local lock_fd
	exec {lock_fd}>"$DAIMON_TCP_STATE_DIR/session.lock" || return 1
	if ! flock -n "$lock_fd"; then
		echo "已有测速或恢复操作进行中，未修改参数。"
		exec {lock_fd}>&-
		return 1
	fi
	tmp=$(mktemp) || { exec {lock_fd}>&-; return 1; }
	cp -f "$DAIMON_TCP_SNAPSHOT" "$tmp" || { rm -f "$tmp"; exec {lock_fd}>&-; return 1; }
	printf '\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> "$tmp"
	if daimon_network_bbr_supported; then
		DAIMON_NETWORK_MERGE_EXISTING=1 DAIMON_NETWORK_PRIORITY_CONF="$DAIMON_TCP_TUNING_CONF" daimon_network_persist "$DAIMON_TCP_BBR_CONF" "$tmp" || failed=1
	else
		rm -f "$DAIMON_TCP_TUNING_CONF"
	fi
	rm -f "$tmp"
	while IFS='=' read -r key value; do
		key=$(printf '%s' "$key" | tr -d '[:space:]')
		value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$key" ] && [ -n "$value" ] || continue
		case "$key" in
			net.core.default_qdisc|net.ipv4.tcp_congestion_control) continue ;;
		esac
		daimon_tcp_key_supported "$key" || continue
		[ "$(daimon_tcp_read_key "$key")" = "$value" ] && continue
		daimon_tcp_write_key "$key" "$value" || failed=1
		[ "$(daimon_tcp_read_key "$key")" = "$value" ] || failed=1
	done < "$DAIMON_TCP_SNAPSHOT"
	sysctl -qw net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr 2>/dev/null || failed=1
	[ "$(daimon_tcp_read_key net.core.default_qdisc)" = fq ] &&
		[ "$(daimon_tcp_read_key net.ipv4.tcp_congestion_control)" = bbr ] || failed=1
	exec {lock_fd}>&-
	if [ "$failed" -eq 0 ]; then
		rm -f "$DAIMON_TCP_SNAPSHOT"
		echo -e "${gl_lv}已恢复到调优前的参数，并保留 BBR + FQ。${gl_bai}"
	else
		echo -e "${gl_huang}恢复或持久化未完成，快照保留在 $DAIMON_TCP_SNAPSHOT。${gl_bai}"
	fi
	printf '  当前拥塞算法: %s   队列算法: %s\n' \
		"$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
		"$(sysctl -n net.core.default_qdisc 2>/dev/null)"
	printf '  当前发送缓冲区上限: %s\n' "$(daimon_tcp_read_key net.core.wmem_max)"
	return "$failed"
}

daimon_tcp_fw_persist() {
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save >/dev/null 2>&1 && return 0
	fi
	if [ ! -d /etc/iptables ] && command -v apt-get >/dev/null 2>&1; then
		install iptables-persistent || return 1
		command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 && return 0
	fi
	if command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
		iptables-save > /etc/iptables/rules.v4 2>/dev/null || return 1
		if command -v ip6tables-save >/dev/null 2>&1; then
			ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || return 1
		fi
		return 0
	fi
	echo "缺少防火墙规则持久化设施，无法保证重启后放行。" >&2
	return 1
}

daimon_tcp_fw_open() {
	local port="$1" family="${2:-both}" tool status
	DAIMON_TCP_FW_METHOD="none"
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
		status=$(ufw status 2>/dev/null)
		if printf '%s\n' "$status" | grep -qE "^${port}/tcp[[:space:]]+ALLOW" &&
			{ [ "$family" = 4 ] || printf '%s\n' "$status" | grep -qE "^${port}/tcp.*\(v6\).*ALLOW"; }; then
			DAIMON_TCP_FW_METHOD="ufw-已放行"
		elif ufw allow "$port/tcp" >/dev/null 2>&1; then
			DAIMON_TCP_FW_METHOD="ufw-已新增"
		else
			return 1
		fi
		status=$(ufw status 2>/dev/null)
		[ "$family" = 6 ] || printf '%s\n' "$status" | grep -qE "^${port}/tcp[[:space:]]+ALLOW" || return 1
		[ "$family" = 4 ] || printf '%s\n' "$status" | grep -qE "^${port}/tcp.*\(v6\).*ALLOW" || { echo "UFW 未放行 IPv6，请检查 UFW 的 IPv6 支持。"; return 1; }
		return 0
	fi
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1 &&
			firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
			DAIMON_TCP_FW_METHOD="firewalld-已放行"
		elif firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1; then
			firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || return 1
			DAIMON_TCP_FW_METHOD="firewalld-已新增"
		else
			return 1
		fi
		return 0
	fi
	if command -v iptables >/dev/null 2>&1; then
		for tool in iptables ip6tables; do
			[ "$family" != 4 ] || [ "$tool" != ip6tables ] || continue
			[ "$family" != 6 ] || [ "$tool" != iptables ] || continue
			command -v "$tool" >/dev/null 2>&1 || { echo "$tool 不可用，无法放行指定协议。"; return 1; }
			if ! "$tool" -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
				"$tool" -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || return 1
			fi
		done
		daimon_tcp_fw_persist || return 1
		DAIMON_TCP_FW_METHOD="iptables-已放行并持久化"
		return 0
	fi
	if command -v nft >/dev/null 2>&1; then
		if ! nft -j list ruleset 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin)["nftables"]
chains = {(c["family"], c["table"], c["name"]): c for item in items
          if (c := item.get("chain")) and c.get("hook") in ("input", "output")}
blocked = any(c.get("policy", "accept") != "accept" for c in chains.values())
blocked |= any((r["family"], r["table"], r["chain"]) in chains for item in items if (r := item.get("rule")))
sys.exit(1 if blocked else 0)
'; then
			echo "检测到独立 nftables 过滤规则，不能安全推断放行位置，未启动测速。" >&2
			return 1
		fi
	fi
	echo "未检测到本机防火墙规则；云安全组需由云平台放行 TCP $port。"
	return 0
}

daimon_tcp_ping_rtt() {
	local host="$1" out
	case "$host" in *:*) out=$(ping -6 -c 3 -W 2 -i 0.3 "$host" 2>/dev/null) ;; *) out=$(ping -c 3 -W 2 -i 0.3 "$host" 2>/dev/null) ;; esac
	printf '%s\n' "$out" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p' | head -n 1
}

daimon_tcp_cn_rtt() {
	local host rtt values=""
	for host in 223.5.5.5 119.29.29.29 180.76.76.76; do
		rtt=$(daimon_tcp_ping_rtt "$host")
		[ -n "$rtt" ] && values="$values $rtt"
	done
	values=${values# }
	[ -n "$values" ] || return 1
	printf '%s\n' $values | daimon_tcp_median
}

daimon_tcp_public_ips() {
	local cand out=""
	ip_address >/dev/null 2>&1 || true
	for cand in $ipv4_address $ipv6_address; do
		case "$cand" in ''|*[!0-9a-fA-F:.]*) continue ;; esac
		case " $out " in *" $cand "*) continue ;; esac
		out="$out $cand"
	done
	case "$ipv4_address" in
		''|*:*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
			cand=$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://ipinfo.io/ip 2>/dev/null)
			case "$cand" in
				''|*[!0-9.]*) ;;
				*) case " $out " in *" $cand "*) ;; *) out="$cand $out" ;; esac ;;
			esac
			;;
	esac
	for cand in $(ip -6 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}'); do
		case "$cand" in 2*|3*) ;; *) continue ;; esac
		case " $out " in *" $cand "*) continue ;; esac
		out="$out $cand"
	done
	printf '%s\n' ${out# }
}

daimon_tcp_tcpquality_rows() {
	sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b\][^\x07]*\x07//g' "$1" 2>/dev/null |
		tr -d '\r' |
		awk '
			/Mbps/ {
				label = ""; retr = ""; down = ""; up = ""
				n = split($0, tok, /[ \t]+/)
				for (i = 1; i <= n; i++) {
					t = tok[i]
					if (t ~ /Mbps$/) {
						num = t; sub(/Mbps$/, "", num)
						if (num ~ /^-?[0-9]+([.][0-9]+)?$/) {
							if (down == "") down = num
							else if (up == "") up = num
						}
					} else if (t ~ /%$/ && retr == "") {
						num = t; sub(/%$/, "", num)
						if (num ~ /^[0-9]+([.][0-9]+)?$/) retr = num
					} else if (label == "" && t ~ /(电信|联通|移动|AppleCDN|IPv6)/) {
						label = t
					}
				}
				if (label != "" && down != "") printf "%s %s %s %s\n", label, down, (up == "" ? "-" : up), (retr == "" ? "-" : retr)
			}'
}

daimon_tcp_measure_tcpquality() {
	root_use
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	daimon_tcp_prune_logs
	rm -f "$DAIMON_TCP_MEASURE_RESULT"
	local log="$DAIMON_TCP_STATE_DIR/tcpquality-$(date +%Y%m%d-%H%M%S).log"
	local rows top bw retr rtt manual
	echo -e "${gl_kjlan}正在运行 TCPquality 国内三网单线程测速（通常 3-8 分钟）...${gl_bai}"
	daimon_tcp_tcpquality_direct "$log"
	rows=$(daimon_tcp_tcpquality_rows "$log" | awk '$1 ~ /(电信|联通|移动)/' || true)
	if [ -z "$rows" ]; then
		echo -e "${gl_huang}直接运行未取得结果，改用 TCPquality 官方 rootfs 模式（需下载 Debian rootfs，耗时更长）。${gl_bai}"
		daimon_tcp_tcpquality_rootfs "$log"
		rows=$(daimon_tcp_tcpquality_rows "$log" | awk '$1 ~ /(电信|联通|移动)/' || true)
	fi
	if [ -z "$rows" ]; then
		echo -e "${gl_huang}未能自动解析 TCPquality 结果，原始输出末尾如下：${gl_bai}"
		sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$log" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 25
		read -e -p "请手工输入单线程下载实测值(Mbps，留空放弃): " manual || return 1
		[ -n "$manual" ] || { echo "已放弃测速，未修改配置。"; return 1; }
		bw=$manual
		read -e -i "150" -p "请输入到国内的往返延迟 RTT(ms): " rtt || rtt=150
		rtt=${rtt:-150}
		retr=0
		echo "使用手工输入: ${bw} Mbps / ${rtt} ms"
	else
		echo "TCPquality 国内单线程结果（标签 / 下载 / 上传 / 重传%）:"
		printf '%s\n' "$rows" | sed 's/^/  /'
		top=$(printf '%s\n' "$rows" | awk '{d=$2+0; if (d>0) print d, ($4=="-" ? 0 : $4)}' | sort -k1,1nr | head -n 3)
		[ -n "$top" ] || { echo "TCPquality 未返回有效下载速率，未修改配置。"; return 1; }
		bw=$(printf '%s\n' "$top" | awk '{print $1}' | daimon_tcp_median)
		retr=$(printf '%s\n' "$top" | awk '{print $2}' | daimon_tcp_median)
		rtt=$(daimon_tcp_cn_rtt) || rtt=""
		if [ -z "$rtt" ]; then
			echo -e "${gl_huang}未能测得国内 RTT，使用默认值 150 ms。${gl_bai}"
			rtt=150
		fi
		printf '取下载最快三个结果的中位数: %s Mbps（重传 %s%%，RTT %s ms）\n' "$bw" "$retr" "$rtt"
	fi
	cat > "$DAIMON_TCP_MEASURE_RESULT" <<EOF
FAMILY=n/a
BW=$bw
RTT=$rtt
BDP=
RETR=$retr
METHOD=tcpquality
F4=
F6=
EOF
}

daimon_tcp_tcpquality_direct() {
	local log="$1" core="$DAIMON_TCP_STATE_DIR/runTcpQuality-core.sh"
	daimon_require_cmd curl || return 1
	curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
		"https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality-core.sh" -o "$core" 2>/dev/null || return 1
	TERM=xterm timeout --kill-after=15s "${DAIMON_TCP_TCPQUALITY_TIMEOUT:-900}s" \
		bash "$core" --only-speedtest > "$log" 2>&1
	return 0
}

daimon_tcp_tcpquality_rootfs() {
	local log="$1"
	daimon_require_cmd script || return 1
	printf 'n\nn\nn\ny\nn\n' | TERM=xterm timeout --kill-after=10s 900s \
		script -qec "timeout --kill-after=10s 840s bash -c 'curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh | bash'" /dev/null \
		> "$log" 2>&1 || true
	return 0
}

daimon_tcp_lab_load() {
    local library="$DAIMON_RELEASE_DIR/scripts/network/tcp-tuning-lab.sh" tool
    for tool in python3 iperf3 ss flock; do
        daimon_require_cmd "$tool" || return 1
    done
    mkdir -p "$DAIMON_TCP_STATE_DIR" && chmod 700 "$DAIMON_TCP_STATE_DIR" || return 1
    source "$library" || return 1
    daimon_tcp_lab_download_helpers
}

daimon_tcp_lab_menu_family() {
	local choice="$1"
	echo "1. IPv4"
	echo "2. IPv6"
	echo "3. IPv4 + IPv6"
	[ "$choice" = tune ] && echo "4. 分别试调 IPv4 / IPv6 候选，择优保留一套全局参数"
	echo "0. 返回上一级菜单"
	read -e -p "请选择协议: " DAIMON_TCP_LAB_CHOICE || return 1
	case "$DAIMON_TCP_LAB_CHOICE" in
		1) DAIMON_TCP_LAB_FAMILY=4 ;;
		2) DAIMON_TCP_LAB_FAMILY=6 ;;
		3) DAIMON_TCP_LAB_FAMILY=both ;;
		4) [ "$choice" = tune ] || return 1; DAIMON_TCP_LAB_FAMILY=both ;;
		0) return 2 ;;
		*) echo "无效选择"; return 1 ;;
	esac
}

daimon_tcp_tune_menu() {
	root_use
	local choice method result
	while true; do
		clear
		echo "系统网络自适应优化"
		echo "------------------------------------------------"
		echo -e "内核版本:   ${gl_huang}$(uname -r)${gl_bai}"
		echo -e "内存/角色:  $(daimon_tcp_ram_mb) MB / $(daimon_tcp_detect_role)"
		echo -e "拥塞算法:   ${gl_huang}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)${gl_bai}"
		echo -e "队列算法:   ${gl_huang}$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)${gl_bai}"
		echo -e "发送缓冲:   core 上限 $(sysctl -n net.core.wmem_max 2>/dev/null || echo 未知) / TCP $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo 未知)"
		echo -e "tcp_mem:    $(sysctl -n net.ipv4.tcp_mem 2>/dev/null || echo 未知)"
		if daimon_network_bbr_supported; then
			echo -e "BBR 内核支持: ${gl_lv}支持${gl_bai}"
		else
			echo -e "BBR 内核支持: ${gl_hong}不支持，请先在主菜单 13 的 BBR 管理安装兼容内核${gl_bai}"
		fi
		[ -s "$DAIMON_TCP_SNAPSHOT" ] && echo -e "调优前快照: ${gl_lv}已保存${gl_bai}（可恢复到调优前）"
		daimon_tcp_family_speed_block
		[ -s "$DAIMON_TCP_PROFILE" ] && echo "上次调优记录: $DAIMON_TCP_PROFILE"
		if [ "$(sysctl -n vm.panic_on_oom 2>/dev/null)" = "1" ] &&
			[ "$(sysctl -n kernel.panic 2>/dev/null)" != "0" ]; then
			echo -e "${gl_hong}提示: vm.panic_on_oom=1 且 kernel.panic 非 0，内存耗尽会直接重启整机。${gl_bai}"
		fi
		echo "------------------------------------------------"
		echo "1. 动态调优（iperf3 多轮对照；TCPquality 仅作线路参考）"
		echo "2. 恢复调优前参数（保留 BBR + FQ）"
		echo "3. iperf3 本地测试（只测速，不修改参数）"
		echo "0. 返回上一级菜单"
		echo "------------------------------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1)
				echo ""
				echo "1. iperf3 单线程下载（到你的本地电脑，最准确，需要本地客户端）"
				echo "2. TCPquality 国内三网线路参考（不修改参数）"
				echo "0. 返回上一级菜单"
				read -e -p "请选择测速方式: " method || return 1
				case "$method" in
					1)
						result=0; daimon_tcp_lab_menu_family tune || result=$?
						[ "$result" != 2 ] || continue
						[ "$result" = 0 ] || continue
						daimon_tcp_lab_load || { echo "调优依赖或组件加载失败，未启动测速。"; continue; }
						if [ "$DAIMON_TCP_LAB_CHOICE" = 4 ]; then
							daimon_tcp_lab_run separate "$DAIMON_TCP_LAB_FAMILY"
						else
							daimon_tcp_lab_run tune "$DAIMON_TCP_LAB_FAMILY"
						fi
						;;
					2)
						echo "TCPquality 公共端点结果仅供线路参考，不据此写入全局 TCP 参数。"
						daimon_tcp_measure_tcpquality
						;;
					0) continue ;;
					*) echo "无效选择" ;;
				esac
				;;
			2) daimon_tcp_restore ;;
			3)
				result=0; daimon_tcp_lab_menu_family test || result=$?
				[ "$result" != 2 ] || continue
				[ "$result" = 0 ] || continue
				daimon_tcp_lab_load || { echo "测速依赖或组件加载失败，未启动测速。"; continue; }
				daimon_tcp_lab_run test "$DAIMON_TCP_LAB_FAMILY"
				;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

system_network_auto_optimize() {
	daimon_tcp_tune_menu
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
