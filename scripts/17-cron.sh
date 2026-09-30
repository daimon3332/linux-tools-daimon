#!/bin/bash

crontab_sync_backup_dir() {
	echo "${DAIMON_BACKUP_SH_DIR:-/root/linux-daimon/backup-sh}"
}

crontab_sync_log_dir() {
	echo "/var/log/rclone"
}

crontab_sync_target_remote() {
	echo "kissska1"
}

crontab_sync_log_cache_file() { echo "${DAIMON_RCLONE_STATUS_CACHE:-/var/cache/daimon/rclone-sync-status.tsv}"; }

crontab_sync_log_run_dir() { echo "${DAIMON_RCLONE_RUN_LOG_DIR:-/var/log/rclone/runs}"; }

crontab_sync_log_export_dir() { echo "${DAIMON_RCLONE_EXPORT_DIR:-/root/linux-daimon/rclone-logs}"; }

crontab_sync_runner_file() { echo "${DAIMON_RCLONE_RUNNER_FILE:-$(crontab_sync_backup_dir)/.rclone-runner.sh}"; }

crontab_sync_write_runner() (
	umask 077
	local target="$1" staged
	mkdir -p "$(dirname "$target")" "$(crontab_sync_log_run_dir)" "$(dirname "$(crontab_sync_log_cache_file)")" || return 1
	staged=$(mktemp "${target}.XXXXXX") || return 1
	trap 'rm -f -- "$staged"' EXIT
	cat > "$staged" <<'EOF'
#!/bin/bash
set -u
TASK="${1:-custom}"
SCRIPT="${2:-}"
[ -x "$SCRIPT" ] || { printf '%s\n' "同步脚本不存在或不可执行: $SCRIPT" >&2; exit 126; }
log_policy() {
local log_exec=()
[ "$1" != monitor ] || log_exec=(exec)
"${log_exec[@]}" python3 - "$@" <<'PYLOG'
import fcntl, os, re, signal, sys, time
from pathlib import Path

mode, directory, cache, filename = sys.argv[1:5]
root, cache, active = Path(directory), Path(cache), Path(filename)
limit = int(os.environ.get('DAIMON_LOG_FILE_BYTES', 8*1024*1024))
budget = int(os.environ.get('DAIMON_LOG_TOTAL_BYTES', 128*1024*1024))
reserve = int(os.environ.get('DAIMON_LOG_MIN_FREE_BYTES', 64*1024*1024))
inodes = int(os.environ.get('DAIMON_LOG_MIN_FREE_INODES', 128))
days = int(os.environ.get('DAIMON_LOG_RETENTION_DAYS', 30))
if limit < 4096 or budget < 2*limit or reserve < 1 or inodes < 1 or days < 1:
    sys.exit('ERROR: Invalid log space/retention policy')
if root.is_symlink() or active.is_symlink() or cache.is_symlink() or active.parent != root:
    sys.exit('ERROR: Unsafe log path')
pattern = re.compile(r'\d{8}-\d{6}-\d+-[A-Za-z0-9_.-]+\.log')

def prune():
    with (root / '.retention.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files = [p for p in root.iterdir() if pattern.fullmatch(p.name) and not p.is_symlink() and p.is_file()]
        files.sort(key=lambda p: p.stat().st_mtime)
        total = sum(p.stat().st_size for p in files)
        for path in files:
            if path == active:
                continue
            info = path.stat()
            free = os.statvfs(root)
            if total + limit <= budget and time.time()-info.st_mtime <= days*86400 and free.f_bavail*free.f_frsize >= reserve+limit:
                continue
            with path.open('rb') as fd:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                path.unlink()
                total -= info.st_size
        if total + (limit if mode == 'prepare' else 0) > budget:
            raise OSError('Owned log budget exhausted by active/recent logs')

def space():
    for path in (root, cache.parent):
        info = os.statvfs(path)
        if info.f_bavail*info.f_frsize < reserve or (info.f_files and info.f_favail < inodes):
            raise OSError('Insufficient log bytes/inodes: ' + str(path))

try:
    if mode == 'prepare':
        prune()
        space()
        with active.open('xb') as out:
            out.write(b'LOG_POLICY_READY\n')
            out.flush()
            os.fsync(out.fileno())
        os.chmod(active, 0o600)
    else:
        parent = int(sys.argv[5])
        while True:
            os.kill(parent, 0)
            if active.stat().st_size > limit:
                with active.open('r+b') as out:
                    out.seek(-limit//2, os.SEEK_END)
                    tail = out.read(limit//2).split(b'\n', 1)[-1]
                    out.seek(0)
                    out.write(b'LOG_ROTATED: older detail discarded by configured size limit\n' + tail)
                    out.truncate()
            prune()
            space()
            time.sleep(0.5)
except (OSError, ValueError) as error:
    print('ERROR: Log policy: ' + str(error), file=sys.stderr)
    if mode != 'prepare':
        try:
            # O_APPEND producers keep the same inode after truncation.
            with active.open('r+b') as out:
                out.truncate(0)
                out.write(b'ERROR: LOG_STORAGE_FAILURE; task cancelled; check writer recovery\n')
            os.kill(parent, signal.SIGUSR1)
        except OSError:
            try: os.kill(parent, signal.SIGUSR1)
            except OSError: pass
    sys.exit(1)
PYLOG
}
RUN_DIR="${DAIMON_RCLONE_RUN_LOG_DIR:-/var/log/rclone/runs}"
CACHE_FILE="${DAIMON_RCLONE_STATUS_CACHE:-/var/cache/daimon/rclone-sync-status.tsv}"
LOCK_FILE="${DAIMON_RCLONE_STATUS_LOCK:-/run/lock/daimon-rclone-status.lock}"
mkdir -p "$RUN_DIR" "$(dirname "$CACHE_FILE")" "$(dirname "$LOCK_FILE")" || exit 1
chmod 700 "$RUN_DIR" "$(dirname "$CACHE_FILE")" 2>/dev/null || true
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 required for bounded logs'; exit 1; }
touch "$CACHE_FILE" && chmod 600 "$CACHE_FILE" || exit 1
safe_task=$(printf '%s' "$TASK" | tr -c 'A-Za-z0-9_.-' '_')
epoch=$(date +%s); started=$(date -Is)
run_id="$(date +%Y%m%d-%H%M%S)-$$-$safe_task"
run_log="$RUN_DIR/$run_id.log"
log_policy prepare "$RUN_DIR" "$CACHE_FILE" "$run_log" || exit 1
exec 10>>"$run_log"; flock -x 10 || exit 1
exec 9>"$LOCK_FILE"; flock -x 9
cutoff=$((epoch - 30 * 86400)); tmp_cache=$(mktemp "$CACHE_FILE.XXXXXX") || exit 1
active_pids=" "
while IFS=$'\t' read -r _ _ _ _ _ _ previous_status _ _ previous_pid _ _; do
    [ "$previous_status" = '执行中' ] && [[ "$previous_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$previous_pid" 2>/dev/null && [ -r "/proc/$previous_pid/cmdline" ] \
        && tr '\0' '\n' < "/proc/$previous_pid/cmdline" | grep -Fxq -- "$0"; then
        active_pids+="$previous_pid "
    fi
done < "$CACHE_FILE"
awk -F '\t' -v OFS='\t' -v cutoff="$cutoff" -v stale="$((epoch - 3600))" -v active="$active_pids" '$1 >= cutoff {if ($7 == "执行中" && $1 < stale && !index(active, " " $10 " ")) {$7="中断/未知"; $8="-"; $12="运行器未正常结束"} print}' "$CACHE_FILE" > "$tmp_cache" || exit 1
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$started" "-" "$run_id" "$safe_task" "sync" "执行中" "-" "0" "$$" "$run_log" "-" >> "$tmp_cache"
chmod 600 "$tmp_cache" && mv -f "$tmp_cache" "$CACHE_FILE" || { rm -f -- "$tmp_cache"; exit 1; }
flock -u 9
export DAIMON_RUN_LOG="$run_log"
printf '===== %s 开始任务=%s 脚本=%s =====\n' "$started" "$safe_task" "$SCRIPT" > "$run_log"; chmod 600 "$run_log"
child_pid=""; guard_pid=""; interrupted=0
cancel_run() {
    interrupted="$1"
    trap '' INT TERM
    if [ -n "$child_pid" ]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
}
trap 'cancel_run 130' INT
trap 'cancel_run 143' TERM
trap 'cancel_run 74' USR1
log_policy monitor "$RUN_DIR" "$CACHE_FILE" "$run_log" "$$" >/dev/null 2>&1 & guard_pid=$!
"$SCRIPT" >> "$run_log" 2>&1 & child_pid=$!
wait "$child_pid"; rc=$?
[ "$interrupted" -eq 0 ] || rc="$interrupted"
child_pid=""
kill "$guard_pid" 2>/dev/null || true
wait "$guard_pid" 2>/dev/null || true
trap - INT TERM USR1
finished=$(date -Is); end_epoch=$(date +%s); duration=$((end_epoch - epoch))
status="成功"; reason="-"
if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    status="中断/未知"; reason="任务已中断，请核对日志中的容器恢复结果"
elif [ "$rc" -ne 0 ]; then
    status="失败"
    reason=$(grep -Ei 'error|failed|fatal|denied|timeout|cannot|无法|失败' "$run_log" 2>/dev/null | tail -n 1 | tr '\t\r\n' '   ' | sed -E -e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' -e 's/((access_token|refresh_token|client_secret|tempauth|password)"?[[:space:]]*[=:][[:space:]]*"?)[^"[:space:]&,}]+/\1[REDACTED]/Ig' | cut -c1-240)
    reason=${reason:-"脚本退出码 $rc"}
    [ "$interrupted" != 74 ] || reason='日志空间或写入故障，任务已取消；请核对服务恢复'
elif grep -Eiq '已有 .*运行.*跳过|已有.*运行，跳过' "$run_log"; then
    status="被锁跳过"; reason="检测到已有同类任务运行"
elif grep -Eiq 'Duplicate (directory|file|object) found in (source|destination) - ignoring' "$run_log"; then
    status="有警告"
    reason=$(grep -Ei 'Duplicate (directory|file|object) found in (source|destination) - ignoring' "$run_log" | tail -n 1 | tr '\t\r\n' '   ' | sed -E -e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' -e 's/((access_token|refresh_token|client_secret|tempauth|password)"?[[:space:]]*[=:][[:space:]]*"?)[^"[:space:]&,}]+/\1[REDACTED]/Ig' | cut -c1-240)
fi
cache_failure() {
    printf '%s\n' 'ERROR: 无法更新任务状态缓存，请核对任务日志' >> "$run_log"
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
}
exec 9>"$LOCK_FILE" || cache_failure
flock -x 9 || cache_failure
tmp_cache=$(mktemp "$CACHE_FILE.XXXXXX") || cache_failure
awk -F '\t' -v OFS='\t' -v id="$run_id" -v ended="$finished" -v status="$status" -v rc="$rc" -v duration="$duration" -v reason="$reason" '$4 == id {$3=ended; $7=status; $8=rc; $9=duration; $12=reason} {print}' "$CACHE_FILE" > "$tmp_cache" \
    && chmod 600 "$tmp_cache" && mv -f "$tmp_cache" "$CACHE_FILE" || { rm -f -- "$tmp_cache"; cache_failure; }
flock -u 9
printf '===== %s 结束状态=%s 退出码=%s 耗时=%ss =====\n' "$finished" "$status" "$rc" "$duration" >> "$run_log"
exit "$rc"
EOF
	bash -n "$staged" && chmod 700 "$staged" && mv -f -- "$staged" "$target"
)

crontab_sync_write_run_tools() { crontab_sync_write_runner "$(crontab_sync_runner_file)"; }

crontab_sync_log_sanitize() {
	sed -E \
		-e 's@(https?://[^[:space:]"?]+)\?[^[:space:]"]*@\1?[REDACTED]@g' \
		-e 's/([Bb]earer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' \
		-e 's/((access_token|refresh_token|client_secret|tempauth|password)"?[[:space:]]*[=:][[:space:]]*"?)[^"[:space:]&,}]+/\1[REDACTED]/Ig' "$1"
}

crontab_sync_log_records() {
	local task="${1:-}" cache
	cache=$(crontab_sync_log_cache_file); [ -f "$cache" ] || return 0
	awk -F '\t' -v task="$task" 'task == "" || $5 == task {print}' "$cache" | sort -t $'\t' -k1,1nr
}

crontab_sync_log_show_recent() {
	local filter="${1:-}" n=0 epoch start end id task op status rc duration pid log reason
	printf '%-3s %-19s %-14s %-10s %-10s %-6s %-7s %-28s %s\n' 编号 开始时间 任务 状态 操作 退出码 耗时 原因 日志
	while IFS=$'\t' read -r epoch start end id task op status rc duration pid log reason; do
		[ -n "$id" ] || continue; n=$((n + 1))
		printf '%-3s %-19s %-14s %-10s %-10s %-6s %-7s %-28s %s\n' "$n" "${start:0:19}" "$task" "$status" "$op" "$rc" "${duration}s" "${reason:0:28}" "$log"
		[ "$n" -ge 15 ] && break
	done < <(crontab_sync_log_records "$filter")
	[ "$n" -gt 0 ] || echo "暂无执行记录"
}

crontab_sync_log_pick() {
	local wanted="$1" filter="${2:-}" n=0 line
	while IFS= read -r line; do
		n=$((n + 1)); [ "$n" -eq "$wanted" ] && { printf '%s\n' "$line"; return 0; }
		[ "$n" -ge 15 ] && break
	done < <(crontab_sync_log_records "$filter")
	return 1
}

crontab_sync_log_copy() {
	local log="$1" tmp
	[ -f "$log" ] || return 1; tmp=$(mktemp) || return 1
	crontab_sync_log_sanitize "$log" > "$tmp"
	if command -v cpcat >/dev/null 2>&1; then cpcat "$tmp" || { rm -f "$tmp"; return 1; }; else printf '\033]52;c;%s\a' "$(base64 < "$tmp" | tr -d '\n')"; fi
	rm -f "$tmp"; echo "已发送到当前终端剪贴板（需要 SSH/终端支持 OSC 52）"
}

crontab_sync_log_export() {
	local log="$1" out_dir out
	[ -f "$log" ] || return 1; out_dir=$(crontab_sync_log_export_dir)
	mkdir -p "$out_dir" && chmod 700 "$out_dir" || return 1
	out="$out_dir/$(basename "$log" .log).redacted.log"
	crontab_sync_log_sanitize "$log" > "$out" && chmod 600 "$out"; echo "已导出: $out"
}

crontab_sync_log_manager() {
	local choice filter="" number record log
	while true; do
		clear; echo "自动同步记录（最近 15 次）"; echo "日志保留 30 天；列表只读取本地缓存，不访问远程。"
		crontab_sync_log_show_recent "$filter"
		echo "------------------------"; echo "1. 查看最近 15 次"; echo "2. 按任务筛选"; echo "3. 查看某次完整日志"; echo "4. 复制某次日志到剪贴板"; echo "5. 导出某次日志到 /root"; echo "0. 返回"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) filter="" ;;
			2) read -e -p "任务名（如 root、emby、bitwarden）: " filter || return 1 ;;
			3|4|5)
				read -e -p "请输入记录编号（1-15）: " number || return 1
				record=$(crontab_sync_log_pick "$number" "$filter") || { echo "记录不存在"; break_end; continue; }
				IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ log _ <<< "$record"
				[ -f "$log" ] || { echo "日志文件不存在: $log"; break_end; continue; }
				case "$choice" in 3) crontab_sync_log_sanitize "$log" ;; 4) crontab_sync_log_copy "$log" ;; 5) crontab_sync_log_export "$log" ;; esac
				break_end ;;
			0) return ;;
			*) echo "无效的输入!"; break_end ;;
		esac
	done
}

crontab_sync_cron_entry() {
	local minute hour day month weekday command
	read -r minute hour day month weekday command <<< "$1"
	[[ "$minute" =~ ^[0-9]{1,2}$ && "$hour" =~ ^[0-9]{1,2}$ ]] || return 1
	((10#$minute < 60 && 10#$hour < 24)) || return 1
	[ "$day:$month" = '*:*' ] && [[ "$weekday" =~ ^(\*|[0-7])$ ]] || return 1
	local clock
	printf -v clock '%02d:%02d' "$((10#$hour))" "$((10#$minute))"
	printf '* * * * * [ "$(TZ=Asia/Shanghai date +\%%H:\%%M)" = "%s" ]' "$clock"
	if [ "$weekday" != '*' ]; then
		printf ' && [ "$(TZ=Asia/Shanghai date +\%%w)" = "%s" ]' "$((weekday % 7))"
	fi
	printf ' && %s\n' "$command"
}

crontab_sync_remote_ready() {
	local remote
	remote=$(crontab_sync_target_remote)
	command -v rclone >/dev/null 2>&1 || return 1
	rclone lsd "${remote}:" --max-depth 1 >/dev/null 2>&1
}

crontab_sync_legacy_script_file_by_id() {
	case "$1" in
		bitwarden) echo "$(crontab_sync_backup_dir)/Vaultwarden_OneDrive_to_Infini.sh" ;;
		via) echo "$(crontab_sync_backup_dir)/Via_Infini_to_OneDrive.sh" ;;
	esac
}

crontab_sync_root_name() {
    local dir name
    dir=$(crontab_sync_backup_dir)
    name=$(python3 - "$dir" <<'PY'
import hashlib, re, sys
from pathlib import Path
root = Path(sys.argv[1])
marker = root / '.root-backup-name'
if marker.is_file() and not marker.is_symlink():
    names = [marker.read_text().strip()]
else:
    names = []
    for path in root.glob('*.sh'):
        if path.is_symlink(): continue
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() == '29cbcb44c60876dbd5b77eeb6a95790623e657cf9a6c67da5f34fc356a2e9282' or (b'# DAIMON_CHAIN_BACKUP_VERSION=' in data and b'TASK_KIND="root"\n' in data):
            names.append(path.stem)
if len(names) != 1 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', names[0]) or names[0] in ('Root_Backup', 'Emby', 'Emby_Root_Backup'):
    sys.exit('ERROR: Cannot uniquely identify the server backup name; create a server-named root task first')
print(names[0])
PY
    ) || return 1
    printf '%s\n' "$name"
}

crontab_sync_prompt_root_name() {
    local dir name
    if name=$(crontab_sync_root_name 2>/dev/null); then
        printf '%s\n' "$name"
        return 0
    fi
    read -e -p "请输入此服务器的 /root 备份名称（例如 Oracle-GuLai-4C24G）: " name || return 1
    name=$(basename "$name")
    name=$(printf '%s' "$name" | sed 's/[[:space:]]/_/g; s/[^A-Za-z0-9_.-]/_/g')
    [ -n "$name" ] && [ "$name" != Root_Backup ] && [ "$name" != Emby ] && [ "$name" != Emby_Root_Backup ] || {
        echo -e "${gl_hong}服务器备份名称无效${gl_bai}"
        return 1
    }
    dir=$(crontab_sync_backup_dir)
    mkdir -p "$dir" || return 1
    printf '%s\n' "$name" > "$dir/.root-backup-name" || return 1
    printf '%s\n' "$name"
}

crontab_sync_upgrade_installed() (
    set -euo pipefail
    umask 077
    local dir stage
    dir=$(crontab_sync_backup_dir)
    [ -d "$dir" ] || return 0
    [ ! -L "$dir" ] || { echo 'ERROR: Symlink backup directory' >&2; return 1; }
    command -v python3 >/dev/null || { echo 'ERROR: python3 required to check installed backup versions' >&2; return 1; }
    mkdir -p "${DAIMON_LOCK_DIR:-/run/lock}"
    exec 7>"${DAIMON_LOCK_DIR:-/run/lock}/daimon-backup-scripts.lock"
    flock -xn 7 || { echo 'ERROR: Backup scripts active; upgrade deferred' >&2; return 1; }
    exec 8>"${DAIMON_LOCK_DIR:-/run/lock}/daimon-rclone-backups.lock"
    flock -xn 8 || { echo 'ERROR: Backup running; upgrade deferred' >&2; return 1; }
    stage=$(mktemp -d "$dir/.upgrade.XXXXXX")
    trap 'rm -f -- "$stage"/*.sh; rmdir -- "$stage"' EXIT
    export DAIMON_SKIP_RUNNER_WRITE=1 DAIMON_UPGRADE_LOCKED=1
    export -f crontab_sync_write_script crontab_sync_root_name crontab_sync_backup_dir crontab_sync_log_dir
    python3 - "$dir" "$stage" <<'PY' || return 1
import hashlib, os, re, subprocess, sys, tempfile
from pathlib import Path
root, stage = (Path(arg).resolve() for arg in sys.argv[1:])
assert stage.parent == root and stage.name.startswith('.upgrade.')
known = {
    '29cbcb44c60876dbd5b77eeb6a95790623e657cf9a6c67da5f34fc356a2e9282': 'root',
    '069e16aeac132d368245114ffa001a87d61b2818443812de59be7eeacb4089ec': 'root',
    '4558aee3c75b35dd1640e086edd220e85a5c761100c9c27746ee8d2a2f223105': 'emby',
}
managed = {}
for path in root.glob('*.sh'):
    if path.is_symlink():
        if path.name in ('Root_Backup.sh', 'Emby_Root_Backup.sh'): sys.exit('ERROR: Managed script is a symlink')
        continue
    data = path.read_bytes()
    kind = known.get(hashlib.sha256(data).hexdigest())
    if re.search(rb'^# DAIMON_CHAIN_BACKUP_VERSION=\d+$', data, re.M):
        match = re.search(rb'^TASK_KIND="(root|emby)"$', data, re.M)
        if not match: sys.exit('ERROR: Invalid managed task header')
        kind = match[1].decode()
    if kind: managed[path] = kind
    elif path.name in ('Root_Backup.sh', 'Emby_Root_Backup.sh'):
        sys.exit('ERROR: Unknown installed backup template: ' + str(path))
if not managed:
    print('BACKUP_UPGRADE no installed root/Emby tasks')
    sys.exit(0)
roots = [path for path, kind in managed.items() if kind == 'root' and path.name != 'Root_Backup.sh']
if len(roots) > 1: sys.exit('ERROR: Multiple server root tasks; identity is ambiguous')
name = roots[0].stem if roots else None
marker = root / '.root-backup-name'
if marker.exists():
    if marker.is_symlink(): sys.exit('ERROR: Symlink identity marker')
    saved = marker.read_text().strip()
    if name and name != saved: sys.exit('ERROR: Saved server identity conflicts with installed script')
    name = saved
if any(kind == 'root' for kind in managed.values()):
    if not name or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) or name in ('Root_Backup', 'Emby', 'Emby_Root_Backup'):
        sys.exit('ERROR: Server backup name is required; no task changed')
    canonical = root / (name + '.sh')
    if canonical.exists() and canonical not in managed: sys.exit('ERROR: Unknown custom script at canonical path')
else:
    canonical = None
# Old jobs do not all use the upgrade lock.
for proc in Path('/proc').glob('[0-9]*/cmdline'):
    try: args = proc.read_bytes().split(b'\0')
    except (FileNotFoundError, PermissionError, ProcessLookupError): continue
    if any(os.fsencode(path) in args for path in managed):
        sys.exit('ERROR: Installed backup process is active; upgrade deferred')
desired = {}
for path, kind in managed.items():
    target = canonical if kind == 'root' else path
    if target in desired: continue
    temporary = stage / target.name
    subprocess.run(['bash', '-c', 'crontab_sync_write_script "$1" "$2"', 'upgrade', kind, str(temporary)], check=True)
    desired[target] = temporary.read_bytes()
if canonical: desired[marker] = (name + '\n').encode()
old = root / 'Root_Backup.sh'
obsolete = [old] if old in managed and old != canonical else []
cron = subprocess.run(['crontab', '-l'], capture_output=True)
if cron.returncode != 0 and not (cron.returncode == 1 and b'no crontab for' in cron.stderr.lower()):
    sys.exit('ERROR: Cannot read existing crontab')
before = cron.stdout
lines = before.decode().splitlines(keepends=True)
after_lines, seen_root = [], False
for line in lines:
    active = not line.lstrip().startswith('#')
    root_line = active and canonical and any(re.search(re.escape(str(path)) + r'(?=\s|$)', line) for path, kind in managed.items() if kind == 'root')
    if root_line:
        if seen_root: continue
        seen_root = True
        line = re.sub(re.escape(str(old)) + r'(?=\s|$)', lambda _: str(canonical), line)
        line = re.sub(r'(\.rclone-runner\.sh\s+)(?:custom:[^\s]+|root)(\s+)', r'\1root\2', line)
    after_lines.append(line)
after = ''.join(after_lines).encode()
changes = {p: data for p, data in desired.items() if not p.exists() or p.read_bytes() != data}
if not changes and not obsolete and after == before:
    print('BACKUP_UPGRADE current')
    sys.exit(0)
# Keep rollback bytes only in memory for this transaction; no persistent backup-of-backup.
previous = {p: (p.read_bytes(), p.stat().st_mode & 0o777) if p.exists() else None for p in set(changes) | set(obsolete)}
def write(path, data, mode):
    assert path.parent == root and not path.is_symlink()
    fd, temporary = tempfile.mkstemp(prefix='.replace.', dir=root)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data); out.flush(); os.fsync(out.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
cron_changed = False
try:
    for path, data in changes.items(): write(path, data, 0o600 if path == marker else 0o700)
    current = subprocess.run(['crontab', '-l'], capture_output=True)
    if current.stdout != before or current.returncode != cron.returncode: raise RuntimeError('Crontab changed during upgrade')
    if after != before:
        subprocess.run(['crontab', '-'], input=after, check=True)
        cron_changed = True
        if subprocess.check_output(['crontab', '-l']) != after: raise RuntimeError('Crontab verification failed')
    for path in obsolete:
        assert path.parent == root and path.name == 'Root_Backup.sh' and not path.is_symlink()
        path.unlink()
except BaseException:
    for path, saved in previous.items():
        if saved is None: path.unlink(missing_ok=True)
        else: write(path, *saved)
    if cron_changed: subprocess.run(['crontab', '-'], input=before, check=True)
    raise
print('BACKUP_UPGRADE updated=' + ','.join(p.name for p in changes) + ' removed=' + ','.join(p.name for p in obsolete))
PY
    crontab_sync_write_run_tools
)

