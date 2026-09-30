#!/bin/bash

delete_swap() {
	daimon_swap_transaction delete || return 1
	echo -e "${gl_lv}已删除脚本创建的 /swapfile 虚拟内存，并清理 /etc/fstab 持久化配置。${gl_bai}"
}

daimon_gai_preference() {
	local family="$1" file=/etc/gai.conf staged
	[[ "$family" = 4 || "$family" = 6 ]] || return 1
	[ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
	staged=$(mktemp "${file}.XXXXXX") || return 1
	if [ -f "$file" ]; then
		awk '!($1=="precedence" && ($2=="::ffff:0:0/96" || $2=="::ffff:0.0.0.0/96"))' "$file" > "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	if [ "$family" = 4 ]; then
		printf 'precedence ::ffff:0:0/96 100\n' >> "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	daimon_config_commit "$file" "$staged" || return 1
	echo "已切换为 IPv${family} 优先"
}

prefer_ipv4() {
	daimon_gai_preference 4
}

prefer_ipv6() {
	daimon_gai_preference 6
}

edit_dns_config() (
	local staged
	install vim python3 || return 1
	command -v vim >/dev/null && command -v python3 >/dev/null || return 1
	[ ! -e /etc/resolv.conf ] || [ -f /etc/resolv.conf ] || return 1
	staged=$(mktemp /etc/.daimon-dns.XXXXXX) || return 1
	trap 'rm -f -- "$staged"' EXIT
	trap 'exit 1' INT TERM HUP
	if [ -e /etc/resolv.conf ]; then cat /etc/resolv.conf > "$staged" || return 1; fi
	vim "$staged" || return 1
	cmp -s /etc/resolv.conf "$staged" && return 0
	python3 - "$staged" <<'PY' || { echo "DNS 配置无效，保留原配置。"; return 1; }
import ipaddress, sys
servers = []
try:
    with open(sys.argv[1]) as config:
        for line in config:
            fields = line.split('#', 1)[0].split(';', 1)[0].split()
            if fields and fields[0] == 'nameserver':
                if len(fields) != 2:
                    raise ValueError('Invalid nameserver line')
                servers.append(ipaddress.ip_address(fields[1]))
    if not servers:
        raise ValueError('No nameserver configured')
except (OSError, ValueError) as error:
    sys.exit(str(error))
PY
	daimon_dns_commit "$staged"
)

restore_dns_config() (
	local target service source="" work attrs locked=0 committed=0
	for target in /run/systemd/resolve/stub-resolv.conf /run/systemd/resolve/resolv.conf /run/NetworkManager/resolv.conf /run/resolvconf/resolv.conf; do
		case "$target" in
			*/stub-resolv.conf)
				service=systemd-resolved
				! grep -qsiE '^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*(no|false|0)' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf || continue ;;
			/run/systemd/resolve/*) service=systemd-resolved ;;
			/run/NetworkManager/*) service=NetworkManager ;;
			/run/resolvconf/*) service=resolvconf ;;
		esac
		if systemctl is-active --quiet "$service" && [ -s "$target" ] && grep -Eq '^[[:space:]]*nameserver[[:space:]]+[^[:space:]#]+' "$target"; then
			source="$target"; break
		fi
	done
	[ -n "$source" ] || { echo "未找到运行中的系统 DNS 管理器及有效配置；保留当前 DNS，不猜测 127.0.0.53。"; return 1; }
	[ ! -e /etc/resolv.conf ] || [ -f /etc/resolv.conf ] || return 1
	work=$(mktemp -d /etc/.daimon-resolv.XXXXXX) || return 1
	trap '
		[ "$committed" = 1 ] || [ "$locked" = 0 ] || chattr +i /etc/resolv.conf
		rm -f -- "$work/link"; rmdir -- "$work"
	' EXIT
	trap 'exit 1' INT TERM HUP
	ln -s -- "$source" "$work/link" || return 1
	if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
		attrs=$(lsattr -d /etc/resolv.conf 2>/dev/null || true); attrs=${attrs%% *}
		[[ "$attrs" != *i* ]] || locked=1
		chattr -i /etc/resolv.conf 2>/dev/null || { [ "$locked" = 0 ] || return 1; }
	fi
	mv -Tf -- "$work/link" /etc/resolv.conf || return 1
	committed=1
	echo "已恢复系统 DNS 管理器提供的上游配置: $source（不启动或重启服务）"
)

set_dns_ui() {
root_use
while true; do
	clear
	echo "优化DNS地址"
	echo "------------------------"
	echo "当前DNS地址"
	cat /etc/resolv.conf
	echo "------------------------"
	echo ""
	echo "1. 国外DNS优化: "
	echo " v4: 1.1.1.1 8.8.8.8"
	echo " v6: 2606:4700:4700::1111 2001:4860:4860::8888"
	echo "2. 国内DNS优化: "
	echo " v4: 223.5.5.5 119.29.29.29"
	echo " v6: 2400:3200::1 2402:4e00::"
	echo "3. 手动编辑DNS配置"
	echo "4. 恢复系统DNS管理器的配置（不可用时保留当前DNS）"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "请输入你的选择: " Limiting || return 1
	case "$Limiting" in
	  1)
		local dns1_ipv4="1.1.1.1"
		local dns2_ipv4="8.8.8.8"
		local dns1_ipv6="2606:4700:4700::1111"
		local dns2_ipv6="2001:4860:4860::8888"
		set_dns
		;;
	  2)
		local dns1_ipv4="223.5.5.5"
		local dns2_ipv4="119.29.29.29"
		local dns1_ipv6="2400:3200::1"
		local dns2_ipv6="2402:4e00::"
		set_dns
		;;
	  3)
		edit_dns_config
		;;
	  4)
		restore_dns_config
		;;
	  *)
		break
		;;
	esac
	break_end
done

}

import_sshkey() {

	local public_key="${1:-}" temp_file result
	local base_dir="${2:-$HOME}"

	if [[ -z "$public_key" ]]; then
		read -e -p "请输入您的SSH公钥内容（通常以 'ssh-rsa' 或 'ssh-ed25519' 开头）: " public_key || return 1
	fi

	if [[ -z "$public_key" ]]; then
		echo -e "${gl_hong}错误：未输入公钥内容。${gl_bai}"
		return 1
	fi

	if ! ssh_public_key_valid "$public_key"; then
		echo -e "${gl_hong}错误：看起来不像合法的 SSH 公钥。${gl_bai}"
		return 1
	fi

	temp_file=$(mktemp) || return 1
	printf '%s\n' "$public_key" > "$temp_file" || { rm -f -- "$temp_file"; return 1; }
	ssh_import_key_file "$temp_file" "$base_dir"
	result=$?
	rm -f -- "$temp_file"
	return "$result"
}

fetch_remote_ssh_keys() {

	local keys_url="${1:-}"
	local base_dir="${2:-$HOME}"
	local ssh_dir="${base_dir}/.ssh"
	local authorized_keys="${ssh_dir}/authorized_keys"
	local temp_file result

	if [[ -z "${keys_url}" ]]; then
		read -e -p "请输入您的远端公钥URL： " keys_url || return 1
	fi

	echo "此脚本将从远程 URL 拉取 SSH 公钥，并添加到 ${authorized_keys}"
	echo ""
	echo "远程公钥地址："
	echo "  ${keys_url}"
	echo ""

	# 创建临时文件
	temp_file=$(mktemp) || return 1

	# 下载公钥
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 "${keys_url}" -o "${temp_file}" || {
			echo "错误：无法从 URL 下载公钥（网络问题或地址无效）" >&2
			rm -f "${temp_file}"
			return 1
		}
	elif command -v wget >/dev/null 2>&1; then
		wget -q --timeout=10 -O "${temp_file}" "${keys_url}" || {
			echo "错误：无法从 URL 下载公钥（网络问题或地址无效）" >&2
			rm -f "${temp_file}"
			return 1
		}
	else
		echo "错误：系统中未找到 curl 或 wget，无法下载公钥" >&2
		rm -f "${temp_file}"
		return 1
	fi

	# 检查内容是否有效
	if [[ ! -s "${temp_file}" ]]; then
		echo "错误：下载到的文件为空，URL 可能不包含任何公钥" >&2
		rm -f "${temp_file}"
		return 1
	fi

	ssh_import_key_file "$temp_file" "$base_dir"
	result=$?
	rm -f -- "$temp_file"
	return "$result"
}

linux_language() {
root_use
while true; do
  clear
  echo "当前系统语言: $LANG"
  echo "------------------------"
  echo "1. en_US.UTF-8（英文）          2. zh_CN.UTF-8（中文简体）"
  echo "3. zh_TW.UTF-8（中文繁体）      4. ja_JP.UTF-8（日文）"
  echo "5. ko_KR.UTF-8（韩文）          6. de_DE.UTF-8（德文）"
  echo "7. fr_FR.UTF-8（法文）          8. es_ES.UTF-8（西班牙文）"
  echo "9. ru_RU.UTF-8（俄文）"
  echo "------------------------"
  echo "0. 返回上一级选单"
  echo "------------------------"
  read -e -p "输入你的选择: " choice || return 1

  case $choice in
	  1)
		  update_locale "en_US.UTF-8" "en_US.UTF-8"
		  ;;
	  2)
		  update_locale "zh_CN.UTF-8" "zh_CN.UTF-8"
		  ;;
	  3)
		  update_locale "zh_TW.UTF-8" "zh_TW.UTF-8"
		  ;;
	  4)
		  update_locale "ja_JP.UTF-8" "ja_JP.UTF-8"
		  ;;
	  5)
		  update_locale "ko_KR.UTF-8" "ko_KR.UTF-8"
		  ;;
	  6)
		  update_locale "de_DE.UTF-8" "de_DE.UTF-8"
		  ;;
	  7)
		  update_locale "fr_FR.UTF-8" "fr_FR.UTF-8"
		  ;;
	  8)
		  update_locale "es_ES.UTF-8" "es_ES.UTF-8"
		  ;;
	  9)
		  update_locale "ru_RU.UTF-8" "ru_RU.UTF-8"
		  ;;
	  *)
		  break
		  ;;
  esac
done
}

daimon_user_home() {
	local name password uid gid comment home shell
	IFS=: read -r name password uid gid comment home shell < <(getent passwd "$1")
	[ "$name" = "$1" ] && [[ "$home" = /* ]] && [ -d "$home" ] && [ ! -L "$home" ] &&
		[ "$(stat -c %u -- "$home")" = "$uid" ] || { echo "用户主目录不存在、归属不符或不安全。" >&2; return 1; }
	printf '%s\n' "$home"
}

daimon_user_has_sudo_rules() {
	local rules status
	rules=$(LC_ALL=C sudo -n -lU "$1" 2>&1); status=$?
	if [ "$status" = 0 ] && LC_ALL=C grep -Eq '^[[:space:]]*\([^)]*\)[[:space:]]+[^[:space:]]' <<< "$rules"; then return 0; fi
	if [ "$status" -le 1 ] && grep -Fq "User $1 is not allowed to run sudo on " <<< "$rules"; then return 1; fi
	return 2
}

daimon_user_delete_home() {
	local username="$1" home users name password uid gid comment other_home shell mounts target
	daimon_regular_user_valid "$username" && [ "$username" != "${SUDO_USER:-${USER:-}}" ] || return 1
	IFS=: read -r name password uid gid comment home shell < <(getent passwd "$username")
	[ "$name" = "$username" ] && [[ "$home" = /*/* ]] && [ ! -L "$home" ] &&
		[ "$(realpath -m -- "$home")" = "$home" ] || return 1
	[ ! -e "$home" ] || { [ -d "$home" ] && [ "$(stat -c %u -- "$home")" = "$uid" ]; } || return 1
	users=$(getent passwd) && mounts=$(findmnt -rn -o TARGET) || return 1
	while IFS=: read -r name password uid gid comment other_home shell; do
		[ "$name" != "$username" ] && [[ "$other_home" = /* ]] || continue
		other_home=$(realpath -m -- "$other_home") || return 1
		[[ "$other_home" != "$home" && "$other_home" != "$home/"* ]] || {
			echo "主目录与其他账号共用，拒绝删除。" >&2; return 1
		}
	done <<< "$users"
	while IFS= read -r target; do
		target=$(printf '%b' "$target")
		[[ "$target" != "$home" && "$target" != "$home/"* ]] || {
			echo "主目录包含挂载点，请先卸载。" >&2; return 1
		}
	done <<< "$mounts"
	printf '%s\n' "$home"
}

daimon_user_sudo() (
	local action="$1" username="$2" file work main_tmp="" lockfd effective_uid had_group=0 had_file=0 mutating=0 committed=0
	local delete_home="" deleting=0 create_lock
	daimon_regular_user_valid "$username" || return 1
	case "$action" in grant|revoke|delete) ;; *) return 1 ;; esac
	if [ "$action" = delete ]; then
		delete_home=$(daimon_user_delete_home "$username") || return 1
	fi
	install sudo || return 1
	command -v visudo >/dev/null || return 1
	file="/etc/sudoers.d/$username"
	[ -f /etc/sudoers ] && [ ! -L /etc/sudoers ] && [ ! -L "$file" ] &&
		{ [ ! -e "$file" ] || [ -f "$file" ]; } || { echo "sudo 配置路径不安全，未修改。"; return 1; }
	mkdir -p "$DAIMON_ROOT_DIR" || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.users.lock" ] || return 1
	if [ "$action" = delete ]; then
		[ ! -L "$DAIMON_ROOT_DIR/.user-create.lock" ] || return 1
		exec {create_lock}> "$DAIMON_ROOT_DIR/.user-create.lock" || return 1
		flock -n "$create_lock" || return 1
	fi
	exec {lockfd}> "$DAIMON_ROOT_DIR/.users.lock" || return 1
	flock -n "$lockfd" || { echo "另一个用户权限操作正在进行。"; return 1; }
	if [ -f "$file" ]; then
		awk -v user="$username" '$1 ~ /^#include(dir)?$/ || (NF && $1 !~ /^#/ && $1 != user) {exit 1}' "$file" || { echo "该 sudo 文件包含其他规则，请手动核查。"; return 1; }
		had_file=1
	fi
	id -nG "$username" | grep -qw sudo && had_group=1
	work=$(mktemp -d /etc/sudoers.d/.daimon-user.XXXXXX) || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$deleting" = 1 ] && ! id "$username" >/dev/null 2>&1; then committed=1; fi
		if [ "$mutating" = 1 ] && [ "$committed" = 0 ]; then
			if ! cmp -s "$work/original-main" /etc/sudoers || [ "$(stat -c %a:%u:%g "$work/original-main")" != "$(stat -c %a:%u:%g /etc/sudoers)" ]; then
				cp -p -- "$work/original-main" "$main_tmp" && mv -Tf -- "$main_tmp" /etc/sudoers || { echo "sudo 配置恢复失败: $work"; exit 1; }
			fi
			if [ "$had_file" = 1 ]; then
				if ! cmp -s "$work/original-grant" "$file" || [ "$(stat -c %a:%u:%g "$work/original-grant")" != "$(stat -c %a:%u:%g "$file")" ]; then
					cp -p -- "$work/original-grant" "$work/restore" && mv -Tf -- "$work/restore" "$file" || { echo "sudo 规则恢复失败: $work"; exit 1; }
				fi
			else
				rm -f -- "$file" || { echo "sudo 规则恢复失败: $work"; exit 1; }
			fi
			if [ "$had_group" = 1 ]; then
				id -nG "$username" | grep -qw sudo || usermod -aG sudo "$username" || { echo "用户组恢复失败。"; exit 1; }
			elif id -nG "$username" | grep -qw sudo; then
				gpasswd -d "$username" sudo || { echo "用户组恢复失败。"; exit 1; }
			fi
		fi
		rm -f -- "$main_tmp" "$work/original-main" "$work/original-grant" "$work/grant" "$work/restore"
		rmdir -- "$work"
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	main_tmp=$(mktemp /etc/.daimon-sudoers.XXXXXX) || return 1
	cp -p -- /etc/sudoers "$work/original-main" || return 1
	[ "$had_file" = 0 ] || cp -p -- "$file" "$work/original-grant" || return 1
	if [ "$action" = grant ]; then
		printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > "$work/grant" || return 1
		chmod 440 "$work/grant" && chown 0:0 "$work/grant" && visudo -cf "$work/grant" || return 1
		mutating=1
		mv -Tf -- "$work/grant" "$file" && usermod -aG sudo "$username" || return 1
	else
		awk -v user="$username" '$1 != user' /etc/sudoers > "$main_tmp" || return 1
		chmod --reference=/etc/sudoers "$main_tmp" && chown --reference=/etc/sudoers "$main_tmp" && visudo -cf "$main_tmp" || return 1
		mutating=1
		mv -Tf -- "$main_tmp" /etc/sudoers && rm -f -- "$file" || return 1
		[ "$had_group" = 0 ] || gpasswd -d "$username" sudo || return 1
	fi
	visudo -cf /etc/sudoers || return 1
	if [ "$action" = grant ]; then
		effective_uid=$(runuser -u "$username" -- sudo -n -u root /usr/bin/id -u) && [ "$effective_uid" = 0 ] || {
			echo "sudo 授权未生效，将尝试恢复原配置。"; return 1
		}
	elif [ "$action" = delete ]; then
		if daimon_user_has_sudo_rules "$username"; then
			echo "仍存在其他 sudo 规则，请先处理后再删除账号。"; return 1
		elif [ "$?" != 1 ]; then
			echo "无法核查 sudo 规则，已取消删除账号。"; return 1
		fi
		[ "$(daimon_user_delete_home "$username")" = "$delete_home" ] || return 1
		deleting=1
		userdel -r "$username" || { echo "账号或主目录删除未完成，请核查实际状态。"; return 1; }
		! id "$username" >/dev/null 2>&1 && [ ! -e "$delete_home" ] && [ ! -L "$delete_home" ] || return 1
	fi
	committed=1
	if [ "$action" = revoke ]; then
		if daimon_user_has_sudo_rules "$username"; then
			echo "已移除该用户的直接授权和 sudo 组；仍检测到其他 sudo 规则，请手动核查。"
			return 1
		elif [ "$?" != 1 ]; then
			echo "已移除直接授权，但无法核查剩余 sudo 规则，请手动核查。"
			return 1
		fi
		echo "已取消用户 sudo 权限: $username"
	elif [ "$action" = delete ]; then
		echo "已删除账号及主目录: $username"
	else
		echo "已赋予 sudo 免密权限: $username"
	fi
)

create_user_with_sshkey() (
	local new_username="${1:-}" is_sudo="${2:-false}" sshkey_vl user_home home_base key_content work=""
	local creating=0 committed=0 uid="" status name password current_uid gid comment current_home shell
	local sudo_file="/etc/sudoers.d/$new_username"
	[[ "$new_username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "用户名格式无效"; return 1; }
	[[ "$is_sudo" = true || "$is_sudo" = false ]] || return 1
	mkdir -p "${DAIMON_ROOT_DIR:-/root/linux-daimon}" || return 1
	[ ! -L "${DAIMON_ROOT_DIR:-/root/linux-daimon}/.user-create.lock" ] || return 1
	exec {user_lock}>"${DAIMON_ROOT_DIR:-/root/linux-daimon}/.user-create.lock" || return 1
	flock -n "$user_lock" || { echo "其他用户管理任务正在运行。"; return 1; }
	if id "$new_username" >/dev/null 2>&1; then
		daimon_regular_user_valid "$new_username" || { echo "不能修改系统账号。"; return 1; }
		user_home=$(daimon_user_home "$new_username") || return 1
		echo "用户已存在: $new_username"
	else
		home_base=$(useradd -D) || return 1
		home_base=$(printf '%s\n' "$home_base" | sed -n 's/^HOME=//p')
		[[ "$home_base" = /* && "$home_base" != / ]] && [ -d "$home_base" ] || return 1
		home_base=$(realpath -e -- "$home_base") || return 1
		user_home="$home_base/$new_username"
		[ ! -e "$user_home" ] && [ ! -L "$user_home" ] || { echo "主目录已存在，拒绝接管或删除原有数据。"; return 1; }
		[ "$is_sudo" != true ] || { [ ! -e "$sudo_file" ] && [ ! -L "$sudo_file" ]; } || {
			echo "存在同名 sudo 规则，请先核查原有授权。"; return 1
		}
	fi
	echo "公钥可输入 URL 或完整 SSH 公钥；留空跳过。"
	read -r -e -p "请输入 ${new_username} 的公钥（可留空跳过）: " sshkey_vl || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$creating" = 1 ] && [ "$committed" = 0 ] && id "$new_username" >/dev/null 2>&1; then
			IFS=: read -r name password current_uid gid comment current_home shell < <(getent passwd "$new_username")
			if [ "$name" = "$new_username" ] && [ "$current_home" = "$user_home" ] &&
				{ [ -z "$uid" ] || [ "$uid" = "$current_uid" ]; } && daimon_regular_user_valid "$new_username"; then
				if [ "$is_sudo" = true ] && [ ! -L "$sudo_file" ] && [ -f "$sudo_file" ] &&
					cmp -s "$sudo_file" <(printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$new_username"); then
					rm -f -- "$sudo_file" || { echo "创建失败，sudo 规则未能清理: $sudo_file"; status=1; }
				fi
				if [ ! -e "$user_home" ] && [ ! -L "$user_home" ]; then
					userdel "$new_username" || status=1
				elif [ "$(daimon_user_home "$new_username")" = "$user_home" ]; then
					userdel -r "$new_username" || status=1
				fi
			fi
			if id "$new_username" >/dev/null 2>&1; then echo "创建失败，账号未能安全清理，请手动核查: $new_username"; status=1; fi
		fi
		if [ -n "$work" ]; then
			rm -f -- "$work/.ssh/authorized_keys"
			[ ! -d "$work/.ssh" ] || rmdir -- "$work/.ssh"
			rmdir -- "$work"
		fi
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	if [ -n "$sshkey_vl" ]; then
		work=$(mktemp -d) || return 1
		(
			sshkey_on() { :; }
			case "$sshkey_vl" in
				http://*|https://*) fetch_remote_ssh_keys "$sshkey_vl" "$work" ;;
				*) import_sshkey "$sshkey_vl" "$work" ;;
			esac
		) >/dev/null || { echo "公钥读取或校验失败，未修改用户。"; return 1; }
		key_content=$(cat "$work/.ssh/authorized_keys") || return 1
	fi
	if ! id "$new_username" >/dev/null 2>&1; then
		creating=1
		useradd -m -d "$user_home" -s /bin/bash "$new_username" || return 1
		uid=$(id -u "$new_username") || return 1
		[ "$(daimon_user_home "$new_username")" = "$user_home" ] || return 1
	fi
	if [ -n "$sshkey_vl" ]; then
		{
			declare -f ssh_public_key_valid ssh_import_key_file
			printf '%s\n' 'sshkey_on() { :; }' 'ssh_import_key_file <(printf "%s\n" "$1") "$2"'
		} | runuser -u "$new_username" -- bash --noprofile --norc -s -- "$key_content" "$user_home" || return 1
	fi
	[ "$is_sudo" != true ] || daimon_user_sudo grant "$new_username" || {
		[ "$creating" = 1 ] || echo "sudo 授权失败；已导入的用户公钥保留。"
		return 1
	}
	committed=1
	[ "$creating" = 0 ] || echo "已创建用户: $new_username"
)

daimon_env_name_valid() {
	local declaration
	[[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	declaration=$(declare -p "$1" 2>/dev/null) || return 0
	[[ ! "$declaration" =~ ^declare\ -[^\ ]*[raAinlu] ]]
}

daimon_env_write() {
	local file="$1" name="$2" staged value
	daimon_env_name_valid "$name" || return 1
	[ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
	[ -e "$file" ] || [ "$#" -gt 2 ] || return 0
	staged=$(mktemp "${file}.XXXXXX") || return 1
	if [ -f "$file" ]; then
		awk -v name="$name" '$0 !~ "^[[:space:]]*export[[:space:]]+" name "="' "$file" > "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	if [ "$#" -gt 2 ]; then
		value=${3//\'/\'\\\'\'}
		printf "export %s='%s'\n" "$name" "$value" >> "$staged" || { rm -f -- "$staged"; return 1; }
	fi
	daimon_config_commit "$file" "$staged" 600
}

env_menu() {
	local bashrc_file="$HOME/.bashrc"
	local profile_file="$HOME/.profile"

	show_env_vars() {
		clear
		echo "当前已生效环境变量（节选）"
		echo "------------------------------------------------"
		printf "%-20s %s\n" "变量名" "值"
		for v in USER HOME SHELL LANG PWD EDITOR VISUAL PATH; do
			printf "%-20s %s\n" "$v" "${!v}"
		done
		echo "------------------------------------------------"
		echo "~/.bashrc 中 export 项："
		grep -n '^export ' "$bashrc_file" 2>/dev/null || echo "无"
		echo "------------------------------------------------"
		echo "~/.profile 中 export 项："
		grep -n '^export ' "$profile_file" 2>/dev/null || echo "无"
	}

	add_env_var() {
		local name value target
		read -r -e -p "变量名（如 JAVA_HOME）: " name || return 1
		[ -z "$name" ] && return
		daimon_env_name_valid "$name" || { echo "变量名无效、只读或不是标量，未修改配置。"; return 1; }
		read -r -e -p "变量值: " value || return 1
		echo "1. 写入 ~/.bashrc（默认）"
		echo "2. 写入 ~/.profile"
		read -e -p "请选择写入位置: " target || return 1
		local file="$bashrc_file"
		case "$target" in
			""|1) ;;
			2) file="$profile_file" ;;
			*) echo "写入位置无效，未修改配置。"; return 1 ;;
		esac
		daimon_env_write "$file" "$name" "$value" || { echo "环境变量写入失败"; return 1; }
		echo "已写入配置: $file；新的 Shell 生效，当前工具箱环境保持不变。"
	}

	delete_env_var() {
		local name
		read -r -e -p "请输入要删除的变量名: " name || return 1
		[ -z "$name" ] && return
		daimon_env_name_valid "$name" || { echo "变量名无效、只读或不是标量。"; return 1; }
		daimon_env_write "$bashrc_file" "$name" && daimon_env_write "$profile_file" "$name" || { echo "环境变量配置删除失败"; return 1; }
		echo "已删除变量配置: $name；重新登录后生效，当前工具箱环境保持不变。"
	}

	while true; do
		clear
		echo "系统变量管理工具"
		echo "------------------------------------------------"
		echo "1. 查看当前环境变量"
		echo "2. 添加/修改环境变量"
		echo "3. 删除环境变量"
		echo "0. 返回上一级选单"
		echo "------------------------------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) show_env_vars ;;
			2) add_env_var ;;
			3) delete_env_var ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

github_proxy_sources_file() {
	echo "${DAIMON_SCRIPT_DIR:-/root/linux-daimon/daimon}/github_proxy_sources.txt"
}

github_proxy_init_sources() {
	local file staged
	file=$(github_proxy_sources_file)
	[ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
	mkdir -p "$(dirname "$file")" || return 1
	if [ ! -s "$file" ]; then
		staged=$(mktemp "${file}.XXXXXX") || return 1
		cat > "$staged" <<'EOF'
gh-proxy.com|https://gh-proxy.com/https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh
ghproxy.net|https://ghproxy.net/https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh
testingcf.jsdelivr.net|https://testingcf.jsdelivr.net/gh/komari-monitor/komari-agent@main/install.sh
ghfast.top|https://ghfast.top/https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh
EOF
		daimon_config_commit "$file" "$staged" || return 1
	fi
}

github_proxy_show_sources() {
	github_proxy_init_sources || return 1
	local file idx=1 name url
	file=$(github_proxy_sources_file)
	while IFS='|' read -r name url; do
		[ -z "$name" ] && continue
		printf "%2d. %-24s %s\n" "$idx" "$name" "$url"
		idx=$((idx + 1))
	done < "$file"
}

github_proxy_add_source() {
	github_proxy_init_sources || return 1
	local name url file staged
	file=$(github_proxy_sources_file)
	read -r -e -p "请输入镜像名称: " name || return 1
	read -r -e -p "请输入测速URL: " url || return 1
	if [ -z "$name" ] || [[ "$name" == *'|'* || "$name" =~ [[:cntrl:]] ]] || ! [[ "$url" =~ ^https?://[^[:space:]\|]+$ ]]; then
		echo "镜像名称或 URL 无效"; return 1
	fi
	staged=$(mktemp "${file}.XXXXXX") || return 1
	DAIMON_PROXY_NAME="$name" awk -F'|' '$1 != ENVIRON["DAIMON_PROXY_NAME"]' "$file" > "$staged" &&
		printf '%s|%s\n' "$name" "$url" >> "$staged" || { rm -f -- "$staged"; return 1; }
	daimon_config_commit "$file" "$staged" || return 1
	echo "已添加: $name"
}

github_proxy_delete_source() {
	github_proxy_init_sources || return 1
	local file num tmp count
	file=$(github_proxy_sources_file)
	github_proxy_show_sources
	read -e -p "请输入要删除的编号: " num || return 1
	[[ "$num" =~ ^[0-9]{1,6}$ ]] || return 1
	num=$((10#$num))
	count=$(awk 'NF {i++} END {print i+0}' "$file")
	[ "$num" -ge 1 ] && [ "$num" -le "$count" ] || { echo "编号不存在，未删除。"; return 1; }
	tmp=$(mktemp "${file}.XXXXXX") || return 1
	awk -F'|' -v n="$num" 'NF && ++i != n {print}' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
	daimon_config_commit "$file" "$tmp" || return 1
	echo "已删除编号: $num"
}

github_proxy_speed_test() (
	github_proxy_init_sources || return 1
	local file out idx name url tmp result http_code time_total speed size work curl_ok
	file=$(github_proxy_sources_file)
	work=$(mktemp -d) || return 1
	trap 'rm -rf -- "$work"' EXIT
	out="$work/ranking"
	: > "$out"
	echo "开始测速 GitHub 镜像源（小文件、短超时，下载后自动删除）..."
	idx=0
	while IFS='|' read -r name url; do
		[ -z "$name" ] && continue
		idx=$((idx + 1))
		tmp="$work/download"
		echo "== Testing: $name"
		curl_ok=0
		result=$(curl -L --connect-timeout 5 --max-time 15 --retry 0 -o "$tmp" -w "%{http_code} %{time_total} %{speed_download} %{size_download}" -s -- "$url") && curl_ok=1
		http_code=$(echo "$result" | awk '{print $1}')
		time_total=$(echo "$result" | awk '{print $2}')
		speed=$(echo "$result" | awk '{print $3}')
		size=$(echo "$result" | awk '{print $4}')
		if [ "$curl_ok" = 1 ] && [ "$http_code" = "200" ] && [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1000 ]; then
			printf "%s\t%s\t%s\t%s\t%s\n" "$speed" "$time_total" "$size" "$http_code" "$name" >> "$out"
			echo "OK  HTTP:$http_code  TIME:${time_total}s  SPEED:${speed}B/s  SIZE:${size}B"
		else
			printf "0\t%s\t%s\t%s\t%s\n" "$time_total" "$size" "$http_code" "$name" >> "$out"
			echo "FAIL  HTTP:$http_code  TIME:${time_total}s  SIZE:${size}B"
		fi
		rm -f "$tmp"
	done < "$file"
	echo "------------------------------------------------"
	echo "Speed ranking:"
	sort -nr "$out" | awk -F '\t' 'BEGIN{printf "%-4s %-28s %-12s %-10s %-10s %-8s\n","Rank","Proxy","Speed","Time","Size","HTTP"}{s=$1; if(s>=1048576){sf=sprintf("%.2f MB/s",s/1048576)}else if(s>=1024){sf=sprintf("%.2f KB/s",s/1024)}else{sf=sprintf("%.0f B/s",s)} printf "%-4d %-28s %-12s %-10ss %-10s %-8s\n",NR,$5,sf,$2,$3,$4}'
)

github_proxy_manager() {
	while true; do
		clear
		echo "github镜像源"
		echo "------------------------------------------------"
		echo "当前镜像源列表："
		github_proxy_show_sources
		echo "------------------------------------------------"
		echo "1. 添加镜像源"
		echo "2. 删除镜像源"
		echo "3. 测速"
		echo "0. 返回上一级选单"
		echo "------------------------------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) github_proxy_add_source ;;
			2) github_proxy_delete_source ;;
			3) github_proxy_speed_test ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

show_ssh_ip_info() {
	clear
	echo "查看ssh的ip"
	echo "------------------------------------------------"
	local current_ip="" current_port=""
	if [ -n "$SSH_CONNECTION" ]; then
		current_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
		current_port=$(echo "$SSH_CONNECTION" | awk '{print $2}')
	elif [ -n "$SSH_CLIENT" ]; then
		current_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
		current_port=$(echo "$SSH_CLIENT" | awk '{print $2}')
	else
		current_ip=$(who am i 2>/dev/null | awk -F'[()]' '{print $2}' | awk '{print $1}')
	fi

	echo "当前 SSH 连接IP："
	if [ -n "$current_ip" ]; then
		[ -n "$current_port" ] && echo "  $current_ip:$current_port" || echo "  $current_ip"
	else
		echo "  未检测到当前 SSH 连接IP（可能不是通过 SSH 登录）"
	fi

	echo "------------------------------------------------"
	echo "所有 SSH 连接地址："
	if command -v ss >/dev/null 2>&1; then
		ss -tnp 2>/dev/null | awk 'NR==1 || /sshd/ {print}' || true
	else
		netstat -tnp 2>/dev/null | awk 'NR==1 || /sshd/ {print}' || true
	fi
}

net_menu() {
	show_nics() {
		local path nic state ipaddr mac
		echo "================ 当前网卡信息 ================"
		printf "%-18s %-12s %-22s %-20s\n" "网卡名" "状态" "IPv4地址" "MAC地址"
		echo "------------------------------------------------"
		for path in /sys/class/net/*; do
			[ -e "$path" ] || continue
			nic=${path##*/}
			state=$(cat "/sys/class/net/$nic/operstate" 2>/dev/null)
			ipaddr=$(ip -4 addr show "$nic" 2>/dev/null | awk '/inet /{print $2}' | head -n1)
			mac=$(cat "/sys/class/net/$nic/address" 2>/dev/null)
			printf "%-18s %-12s %-22s %-20s\n" "$nic" "$state" "${ipaddr:-无}" "$mac"
		done
		echo "================================================"
	}
	while true; do
		clear
		show_nics
		echo ""
		echo "=========== 网卡管理菜单 ==========="
		echo "1. 启用网卡"
		echo "2. 禁用网卡"
		echo "3. 查看网卡详细信息"
		echo "4. 刷新网卡信息"
		echo "0. 返回上一级选单"
		echo "===================================="
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) read -e -p "请输入网卡名: " nic || return 1; [ -n "$nic" ] && ip link set "$nic" up ;;
			2) read -e -p "请输入网卡名: " nic || return 1; [ -n "$nic" ] && ip link set "$nic" down ;;
			3) read -e -p "请输入网卡名: " nic || return 1; [ -n "$nic" ] && { ip addr show "$nic"; echo; ethtool "$nic" 2>/dev/null || true; } ;;
			4) continue ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

