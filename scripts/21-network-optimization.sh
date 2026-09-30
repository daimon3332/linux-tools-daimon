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

daimon_tcp_percentile() {
	sort -n | awk -v p="${1:-75}" '{v[NR]=$1} END {if (NR==0) exit 1; i=int((NR*p+99)/100); if (i<1) i=1; if (i>NR) i=NR; printf "%.1f\n", v[i]}'
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

daimon_tcp_calc_profile() {
	awk -v bw="$1" -v rtt="$2" -v ram="$(daimon_tcp_ram_mb)" -v role="$3" -v bdp_in="${4:-}" 'BEGIN{
		if (bdp_in !~ /^[0-9]+$/ || bdp_in + 0 <= 0) {
			if (bw <= 0 || rtt <= 0) exit 1
			bdp = bw * 1000000 / 8 * (rtt / 1000)
		} else {
			bdp = bdp_in + 0
		}
		target = bdp * 2 + 2097152
		cap = ram * 32768
		if (cap > 268435456) cap = 268435456
		buf_max = target > cap ? cap : target
		if (buf_max < 4194304) buf_max = 4194304
		if (role == "mixed") buf_default = 2097152
		else buf_default = 1048576
		if (buf_default > buf_max) buf_default = buf_max
		pages = ram * 1024 / 4
		low = int(pages / 16); pres = int(pages / 8); maximum = int(pages / 4)
		if (low < 4096) low = 4096
		if (pres < 8192) pres = 8192
		if (maximum < 16384) maximum = 16384
		printf "bdp=%d\nbuf_max=%d\nbuf_default=%d\ntcp_mem=%d %d %d\n", bdp, buf_max, buf_default, low, pres, maximum
	}'
}

daimon_tcp_build_conf() {
	local out="$1" profile bdp buf_max buf_default tcp_mem line key value unsupported=0 checked="${1}.checked"
	profile=$(daimon_tcp_calc_profile "$2" "$3" "$4" "${5:-}") || { echo "带宽或 RTT 无效，未生成配置。" >&2; return 1; }
	bdp=$(printf '%s\n' "$profile" | sed -n 's/^bdp=//p')
	buf_max=$(printf '%s\n' "$profile" | sed -n 's/^buf_max=//p')
	buf_default=$(printf '%s\n' "$profile" | sed -n 's/^buf_default=//p')
	tcp_mem=$(printf '%s\n' "$profile" | sed -n 's/^tcp_mem=//p')
	cat > "$out" <<EOF
# linux-tools-daimon dynamic TCP tuning
# measured_bandwidth=${2}Mbps measured_rtt=${3}ms ram=$(daimon_tcp_ram_mb)MB role=${4} bdp_bytes=${bdp}
# 由 daimon 动态调优写入，手工修改会在下次调优时被覆盖
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_default
net.core.wmem_default = $buf_default
net.ipv4.tcp_rmem = 4096 $buf_default $buf_max
net.ipv4.tcp_wmem = 4096 16384 $buf_max
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_limit_output_bytes = $buf_max
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
vm.swappiness = 10
EOF
	: > "$checked"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|\#*) printf '%s\n' "$line" >> "$checked"; continue ;; esac
		case "$line" in *=*) ;; *) printf '%s\n' "$line" >> "$checked"; continue ;; esac
		key=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
		value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		if daimon_tcp_write_key "$key" "$value"; then
			printf '%s = %s\n' "$key" "$value" >> "$checked"
		else
			printf '# 当前内核不支持，已跳过: %s = %s\n' "$key" "$value" >> "$checked"
			unsupported=$((unsupported + 1))
		fi
	done < "$out"
	mv -f "$checked" "$out" || return 1
	[ "$unsupported" -eq 0 ] || echo -e "${gl_huang}已跳过 $unsupported 个当前内核不支持的参数。${gl_bai}"
	return 0
}