crontab_sync_script_file_by_id() {
	case "$1" in
		bitwarden) echo "$(crontab_sync_backup_dir)/Vaultwarden_OneDrive_to_Kissska1.sh" ;;
		imagebed) echo "$(crontab_sync_backup_dir)/ImageBed_CloudFlare-R2_to_OneDrive.sh" ;;
		via) echo "$(crontab_sync_backup_dir)/Via_OneDrive_to_Kissska1.sh" ;;
		nginxdomain) echo "$(crontab_sync_backup_dir)/Nginx_Domain_Local_Backup.sh" ;;
		root) local name; name=$(crontab_sync_root_name) || return 1; echo "$(crontab_sync_backup_dir)/$name.sh" ;;
		emby) echo "$(crontab_sync_backup_dir)/Emby_Root_Backup.sh" ;;
		custom) echo "$(crontab_sync_backup_dir)/$2" ;;
	esac
}

crontab_sync_cron_line_by_id() {
	local id="$1"
	local script_file="$2"
	local runner
	runner=$(crontab_sync_runner_file)
	local line
	line=$(case "$id" in
		bitwarden) echo "5 5 * * * /bin/bash $runner bitwarden $script_file >> /var/log/rclone/cron_Vaultwarden_OneDrive_to_Kissska1.log 2>&1" ;;
		imagebed) echo "10 4 * * * /bin/bash $runner imagebed $script_file >> /var/log/rclone/cron_ImageBed_CloudFlare-R2_to_OneDrive.log 2>&1" ;;
		via) echo "15 4 * * * /bin/bash $runner via $script_file >> /var/log/rclone/cron_Via_OneDrive_to_Kissska1.log 2>&1" ;;
		nginxdomain) echo "0 4 * * * /bin/bash $runner nginxdomain $script_file >> /var/log/rclone/cron_Nginx_Domain_Local_Backup.log 2>&1" ;;
		root) echo "25 4 * * * /bin/bash $runner root $script_file >> /var/log/rclone/cron_Root_Backup.log 2>&1" ;;
		emby) echo "45 5 * * 0 /bin/bash $runner emby $script_file >> /var/log/rclone/cron_Emby_Root_Backup.log 2>&1" ;;
		custom)
			local script_base
			script_base=$(basename "$script_file" .sh)
			echo "45 4 * * * /bin/bash $runner custom:$script_base $script_file >> /var/log/rclone/cron_${script_base}.log 2>&1"
			;;
	esac) || return 1
	crontab_sync_cron_entry "$line"
}