daimon_journal_size_valid() {
	local value shifts=0
	[[ "$1" =~ ^([0-9]{1,18})([KMGTPE]?)$ ]] || return 1
	value=$((10#${BASH_REMATCH[1]}))
	case "${BASH_REMATCH[2]}" in K) shifts=1 ;; M) shifts=2 ;; G) shifts=3 ;; T) shifts=4 ;; P) shifts=5 ;; E) shifts=6 ;; esac
	while [ "$shifts" -gt 0 ]; do
		[ "$value" -le 9007199254740991 ] || return 1
		value=$((value * 1024)); shifts=$((shifts - 1))
	done
}

daimon_journal_configure() (
	local file=/etc/systemd/journald.conf.d/99-daimon-journal.conf work lockfd had_file=0 active=0
	local mutating=0 restart_attempted=0 committed=0 status value
	[ "$#" = 4 ] || return 1
	for value in "$1" "$2" "$3"; do
		daimon_journal_size_valid "$value" || { echo "日志大小无效，请使用字节数或 K/M/G/T/P/E 后缀。"; return 1; }
	done
	[[ "$4" != *$'\n'* && "$4" != *$'\r'* ]] && systemd-analyze timespan -- "$4" >/dev/null 2>&1 || {
		echo "日志保留时间无效。"; return 1
	}
	command -v systemctl >/dev/null || return 1
	[ ! -L "${file%/*}" ] && [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
	mkdir -p "${file%/*}" "$DAIMON_ROOT_DIR" || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.journal.lock" ] || return 1
	exec {lockfd}> "$DAIMON_ROOT_DIR/.journal.lock" || return 1
	flock -n "$lockfd" || return 1
	systemctl is-active --quiet systemd-journald && active=1
	work=$(mktemp -d "${file%/*}/.daimon-journal.XXXXXX") || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$mutating" = 1 ] && [ "$committed" = 0 ]; then
			if [ "$had_file" = 1 ]; then
				if ! cmp -s "$work/original" "$file"; then
					cp -p -- "$work/original" "$work/restore" && mv -Tf -- "$work/restore" "$file" || { echo "日志配置恢复失败: $work"; exit 1; }
				fi
			else
				rm -f -- "$file" || { echo "日志配置恢复失败: $work"; exit 1; }
			fi
			if [ "$restart_attempted" = 1 ]; then
				systemctl restart systemd-journald && systemctl is-active --quiet systemd-journald || {
					echo "原日志配置已恢复，但服务恢复未能确认，请手动核查。"; status=1
				}
			fi
		fi
		rm -f -- "$work/original" "$work/config" "$work/restore" && rmdir -- "$work" || status=1
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	if [ -f "$file" ]; then
		had_file=1
		cp -p -- "$file" "$work/original" || return 1
	else
		: > "$work/original" || return 1
	fi
	awk '
		BEGIN {print "[Journal]"}
		/^[[:space:]]*\[/ {if ($0 !~ /^[[:space:]]*\[Journal\][[:space:]]*$/) exit 1; next}
		/^[[:space:]]*(SystemMaxUse|SystemKeepFree|SystemMaxFileSize|MaxRetentionSec)[[:space:]]*=/ {next}
		{print}
	' "$work/original" > "$work/config" || return 1
	printf 'SystemMaxUse=%s\nSystemKeepFree=%s\nSystemMaxFileSize=%s\nMaxRetentionSec=%s\n' "$1" "$2" "$3" "$4" >> "$work/config" || return 1
	mutating=1
	daimon_config_commit "$file" "$work/config" || return 1
	if [ "$active" = 1 ]; then
		restart_attempted=1
		systemctl restart systemd-journald && systemctl is-active --quiet systemd-journald || return 1
	fi
	committed=1
	echo "日志配置已更新: $file"
	[ "$active" = 1 ] || echo "日志服务原先未运行；配置将在下次启动时生效。"
)

journalctl_log_manager() {
	root_use
	while true; do
		clear
		echo "journalctl日志管理"
		echo "------------------------------------------------"
		echo "1. 配置自动清理（默认最多500M、保留1G空闲、单文件50M、保留1个月）"
		echo "2. 查看日志磁盘占用大小"
		echo "3. 查看某服务的日志（最后200条）"
		echo "4. 按时间保留日志（默认7天）"
		echo "5. 按大小保留日志（默认500M）"
		echo "0. 返回上一级菜单"
		echo "------------------------------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1)
				local system_max_use system_keep_free system_max_file_size max_retention_sec
				echo "收紧日志限制可能清理旧日志；恢复配置不能找回已删除的日志。"
				read -e -p "SystemMaxUse 最大总占用（默认 500M）: " system_max_use || return 1
				system_max_use=${system_max_use:-500M}
				read -e -p "SystemKeepFree 系统至少保留空闲空间（默认 1G）: " system_keep_free || return 1
				system_keep_free=${system_keep_free:-1G}
				read -e -p "SystemMaxFileSize 单个 journal 文件最大大小（默认 50M）: " system_max_file_size || return 1
				system_max_file_size=${system_max_file_size:-50M}
				read -e -p "MaxRetentionSec 最长保留时间（默认 1month）: " max_retention_sec || return 1
				max_retention_sec=${max_retention_sec:-1month}
				daimon_journal_configure "$system_max_use" "$system_keep_free" "$system_max_file_size" "$max_retention_sec" || echo "日志配置未完成，请检查上方错误。"
				;;
			2) journalctl --disk-usage ;;
			3) read -e -p "请输入服务名（可不带 .service）: " svc || return 1; [ -z "$svc" ] && continue; [[ "$svc" != *.service ]] && svc="$svc.service"; journalctl -u "$svc" -n 200 --no-pager ;;
			4) read -e -p "保留时间（默认 7d）: " t || return 1; journalctl --vacuum-time="${t:-7d}" ;;
			5) read -e -p "保留大小（默认 500M）: " z || return 1; journalctl --vacuum-size="${z:-500M}" ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

