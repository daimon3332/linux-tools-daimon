#!/bin/bash

bitwarden_rclone_conf_file() {
	local volume path
	volume=$(bitwarden_volume_name /config "${DAIMON_VAULT_CONFIG_VOLUME:-vaultwarden-rclone-data}") || return 1
	path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume" 2>/dev/null) || return 1
	printf '%s/rclone/rclone.conf\n' "$path"
}

bitwarden_volume_name() {
	local destination="$1" fallback="$2" container="${DAIMON_VAULT_BACKUP_CONTAINER:-vaultwarden-backup}" data
	if ! data=$(docker inspect "$container" 2>/dev/null); then
		docker info >/dev/null 2>&1 || return 1
		printf '%s\n' "$fallback"
		return
	fi
	printf '%s' "$data" | python3 -c '
import json,sys
mounts = [m for m in json.load(sys.stdin)[0]["Mounts"] if m["Destination"].rstrip("/") == sys.argv[1]]
if len(mounts) != 1 or mounts[0]["Type"] != "volume" or not mounts[0].get("Name"):
    sys.exit("Vaultwarden requires the expected named volume; no Compose file was changed.")
print(mounts[0]["Name"])
' "$destination"
}

bitwarden_backup_image() {
	local image
	image=$(docker inspect --format '{{.Image}}' "${DAIMON_VAULT_BACKUP_CONTAINER:-vaultwarden-backup}" 2>/dev/null) ||
		image=$(docker image inspect --format '{{.Id}}' ttionya/vaultwarden-backup:latest 2>/dev/null) || return 1
	[[ "$image" = sha256:* ]] || return 1
	printf '%s\n' "$image"
}

bitwarden_remote_path() {
	local data
	data=$(docker inspect "${DAIMON_VAULT_BACKUP_CONTAINER:-vaultwarden-backup}" 2>/dev/null) || return 1
	printf '%s' "$data" | python3 -c '
import json,sys
env = dict(e.split("=",1) for e in json.load(sys.stdin)[0]["Config"]["Env"] if "=" in e)
remote = env.get("RCLONE_REMOTE_NAME", "BitwardenBackup")
path = env.get("RCLONE_REMOTE_DIR", "/BitwardenBackup/")
if any(ord(c) < 32 or ord(c) == 127 for c in remote + path) or ":" in remote:
    sys.exit(1)
print(remote + ":" + path.rstrip("/"))
'
}

bitwarden_sync_script_file() {
	echo "${DAIMON_BACKUP_SH_DIR:-/root/linux-daimon/backup-sh}/Vaultwarden_OneDrive_to_Kissska1.sh"
}

bitwarden_sync_cron_line() {
	crontab_sync_cron_entry "5 5 * * * /bin/bash $(crontab_sync_runner_file) bitwarden $(bitwarden_sync_script_file) >> /var/log/rclone/cron_Vaultwarden_OneDrive_to_Kissska1.log 2>&1"
}

bitwarden_rclone_config_status() {
	local conf_file remote
	if conf_file=$(bitwarden_rclone_conf_file) && [ -f "$conf_file" ]; then
		remote=$(bitwarden_remote_path) || { rclone_state_text unknown; return; }
		rclone_state_text "$(rclone_remote_state "$conf_file" "$remote")"
	else
		echo -e "${gl_hong}未配置${gl_bai}"
	fi
}

bitwarden_sync_script_status() {
	local script_file cron_line
	script_file=$(bitwarden_sync_script_file)
	cron_line=$(bitwarden_sync_cron_line)
	if [ -f "$script_file" ] && crontab -l 2>/dev/null | grep -Fxq "$cron_line"; then
		echo -e "${gl_lv}已配置${gl_bai}"
	elif [ -f "$script_file" ]; then
		echo -e "${gl_huang}脚本已存在，定时任务未配置${gl_bai}"
	elif crontab -l 2>/dev/null | grep -Fq "$script_file"; then
		echo -e "${gl_huang}定时任务已存在，脚本不存在${gl_bai}"
	else
		echo -e "${gl_hong}未配置${gl_bai}"
	fi
}

bitwarden_check_requirements() {
	local missing=0
	if ! command -v docker >/dev/null 2>&1; then
		echo -e "${gl_hong}未检测到 docker，本机没有可配置的 Vaultwarden 备份。${gl_bai}"
		return 1
	fi
	rclone_require || missing=1
	daimon_require_cmd python3 || missing=1
	docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用。"; missing=1; }
	return "$missing"
}