crontab_sync_script_content_ok() {
	local id="$1"
	local script_file="$2"
	[ -f "$script_file" ] || return 1
	case "$id" in
		bitwarden)
			grep -q 'SRC_REMOTE="qq3303338052@outlook:/BitwardenBackup"' "$script_file" 2>/dev/null \
				&& grep -q 'DEST_REMOTE="kissska1:/BitwardenBackup"' "$script_file" 2>/dev/null \
				&& grep -q 'rclone sync' "$script_file" 2>/dev/null
			;;
		imagebed)
			grep -q 'qq3303338052@cloudflare:image-bed-daimon' "$script_file" 2>/dev/null \
				&& grep -q 'qq3303338052@outlook:image-bed-daimon' "$script_file" 2>/dev/null \
				&& grep -q 'rclone sync' "$script_file" 2>/dev/null
			;;
		via)
			grep -q '"qq3303338052@outlook:Via"' "$script_file" 2>/dev/null \
				&& grep -q '"kissska1:Via"' "$script_file" 2>/dev/null \
				&& grep -q 'rclone sync' "$script_file" 2>/dev/null
			;;
        nginxdomain)
            # Accept current and legacy generated Nginx backup scripts.
            if grep -q 'BACKUP_DIR="\$BACKUP_ROOT/auto_latest"' "$script_file" 2>/dev/null &&
               grep -Eq 'rclone_nginx_write_bundle|copy_backup_item' "$script_file" 2>/dev/null &&
               grep -q 'manifest.txt' "$script_file" 2>/dev/null; then
                return 0
            fi
            return 1
            ;;
        root|emby|custom)
            local stage expected result=1
            stage=$(mktemp -d) || return 1
            expected="$stage/$(basename "$script_file")"
            if DAIMON_SKIP_RUNNER_WRITE=1 crontab_sync_write_script "$id" "$expected" && cmp -s "$expected" "$script_file"; then result=0; fi
            rm -f -- "$expected"
            rmdir -- "$stage"
            return "$result"
            ;;
	esac
}

crontab_sync_status_text() {
	local id="$1"
	local script_file="$2"
	local cron_line="$3"
	local has_file=false
	local content_ok=false
	local has_cron=false
	local cron_output=""

	[ -f "$script_file" ] && has_file=true
	cron_output=$(crontab -l 2>/dev/null || true)
    # Status is path based: legacy entries may use a different time, runner, or timezone wrapper.
    # Ignore comments and require the managed script path as a standalone shell argument.
    if printf '%s\n' "$cron_output" | sed '/^[[:space:]]*#/d' | grep -Eq "(^|[[:space:]])$(printf '%s' "$script_file" | sed 's/[.[\\^$*+?(){|]/\\&/g')([[:space:]]|$)"; then
        has_cron=true
    fi
	crontab_sync_script_content_ok "$id" "$script_file" && content_ok=true

	if $has_file && $content_ok && $has_cron; then
		echo -e "${gl_lv}已安装${gl_bai}"
	elif $has_file && ! $content_ok && $has_cron; then
		echo -e "${gl_huang}已加入定时，脚本内容异常${gl_bai}"
	elif $has_file && $content_ok && ! $has_cron; then
		echo -e "${gl_huang}脚本已存在，未加入定时${gl_bai}"
	elif ! $has_file && $has_cron; then
		echo -e "${gl_huang}定时任务存在，脚本不存在${gl_bai}"
	else
		echo -e "${gl_hong}未安装${gl_bai}"
	fi
}

crontab_sync_builtin_name_by_id() {
	case "$1" in
		bitwarden) echo "bitwarden同步脚本" ;;
		imagebed) echo "图床同步脚本" ;;
		via) echo "via同步脚本" ;;
		nginxdomain) echo "域名和nginx配置备份脚本" ;;
		root) echo "/root Docker一致性备份脚本" ;;
		emby) echo "Emby目录备份脚本" ;;
	esac
}

crontab_sync_builtin_id_by_number() {
	case "$1" in
		1) echo "bitwarden" ;;
		2) echo "imagebed" ;;
		3) echo "via" ;;
		4) echo "nginxdomain" ;;
		5) echo "emby" ;;
		6) echo "root" ;;
	esac
}

crontab_sync_custom_files() {
	local dir
	dir=$(crontab_sync_backup_dir)
	[ -d "$dir" ] || return 0
	find "$dir" -maxdepth 1 -type f -name '*.sh' \
		! -name '.rclone-runner.sh' \
		! -name 'Vaultwarden_OneDrive_to_Kissska1.sh' \
		! -name 'ImageBed_CloudFlare-R2_to_OneDrive.sh' \
		! -name 'Via_OneDrive_to_Kissska1.sh' \
		! -name 'Nginx_Domain_Local_Backup.sh' \
		! -name 'Root_Backup.sh' \
		! -name 'Emby_Root_Backup.sh' \
		-printf '%f\n' 2>/dev/null | sort | { local name; name=$(crontab_sync_root_name 2>/dev/null) || name=''; while IFS= read -r file; do [ "$file" = "$name.sh" ] || printf '%s\n' "$file"; done; }
}

crontab_sync_write_script() (
	umask 077
	local id="$1"
	local target="$2" script_file
    if [ "${DAIMON_UPGRADE_LOCKED:-0}" != 1 ]; then
        mkdir -p "${DAIMON_LOCK_DIR:-/run/lock}" || return 1
        exec 7>"${DAIMON_LOCK_DIR:-/run/lock}/daimon-backup-scripts.lock"
        flock -xn 7 || { echo 'ERROR: Backup running; script replacement deferred' >&2; return 1; }
    fi
	mkdir -p "$(dirname "$target")" "$(crontab_sync_log_dir)" || return 1
	script_file=$(mktemp "${target}.XXXXXX") || return 1
	trap 'rm -f -- "$script_file"' EXIT
	case "$id" in
		bitwarden)
			cat > "$script_file" <<'EOF'
#!/bin/bash
set -euo pipefail

# ========= 源与目标 =========
SRC_REMOTE="qq3303338052@outlook:/BitwardenBackup"
DEST_REMOTE="kissska1:/BitwardenBackup"

# ========= 日志 =========
LOG_DIR="/var/log/rclone"
LOG_FILE="${DAIMON_RUN_LOG:-$LOG_DIR/vaultwarden_backup_sync_$(date +%F).log}"
LOCK_FILE="/run/lock/daimon-rclone-backups.lock"

install -d -m 700 "$LOG_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -x 9

echo "===== $(date) 开始同步 Vaultwarden 备份（sync） =====" >> "$LOG_FILE"

# ========= rclone sync =========
rclone sync \
  "$SRC_REMOTE" "$DEST_REMOTE" \
  --transfers=4 \
  --checkers=8 \
  --fast-list \
  --progress \
  --log-file="$LOG_FILE" \
  --log-level INFO

echo "===== $(date) Vaultwarden 备份同步完成（sync） =====" >> "$LOG_FILE"
EOF
			;;
		imagebed)
			cat > "$script_file" <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/rclone"
LOG_FILE="${DAIMON_RUN_LOG:-$LOG_DIR/r2_to_onedrive_imagebed.log}"
LOCK_FILE="/run/lock/daimon-rclone-backups.lock"

install -d -m 700 "$LOG_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -x 9

rclone sync \
  qq3303338052@cloudflare:image-bed-daimon \
  qq3303338052@outlook:image-bed-daimon \
  --transfers=8 \
  --checkers=16 \
  --onedrive-chunk-size=100M \
  --progress \
  --log-file="$LOG_FILE" \
  --log-level INFO