system_ipv6_status() {
	echo "------------------------------------------------"
	echo "IPv6 当前状态（disable_ipv6: 0=允许，1=禁用；不代表公网连通性）："
	local path value found=0
	for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
		[ -e "$path" ] || continue
		found=1
		if read -r value < "$path"; then printf '%s = %s\n' "$path" "$value"; else echo "无法读取: $path"; return 1; fi
	done
	[ "$found" = 1 ] || { echo "内核未提供 IPv6 控制接口。"; return 1; }
	ip -6 addr show scope global
}

daimon_ipv6_network_policy() {
	python3 - "$@" <<'PY'
import hashlib, json, os, re, stat, subprocess, sys, tempfile
from pathlib import Path
action, directory, value = sys.argv[1:]
work = Path(directory)
marker = "# Managed by daimon IPv6 policy v1\n"
roots = [Path(p) for p in ("/usr/lib/systemd/network", "/usr/local/lib/systemd/network", "/run/systemd/network", "/etc/systemd/network")]
name = "99-daimon-ipv6.conf"
def command(*args):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, env=dict(os.environ, LC_ALL="C", SYSTEMD_COLORS="0"))
def safe(path):
    if path.is_symlink() or path.resolve() != path: raise ValueError("Unsafe network path: " + str(path))
    for entry in (path, *path.parents):
        if entry.exists():
            st = entry.stat()
            if st.st_uid or st.st_mode & 0o022: raise ValueError("Untrusted network path: " + str(entry))