daimon_tcp_snapshot() {
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	[ -s "$DAIMON_TCP_SNAPSHOT" ] && return 0
	local key
	: > "$DAIMON_TCP_SNAPSHOT" || return 1
	for key in "${DAIMON_TCP_MANAGED_KEYS[@]}"; do
		daimon_tcp_key_supported "$key" || continue
		printf '%s = %s\n' "$key" "$(daimon_tcp_read_key "$key")" >> "$DAIMON_TCP_SNAPSHOT" || return 1
	done
	cp -a /etc/sysctl.conf "$DAIMON_TCP_STATE_DIR/sysctl.conf.before" 2>/dev/null || true
	[ ! -e "$DAIMON_TCP_TUNING_CONF" ] ||
		cp -a "$DAIMON_TCP_TUNING_CONF" "$DAIMON_TCP_STATE_DIR/tuning.conf.before" 2>/dev/null || true
}

daimon_tcp_show_key_sources() {
	local key="$1" file found=0
	for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
		/usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
		[ -f "$file" ] || continue
		grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null || continue
		echo "  同时定义该参数的文件: $file"
		found=1
	done
	[ "$found" -eq 1 ] || echo "  没有其他配置文件定义该参数（可能来自内核默认值或其他运行态覆盖）"
}

daimon_tcp_verify_applied() {
	local file="$1" line key value actual failed=0
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|\#*) continue ;; esac
		case "$line" in *=*) ;; *) continue ;; esac
		key=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
		value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		daimon_tcp_key_supported "$key" || continue
		actual=$(daimon_tcp_read_key "$key")
		[ "$actual" = "$value" ] && continue
		echo -e "${gl_hong}参数被其他来源覆盖: $key 期望 $value 实际 ${actual:-无}${gl_bai}"
		daimon_tcp_show_key_sources "$key"
		daimon_tcp_write_key "$key" "$value" && echo "  已重新写入当前运行态: $key = $value"
		failed=$((failed + 1))
	done < "$file"
	return "$failed"
}

daimon_tcp_persist_values() {
	local conf="$1"
	DAIMON_NETWORK_PRIORITY_CONF="$DAIMON_TCP_TUNING_CONF" daimon_network_persist "$DAIMON_TCP_BBR_CONF" "$conf"
}

daimon_tcp_apply_profile() {
	root_use
	local bw="$1" rtt="$2" method="$3" retr="${4:-}" bdp="${5:-}" role tmp
	[ -n "$bw" ] && [ -n "$rtt" ] || { echo "缺少实测带宽或 RTT，未修改配置。"; return 1; }
	daimon_network_bbr_supported || { echo -e "${gl_hong}当前内核不支持 BBR，未修改任何配置。${gl_bai}"; return 2; }
	role=$(daimon_tcp_detect_role)
	daimon_tcp_snapshot || { echo "无法保存调优前快照，未修改配置。"; return 1; }
	tmp=$(mktemp) || return 1
	if ! daimon_tcp_build_conf "$tmp" "$bw" "$rtt" "$role" "$bdp"; then
		rm -f "$tmp"
		return 1
	fi
	if [ -e "$DAIMON_TCP_TUNING_CONF" ] && ! head -n 1 "$DAIMON_TCP_TUNING_CONF" 2>/dev/null | grep -q 'BEGIN daimon network overrides'; then
		cp -a "$DAIMON_TCP_TUNING_CONF" "$DAIMON_TCP_STATE_DIR/tuning.conf.foreign-before" 2>/dev/null || true
		rm -f "$DAIMON_TCP_TUNING_CONF"
	fi
	printf 'tcp_bbr\n' > /etc/modules-load.d/daimon-tcp-bbr.conf 2>/dev/null || true
	if ! daimon_tcp_persist_values "$tmp" || ! sysctl --system >/dev/null 2>&1; then
		rm -f "$tmp"
		daimon_tcp_revert_runtime
		echo -e "${gl_hong}写入或重载失败，已恢复调优前参数。${gl_bai}"
		return 1
	fi
	rm -f "$tmp"
	echo -e "${gl_lv}TCP 动态调优已应用：$(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)${gl_bai}"
	printf '  实测带宽: %s Mbps   实测 RTT: %s ms   角色: %s\n' "$bw" "$rtt" "$role"
	[ -n "$bdp" ] && printf '  BDP: %s 字节（%s MB）\n' "$bdp" "$((bdp / 1048576))"
	printf '  缓冲区上限: %s 字节（%s MB）\n' "$(sysctl -n net.core.rmem_max)" "$(( $(sysctl -n net.core.rmem_max) / 1048576 ))"
	printf '  缓冲区默认: %s 字节\n' "$(sysctl -n net.core.rmem_default)"
	printf '  tcp_mem: %s\n' "$(sysctl -n net.ipv4.tcp_mem)"
	printf '  配置文件: %s\n' "$DAIMON_TCP_TUNING_CONF"
	daimon_tcp_verify_applied "$DAIMON_TCP_TUNING_CONF" || echo -e "${gl_huang}存在被其他配置覆盖的参数，已在上方列出。${gl_bai}"
	daimon_tcp_save_profile "$method" "$bw" "$rtt" "$role" "" "" "$retr"
	send_stats "TCP动态调优"
}