EOF
			;;
		via)
			cat > "$script_file" <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/rclone"
LOG_FILE="${DAIMON_RUN_LOG:-$LOG_DIR/outlook_to_kissska1_via.log}"
LOCK_FILE="/run/lock/daimon-rclone-backups.lock"

install -d -m 700 "$LOG_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -x 9

rclone sync \
  "qq3303338052@outlook:Via" \
  "kissska1:Via" \
  --transfers=8 \
  --checkers=16 \
  --progress \
  --log-file="$LOG_FILE" \
  --log-level INFO
EOF
			;;
		nginxdomain)
			rclone_nginx_write_backup_script "$script_file"
			;;
		root|emby|custom)
            local backup_name kind source
            if [ "$id" = emby ]; then
                backup_name=Emby; kind=emby; source=/root/emby
            else
                backup_name=$(basename "$target" .sh)
                if [ "$backup_name" = Root_Backup ]; then
                    backup_name=$(crontab_sync_root_name) || return 1
                fi
                [[ "$backup_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && [ "$backup_name" != Root_Backup ] || { echo 'ERROR: A persistent server backup name is required' >&2; return 1; }
                kind=root; source=/root
            fi
            printf '#!/bin/bash\n# DAIMON_CHAIN_BACKUP_VERSION=1\nTASK_KIND="%s"\nBACKUP_NAME="%s"\nSRC1="%s"\n' "$kind" "$backup_name" "$source" > "$script_file"
            cat >> "$script_file" <<'EOF'
set -Eeuo pipefail
umask 077

PRIMARY="qq3303338052@outlook:$BACKUP_NAME"
SECONDARY="kissska1:$BACKUP_NAME"
LOG_DIR="/var/log/rclone"
LOG_FILE="${DAIMON_RUN_LOG:-$LOG_DIR/${BACKUP_NAME}_$(date +%Y%m%d-%H%M%S)-$$.log}"
RUNTIME_DIR="${DAIMON_LOCK_DIR:-/run/lock}"
LOCK_FILE="$RUNTIME_DIR/daimon-${TASK_KIND}-root-backup.lock"
GLOBAL_LOCK_FILE="$RUNTIME_DIR/daimon-rclone-backups.lock"
STATE_DIR="$RUNTIME_DIR/daimon-$TASK_KIND"
STATE_FILE="$STATE_DIR/containers.pending"
SUCCESS_FILE="$LOG_DIR/${BACKUP_NAME}.last-success"
PRIMARY_SUCCESS="$LOG_DIR/${BACKUP_NAME}.qq-success"
if [ "$TASK_KIND" = root ] && [ -z "${DAIMON_RUN_LOG:-}" ]; then
    runner="$(dirname "$(readlink -f "$0")")/.rclone-runner.sh"
    [ -x "$runner" ] || { echo 'ERROR: Missing bounded-log runner; update the installed backup task'; exit 1; }
    exec bash "$runner" root "$0"
fi
STAGE=preflight
INVENTORY="" MOUNTS="" CHILD_PID="" GENERATION="" AFTER_GENERATION=""
OWNS_STATE=0 BACKUP_OK=0
WORK_DIR="" METADATA_ROOT="" PRIMARY_VERIFIED=0 WRITERS_RESUMED=0
FILTERS=(--exclude '/logs/**' --exclude '**/logs/**' --exclude '/*.log' --exclude '**/*.log'
    --exclude '/.migration-*/**' --exclude '**/.migration-*/**'
    --exclude '/.tmp/**' --exclude '**/.tmp/**')
if [ "$TASK_KIND" = root ]; then
    FILTERS+=(--exclude '/.cache/**' --exclude '/.npm/**' --exclude '/.nvm/**' --exclude '/emby/**'
        --exclude '**/node_modules/**' --exclude '/*.tmp' --exclude '**/*.tmp'
        --exclude '/*.temp' --exclude '**/*.temp'
        --exclude '/linux-daimon/backup/nginx-domain/.bundle*'
        --exclude '/linux-daimon/backup-sh/.upgrade*/**'
        --exclude '/linux-daimon/rclone-logs/**'
        --exclude '/linux-daimon/backup/nginx-domain/script-update-*/**'
        --exclude '/linux-daimon/backup/nginx-domain/challenge-fix-*/**'
        --exclude '/linux-daimon/backup/nginx-domain/migration_*/**'
        --exclude '/linux-daimon/backup/nginx-domain/cpa-renew-20260820_112206/**')
    exclude_file="${DAIMON_ROOT_EXCLUDE_FILE:-$(dirname "$(readlink -f "$0")")/.root-backup.exclude}"
    if [ -e "$exclude_file" ] || [ -L "$exclude_file" ]; then
        [ -f "$exclude_file" ] && [ ! -L "$exclude_file" ] || { echo 'ERROR: Unsafe root exclusion file'; exit 1; }
        while IFS= read -r pattern || [ -n "$pattern" ]; do
            pattern=${pattern%$'\r'}
            case "$pattern" in ''|'#'*) continue ;; esac
            FILTERS+=(--exclude "$pattern")
        done < "$exclude_file"
    fi
fi
NETWORK=(--bwlimit=0 --transfers=4 --checkers=8 --contimeout=30s --timeout=2m --retries=3 --low-level-retries=2
    --log-file="$LOG_FILE" --log-level INFO)
if [ "$TASK_KIND" = root ]; then
    backup_transfers=${DAIMON_ROOT_TRANSFERS:-4}
    backup_checkers=${DAIMON_ROOT_CHECKERS:-8}
    backup_tps=${DAIMON_ROOT_TPS_LIMIT:-4}
    [[ "$backup_transfers" =~ ^[1-9][0-9]?$ ]] && [ "$backup_transfers" -le 32 ] &&
        [[ "$backup_checkers" =~ ^[1-9][0-9]?$ ]] && [ "$backup_checkers" -le 64 ] &&
        [[ "$backup_tps" =~ ^[1-9][0-9]?$ ]] && [ "$backup_tps" -le 32 ] || {
        echo 'ERROR: Root transfers/TPS must be 1-32 and checkers 1-64'; exit 1;
    }
    NETWORK[1]="--transfers=$backup_transfers"
    NETWORK[2]="--checkers=$backup_checkers"
    NETWORK[6]=--low-level-retries=10
    NETWORK+=(--tpslimit="$backup_tps" --tpslimit-burst=1)
fi

for tool in flock python3 rclone timeout; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'ERROR: 缺少依赖 %s\n' "$tool" >&2; exit 1; }
done
install -d -m 700 "$LOG_DIR"
mkdir -p "$RUNTIME_DIR"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec 7>"$RUNTIME_DIR/daimon-backup-scripts.lock"
flock -s 7
exec 9>"$LOCK_FILE"
flock -n 9 || { printf '%s\n' "已有 $BACKUP_NAME 备份运行，跳过本次任务" >> "$LOG_FILE"; exit 0; }
exec 8>"$GLOBAL_LOCK_FILE"
flock -x 8
root_services() {
    [ "$TASK_KIND" = root ] || return 0
    python3 - "$1" "$STATE_DIR/services.pending" "${DAIMON_ROOT_SERVICES_FILE:-$(dirname "$(readlink -f "$0")")/.root-backup.services}" <<'PYSERVICES'
import json, os, re, subprocess, sys, tempfile
from pathlib import Path
mode, journal, config = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
def read(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError('Unsafe service configuration/recovery file')
    return path.read_text()
def valid(unit):
    return isinstance(unit,str) and re.fullmatch(r'[A-Za-z0-9_:@.\-]+\.service',unit) and not unit.startswith('-')
def call(*args):
    result = subprocess.run(['systemctl',*args],capture_output=True,text=True,timeout=180)
    if result.returncode:
        raise RuntimeError('systemctl failed: ' + ' '.join(args[:2]))
    return result.stdout
def state(unit):
    values = dict(line.split('=',1) for line in call('show',unit,'--property=LoadState,ActiveState,CanStop,RefuseManualStop,RefuseManualStart,TriggeredBy').splitlines() if '=' in line)
    if values.get('LoadState') != 'loaded':
        raise RuntimeError('Service is unavailable: ' + unit)
    return values
try:
    units = []
    if journal.exists() or journal.is_symlink():
        units = json.loads(read(journal))
        if not isinstance(units,list) or any(not valid(unit) for unit in units):
            raise RuntimeError('Invalid service recovery journal')
    if mode == 'stop':
        if journal.exists():
            raise RuntimeError('Pending service recovery must finish first')
        if not config.exists() and not config.is_symlink():
            sys.exit(0)
        selected = list(dict.fromkeys(line.strip() for line in read(config).splitlines() if line.strip() and not line.lstrip().startswith('#')))
        if any(not valid(unit) for unit in selected):
            raise RuntimeError('Invalid backup service name; expected explicit .service units')
        for unit in selected:
            info = state(unit)
            if info.get('ActiveState') in ('inactive','failed'):
                continue
            if info.get('ActiveState') != 'active' or info.get('CanStop') != 'yes' or info.get('RefuseManualStop') == 'yes' or info.get('RefuseManualStart') == 'yes':
                raise RuntimeError('Service cannot be safely paused: ' + unit)
            if info.get('TriggeredBy'):
                raise RuntimeError('Timer/socket-triggered services require a separate pause policy: ' + unit)
            units.append(unit)
        fd, temporary = tempfile.mkstemp(prefix='.services.',dir=journal.parent)
        try:
            with os.fdopen(fd,'w') as output:
                json.dump(units,output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary,journal)
            descriptor = os.open(journal.parent,os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            Path(temporary).unlink(missing_ok=True)
        for unit in reversed(units):
            call('stop',unit)
            if state(unit).get('ActiveState') != 'inactive':
                raise RuntimeError('Service did not stop: ' + unit)
        print('HOST_SERVICES_PAUSED count=' + str(len(units)))
    elif mode == 'verify':
        for unit in units:
            if state(unit).get('ActiveState') != 'inactive':
                raise RuntimeError('Service restarted during primary backup: ' + unit)
    elif mode in ('resume','finish','reconcile'):
        failed = []
        for unit in units:
            try:
                call('start',unit)
                if state(unit).get('ActiveState') != 'active':
                    raise RuntimeError('Service did not become active')
            except (RuntimeError,subprocess.TimeoutExpired):
                failed.append(unit)
        if failed:
            raise RuntimeError('Service recovery failed; journal retained: ' + ', '.join(failed))
        if units:
            print('HOST_SERVICES_RESUMED count=' + str(len(units)))
        if mode != 'resume':
            journal.unlink(missing_ok=True)
    else:
        raise RuntimeError('Invalid service recovery operation')
except (OSError,ValueError,RuntimeError,subprocess.TimeoutExpired) as error:
    sys.exit('ERROR: ' + str(error))
PYSERVICES
}

install -d -m 700 "$STATE_DIR"
if [ "$TASK_KIND" = root ]; then
    STATE_DIR="${DAIMON_ROOT_STATE_DIR:-/var/lib/daimon/root-backups/$BACKUP_NAME}"
    [ ! -L "$STATE_DIR" ] || { echo 'ERROR: Recovery directory is a symlink'; exit 1; }
    install -d -m 700 "$STATE_DIR"
    STATE_FILE="$STATE_DIR/containers.pending"
    root_services reconcile
    # An old ID-only journal is reconciled only when every surviving container is ready.
    python3 - "$RUNTIME_DIR/daimon-root/containers.pending" "$STATE_FILE" <<'PYROOT'
import json, os, re, subprocess, sys, time
from pathlib import Path
for path in dict.fromkeys(Path(p) for p in sys.argv[1:]):
    if not path.exists():
        continue
    if path.is_symlink() or not path.is_file():
        sys.exit('ERROR: Unsafe recovery journal')
    ids = path.read_text().splitlines()
    if any(not re.fullmatch('[a-f0-9]{12,64}', cid) for cid in ids):
        sys.exit('ERROR: Invalid recovery journal; manual review required')
    live = subprocess.run(['docker', 'ps', '-aq', '--no-trunc'], capture_output=True, text=True, timeout=30)
    if live.returncode:
        sys.exit('ERROR: Cannot inventory Docker; recovery journal retained')
    all_ids = live.stdout.splitlines()
    removed = []
    metadata = path.with_name('writers.json')
    known = json.loads(metadata.read_text()).get('names', {}) if metadata.exists() else {}
    recovery = []
    for cid in ids:
        matches = [value for value in all_ids if value.startswith(cid)]
        if not matches:
            removed.append(cid)
            continue
        state = subprocess.run(['docker', 'inspect', '-f', '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', cid], capture_output=True, text=True, timeout=30)
        if state.returncode:
            sys.exit('ERROR: Cannot inspect previous writer; journal retained')
        if state.stdout.strip() not in ('true none', 'true healthy'):
            if cid not in known:
                sys.exit('ERROR: Previous writer still needs recovery: ' + cid + '; journal retained')
            recovery.append(cid)
    for cid in recovery:
        if subprocess.run(['docker','start',cid], stdout=subprocess.DEVNULL, timeout=60).returncode:
            sys.exit('ERROR: Previous writer start failed; journal retained')
    budget = 180
    for cid in recovery:
        info = subprocess.run(['docker','inspect','-f','{{json .Config.Healthcheck}}',cid],capture_output=True,text=True,timeout=30)
        try:
            health = json.loads(info.stdout) or {}
            seconds = (health.get('StartPeriod',0) + ((health.get('Interval') or 30000000000) + (health.get('Timeout') or 30000000000)) * (health.get('Retries') or 3)) // 1000000000 + 30
            budget = max(budget, min(3600, seconds))
        except (ValueError, TypeError, AttributeError):
            pass
    budget = int(os.environ.get('DAIMON_RECOVERY_TIMEOUT',budget))
    if not 1 <= budget <= 3600: sys.exit('ERROR: Invalid recovery timeout')
    deadline = time.monotonic() + budget
    while recovery:
        pending = []
        for cid in recovery:
            state = subprocess.run(['docker','inspect','-f','{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',cid],capture_output=True,text=True,timeout=30)
            if state.returncode or state.stdout.strip() not in ('true none','true healthy'):
                pending.append(cid)
        if not pending: break
        if time.monotonic() >= deadline:
            sys.exit('ERROR: Previous writers not healthy; journal retained')
        recovery = pending
        time.sleep(1)
    audit = path.with_name('recovery-last.json')
    audit.write_text(json.dumps({'resolved_ids': ids, 'removed_ids': removed}))
    os.chmod(audit, 0o600)
    path.unlink()
    print('RECOVERY_RECONCILED ready=' + str(len(ids)-len(removed)) + ' removed=' + str(len(removed)))
PYROOT
fi
[ ! -e "$STATE_FILE" ] || { printf 'ERROR: 存在待恢复容器清单，确认恢复后再重试: %s\n' "$STATE_FILE" >> "$LOG_FILE"; exit 1; }
rm -f -- "$SUCCESS_FILE" "$PRIMARY_SUCCESS"
if [ "$TASK_KIND" = root ] && [ -d "$SRC1/linux-daimon/backup/nginx-domain" ]; then
    exec 6>"$SRC1/linux-daimon/backup/nginx-domain/.bundle.lock"
    flock -x 6
fi

container_state() {
    timeout 30s docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>> "$LOG_FILE"
}

stop_transfer() {
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
}

container_recovery_timeout() {
    if [ -n "${DAIMON_RECOVERY_TIMEOUT:-}" ]; then printf '%s\n' "$DAIMON_RECOVERY_TIMEOUT"; return; fi
    local timing budget
    timing=$(timeout 30s docker inspect -f '{{json .Config.Healthcheck}}' "$1" 2>/dev/null) || timing=""
    budget=$(python3 - "$timing" <<'PYHEALTH'
import json, sys
try:
    config = json.loads(sys.argv[1]) or {}
    if not config:
        print(180)
        sys.exit(0)
    start = int(config.get('StartPeriod') or 0)
    interval = int(config.get('Interval') or 30000000000)
    timeout = int(config.get('Timeout') or 30000000000)
    retries = int(config.get('Retries') or 3)
    seconds = (start + (interval + timeout) * retries + 999999999) // 1000000000 + 30
    print(max(180, min(3600, seconds)))
except (ValueError, TypeError, AttributeError):
    print(180)
PYHEALTH
    ) || budget=180
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=180
    printf '%s\n' "$budget"
}

recover_writers() {
    local id state deadline recovery_failed=0 LOG_FILE="$LOG_FILE"
    if [ "$OWNS_STATE" -eq 1 ]; then
        if [ "$TASK_KIND" = root ]; then
            # Recovery must remain executable even when the log filesystem fails.
            LOG_FILE=/dev/null
        fi
        if [ "$TASK_KIND" = root ]; then
            # Start every original writer before waiting for readiness of any writer.
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                if [ -f "${STATE_DIR:-}/dependencies.tsv" ]; then
                    local dependency
                    for dependency in $(awk -v id="$id" '$1==id {for(i=2;i<=NF;i++) print $i}' "$STATE_DIR/dependencies.tsv"); do
                        deadline=$((SECONDS + $(container_recovery_timeout "$dependency")))
                        while true; do
                            state=$(container_state "$dependency") || state=""
                            case "$state" in 'true healthy'|'true none') break ;; esac
                            [ "$SECONDS" -lt "$deadline" ] || { recovery_failed=1; break; }
                            sleep 1
                        done
                    done
                fi
                state=$(container_state "$id") || state=""
                if [ "${state%% *}" != true ]; then
                    timeout 60s docker start "$id" >> "$LOG_FILE" 2>&1 || recovery_failed=1
                fi
            done < "$STATE_FILE"
            if [ "${1:-}" = start-only ]; then
                writers_running || return 1
                WRITERS_RESUMED=1
                return 0
            fi
        fi
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            state=$(container_state "$id") || state=""
            if [ "${state%% *}" != true ]; then
                timeout 60s docker start "$id" >> "$LOG_FILE" 2>&1 || { recovery_failed=1; continue; }
            fi
            deadline=$((SECONDS + 60))
            if [ "$TASK_KIND" = root ]; then deadline=$((SECONDS + $(container_recovery_timeout "$id"))); fi
            while true; do
                state=$(container_state "$id") || state=""
                case "$state" in 'true none'|'true healthy') break ;; esac
                if [ "$SECONDS" -ge "$deadline" ] || { [ "$TASK_KIND" != root ] && [ "$state" != 'true starting' ]; }; then
                    printf 'ERROR: 备份相关容器恢复验证失败: %s (%s)\n' "$id" "$state" >&2
                    recovery_failed=1
                    break
                fi
                sleep 1
            done
        done < "$STATE_FILE"
        if [ "$recovery_failed" -eq 0 ]; then
            if rm -f -- "$STATE_FILE"; then OWNS_STATE=0; else recovery_failed=1; fi
        else
            printf 'ERROR: 请检查并恢复清单中的原运行容器: %s\n' "$STATE_FILE" >&2
        fi
    fi
    return "$recovery_failed"
}