bitwarden_configure_rclone_conf() (
	root_use
	bitwarden_check_requirements || return 1
	umask 077
	local conf source_conf volume mount target image work staged="" existed=0
	source_conf=$(rclone_config_path)
	rclone_select_remote "$source_conf" || return 1
	image=$(bitwarden_backup_image) || { echo "未找到本机备份镜像，未下载或升级镜像。"; return 1; }
	volume=$(bitwarden_volume_name /config "${DAIMON_VAULT_CONFIG_VOLUME:-vaultwarden-rclone-data}") || return 1
	work=$(mktemp -d) || return 1
	trap 'if [ -s "$work/cid" ]; then docker rm -f "$(<"$work/cid")" >/dev/null 2>&1 || true; fi; rm -rf -- "$work"; [ -z "$staged" ] || rm -f -- "$staged"' EXIT
	if conf=$(bitwarden_rclone_conf_file) && [ -f "$conf" ]; then
		cp -- "$conf" "$work/original.conf" || return 1
		existed=1
	else
		: > "$work/original.conf"
	fi
	rclone --config "$source_conf" config dump --ask-password=false > "$work/source.json" 2>/dev/null || return 1
	python3 - "$work/source.json" "$work/original.conf" "$work/rclone.conf" "$RCLONE_SELECTED_REMOTE" <<'PY' || return 1
import configparser, json, sys
from pathlib import Path
source = json.loads(Path(sys.argv[1]).read_text())
target = configparser.RawConfigParser()
target.optionxform = str
try:
    target.read(sys.argv[2])
except configparser.Error:
    sys.exit("Existing configuration cannot be parsed; contents are hidden and unchanged.")
selected = sys.argv[4]
pending, visited = [selected], set()
while pending:
    name = pending.pop()
    if name in visited:
        continue
    visited.add(name)
    config = source[name]
    for key in ("remote", "upstreams"):
        for item in config.get(key, "").split():
            dependency = item.split(":", 1)[0]
            if ":" in item and dependency in source:
                pending.append(dependency)
for name in visited - {selected}:
    if name == "BitwardenBackup" or (target.has_section(name) and dict(target[name]) != source[name]):
        sys.exit("Remote dependency conflicts with existing configuration; nothing was replaced.")
    target[name] = source[name]
target["BitwardenBackup"] = source[selected]
with open(sys.argv[3], "w") as output:
    target.write(output)
PY
	echo "使用备份镜像的 rclone 直接验证候选配置..."
	if ! timeout 30s docker run --rm --pull never --entrypoint rclone --cidfile "$work/cid" \
		--mount "type=bind,source=$work,target=/audit" "$image" --config /audit/rclone.conf \
		lsf BitwardenBackup: --dirs-only --max-depth 1 --ask-password=false \
		--contimeout 8s --timeout 15s --retries 1 --low-level-retries 1 >/dev/null 2>&1; then
		echo "BitwardenBackup 验证失败，原配置保持不变。"
		return 1
	fi
	docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null || return 1
	mount=$(docker volume inspect --format '{{.Mountpoint}}' "$volume" 2>/dev/null) || return 1
	target="$mount/rclone/rclone.conf"
	rclone_tree_safe "$mount/rclone" || return 1
	mkdir -p "$mount/rclone" && chmod 700 "$mount/rclone" || return 1
	if [ "$existed" = 1 ]; then
		cmp -s -- "$work/original.conf" "$target" || { echo "原配置已被其他进程更新，请重新操作。"; return 1; }
	else
		[ ! -e "$target" ] || { echo "目标配置已创建，未覆盖。"; return 1; }
	fi
	staged=$(mktemp "$mount/rclone/.rclone.conf.XXXXXX") || return 1
	command install -m 600 "$work/rclone.conf" "$staged" && mv -f -- "$staged" "$target" || return 1
	staged=""
	echo "BitwardenBackup 配置已验证并更新，其他 remote 保留；未执行生产备份。"
)