daimon_tcp_save_profile() {
	local method="$1" bw="$2" rtt="$3" role="$4" before="$5" after="$6" retr="$7"
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	cat > "$DAIMON_TCP_PROFILE" <<EOF
{
  "method": "$method",
  "bandwidth_mbps": ${bw:-0},
  "rtt_ms": ${rtt:-0},
  "ram_mb": $(daimon_tcp_ram_mb),
  "role": "$role",
  "before_mbps": ${before:-0},
  "after_mbps": ${after:-0},
  "retrans": ${retr:-0},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

daimon_tcp_revert_runtime() {
	[ -s "$DAIMON_TCP_SNAPSHOT" ] || return 0
	local key value failed=0
	while IFS='=' read -r key value; do
		key=$(printf '%s' "$key" | tr -d '[:space:]')
		value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$key" ] && [ -n "$value" ] || continue
		daimon_tcp_key_supported "$key" || continue
		[ "$(daimon_tcp_read_key "$key")" = "$value" ] && continue
		daimon_tcp_write_key "$key" "$value" || failed=1
	done < "$DAIMON_TCP_SNAPSHOT"
	return "$failed"
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

daimon_tcp_sample_socket_rtt() {
	local port="$1" sample
	sample=$(ss -tin state established "( sport = :$port )" 2>/dev/null |
		grep -o 'rtt:[0-9.]*' | cut -d: -f2 | head -n 3 | daimon_tcp_median 2>/dev/null)
	[ -n "$sample" ] && DAIMON_TCP_RTT_SAMPLES="$DAIMON_TCP_RTT_SAMPLES $sample"
	return 0
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

daimon_tcp_iperf3_samples() {
	awk '
		/^Accepted connection from/ {
			if (have) printf "%.1f %d\n", rate, retr
			have = 0; rate = 0; retr = 0
			next
		}
		/^\[/ && $NF == "sender" {
			unit = $(NF-2); val = $(NF-3) + 0
			if (unit ~ /^Kbits/) val = val / 1000
			else if (unit ~ /^Gbits/) val = val * 1000
			else if (unit ~ /^bits/) val = val / 1000000
			rate = val; retr = $(NF-1) + 0; have = 1
		}
		END { if (have) printf "%.1f %d\n", rate, retr }
	' "$1" 2>/dev/null
}

daimon_tcp_start_iperf_server() {
	local port="$1" log="$2" pid
	DAIMON_TCP_IPERF_PID=""
	: > "$log"
	iperf3 -s -p "$port" --forceflush > "$log" 2>&1 &
	pid=$!
	sleep 1
	if kill -0 "$pid" 2>/dev/null && [ -s "$log" ]; then
		DAIMON_TCP_IPERF_PID="$pid"
		return 0
	fi
	kill "$pid" 2>/dev/null || true
	if command -v stdbuf >/dev/null 2>&1; then
		: > "$log"
		stdbuf -oL -eL iperf3 -s -p "$port" > "$log" 2>&1 &
		pid=$!
		sleep 1
		if kill -0 "$pid" 2>/dev/null && [ -s "$log" ]; then
			DAIMON_TCP_IPERF_PID="$pid"
			return 0
		fi
		kill "$pid" 2>/dev/null || true
	fi
	return 1
}

daimon_tcp_stop_iperf_server() {
	local port="$1" pid="$2"
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	pkill -f "iperf3 -s -p ${port}( |$)" 2>/dev/null || true
	[ -n "$pid" ] && wait "$pid" 2>/dev/null || true
	return 0
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

daimon_tcp_iperf3_peer() {
	grep -m 1 '^Accepted connection from' "$1" 2>/dev/null |
		sed -e 's/^Accepted connection from[[:space:]]*//' -e 's/,.*$//' -e 's/[][]//g' -e 's/[[:space:]]*$//'
}

daimon_tcp_iperf3_intervals() {
	awk -v omit="${2:-4}" '
		/^Accepted connection from/ { conn++; idx = 0; next }
		/^\[/ && /bits\/sec/ && $NF != "sender" && $NF != "receiver" {
			if (conn == 0 || $2 !~ /^[0-9]+\]$/) next
			ui = 0; iv = ""
			for (i = 2; i <= NF; i++) {
				if ($i ~ /^[KMGT]?bits\/sec$/) ui = i
				else if (iv == "" && $i ~ /^[0-9.]+-[0-9.]+$/) iv = $i
			}
			if (ui == 0 || iv == "") next
			split(iv, part, "-")
			if (part[2] + 0 <= omit + 0 || part[2] - part[1] < 0.5) next
			unit = $ui; rate = $(ui - 1) + 0
			if (unit ~ /^Kbits/) rate = rate / 1000
			else if (unit ~ /^Gbits/) rate = rate * 1000
			else if (unit ~ /^bits/) rate = rate / 1000000
			samples[conn, ++idx] = rate
			retrs[conn, idx] = $(ui + 1) + 0
		}
		END {
			if (conn == 0) exit
			for (i = 1; i <= idx; i++) printf "%.1f %d\n", samples[conn, i], retrs[conn, i]
		}
	' "$1" 2>/dev/null
}

daimon_tcp_iperf3_connection_count() {
	grep -c '^Accepted connection from' "$1" 2>/dev/null || true
}

daimon_tcp_iperf3_last_peer() {
	grep '^Accepted connection from' "$1" 2>/dev/null | tail -n 1 |
		sed -e 's/^Accepted connection from[[:space:]]*//' -e 's/,.*$//' -e 's/[][]//g' -e 's/[[:space:]]*$//'
}

daimon_tcp_measure_iperf3() {
	root_use
	local family="${1:-4}"
	local port="${DAIMON_TCP_IPERF3_PORT:-50280}" log server_pid ips cand fam
	local duration="${DAIMON_TCP_IPERF3_TIME:-20}" omit="${DAIMON_TCP_IPERF3_OMIT:-4}"
	local deadline ip4="" ip6="" fam_list f target fam_opt conns_before conns_now peer_family
	local samples count bw retr rtt peer mean hi lo med finished
	local retr_total=0 bdp=0 bdp_f=0 bw_use="" rtt_use="" detail4="" detail6=""
	rm -f "$DAIMON_TCP_MEASURE_RESULT"
	DAIMON_TCP_RTT_SAMPLES=""
	daimon_require_cmd iperf3 && daimon_require_cmd ss || return 1
	while ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; do
		port=$((port + 1))
		[ "$port" -gt 65000 ] && { echo "找不到可用端口。"; return 1; }
	done
	ips=$(daimon_tcp_public_ips)
	[ -n "$ips" ] || { echo "无法获取公网地址，未修改配置。"; return 1; }
	for cand in $ips; do
		case "$cand" in
			*:*) [ -n "$ip6" ] || ip6=$cand ;;
			*) [ -n "$ip4" ] || ip4=$cand ;;
		esac
	done
	case "$family" in
		4) fam_list="4"; [ -n "$ip4" ] || { echo "没有检测到公网 IPv4 地址，未修改配置。"; return 1; } ;;
		6) fam_list="6"; [ -n "$ip6" ] || { echo "没有检测到公网 IPv6 地址，未修改配置。"; return 1; } ;;
		both)
			fam_list="4 6"
			[ -n "$ip4" ] && [ -n "$ip6" ] || { echo "同时优化 IPv4 和 IPv6 需要本机两个地址都可用，未修改配置。"; return 1; }
			;;
		*) fam_list="4" ;;
	esac
	mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
	daimon_tcp_prune_logs
	log="$DAIMON_TCP_STATE_DIR/iperf3-$(date +%Y%m%d-%H%M%S).log"
	daimon_tcp_fw_open "$port"
	if ! daimon_tcp_start_iperf_server "$port" "$log"; then
		echo "iperf3 服务端启动失败，日志: $log"
		return 1
	fi
	server_pid="$DAIMON_TCP_IPERF_PID"
	echo -e "${gl_kjlan}iperf3 服务端已监听端口 $port（防火墙: ${DAIMON_TCP_FW_METHOD}，测速端口已放行并保留）。${gl_bai}"
	for f in $fam_list; do
		if [ "$f" = 6 ]; then
			target="$ip6"; fam_opt="-6"
		else
			target="$ip4"; fam_opt="-4"
		fi
		conns_before=$(daimon_tcp_iperf3_connection_count "$log")
		echo -e "${gl_huang}IPv$f 测速：请在本地电脑运行下面这一条命令，只运行 1 次（单线程下载 ${duration}s，前 ${omit}s 预热不计入）：${gl_bai}"
		printf '  iperf3 -c %s -p %s %s -R -t %s -O %s -i 1\n' "$target" "$port" "$fam_opt" "$duration" "$omit"
		finished=0
		deadline=$((SECONDS + ${DAIMON_TCP_IPERF3_WAIT:-600}))
		while :; do
			daimon_tcp_sample_socket_rtt "$port"
			conns_now=$(daimon_tcp_iperf3_connection_count "$log")
			if [ "${conns_now:-0}" -gt "${conns_before:-0}" ] && [ -n "$(daimon_tcp_iperf3_samples "$log" | head -n 1)" ]; then
				finished=1
				break
			fi
			kill -0 "$server_pid" 2>/dev/null || break
			[ "$SECONDS" -ge "$deadline" ] && break
			sleep 1
		done
		if [ "$finished" -ne 1 ]; then
			daimon_tcp_stop_iperf_server "$port" "$server_pid"
			echo "IPv$f 没有检测到完成的测试，未修改配置。日志: $log"
			return 1
		fi
		peer=$(daimon_tcp_iperf3_last_peer "$log")
		peer_family=4
		case "$peer" in *:*) peer_family=6 ;; esac
		if [ "$peer_family" != "$f" ]; then
			daimon_tcp_stop_iperf_server "$port" "$server_pid"
			echo -e "${gl_hong}请求 IPv$f 测速，但连接来自 IPv$peer_family 地址 $peer，未修改配置。${gl_bai}"
			return 1
		fi
		samples=$(daimon_tcp_iperf3_intervals "$log" "$omit")
		count=$(printf '%s\n' "$samples" | grep -c . || true)
		if [ "${count:-0}" -lt 5 ]; then
			daimon_tcp_stop_iperf_server "$port" "$server_pid"
			echo -e "${gl_hong}IPv$f 预热 ${omit}s 之后只取到 ${count:-0} 个每秒采样，样本不足，未修改配置。日志: $log${gl_bai}"
			if [ "$family" = both ]; then
				echo -e "${gl_huang}IPv$f 链路当前不可用（本机、对端或中间路由问题），未写入任何参数；可改用“只优化 IPv4”或“只优化 IPv6”。${gl_bai}"
			fi
			return 1
		fi
		bw=$(printf '%s\n' "$samples" | awk '{print $1}' | daimon_tcp_percentile 75)
		mean=$(printf '%s\n' "$samples" | awk '{s += $1} END {printf "%.1f", s / NR}')
		med=$(printf '%s\n' "$samples" | awk '{print $1}' | daimon_tcp_median)
		lo=$(printf '%s\n' "$samples" | awk 'NR == 1 || $1 < lo {lo = $1} END {printf "%.1f", lo}')
		hi=$(printf '%s\n' "$samples" | awk 'NR == 1 || $1 > hi {hi = $1} END {printf "%.1f", hi}')
		retr=$(printf '%s\n' "$samples" | awk '{s += $2} END {printf "%d", s}')
		rtt=$(printf '%s\n' $DAIMON_TCP_RTT_SAMPLES 2>/dev/null | daimon_tcp_median 2>/dev/null || true)
		[ -n "$rtt" ] || rtt=$(daimon_tcp_ping_rtt "$peer")
		printf 'IPv%s 单线程下载: 取 75%% 分位 %s Mbps（中位数 %s，均值 %s，最低 %s，最高 %s，%s 个每秒采样，重传合计 %s，RTT %s ms）\n' \
			"$f" "$bw" "$med" "$mean" "$lo" "$hi" "$count" "$retr" "${rtt:-未知}"
		DAIMON_TCP_RTT_SAMPLES=""
		retr_total=$((retr_total + retr))
		if [ -z "$bw_use" ]; then
			bw_use=$bw; rtt_use=${rtt:-150}
			bdp=$(awk -v b="$bw" -v r="${rtt:-150}" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}')
		else
			bdp_f=$(awk -v b="$bw" -v r="${rtt:-150}" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}')
			if [ "$bdp_f" -gt "$bdp" ]; then
				bdp=$bdp_f; bw_use=$bw; rtt_use=${rtt:-150}
			fi
		fi
		[ "$f" = 4 ] && detail4="$bw ${rtt:-150} $retr" || detail6="$bw ${rtt:-150} $retr"
		daimon_tcp_record_family "$f" "$bw" "${rtt:-0}" "$retr"
	done
	daimon_tcp_stop_iperf_server "$port" "$server_pid"
	cat > "$DAIMON_TCP_MEASURE_RESULT" <<EOF