writers_running() {
    local id state
    [ -f "$STATE_FILE" ] || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        state=$(container_state "$id") || return 1
        [ "${state%% *}" = true ] || return 1
    done < "$STATE_FILE"
}

restore_containers() {
    local rc=$? recovery_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e
    stop_transfer
    recover_writers || recovery_failed=1
    root_services finish || recovery_failed=1
    [ -z "$INVENTORY" ] || rm -f -- "$INVENTORY"
    [ -z "$MOUNTS" ] || rm -f -- "$MOUNTS"
    [ -z "$GENERATION" ] || rm -f -- "$GENERATION"
    [ -z "$AFTER_GENERATION" ] || rm -f -- "$AFTER_GENERATION"
    if [ -n "$WORK_DIR" ]; then
        case "$(realpath -m "$WORK_DIR")" in "$(realpath -m "$WORK_BASE")"/run.*) [ -f "$WORK_DIR/.daimon-work" ] && rm -rf -- "$WORK_DIR" ;; esac
    fi
    if [ "$rc" -eq 0 ] && [ "$BACKUP_OK" -eq 1 ] && [ "$recovery_failed" -eq 0 ]; then
        if date -Is > "$SUCCESS_FILE" && chmod 600 "$SUCCESS_FILE"; then
            printf '===== %s %s 双备份完成 =====\n' "$(date -Is)" "$BACKUP_NAME" >> "$LOG_FILE"
        else
            rm -f -- "$SUCCESS_FILE"
            rc=1
        fi
    else
        [ "$rc" -ne 0 ] || rc=1
        printf 'ERROR: stage=%s rc=%s qq_verified=%s secondary_verified=%s recovery_failed=%s\n' "$STAGE" "$rc" "$([ "$PRIMARY_VERIFIED" = 1 ] || [ -f "$PRIMARY_SUCCESS" ] && echo yes || echo no)" "$BACKUP_OK" "$recovery_failed" >> "$LOG_FILE"
    fi
    exit "$rc"
}
trap restore_containers EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

root_space_ok() {
    python3 - "$WORK_BASE" "$STATE_DIR" "$LOG_DIR" <<'PYSPACE'
import os, sys
minimum = int(os.environ.get('DAIMON_BACKUP_MIN_FREE_BYTES', 256*1024*1024))
inodes = int(os.environ.get('DAIMON_BACKUP_MIN_FREE_INODES', 128))
if minimum < 1 or inodes < 1:
    sys.exit('ERROR: Invalid backup space budget')
for directory in sys.argv[1:]:
    stat = os.statvfs(directory)
    if stat.f_bavail * stat.f_frsize < minimum or (stat.f_files and stat.f_favail < inodes):
        sys.exit('ERROR: Insufficient backup bytes/inodes: ' + directory)
PYSPACE
}

if [ "$TASK_KIND" = root ]; then
    [[ "${DAIMON_RECOVERY_TIMEOUT:-180}" =~ ^[0-9]{1,4}$ ]] &&
        [ "${DAIMON_RECOVERY_TIMEOUT:-180}" -ge 1 ] && [ "${DAIMON_RECOVERY_TIMEOUT:-180}" -le 3600 ] || exit 1
    for tool in findmnt realpath tac; do command -v "$tool" >/dev/null || { echo "ERROR: Missing root backup capability: $tool"; exit 1; }; done
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else "ERROR: Python 3.9+ required")'
    WORK_BASE="${DAIMON_BACKUP_WORK_DIR:-/var/tmp/daimon-root-backups}"
    [ ! -L "$WORK_BASE" ] || { echo 'ERROR: Work directory is a symlink'; exit 1; }
    install -d -m 700 "$WORK_BASE"
    root_space_ok
    if [ "$(findmnt -n -o FSTYPE -T "$WORK_BASE")" = tmpfs ]; then
        echo 'ERROR: Backup inventory requires a disk-backed work directory'
        exit 1
    fi
    WORK_DIR=$(mktemp -d "$WORK_BASE/run.XXXXXX")
    printf '%s %s\n' "$$" "$(cat /proc/sys/kernel/random/boot_id)" > "$WORK_DIR/.daimon-work"
    python3 - "$WORK_BASE" "$WORK_DIR" <<'PYCLEAN'
import os, shutil, sys
from pathlib import Path
base, current = (Path(p).resolve() for p in sys.argv[1:])
boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
for path in base.glob('run.*'):
    if path == current or path.is_symlink() or not path.is_dir() or path.resolve().parent != base:
        continue
    marker = path / '.daimon-work'
    if not marker.is_file() or marker.is_symlink():
        continue
    parts = marker.read_text().split()
    if len(parts) != 2 or not parts[0].isdigit():
        continue
    if parts[1] == boot:
        try:
            os.kill(int(parts[0]), 0)
            continue
        except ProcessLookupError:
            pass
        except PermissionError:
            continue
    shutil.rmtree(path)
PYCLEAN
    for path in "$WORK_BASE" "$STATE_DIR" "$LOG_DIR"; do
        case "$(realpath -m "$path")" in "$(realpath "$SRC1")"/*) FILTERS+=(--exclude "/${path#"$SRC1"/}/**") ;; esac
    done
    FILTERS+=(--exclude '/linux-daimon/tests/**' --exclude '/linux-daimon/audit-*/**')
    NETWORK+=(--no-update-dir-modtime)