bitwarden_backup_data() {
	root_use
	if ! command -v docker >/dev/null 2>&1; then
		echo -e "${gl_hong}未检测到 docker，请先安装 Docker。${gl_bai}"
		return 1
	fi
	if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vaultwarden-backup'; then
		echo -e "${gl_hong}vaultwarden-backup 容器未运行，无法执行备份。${gl_bai}"
		echo "请先启动 vaultwarden-backup 容器后再重试。"
		return 1
	fi

	local backup_output
	echo "正在执行备份..."
	if ! backup_output=$(docker exec -i vaultwarden-backup bash /app/backup.sh 2>&1); then
		echo "$backup_output"
		echo -e "${gl_hong}备份命令执行失败，请检查容器日志和远程存储。${gl_bai}"
		return 1
	fi
	echo "$backup_output"

	if echo "$backup_output" | grep -q 'upload backup file to storage system'; then
		echo -e "${gl_lv}备份成功：已检测到 upload backup file to storage system。${gl_bai}"
	else
		echo -e "${gl_hong}备份可能失败：没有检测到 upload backup file to storage system 字段。${gl_bai}"
		return 1
	fi
}

bitwarden_restore_preflight() {
	local volume data
	volume=$(bitwarden_volume_name /bitwarden/data "${DAIMON_VAULT_DATA_VOLUME:-vaultwarden-data}") || return 1
	data=$(docker volume inspect "$volume" 2>/dev/null) || { echo "目标 named volume 不存在，请先创建并确认目标卷。"; return 1; }
	BITWARDEN_DATA_PATH=$(printf '%s' "$data" | python3 -c '
import json,sys
volume = json.load(sys.stdin)[0]
if volume["Driver"] != "local" or volume.get("Options"):
    sys.exit("Only ordinary local named volumes are supported by this restore.")
print(volume["Mountpoint"])
') || return 1
	[ -d "$BITWARDEN_DATA_PATH" ] && rclone_tree_safe "$BITWARDEN_DATA_PATH" || return 1
	rclone_assert_inactive "$BITWARDEN_DATA_PATH" || { echo "请先停止使用此卷的 Vaultwarden 和 backup 容器，再执行还原。"; return 1; }
	if mountpoint -q "$BITWARDEN_DATA_PATH"; then echo "目标卷仍是活动挂载点，已停止还原。"; return 1; fi
}

bitwarden_prepare_restored_files() {
	python3 - "$1" "$2" "$3" <<'PY'
import json, os, shutil, sqlite3, sys, tarfile
from pathlib import Path, PurePosixPath
source, target, previous = map(Path, sys.argv[1:])
target.mkdir()
for entry in source.rglob("*"):
    if entry.is_symlink() or (not entry.is_file() and not entry.is_dir()):
        sys.exit("Unsafe extracted archive entry.")
databases = list(source.glob("db.*.*"))
if len(databases) != 1:
    sys.exit("Expected exactly one SQLite database; external databases require their native restore tools.")
db = databases[0]
with sqlite3.connect(db.resolve().as_uri() + "?mode=ro&immutable=1", uri=True) as conn:
    if conn.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        sys.exit("SQLite integrity check failed.")
    counts = [conn.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] for table in ("users", "ciphers")]
shutil.copy2(db, target / "db.sqlite3")
configs = list(source.glob("config.*.json"))
if len(configs) > 1:
    sys.exit("Ambiguous configuration in archive.")
if configs:
    json.loads(configs[0].read_text())
    shutil.copy2(configs[0], target / "config.json")
for kind in ("rsakey", "attachments", "sends"):
    archives = list(source.glob(kind + ".*.tar"))
    if len(archives) > 1 or (kind == "rsakey" and not archives):
        sys.exit("Missing or ambiguous " + kind + " archive.")
    if not archives:
        continue
    with tarfile.open(archives[0]) as archive:
        members = archive.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name or not (member.isfile() or member.isdir()):
                sys.exit("Unsafe tar member; target volume is unchanged.")
            if not path.parts:
                continue
            if kind == "rsakey":
                if len(path.parts) != 1 or not path.name.startswith("rsa_key"):
                    sys.exit("Unexpected RSA key path.")
                relative = Path(path.name)
            else:
                if len(path.parts) < 2 and member.isfile():
                    sys.exit("Unexpected archive root.")
                relative = Path(kind, *path.parts[1:])
            destination = target / relative
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as incoming, destination.open("xb") as output:
                    shutil.copyfileobj(incoming, output)
                os.chmod(destination, member.mode & 0o777)
    if kind == "rsakey" and not any(target.glob("rsa_key*")):
        sys.exit("RSA key archive is empty.")
owner = (previous / "db.sqlite3") if (previous / "db.sqlite3").exists() else previous
if hasattr(os, "chown"):
    stat = owner.stat()
    for entry in [target, *target.rglob("*")]:
        os.chown(entry, stat.st_uid, stat.st_gid)
print("SQLite integrity OK; users=%d ciphers=%d" % tuple(counts))
PY
}

