#!/bin/bash

validate_tcp_port() {
	[[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

daimon_country() {
	local cache="${DAIMON_ROOT_DIR:-/root/linux-daimon}/.country" value="" staged
	if [ -z "${DAIMON_COUNTRY_CACHE:-}" ] && [ -f "$cache" ] && [ ! -L "$cache" ]; then
		read -r value < "$cache" || value=""
		if { [[ "$value" =~ ^[A-Z]{2}$ ]] && [ -n "$(find "$cache" -mmin -1440 2>/dev/null)" ]; } ||
			{ [ "$value" = -- ] && [ -n "$(find "$cache" -mmin -60 2>/dev/null)" ]; }; then
			[ "$value" != -- ] || { echo ""; return 0; }
			DAIMON_COUNTRY_CACHE=$value
		fi
	fi
	if [ -z "${DAIMON_COUNTRY_CACHE:-}" ]; then
		value=$(curl -fsSL --connect-timeout 3 --max-time 5 https://ipinfo.io/json 2>/dev/null | grep -oE '"country"[[:space:]]*:[[:space:]]*"[A-Z]{2}"' | head -1 | cut -d'"' -f4)
		[[ "$value" =~ ^[A-Z]{2}$ ]] || value=$(curl -4 -fsSL --connect-timeout 3 --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
		[[ "$value" =~ ^[A-Z]{2}$ ]] || value=""
		DAIMON_COUNTRY_CACHE=$value
		if [ -d "${cache%/*}" ] && staged=$(mktemp "$cache.XXXXXX" 2>/dev/null); then
			printf '%s\n' "${value:---}" > "$staged" && mv -f -- "$staged" "$cache" || rm -f -- "$staged"
		fi
	fi
	echo "$DAIMON_COUNTRY_CACHE"
}

daimon_is_cn() {
	[ "$(daimon_country)" = "CN" ]
}

daimon_strip_github_proxy() {
	local url="$1"
	case "$url" in
		https://gh-proxy.com/http*) echo "${url#https://gh-proxy.com/}" ;;
		https://ghproxy.net/http*) echo "${url#https://ghproxy.net/}" ;;
		https://ghfast.top/http*) echo "${url#https://ghfast.top/}" ;;
		https://gh.kejilion.pro/raw.githubusercontent.com/*) echo "https://${url#https://gh.kejilion.pro/}" ;;
		https://gh.kejilion.pro/github.com/*) echo "https://${url#https://gh.kejilion.pro/}" ;;
		*) echo "$url" ;;
	esac
}

daimon_jsdelivr_url() {
	local url="$1" path owner repo branch rest
	case "$url" in
		https://raw.githubusercontent.com/*)
			path="${url#https://raw.githubusercontent.com/}"
			owner="${path%%/*}"; path="${path#*/}"
			repo="${path%%/*}"; path="${path#*/}"
			path="${path#refs/heads/}"
			branch="${path%%/*}"; rest="${path#*/}"
			[ -n "$owner" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$rest" ] && echo "https://testingcf.jsdelivr.net/gh/${owner}/${repo}@${branch}/${rest}"
			;;
		https://github.com/*/raw/refs/heads/*)
			path="${url#https://github.com/}"
			owner="${path%%/*}"; path="${path#*/}"
			repo="${path%%/*}"; path="${path#*/raw/refs/heads/}"
			branch="${path%%/*}"; rest="${path#*/}"
			[ -n "$owner" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$rest" ] && echo "https://testingcf.jsdelivr.net/gh/${owner}/${repo}@${branch}/${rest}"
			;;
	esac
}

daimon_github_url_candidates() {
	local url jsdelivr
	url=$(daimon_strip_github_proxy "$1")
	if ! daimon_is_cn; then
		echo "$url"
		return 0
	fi
	case "$url" in
		https://raw.githubusercontent.com/*|https://github.com/*)
			echo "https://gh-proxy.com/$url"
			echo "https://ghproxy.net/$url"
			jsdelivr=$(daimon_jsdelivr_url "$url")
			[ -n "$jsdelivr" ] && echo "$jsdelivr"
			echo "https://ghfast.top/$url"
			echo "$url"
			;;
		*)
			echo "$url"
			;;
	esac
}

daimon_download_to() {
	local url="$1"
	local target="$2"
	local download_timeout="${3:-180}" real_url tmp
	mkdir -p "$(dirname "$target")" || return 1
	tmp=$(mktemp "${target}.download.XXXXXX") || return 1
	while IFS= read -r real_url; do
		[ -z "$real_url" ] && continue
		echo -e "${gl_kjlan}尝试下载: $real_url${gl_bai}"
		if curl -fsSL --connect-timeout 10 --max-time "$download_timeout" \
			--speed-limit 1024 --speed-time 15 --retry 1 --retry-max-time "$download_timeout" \
			"$real_url" -o "$tmp" && [ -s "$tmp" ]; then
			mv -f -- "$tmp" "$target" && return 0
			break
		fi
		if command -v wget >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 &&
			timeout "$download_timeout" wget --timeout=15 --tries=1 -qO "$tmp" "$real_url" && [ -s "$tmp" ]; then
			mv -f -- "$tmp" "$target" && return 0
			break
		fi
	done < <(daimon_github_url_candidates "$url")
	rm -f -- "$tmp"
	return 1
}

daimon_download() {
	local url="$1"
	local name="$2"
	mkdir -p "$DAIMON_SCRIPT_DIR" >/dev/null 2>&1 || return 1
	local target="$DAIMON_SCRIPT_DIR/$name"
	if [ -s "$target" ]; then
		echo -e "${gl_lv}使用本地缓存: $target${gl_bai}"
		chmod +x "$target" >/dev/null 2>&1
		return $?
	fi
	echo -e "${gl_kjlan}下载到: $target${gl_bai}"
	daimon_download_to "$url" "$target" || return 1
	chmod +x "$target" >/dev/null 2>&1
}

daimon_run_cached_script() {
	local url="$1"
	local name="$2"
	shift 2
	daimon_download "$url" "$name" || return 1
	bash -n "$DAIMON_SCRIPT_DIR/$name" || { echo "脚本语法校验失败，未执行。"; return 1; }
	if [ -n "${DAIMON_SCRIPT_TIMEOUT:-}" ]; then
		timeout "$DAIMON_SCRIPT_TIMEOUT" bash "$DAIMON_SCRIPT_DIR/$name" "$@"
	else
		bash "$DAIMON_SCRIPT_DIR/$name" "$@"
	fi
}

ip_address() {

get_public_ip() {
	curl -4 -fsS --connect-timeout 3 --max-time 5 https://ipinfo.io/ip 2>/dev/null && echo
}

get_local_ip() {
	local address
	address=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
	if [ -z "$address" ]; then
		address=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')
	fi
	if [ -z "$address" ]; then
		address=$(ifconfig 2>/dev/null | awk '$1=="inet" && $2 !~ /^127\./ {print $2; exit}')
	fi
	printf '%s\n' "$address"
}

public_ip=$(get_public_ip)
isp_info=$(curl -fsS --connect-timeout 3 --max-time 3 https://ipinfo.io/org 2>/dev/null)


if echo "$isp_info" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
  ipv4_address=$(get_local_ip)
else
  ipv4_address="$public_ip"
fi


ipv6_address=$(curl -6 -fsS --connect-timeout 1 --max-time 1 https://v6.ipinfo.io/ip 2>/dev/null && echo)

}

systemctl() {
	local COMMAND="$1"
	shift

	if command -v apk &>/dev/null; then
		if [ "$#" -eq 0 ]; then
			service "$COMMAND"
		else
			local SERVICE_NAME
			for SERVICE_NAME in "$@"; do
				service "$SERVICE_NAME" "$COMMAND" || return $?
			done
		fi
	else
		/bin/systemctl "$COMMAND" "$@"
	fi
}

install_add_docker_cn() {
	docker_daemon_json_merge '."registry-mirrors" = $mirrors' --argjson mirrors \
		'["https://hub.333186.xyz","https://docker.m.daocloud.io","https://docker.1ms.run","https://docker.registry.cyou"]'
}

linuxmirrors_install_docker() {

local country=$(daimon_country)
if [ "$country" = "CN" ]; then
	daimon_run_cached_script "https://linuxmirrors.cn/docker.sh" "linuxmirrors-docker.sh" \
	  --source mirrors.huaweicloud.com/docker-ce \
	  --source-registry docker.1ms.run \
	  --protocol https \
	  --use-intranet-source false \
	  --install-latest true \
	  --close-firewall false \
	  --ignore-backup-tips || return 1
else
	daimon_run_cached_script "https://linuxmirrors.cn/docker.sh" "linuxmirrors-docker.sh" \
	  --source download.docker.com \
	  --source-registry registry.hub.docker.com \
	  --protocol https \
	  --use-intranet-source false \
	  --install-latest true \
	  --close-firewall false \
	  --ignore-backup-tips || return 1
fi

if [ "$country" = CN ]; then install_add_docker_cn || return 1; fi

}

install_add_docker() {
	echo -e "${gl_kjlan}正在安装docker环境...${gl_bai}"
	if command -v apt &>/dev/null || command -v yum &>/dev/null || command -v dnf &>/dev/null; then
		linuxmirrors_install_docker || return 1
	else
		install docker docker-compose
		if [ "$(daimon_country)" = CN ]; then install_add_docker_cn || return 1; fi

	fi
	sleep 2
}

check_crontab_installed() {
	daimon_require_cmd crontab || return 1
	systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 ||
		service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
	grep -qxE 'cron|crond' /proc/[0-9]*/comm 2>/dev/null || {
		echo -e "${gl_hong}cron 服务未运行，定时任务不会执行。${gl_bai}" >&2
		return 1
	}
}

daimon_swap_is_active() {
	awk '$1 == "/swapfile" {found=1} END {exit !found}' /proc/swaps
}

daimon_swap_is_managed() {
	[ -f "$DAIMON_ROOT_DIR/.swapfile-managed" ] &&
		[ ! -L /swapfile ] && [ -f /swapfile ] &&
		[ "$(stat -c '%d:%i' /swapfile)" = "$(cat "$DAIMON_ROOT_DIR/.swapfile-managed")" ]
}

daimon_swap_transaction() (
	local action="$1" size="${2:-}" work tmp="" old_swap="" marker_tmp="" lockfd
	local was_active=0 old_moved=0 new_moved=0 fstab_changed=0 marker_changed=0 committed=0 had_marker=0
	local old_identity="" new_identity="" fstab_identity="" marker_identity=""
	root_use
	[ -f /etc/fstab ] && [ ! -L /etc/fstab ] || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.swapfile-managed" ] || return 1
	[ ! -e "$DAIMON_ROOT_DIR/.swapfile-managed" ] || [ -f "$DAIMON_ROOT_DIR/.swapfile-managed" ] || return 1
	mkdir -p "$DAIMON_ROOT_DIR" || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.swapfile.lock" ] || return 1
	exec {lockfd}> "$DAIMON_ROOT_DIR/.swapfile.lock" || return 1
	flock -n "$lockfd" || { echo "另一个虚拟内存操作正在进行，请稍后重试。"; return 1; }
	if [ "$action" = delete ] || [ -e /swapfile ] || [ -L /swapfile ]; then
		daimon_swap_is_managed || { echo "现有 /swapfile 的归属未确认，未修改。"; return 1; }
	fi
	work=$(mktemp -d /etc/.daimon-swap.XXXXXX) || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$committed" = 0 ]; then
			[ -z "$old_identity" ] || [ "$(stat -c "%d:%i" "$old_swap" 2>/dev/null)" != "$old_identity" ] || old_moved=1
			[ -z "$new_identity" ] || [ "$(stat -c "%d:%i" /swapfile 2>/dev/null)" != "$new_identity" ] || new_moved=1
			[ -z "$fstab_identity" ] || [ "$(stat -c "%d:%i" /etc/fstab 2>/dev/null)" != "$fstab_identity" ] || fstab_changed=1
			[ -z "$marker_identity" ] || [ "$(stat -c "%d:%i" "$DAIMON_ROOT_DIR/.swapfile-managed" 2>/dev/null)" != "$marker_identity" ] || marker_changed=1
			[ "$had_marker" = 0 ] || [ -e "$DAIMON_ROOT_DIR/.swapfile-managed" ] || marker_changed=1
			if [ "$new_moved" = 1 ] && daimon_swap_is_active; then
				swapoff /swapfile || { echo "回滚失败，新 swap 无法停用；恢复文件保留在: $work $old_swap"; exit 1; }
			fi
			if [ "$old_moved" = 1 ]; then
				mv -Tf -- "$old_swap" /swapfile || { echo "回滚失败，原 swap 保留在: $old_swap"; exit 1; }
			elif [ "$new_moved" = 1 ]; then
				rm -f -- /swapfile || exit 1
			fi
			if [ "$was_active" = 1 ] && ! daimon_swap_is_active; then
				swapon /swapfile && daimon_swap_is_active || { echo "原 swap 重新启用失败，恢复文件保留在: $work"; exit 1; }
			fi
			[ "$fstab_changed" = 0 ] || mv -Tf -- "$work/fstab" /etc/fstab || { echo "fstab 恢复失败: $work/fstab"; exit 1; }
			if [ "$marker_changed" = 1 ]; then
				if [ "$had_marker" = 1 ]; then
					cp -p -- "$work/marker" "$marker_tmp" && mv -Tf -- "$marker_tmp" "$DAIMON_ROOT_DIR/.swapfile-managed" || { echo "归属标记恢复失败: $work/marker"; exit 1; }
				else
					rm -f -- "$DAIMON_ROOT_DIR/.swapfile-managed" || exit 1
				fi
			fi
		fi
		rm -f -- "$tmp" "$old_swap" "$marker_tmp" "$work/fstab" "$work/new-fstab" "$work/marker"
		rmdir -- "$work"
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	cp -p -- /etc/fstab "$work/fstab" || return 1
	sed '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab > "$work/new-fstab" || return 1
	chmod --reference=/etc/fstab "$work/new-fstab" && chown --reference=/etc/fstab "$work/new-fstab" || return 1
	fstab_identity=$(stat -c '%d:%i' "$work/new-fstab") || return 1
	if [ -f "$DAIMON_ROOT_DIR/.swapfile-managed" ]; then
		cp -p -- "$DAIMON_ROOT_DIR/.swapfile-managed" "$work/marker" || return 1
		had_marker=1
	fi
	marker_tmp=$(mktemp "$DAIMON_ROOT_DIR/.swapfile-managed.XXXXXX") || return 1
	marker_identity=$(stat -c '%d:%i' "$marker_tmp") || return 1
	if [ "$action" = resize ]; then
		tmp=$(mktemp /swapfile.daimon.XXXXXX) || return 1
		chmod 600 "$tmp" && fallocate -l "${size}M" "$tmp" && mkswap "$tmp" || return 1
		stat -c '%d:%i' "$tmp" > "$marker_tmp" || return 1
		new_identity=$(cat "$marker_tmp") || return 1
		printf '/swapfile swap swap defaults 0 0\n' >> "$work/new-fstab" || return 1
	fi
	if [ -e /swapfile ]; then
		old_swap=$(mktemp /swapfile.daimon.old.XXXXXX) || return 1
		old_identity=$(stat -c '%d:%i' /swapfile) || return 1
	fi
	daimon_swap_is_active && was_active=1
	if [ "$was_active" = 1 ]; then swapoff /swapfile || return 1; fi
	if [ -n "$old_swap" ]; then mv -Tf -- /swapfile "$old_swap" || return 1; old_moved=1; fi
	if [ "$action" = resize ]; then
		mv -Tf -- "$tmp" /swapfile || return 1
		new_moved=1
		swapon /swapfile && daimon_swap_is_active || return 1
	fi
	mv -Tf -- "$work/new-fstab" /etc/fstab || return 1
	fstab_changed=1
	if [ "$action" = resize ]; then
		mv -Tf -- "$marker_tmp" "$DAIMON_ROOT_DIR/.swapfile-managed" || return 1
	else
		rm -f -- "$DAIMON_ROOT_DIR/.swapfile-managed" || return 1
	fi
	marker_changed=1
	committed=1
	if [ -f /etc/alpine-release ]; then
		if [ "$action" = resize ]; then
			mkdir -p /etc/local.d && printf 'nohup swapon /swapfile\n' > /etc/local.d/swap.start &&
				chmod +x /etc/local.d/swap.start && rc-update add local || return 1
		else
			rm -f /etc/local.d/swap.start || return 1
		fi
	fi
)

add_swap() {
	local new_swap="${1:-}"
	if ! [[ "$new_swap" =~ ^[1-9][0-9]{0,6}$ ]] || [ "$new_swap" -gt 1048576 ]; then
		echo "虚拟内存大小必须为 1-1048576 MiB 的整数"
		return 1
	fi
	daimon_swap_transaction resize "$new_swap" || return 1
	echo -e "虚拟内存大小已调整为${gl_huang}${new_swap}${gl_bai}M"
}

daimon_config_commit() {
	local file="$1" staged="$2" mode="${3:-644}"
	if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
		rm -f -- "$staged"
		return 1
	fi
	if [ -f "$file" ]; then
		chmod --reference="$file" "$staged" &&
			{ [ "$(id -u)" != 0 ] || chown --reference="$file" "$staged"; } || { rm -f -- "$staged"; return 1; }
	else
		chmod "$mode" "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	mv -f -- "$staged" "$file" || { rm -f -- "$staged"; return 1; }
}

current_timezone() {
	local timezone
	timezone=$(readlink -f /etc/localtime 2>/dev/null)
	case "$timezone" in
		/usr/share/zoneinfo/*) printf '%s\n' "${timezone#/usr/share/zoneinfo/}" ;;
		*) date +"%Z %z" ;;
	esac
}

set_timedate() {
	local shiqu="$1"
	if grep -q 'Alpine' /etc/issue; then
		install tzdata || return 1
		cp "/usr/share/zoneinfo/$shiqu" /etc/localtime || return 1
		hwclock --systohc
	else
		timedatectl set-timezone "$shiqu"
	fi
}

fix_dpkg() {
	DEBIAN_FRONTEND=noninteractive dpkg --configure -a || {
		echo "dpkg 修复失败或正被其他进程占用；请等待现有任务完成后重试，不会强杀进程或删除锁。"
		return 1
	}
}

daimon_dns_commit() (
	local staged="$1" attrs locked=0 committed=0
	trap '
		[ "$committed" = 1 ] || [ "$locked" = 0 ] || chattr +i /etc/resolv.conf
		rm -f -- "$staged"
	' EXIT
	trap 'exit 1' INT TERM HUP
	[ ! -e /etc/resolv.conf ] || [ -f /etc/resolv.conf ] || return 1
	chmod 644 "$staged" || return 1
	if [ -f /etc/resolv.conf ]; then
		chmod --reference=/etc/resolv.conf "$staged" || return 1
		[ "$(id -u)" != 0 ] || chown --reference=/etc/resolv.conf "$staged" || return 1
		if [ ! -L /etc/resolv.conf ]; then
			attrs=$(lsattr -d /etc/resolv.conf 2>/dev/null || true); attrs=${attrs%% *}
			[[ "$attrs" != *i* ]] || locked=1
			chattr -i /etc/resolv.conf 2>/dev/null || { [ "$locked" = 0 ] || return 1; }
		fi
	fi
	mv -Tf -- "$staged" /etc/resolv.conf || return 1
	committed=1
	chattr +i /etc/resolv.conf 2>/dev/null || echo "DNS 已写入，但此文件系统不支持锁定 resolv.conf。"
	return 0
)

set_dns() {
	ip_address
	local staged server
	local -a servers=()
	if [ -n "$ipv4_address" ]; then servers+=("$dns1_ipv4" "$dns2_ipv4"); fi
	if [ -n "$ipv6_address" ]; then servers+=("$dns1_ipv6" "$dns2_ipv6"); fi
	if [ "${#servers[@]}" -eq 0 ]; then servers=("$dns1_ipv4" "$dns2_ipv4"); fi
	for server in "${servers[@]}"; do
		[ -n "$server" ] && [[ "$server" != *[[:space:]]* ]] || return 1
	done
	[ ! -e /etc/resolv.conf ] || [ -f /etc/resolv.conf ] || return 1
	staged=$(mktemp /etc/.daimon-dns.XXXXXX) || return 1
	if [ -f /etc/resolv.conf ]; then
		awk '$1 != "nameserver"' /etc/resolv.conf > "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	printf 'nameserver %s\n' "${servers[@]}" >> "$staged" || { rm -f -- "$staged"; return 1; }
	daimon_dns_commit "$staged"
}

daimon_debian_locale() (
	local lang="$1" selection="$2" config work lockfd had_config=0 mutating=0 committed=0 status
	[[ "$lang" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] && [ "$lang" = "$selection" ] || return 1
	install locales || return 1
	[ -f /etc/locale.gen ] && [ ! -L /etc/locale.gen ] || return 1
	config=$(realpath -m -- /etc/default/locale) || return 1
	case "$config" in /etc/default/locale|/etc/locale.conf) ;; *) echo "语言配置链接目标不安全。"; return 1 ;; esac
	[ ! -e "$config" ] || [ -f "$config" ] || return 1
	mkdir -p "$DAIMON_ROOT_DIR" || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.locale.lock" ] || return 1
	exec {lockfd}> "$DAIMON_ROOT_DIR/.locale.lock" || return 1
	flock -n "$lockfd" || return 1
	work=$(mktemp -d /etc/.daimon-locale.XXXXXX) || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$mutating" = 1 ] && [ "$committed" = 0 ]; then
			if ! cmp -s "$work/original-gen" /etc/locale.gen; then
				cp -p -- "$work/original-gen" "$work/restore" && mv -Tf -- "$work/restore" /etc/locale.gen || { echo "语言生成配置恢复失败: $work"; exit 1; }
			fi
			if [ "$had_config" = 1 ]; then
				if ! cmp -s "$work/original-config" "$config"; then
					cp -p -- "$work/original-config" "$work/restore" && mv -Tf -- "$work/restore" "$config" || { echo "语言配置恢复失败: $work"; exit 1; }
				fi
			else
				rm -f -- "$config" || { echo "语言配置恢复失败: $work"; exit 1; }
			fi
		fi
		rm -f -- "$work/original-gen" "$work/original-config" "$work/selection" "$work/config" "$work/restore"
		rmdir -- "$work"
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	cp -p -- /etc/locale.gen "$work/original-gen" || return 1
	if [ -f "$config" ]; then
		had_config=1
		cp -p -- "$config" "$work/original-config" && cp -p -- "$config" "$work/config" || return 1
	else
		: > "$work/config" || return 1
	fi
	awk -v wanted="$selection" '
		{ line=$0; sub(/^[[:space:]]*#[[:space:]]*/, "", line); sub(/^[[:space:]]*/, "", line); split(line, fields, /[[:space:]]+/)
		  if (fields[1] == wanted) {if (!found++) print wanted " UTF-8"; next} print }
		END {if (!found) print wanted " UTF-8"}
	' /etc/locale.gen > "$work/selection" || return 1
	mutating=1
	daimon_config_commit /etc/locale.gen "$work/selection" || return 1
	locale-gen || return 1
	LC_ALL=C locale -a | awk -v wanted="$lang" 'BEGIN {gsub(/[-.]/,"",wanted); wanted=tolower(wanted)} {gsub(/[-.]/,""); if(tolower($0)==wanted) found=1} END {exit !found}' || return 1
	update-locale --locale-file "$work/config" "LANG=$lang" || return 1
	daimon_config_commit "$config" "$work/config" || return 1
	committed=1
)

update_locale() {
	local lang=$1
	local locale_file=$2
	local pause_after="${3:-true}"

	if [ -f /etc/os-release ]; then
		. /etc/os-release
		case $ID in
			debian|ubuntu|kali)
				daimon_debian_locale "$lang" "$locale_file" || return 1
				export LANG=${lang}
				echo -e "${gl_lv}系统语言已经修改为: $lang 重新连接SSH生效。${gl_bai}"
				hash -r
				break_end_unless "$pause_after" false

				;;
			centos|rhel|almalinux|rocky|fedora)
				install "glibc-langpack-${lang%%_*}" || return 1
				localectl set-locale "LANG=$lang" || return 1
				echo "LANG=${lang}" > /etc/locale.conf || return 1
				export LANG="$lang"
				echo -e "${gl_lv}系统语言已经修改为: $lang 重新连接SSH生效。${gl_bai}"
				hash -r
				break_end_unless "$pause_after" false
				;;
			*)
				echo "不支持的系统: $ID"
				break_end_unless "$pause_after" false 1
				return 1
				;;
		esac
	else
		echo "不支持的系统，无法识别系统类型。"
		break_end_unless "$pause_after" false 1
		return 1
	fi
}

rsync_cron_read() {
	local current
	command -v crontab >/dev/null 2>&1 || return 0
	if current=$(LC_ALL=C crontab -l 2>&1); then
		printf '%s\n' "$current"
	elif [[ "$current" == 'no crontab for '* ]]; then
		return 0
	else
		printf '%s\n' "$current" >&2
		return 1
	fi
}

daimon_network_persist() {
	if ! command -v python3 >/dev/null 2>&1; then
		install python3 || { echo "持久化网络配置需要 python3，安装失败，未写入覆盖配置。"; return 1; }
		command -v python3 >/dev/null 2>&1 || { echo "python3 安装后不可用，未写入覆盖配置。"; return 1; }
	fi
	python3 - "${DAIMON_SYSCTL_CONF:-/etc/sysctl.conf}" \
		"${DAIMON_NETWORK_PRIORITY_CONF:-/etc/sysctl.d/zz-daimon-network.conf}" "$@" <<'PY'
import os, re, stat, sys, tempfile
from pathlib import Path

begin = b'# BEGIN daimon network overrides\n'
end = b'# END daimon network overrides\n'
staged, changed, originals = {}, [], {}

def stage(path, data, metadata):
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
            os.fchmod(out.fileno(), stat.S_IMODE(metadata.st_mode) if metadata else 0o644)
            if metadata:
                os.fchown(out.fileno(), metadata.st_uid, metadata.st_gid)
        return name
    except BaseException:
        os.unlink(name)
        raise

try:
    main = Path(sys.argv[1]).resolve()
    late = Path(sys.argv[2])
    if late.is_symlink() or main == late.resolve():
        raise ValueError('Unsafe network override path')
    for path in (main, late):
        if path.exists() and not path.is_file():
            raise ValueError('Configuration is not a regular file: ' + str(path))
        originals[path] = (path.read_bytes(), path.stat()) if path.exists() else (None, None)
    old = originals[main][0] or b''
    preserved = (originals[late][0] or b'') if os.environ.get('DAIMON_NETWORK_MERGE_EXISTING') == '1' else b''
    if old.count(begin) != old.count(end) or old.count(begin) > 1:
        raise ValueError('Malformed daimon block in sysctl.conf')
    if begin in old:
        start, stop = old.index(begin), old.index(end)
        if stop < start:
            raise ValueError('Malformed daimon block order')
        if os.environ.get('DAIMON_NETWORK_MERGE_EXISTING') == '1':
            preserved += old[start + len(begin):stop]
        old = old[:start] + old[stop + len(end):]
    if originals[late][0] is not None and not originals[late][0].startswith(begin):
        raise ValueError('Refusing to overwrite an unmanaged file: ' + str(late))
    values = {}
    for line in preserved.decode().splitlines():
        if '=' in line and not line.lstrip().startswith(('#', ';')):
            key, value = line.split('=', 1)
            values[key.strip()] = ' '.join(value.split())
    for filename in sys.argv[3:]:
        if not filename or not Path(filename).exists():
            continue
        for line in Path(filename).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith(('#', ';')):
                continue
            key, value = line.split('=', 1)
            key, value = key.strip(), ' '.join(value.split())
            if not re.fullmatch(r'(net|vm|fs)\.[a-zA-Z0-9_.-]+', key) or not value:
                raise ValueError('Invalid managed sysctl assignment')
            values[key] = value
    seen = set()
    for directory in (late.parent, Path('/run/sysctl.d'), Path('/usr/local/lib/sysctl.d'), Path('/usr/lib/sysctl.d'), Path('/lib/sysctl.d')):
        for path in directory.glob('*.conf'):
            if path.name in seen:
                continue
            seen.add(path.name)
            if path.name <= late.name:
                continue
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith(('#', ';')) or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                key = key.strip().lstrip('-').replace('/', '.')
                if key in values and ' '.join(value.split()) != values[key]:
                    raise ValueError('Later sysctl override must be resolved: ' + str(path) + ': ' + key)
    block = begin + ''.join(f'{k} = {v}\n' for k, v in values.items()).encode() + end
    new_main = old + (b'\n' if old and not old.endswith(b'\n') else b'') + block
    for path, data in ((main, new_main), (late, block)):
        staged[path] = stage(path, data, originals[path][1])
    for path in (main, late):
        os.replace(staged[path], path)
        del staged[path]
        changed.append(path)
except (OSError, ValueError) as error:
    print('Network persistence failed: ' + str(error), file=sys.stderr)
    for path in reversed(changed):
        data, metadata = originals[path]
        try:
            if data is None:
                path.unlink()
            else:
                backup = stage(path, data, metadata)
                os.replace(backup, path)
        except OSError as rollback:
            print('ROLLBACK FAILED: ' + str(path) + ': ' + str(rollback), file=sys.stderr)
    sys.exit(1)
finally:
    for name in staged.values():
        os.unlink(name)
PY
}

daimon_network_bbr_supported() {
	modprobe tcp_bbr 2>/dev/null || true
	sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

daimon_is_debian() {
	[ -r /etc/os-release ] || return 1
	local ID
	. /etc/os-release
	[ "$ID" = debian ]
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