fi

backup_preflight() {
    [ -d "$SRC1" ] && [ -r "$SRC1" ] || { printf 'ERROR: 备份源目录不存在或不可读: %s\n' "$SRC1" >&2; return 1; }
    if [ "$TASK_KIND" = root ]; then root_space_ok || return 1; fi
    rclone lsjson "$SRC1" --recursive "${FILTERS[@]}" > "$INVENTORY" || return
    python3 - "$INVENTORY" <<'PY'
import json
import sys
import unicodedata

with open(sys.argv[1], encoding="utf-8") as source:
    entries = json.load(source)
seen, conflicts = {}, set()
if not any(not entry["IsDir"] for entry in entries):
    sys.exit("ERROR: 备份同步范围为空，拒绝同步以保护远端数据")
for entry in entries:
    parts = entry["Path"].split("/")
    if any(part in ("", ".", "..") for part in parts):
        sys.exit("ERROR: 无效的 备份相对路径")
    for length in range(1, len(parts) + 1):
        path = "/".join(parts[:length])
        key = unicodedata.normalize("NFC", path).casefold()
        previous = seen.setdefault(key, path)
        if previous != path:
            conflicts.add(tuple(sorted((previous, path))))
if conflicts:
    print("ERROR: EMBY_CASE_COLLISION: OneDrive 无法保存以下大小写重名路径:", file=sys.stderr)
    for left, right in sorted(conflicts):
        print("  " + left + " | " + right, file=sys.stderr)
    sys.exit(1)
PY
}

run_transfer() {
    timeout --kill-after=30s 7d rclone "$@" >> "$LOG_FILE" 2>&1 &
    CHILD_PID=$!
    local rc=0
    if [ "$TASK_KIND" = root ]; then
        while kill -0 "$CHILD_PID" 2>/dev/null; do
            if ! root_space_ok || ! verify_backup_state; then
                stop_transfer
                return 1
            fi
            sleep 5
        done
    fi
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=""
    return "$rc"
}

checked_transfer() {
    local attempt rc=0 delay pause
    for attempt in 1 2 3; do
        if run_transfer check "$@"; then return 0; else rc=$?; fi
        [ "$TASK_KIND" = root ] && [ "$attempt" -lt 3 ] && [ "$rc" -le 6 ] || return "$rc"
        root_space_ok && verify_backup_state || return 1
        delay=$(python3 - "$LOG_FILE" "$((60 * attempt))" <<'PYBACKOFF'
import math, re, sys
from pathlib import Path
delay = int(sys.argv[2])
for value in re.findall(r'trying again in ((?:\d+(?:\.\d+)?(?:ms|s|m|h))+)', Path(sys.argv[1]).read_text(errors='replace'), re.I):
    seconds = sum(float(n) * {'ms':0.001,'s':1,'m':60,'h':3600}[unit.lower()] for n,unit in re.findall(r'(\d+(?:\.\d+)?)(ms|s|m|h)',value,re.I))
    delay = max(delay,math.ceil(seconds))
if delay > 3600:
    sys.exit('ERROR: Remote retry delay exceeds one hour; preserving failure instead of retrying early')
print(delay)
PYBACKOFF
        ) || return "$rc"
        printf 'CHECK_RETRY: attempt=%s rc=%s backoff=%ss\n' "$attempt" "$rc" "$delay" >> "$LOG_FILE" || return 1
        while [ "$delay" -gt 0 ]; do
            root_space_ok && verify_backup_state || return 1
            pause=5; [ "$delay" -ge 5 ] || pause=$delay
            sleep "$pause" || return 1
            delay=$((delay-pause))
        done
    done
    return "$rc"
}

verify_backup_state() {
    local id state
    if grep -Eiq 'Duplicate (directory|file|object) found in (source|destination) - ignoring' "$LOG_FILE"; then
        echo 'ERROR: 同步或校验忽略了重复路径，备份不完整' >> "$LOG_FILE"
        return 1
    fi
    [ "$OWNS_STATE" -eq 1 ] || return 0
    [ "$WRITERS_RESUMED" -eq 0 ] || return 0
    root_services verify || return 1
    while IFS= read -r id; do
        state=$(container_state "$id") || return
        [ "${state%% *}" = false ] || { printf 'ERROR: 备份期间容器被外部启动: %s\n' "$id" >&2; return 1; }
    done < "$STATE_FILE"
    if [ "$TASK_KIND" = root ] && command -v docker >/dev/null 2>&1; then
        python3 - "$SRC1" <<'PYWRITERS'
import json, os, subprocess, sys
root = os.path.realpath(sys.argv[1])
ids = subprocess.check_output(['docker','ps','-q'], text=True, timeout=30).split()
if ids:
    records = json.loads(subprocess.check_output(['docker','inspect',*ids], timeout=30))
    for record in records:
        for mount in record['Mounts']:
            if mount['Type'] != 'bind' or not mount.get('RW'):
                continue
            path = os.path.realpath(mount['Source'])
            if os.path.commonpath((root + '/emby', path)) == root + '/emby':
                continue
            if os.path.commonpath((root,path)) in (root,path):
                sys.exit('ERROR: Active/replaced writer during backup: ' + record['Name'])
PYWRITERS
    fi
    if [ "$TASK_KIND" = root ]; then
        python3 - "$SRC1" "${FILTERS[@]}" <<'PYHOST'
import fnmatch, os, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
patterns = [sys.argv[i+1] for i in range(2,len(sys.argv)-1) if sys.argv[i]=='--exclude']
for proc in Path('/proc').glob('[0-9]*'):
    try:
        group = (proc/'cgroup').read_text()
        if 'docker' in group or 'kubepods' in group or 'containerd' in group:
            continue
        for fd in (proc/'fd').iterdir():
            try:
                target = Path(os.readlink(fd))
                if not target.is_absolute() or not target.is_relative_to(root) or not target.is_file():
                    continue
                relative = target.relative_to(root)
                if any(fnmatch.fnmatchcase('/'+relative.as_posix(), pattern) or
                       fnmatch.fnmatchcase(relative.as_posix(),pattern) for pattern in patterns):
                    continue
                if relative.parts[0] in ('.cache','.npm','.nvm','emby') or any(part in ('logs','node_modules','.tmp') for part in relative.parts) or target.suffix in ('.log','.tmp','.temp'):
                    continue
                flags = next(line.split()[1] for line in (proc/'fdinfo'/fd.name).read_text().splitlines() if line.startswith('flags:'))
                if int(flags,8) & 3:
                    sys.exit('ERROR: Unmanaged host writer holds a writable file in backup source: pid=' + proc.name + ' path=' + str(relative))
            except (FileNotFoundError,ProcessLookupError,PermissionError,StopIteration):
                continue
    except (FileNotFoundError,ProcessLookupError,PermissionError):
        continue
PYHOST
    fi
}

INVENTORY=$(mktemp "${WORK_DIR:-$STATE_DIR}/inventory.XXXXXX")
MOUNTS=$(mktemp "${WORK_DIR:-$STATE_DIR}/mounts.XXXXXX")
printf '===== %s 开始 %s 一致性备份 =====\n' "$(date -Is)" "$BACKUP_NAME" >> "$LOG_FILE"
backup_preflight >> "$LOG_FILE" 2>&1
REMOTE_FILTERS=("${FILTERS[@]}")
if [ "$TASK_KIND" = root ]; then
    for remote in "${PRIMARY%%:*}:" "${SECONDARY%%:*}:"; do
        timeout --kill-after=5s 60s rclone lsd "$remote" --max-depth 1 \
            --contimeout=10s --timeout=20s --retries=1 --low-level-retries=1 >/dev/null 2>> "$LOG_FILE" || {
            echo "ERROR: Remote preflight failed before stopping writers: $remote" >&2
            exit 1
        }
    done
    config_file=$(rclone config file | tail -n 1)
    python3 - "$config_file" "$SRC1" "$INVENTORY" "$WORK_DIR" <<'PYMETADATA'
import json, os, shutil, sys
from pathlib import Path
config, source, inventory, work = map(Path, sys.argv[1:])
entries = json.loads(inventory.read_text())
included = {entry['Path'] for entry in entries if not entry['IsDir']}
captured = []
for item in dict.fromkeys((config, source/'.bash_history', source/'.zsh_history')):
    if item.is_symlink() or not item.is_file():
        continue
    try:
        relative = item.resolve().relative_to(source.resolve()).as_posix()
    except ValueError:
        continue
    if relative not in included:
        continue
    if any(char in relative for char in '*?[]\\\r\n') or relative.strip() != relative or relative.startswith('#'):
        sys.exit('ERROR: Unsupported special characters in backed-up metadata path')
    snapshot = work/'metadata-snapshot'/relative
    snapshot.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    for _ in range(3):
        shutil.copy2(item,snapshot)
        os.chmod(snapshot,0o600)
        if snapshot.read_bytes() == item.read_bytes():
            captured.append(relative)
            break
    else:
        sys.exit('ERROR: Metadata is changing concurrently; writers were not stopped')
if captured:
    (work/'snapshot.paths').write_text('\n'.join(captured)+'\n')
PYMETADATA
    if [ -s "$WORK_DIR/snapshot.paths" ]; then
        while IFS= read -r snapshot_relative; do FILTERS+=(--exclude "/$snapshot_relative"); done < "$WORK_DIR/snapshot.paths"
        METADATA_ROOT="$WORK_DIR/metadata-snapshot"
        echo 'METADATA_SNAPSHOT: included credentials and shell histories captured privately; live files remain writable' >> "$LOG_FILE"
    fi
fi
ids=""
if command -v docker >/dev/null 2>&1; then
    timeout 30s docker info >> "$LOG_FILE" 2>&1
    ids=$(timeout 30s docker ps -q)
elif [ "$TASK_KIND" = emby ] || [ -d /var/lib/docker ]; then
    echo 'ERROR: Docker unavailable; cannot establish writer state' >&2
    exit 1