bitwarden_restore_data() (
	root_use
	bitwarden_check_requirements && bitwarden_restore_preflight || return 1
	umask 077
	set -o pipefail
	local remote conf image work stage="" target="$BITWARDEN_DATA_PATH" moved=0 state
	local list_output selected_idx selected_file password confirm i cid bytes
	local files=()
	image=$(bitwarden_backup_image) || { echo "本机缺少备份工具镜像，未拉取或升级镜像。"; return 1; }
	remote=$(bitwarden_remote_path) || return 1
	conf=$(bitwarden_rclone_conf_file) || return 1
	state=$(rclone_remote_state "$conf" "$remote")
	[ "$state" = valid ] || state=$(rclone_remote_state "$conf" "$remote")
	if [ "$state" = unknown ]; then
		echo "当前备份 remote $remote 暂时无法连接（网络或超时），未修改数据卷，请稍后重试。"
		return 1
	fi
	if [ "$state" != valid ]; then
		echo "当前备份 remote $remote 凭据无效，请选择已验证的凭据。"
		rclone_select_remote || return 1
		remote="$RCLONE_SELECTED_REMOTE:${remote#*:}"
		conf=$(rclone_config_path)
	fi
	work=$(mktemp -d "${DAIMON_RESTORE_ROOT:-/root}/.daimon-vault-download.XXXXXX") || return 1
	bitwarden_restore_finish() {
		local rc=$?
		if [ -s "$work/cid" ]; then read -r cid < "$work/cid"; docker rm -f "$cid" >/dev/null 2>&1 || true; fi
		if [ "$moved" = 1 ]; then
			if [ -e "$target" ] || [ -L "$target" ] || ! mv -T -- "$stage/previous" "$target"; then
				echo "还原未完成，保留回滚目录: $stage"
				return
			fi
		fi
		[ -z "$stage" ] || rm -rf -- "$stage"
		rm -rf -- "$work"
		return "$rc"
	}
	trap bitwarden_restore_finish EXIT
	cp -- "$conf" "$work/rclone.conf" || return 1
	conf="$work/rclone.conf"
	echo "备份来源: $remote"
	list_output=$(rclone --config "$conf" lsjson "$remote" --files-only --max-depth 1 --contimeout 10s --timeout 30s --retries 1 2>/dev/null | python3 -c '
import json,re,sys
for entry in sorted(json.load(sys.stdin), key=lambda e:e["Name"], reverse=True):
    if re.fullmatch(r"backup\.[0-9]{8}\.zip", entry["Name"]):
        print(entry["Name"])
') || { echo "读取备份列表失败。"; return 1; }
	[ -n "$list_output" ] || { echo "未找到备份 ZIP。"; return 1; }
	mapfile -t files <<< "$list_output"
	for i in "${!files[@]}"; do printf '%2d. %s\n' "$((i+1))" "${files[i]}"; done
	read -r -p "请选择备份（默认 1 最新，0 返回）: " selected_idx || return 1
	selected_idx=$(rclone_selection_index "${selected_idx:-1}" "${#files[@]}") || return 1
	selected_file="${files[selected_idx]}"
	bytes=$(rclone --config "$conf" size "$remote/$selected_file" --json --contimeout 10s --timeout 30s --retries 1 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])') || return 1
	rclone_require_space "${DAIMON_RESTORE_ROOT:-/root}" "$bytes" || return 1
	mkdir "$work/zip" "$work/extracted" || return 1
	if ! rclone --config "$conf" copyto "$remote/$selected_file" "$work/zip/$selected_file" --contimeout 10s --timeout 60s --retries 1 2>/dev/null ||
		! rclone --config "$conf" check "$remote" "$work/zip" --include "/$selected_file" --download --one-way --contimeout 10s --timeout 60s --retries 1 >/dev/null 2>&1; then
		 echo "备份下载或内容校验失败，未修改数据卷。"; return 1
	fi
	bytes=$(python3 - "$work/zip/$selected_file" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    print(sum(entry.file_size for entry in archive.infolist()) * 3)
PY
	) || return 1
	rclone_require_space "${DAIMON_RESTORE_ROOT:-/root}" "$bytes" || return 1
	read -r -s -p "请输入备份 ZIP 密码（不会显示或保存）: " password || return 1
	echo
	if ! printf '%s\n' "$password" | timeout 120s docker run --rm -i --pull never --network none \
		--read-only --cap-drop ALL --security-opt no-new-privileges:true --cidfile "$work/cid" \
		--entrypoint sh --mount "type=bind,source=$work/zip,target=/input,readonly" \
		--mount "type=bind,source=$work/extracted,target=/output" "$image" -c \
		'IFS= read -r password; exec 7z e -y "-p$password" "/input/$1" -o/output </dev/null' sh "$selected_file" >/dev/null 2>&1; then
		unset password
		echo "ZIP 解密失败或超时，未修改数据卷。"; return 1
	fi
	unset password
	bitwarden_prepare_restored_files "$work/extracted" "$work/data" "$target" || return 1
	rclone_require_space "$(dirname "$target")" "$(du -sb "$work/data" | awk '{print $1}')" || return 1
	read -r -p "确认用已验证的备份替换 $target？容器将保持停止。(y/N): " confirm || return 1
	[ "$confirm" = y ] || [ "$confirm" = Y ] || return 0
	bitwarden_restore_preflight && [ "$target" = "$BITWARDEN_DATA_PATH" ] || return 1
	stage=$(mktemp -d "$(dirname "$target")/.daimon-vault-restore.XXXXXX") || return 1
	cp -a -- "$work/data" "$stage/new" || return 1
	rclone check "$work/data" "$stage/new" --download >/dev/null 2>&1 || return 1
	mv -- "$target" "$stage/previous" || return 1
	moved=1
	mv -T -- "$stage/new" "$target" || return 1
	moved=0
	echo "Vaultwarden 数据卷还原完成；请启动对应 Compose 项目并验证登录。"
)

