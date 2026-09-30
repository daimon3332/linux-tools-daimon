#!/bin/bash

install_docker() {
	if ! command -v docker &>/dev/null; then
		install_add_docker
	fi
}

rclone_status_text() {
	if command -v rclone >/dev/null 2>&1; then
		rclone version 2>/dev/null | head -n 1 | awk '{print $2}'
	else
		echo "未安装"
	fi
}

rclone_prepare_config() {
	local conf_dir conf_file
	conf_file=$(rclone_config_path)
	conf_dir=$(dirname "$conf_file")
	mkdir -p "$conf_dir" && touch "$conf_file" &&
		chmod 700 "$conf_dir" && chmod 600 "$conf_file"
}

rclone_install_cn_release() (
	local work arch version archive checksum binary target staged
	case "$(uname -m)" in
		x86_64|amd64) arch=amd64 ;;
		aarch64|arm64) arch=arm64 ;;
		i?86) arch=386 ;;
		armv7*) arch=arm-v7 ;;
		armv6*) arch=arm-v6 ;;
		*) echo "不支持的 rclone 架构: $(uname -m)"; return 1 ;;
	esac
	work=$(mktemp -d) || return 1
	staged=""
	trap 'rm -rf -- "$work"; [ -z "$staged" ] || rm -f -- "$staged"' EXIT
	daimon_download_to "https://github.com/rclone/rclone/releases/latest/download/version.txt" "$work/version.txt" 30 || return 1
	read -r _ version < "$work/version.txt"
	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "rclone 版本信息无效"; return 1; }
	archive="rclone-$version-linux-$arch.zip"
	if ! daimon_download_to "https://downloads.rclone.org/$version/SHA256SUMS" "$work/SHA256SUMS" 30; then
		daimon_download_to "https://github.com/rclone/rclone/releases/download/$version/SHA256SUMS" "$work/SHA256SUMS" 30 || return 1
	fi
	checksum=$(awk -v name="$archive" '$2 == name || $2 == "*" name {print $1}' "$work/SHA256SUMS")
	[[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "未找到有效的 rclone SHA256 校验值"; return 1; }
	daimon_download_to "https://github.com/rclone/rclone/releases/download/$version/$archive" "$work/$archive" 300 || return 1
	printf '%s  %s\n' "$checksum" "$work/$archive" | sha256sum -c - || return 1
	unzip -tq "$work/$archive" >/dev/null || return 1
	binary="$work/rclone"
	unzip -p "$work/$archive" "rclone-$version-linux-$arch/rclone" > "$binary" || return 1
	chmod 755 "$binary" || return 1
	[ "$("$binary" version 2>/dev/null | head -n1)" = "rclone $version" ] || return 1
	target="${DAIMON_RCLONE_BIN_DIR:-/usr/local/bin}/rclone"
	mkdir -p "$(dirname "$target")" || return 1
	staged=$(mktemp "${target}.XXXXXX") || return 1
	command install -m 755 "$binary" "$staged" && mv -f -- "$staged" "$target" || return 1
	staged=""
	"$target" version
)

rclone_install_tool() {
	root_use
	local status=0 active_bin staged
	install curl unzip || return 1
	if daimon_is_cn; then
		rclone_install_cn_release || status=$?
	else
		DAIMON_SCRIPT_TIMEOUT=600 daimon_run_cached_script "https://rclone.org/install.sh" "rclone-install.sh" || status=$?
		active_bin=$(command -v rclone 2>/dev/null || true)
		if [ "$status" -eq 0 ] && [ "$active_bin" = /usr/local/bin/rclone ]; then
			/usr/bin/rclone version >/dev/null 2>&1 || return 1
			staged=$(mktemp /usr/local/bin/rclone.XXXXXX) || return 1
			if ! command install -m 755 /usr/bin/rclone "$staged" || ! mv -f -- "$staged" "$active_bin"; then
				rm -f -- "$staged"
				return 1
			fi
		fi
		[ "$status" -eq 3 ] && status=0
	fi
	hash -r
	if [ "$status" -ne 0 ] || ! command -v rclone >/dev/null 2>&1 || ! rclone version; then
		echo -e "${gl_hong}rclone 安装失败，现有配置保持不变。${gl_bai}"
		return 1
	fi
	rclone_prepare_config || return 1
	echo -e "${gl_lv}rclone 安装完成${gl_bai}"
	echo -e "${gl_kjlan}配置文件: $(rclone_config_path)${gl_bai}"
}

rclone_require() {
	command -v rclone >/dev/null 2>&1 && return 0
	echo -e "${gl_kjlan}缺少 rclone，正在自动安装...${gl_bai}"
	rclone_install_tool
}

rclone_edit_config() {
	root_use
	rclone_require || return 1
	daimon_require_cmd vim || return 1
	rclone_prepare_config || return 1
	vim "$(rclone_config_path)" || return 1
	chmod 600 "$(rclone_config_path)" || return 1
	echo -e "${gl_lv}配置文件权限已设置为 600${gl_bai}"
	echo -e "${gl_kjlan}当前远程存储:${gl_bai}"
	rclone listremotes 2>/dev/null || true
}

rclone_uninstall_tool() {
	root_use
	read -e -p "确认卸载 rclone？(y/N): " confirm || return 1
	[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "已取消"; return; }
	if command -v apt >/dev/null 2>&1; then
		apt purge -y rclone 2>/dev/null || true
	elif command -v dnf >/dev/null 2>&1; then
		dnf remove -y rclone 2>/dev/null || true
	elif command -v yum >/dev/null 2>&1; then
		yum remove -y rclone 2>/dev/null || true
	elif command -v apk >/dev/null 2>&1; then
		apk del rclone 2>/dev/null || true
	fi
	rm -f /usr/bin/rclone /usr/local/bin/rclone 2>/dev/null || true
	read -e -p "是否同时删除 /root/.config/rclone 配置目录？(y/N): " remove_conf || return 1
	if [ "$remove_conf" = "y" ] || [ "$remove_conf" = "Y" ]; then
		rm -rf /root/.config/rclone
	fi
	echo -e "${gl_lv}rclone 卸载完成${gl_bai}"
}