def contents(path):
    safe(path)
    if not path.exists(): return None
    st = path.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1: raise ValueError("Not a private regular network file")
    return path.read_text()
def save(path, text):
    safe(path)
    if text is None:
        path.unlink(missing_ok=True)
        try: path.parent.rmdir()
        except OSError: pass
        return
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".daimon-ipv6-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f: f.write(text)
        os.chmod(tmp, 0o644); os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)
try:
    planfile = work / "network-plan.json"
    if action == "plan":
        if command("systemctl", "is-active", "--quiet", "NetworkManager").returncode == 0:
            raise ValueError("NetworkManager ownership requires explicit per-connection configuration; no changes")
        if command("systemctl", "is-active", "--quiet", "systemd-networkd").returncode != 0:
            raise ValueError("No supported active network manager; persistent IPv6 change refused")
        records = {}; interfaces = []
        for interface in sorted(Path("/sys/class/net").iterdir()):
            if interface.name == "lo": continue
            status = command("networkctl", "status", "--no-pager", "--no-legend", interface.name)
            if status.returncode: raise ValueError("Cannot inspect network ownership: " + interface.name)
            match = re.search(r"Network File:\s+(/[^\n]+)", status.stdout)
            if not match:
                if (interface / "device").exists(): raise ValueError("Unmanaged physical interface: " + interface.name)
                continue
            main = Path(match[1].strip())
            if main.parent not in roots or main.suffix != ".network": raise ValueError("Unknown network profile")
            text = contents(main)
            if text is None or "\\\n" in text: raise ValueError("Unsupported network profile syntax")
            override = roots[-1] / (main.name + ".d") / name
            old = contents(override)
            if old is not None and not re.fullmatch(re.escape(marker) + r"\[Network\]\nDHCP=(?:ipv4|no)\nLinkLocalAddressing=(?:ipv4|no)\nIPv6AcceptRA=no\n", old):
                raise ValueError("Foreign IPv6 override retained")
            for root in roots:
                for folder in [root / (main.name + ".d"), root / ".network.d", root / "10-.network.d", root / "10-netplan-.network.d"]:
                    for drop in folder.glob("*.conf"):
                        if drop != override: raise ValueError("Additional network drop-ins require manual review: " + str(drop))
            options = {}; section = ""
            for line in text.splitlines():
                line = line.strip()
                if not line or line.startswith(("#", ";")): continue
                if line.startswith("["): section = line; continue
                if "=" not in line: raise ValueError("Unknown network directive")
                key, val = (part.strip() for part in line.split("=", 1))
                if key in ("Address", "Gateway", "Destination", "Source", "PreferredSource") and ":" in val:
                    raise ValueError("Static IPv6 must be reviewed before disabling")
                if section == "[Network]": options[key] = val
            if any(options.get(k) for k in ("Bridge", "Bond", "VLAN", "Tunnel")) or options.get("IPv6SendRA", "no") not in ("no", "false", "0"):
                raise ValueError("Routed or stacked network profile requires manual review")
            dhcp = options.get("DHCP", "no"); link = options.get("LinkLocalAddressing", "ipv6")
            if dhcp not in ("yes", "true", "1", "no", "false", "0", "ipv4", "ipv6") or link not in ("yes", "true", "1", "no", "false", "0", "ipv4", "ipv6"):
                raise ValueError("Unsupported dynamic addressing mode")
            new = marker + "[Network]\nDHCP=" + ("ipv4" if dhcp in ("yes", "true", "1", "ipv4") else "no") + "\nLinkLocalAddressing=" + ("ipv4" if link in ("yes", "true", "1", "ipv4") else "no") + "\nIPv6AcceptRA=no\n"
            records[str(override)] = {"old": old, "new": new if value == "1" else None, "source": str(main), "hash": hashlib.sha256(text.encode()).hexdigest()}
            interfaces.append(interface.name)
        if not interfaces: raise ValueError("No supported managed interface found")
        # Do not silently leave a policy attached to an old renamed profile.
        for old in roots[-1].glob("*.network.d/" + name):
            if str(old) not in records: raise ValueError("Stale IPv6 policy needs explicit review: " + str(old))
        planfile.write_text(json.dumps({"records": records, "interfaces": interfaces}))
    elif action in ("apply", "restore"):
        plan = json.loads(planfile.read_text())
        if action == "apply":
            for target, record in plan["records"].items():
                if contents(Path(target)) != record["old"] or hashlib.sha256(contents(Path(record["source"])).encode()).hexdigest() != record["hash"]:
                    raise ValueError("Network configuration changed concurrently")
        for target, record in plan["records"].items():
            path = Path(target); current = contents(path)
            if action == "restore" and current not in (record["old"], record["new"]):
                raise ValueError("Concurrent network policy retained instead of overwriting")
            wanted = record["new" if action == "apply" else "old"]
            if current != wanted: save(path, wanted)
        result = command("networkctl", "reload")
        if result.returncode: raise ValueError("networkctl reload failed")
        for interface in plan["interfaces"]:
            result = command("networkctl", "reconfigure", interface)
            if result.returncode: raise ValueError("networkctl reconfigure failed: " + interface)
    else: raise ValueError("Unknown network policy action")