bitwarden_configure_sync_script() {
	root_use
	rclone_require || return 1
	check_crontab_installed || return 1
	if ! crontab_sync_remote_ready; then
		echo -e "${gl_hong}kissska1 连接检查失败，未修改同步脚本。${gl_bai}"
		return 1
	fi

	local script_file cron_line
	script_file=$(bitwarden_sync_script_file)
	cron_line=$(bitwarden_sync_cron_line)

	crontab_sync_write_script bitwarden "$script_file" || return 1
	(crontab -l 2>/dev/null | grep -vF "$script_file" || true; echo "$cron_line") | crontab - || return 1

	echo -e "${gl_lv}Bitwarden 同步脚本已配置${gl_bai}"
	echo "脚本路径: $script_file"
	echo "定时任务: $cron_line"
	echo "同步日志: /var/log/rclone/vaultwarden_backup_sync_日期.log"
	echo "cron 日志: /var/log/rclone/cron_Vaultwarden_OneDrive_to_Kissska1.log"
}

bitwarden_manager() {
	crontab_sync_reconcile_legacy || true
	while true; do
		clear
		echo -e "Bitwarden管理"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo -e "rclone.conf 状态: $(bitwarden_rclone_config_status)"
		echo -e "同步脚本状态: $(bitwarden_sync_script_status)"
		echo -e "配置文件位置: ${gl_kjlan}$(bitwarden_rclone_conf_file 2>/dev/null || echo "未检测到（需要 Docker 中的 vaultwarden-backup）")${gl_bai}"
		echo -e "同步脚本位置: ${gl_kjlan}$(bitwarden_sync_script_file)${gl_bai}"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo -e "${gl_kjlan}1.   ${gl_bai}配置 rclone.conf 文件"
		echo -e "${gl_kjlan}2.   ${gl_bai}数据备份"
		echo -e "${gl_kjlan}3.   ${gl_bai}数据还原"
		echo -e "${gl_kjlan}4.   ${gl_bai}配置 Bitwarden 同步脚本（OneDrive -> kissska1）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case $sub_choice in
			1) bitwarden_configure_rclone_conf ;;
			2) bitwarden_backup_data ;;
			3) bitwarden_restore_data ;;
			4) bitwarden_configure_sync_script ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