rclone_restore_name_valid() {
	local name="$1"
	[ -n "$name" ] && [ "$name" != "." ] && [ "$name" != ".." ] || return 1
	case "$name" in
		*/*|*\\*|*[[:cntrl:]]*) return 1 ;;
	esac
	return 0
}

rclone_config_path() {
	printf '%s\n' "${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
}

rclone_config_remotes() (
	set -o pipefail
	rclone --config "$1" config dump --ask-password=false 2>/dev/null | python3 -c '
import json, sys
for name, config in sorted(json.load(sys.stdin).items()):
    kind = config.get("type", "unknown")
    if all(ord(c) >= 32 and ord(c) != 127 for c in name + kind):
        print(name + "\t" + kind)
'
)

rclone_remote_state() (
	umask 077
	local conf="$1" remote="$2" work
	work=$(mktemp -d) || { echo unknown; return; }
	trap 'rm -rf -- "$work"' EXIT
	if ! cp -- "$conf" "$work/rclone.conf" || ! command -v timeout >/dev/null 2>&1; then
		echo unknown
		return
	fi
	if timeout 25s rclone --config "$work/rclone.conf" lsf "$remote" --dirs-only --max-depth 1 \
		--ask-password=false --contimeout 8s --timeout 15s --retries 1 --low-level-retries 1 \
		>/dev/null 2>"$work/error"; then
		echo valid
	elif grep -Eqi 'invalid_grant|invalid_client|invalid_token|unauthenticated|401 Unauthorized|InvalidAccessKeyId|SignatureDoesNotMatch' "$work/error"; then
		echo invalid
	else
		echo unknown
	fi
)

rclone_state_text() {
	case "$1" in
		valid) echo "有效（读取验证）" ;;
		invalid) echo "无效（认证失败）" ;;
		*) echo "无法检测（网络、权限或配置）" ;;
	esac
}

rclone_load_remote_status() {
	local conf="${1:-$(rclone_config_path)}" entries name kind state
	RCLONE_REMOTE_NAMES=() RCLONE_REMOTE_STATES=()
	command -v rclone >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
		echo "需要 rclone 和 python3 才能检查远程存储。"; return 1;
	}
	entries=$(rclone_config_remotes "$conf") || { echo "无法读取 rclone 配置；未显示敏感内容。"; return 1; }
	while IFS=$'\t' read -r name kind; do
		[ -n "$name" ] || continue
		state=$(rclone_remote_state "$conf" "$name:")
		RCLONE_REMOTE_NAMES+=("$name") RCLONE_REMOTE_STATES+=("$state")
		printf '%2d. %s [%s] %s\n' "${#RCLONE_REMOTE_NAMES[@]}" "$name" "$kind" "$(rclone_state_text "$state")"
	done <<< "$entries"
	[ "${#RCLONE_REMOTE_NAMES[@]}" -gt 0 ] || { echo "未配置远程存储。"; return 1; }
}

rclone_select_remote() {
	local conf="${1:-$(rclone_config_path)}" idx
	RCLONE_SELECTED_REMOTE=""
	rclone_require && daimon_require_cmd python3 || return 1
	rclone_load_remote_status "$conf" || return 1
	read -r -p "请选择有效远程存储（0 返回）: " idx || return 1
	idx=$(rclone_selection_index "$idx" "${#RCLONE_REMOTE_NAMES[@]}") || return 1
	[ "${RCLONE_REMOTE_STATES[idx]}" = valid ] || { echo "该远程尚未通过验证，已取消。"; return 1; }
	RCLONE_SELECTED_REMOTE="${RCLONE_REMOTE_NAMES[idx]}"
}

rclone_selection_index() {
	local value="$1" count="$2"
	[[ "$value" =~ ^[0-9]{1,8}$ ]] || return 1
	value=$((10#$value))
	[ "$value" -ge 1 ] && [ "$value" -le "$count" ] || return 1
	echo "$((value - 1))"
}

rclone_directory_names() (
	set -o pipefail
	rclone lsjson "$1" --dirs-only --max-depth 1 --contimeout 10s --timeout 30s --retries 1 \
		--low-level-retries 1 2>/dev/null | python3 -c '
import json, sys
for item in json.load(sys.stdin):
    name = item["Name"]
    if item.get("IsDir") and name not in ("", ".", "..") and not any(ord(c) < 32 or ord(c) == 127 or c in "/\\" for c in name):
        print(name)
'
)

rclone_tree_safe() {
	local path="$1" canonical link
	canonical=$(realpath -m -- "$path") || return 1
	[ "$canonical" = "$path" ] && [ ! -L "$path" ] || { echo "拒绝符号链接或非规范目标: $path"; return 1; }
	if [ -e "$path" ]; then
		[ -d "$path" ] || return 1
		link=$(find "$path" -type l -print -quit) || return 1
		[ -z "$link" ] || { echo "目标含符号链接，需人工确认: $link"; return 1; }
	fi
}

rclone_assert_inactive() {
	local target="$1" ids data
	command -v docker >/dev/null 2>&1 || return 0
	ids=$(docker ps -q 2>/dev/null) || { echo "无法检查 Docker 挂载，已停止恢复。"; return 1; }
	[ -n "$ids" ] || return 0
	data=$(docker inspect $ids 2>/dev/null) || return 1
	printf '%s' "$data" | python3 -c '
import json, os, sys
target = os.path.realpath(sys.argv[1])
busy = []
for container in json.load(sys.stdin):
    for mount in container.get("Mounts", []):
        source = os.path.realpath(mount.get("Source", "/"))
        if os.path.commonpath([source, target]) in (source, target):
            busy.append(container["Name"].lstrip("/"))
if busy:
    print("目标数据仍被容器使用: " + ", ".join(sorted(set(busy))))
sys.exit(bool(busy))
' "$target"
}

rclone_require_space() {
	local dir="$1" needed="$2" free
	[[ "$needed" =~ ^[0-9]+$ ]] || return 1
	free=$(df -Pk -- "$dir" | awk 'NR==2 {print $4}') || return 1
	[[ "$free" =~ ^[0-9]+$ ]] || return 1
	python3 -c 'import sys; sys.exit(int(sys.argv[1]) * 1024 <= int(sys.argv[2]) + 4194304)' "$free" "$needed" || {
		echo "暂存及回滚空间不足: $dir"; return 1;
	}
}

rclone_restore_record() (
	umask 077
	local dir="${DAIMON_RESTORE_ROOT:-/root}/linux-daimon" file
	[ "$(realpath -m -- "$dir")" = "$dir" ] && [ ! -L "$dir" ] || return 1
	mkdir -p "$dir" || return 1
	file="$dir/restore-status.json"
	[ ! -L "$file" ] || return 1
	python3 - "$file" "$@" <<'PY'
import datetime, json, os, sys, tempfile
from pathlib import Path
p = Path(sys.argv[1])
stage, target, status, detail = sys.argv[2:]
entries = json.loads(p.read_text()) if p.exists() else []
if not isinstance(entries, list):
    sys.exit(1)
entries = [e for e in entries if (e.get("stage"),e.get("target")) != (stage,target)]
entries.append(dict(stage=stage, target=target, status=status, detail=detail, time=datetime.datetime.now(datetime.timezone.utc).isoformat()))
fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".restore-status.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(entries, f, ensure_ascii=True, indent=2)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
)

rclone_restore_folder() (
	umask 077
	set -o pipefail
	local remote="$1" root="$2" name="$3" policy="${4:-keep}" target work size existing=0 committed=0
	rclone_restore_name_valid "$name" || return 1
	[ "$policy" = keep ] || [ "$policy" = replace ] || return 1
	root=$(realpath -e -- "$root") || return 1
	target="$root/$name"
	rclone_tree_safe "$target" && rclone_assert_inactive "$target" || return 1
	size=$(rclone size "$remote" --json --contimeout 10s --timeout 30s --retries 1 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])') || return 1
	[[ "$size" =~ ^[0-9]{1,15}$ ]] || return 1
	[ ! -d "$target" ] || existing=$(du -sb -- "$target" | awk '{print $1}') || return 1
	rclone_require_space "$root" "$((size * 2 + existing))" || return 1
	work=$(mktemp -d "$root/.daimon-restore.XXXXXX") || return 1
	trap 'if [ "$committed" = 1 ]; then if [ -e "$target" ] || [ -L "$target" ] || ! mv -T -- "$work/previous" "$target"; then echo "回滚未完成，保留: $work"; exit 1; fi; fi; rm -rf -- "$work"' EXIT
	mkdir "$work/download" "$work/result" || return 1
	if ! rclone copy "$remote" "$work/download" --contimeout 10s --timeout 60s --retries 1 2>"$work/error" ||
		! rclone check "$remote" "$work/download" --download --contimeout 10s --timeout 60s --retries 1 > /dev/null 2>"$work/error"; then
		echo "下载或内容校验失败，原目录未修改。"
		return 1
	fi
	rclone_tree_safe "$work/download" || return 1
	[ ! -d "$target" ] || cp -a -- "$target/." "$work/result/" || return 1
	if [ "$policy" = keep ]; then
		cp -an -- "$work/download/." "$work/result/" || return 1
	else
		cp -a -- "$work/download/." "$work/result/" || return 1
	fi
	rclone_tree_safe "$target" && rclone_assert_inactive "$target" || return 1
	if [ -e "$target" ]; then
		mv -- "$target" "$work/previous" || return 1
		committed=1
	fi
	mv -T -- "$work/result" "$target" || return 1
	committed=0
	echo "恢复并校验完成: $target（同名文件策略: $policy）"
)

rclone_select_remote_dir() {
	local remote="$1"
	local title="$2"
	local list_output selected_idx i
	local dirs=()
	local valid_dirs=()
	RCLONE_SELECTED_DIR=""

	echo "$title"
	echo "远程路径: $remote"
	if ! list_output=$(rclone_directory_names "$remote"); then
		echo -e "${gl_hong}读取远程目录失败，请检查 rclone 配置和远程路径。${gl_bai}"
		return 1
	fi

	mapfile -t dirs <<< "$list_output"
	for i in "${dirs[@]}"; do
		rclone_restore_name_valid "$i" && valid_dirs+=("$i")
	done
	if [ "${#valid_dirs[@]}" -eq 0 ]; then
		echo -e "${gl_huang}未找到可选择的子文件夹。${gl_bai}"
		return 1
	fi

	echo "------------------------"
	for ((i=0; i<${#valid_dirs[@]}; i++)); do
		printf "%2d. %s\n" "$((i+1))" "${valid_dirs[i]}"
	done
	echo "------------------------"
	read -e -p "请输入目录序号: " selected_idx || return 1
	if ! selected_idx=$(rclone_selection_index "$selected_idx" "${#valid_dirs[@]}"); then
		echo "无效编号"
		return 1
	fi

	RCLONE_SELECTED_DIR="${valid_dirs[selected_idx]}"
}

rclone_select_remote_dirs_multi() {
	local remote="$1"
	local title="$2"
	local list_output selected_raw token idx i exists
	local dirs=()
	local valid_dirs=()
	local selected_dirs=()
	RCLONE_SELECTED_DIRS=()

	echo "$title"
	echo "远程路径: $remote"
	if ! list_output=$(rclone_directory_names "$remote"); then
		echo -e "${gl_hong}读取远程目录失败，请检查 rclone 配置和远程路径。${gl_bai}"
		return 1
	fi

	mapfile -t dirs <<< "$list_output"
	for i in "${dirs[@]}"; do
		rclone_restore_name_valid "$i" && valid_dirs+=("$i")
	done
	if [ "${#valid_dirs[@]}" -eq 0 ]; then
		echo -e "${gl_huang}未找到可选择的子文件夹。${gl_bai}"
		return 1
	fi

	echo "------------------------"
	for ((i=0; i<${#valid_dirs[@]}; i++)); do
		printf "%2d. %s\n" "$((i+1))" "${valid_dirs[i]}"
	done
	echo "------------------------"
	echo "支持输入: 1 2 3、1,2,3、all"
	read -e -p "请输入目录序号（0 返回）: " selected_raw || return 1
	[ "$selected_raw" = "0" ] && return 1
	selected_raw="${selected_raw//,/ }"

	if [[ "$selected_raw" =~ ^[Aa][Ll][Ll]$ ]]; then
		RCLONE_SELECTED_DIRS=("${valid_dirs[@]}")
		return 0
	fi

	for token in $selected_raw; do
		if ! idx=$(rclone_selection_index "$token" "${#valid_dirs[@]}"); then
			echo -e "${gl_huang}跳过无效编号: $token${gl_bai}"
			continue
		fi
		exists=0
		for i in "${selected_dirs[@]}"; do
			[ "$i" = "${valid_dirs[idx]}" ] && exists=1 && break
		done
		[ "$exists" -eq 0 ] && selected_dirs+=("${valid_dirs[idx]}")
	done

	if [ "${#selected_dirs[@]}" -eq 0 ]; then
		echo -e "${gl_huang}未选择有效目录。${gl_bai}"
		return 1
	fi
	RCLONE_SELECTED_DIRS=("${selected_dirs[@]}")
}

rclone_restore_remote_folder() {
	root_use
	rclone_require || return 1

	local remote_root root="${DAIMON_RESTORE_ROOT:-/root}" policy
	local server_dir restore_dir remote_path target_dir confirm failed
	local restore_dirs=()

	rclone_select_remote || return 1
	remote_root="$RCLONE_SELECTED_REMOTE:"
	rclone_select_remote_dir "$remote_root" "请选择服务器目录" || return
	server_dir="$RCLONE_SELECTED_DIR"

	rclone_select_remote_dirs_multi "${remote_root}${server_dir}" "请选择要恢复的文件夹，可多选" || return
	restore_dirs=("${RCLONE_SELECTED_DIRS[@]}")
	echo "远程根层清单（文件仅显示，不自动恢复）："
	rclone lsjson "${remote_root}${server_dir}" --max-depth 1 --contimeout 10s --timeout 30s --retries 1 2>/dev/null | python3 -c '
import json,sys
selected = set(sys.argv[1:])
for e in json.load(sys.stdin):
    name = e["Name"]
    if any(ord(c)<32 or ord(c)==127 for c in name): continue
    state = "selected" if e.get("IsDir") and name in selected else "not selected"
    print("  %s [%s, %s]" % (name, "directory" if e.get("IsDir") else "file", state))
' "${restore_dirs[@]}" || { echo "无法列出完整清单，未开始恢复。"; return 1; }

	echo -e "${gl_huang}即将执行:${gl_bai}"
	for restore_dir in "${restore_dirs[@]}"; do
		remote_path="${remote_root}${server_dir}/${restore_dir}"
		target_dir="$root/${restore_dir}"
		echo "$remote_path -> $target_dir"
	done
	echo "仅恢复选中的子目录；不包含根层文件、未备份的隐藏配置、/data、Docker volumes 或系统 cron。"
	echo "云文件恢复不保证原主机的 UID/GID、权限及符号链接；启动服务前必须检查数据挂载。"
	read -r -p "同名文件处理：1 保留本机并补齐缺项，2 使用远程版本（0 返回）: " policy || return 1
	case "$policy" in 1) policy=keep ;; 2) policy=replace ;; *) return 0 ;; esac
	read -e -p "确认恢复以上 ${#restore_dirs[@]} 个文件夹？(y/N): " confirm || return 1
	[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "已取消"; return; }

	failed=0
	for restore_dir in "${restore_dirs[@]}"; do
		remote_path="${remote_root}${server_dir}/${restore_dir}"
		rclone_restore_record folder "$root/$restore_dir" pending "$policy" || return 1
		if rclone_restore_folder "$remote_path" "$root" "$restore_dir" "$policy"; then
			rclone_restore_record folder "$root/$restore_dir" restored "download checked; policy=$policy" || failed=1
		else
			rclone_restore_record folder "$root/$restore_dir" failed "check restore output" || true
			failed=1
		fi
	done
	[ "$failed" -eq 0 ] || echo "部分目录恢复失败，不能视为整机迁移完成。"
	return "$failed"
}

rclone_nginx_prepare() {
	if ! command -v nginx >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
		install nginx openssl || return 1
	fi
	if ! command -v nginx >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
		echo "Nginx/OpenSSL 安装后仍不可用。"
		return 1
	fi
	if ! command -v ufw >/dev/null 2>&1; then
		install ufw || return 1
	fi
	command -v ufw >/dev/null 2>&1
}

rclone_nginx_allow_ports() {
	local status ssh_ports ssh_port
	command -v ufw >/dev/null 2>&1 || { echo "UFW 未安装。"; return 1; }
	status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
	case "$status" in *'Status: active'*|*'Status: inactive'*) ;; *) echo "UFW 状态未知，未修改规则。"; return 1 ;; esac
	ssh_ports=$(ssh_current_ports) || return 1
	while IFS= read -r ssh_port; do
		[[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] && [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ] || return 1
		ufw allow "$ssh_port/tcp" || return 1
	done <<< "$ssh_ports"
	ufw allow 80/tcp && ufw allow 443/tcp || return 1
	ufw allow from 172.16.0.0/12 || return 1
	if [[ "$status" != *'Status: active'* ]]; then
		ufw --force enable || return 1
	fi
	status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
	[[ "$status" = *'Status: active'* ]] || { echo "UFW 启用失败。"; return 1; }
	echo "UFW 已启用：SSH(${ssh_ports//$'\n'/,})、80/tcp、443/tcp、172.16.0.0/12。"
	echo "保留已有防火墙策略；云安全组仍须允许业务流量。"
}

rclone_nginx_cert_valid() (
	set -o pipefail
	local dir="$1" cert_key private_key
	[ -s "$dir/fullchain.pem" ] && [ -s "$dir/privkey.pem" ] || { echo "证书或私钥缺失: $dir"; return 1; }
	openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || { echo "证书无效或已过期: $dir"; return 1; }
	cert_key=$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) || return 1
	private_key=$(openssl pkey -in "$dir/privkey.pem" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum) || return 1
	[ "$cert_key" = "$private_key" ] || { echo "证书与私钥不匹配: $dir"; return 1; }
)

rclone_nginx_target_for_key() {
	local key="$1" nginx_dir="${DAIMON_NGINX_DIR:-/etc/nginx}"
	case "$key" in
		sites-available|sites-enabled|conf.d|stream.d|nginx.conf|mime.types) printf '%s/%s\n' "$nginx_dir" "$key" ;;
		home-web-conf.d) printf '%s/conf.d\n' "${DAIMON_WEB_DIR:-/home/web}" ;;
		home-web-stream.d) printf '%s/stream.d\n' "${DAIMON_WEB_DIR:-/home/web}" ;;
		domain) printf '%s\n' "${DAIMON_DOMAIN_DIR:-${DAIMON_RESTORE_ROOT:-/root}/domain}" ;;
		*) return 1 ;;
	esac
}

rclone_nginx_loaded_files() (
	set -o pipefail
	nginx -T 2>/dev/null | python3 -c '
import json, re, sys
paths = sorted(set(re.findall(r"^# configuration file (.+):$", sys.stdin.read(), re.M)))
if not paths or any(any(ord(c) < 32 or ord(c) == 127 for c in p) for p in paths):
    sys.exit(1)
print(json.dumps(paths))
'
)

rclone_nginx_write_bundle() (
	set -o pipefail
	local dest="$1" key src loaded keys=()
	loaded=$(rclone_nginx_loaded_files) || { echo "Nginx 配置无法解析，未刷新迁移清单。"; return 1; }
	for key in sites-available domain conf.d stream.d home-web-conf.d home-web-stream.d nginx.conf mime.types; do
		src=$(rclone_nginx_target_for_key "$key") || return 1
		[ -e "$src" ] || continue
		if [ -d "$src" ]; then rclone_tree_safe "$src" || return 1; else [ ! -L "$src" ] || return 1; fi
		cp -a -- "$src" "$dest/$key" || return 1
		keys+=("$key")
	done
	printf '%s\n' "$loaded" > "$dest/config-files.json" || return 1
	: > "$dest/enabled_sites.txt" || return 1
	if [ -d "${DAIMON_NGINX_DIR:-/etc/nginx}/sites-enabled" ]; then
		find "${DAIMON_NGINX_DIR:-/etc/nginx}/sites-enabled" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > "$dest/enabled_sites.txt" || return 1
	fi
	printf 'backup_time=%s\nmode=auto_latest\nitems=%s\n' "$(date -Is)" "${keys[*]}" > "$dest/manifest.txt"
)

rclone_nginx_write_backup_script() {
	{
		printf '#!/bin/bash\nset -euo pipefail\numask 077\n'
		declare -f rclone_tree_safe rclone_nginx_target_for_key rclone_nginx_loaded_files rclone_nginx_write_bundle || return 1
		cat <<'EOF'
BACKUP_ROOT="${DAIMON_BACKUP_DIR:-/root/linux-daimon/backup}/nginx-domain"
BACKUP_DIR="$BACKUP_ROOT/auto_latest"
domain_dir="${DAIMON_DOMAIN_DIR:-/root/domain}"
if ! find "$domain_dir" -mindepth 2 -maxdepth 2 -type f -name fullchain.pem -size +0c -print -quit 2>/dev/null | grep -q .; then
    exit 0
fi
rclone_tree_safe "$BACKUP_ROOT"
mkdir -p "$BACKUP_ROOT"
exec 9>"$BACKUP_ROOT/.bundle.lock"
flock -n 9 || exit 0
TMP_DIR=$(mktemp -d "$BACKUP_ROOT/.bundle.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT
rclone_nginx_write_bundle "$TMP_DIR"
rclone_tree_safe "$BACKUP_DIR"
rm -rf -- "$BACKUP_DIR"
mv -- "$TMP_DIR" "$BACKUP_DIR"
EOF
	} > "$1"
}

rclone_nginx_check_manifest() {
	local backup="$1" loaded
	[ -f "$backup/config-files.json" ] || { echo "旧备份未记录 Nginx include 清单，额外配置需人工核对。"; return 0; }
	loaded=$(rclone_nginx_loaded_files) || return 1
	python3 - "$backup/config-files.json" "$loaded" <<'PY'
import json, sys
from pathlib import Path
expected = json.loads(Path(sys.argv[1]).read_text())
actual = json.loads(sys.argv[2])
if not isinstance(expected, list) or not all(isinstance(p, str) and p.startswith("/") and not any(ord(c)<32 for c in p) for p in expected):
    sys.exit("Invalid Nginx include manifest.")
missing = sorted(set(expected) - set(actual))
for path in missing:
    print("Nginx include not loaded: " + path)
sys.exit(bool(missing))
PY
}

rclone_nginx_apply() (
	umask 077
	set -o pipefail
	local backup="$1" mode="${2:-all}" policy="${3:-keep}"
	local nginx_dir="${DAIMON_NGINX_DIR:-/etc/nginx}" domain_dir="${DAIMON_DOMAIN_DIR:-${DAIMON_RESTORE_ROOT:-/root}/domain}"
	local work name src dst key i changed=0 was_running=0 size=0
	local keys=() targets=() existed=()
	case "$policy" in keep|replace) ;; *) return 1 ;; esac
	case "$mode" in
		sites) keys=(sites-available) ;;
		links) keys=(sites-enabled) ;;
		domain) keys=(domain) ;;
		all)
			for key in sites-available domain conf.d stream.d home-web-conf.d home-web-stream.d nginx.conf mime.types; do
				[ ! -e "$backup/$key" ] || keys+=("$key")
			done
			[ ! -s "$backup/enabled_sites.txt" ] || keys+=(sites-enabled)
			[ "${#keys[@]}" -gt 0 ] || { echo "备份中没有可恢复的 Nginx 或域名内容。"; return 1; }
			;;
		*) return 1 ;;
	esac
	rclone_tree_safe "$backup" || return 1
	if [ "$mode" = all ] || [ "$mode" = links ]; then
		[ -f "$backup/enabled_sites.txt" ] || { echo "缺少 enabled_sites.txt，拒绝猜测或启用本机其他站点。"; return 1; }
	fi
	rclone_nginx_prepare || { echo "Nginx 依赖安装失败，未恢复配置。"; return 1; }
	mkdir -p "$nginx_dir" "$(dirname "$domain_dir")" || return 1
	[ "$(realpath -e "$nginx_dir")" = "$nginx_dir" ] || return 1
	for key in "${keys[@]}"; do
		dst=$(rclone_nginx_target_for_key "$key") || return 1
		mkdir -p "$(dirname "$dst")" || return 1
		[ "$(realpath -m "$dst")" = "$dst" ] && [ ! -L "$dst" ] || return 1
		case "$key" in
			nginx.conf|mime.types) [ -f "$backup/$key" ] && { [ ! -e "$dst" ] || [ -f "$dst" ]; } || return 1 ;;
			*) [ "$key" = sites-enabled ] || rclone_tree_safe "$dst" || return 1 ;;
		esac
		rclone_assert_inactive "$dst" || return 1
		targets+=("$dst")
		[ ! -e "$dst" ] || size=$((size + $(du -sb "$dst" | awk '{print $1}')))
		[ ! -e "$backup/$key" ] || rclone_require_space "$(dirname "$dst")" "$(du -sb "$backup/$key" | awk '{print $1}')" || return 1
	done
	size=$((size + $(du -sb "$backup" | awk '{print $1}')))
	rclone_require_space "$nginx_dir" "$((size * 2))" || return 1
	work=$(mktemp -d "$nginx_dir/.daimon-nginx.XXXXXX") || return 1
	systemctl is-active --quiet nginx && was_running=1
	rclone_nginx_finish() {
		local rc=$? j rollback_failed=0
		if [ "$rc" -ne 0 ] && [ "$changed" -gt 0 ]; then
			if [ "$was_running" = 0 ]; then systemctl stop nginx >/dev/null 2>&1 || rollback_failed=1; fi
			for ((j=changed-1; j>=0; j--)); do
				rm -rf -- "${targets[j]}" || rollback_failed=1
				[ "${existed[j]}" = 0 ] || cp -a -- "$work/old/$j" "${targets[j]}" || rollback_failed=1
			done
			if [ "$was_running" = 1 ]; then
				nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || rollback_failed=1
			fi
			echo "恢复失败，已尝试回滚原配置。"
		fi
		if [ "$rollback_failed" = 0 ]; then rm -rf -- "$work"; else echo "回滚未完成，保留现场: $work"; fi
	}
	trap rclone_nginx_finish EXIT
	mkdir "$work/old" "$work/new" || return 1
	for i in "${!keys[@]}"; do
		key="${keys[i]}" dst="${targets[i]}"
		if [ -e "$dst" ]; then
			existed+=(1)
			cp -a -- "$dst" "$work/old/$i" && cp -a -- "$dst" "$work/new/$key" || return 1
		else
			existed+=(0)
			case "$key" in nginx.conf|mime.types) ;; *) mkdir "$work/new/$key" || return 1 ;; esac
		fi
		[ "$key" != sites-enabled ] || continue
		case "$key" in
			nginx.conf|mime.types)
				if [ "$policy" = replace ] || [ ! -f "$work/new/$key" ]; then cp -a -- "$backup/$key" "$work/new/$key" || return 1; fi
				continue ;;
		esac
		[ -d "$backup/$key" ] || { echo "备份缺少: $key"; return 1; }
		if [ "$policy" = keep ]; then
			cp -an -- "$backup/$key/." "$work/new/$key/" || return 1
		else
			cp -a -- "$backup/$key/." "$work/new/$key/" || return 1
		fi
	done
	if [ "$mode" = domain ] || [ "$mode" = all ]; then
		for src in "$backup/domain"/*; do
			[ -d "$src" ] || continue
			rclone_nginx_cert_valid "$work/new/domain/$(basename "$src")" || return 1
		done
	fi
	if [ "$mode" = links ] || [ "$mode" = all ]; then
		while IFS= read -r name || [ -n "$name" ]; do
			[ -n "$name" ] || continue
			rclone_restore_name_valid "$name" || { echo "站点清单包含非法名称。"; return 1; }
			src="$nginx_dir/sites-available/$name"
			if [ "$mode" = all ]; then [ -f "$work/new/sites-available/$name" ] || return 1; else [ -f "$src" ] || return 1; fi
			dst="$work/new/sites-enabled/$name"
			if [ -L "$dst" ] && [ "$(realpath -m "$nginx_dir/sites-enabled/$name")" = "$src" ]; then continue; fi
			if [ -e "$dst" ] || [ -L "$dst" ]; then echo "启用站点冲突: $name"; return 1; fi
			ln -s -- "$src" "$dst" || return 1
		done < "$backup/enabled_sites.txt"
	fi
	for i in "${!keys[@]}"; do
		changed=$((i + 1))
		rm -rf -- "${targets[i]}" && cp -a -- "$work/new/${keys[i]}" "${targets[i]}" || return 1
	done
	nginx -t || { echo "配置校验失败，检查缺失的 include、证书、模块或路径。"; return 1; }
	[ "$mode" != all ] || rclone_nginx_check_manifest "$backup" || return 1
	rclone_nginx_allow_ports && rclone_check_nginx_after_restore || return 1
	systemctl enable nginx >/dev/null 2>&1 || return 1
	echo "Nginx 恢复成功（同名文件策略: $policy）；未修改 DNS。"
	[ -x "${DAIMON_RESTORE_ROOT:-/root}/.acme.sh/acme.sh" ] || echo "注意：acme.sh 未迁移，证书自动续期尚未验证。"
	printf '本次恢复项：%s\n' "${keys[*]}"
	return 0
)

rclone_nginx_download_apply() (
	umask 077
	set -o pipefail
	local remote="$1" mode="$2" policy="${3:-keep}" work size root="${DAIMON_RESTORE_ROOT:-/root}"
	size=$(rclone size "$remote" --json --contimeout 10s --timeout 30s --retries 1 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])') || return 1
	[[ "$size" =~ ^[0-9]{1,15}$ ]] || return 1
	rclone_require_space "$root" "$((size * 3))" || return 1
	work=$(mktemp -d "$root/.daimon-nginx-download.XXXXXX") || return 1
	trap 'rm -rf -- "$work"' EXIT
	if ! rclone copy "$remote" "$work" --contimeout 10s --timeout 60s --retries 1 2>/dev/null ||
		! rclone check "$remote" "$work" --download --contimeout 10s --timeout 60s --retries 1 >/dev/null 2>&1; then
		echo "Nginx 备份下载或内容校验失败，未应用配置。"
		return 1
	fi
	rclone_nginx_apply "$work" "$mode" "$policy"
)

rclone_check_nginx_after_restore() {
	command -v nginx >/dev/null 2>&1 || { echo "未安装 Nginx，恢复未完成。"; return 1; }
	nginx -t || return 1
	if systemctl is-active --quiet nginx; then
		systemctl reload nginx || { echo "Nginx 重载失败。"; return 1; }
	else
		systemctl start nginx || { echo "Nginx 启动失败。"; return 1; }
	fi
	systemctl is-active --quiet nginx || return 1
	echo "Nginx 配置校验及服务状态检查通过。"
}

rclone_restore_nginx_domain_remote() {
	root_use
	rclone_require || return 1

	local remote_root server_dir remote_backup choice confirm mode policy

	rclone_select_remote || return 1
	remote_root="$RCLONE_SELECTED_REMOTE:"
	rclone_select_remote_dir "$remote_root" "请选择包含 Nginx + 域名备份的服务器目录" || return
	server_dir="$RCLONE_SELECTED_DIR"
	remote_backup="${remote_root}${server_dir}/linux-daimon/backup/nginx-domain/auto_latest"

	echo "正在检查远程备份: $remote_backup"
	if ! rclone lsf "$remote_backup" >/dev/null 2>&1; then
		echo -e "${gl_hong}未找到远程 Nginx + 域名备份：$remote_backup${gl_bai}"
		return 1
	fi

	while true; do
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo "远程备份: $remote_backup"
		echo -e "${gl_kjlan}1.   ${gl_bai}恢复 sites-available"
		echo -e "${gl_kjlan}2.   ${gl_bai}重建 sites-enabled 软链接"
		echo -e "${gl_kjlan}3.   ${gl_bai}恢复域名证书 /root/domain"
		echo -e "${gl_kjlan}4.   ${gl_bai}一键恢复全部"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1) mode=sites ;;
			2) mode=links ;;
			3) mode=domain ;;
			4) mode=all ;;
			0) return ;;
			*) echo "无效的输入!"; continue ;;
		esac
		read -r -p "同名文件：1 保留并补齐，2 使用远程版本（0 返回）: " policy || return 1
		case "$policy" in 1) policy=keep ;; 2) policy=replace ;; *) continue ;; esac
		echo "将自动安装缺少的 Nginx/OpenSSL/UFW；保护 SSH 后启用 UFW，放行 80/443 和 172.16.0.0/12。"
		read -r -p "确认恢复以上配置和防火墙规则？(y/N): " confirm || return 1
		[ "$confirm" = y ] || [ "$confirm" = Y ] || continue
		rclone_restore_record nginx "$mode" pending "$policy" || return 1
		if rclone_nginx_download_apply "$remote_backup" "$mode" "$policy"; then
			rclone_restore_record nginx "$mode" restored "Nginx config/service and UFW checked" || return 1
		else
			rclone_restore_record nginx "$mode" failed "check restore output" || return 1
			echo "恢复失败，不能视为迁移完成。"
		fi
	done
}

rclone_compose_directories() {
	python3 - "${DAIMON_RESTORE_ROOT:-/root}" <<'PY'
import os, sys
root = os.path.realpath(sys.argv[1])
names = {"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"}
for directory, children, files in os.walk(root, followlinks=False):
    depth = len(os.path.relpath(directory, root).split(os.sep)) if directory != root else 0
    children[:] = [name for name in sorted(children) if depth < 5 and not name.startswith((".", "migration-", "audit-")) and name not in ("data", "backup", "backups", "node_modules", "volumes")]
    if names.intersection(files) and not any(ord(c) < 32 or ord(c) == 127 for c in directory):
        print(directory)
PY
}

rclone_compose_prepare() {
	if ! command -v docker >/dev/null 2>&1; then
		if [ -e /etc/docker/daemon.json ] || [ -L /etc/docker/daemon.json ]; then
			echo "已有 daemon.json 但 Docker 不可用；为避免上游安装器改写配置，请先修复 Docker 安装。"
			return 1
		fi
		echo "未检测到 Docker，正在调用现有 Docker 安装流程。"
		install_docker || return 1
	fi
	command -v docker >/dev/null 2>&1 || { echo "Docker 安装后仍不可用。"; return 1; }
	if ! docker info >/dev/null 2>&1; then
		systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
		sleep 2
	fi
	docker info >/dev/null 2>&1 || { echo "Docker daemon 启动失败。"; return 1; }
	docker_compose_require_plugin || return 1
	docker compose up --help 2>/dev/null | grep -q -- '--wait' || { echo "Compose 版本不支持健康等待，请升级 Compose 插件。"; return 1; }
}

rclone_compose_context() {
	local dir="$1" data ids context="" line
	RCLONE_COMPOSE_ARGS=()
	declare -p RCLONE_COMPOSE_MANUAL >/dev/null 2>&1 || declare -gA RCLONE_COMPOSE_MANUAL=()
	if [ -n "${RCLONE_COMPOSE_MANUAL[$dir]:-}" ]; then
		mapfile -t RCLONE_COMPOSE_ARGS <<< "${RCLONE_COMPOSE_MANUAL[$dir]}"
		return 0
	fi
	ids=$(docker ps -aq 2>/dev/null) || return 1
	if [ -n "$ids" ]; then
		data=$(docker inspect $ids 2>/dev/null) || return 1
		context=$(printf '%s' "$data" | python3 -c '
import json,sys
contexts = set()
for container in json.load(sys.stdin):
    labels = container["Config"].get("Labels") or {}
    if labels.get("com.docker.compose.project.working_dir") == sys.argv[1]:
        contexts.add((labels.get("com.docker.compose.project", ""), labels.get("com.docker.compose.project.config_files", "")))
if len(contexts) > 1:
    sys.exit("Multiple Compose contexts share this directory; select them manually.")
for project, files in contexts:
    if not project or not files or any(ord(c) < 32 or ord(c) == 127 for c in project + files):
        sys.exit(1)
    print(project)
    print(files.replace(",", "\n"))
' "$dir") || return 1
	fi
	if [ -z "$context" ]; then
		data=$(rclone_compose_run "$dir" config --format json 2>/dev/null) || return 1
		context=$(printf '%s' "$data" | python3 -c '
import json, os, re, sys
try:
    data = json.load(sys.stdin)
except (ValueError, TypeError):
    sys.exit(1)
name = data.get("name") or os.path.basename(os.path.realpath(sys.argv[1]))
if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
    sys.exit(1)
print(name)
' "$dir") || return 1
		[ -n "$context" ] || return 0
		RCLONE_COMPOSE_ARGS=(-p "$context")
		return 0
	fi
	local -a lines=()
	mapfile -t lines <<< "$context"
	RCLONE_COMPOSE_ARGS=(-p "${lines[0]}")
	for line in "${lines[@]:1}"; do
		[ -f "$line" ] || { echo "Compose 配置缺失: $line"; return 1; }
		RCLONE_COMPOSE_ARGS+=(-f "$line")
	done
}

rclone_compose_add_project() {
	local dir file project args=()
	read -r -e -p "额外项目或重设上下文的绝对目录（回车跳过）: " dir || return 0
	[ -n "$dir" ] || return 0
	[ -d "$dir" ] && [ "$dir" != / ] && [ "$(realpath -e -- "$dir")" = "$dir" ] && [[ "$dir" != *[[:cntrl:]]* ]] || return 1
	while true; do
		read -r -e -p "Compose 配置路径（按 -f 顺序逐个输入，回车结束，空列表用默认发现）: " file || return 1
		[ -n "$file" ] || break
		[[ "$file" = /* ]] || file="$dir/$file"
		[ -f "$file" ] && [[ "$file" != *[[:cntrl:]]* ]] || return 1
		args+=(-f "$file")
	done
	read -r -e -p "额外环境文件路径（回车用 .env）: " file || return 1
	if [ -n "$file" ]; then
		[[ "$file" = /* ]] || file="$dir/$file"
		[ -f "$file" ] && [[ "$file" != *[[:cntrl:]]* ]] || return 1
		args+=(--env-file "$file")
	fi
	read -r -p "Compose 项目名（回车用 name:/默认名称）: " project || return 1
	if [ -n "$project" ]; then
		[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
		args+=(-p "$project")
	fi
	RCLONE_COMPOSE_ARGS=("${args[@]}")
	rclone_compose_run "$dir" config --quiet >/dev/null 2>&1 || { echo "配置/环境文件无效；未启动服务。"; return 1; }
	declare -p RCLONE_COMPOSE_MANUAL >/dev/null 2>&1 || declare -gA RCLONE_COMPOSE_MANUAL=()
	if [ "${#args[@]}" -gt 0 ]; then RCLONE_COMPOSE_MANUAL["$dir"]=$(printf '%s\n' "${args[@]}"); fi
	RCLONE_COMPOSE_ADDITIONAL="$dir"
}

rclone_compose_run() (
	local dir="$1"
	shift
	cd -- "$dir" || return 1
	docker compose "${RCLONE_COMPOSE_ARGS[@]}" "$@"
)

rclone_compose_status() (
	umask 077
	local dir="$1" work
	work=$(mktemp -d) || return 2
	trap 'rm -rf -- "$work"' EXIT
	rclone_compose_run "$dir" config --format json > "$work/config" 2>/dev/null &&
		rclone_compose_run "$dir" config --services > "$work/services" 2>/dev/null &&
		rclone_compose_run "$dir" ps -a --format json > "$work/ps" 2>/dev/null || return 2
	python3 - "$work" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1])
try:
    config = json.loads((work / "config").read_text())
    active = (work / "services").read_text().splitlines()
    raw = (work / "ps").read_text().strip()
    containers = json.loads(raw) if raw.startswith("[") else [json.loads(line) for line in raw.splitlines()]
    if not active:
        sys.exit(2)
    jobs = {name for service in config["services"].values() for name, dependency in service.get("depends_on", {}).items() if isinstance(dependency, dict) and dependency.get("condition") == "service_completed_successfully"}
    missing = False
    for name in active:
        service = config["services"][name]
        count = service.get("scale", service.get("deploy", {}).get("replicas", 1))
        rows = [c for c in containers if c.get("Service") == name]
        if len(rows) < count:
            missing = True
        for row in rows:
            if name in jobs and row.get("State") == "exited" and row.get("ExitCode") == 0:
                continue
            if row.get("Health") == "unhealthy" or row.get("State") in ("dead", "restarting"):
                sys.exit(3)
            if row.get("State") != "running" or row.get("Health") not in ("", None, "healthy"):
                missing = True
    sys.exit(1 if missing else 0)
except (ValueError, KeyError, TypeError):
    sys.exit(2)
PY
)

rclone_compose_preflight() (
	umask 077
	set -o pipefail
	local dir="$1" phase="${2:-before}" work ids name ip port pid subnet status failed=0 confirm
	work=$(mktemp -d) || return 1
	trap 'rm -rf -- "$work"' EXIT
	rclone_compose_run "$dir" config --format json > "$work/config" 2>/dev/null &&
		rclone_compose_run "$dir" config --services > "$work/services" 2>/dev/null || { echo "Compose 配置或环境文件解析失败。"; return 1; }
	ids=$(docker ps -aq 2>/dev/null) || return 1
	if [ -n "$ids" ]; then docker inspect $ids > "$work/containers" 2>/dev/null || return 1; else echo '[]' > "$work/containers"; fi
	ids=$(docker volume ls -q 2>/dev/null) || return 1
	if [ -n "$ids" ]; then docker volume inspect $ids > "$work/volumes" 2>/dev/null || return 1; else echo '[]' > "$work/volumes"; fi
	ids=$(docker network ls -q 2>/dev/null) || return 1
	if [ -n "$ids" ]; then docker network inspect $ids > "$work/networks" 2>/dev/null || return 1; else echo '[]' > "$work/networks"; fi
	if ! timeout 30s python3 - "$work" <<'PY'
import ipaddress, json, os, re, socket, sys
from pathlib import Path
from urllib.parse import urlsplit
work = Path(sys.argv[1])
config = json.loads((work / "config").read_text())
containers = json.loads((work / "containers").read_text())
volumes = {v["Name"]: v for v in json.loads((work / "volumes").read_text())}
networks = {n["Name"]: n for n in json.loads((work / "networks").read_text())}
active = (work / "services").read_text().splitlines()
errors, proxies, rules = [], [], set()
project = config["name"]
for name in active:
    service = config["services"][name]
    current = [c for c in containers if (c["Config"].get("Labels") or {}).get("com.docker.compose.project") == project and (c["Config"].get("Labels") or {}).get("com.docker.compose.service") == name and c["State"]["Running"]]
    for mount in service.get("volumes", []):
        source = mount.get("source")
        if mount["type"] == "bind":
            if not source or not Path(source).exists():
                errors.append(name + ": bind source missing: " + str(source))
            elif source not in ("/etc/localtime", "/etc/timezone", "/var/run/docker.sock"):
                print(name + ": bind " + source + "; verify original data and UID/GID before startup")
        elif mount["type"] == "volume":
            volume = config.get("volumes", {}).get(source, {}).get("name", project + "_" + str(source))
            if not source or volume not in volumes:
                errors.append(name + ": volume missing or anonymous; restore data before startup: " + volume)
            else:
                print(name + ": named volume " + volume + " is outside /root restore coverage")
                point = volumes[volume].get("Mountpoint")
                if not current and volumes[volume].get("Driver") == "local" and not volumes[volume].get("Options"):
                    if not point or not Path(point).is_dir() or not any(Path(point).iterdir()):
                        errors.append(name + ": local volume is empty or unavailable; restore data or explicitly initialize it first: " + volume)
    if service.get("restart", "no") not in ("always", "unless-stopped"):
        print(name + ": restart=" + service.get("restart", "no") + "; not guaranteed to start after reboot")
    hosts = service.get("extra_hosts", {})
    if isinstance(hosts, list):
        hosts = dict(re.split(r"[=:]", value, maxsplit=1) for value in hosts)
    for key, value in service.get("environment", {}).items():
        if key.lower() not in ("http_proxy", "https_proxy", "all_proxy") or not value:
            continue
        try:
            url = urlsplit(value)
            host, port = url.hostname, url.port or (1080 if url.scheme.startswith("socks") else 443 if url.scheme == "https" else 80)
            if url.scheme not in ("http", "https", "socks5", "socks5h", "socks4") or not host or not 1 <= port <= 65535:
                raise ValueError()
            host_ip = ipaddress.ip_address(host) if re.fullmatch(r"[0-9.]+|[0-9a-fA-F:]+", host) else None
            if service.get("network_mode") != "host" and (host in ("localhost", "::1") or (host_ip and host_ip.is_loopback)):
                errors.append(name + ": " + key + " points to container loopback, not the host")
                continue
            for container in current or [None]:
                address = hosts.get(host, host)
                if host == "host.docker.internal" and host not in hosts and not container:
                    errors.append(name + ": missing extra_hosts mapping for host.docker.internal")
                    continue
                if container:
                    hosts_file = Path(container.get("HostsPath", "/nonexistent"))
                    if hosts_file.is_file():
                        for line in hosts_file.read_text().splitlines():
                            fields = line.split("#", 1)[0].split()
                            if host in fields[1:]:
                                address = fields[0]
                if address == "host-gateway":
                    daemon = Path("/etc/docker/daemon.json")
                    settings = json.loads(daemon.read_text()) if daemon.is_file() else {}
                    gateways = settings.get("host-gateway-ips", [settings.get("host-gateway-ip")])
                    address = (gateways[0] if gateways else None) or next((c["Gateway"] for c in (networks.get("bridge", {}).get("IPAM", {}).get("Config") or []) if c.get("Gateway")), None)
                if address in config["services"]:
                    peers = [c for c in containers if (c["Config"].get("Labels") or {}).get("com.docker.compose.project") == project and (c["Config"].get("Labels") or {}).get("com.docker.compose.service") == address and c["State"]["Running"]]
                    shared = set(container["NetworkSettings"]["Networks"]) if container else set(networks)
                    address = next((n["IPAddress"] for c in peers for k,n in c["NetworkSettings"]["Networks"].items() if k in shared and n.get("IPAddress")), None)
                if not address:
                    print(name + ": proxy target requires validation after startup")
                    continue
                address = socket.getaddrinfo(address, port, type=socket.SOCK_STREAM)[0][4][0]
                ipaddress.ip_address(address)
                pid = container["State"]["Pid"] if container else 0
                proxies.append((name, address, port, pid))
                gateways = {c.get("Gateway") for n in networks.values() for c in (n.get("IPAM") or {}).get("Config") or []}
                if container and address in gateways:
                    for network in container["NetworkSettings"]["Networks"]:
                        for entry in networks.get(network, {}).get("IPAM", {}).get("Config", []):
                            subnet = entry.get("Subnet")
                            if subnet and ipaddress.ip_network(subnet).version == 4:
                                rules.add((subnet, port))
        except (ValueError, OSError, TypeError):
            errors.append(name + ": " + key + " endpoint could not be validated (credentials hidden)")
with (work / "proxies").open("w") as output:
    for row in sorted(set(proxies)):
        output.write("\t".join(map(str, row)) + "\n")
with (work / "rules").open("w") as output:
    for row in sorted(rules):
        output.write("\t".join(map(str, row)) + "\n")
for error in errors:
    print("ERROR " + error)
sys.exit(bool(errors))
PY
	then return 1; fi
	while IFS=$'\t' read -r name ip port pid; do
		[ -n "$name" ] || continue
		if [ "$pid" -gt 0 ]; then
			daimon_require_cmd nsenter || { echo "缺少 nsenter，无法验证容器网络。"; failed=1; continue; }
			if ! nsenter -t "$pid" -n -- timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$ip" "$port" 2>/dev/null; then
				echo "$name: 容器无法连接代理 $ip:$port；检查监听、网关及 UFW。"
				failed=1
			else
				echo "$name: 容器到代理 $ip:$port TCP 可达（未验证代理外网请求）。"
			fi
		else
			echo "$name: 代理 $ip:$port，待容器启动后验证。"
		fi
	done < "$work/proxies"
	if [ "$failed" = 1 ] && [ "$phase" != verify ] && [ -s "$work/rules" ] && command -v ufw >/dev/null 2>&1; then
		status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
		if [[ "$status" = *'Status: active'* ]]; then
			while IFS=$'\t' read -r subnet port; do echo "ufw allow from $subnet to any port $port proto tcp"; done < "$work/rules"
			read -r -p "是否添加以上 Docker 网段到必要宿主机端口的规则？(y/N): " confirm || return 1
			if [ "$confirm" = y ] || [ "$confirm" = Y ]; then
				while IFS=$'\t' read -r subnet port; do ufw allow from "$subnet" to any port "$port" proto tcp || return 1; done < "$work/rules"
				rclone_compose_preflight "$dir" verify
				return $?
			fi
		fi
	fi
	[ "$failed" = 0 ]
)

rclone_compose_volume_names() (
	set -o pipefail
	local dir="$1"
	rclone_compose_run "$dir" config --format json 2>/dev/null | python3 -c '
import json, re, sys
try:
    config = json.load(sys.stdin)
except (ValueError, TypeError):
    sys.exit(1)
project = config.get("name") or ""
for service in (config.get("services") or {}).values():
    for mount in service.get("volumes") or []:
        if mount.get("type") != "volume" or not mount.get("source"):
            continue
        source = mount["source"]
        declared = (config.get("volumes") or {}).get(source) or {}
        name = declared.get("name") or (project + "_" + source if project else source)
        if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
            print(name)
' | sort -u
)

rclone_compose_volume_report() {
	local dir="$1" volume mount names
	names=$(rclone_compose_volume_names "$dir") || return 1
	while IFS= read -r volume; do
		[ -n "$volume" ] || continue
		if mount=$(docker volume inspect --format '{{.Mountpoint}}' "$volume" 2>/dev/null); then
			echo "  named volume: $volume [$mount] 已存在（不会由 /root 目录恢复自动填充）"
		else
			echo "  named volume: $volume [缺失，启动前必须单独恢复或确认为空卷]"
		fi
	done <<< "$names"
}

rclone_restore_docker_compose_projects() {
	root_use
	rclone_compose_prepare || return 1

	local project_dir confirm found=0 directories
	local start_dirs=()
	local success_dirs=()
	local skipped_dirs=()
	local failed_dirs=()
	local check_failed_dirs=()

	rclone_show_compose_restore_group() {
		local title="$1"
		shift
		echo -e "${gl_kjlan}${title}:${gl_bai}"
		if [ "$#" -eq 0 ]; then
			echo "  无"
			return
		fi
		printf '  %s\n' "$@"
	}

	directories=$(rclone_compose_directories) || return 1
	RCLONE_COMPOSE_ADDITIONAL=""
	rclone_compose_add_project || return 1
	if [ -n "$RCLONE_COMPOSE_ADDITIONAL" ]; then
		directories=$(printf '%s\n%s\n' "$directories" "$RCLONE_COMPOSE_ADDITIONAL" | sed '/^$/d' | sort -u)
	fi
	while IFS= read -r project_dir; do
		[ -n "$project_dir" ] || continue
		found=1
		if ! rclone_compose_context "$project_dir" || ! rclone_compose_preflight "$project_dir" before; then
			check_failed_dirs+=("$project_dir")
			rclone_restore_record compose "$project_dir" failed "preflight failed" || return 1
			continue
		fi
		echo "项目：$project_dir；Compose 参数：${RCLONE_COMPOSE_ARGS[*]:-默认发现（含 .env 和默认 override）}"
		rclone_compose_volume_report "$project_dir" || return 1
		if rclone_compose_status "$project_dir"; then
			skipped_dirs+=("$project_dir")
			rclone_restore_record compose "$project_dir" running "runtime/healthcheck only; business not verified" || return 1
		else
			case "$?" in
				1) start_dirs+=("$project_dir"); rclone_restore_record compose "$project_dir" pending "awaiting startup confirmation" || return 1 ;;
				*) check_failed_dirs+=("$project_dir"); rclone_restore_record compose "$project_dir" failed "status query/health failed" || return 1 ;;
			esac
		fi
	done <<< "$directories"

	if [ "$found" -eq 0 ]; then
		echo "未发现受限扫描范围内的 Compose 项目。"
		return 0
	fi

	echo -e "${gl_kjlan}------------------------${gl_bai}"
	rclone_show_compose_restore_group "将要启动" "${start_dirs[@]}"
	rclone_show_compose_restore_group "已完整运行，跳过" "${skipped_dirs[@]}"
	rclone_show_compose_restore_group "检测失败" "${check_failed_dirs[@]}"
	echo -e "${gl_kjlan}------------------------${gl_bai}"

	if [ "${#start_dirs[@]}" -eq 0 ]; then
		if [ "${#check_failed_dirs[@]}" -eq 0 ]; then
			echo -e "${gl_lv}没有需要启动的 Docker Compose 项目。${gl_bai}"
			return 0
		fi
		echo -e "${gl_hong}存在检测失败的 Docker Compose 项目，请先检查配置。${gl_bai}"
		return 1
	fi

	read -e -p "确认启动以上 ${#start_dirs[@]} 个 Docker Compose 项目？(y/N): " confirm || return 1
	[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "已取消"; return 0; }

	for project_dir in "${start_dirs[@]}"; do
		echo -e "${gl_kjlan}正在启动: $project_dir${gl_bai}"
		if rclone_compose_context "$project_dir" && rclone_compose_preflight "$project_dir" before &&
			rclone_compose_run "$project_dir" up -d --no-recreate --no-build --pull missing --wait --wait-timeout 120 &&
			rclone_compose_status "$project_dir" && rclone_compose_preflight "$project_dir" after; then
			success_dirs+=("$project_dir")
			rclone_restore_record compose "$project_dir" running "runtime/healthcheck only; business not verified" || return 1
		else
			failed_dirs+=("$project_dir")
			rclone_restore_record compose "$project_dir" failed "startup or post-start check failed" || return 1
		fi
	done

	echo -e "${gl_kjlan}------------------------${gl_bai}"
	rclone_show_compose_restore_group "启动成功" "${success_dirs[@]}"
	rclone_show_compose_restore_group "已完整运行，跳过" "${skipped_dirs[@]}"
	rclone_show_compose_restore_group "启动失败" "${failed_dirs[@]}"
	rclone_show_compose_restore_group "检测失败" "${check_failed_dirs[@]}"
	echo "未修改业务 YAML、Mihomo 或 DNS；无 healthcheck 的服务仅确认容器运行，登录和接口仍需验证。"
	echo "目录恢复不会安装系统 cron；请在 Docker 自动更新管理中核对脚本和定时任务。"
	echo -e "${gl_kjlan}------------------------${gl_bai}"
	[ "${#failed_dirs[@]}" -eq 0 ] && [ "${#check_failed_dirs[@]}" -eq 0 ]
}

rclone_manager() {
	local remote_status status
	remote_status=$(rclone_load_remote_status 2>/dev/null) || true
	while true; do
		clear
		echo -e "rclone 配置"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo -e "当前版本: ${gl_huang}$(rclone_status_text)${gl_bai}"
		echo -e "配置文件: ${gl_kjlan}$(rclone_config_path)${gl_bai}"
		printf '%s\n' "$remote_status"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		echo -e "${gl_kjlan}1.   ${gl_bai}安装 rclone（自动创建配置文件并设置权限）"
		echo -e "${gl_kjlan}2.   ${gl_bai}修改配置文件"
		echo -e "${gl_kjlan}3.   ${gl_bai}卸载 rclone"
		echo -e "${gl_kjlan}4.   ${gl_bai}恢复远程文件夹到 /root"
		echo -e "${gl_kjlan}5.   ${gl_bai}从远程恢复 Nginx + 域名"
		echo -e "${gl_kjlan}6.   ${gl_bai}Docker Compose 恢复"
		echo -e "${gl_kjlan}7.   ${gl_bai}自动同步记录"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case $sub_choice in
			1) rclone_install_tool ;;
			2) rclone_edit_config ;;
			3) rclone_uninstall_tool ;;
			4) rclone_restore_remote_folder ;;
			5) rclone_restore_nginx_domain_remote ;;
			6) rclone_restore_docker_compose_projects ;;
			7) crontab_sync_log_manager ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		status=$?
		[[ "$sub_choice" =~ ^[1-6]$ ]] && remote_status=$(rclone_load_remote_status 2>/dev/null)
		(exit "$status")
		break_end
	done
}