fi
if [ -n "$ids" ]; then
    mapfile -t containers <<< "$ids"
    for id in "${containers[@]}"; do
        [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || { echo 'ERROR: 无效的 Docker 容器 ID' >&2; exit 1; }
    done
    timeout 30s docker inspect -f '{{.Id}} {{json .Mounts}}' "${containers[@]}" > "$MOUNTS"
fi
python3 - "$SRC1" "$MOUNTS" "$STATE_FILE" "$TASK_KIND" <<'PY'
import json
import os
import sys

root = os.path.realpath(sys.argv[1])
selected = []
with open(sys.argv[2], encoding="utf-8") as source:
    for line in source:
        container, mounts = line.strip().split(" ", 1)
        for mount in json.loads(mounts):
            if mount["Type"] != "bind" or not mount["RW"]:
                continue
            path = os.path.realpath(mount["Source"])
            if sys.argv[4] == "root" and os.path.commonpath((os.path.join(root, "emby"), path)) == os.path.join(root, "emby"):
                continue
            if os.path.commonpath((root, path)) in (root, path):
                selected.append(container)
                break
with open(sys.argv[3], "x", encoding="utf-8") as target:
    target.writelines(container + "\n" for container in selected)
    target.flush()
    os.fsync(target.fileno())
PY
OWNS_STATE=1
if [ "$TASK_KIND" = root ] && [ -s "$STATE_FILE" ]; then
    python3 - "$STATE_FILE" "$STATE_DIR" <<'PYORDER'
import json, os, subprocess, sys
from pathlib import Path
path, directory = Path(sys.argv[1]), Path(sys.argv[2])
ids = path.read_text().splitlines()
records = json.loads(subprocess.check_output(['docker','inspect',*ids], timeout=30))
services = {}
for item in records:
    labels = item['Config'].get('Labels') or {}
    services[(labels.get('com.docker.compose.project'),labels.get('com.docker.compose.service'))] = item['Id']
deps, health_deps = {}, {}
names = {}
for item in records:
    labels = item['Config'].get('Labels') or {}
    cid = item['Id']
    names[cid] = item['Name']
    deps[cid] = []
    health_deps[cid] = []
    for dependency in labels.get('com.docker.compose.depends_on','').split(','):
        parts = dependency.split(':')
        other = services.get((labels.get('com.docker.compose.project'),parts[0]))
        if other and other != cid:
            deps[cid].append(other)
            if len(parts) > 1 and parts[1] == 'service_healthy': health_deps[cid].append(other)
ordered, visiting = [], set()
def visit(cid):
    if cid in ordered: return
    if cid in visiting: sys.exit('ERROR: Cyclic writer dependencies')
    visiting.add(cid)
    for dep in deps[cid]: visit(dep)
    visiting.remove(cid)
    ordered.append(cid)
for cid in ids: visit(cid)
for target, content in (
    (directory/'dependencies.tsv', ''.join(cid+'\t'+'\t'.join(health_deps[cid])+'\n' for cid in ordered)),
    (directory/'writers.json', json.dumps({'names':names,'dependencies':deps})),
    (path, ''.join(cid+'\n' for cid in ordered))):
    tmp = target.with_suffix(target.suffix + '.tmp')
    with tmp.open('w') as out:
        out.write(content); out.flush(); os.fsync(out.fileno())
    os.replace(tmp,target)
PYORDER
fi
root_services stop
while IFS= read -r id; do
    timeout 60s docker stop --timeout 30 "$id" >> "$LOG_FILE" 2>&1
    state=$(container_state "$id")
    [ "${state%% *}" = false ] || { printf 'ERROR: 容器未停止: %s\n' "$id" >&2; exit 1; }
done < <(if [ "$TASK_KIND" = root ]; then tac "$STATE_FILE"; else cat "$STATE_FILE"; fi)

if [ "$TASK_KIND" = root ]; then verify_backup_state; fi
backup_preflight >> "$LOG_FILE" 2>&1
STAGE=primary_sync
run_transfer sync "$SRC1" "$PRIMARY" "${FILTERS[@]}" "${NETWORK[@]}"
verify_backup_state
if [ -n "$METADATA_ROOT" ]; then
    run_transfer copy "$METADATA_ROOT" "$PRIMARY" --no-traverse "${NETWORK[@]}"
fi
STAGE=primary_check
checked_transfer "$SRC1" "$PRIMARY" "${FILTERS[@]}" "${NETWORK[@]}"
verify_backup_state
if [ -n "$METADATA_ROOT" ]; then
    checked_transfer "$METADATA_ROOT" "$PRIMARY" --one-way --files-from "$WORK_DIR/snapshot.paths" "${NETWORK[@]}"
    verify_backup_state
fi
PRIMARY_VERIFIED=1
printf 'PRIMARY_VERIFIED: content check passed\n' >> "$LOG_FILE"
GENERATION=$(mktemp "${WORK_DIR:-$STATE_DIR}/qq-generation.XXXXXX")
AFTER_GENERATION=$(mktemp "${WORK_DIR:-$STATE_DIR}/qq-after.XXXXXX")
capture_generation() {
    timeout --kill-after=30s 7d rclone lsjson "$PRIMARY" --recursive --files-only --hash \
        "${REMOTE_FILTERS[@]}" "${NETWORK[@]}" > "$1" 2>> "$LOG_FILE" &
    CHILD_PID=$!
    local rc=0
    if [ "$TASK_KIND" = root ]; then
        while kill -0 "$CHILD_PID" 2>/dev/null; do
            if ! root_space_ok || ! verify_backup_state; then stop_transfer; return 1; fi
            sleep 5
        done
    fi
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=""
    [ "$rc" -eq 0 ] || return "$rc"
    python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
entries = json.loads(path.read_text())
if not entries:
    sys.exit("ERROR: Primary backup is empty")
records = sorted((entry["Path"], entry["Size"], entry.get("ModTime"), entry.get("Hashes", {})) for entry in entries)
path.write_text(json.dumps(records, sort_keys=True))
PY
}
capture_generation "$GENERATION"
STAGE=recover_writers
if [ "$TASK_KIND" = root ]; then recovery_mode=start-only; else recovery_mode=health; fi
if ! recover_writers "$recovery_mode"; then
    if [ "$TASK_KIND" = root ] && writers_running; then
        WRITERS_RESUMED=1
        printf 'WARN: 原运行容器均已启动，健康状态待确认；继续复制已校验的主备份，完成前再次验证健康。\n' >> "$LOG_FILE"
    else
        exit 1
    fi
fi
root_services resume
if [ "$TASK_KIND" = root ]; then exec 6>&-; fi
STAGE=primary_recheck
capture_generation "$AFTER_GENERATION"
cmp -s "$GENERATION" "$AFTER_GENERATION" || { echo 'ERROR: QQ backup changed after primary verification' >&2; exit 1; }
date -Is > "$PRIMARY_SUCCESS"
chmod 600 "$PRIMARY_SUCCESS"
printf '===== %s QQ 校验完成，原容器已运行，待最终健康确认=%s =====\n' "$(date -Is)" "$WRITERS_RESUMED" >> "$LOG_FILE"
STAGE=secondary_sync
run_transfer sync "$PRIMARY" "$SECONDARY" "${REMOTE_FILTERS[@]}" "${NETWORK[@]}"
verify_backup_state
STAGE=secondary_check
checked_transfer "$PRIMARY" "$SECONDARY" "${REMOTE_FILTERS[@]}" "${NETWORK[@]}"
verify_backup_state
capture_generation "$AFTER_GENERATION"
cmp -s "$GENERATION" "$AFTER_GENERATION" || { echo 'ERROR: QQ backup changed during replication' >&2; exit 1; }
STAGE=complete
BACKUP_OK=1
EOF
            ;;
		*) return 1 ;;
	esac || return 1
	[ "${DAIMON_SKIP_RUNNER_WRITE:-0}" = 1 ] || crontab_sync_write_run_tools || return 1
	bash -n "$script_file" && chmod 700 "$script_file" && mv -f -- "$script_file" "$target"
)

crontab_sync_reconcile_legacy() {
	[ "${CRONTAB_SYNC_RECONCILED:-false}" = true ] && return 0
	local id file
	for id in bitwarden via; do
		file=$(crontab_sync_legacy_script_file_by_id "$id") || return 1
		if [ -f "$file" ] && [ ! -L "$file" ] && grep -q 'Infini-cloud:' "$file"; then
			echo "检测到旧同步脚本，原任务保持不变；请到 crontab 管理选项 6 显式迁移: $file"
		fi
	done
	CRONTAB_SYNC_RECONCILED=true
}

crontab_sync_migrate_legacy_file() {
	local id="$1" file
	case "$id" in bitwarden|via) ;; *) return 1 ;; esac
	file=$(crontab_sync_legacy_script_file_by_id "$id") || return 1
	crontab_sync_remote_ready || return 1
	python3 - "$file" "${DAIMON_LOCK_DIR:-/run/lock}" <<'PYCRON_MIGRATE'
import fcntl, os, re, signal, stat, subprocess, sys, tempfile
from pathlib import Path

def require(ok, message):
    if not ok: raise ValueError(message)

def trusted(path, directory=False):
    info = path.lstat()
    require(path.resolve() == path and info.st_uid == 0 and not info.st_mode & 0o022,
            'Untrusted migration path')
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
            'Not a private regular script or directory')
    return info

def identity(path):
    i = trusted(path)
    return (i.st_dev, i.st_ino, i.st_mode, i.st_uid, i.st_gid, i.st_size, i.st_mtime_ns, path.read_bytes())

def idle(path):
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal() or int(proc.name) == os.getpid(): continue
        try:
            require(os.fsencode(path) not in (proc / 'cmdline').read_bytes().split(b'\0'), 'Script is running')
            for fd in (proc / 'fd').iterdir():
                try: require(fd.resolve() != path, 'Script is open')
                except FileNotFoundError: pass
        except (FileNotFoundError, ProcessLookupError): pass

def interrupted(signum, frame):
    raise InterruptedError('Migration interrupted')

for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(signum, interrupted)
temp = None
try:
    require(os.geteuid() == 0, 'Root required')
    target, locks = map(Path, sys.argv[1:])
    require(target.is_absolute(), 'Absolute script path required')
    for parent in target.parents: trusted(parent, True)
    require(locks.resolve() == locks and locks.stat().st_uid == 0, 'Untrusted lock directory')
    require(not locks.stat().st_mode & 0o022 or locks.stat().st_mode & stat.S_ISVTX, 'Unsafe lock directory')
    lock = os.open(locks / 'daimon-backup-scripts.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    i = os.fstat(lock)
    require(stat.S_ISREG(i.st_mode) and i.st_uid == 0 and i.st_nlink == 1 and not i.st_mode & 0o022, 'Unsafe lock file')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    original = identity(target)
    idle(target)
    data = re.sub(rb'(?<![A-Za-z0-9_.-])Infini-cloud:', b'kissska1:', original[-1])
    require(data != original[-1], 'No literal legacy remote found; unchanged')
    fd, name = tempfile.mkstemp(prefix='.legacy-migrate.', dir=target.parent)
    temp = Path(name)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fchmod(stream.fileno(), stat.S_IMODE(original[2]))
        os.fchown(stream.fileno(), original[3], original[4])
        os.fsync(stream.fileno())
    require(subprocess.run(['/bin/bash', '-n', str(temp)], capture_output=True).returncode == 0, 'Invalid script syntax; unchanged')
    idle(target)
    require(identity(target) == original, 'Script changed concurrently; unchanged by migration')
    os.replace(temp, target)
    temp = None
    require(target.read_bytes() == data, 'Post-write verification failed; check script before use')
    print('Migrated literal remote in the selected script; path, direction and crontab preserved.')
except (OSError, ValueError) as error:
    print('Migration failed: ' + str(error), file=sys.stderr)
    sys.exit(1)
finally:
    if temp is not None: temp.unlink()
PYCRON_MIGRATE
}

crontab_sync_migrate_legacy_menu() {
	local choice id file confirm
	echo "仅替换所选旧脚本的 Infini-cloud: 远端为 kissska1:；保留文件名、同步方向和定时，不改自定义脚本。"
	echo "1. Bitwarden 旧脚本    2. Via 旧脚本    0. 返回"
	read -r -p "请选择: " choice || return 1
	case "$choice" in 1) id=bitwarden ;; 2) id=via ;; 0|'') return 0 ;; *) return 1 ;; esac
	file=$(crontab_sync_legacy_script_file_by_id "$id") || return 1
	printf '目标: %s\n请先核查脚本，迁移后同步方向和删除行为保持原样。\n' "$file"
	read -r -p "输入 MIGRATE 确认: " confirm || return 1
	[ "$confirm" = MIGRATE ] || return 0
	crontab_sync_migrate_legacy_file "$id"
}