except (OSError, ValueError, subprocess.TimeoutExpired) as error:
    print("IPv6 network policy: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

daimon_ipv6_configure() (
	local value="$1" file=/etc/sysctl.d/99-daimon-ipv6.conf work lockfd path current status
	local had_file=0 mutating=0 runtime_started=0 committed=0 restore_failed=0 network_started=0
	local -a paths=()
	local -A original=()
	[[ "$value" = 0 || "$value" = 1 ]] || return 1
	if [ "$value" = 1 ] && [[ "${SSH_CONNECTION:-} ${SSH_CLIENT:-}" = *:* ]]; then
		echo "拒绝在 IPv6 SSH 连接中禁用 IPv6，请改用 IPv4 SSH 或控制台。"; return 1
	fi
	command -v sysctl >/dev/null && command -v ip >/dev/null && command -v flock >/dev/null || return 1
	for path in all default lo; do
		[ -f "/proc/sys/net/ipv6/conf/$path/disable_ipv6" ] || { echo "内核未提供 IPv6 控制接口。"; return 1; }
	done
	[ ! -L "${file%/*}" ] && [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || return 1
	mkdir -p "${file%/*}" "$DAIMON_ROOT_DIR" || return 1
	[ ! -L "$DAIMON_ROOT_DIR/.ipv6.lock" ] || return 1
	exec {lockfd}> "$DAIMON_ROOT_DIR/.ipv6.lock" || return 1
	flock -n "$lockfd" || return 1
	for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
		read -r current < "$path" && [[ "$current" = 0 || "$current" = 1 ]] && [ -w "$path" ] || return 1
		paths+=("$path"); original["$path"]=$current
	done
	work=$(mktemp -d "${file%/*}/.daimon-ipv6.XXXXXX") || return 1
	trap '
		status=$?
		trap "" INT TERM HUP
		if [ "$mutating" = 1 ] && [ "$committed" = 0 ]; then
			if [ "$had_file" = 1 ]; then
				if ! cmp -s "$work/original" "$file"; then
					cp -p -- "$work/original" "$work/restore" && mv -Tf -- "$work/restore" "$file" || restore_failed=1
				fi
			else
				rm -f -- "$file" || restore_failed=1
			fi
			if [ "$network_started" = 1 ]; then daimon_ipv6_network_policy restore "$work" "$value" || restore_failed=1; fi
			if [ "$runtime_started" = 1 ]; then
				for path in "${paths[@]}"; do
					if read -r current < "$path" && [ "$current" != "${original[$path]}" ]; then
						printf "%s\n" "${original[$path]}" > "$path" || restore_failed=1
					fi
					read -r current < "$path" && [ "$current" = "${original[$path]}" ] || restore_failed=1
				done
				echo "IPv6 修改失败，已尝试恢复原配置和开关；被删除的地址、路由及中断的连接无法自动恢复，请通过控制台或 IPv4 核查网络配置。"
			fi
		fi
		if [ "$restore_failed" = 1 ]; then echo "IPv6 恢复失败，请核查临时恢复文件: $work"; exit 1; fi
		rm -f -- "$work/original" "$work/config" "$work/apply" "$work/restore" "$work/network-plan.json" && rmdir -- "$work" || status=1
		exit "$status"
	' EXIT
	trap 'exit 1' INT TERM HUP
	if [ -f "$file" ]; then had_file=1; cp -p -- "$file" "$work/original" || return 1; else : > "$work/original" || return 1; fi
	awk '
		/^[[:space:]]*($|[#;])/ {print; next}
		/^[[:space:]]*net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=/ {next}
		{exit 1}
	' "$work/original" > "$work/config" || { echo "IPv6 配置包含非工具箱设置，未修改。"; return 1; }
	printf "net.ipv6.conf.all.disable_ipv6 = %s\nnet.ipv6.conf.default.disable_ipv6 = %s\nnet.ipv6.conf.lo.disable_ipv6 = %s\n" "$value" "$value" "$value" > "$work/apply" || return 1
	cat "$work/apply" >> "$work/config" || return 1
	daimon_ipv6_network_policy plan "$work" "$value" || return 1
	mutating=1
	daimon_config_commit "$file" "$work/config" || return 1
	network_started=1
	if [ "$value" = 1 ]; then daimon_ipv6_network_policy apply "$work" "$value" || return 1; fi
	runtime_started=1
	sysctl -p "$work/apply" || return 1
	if [ "$value" = 0 ]; then daimon_ipv6_network_policy apply "$work" "$value" || return 1; fi
	for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
		read -r current < "$path" && [ "$current" = "$value" ] || { echo "IPv6 状态校验失败: $path"; return 1; }
	done
	committed=1
)

system_disable_ipv6() {
	root_use
	echo "禁用 IPv6 会删除接口上的 IPv6 地址和路由、中断相关连接；失败时也无法自动恢复这些网络状态。"
	daimon_ipv6_configure 1 || { echo "IPv6 禁用未完成，请检查上方错误。"; return 1; }
	echo -e "${gl_lv}IPv6 已禁用。配置文件: /etc/sysctl.d/99-daimon-ipv6.conf${gl_bai}"
	system_ipv6_status || return 1
}

system_enable_ipv6() {
	root_use
	daimon_ipv6_configure 0 || { echo "IPv6 开启未完成，请检查上方错误。"; return 1; }
	echo -e "${gl_lv}IPv6 已开启。配置文件: /etc/sysctl.d/99-daimon-ipv6.conf${gl_bai}"
	echo "允许 IPv6 不等于恢复静态地址、路由或公网连通性；请核查网络管理器配置。"
	system_ipv6_status || return 1
}

daimon_hosts_edit() {
	local action="$1" value="$2" file=/etc/hosts staged
	[ ! -L "$file" ] && [ -f "$file" ] || return 1
	[ -n "$value" ] || return 1
	command -v python3 >/dev/null 2>&1 || { install python3 || return 1; }
	staged=$(mktemp "${file}.XXXXXX") || return 1
	if ! python3 -c 'import ipaddress, re, sys
action, value = sys.argv[1:]
text = sys.stdin.read()
if any(c in value for c in "\r\n\0"):
    raise SystemExit("Invalid hosts record")
if action == "delete":
    result = "".join(line for line in text.splitlines(keepends=True) if value not in line)
elif action == "add":
    fields = value.split("#", 1)[0].split()
    if len(fields) < 2:
        raise SystemExit("Expected an IP address and host names")
    ipaddress.ip_address(fields[0])
    for host in fields[1:]:
        if len(host) > 253 or not re.fullmatch(r"[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_.])?", host):
            raise SystemExit("Invalid host name")
    exists = any(line.split("#", 1)[0].split() == fields for line in text.splitlines())
    result = text if exists else text + ("\n" if text and not text.endswith("\n") else "") + value + "\n"
else:
    raise SystemExit("Invalid hosts operation")
sys.stdout.write(result)' "$action" "$value" < "$file" > "$staged"; then
		rm -f -- "$staged"
		echo "hosts 修改失败，原文件未改变。"
		return 1
	fi
	daimon_config_commit "$file" "$staged"
}

daimon_set_hostname() (
	local name="$1" old staged host_file=/etc/hostname hosts_file=/etc/hosts
	local runtime_changed=0 host_changed=0 hosts_changed=0
	[[ ${#name} -le 64 && "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || { echo "主机名无效"; return 1; }
	[ ! -L "$host_file" ] && [ ! -L "$hosts_file" ] && [ -f "$host_file" ] && [ -f "$hosts_file" ] || return 1
	old=$(uname -n) || return 1
	staged=$(mktemp -d "${host_file%/*}/.daimon-hostname.XXXXXX") || return 1
	cleanup_hostname() {
		local status=$?
		if [ "$status" != 0 ]; then
			if [ "$host_changed" = 1 ]; then
				daimon_config_commit "$host_file" "$staged/original-hostname" || echo "ERROR: 主机名文件恢复失败" >&2
			fi
			if [ "$hosts_changed" = 1 ]; then
				daimon_config_commit "$hosts_file" "$staged/original-hosts" || echo "ERROR: hosts 文件恢复失败" >&2
			fi
			if [ "$runtime_changed" = 1 ]; then
				hostname "$old" && [ "$(uname -n)" = "$old" ] || echo "ERROR: 运行时主机名恢复失败" >&2
			fi
		fi
		case "$staged" in "${host_file%/*}"/.daimon-hostname.*) rm -rf -- "$staged" ;; esac
		exit "$status"
	}
	trap cleanup_hostname EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM HUP
	cp -p -- "$host_file" "$staged/original-hostname" && cp -p -- "$hosts_file" "$staged/original-hosts" || return 1
	printf '%s\n' "$name" > "$staged/new-hostname" || return 1
	awk -v old="$old" -v name="$name" '
		$1=="127.0.0.1" || $1=="127.0.1.1" || $1=="::1" {
			for (i=2;i<=NF && $i !~ /^#/;i++) {
				if ($i==old) {$i=name; found=1}
				if ($i==name) found=1
			}
		}
		{print}
		END {if (!found) print "127.0.1.1 " name}' "$hosts_file" > "$staged/new-hosts" || return 1
	runtime_changed=1
	hostname "$name" && [ "$(uname -n)" = "$name" ] || return 1
	host_changed=1
	daimon_config_commit "$host_file" "$staged/new-hostname" || return 1
	hosts_changed=1
	daimon_config_commit "$hosts_file" "$staged/new-hosts" || return 1
	echo "主机名已更改为: $name"
	return 0
)

daimon_shortcut_available() {
	local name="$1" path
	[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || return 1
	for path in "/usr/local/bin/$name" "/usr/bin/$name"; do
		if [ -e "$path" ] || [ -L "$path" ]; then
			[ "$(readlink -f -- "$path")" = /usr/local/bin/d ] || return 1
		fi
	done
}

daimon_set_shortcut() (
	local name="$1" path staged="" i committed=0
	local -a paths=() previous=() changed=() obsolete=()
	daimon_shortcut_available "$name" || return 1
	[ -f /usr/local/bin/d ] && [ ! -L /usr/local/bin/d ] || return 1
	for path in "/usr/local/bin/$name" "/usr/bin/$name"; do
		[ "$path" != /usr/local/bin/d ] || continue
		paths+=("$path")
		previous+=("$(readlink -- "$path" 2>/dev/null || true)")
	done
	trap '
		if [ "$committed" = 0 ]; then
			for i in "${changed[@]}"; do
				if [ -n "${previous[i]}" ]; then
					ln -sfnT -- "${previous[i]}" "${paths[i]}" || echo "快捷键恢复失败: ${paths[i]}" >&2
				else
					rm -f -- "${paths[i]}"
				fi
			done
		fi
		[ -z "$staged" ] || { rm -f -- "$staged/link"; rmdir -- "$staged"; }
	' EXIT
	trap 'exit 1' INT TERM HUP
	for i in "${!paths[@]}"; do
		path=${paths[i]}
		staged=$(mktemp -d "${path}.XXXXXX") || return 1
		ln -s /usr/local/bin/d "$staged/link" || return 1
		changed+=("$i")
		mv -Tf -- "$staged/link" "$path" || return 1
		rmdir -- "$staged" || return 1
		staged=""
	done
	committed=1
	while IFS= read -r -d '' path; do
		case "$path" in /usr/local/bin/d|/usr/bin/d|"/usr/local/bin/$name"|"/usr/bin/$name") continue ;; esac
		[ "$(readlink -f -- "$path")" != /usr/local/bin/d ] || obsolete+=("$path")
	done < <(find /usr/local/bin /usr/bin -maxdepth 1 -type l -print0)
	[ "${#obsolete[@]}" = 0 ] || rm -f -- "${obsolete[@]}" || { echo "新快捷键已创建，但部分旧快捷键未能删除。"; return 1; }
)

daimon_regular_user_valid() {
	local uid
	[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
	uid=$(id -u -- "$1" 2>/dev/null) || return 1
	[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ]
}

daimon_uninstall_toolbox() {
	[ "$(id -u)" = 0 ] || { echo "请以 root 身份卸载工具箱。"; return 1; }
	local path target
	local -a files=() links=()
	for path in "$DAIMON_LOCAL_SCRIPT" "$DAIMON_OLD_LOCAL_SCRIPT" /usr/local/bin/d /usr/bin/d; do
		if [ -L "$path" ]; then
			target=$(readlink -m -- "$path") || return 1
			case "$target" in /usr/local/bin/d|"$DAIMON_LOCAL_SCRIPT"|"$DAIMON_OLD_LOCAL_SCRIPT") ;; *) echo "拒绝删除非工具箱链接: $path"; return 1 ;; esac
		elif [ -e "$path" ]; then
			[ -f "$path" ] && grep -qxF 'DAIMON_NAME="linux-tools-daimon"' "$path" || { echo "拒绝删除无法确认归属的文件: $path"; return 1; }
		fi
	done
	for path in /usr/local/bin/* /usr/bin/*; do
		[ -L "$path" ] || continue
		target=$(readlink -m -- "$path") || return 1
		case "$target" in /usr/local/bin/d|"$DAIMON_LOCAL_SCRIPT"|"$DAIMON_OLD_LOCAL_SCRIPT") links+=("$path") ;; esac
	done
	for path in "$DAIMON_LOCAL_SCRIPT" "$DAIMON_OLD_LOCAL_SCRIPT" /usr/bin/d /usr/local/bin/d; do
		[ ! -e "$path" ] && [ ! -L "$path" ] || files+=("$path")
	done
	for path in "${links[@]}" "${files[@]}"; do
		rm -f -- "$path" && [ ! -e "$path" ] && [ ! -L "$path" ] || { echo "脚本卸载未完成，请处理错误后重试；未删除其他服务或定时任务。"; return 1; }
	done
}

linux_Settings() {
	while true; do
		clear
		echo -e "系统工具"
		echo -e "${gl_kjlan}------------------------"
		# 使用 ANSI 光标定位对齐第二列，避免中文宽字符导致空格补齐不稳定
		printf "%b\033[55G%b\n" "${gl_kjlan}1.   ${gl_bai}设置脚本启动快捷键" "${gl_kjlan}2.   ${gl_bai}更换系统软件包镜像源"
		printf "%b\033[55G%b\n" "${gl_kjlan}3.   ${gl_bai}优化DNS地址" "${gl_kjlan}4.   ${gl_bai}切换优先ipv4/ipv6"
		printf "%b\033[55G%b\n" "${gl_kjlan}5.   ${gl_bai}修改虚拟内存大小" "${gl_kjlan}6.   ${gl_bai}用户管理"
		printf "%b\033[55G%b\n" "${gl_kjlan}7.   ${gl_bai}系统时区调整" "${gl_kjlan}8.   ${gl_bai}修改主机名"
		printf "%b\033[55G%b\n" "${gl_kjlan}9.   ${gl_bai}本机host解析" "${gl_kjlan}10.  ${gl_bai}系统变量管理工具"
		printf "%b\033[55G%b\n" "${gl_kjlan}11.  ${gl_bai}github镜像源" "${gl_kjlan}12.  ${gl_bai}查看ssh的ip"
		printf "%b\033[55G%b\n" "${gl_kjlan}13.  ${gl_bai}网卡管理工具" "${gl_kjlan}14.  ${gl_bai}journalctl日志管理"
		printf "%b\033[55G%b\n" "${gl_kjlan}15.  ${gl_bai}网络自适应优化（转到主菜单21）" "${gl_kjlan}16.  ${gl_bai}禁用IPv6"
		printf "%b\033[55G%b\n" "${gl_kjlan}17.  ${gl_bai}开启IPv6" "${gl_kjlan}18.  ${gl_bai}设置本地语言"
		printf "%b\033[55G%b\n" "${gl_kjlan}19.  ${gl_bai}Docker镜像源测速" "${gl_kjlan}20.  ${gl_bai}卸载daimon脚本"
		echo -e "${gl_kjlan}------------------------"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1

		case "$sub_choice" in
			1)
				while true; do
					clear
					read -e -p "请输入你的快捷按键（默认 d，输入0退出）: " kuaijiejian || return 1
					kuaijiejian=${kuaijiejian:-d}
					[ "$kuaijiejian" = "0" ] && break
					if ! daimon_shortcut_available "$kuaijiejian"; then
						echo "快捷键无效或与现有命令冲突，未修改任何文件。"
						break_end; continue
					fi
					root_use
					if ! daimon_set_shortcut "$kuaijiejian"; then
						echo "快捷键创建失败"; break_end; continue
					fi
					echo "快捷键已设置: $kuaijiejian"
					break_end
					break
				done
				;;
			2)
				root_use
				clear
				echo "更换系统软件包镜像源"
				echo "下载并校验后执行 LinuxMirrors 脚本；下载失败时不会执行部分内容。"
				daimon_run_cached_script "https://linuxmirrors.cn/main.sh" "linuxmirrors-main.sh"
				break_end
				;;
			3) set_dns_ui ;;
			4)
				root_use
				while true; do
					clear
					echo "设置v4/v6优先级"
					echo "------------------------"
					if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100\s*$' /etc/gai.conf 2>/dev/null; then
						echo -e "当前网络优先级设置: ${gl_huang}IPv4${gl_bai} 优先"
					else
						echo -e "当前网络优先级设置: ${gl_huang}IPv6${gl_bai} 优先"
					fi
					echo ""
					echo "------------------------"
					echo "1. IPv4 优先          2. IPv6 优先          3. IPv6 修复工具"
					echo "------------------------"
					echo "0. 返回上一级选单"
					echo "------------------------"
					read -e -p "选择优先的网络: " choice || return 1
					case "$choice" in
						1) prefer_ipv4 ;;
						2) prefer_ipv6 ;;
						3) clear; daimon_run_cached_script "https://jhb.ovh/jb/v6.sh" "jhb-v6.sh"; echo "该功能由jhb大神提供，感谢他！" ;;
						0) break ;;
						*) echo "无效的输入!" ;;
					esac
					break_end_unless "$choice" 0
				done
				;;
			5)
				root_use
				while true; do
					clear
					echo "设置虚拟内存"
					local swap_used swap_total swap_info
					swap_used=$(free -m | awk 'NR==3{print $3}')
					swap_total=$(free -m | awk 'NR==3{print $2}')
					swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')
					echo -e "当前虚拟内存: ${gl_huang}$swap_info${gl_bai}"
					echo "------------------------"
					echo "1. 分配1024M         2. 分配2048M         3. 分配4096M         4. 自定义大小"
					echo "5. 删除虚拟内存（删除 /swapfile）"
					echo "------------------------"
					echo "0. 返回上一级选单"
					echo "------------------------"
					read -e -p "请输入你的选择: " choice || return 1
					case "$choice" in
						1) add_swap 1024 ;;
						2) add_swap 2048 ;;
						3) add_swap 4096 ;;
						4) read -e -p "请输入虚拟内存大小（单位M）: " new_swap || return 1; [ -n "$new_swap" ] && add_swap "$new_swap" ;;
						5) delete_swap ;;
						0) break ;;
						*) echo "无效的输入!" ;;
					esac
					break_end_unless "$choice" 0
				done
				;;
			6)
				while true; do
					root_use
					clear
					echo "用户列表"
					echo "----------------------------------------------------------------------------"
					printf "%-24s %-34s %-20s %-10s\n" "用户名" "用户目录" "用户组" "sudo规则"
					while IFS=: read -r username _ userid groupid _ homedir shell; do
						[ "$userid" -lt 1000 ] && [ "$username" != "root" ] && continue
						local groups sudo_status
						groups=$(groups "$username" 2>/dev/null | cut -d : -f 2)
						if ! command -v sudo >/dev/null 2>&1; then
							sudo_status="Unknown"
						elif daimon_user_has_sudo_rules "$username"; then
							sudo_status="Yes"
						elif [ "$?" != 1 ]; then
							sudo_status="Unknown"
						else
							sudo_status="No"
						fi
						printf "%-24s %-34s %-20s %-10s\n" "$username" "$homedir" "$groups" "$sudo_status"
					done < /etc/passwd
					echo ""
					echo "账户操作"
					echo "------------------------"
					echo "1. 创建普通用户             2. 创建高级用户（含sudo权限）"
					echo "------------------------"
					echo "3. 赋予最高权限             4. 取消最高权限"
					echo "------------------------"
					echo "5. 删除账号"
					echo "------------------------"
					echo "0. 返回上一级选单"
					echo "------------------------"
					read -e -p "请输入你的选择: " choice || return 1
					case "$choice" in
						1) read -e -p "请输入新用户名: " new_username || return 1; [ -n "$new_username" ] && create_user_with_sshkey "$new_username" false ;;
						2) read -e -p "请输入新用户名: " new_username || return 1; [ -n "$new_username" ] && create_user_with_sshkey "$new_username" true ;;
						3) read -e -p "请输入用户名: " username || return 1; daimon_user_sudo grant "$username" ;;
						4) read -e -p "请输入用户名: " username || return 1; daimon_user_sudo revoke "$username" ;;
						5)
							read -e -p "请输入要删除的用户名: " username || return 1
							if ! daimon_regular_user_valid "$username" || [ "$username" = "${SUDO_USER:-${USER:-}}" ]; then
								echo "不能删除系统账号、不存在的账号或当前登录账号。"
							else
								read -e -p "再次输入用户名确认删除账号及其主目录: " confirm_user || return 1
								[ "$confirm_user" = "$username" ] && daimon_user_sudo delete "$username"
							fi
							;;
						0) break ;;
						*) echo "无效的输入!" ;;
					esac
					break_end_unless "$choice" 0
				done
				;;
			7)
				root_use
				while true; do
					clear
					echo "系统时间信息"
					local timezone current_time
					timezone=$(current_timezone)
					current_time=$(date +"%Y-%m-%d %H:%M:%S")
					echo "当前系统时区：$timezone"
					echo "当前系统时间：$current_time"
					echo ""
					echo "时区切换"
					echo "------------------------"
					echo "亚洲"
					echo "1.  中国上海时间             2.  中国香港时间"
					echo "3.  日本东京时间             4.  韩国首尔时间"
					echo "5.  新加坡时间               6.  印度加尔各答时间"
					echo "7.  阿联酋迪拜时间           8.  澳大利亚悉尼时间"
					echo "9.  泰国曼谷时间"
					echo "------------------------"
					echo "欧洲"
					echo "11. 英国伦敦时间             12. 法国巴黎时间"
					echo "13. 德国柏林时间             14. 俄罗斯莫斯科时间"
					echo "15. 荷兰阿姆斯特丹时间       16. 西班牙马德里时间"
					echo "------------------------"
					echo "美洲"
					echo "21. 美国西部时间             22. 美国东部时间"
					echo "23. 加拿大温哥华时间         24. 墨西哥城时间"
					echo "25. 巴西圣保罗时间           26. 阿根廷布宜诺斯艾利斯时间"
					echo "------------------------"
					echo "31. UTC全球标准时间"
					echo "------------------------"
					echo "0. 返回上一级选单"
					echo "------------------------"
					read -e -p "请输入你的选择: " choice || return 1
					case "$choice" in
						1) set_timedate Asia/Shanghai ;;
						2) set_timedate Asia/Hong_Kong ;;
						3) set_timedate Asia/Tokyo ;;
						4) set_timedate Asia/Seoul ;;
						5) set_timedate Asia/Singapore ;;
						6) set_timedate Asia/Kolkata ;;
						7) set_timedate Asia/Dubai ;;
						8) set_timedate Australia/Sydney ;;
						9) set_timedate Asia/Bangkok ;;
						11) set_timedate Europe/London ;;
						12) set_timedate Europe/Paris ;;
						13) set_timedate Europe/Berlin ;;
						14) set_timedate Europe/Moscow ;;
						15) set_timedate Europe/Amsterdam ;;
						16) set_timedate Europe/Madrid ;;
						21) set_timedate America/Los_Angeles ;;
						22) set_timedate America/New_York ;;
						23) set_timedate America/Vancouver ;;
						24) set_timedate America/Mexico_City ;;
						25) set_timedate America/Sao_Paulo ;;
						26) set_timedate America/Argentina/Buenos_Aires ;;
						31) set_timedate UTC ;;
						0) break ;;
						*) echo "无效的输入!" ;;
					esac
					break_end_unless "$choice" 0
				done
				;;
			8)
				root_use
				while true; do
					clear
					local current_hostname new_hostname
					current_hostname=$(uname -n)
					echo -e "当前主机名: ${gl_huang}$current_hostname${gl_bai}"
					echo "------------------------"
					read -e -p "请输入新的主机名（输入0退出）: " new_hostname || return 1
					if [ -n "$new_hostname" ] && [ "$new_hostname" != "0" ]; then
						daimon_set_hostname "$new_hostname" || { echo "主机名修改失败，请检查上方错误。"; false; }
						break_end
					else
						break
					fi
				done
				;;
			9)
				root_use
				while true; do
					clear
					echo "本机host解析列表"
					echo "如果你在这里添加解析匹配，将不再使用动态解析了"
					cat /etc/hosts
					echo ""
					echo "操作"
					echo "------------------------"
					echo "1. 添加新的解析              2. 删除解析地址"
					echo "------------------------"
					echo "0. 返回上一级选单"
					echo "------------------------"
					read -e -p "请输入你的选择: " host_dns || return 1
					case "$host_dns" in
						1) read -r -e -p "请输入新的解析记录 格式: 110.25.5.33 example.com : " addhost || return 1; [ -n "$addhost" ] && daimon_hosts_edit add "$addhost" ;;
						2) read -r -e -p "请输入需要删除的解析内容关键字（按字面匹配）: " delhost || return 1; [ -n "$delhost" ] && daimon_hosts_edit delete "$delhost" ;;
						0) break ;;
						*) echo "无效的输入!" ;;
					esac
					break_end_unless "$host_dns" 0
				done
				;;
			10) clear; env_menu ;;
			11) github_proxy_manager ;;
			12) show_ssh_ip_info; break_end ;;
			13) clear; net_menu ;;
			14) journalctl_log_manager ;;
			15) system_network_auto_optimize ;;
			16) clear; system_disable_ipv6; break_end ;;
			17) clear; system_enable_ipv6; break_end ;;
			18) clear; linux_language ;;
			19) docker_mirror_speed_test_menu ;;
			20)
				clear
				echo "卸载daimon脚本"
				echo "------------------------------------------------"
				echo "删除工具箱主脚本及其快捷键；保留已安装服务、辅助脚本和定时任务。"
				read -e -p "确定继续吗？(Y/N): " choice || return 1
				case "$choice" in
					[Yy])
						clear
						daimon_uninstall_toolbox || { break_end; continue; }
						echo "脚本已卸载，再见！"
						break_end
						clear
						exit
						;;
					[Nn]) echo "已取消" ;;
					*) echo "无效的选择，请输入 Y 或 N。" ;;
				esac
				;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
	done
}
