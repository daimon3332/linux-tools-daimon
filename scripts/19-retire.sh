#!/bin/bash

validate_domain_name() {
	[[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]
}

server_retire_compose_stop() {
	[ "$(id -u)" = 0 ] || return 1
	python3 - "$1" "$2" "$3" <<'PYRETIRE_COMPOSE'
import json, re, subprocess, sys

def command(*args):
    result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=90)
    if result.returncode: raise ValueError('Docker operation failed: ' + args[0] + '; completed actions are not rolled back')
    return result.stdout

def main(project, workdir, files):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', project) or not workdir.startswith('/') or not files:
        raise ValueError('Missing or unsupported Compose context; no containers changed')
    ids = command('ps', '-aq', '--no-trunc', '--filter', 'label=com.docker.compose.project=' + project).split()
    if not ids: return
    if not all(re.fullmatch(r'[a-f0-9]{64}', item) for item in ids): raise ValueError('Invalid container identity')
    def inspect(container):
        data = json.loads(command('inspect', '--type', 'container', container))
        if len(data) != 1 or data[0]['Id'] != container: raise ValueError('Container identity changed')
        item = data[0]
        labels = item['Config'].get('Labels') or {}
        context = tuple(labels.get('com.docker.compose.' + k) for k in ('project', 'project.working_dir', 'project.config_files'))
        if context != (project, workdir, files): raise ValueError('Project name is shared by another context; nothing else will be changed')
        return item
    for container in ids: inspect(container)
    if command('ps', '-aq', '--no-trunc', '--filter', 'label=com.docker.compose.project=' + project).split() != ids:
        raise ValueError('Project membership changed; retry selection')
    for container in ids:
        if inspect(container)['State']['Running']: command('stop', '--time', '30', container)
        if inspect(container)['State']['Running']: raise ValueError('Container is still running; retained')
        command('rm', container)
    print('Selected containers retired. Volumes, images, networks and project files preserved.')

if __name__ == '__main__':
    try: main(*sys.argv[1:])
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('Retirement failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
PYRETIRE_COMPOSE
}

server_retire_compose_item() {
	docker_compose_update_get_item_by_number "$1"
}

server_retire_nginx_items() {
	local dir file canonical domains enabled link
	local -A seen=()
	for dir in /etc/nginx/sites-enabled /etc/nginx/sites-available /home/web/conf.d; do
		[ -d "$dir" ] || continue
		while IFS= read -r -d '' file; do
			domains=$(awk '/^[[:space:]]*server_name[[:space:]]/ { for (i=2; i<=NF; i++) { gsub(";", "", $i); if ($i != "_" && $i !~ /^\$/) print $i } }' "$file" 2>/dev/null | while read -r domain; do validate_domain_name "$domain" && printf '%s\n' "$domain"; done | sort -u | paste -sd, -)
			[ -n "$domains" ] || continue
			canonical=$(realpath -m -- "$file" 2>/dev/null || printf '%s' "$file")
			[ -n "${seen[$canonical]:-}" ] && continue
			seen["$canonical"]=1
			enabled=false
			for link in /etc/nginx/sites-enabled/*; do
				[ -e "$link" ] || [ -L "$link" ] || continue
				[ "$(realpath -m -- "$link" 2>/dev/null)" = "$canonical" ] && enabled=true
			done
			printf '%s\t%s\t%s\n' "$canonical" "$domains" "$enabled"
		done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
	done | sort -u
}

server_retire_nginx_item() {
	local target="$1" idx=0 file domains enabled
	while IFS=$'\t' read -r file domains enabled; do
		idx=$((idx + 1))
		[ "$idx" -eq "$target" ] && { printf '%s\t%s\t%s\n' "$file" "$domains" "$enabled"; return 0; }
	done < <(server_retire_nginx_items)
	return 1
}

server_retire_nginx_remove() (
	local file="$1" domains="$2" parent link target work="" done=0 moved=0 i
	local links=() destinations=()
	[ "$(id -u)" = 0 ] || return 1
	parent=$(dirname -- "$file")
	case "$parent" in /etc/nginx/sites-enabled|/etc/nginx/sites-available|/home/web/conf.d) ;; *) echo "拒绝非托管配置路径。"; return 1 ;; esac
	[ -f "$file" ] && [ ! -L "$file" ] && [ "$(realpath -e -- "$file")" = "$file" ] || return 1
	[ "$(stat -c %u:%h "$file")" = 0:1 ] && [ "$(stat -c %u "$parent")" = 0 ] || return 1
	(( (8#$(stat -c %a "$parent") & 8#022) == 0 )) || return 1
	for link in /etc/nginx/sites-enabled/*; do
		[ -L "$link" ] || continue
		[ "$(realpath -m -- "$link")" = "$file" ] || continue
		links+=("$link"); destinations+=("$(readlink -- "$link")")
	done
	work=$(mktemp -d "$parent/.daimon-retire.XXXXXX") || return 1
	retire_nginx_finish() {
		local rc=$? restore_failed=0
		trap - EXIT INT TERM HUP
		if [ "$done" = 0 ] && [ "$moved" = 1 ] && [ -f "$work/config" ]; then
			if [ ! -e "$file" ] && [ ! -L "$file" ]; then mv -- "$work/config" "$file" || restore_failed=1; else restore_failed=1; fi
			for i in "${!links[@]}"; do
				link=${links[$i]}
				if [ -L "$link" ] && [ "$(readlink -- "$link")" = "${destinations[$i]}" ]; then continue; fi
				[ ! -e "$link" ] && [ ! -L "$link" ] && ln -s -- "${destinations[$i]}" "$link" || restore_failed=1
			done
			if [ "$restore_failed" = 0 ]; then server_retire_nginx_reload || restore_failed=1; fi
			if [ "$restore_failed" != 0 ]; then echo "Nginx 配置或服务恢复失败，请检查 $file 和 $work。" >&2; rmdir -- "$work" 2>/dev/null || true; exit 1; fi
		fi
		rm -f -- "$work/config" || rc=1
		rmdir -- "$work" || rc=1
		exit "$rc"
	}
	trap retire_nginx_finish EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	moved=1
	mv -- "$file" "$work/config" || { moved=0; return 1; }
	for link in "${links[@]}"; do rm -- "$link" || return 1; done
	server_retire_nginx_reload || return 1
	done=1
	echo "已删除 Nginx 配置；证书可能被其他配置或服务共享，保留证书目录，请在证书管理中单独核查。"
)

server_retire_nginx_reload() {
	if command -v nginx >/dev/null 2>&1; then
		nginx -t || return 1
		if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
	elif command -v docker >/dev/null 2>&1 && docker inspect nginx >/dev/null 2>&1; then
		docker exec nginx nginx -t && docker exec nginx nginx -s reload
	else
		echo "未检测到可验证的 Nginx，未完成配置修改。" >&2
		return 1
	fi
}

server_retire_sync_dirs() {
	printf '%s\n' "$(crontab_sync_backup_dir)" /root/backup-sh
}

server_retire_update_dirs() {
	printf '%s\n' "$(docker_compose_update_script_dir)" /root/docker-compose-update
}

server_retire_script_items() {
	local dir file cron_output
	cron_output=$(rsync_cron_read) || return 1
	while IFS= read -r dir; do
		[ -d "$dir" ] || continue
		while IFS= read -r -d '' file; do
			printf '%s\t%s\n' "$file" "$(printf '%s\n' "$cron_output" | awk -v path="$file" '/^[[:space:]]*#/ {next} {p=" " $0 " "; if (index(p, " " path " ")) found=1} END {exit !found}' && echo true || echo false)"
		done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
	done < <(server_retire_sync_dirs) | sort -u
}

server_retire_update_items() {
	local dir file cron_output
	cron_output=$(rsync_cron_read) || return 1
	while IFS= read -r dir; do
		[ -d "$dir" ] || continue
		while IFS= read -r -d '' file; do
			printf '%s\t%s\n' "$file" "$(printf '%s\n' "$cron_output" | awk -v path="$file" '/^[[:space:]]*#/ {next} {p=" " $0 " "; if (index(p, " " path " ")) found=1} END {exit !found}' && echo true || echo false)"
		done < <(find "$dir" -maxdepth 1 -type f -name 'compose_update_*.sh' -print0 2>/dev/null)
	done < <(server_retire_update_dirs) | sort -u
}

server_retire_filter_cron() {
	command -v python3 >/dev/null 2>&1 || { echo "安全识别定时任务需要 python3，未修改。" >&2; return 1; }
	python3 -c '
import re, shlex, sys
target, runner = sys.argv[1:]
gate = re.compile(r"^\[ \"\$\(TZ=Asia/Shanghai date \+\\%H:\\%M\)\" = \"[0-2][0-9]:[0-5][0-9]\" \] && (?:\[ \"\$\(TZ=Asia/Shanghai date \+\\%w\)\" = \"[0-6]\" \] && )?")
kept = []
try:
    for line in sys.stdin:
        stripped = line.lstrip()
        if not stripped.strip() or stripped.startswith("#"):
            kept.append(line); continue
        fields = stripped.split(None, 1 if stripped.startswith("@") else 5)
        if len(fields) != (2 if stripped.startswith("@") else 6):
            kept.append(line); continue
        command = gate.sub("", fields[-1], count=1)
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
        args = tokens[1:] if tokens and tokens[0] in ("bash", "/bin/bash", "/usr/bin/bash", "sh", "/bin/sh", "/usr/bin/sh") else tokens
        owned = bool(args) and (args[0] == target or (len(args) >= 3 and args[0] == runner and re.fullmatch(r"[A-Za-z0-9_.:-]+", args[1]) and args[2] == target))
        compound = any(any(c in t for c in ";|()") or t in ("&", "&&") for t in tokens) or "$(" in command or "`" in command
        if owned:
            if compound: raise ValueError("Target shares a compound cron command; edit it explicitly")
            continue
        if target in tokens and (compound or not tokens or tokens[0] not in ("echo", "printf", "/bin/echo", "/usr/bin/printf")):
            raise ValueError("Ambiguous cron reference to target; edit it explicitly")
        kept.append(line)
    sys.stdout.write("".join(kept))
except ValueError as error:
    print("Cron unchanged: " + str(error), file=sys.stderr)
    sys.exit(1)
' "$1" "$2"
}

server_retire_remove_cron_path() {
	local path="$1" current next checked runner
	[[ "$path" = /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
	current=$(rsync_cron_read) || return 1
	[ -n "$current" ] || return 0
	runner=$(crontab_sync_runner_file) || return 1
	next=$(printf '%s\n' "$current" | server_retire_filter_cron "$path" "$runner") || return 1
	[ "$current" != "$next" ] || return 0
	checked=$(rsync_cron_read) || return 1
	[ "$checked" = "$current" ] || { echo "定时任务已被其他进程修改，已取消。" >&2; return 1; }
	printf '%s\n' "$next" | crontab - || return 1
	checked=$(rsync_cron_read) || return 1
	[ "$checked" = "$next" ] || { echo "定时任务写入后校验失败，请检查 crontab。" >&2; return 1; }
}

server_retire_script_guard() {
	local file="$1" dir
	local dirs=()
	while IFS= read -r dir; do dirs+=("$dir"); done < <(server_retire_sync_dirs; server_retire_update_dirs)
	python3 - "$file" "$DAIMON_SCRIPT_DIR/auto_cert_renewal.sh" "$DAIMON_ROOT_DIR/cert-renew.sh" "${dirs[@]}" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
try:
    target = Path(sys.argv[1])
    allowed = target in (Path(sys.argv[2]), Path(sys.argv[3])) or target.parent in map(Path, sys.argv[4:])
    if not allowed or not target.is_absolute() or target.resolve() != target or target.suffix != ".sh":
        raise ValueError("Not a direct managed script")
    for parent in target.parents:
        if not parent.exists(): continue
        info = parent.stat()
        if info.st_uid != 0 or info.st_mode & 0o022: raise ValueError("Untrusted script directory")
    if not target.exists():
        print("absent"); sys.exit(0)
    info = target.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o022:
        raise ValueError("Untrusted script file")
    for proc in Path("/proc").iterdir():
        if not proc.name.isdecimal() or int(proc.name) == os.getpid(): continue
        try:
            if os.fsencode(target) in (proc / "cmdline").read_bytes().split(b"\0"):
                raise ValueError("Script is running; stop it before retirement")
            for fd in (proc / "fd").iterdir():
                try:
                    if fd.resolve() == target: raise ValueError("Script is open; stop its user before retirement")
                except FileNotFoundError: pass
        except (FileNotFoundError, ProcessLookupError): pass
    print(f"{info.st_dev}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}:" + hashlib.sha256(target.read_bytes()).hexdigest())
except (OSError, ValueError) as error:
    print("Script retained: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

server_retire_remove_script() {
	local file="$1" identity checked
	[ "$(id -u)" = 0 ] || return 1
	identity=$(server_retire_script_guard "$file") || return 1
	server_retire_remove_cron_path "$file" || return 1
	checked=$(server_retire_script_guard "$file") || { echo "定时任务已移除，但脚本状态变化，保留脚本。"; return 1; }
	[ "$checked" = "$identity" ] || { echo "脚本已变化，保留文件；定时任务已移除。"; return 1; }
	[ "$identity" = absent ] || rm -f -- "$file"
}

server_retire_show_status() {
	local count=0 running project workdir config_files file domains enabled cron_state active=0 cert_file legacy_cert_file cert_cron=false
	echo "服务器退役状态（只读检测，不会自动删除）"
	echo "------------------------"
	while IFS=$'\t' read -r project workdir config_files; do
		[ -n "$project" ] || continue
		count=$((count + 1)); running=$(docker ps -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
		[ "$running" -gt 0 ] && cron_state="运行中" || cron_state="已停止"
		echo "Compose $count: $project [$cron_state]"
	done < <(docker_compose_update_discover_projects)
	[ "$count" -eq 0 ] && echo "Compose 项目：未检测到"
	count=0; active=0
	while IFS=$'\t' read -r file domains enabled; do count=$((count + 1)); [ "$enabled" = true ] && active=$((active + 1)); done < <(server_retire_nginx_items)
	echo "Nginx 域名配置：$active 个启用，$((count - active)) 个未启用"
	count=0
	while IFS=$'\t' read -r file cron_state; do count=$((count + 1)); done < <(server_retire_script_items)
	active=$count; count=0
	while IFS=$'\t' read -r file cron_state; do count=$((count + 1)); done < <(server_retire_update_items)
	echo "自动同步脚本：$active 个，Compose 自动更新脚本：$count 个"
	cert_file="$DAIMON_SCRIPT_DIR/auto_cert_renewal.sh"
	legacy_cert_file="$DAIMON_ROOT_DIR/cert-renew.sh"
	if printf '%s\n' "$(crontab -l 2>/dev/null || true)" | awk -v path="$cert_file" -v legacy="$legacy_cert_file" '/^[[:space:]]*#/ {next} {p=" " $0 " "; if (index(p, " " path " ") || index(p, " " legacy " ")) found=1} END {exit !found}'; then cert_cron=true; fi
	if { [ -f "$cert_file" ] || [ -f "$legacy_cert_file" ]; } && $cert_cron; then
		echo "证书自动续期：已配置"
	elif [ -f "$cert_file" ] || [ -f "$legacy_cert_file" ]; then
		echo "证书自动续期：脚本存在，未加入定时"
	elif $cert_cron; then
		echo "证书自动续期：定时存在，脚本不存在"
	else
		echo "证书自动续期：未检测到"
	fi
	echo "DNS 服务商记录：不会由本功能修改"
	echo "------------------------"
}

server_retire_capture() {
	case "$1" in
		C) docker_compose_update_discover_projects ;;
		N) server_retire_nginx_items ;;
		A) server_retire_script_items ;;
		U) server_retire_update_items ;;
		R) printf '%s	%s\n' "$DAIMON_SCRIPT_DIR/auto_cert_renewal.sh" "$DAIMON_ROOT_DIR/cert-renew.sh" ;;
		*) return 1 ;;
	esac
}

server_retire_apply_token() {
	local token="$1" item="${2:-}" n project workdir config_files file domains enabled failure=0
	[[ "$token" =~ ^[CNAU][1-9][0-9]{0,5}$ || "$token" = R1 ]] || return 1
	if [ -z "$item" ]; then
		local rows=() listing
		listing=$(server_retire_capture "${token:0:1}") || return 1
		[ -n "$listing" ] && mapfile -t rows <<< "$listing"
		n=${token:1}; (( n <= ${#rows[@]} )) || return 1
		item=${rows[$((n-1))]}
	fi
	case "$token" in
		C*) IFS=$'	' read -r project workdir config_files <<< "$item"; server_retire_compose_stop "$project" "$workdir" "$config_files" ;;
		N*) IFS=$'	' read -r file domains enabled <<< "$item"; server_retire_nginx_remove "$file" "$domains" ;;
		A*|U*) file=${item%%$'	'*}; server_retire_remove_script "$file" ;;
		R1)
			IFS=$'	' read -r file workdir <<< "$item"
			server_retire_remove_script "$file" || failure=1
			server_retire_remove_script "$workdir" || failure=1
			return "$failure"
			;;
	esac
}

server_retire_apply_selection() {
	local nums="$1" prefix token index listing plan="" current failure=0
	local rows=()
	local -A selected=() checked=()
	for token in $nums; do
		[[ "$token" =~ ^[CNAU][1-9][0-9]{0,5}$ || "$token" = R1 ]] || { echo "编号无效，未执行: $token"; return 1; }
		[ -z "${selected[$token]:-}" ] || continue
		selected[$token]=1
		prefix=${token:0:1}; index=${token:1}
		listing=${retire_snapshot[$prefix]}
		rows=(); [ -n "$listing" ] && mapfile -t rows <<< "$listing"
		(( index <= ${#rows[@]} )) || { echo "编号不存在，未执行: $token"; return 1; }
		plan+="$token"$'	'"${rows[$((index-1))]}"$'\n'
		checked[$prefix]=1
	done
	for prefix in "${!checked[@]}"; do
		current=$(server_retire_capture "$prefix") || return 1
		[ "$current" = "${retire_snapshot[$prefix]}" ] || { echo "项目列表已变化，请重新选择。"; return 1; }
	done
	while IFS=$'	' read -r token listing; do
		[ -n "$token" ] || continue
		server_retire_apply_token "$token" "$listing" || { echo "处理失败: $token"; failure=1; }
	done <<< "$plan"
	return "$failure"
}

server_retire_apply_tokens_for_prefix() {
	local prefix="$1" nums="$2" token selected=""
	local -A retire_snapshot=()
	[[ "$prefix" =~ ^[CNAUR]$ ]] || return 1
	retire_snapshot[$prefix]=$(server_retire_capture "$prefix") || return 1
	for token in $nums; do
		[[ "$token" =~ ^[CNAU][1-9][0-9]{0,5}$ || "$token" = R1 ]] || return 1
		[[ "$token" != "$prefix"* ]] || selected+="$token"$'\n'
	done
	selected=$(printf '%s' "$selected" | sort -k1.2nr)
	server_retire_apply_selection "$selected"
}

server_retire_bulk() {
	local nums="" token prefix row index
	local -A retire_snapshot=()
	for prefix in C N A U R; do
		retire_snapshot[$prefix]=$(server_retire_capture "$prefix") || return 1
		index=0
		while IFS= read -r row; do
			[ -n "$row" ] || continue
			index=$((index+1)); nums+="$prefix$index "
		done <<< "${retire_snapshot[$prefix]}"
	done
	read -e -i "$nums" -p "请确认/修改退役项目编号（C=Compose N=Nginx A=同步脚本 U=自动更新 R=证书续期）: " nums || return 1
	[ -n "$nums" ] || { echo "已取消"; return 0; }
	read -r -p "将执行所选退役操作，输入 RETIRE 确认: " token || return 1
	[ "$token" = RETIRE ] || { echo "已取消"; return 0; }
	server_retire_apply_selection "$nums"
}

server_retire_select_menu() {
	local prefix="$1" label="$2" nums confirm row index=0 tokens=""
	local -A retire_snapshot=()
	retire_snapshot[$prefix]=$(server_retire_capture "$prefix") || return 1
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		index=$((index+1)); printf '%d. %s\n' "$index" "$row"
	done <<< "${retire_snapshot[$prefix]}"
	[ "$index" -gt 0 ] || { echo "没有可处理项目。"; return 0; }
	read -e -p "请输入要处理的${label}编号（空格多选）: " nums || return 1
	[ -n "$nums" ] || return 0
	read -r -p "确认处理所选${label}？(y/N): " confirm || return 1
	[[ "$confirm" =~ ^[Yy]$ ]] || return 0
	for index in $nums; do
		[[ "$index" =~ ^[1-9][0-9]{0,5}$ ]] || { echo "编号无效，未执行。"; return 1; }
		tokens+="$prefix$index "
	done
	server_retire_apply_selection "$tokens"
}

server_retire_compose_menu() {
	server_retire_select_menu C "Compose 服务"
}

server_retire_nginx_menu() {
	server_retire_select_menu N "Nginx 配置（共享或无法证明独占的证书保留）"
}

server_retire_script_menu() {
	if [ "$1" = update ]; then server_retire_select_menu U "自动更新脚本和定时任务"; else server_retire_select_menu A "同步脚本和定时任务"; fi
}

server_retire_cert_menu() {
	local confirm
	read -r -p "删除证书自动续期脚本和定时任务？(y/N): " confirm || return 1
	[[ "$confirm" =~ ^[Yy]$ ]] || return 0
	server_retire_apply_token R1
}

server_retire_menu() {
	local choice
	while true; do
		clear
		server_retire_show_status
		echo "1. 一键退役（默认全选，可删除编号）"
		echo "2. Docker Compose 服务"
		echo "3. Nginx 域名配置"
		echo "4. 自动同步脚本"
		echo "5. Docker Compose 自动更新"
		echo "6. 证书自动续期任务"
		echo "0. 返回主菜单"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) server_retire_bulk ;;
			2) server_retire_compose_menu ;;
			3) server_retire_nginx_menu ;;
			4) server_retire_script_menu sync ;;
			5) server_retire_script_menu update ;;
			6) server_retire_cert_menu ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
