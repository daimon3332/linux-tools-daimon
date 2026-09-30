#!/bin/bash

daimon_preferences_load() {
    local values
    values=$(daimon_boot_value setting) && [ -n "$values" ] ||
        values=$(python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" settings) || return 1
    unset DAIMON_BOOT
    while IFS='=' read -r key value; do
        value=${value#\"}; value=${value%\"}
        case "$key" in canshu|permission_granted|ENABLE_STATS) printf -v "$key" '%s' "$value" ;; *) return 1 ;; esac
    done <<< "$values"
}

daimon_preference_set() {
    python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" setting "$1" "$2" || return 1
    printf -v "$1" '%s' "$2"
}

daimon_initialize() {
    mkdir -p "$DAIMON_SCRIPT_DIR" "$DAIMON_BACKUP_DIR" "$DAIMON_BACKUP_SH_DIR" "$DAIMON_TOOLS_DIR" "$DAIMON_DOCKER_COMPOSE_UPDATE_DIR" || return 1
    daimon_migrate_runtime_layout || return 1
    daimon_preferences_load || return 1
    quanju_canshu
    if [ "$permission_granted" != true ]; then
        UserLicenseAgreement
    fi
}

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