FAMILY=$family
BW=$bw_use
RTT=$rtt_use
BDP=$bdp
RETR=$retr_total
METHOD=iperf3
F4=$detail4
F6=$detail6
EOF
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

daimon_tcp_measure() {
	case "$1" in
		iperf3) daimon_tcp_measure_iperf3 "${2:-4}" ;;
		*) daimon_tcp_measure_tcpquality ;;
	esac
}

daimon_tcp_tcpquality_direct() {
	local log="$1" core="$DAIMON_TCP_STATE_DIR/runTcpQuality-core.sh"
	command -v curl >/dev/null 2>&1 || install curl || { echo "curl 安装失败，无法运行 TCPquality。"; return 1; }
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

daimon_tcp_compare_result() {
	local before="$1" after="$2" f b a compared=0 regressed=0
	for f in 4 6; do
		b=$(sed -n "s/^F$f=//p" "$before" | tail -n 1 | awk '{print $1}')
		a=$(sed -n "s/^F$f=//p" "$after" | tail -n 1 | awk '{print $1}')
		[ -n "$b" ] && [ -n "$a" ] || continue
		compared=1
		if awk -v x="$b" -v y="$a" 'BEGIN{exit !(y < x * 0.95)}'; then
			printf 'IPv%s: %s -> %s Mbps（下降）\n' "$f" "$b" "$a"
			regressed=1
		else
			printf 'IPv%s: %s -> %s Mbps\n' "$f" "$b" "$a"
		fi
	done
	if [ "$compared" -eq 0 ]; then
		b=$(sed -n 's/^BW=//p' "$before" | tail -n 1)
		a=$(sed -n 's/^BW=//p' "$after" | tail -n 1)
		printf '测速端点: %s -> %s Mbps\n' "$b" "$a"
		awk -v x="$b" -v y="$a" 'BEGIN{exit !(x > 0 && y > 0 && y >= x * 0.95)}' || regressed=1
	fi
	return "$regressed"
}

daimon_tcp_tune_run() {
	root_use
	local method="$1" family="${2:-4}"
	local before_bw before_rtt before_retr before_bdp after_bw after_retr role label
	role=$(daimon_tcp_detect_role)
	label="TCPquality 国内三网单线程下载"
	if [ "$method" = iperf3 ]; then
		case "$family" in
			6) label="iperf3 IPv6 单线程下载（到本地电脑，最准确）" ;;
			both) label="iperf3 IPv4 + IPv6 单线程下载（到本地电脑，最准确）" ;;
			*) label="iperf3 IPv4 单线程下载（到本地电脑，最准确）" ;;
		esac
	fi
	echo -e "${gl_kjlan}测速方式: $label${gl_bai}"
	daimon_tcp_measure "$method" "$family" || { echo "测速失败，未修改任何配置。"; return 1; }
	cp -f "$DAIMON_TCP_MEASURE_RESULT" "$DAIMON_TCP_BEFORE_RESULT" 2>/dev/null || true
	before_bw=$(sed -n 's/^BW=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	before_rtt=$(sed -n 's/^RTT=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	before_retr=$(sed -n 's/^RETR=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	before_bdp=$(sed -n 's/^BDP=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	[ -n "$before_bw" ] && [ -n "$before_rtt" ] || { echo "未能解析测速结果，未修改任何配置。"; return 1; }
	echo
	daimon_tcp_apply_profile "$before_bw" "$before_rtt" "$method" "$before_retr" "$before_bdp" || return 1
	echo
	echo -e "${gl_kjlan}复测验证：请再运行同一条命令 1 次${gl_bai}"
	if ! daimon_tcp_measure "$method" "$family"; then
		echo -e "${gl_huang}复测未完成，无法确认是否变快，按“不劣化”原则恢复原参数（保留 BBR + FQ）。${gl_bai}"
		daimon_tcp_restore
		return 0
	fi
	after_bw=$(sed -n 's/^BW=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	after_retr=$(sed -n 's/^RETR=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	echo "------------------------------------------------"
	printf '优化前中位数: %s Mbps   优化后中位数: %s Mbps\n' "$before_bw" "${after_bw:-?}"
	daimon_tcp_save_profile "$method" "$before_bw" "$before_rtt" "$role" "$before_bw" "$after_bw" "$after_retr"
	if daimon_tcp_compare_result "$DAIMON_TCP_BEFORE_RESULT" "$DAIMON_TCP_MEASURE_RESULT"; then
		echo -e "${gl_lv}复测不低于优化前（容差 5%），保留动态调优参数。${gl_bai}"
	else
		echo -e "${gl_hong}复测低于优化前，按“不劣化”原则恢复原参数（保留 BBR + FQ）。${gl_bai}"
		daimon_tcp_restore
	fi
	echo "------------------------------------------------"
}

daimon_tcp_tune_auto_apply() {
	local method="${1:-tcpquality}" bw rtt retr
	daimon_tcp_measure "$method" || return 1
	bw=$(sed -n 's/^BW=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	rtt=$(sed -n 's/^RTT=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	retr=$(sed -n 's/^RETR=//p' "$DAIMON_TCP_MEASURE_RESULT" | tail -n 1)
	[ -n "$bw" ] && [ -n "$rtt" ] || { echo "未能解析测速结果，未修改配置。"; return 1; }
	daimon_tcp_apply_profile "$bw" "$rtt" "$method" "$retr"
}

daimon_tcp_lab_load() {
    local library="$DAIMON_RELEASE_DIR/scripts/network/tcp-tuning-lab.sh" tool package
    for tool in python3 iperf3 ss flock; do
        command -v "$tool" >/dev/null 2>&1 && continue
        case "$tool" in ss) package=iproute2 ;; flock) package=util-linux ;; *) package="$tool" ;; esac
        install "$package" || return 1
        command -v "$tool" >/dev/null 2>&1 || { echo "$tool 安装后仍不可用。" >&2; return 1; }
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