crontab_sync_install_one() {
	local id="$1"
	local script_file="$2"
	local cron_line="$3"
	local current next checked runner
	root_use
	if [ "$id" != "nginxdomain" ]; then
		rclone_require || return 1
	fi
	case "$id" in
		bitwarden|via|root|emby|custom)
			if ! crontab_sync_remote_ready; then
				echo -e "${gl_hong}kissska1 连接检查失败，未修改脚本和定时任务。${gl_bai}"
				return 1
			fi
			;;
	esac
	check_crontab_installed || return 1
	current=$(rsync_cron_read) || return 1
	runner=$(crontab_sync_runner_file) || return 1
	next=$(printf '%s\n' "$current" | server_retire_filter_cron "$script_file" "$runner") || return 1
	if [ -n "$next" ]; then next+=$'\n'; fi
	next+="$cron_line"
	(
		umask 077
		local stage='' applying=0 committed=0 cron_attempt=0 had_cron=0 keep_stage=0 i status restored
		local lock_dir="${DAIMON_LOCK_DIR:-/run/lock}" lock_file lock_mode original_script original_runner
		local -a files=("$script_file" "$runner") identities=()
		[ "$script_file" != "$runner" ] && [ "$(dirname "$script_file")" = "$(dirname "$runner")" ] || return 1
		for i in 0 1; do identities[$i]=$(server_retire_script_guard "${files[$i]}") || return 1; done
		mkdir -p -- "$lock_dir" "$(dirname "$script_file")" || return 1
		[ "$(realpath -e -- "$lock_dir")" = "$lock_dir" ] && [ -O "$lock_dir" ] || return 1
		lock_mode=$(stat -c %a -- "$lock_dir") || return 1
		(( (8#${lock_mode} & 022) == 0 || (8#${lock_mode} & 01000) != 0 )) || return 1
		lock_file="$lock_dir/daimon-backup-scripts.lock"
		(set -o noclobber; : > "$lock_file") 2>/dev/null || true
		[ -f "$lock_file" ] && [ ! -L "$lock_file" ] && [ -O "$lock_file" ] || return 1
		lock_mode=$(stat -c %a -- "$lock_file") || return 1
		(( (8#${lock_mode} & 022) == 0 )) || return 1
		exec 7< "$lock_file" || return 1
		[ "$(stat -c '%d:%i' -- "$lock_file")" = "$(stat -Lc '%d:%i' /dev/fd/7)" ] &&
			[ "$(stat -Lc %h /dev/fd/7)" = 1 ] && flock -xn 7 || return 1
		stage=$(mktemp -d "$(dirname "$script_file")/.cron-install.XXXXXX") || return 1
		original_script="$stage/$(basename "$script_file")"
		original_runner="$stage/$(basename "$runner")"
		trap '
			status=$?
			trap "" INT TERM HUP
			if [ "$applying" = 1 ] && [ "$committed" = 0 ]; then
				restored=1
				if [ "$cron_attempt" = 1 ]; then
					if ! checked=$(rsync_cron_read); then restored=0
					elif [ "$checked" = "$next" ]; then
						if [ "$had_cron" = 1 ]; then crontab - < "$stage/cron.old" || restored=0
						else crontab -r || restored=0; fi
						checked=$(rsync_cron_read) && [ "$checked" = "$current" ] || restored=0
					elif [ "$checked" != "$current" ]; then restored=0; fi
				fi
				if [ "$restored" = 1 ]; then
					for i in 0 1; do
						checked=$(server_retire_script_guard "${files[$i]}") || { keep_stage=1; continue; }
						[ "$checked" != "${identities[$i]}" ] || continue
						if [ "$checked" != absent ] && cmp -s -- "${files[$i]}" "$stage/new-$i"; then
							if [ "${identities[$i]}" = absent ]; then rm -- "${files[$i]}" || keep_stage=1
							else mv -f -- "$stage/old-$i" "${files[$i]}" || keep_stage=1; fi
						else keep_stage=1; fi
					done
				else keep_stage=1; fi
			fi
			if [ "$keep_stage" = 1 ]; then
				echo "安装回滚未完成，未覆盖未知变更；私有恢复文件保留在 $stage" >&2
				status=1
			else
				rm -f -- "$original_script" "$original_runner" "$stage"/{old-0,old-1,new-0,new-1,apply-0,apply-1,cron.old,cron.err}
				rmdir -- "$stage" || { echo "临时目录包含未识别内容，已保留: $stage" >&2; status=1; }
			fi
			exit "$status"
		' EXIT
		trap 'exit 130' INT
		trap 'exit 143' TERM
		trap 'exit 129' HUP
		for i in 0 1; do
			[ "${identities[$i]}" = absent ] || cp -p -- "${files[$i]}" "$stage/old-$i" || return 1
		done
		if LC_ALL=C crontab -l > "$stage/cron.old" 2> "$stage/cron.err"; then had_cron=1
		else grep -q '^no crontab for ' "$stage/cron.err" || return 1; fi
		[ "$(cat "$stage/cron.old")" = "$current" ] || return 1
		DAIMON_SKIP_RUNNER_WRITE=1 DAIMON_UPGRADE_LOCKED=1 crontab_sync_write_script "$id" "$original_script" || return 1
		crontab_sync_write_runner "$original_runner" || return 1
		cp -p -- "$original_script" "$stage/new-0" && cp -p -- "$original_runner" "$stage/new-1" || return 1
		for i in 0 1; do
			checked=$(server_retire_script_guard "${files[$i]}") || return 1
			[ "$checked" = "${identities[$i]}" ] || return 1
		done
		checked=$(rsync_cron_read) || return 1
		[ "$checked" = "$current" ] || { echo "定时任务已被其他进程修改，未覆盖。" >&2; return 1; }
		applying=1
		for i in 0 1; do
			cp -p -- "$stage/new-$i" "$stage/apply-$i" && mv -f -- "$stage/apply-$i" "${files[$i]}" || return 1
		done
		checked=$(rsync_cron_read) || return 1
		[ "$checked" = "$current" ] || { echo "定时任务已变化，正在恢复脚本；未覆盖其他任务。" >&2; return 1; }
		cron_attempt=1
		printf '%s\n' "$next" | crontab - || return 1
		checked=$(rsync_cron_read) || return 1
		[ "$checked" = "$next" ] || { echo "定时任务写入后校验失败。" >&2; return 1; }
		committed=1
	) || return 1
	if [ "$id" = "nginxdomain" ]; then /bin/bash "$script_file" || return 1; fi
	echo -e "${gl_lv}已安装: $(basename "$script_file")${gl_bai}"
	echo "定时任务: $cron_line"
}

crontab_sync_remove_one() {
	local script_file="$1"
	server_retire_remove_script "$script_file" || return 1
	echo -e "${gl_lv}已卸载: $(basename "$script_file")${gl_bai}"
}

crontab_sync_show_status() {
	local custom_files=()
	local custom_count=0
	local file cron_line id name

	echo -e "${gl_kjlan}------------------------${gl_bai}"
	for n in 1 2 3 4 5 6; do
		id=$(crontab_sync_builtin_id_by_number "$n")
		name=$(crontab_sync_builtin_name_by_id "$id")
		file=$(crontab_sync_script_file_by_id "$id" 2>/dev/null || true)
		if [ "$id" = root ] && [ -z "$file" ]; then
			printf "%2d. %-20s %-58s %b\n" "$n" "$name" "" "${gl_huang}未安装（安装时设置服务器名称）${gl_bai}"
			continue
		fi
		cron_line=$(crontab_sync_cron_line_by_id "$id" "$file")
		printf "%2d. %-20s %-58s %b\n" "$n" "$name" "$file" "$(crontab_sync_status_text "$id" "$file" "$cron_line")"
	done

	mapfile -t custom_files < <(crontab_sync_custom_files)
	if [ "${#custom_files[@]}" -eq 0 ]; then
		echo -e "其他脚本: ${gl_hui}无${gl_bai}"
	else
		echo "其他脚本:"
		for file_name in "${custom_files[@]}"; do
			custom_count=$((custom_count + 1))
			file="$(crontab_sync_script_file_by_id custom "$file_name")"
			cron_line=$(crontab_sync_cron_line_by_id custom "$file")
			printf "%2d. %-20s %-58s %b\n" "$((6 + custom_count))" "${file_name%.sh}" "$file" "$(crontab_sync_status_text custom "$file" "$cron_line")"
		done
	fi
	echo -e "${gl_kjlan}------------------------${gl_bai}"
}

crontab_sync_get_item_by_number() {
	local num="$1" action="${2:-install}"
	local id file cron_line
	case "$num" in
		1|2|3|4|5|6)
			id=$(crontab_sync_builtin_id_by_number "$num")
			if [ "$id" = root ]; then
				if ! file=$(crontab_sync_script_file_by_id "$id" 2>/dev/null); then
					[ "$action" = install ] || return 1
					crontab_sync_prompt_root_name >/dev/null || return 1
					file=$(crontab_sync_script_file_by_id "$id") || return 1
				fi
			else
				file=$(crontab_sync_script_file_by_id "$id")
			fi
			cron_line=$(crontab_sync_cron_line_by_id "$id" "$file")
			echo "$id|$file|$cron_line"
			return 0
			;;
	esac

	local custom_index=$((num - 7))
	if [ "$custom_index" -ge 0 ]; then
		local custom_files=()
		mapfile -t custom_files < <(crontab_sync_custom_files)
		if [ "$custom_index" -lt "${#custom_files[@]}" ]; then
			file=$(crontab_sync_script_file_by_id custom "${custom_files[$custom_index]}")
			cron_line=$(crontab_sync_cron_line_by_id custom "$file")
			echo "custom|$file|$cron_line"
			return 0
		fi
	fi
	return 1
}

crontab_sync_handle_numbers() {
	local action="$1"
	local nums="$2"
	local n item id file cron_line status=0
	local -a items=()
	local -A selected=()
	case "$action" in install|remove) ;; *) return 1 ;; esac
	for n in $nums; do
		if ! [[ "$n" =~ ^[1-9][0-9]{0,5}$ ]]; then
			echo "无效编号，未执行: $n"
			return 1
		fi
	done
	for n in $nums; do
		[ -z "${selected[$n]:-}" ] || continue
		if ! item=$(crontab_sync_get_item_by_number "$n" "$action"); then
			echo "编号不可用，未执行: $n"
			return 1
		fi
		selected[$n]=1
		items+=("$item")
	done
	for item in "${items[@]}"; do
		IFS='|' read -r id file cron_line <<< "$item"
		if [ "$action" = "install" ]; then
			crontab_sync_install_one "$id" "$file" "$cron_line" || status=1
		else
			crontab_sync_remove_one "$file" || status=1
		fi
	done
	return "$status"
}

crontab_sync_all_numbers() {
	local count=6
	local custom_files=()
	mapfile -t custom_files < <(crontab_sync_custom_files)
	count=$((count + ${#custom_files[@]}))
	seq 1 "$count" | tr '\n' ' '
}

crontab_sync_run_root_once() {
	root_use
	local file confirm
	file=$(crontab_sync_script_file_by_id root)
	read -r -p "将停止当前运行的 Docker 容器并执行一次 /root 一致性备份，输入 RUN_ROOT_BACKUP 确认：" confirm || return 1
	[ "$confirm" = RUN_ROOT_BACKUP ] || { echo "已取消"; return 0; }
	crontab_sync_write_script root "$file" || return 1
	/bin/bash "$(crontab_sync_runner_file)" root "$file"
}

crontab_sync_manager() {
    crontab_sync_upgrade_installed || return 1
	crontab_sync_reconcile_legacy || true
	while true; do
		clear
		echo -e "crontab同步脚本管理"
		echo -e "脚本目录: ${gl_kjlan}$(crontab_sync_backup_dir)${gl_bai}"
		echo -e "日志目录: ${gl_kjlan}$(crontab_sync_log_dir)${gl_bai}"
		crontab_sync_show_status
		echo -e "${gl_kjlan}1.   ${gl_bai}安装脚本（支持多选，输入编号，如: 1 2）"
		echo -e "${gl_kjlan}2.   ${gl_bai}卸载脚本（支持多选，输入编号，如: 2 4）"
		echo -e "${gl_kjlan}3.   ${gl_bai}一键安装（默认全选，可自行删除编号）"
		echo -e "${gl_kjlan}4.   ${gl_bai}一键卸载（默认全选，可自行删除编号）"
		echo -e "${gl_kjlan}5.   ${gl_bai}立即执行一次 /root Docker 一致性备份"
		echo -e "${gl_kjlan}6.   ${gl_bai}迁移旧 Infini-cloud 脚本（显式确认）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1)
				read -e -p "请输入要安装的脚本编号（支持多选，空格分隔）: " nums || return 1
				crontab_sync_handle_numbers install "$nums"
				;;
			2)
				read -e -p "请输入要卸载的脚本编号（支持多选，空格分隔）: " nums || return 1
				crontab_sync_handle_numbers remove "$nums"
				;;
			3)
				local nums
				nums="$(crontab_sync_all_numbers)"
				read -e -i "$nums" -p "请确认/修改要安装的脚本编号（默认全选，空格分隔）: " nums || return 1
				crontab_sync_handle_numbers install "$nums"
				;;
			4)
				local nums
				nums="$(crontab_sync_all_numbers)"
				read -e -i "$nums" -p "请确认/修改要卸载的脚本编号（默认全选，空格分隔）: " nums || return 1
				read -e -p "确认卸载以上编号对应脚本和定时任务？(y/N): " confirm || return 1
				if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
					crontab_sync_handle_numbers remove "$nums"
				else
					echo "已取消"
				fi
				;;
			5) crontab_sync_run_root_once ;;
			6) crontab_sync_migrate_legacy_menu ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
