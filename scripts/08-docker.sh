#!/bin/bash

docker_config_require_tool() {
	daimon_require_cmd "$1" || { echo "未修改 Docker 配置。" >&2; return 1; }
}

docker_daemon_json_merge() (
	local filter="$1" file="/etc/docker/daemon.json" work="" original="" state="" written=0 done=0 fingerprint=""
	shift
	[ "$(id -u)" -eq 0 ] || return 1
	docker_config_require_tool jq || return 1
	command -v dockerd >/dev/null 2>&1 || { echo "未检测到 Docker 引擎（dockerd），请先在 Docker 管理中安装 Docker；未修改配置。" >&2; return 1; }
	docker_config_require_tool flock || return 1
	[ ! -L /etc/docker ] && [ "$(realpath -m /etc/docker)" = /etc/docker ] || return 1
	mkdir -p /etc/docker || return 1
	[ "$(stat -c %u /etc/docker)" = 0 ] && (( (8#$(stat -c %a /etc/docker) & 8#022) == 0 )) || return 1
	[ ! -L /run/lock/daimon-docker-config.lock ] || return 1
	exec 9>/run/lock/daimon-docker-config.lock || return 1
	flock -n 9 || { echo "Docker 配置正在修改，请稍后重试。"; return 1; }
	if [ -e "$file" ] || [ -L "$file" ]; then
		[ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -c %u:%h "$file")" = 0:1 ] || return 1
		(( (8#$(stat -c %a "$file") & 8#022) == 0 )) || return 1
		[ "$filter" = __edit__ ] || jq -se 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1 || { echo "现有 Docker 配置无效，未修改。"; return 1; }
		original=$(sha256sum "$file") || return 1
	fi
	state=$(systemctl show -p ActiveState --value docker) || return 1
	case "$state" in active|inactive|failed) ;; *) echo "Docker 服务状态不稳定，未修改。"; return 1 ;; esac
	work=$(mktemp -d /etc/docker/.daimon-config.XXXXXX) || return 1
	docker_config_finish() {
		local rc=$?
		trap - EXIT INT TERM HUP
		if [ "$written" = 1 ] && [ "$done" = 0 ]; then
			if [ "$(sha256sum "$file" 2>/dev/null)" = "$fingerprint" ]; then
				if [ -n "$original" ]; then
					mv -f -- "$work/original" "$file" || rc=1
				else
					rm -f -- "$file" || rc=1
				fi
				if [ "$state" = active ]; then
					systemctl restart docker && systemctl is-active --quiet docker || { echo "Docker 原配置已恢复，但服务恢复失败，请检查。" >&2; rc=1; }
				fi
			else
				echo "Docker 配置已被其他进程修改，未覆盖；请人工检查。" >&2
				rc=1
			fi
		fi
		rm -f -- "$work/original" "$work/next" || rc=1
		rmdir -- "$work" || rc=1
		exit "$rc"
	}
	trap docker_config_finish EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	if [ -n "$original" ]; then
		cp -p -- "$file" "$work/original" || return 1
	fi
	if [ "$filter" = __edit__ ]; then
		docker_config_require_tool vim || return 1
		if [ -n "$original" ]; then cp -p -- "$file" "$work/next"; else printf '{}\n' > "$work/next"; fi || return 1
		vim "$work/next" || return 1
	elif [ -n "$original" ]; then
		jq "$@" "$filter" "$file" > "$work/next" || return 1
	else
		jq -n "$@" "$filter" > "$work/next" || return 1
	fi
	[ -f "$work/next" ] && [ ! -L "$work/next" ] || return 1
	if [ -n "$original" ]; then
		chmod --reference="$work/original" "$work/next" && chown --reference="$work/original" "$work/next" || return 1
	else
		chmod 600 "$work/next" || return 1
	fi
	jq -se 'length == 1 and (.[0] | type == "object")' "$work/next" >/dev/null 2>&1 || { echo "Docker 配置不是有效 JSON 对象，未修改。"; return 1; }
	dockerd --validate --config-file "$work/next" >/dev/null || { echo "Docker 配置验证失败，未修改。" >&2; return 1; }
	if [ -n "$original" ] && [ "$(jq -cS . "$work/original" 2>/dev/null)" = "$(jq -cS . "$work/next")" ]; then
		echo "Docker 配置未变化。"; return 0
	fi
	[ "$(sha256sum "$file" 2>/dev/null)" = "$original" ] && [ ! -L "$file" ] || { echo "Docker 配置已变化，已取消。"; return 1; }
	fingerprint="$(sha256sum "$work/next" | cut -d' ' -f1)  $file"
	written=1
	mv -f -- "$work/next" "$file" || { written=0; return 1; }
	if [ "$state" = active ]; then
		systemctl restart docker && systemctl is-active --quiet docker || return 1
	fi
	done=1
	echo "Docker 配置已验证并更新；未启动原先停止的服务。"
)

docker_mirror_menu() {
	local selected idx mirrors_json
	local mirrors=("https://hub.333186.xyz" "https://docker.m.daocloud.io" "https://docker.1ms.run" "https://docker.registry.cyou")
	local selected_mirrors=()
	clear
	echo "Docker 镜像源多选"
	echo "------------------------"
	for idx in "${!mirrors[@]}"; do printf '%2d. %s\n' "$((idx+1))" "${mirrors[$idx]}"; done
	echo "直接回车使用默认源 1 2 3 4；输入 0 返回上一级菜单"
	read -e -p "请选择: " selected || return 1
	[ "$selected" = 0 ] && return 90
	selected=${selected:-"1 2 3 4"}
	for idx in $selected; do
		[[ "$idx" =~ ^[1-4]$ ]] || { echo "无效编号，未修改: $idx"; return 1; }
		[[ " ${selected_mirrors[*]} " = *" ${mirrors[$((idx-1))]} "* ]] || selected_mirrors+=("${mirrors[$((idx-1))]}")
	done
	[ "${#selected_mirrors[@]}" -gt 0 ] || return 1
	docker_config_require_tool jq || return 1
	mirrors_json=$(printf '%s\n' "${selected_mirrors[@]}" | jq -R . | jq -s -c .) || return 1
	docker_daemon_json_merge '."registry-mirrors" = $mirrors' --argjson mirrors "$mirrors_json"
}

docker_mirror_default_urls() {
	printf '%s\n' \
		"https://hub.333186.xyz" \
		"https://docker.m.daocloud.io" \
		"https://docker.1ms.run" \
		"https://docker.registry.cyou"
}

docker_mirror_normalize_host() {
	local s="$1"
	s="${s#http://}"
	s="${s#https://}"
	s="${s%%/*}"
	echo "$s"
}

docker_mirror_scheme_url() {
	local s="$1"
	if [[ "$s" =~ ^https?:// ]]; then
		echo "${s%/}"
	else
		echo "https://${s%/}"
	fi
}

docker_mirror_size_mb() {
	awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 / 1024 }'
}

docker_mirror_cleanup_test_image() {
	local ref="$1" expected="${2:-}" current users
	[ -n "$expected" ] || return 1
	current=$(docker image inspect -f '{{.Id}}' "$ref") || return 1
	[ "$current" = "$expected" ] || { echo "镜像引用已变化，保留: $ref"; return 0; }
	users=$(docker ps -aq --filter "ancestor=$expected") || return 1
	[ -z "$users" ] || { echo "镜像已被容器使用，保留: $ref"; return 0; }
	docker image rm "$ref" >/dev/null || { echo "测速镜像清理失败，已保留: $ref"; return 1; }
}

docker_mirror_ask_official() {
	local answer
	read -e -p "是否加入官方镜像源 registry-1.docker.io？(y/N): " answer || return 1
	case "$answer" in
		[Yy]) return 0 ;;
		*) return 1 ;;
	esac
}

docker_mirror_speed_run() {
	local timeout_sec="$1"
	local rounds="$2"
	shift 2
	local mirrors=("$@")
	local image="${IMAGE:-library/python:3.12-slim}"
	local platform="${PLATFORM:-}"
	local pull_args=()
	local round mirror base_url host ref start_ms end_ms status size_bytes rc pull_time mb initial image_id port prior_ids
	local failed=0 measured=0
	[[ "$timeout_sec" =~ ^[0-9]{1,4}$ && "$rounds" =~ ^[0-9]{1,2}$ ]] &&
		(( 10#$timeout_sec >= 1 && 10#$timeout_sec <= 3600 && 10#$rounds >= 1 && 10#$rounds <= 20 )) || {
		echo "超时需为 1–3600 秒，轮数需为 1–20。"; return 1
	}
	timeout_sec=$((10#$timeout_sec)); rounds=$((10#$rounds))
	[[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || return 1
	for mirror in "${mirrors[@]}"; do
		base_url=$(docker_mirror_scheme_url "$mirror"); host=$(docker_mirror_normalize_host "$mirror")
		[[ "$base_url" = "https://$host" || "$base_url" = "http://$host" ]] &&
			[[ "$host" =~ ^(\[[0-9a-fA-F:]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?$ ]] || { echo "镜像源地址无效: $mirror"; return 1; }
		port=${host##*]}; [[ "$host" = \[* ]] || port="$host"
		if [[ "$port" = *:* ]]; then
			port=${port##*:}
			[[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 1
		fi
	done

	if ! command -v docker >/dev/null 2>&1; then
		echo -e "${gl_hong}未检测到 docker，请先安装并启动 Docker。${gl_bai}"
		return 1
	fi
	if ! command -v timeout >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
		echo -e "${gl_hong}缺少 timeout 或 awk 命令。${gl_bai}"
		return 1
	fi
	if [ ${#mirrors[@]} -eq 0 ]; then
		echo -e "${gl_huang}没有可测速的镜像源。${gl_bai}"
		return 1
	fi
	[ -n "$platform" ] && pull_args+=(--platform "$platform")
	timeout 10s docker info >/dev/null 2>&1 || { echo "Docker 服务不可用，未测速。"; return 1; }

	echo "image=$image timeout=${timeout_sec}s rounds=$rounds"
	echo "已有镜像引用跳过；仅非强制清理本轮新增且未使用的引用，不执行全局 prune。"
	echo "结果为拉取耗时及镜像逻辑大小，不是网络带宽；共享缓存和失败拉取留下的层可能影响耗时。"
	echo "------------------------"
	for round in $(seq 1 "$rounds"); do
		for mirror in "${mirrors[@]}"; do
			base_url="$(docker_mirror_scheme_url "$mirror")"
			host="$(docker_mirror_normalize_host "$mirror")"
			ref="${host}/${image}"
			echo "round=${round} mirror=${base_url}"
			if initial=$(docker image inspect -f '{{.Id}}' "$ref" 2>&1 >/dev/null); then
				echo "SKIP(existing) $ref"; continue
			fi
			if [[ "$initial" != "Error response from daemon: No such image: $ref" && "$initial" != "Error: No such image: $ref" ]]; then
				echo "无法确认镜像是否存在，跳过: $ref"; failed=1; continue
			fi
			prior_ids=$(docker image ls -aq --no-trunc) || { echo "无法读取已有镜像清单，未拉取。"; failed=1; continue; }
			start_ms="$(date +%s%3N)"
			if timeout "${timeout_sec}s" docker pull "${pull_args[@]}" "$ref" >/dev/null 2>&1; then
				end_ms="$(date +%s%3N)"
				status="OK"
				image_id=$(docker image inspect -f '{{.Id}}' "$ref") &&
					size_bytes=$(docker image inspect -f '{{.Size}}' "$ref") && [[ "$size_bytes" =~ ^[0-9]+$ ]] || {
					echo "镜像读取失败，保留现场: $ref"; failed=1; continue
				}
				measured=$((measured + 1))
				if [[ $'\n'"$prior_ids"$'\n' = *$'\n'"$image_id"$'\n'* ]]; then
					echo "镜像数据原已存在，为避免删除原镜像，保留新增引用: $ref"
				else
					docker_mirror_cleanup_test_image "$ref" "$image_id" || failed=1
				fi
			else
				rc=$?
				end_ms="$(date +%s%3N)"
				if [ "$rc" -eq 124 ]; then
					status="FAIL(timeout ${timeout_sec}s)"
				else
					status="FAIL"
				fi
				size_bytes=0
				failed=1
			fi
			pull_time="$(awk -v s="$start_ms" -v e="$end_ms" 'BEGIN { printf "%.3f", (e - s) / 1000 }')"
			mb="$(docker_mirror_size_mb "$size_bytes")"
			echo "${status} pull=${pull_time}s logical-size=${mb}MiB"
			echo
		done
	done
	[ "$measured" -gt 0 ] || echo "没有完成有效拉取测量。"
	return "$failed"
}

docker_mirror_collect_defaults() {
	local selected="$1"
	local add_official="$2"
	local default_mirrors=()
	local mirrors=()
	local idx
	mapfile -t default_mirrors < <(docker_mirror_default_urls)
	selected=${selected:-"1 2 3 4"}
	for idx in $selected; do
		if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt ${#default_mirrors[@]} ]; then
			echo -e "${gl_huang}跳过无效编号: $idx${gl_bai}" >&2
			continue
		fi
		mirrors+=("${default_mirrors[$((idx-1))]}")
	done
	[ "$add_official" = "yes" ] && mirrors+=("https://registry-1.docker.io")
	printf '%s\n' "${mirrors[@]}"
}

docker_mirror_speed_test_menu() {
	local default_mirrors=()
	mapfile -t default_mirrors < <(docker_mirror_default_urls)
	while true; do
		clear
		echo "Docker镜像源测速"
		echo "------------------------"
		echo "默认镜像源："
		for i in "${!default_mirrors[@]}"; do
			printf "%2d. %s\n" "$((i+1))" "${default_mirrors[$i]}"
		done
		echo "官方镜像源: https://registry-1.docker.io"
		echo "------------------------"
		echo "1. 测速默认镜像源"
		echo "2. 测速第三方镜像源"
		echo "3. 测速第三方镜像源 + 默认镜像源"
		echo "0. 返回上一级菜单"
		echo "------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case "$choice" in
			1)
				local selected timeout_sec rounds add_official mirrors=()
				read -e -i "1 2 3 4" -p "请选择默认镜像源编号（空格分隔）: " selected || return 1
				read -e -i "100" -p "请输入超时时间（秒）: " timeout_sec || return 1
				read -e -i "1" -p "请输入测速轮数: " rounds || return 1
				if docker_mirror_ask_official; then add_official=yes; else add_official=no; fi
				mapfile -t mirrors < <(docker_mirror_collect_defaults "$selected" "$add_official")
				docker_mirror_speed_run "${timeout_sec:-100}" "${rounds:-1}" "${mirrors[@]}"
				break_end
				;;
			2)
				local third timeout_sec rounds mirrors=()
				read -e -p "请输入第三方镜像源地址: " third || return 1
				[ -z "$third" ] && echo "镜像源不能为空" && break_end && continue
				read -e -i "100" -p "请输入超时时间（秒）: " timeout_sec || return 1
				read -e -i "1" -p "请输入测速轮数: " rounds || return 1
				mirrors+=("$(docker_mirror_scheme_url "$third")")
				if docker_mirror_ask_official; then mirrors+=("https://registry-1.docker.io"); fi
				docker_mirror_speed_run "${timeout_sec:-100}" "${rounds:-1}" "${mirrors[@]}"
				break_end
				;;
			3)
				local third selected timeout_sec rounds add_official mirrors=() default_selected=()
				read -e -p "请输入第三方镜像源地址: " third || return 1
				[ -z "$third" ] && echo "镜像源不能为空" && break_end && continue
				read -e -i "1 2 3 4" -p "请选择默认镜像源编号（空格分隔）: " selected || return 1
				read -e -i "100" -p "请输入超时时间（秒）: " timeout_sec || return 1
				read -e -i "1" -p "请输入测速轮数: " rounds || return 1
				mirrors+=("$(docker_mirror_scheme_url "$third")")
				if docker_mirror_ask_official; then add_official=yes; else add_official=no; fi
				mapfile -t default_selected < <(docker_mirror_collect_defaults "$selected" "$add_official")
				mirrors+=("${default_selected[@]}")
				docker_mirror_speed_run "${timeout_sec:-100}" "${rounds:-1}" "${mirrors[@]}"
				break_end
				;;
			0) return ;;
			*) echo "无效的输入!"; break_end ;;
		esac
	done
}

docker_uninstall_environment() {
	root_use
	if command -v docker >/dev/null 2>&1; then
		docker ps -a -q | xargs -r docker rm -f || return 1
		docker images -q | xargs -r docker rmi || true
		docker network prune -f || true
		docker volume prune -f || true
	fi
	remove docker docker-compose docker-ce docker-ce-cli containerd.io || return 1
	rm -f /etc/docker/daemon.json /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources \
		/etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
	rm -rf /etc/docker /var/lib/docker /var/lib/containerd
	if getent group docker >/dev/null 2>&1; then groupdel docker; fi
	hash -r 2>/dev/null || true
}

docker_ps() {
while true; do
	clear
	send_stats "Docker容器管理"
	echo "Docker容器列表"
	docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
	echo ""
	echo "容器操作"
	echo "------------------------"
	echo "1. 创建新的容器"
	echo "------------------------"
	echo "2. 启动指定容器             6. 启动所有容器"
	echo "3. 停止指定容器             7. 停止所有容器"
	echo "4. 删除指定容器             8. 删除所有容器"
	echo "5. 重启指定容器             9. 重启所有容器"
	echo "------------------------"
	echo "11. 进入指定容器           12. 查看容器日志"
	echo "13. 查看容器网络           14. 查看容器占用"
	echo "------------------------"
	echo "15. 开启容器端口访问       16. 关闭容器端口访问"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "请输入你的选择: " sub_choice || return 1
	case $sub_choice in
		1)
			send_stats "新建容器"
			read -e -p "请输入创建命令: " dockername || return 1
			$dockername
			;;
		2)
			send_stats "启动指定容器"
			read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername || return 1
			docker start $dockername
			;;
		3)
			send_stats "停止指定容器"
			read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername || return 1
			docker stop $dockername
			;;
		4)
			send_stats "删除指定容器"
			read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername || return 1
			docker rm -f $dockername
			;;
		5)
			send_stats "重启指定容器"
			read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername || return 1
			docker restart $dockername
			;;
		6)
			send_stats "启动所有容器"
			docker start $(docker ps -a -q)
			;;
		7)
			send_stats "停止所有容器"
			docker stop $(docker ps -q)
			;;
		8)
			send_stats "删除所有容器"
			read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有容器吗？(Y/N): ")" choice || return 1
			case "$choice" in
			  [Yy])
			    docker rm -f $(docker ps -a -q)
			    ;;
			  [Nn])
			    ;;
			  *)
				echo "无效的选择，请输入 Y 或 N。"
				;;
			esac
			;;
		9)
			send_stats "重启所有容器"
			docker restart $(docker ps -q)
			;;
		11)
			send_stats "进入容器"
			read -e -p "请输入容器名: " dockername || return 1
			docker exec -it $dockername /bin/sh
			break_end
			;;
		12)
			send_stats "查看容器日志"
			read -e -p "请输入容器名: " dockername || return 1
			docker logs $dockername
			break_end
			;;
		13)
			send_stats "查看容器网络"
			echo ""
			container_ids=$(docker ps -q)
			echo "------------------------------------------------------------"
			printf "%-25s %-25s %-25s\n" "容器名称" "网络名称" "IP地址"
			for container_id in $container_ids; do
				local container_info=$(docker inspect --format '{{ .Name }}{{ range $network, $config := .NetworkSettings.Networks }} {{ $network }} {{ $config.IPAddress }}{{ end }}' "$container_id")
				local container_name=$(echo "$container_info" | awk '{print $1}')
				local network_info=$(echo "$container_info" | cut -d' ' -f2-)
				while IFS= read -r line; do
					local network_name=$(echo "$line" | awk '{print $1}')
					local ip_address=$(echo "$line" | awk '{print $2}')
					printf "%-20s %-20s %-15s\n" "$container_name" "$network_name" "$ip_address"
				done <<< "$network_info"
			done
			break_end
			;;
		14)
			send_stats "查看容器占用"
			docker stats --no-stream
			break_end
			;;

		15)
			send_stats "允许容器端口访问"
			read -e -p "请输入容器名: " docker_name || return 1
			ip_address
			clear_container_rules "$docker_name" "$ipv4_address"
			local docker_port=$(docker port $docker_name | awk -F'[:]' '/->/ {print $NF}' | uniq)
			check_docker_app_ip
			break_end
			;;

		16)
			send_stats "阻止容器端口访问"
			read -e -p "请输入容器名: " docker_name || return 1
			ip_address
			block_container_port "$docker_name" "$ipv4_address"
			local docker_port=$(docker port $docker_name | awk -F'[:]' '/->/ {print $NF}' | uniq)
			check_docker_app_ip
			break_end
			;;

		0)
			return 90
			;;
		*)
			break  # 跳出循环，退出菜单
			;;
	esac
done
}

docker_image() {
while true; do
	clear
	send_stats "Docker镜像管理"
	echo "Docker镜像列表"
	docker image ls
	echo ""
	echo "镜像操作"
	echo "------------------------"
	echo "1. 获取指定镜像             3. 删除指定镜像"
	echo "2. 更新指定镜像             4. 删除所有镜像"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "请输入你的选择: " sub_choice || return 1
	case $sub_choice in
		1)
			send_stats "拉取镜像"
			read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames || return 1
			for name in $imagenames; do
				echo -e "${gl_kjlan}正在获取镜像: $name${gl_bai}"
				docker pull $name
			done
			;;
		2)
			send_stats "更新镜像"
			read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames || return 1
			for name in $imagenames; do
				echo -e "${gl_kjlan}正在更新镜像: $name${gl_bai}"
				docker pull $name
			done
			;;
		3)
			send_stats "删除镜像"
			read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames || return 1
			for name in $imagenames; do
				docker rmi -f $name
			done
			;;
		4)
			send_stats "删除所有镜像"
			read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有镜像吗？(Y/N): ")" choice || return 1
			case "$choice" in
			  [Yy])
				docker rmi -f $(docker images -q)
				;;
			  [Nn])
				;;
			  *)
				echo "无效的选择，请输入 Y 或 N。"
				;;
			esac
			;;
		0)
			return 90
			;;
		*)
			break  # 跳出循环，退出菜单
			;;
	esac
done


}

docker_ipv6_on() {
	docker_daemon_json_merge '.ipv6 = true | .["fixed-cidr-v6"] //= "fd42:da10:6::/64"'
}

docker_ipv6_off() {
	docker_daemon_json_merge 'del(.["fixed-cidr-v6"]) | .ipv6 = false'
}

save_iptables_rules() {
	mkdir -p /etc/iptables
	touch /etc/iptables/rules.v4
	iptables-save > /etc/iptables/rules.v4
	check_crontab_installed || return 1
	crontab -l | grep -v 'iptables-restore' | crontab - > /dev/null 2>&1
	(crontab -l ; echo '@reboot iptables-restore < /etc/iptables/rules.v4') | crontab - > /dev/null 2>&1

}

check_docker_app_ip() {
echo "------------------------"
echo "访问地址:"
ip_address



if [ -n "$ipv4_address" ]; then
	echo "http://$ipv4_address:${docker_port}"
fi

if [ -n "$ipv6_address" ]; then
	echo "http://[$ipv6_address]:${docker_port}"
fi

local search_pattern1="$ipv4_address:${docker_port}"
local search_pattern2="127.0.0.1:${docker_port}"

for file in /home/web/conf.d/*; do
	if [ -f "$file" ]; then
		if grep -q "$search_pattern1" "$file" 2>/dev/null || grep -q "$search_pattern2" "$file" 2>/dev/null; then
			echo "https://$(basename "$file" | sed 's/\.conf$//')"
		fi
	fi
done


}

block_container_port() {
	local container_name_or_id=$1
	local allowed_ip=$2

	# 获取容器的 IP 地址
	local container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name_or_id")

	if [ -z "$container_ip" ]; then
		return 1
	fi

	install iptables


	# 检查并封禁其他所有 IP
	if ! iptables -C DOCKER-USER -p tcp -d "$container_ip" -j DROP &>/dev/null; then
		iptables -I DOCKER-USER -p tcp -d "$container_ip" -j DROP
	fi

	# 检查并放行指定 IP
	if ! iptables -C DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -I DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
	fi

	# 检查并放行本地网络 127.0.0.0/8
	if ! iptables -C DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -I DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
	fi



	# 检查并封禁其他所有 IP
	if ! iptables -C DOCKER-USER -p udp -d "$container_ip" -j DROP &>/dev/null; then
		iptables -I DOCKER-USER -p udp -d "$container_ip" -j DROP
	fi

	# 检查并放行指定 IP
	if ! iptables -C DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -I DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
	fi

	# 检查并放行本地网络 127.0.0.0/8
	if ! iptables -C DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -I DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
	fi

	if ! iptables -C DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -I DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT
	fi


	echo "已阻止IP+端口访问该服务"
	save_iptables_rules
}

clear_container_rules() {
	local container_name_or_id=$1
	local allowed_ip=$2

	# 获取容器的 IP 地址
	local container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name_or_id")

	if [ -z "$container_ip" ]; then
		return 1
	fi

	install iptables


	# 清除封禁其他所有 IP 的规则
	if iptables -C DOCKER-USER -p tcp -d "$container_ip" -j DROP &>/dev/null; then
		iptables -D DOCKER-USER -p tcp -d "$container_ip" -j DROP
	fi

	# 清除放行指定 IP 的规则
	if iptables -C DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -D DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
	fi

	# 清除放行本地网络 127.0.0.0/8 的规则
	if iptables -C DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -D DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
	fi





	# 清除封禁其他所有 IP 的规则
	if iptables -C DOCKER-USER -p udp -d "$container_ip" -j DROP &>/dev/null; then
		iptables -D DOCKER-USER -p udp -d "$container_ip" -j DROP
	fi

	# 清除放行指定 IP 的规则
	if iptables -C DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -D DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
	fi

	# 清除放行本地网络 127.0.0.0/8 的规则
	if iptables -C DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -D DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
	fi


	if iptables -C DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT &>/dev/null; then
		iptables -D DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT
	fi


	echo "已允许IP+端口访问该服务"
	save_iptables_rules
}

docker_app() {
send_stats "${docker_name}管理"

while true; do
	clear
	check_docker_app
	check_docker_image_update $docker_name
	echo -e "$docker_name $check_docker $update_status"
	echo "$docker_describe"
	echo "$docker_url"
	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$docker_name"; then
		if [ ! -f "/home/docker/${docker_name}_port.conf" ]; then
			local docker_port=$(docker port "$docker_name" | head -n1 | awk -F'[:]' '/->/ {print $NF; exit}')
			docker_port=${docker_port:-0000}
			echo "$docker_port" > "/home/docker/${docker_name}_port.conf"
		fi
		local docker_port=$(cat "/home/docker/${docker_name}_port.conf")
		check_docker_app_ip
	fi
	echo ""
	echo "------------------------"
	echo "1. 安装              2. 更新            3. 卸载"
	echo "------------------------"
	echo "5. 添加域名访问      6. 删除域名访问"
	echo "7. 允许IP+端口访问   8. 阻止IP+端口访问"
	echo "------------------------"
	echo "0. 返回上一级选单"
	echo "------------------------"
	read -e -p "请输入你的选择: " choice || return 1
	 case $choice in
		1)
			setup_docker_dir
			check_disk_space $app_size /home/docker
			while true; do
				read -e -p "输入应用对外服务端口，回车默认使用${docker_port}端口: " app_port || return 1
				local app_port=${app_port:-${docker_port}}

				if ss -tuln | grep -q ":$app_port "; then
					echo -e "${gl_hong}错误: ${gl_bai}端口 $app_port 已被占用，请更换一个端口"
					send_stats "应用端口已被占用"
				else
					local docker_port=$app_port
					break
				fi
			done

			install jq
			install_docker
			docker_rum
			echo "$docker_port" > "/home/docker/${docker_name}_port.conf"

			add_app_id

			clear
			echo "$docker_name 已经安装完成"
			check_docker_app_ip
			echo ""
			$docker_use
			$docker_passwd
			send_stats "安装$docker_name"
			;;
		2)
			docker rm -f "$docker_name"
			docker rmi -f "$docker_img"
			docker_rum

			add_app_id

			clear
			echo "$docker_name 已经安装完成"
			check_docker_app_ip
			echo ""
			$docker_use
			$docker_passwd
			send_stats "更新$docker_name"
			;;
		3)
			docker rm -f "$docker_name"
			docker rmi -f "$docker_img"
			rm -rf "/home/docker/$docker_name"
			rm -f /home/docker/${docker_name}_port.conf

			sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
			echo "应用已卸载"
			send_stats "卸载$docker_name"
			;;

		5)
			echo "${docker_name}域名访问设置"
			send_stats "${docker_name}域名访问设置"
			add_yuming
			ldnmp_Proxy ${yuming} 127.0.0.1 ${docker_port}
			block_container_port "$docker_name" "$ipv4_address"
			;;

		6)
			echo "域名格式 example.com 不带https://"
			web_del
			;;

		7)
			send_stats "允许IP访问 ${docker_name}"
			clear_container_rules "$docker_name" "$ipv4_address"
			;;

		8)
			send_stats "阻止IP访问 ${docker_name}"
			block_container_port "$docker_name" "$ipv4_address"
			;;

		*)
			break
			;;
	 esac
	 break_end
done

}

docker_app_plus() {
	send_stats "$app_name"
	while true; do
		clear
		check_docker_app
		check_docker_image_update $docker_name
		echo -e "$app_name $check_docker $update_status"
		echo "$app_text"
		echo "$app_url"
		if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$docker_name"; then
			if [ ! -f "/home/docker/${docker_name}_port.conf" ]; then
				local docker_port=$(docker port "$docker_name" | head -n1 | awk -F'[:]' '/->/ {print $NF; exit}')
				docker_port=${docker_port:-0000}
				echo "$docker_port" > "/home/docker/${docker_name}_port.conf"
			fi
			local docker_port=$(cat "/home/docker/${docker_name}_port.conf")
			check_docker_app_ip
		fi
		echo ""
		echo "------------------------"
		echo "1. 安装             2. 更新             3. 卸载"
		echo "------------------------"
		echo "5. 添加域名访问     6. 删除域名访问"
		echo "7. 允许IP+端口访问  8. 阻止IP+端口访问"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "输入你的选择: " choice || return 1
		case $choice in
			1)
				setup_docker_dir
				check_disk_space $app_size /home/docker

				while true; do
					read -e -p "输入应用对外服务端口，回车默认使用${docker_port}端口: " app_port || return 1
					local app_port=${app_port:-${docker_port}}

					if ss -tuln | grep -q ":$app_port "; then
						echo -e "${gl_hong}错误: ${gl_bai}端口 $app_port 已被占用，请更换一个端口"
						send_stats "应用端口已被占用"
					else
						local docker_port=$app_port
						break
					fi
				done

				install jq
				install_docker
				docker_app_install
				echo "$docker_port" > "/home/docker/${docker_name}_port.conf"

				add_app_id
				send_stats "$app_name 安装"
				;;

			2)
				docker_app_update
				add_app_id
				send_stats "$app_name 更新"
				;;

			3)
				docker_app_uninstall
				rm -f /home/docker/${docker_name}_port.conf

				sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
				send_stats "$app_name 卸载"
				;;

			5)
				echo "${docker_name}域名访问设置"
				send_stats "${docker_name}域名访问设置"
				add_yuming
				ldnmp_Proxy ${yuming} 127.0.0.1 ${docker_port}
				block_container_port "$docker_name" "$ipv4_address"

				;;
			6)
				echo "域名格式 example.com 不带https://"
				web_del
				;;
			7)
				send_stats "允许IP访问 ${docker_name}"
				clear_container_rules "$docker_name" "$ipv4_address"
				;;
			8)
				send_stats "阻止IP访问 ${docker_name}"
				block_container_port "$docker_name" "$ipv4_address"
				;;
			*)
				break
				;;
		esac
		break_end
	done
}

kj_ssh_validate_host() {
	local host="$1"
	[[ -n "$host" && ! "$host" =~ [[:space:]] && "$host" =~ ^[A-Za-z0-9._:-]+$ ]]
}

kj_ssh_validate_port() {
	local port="$1"
	[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

kj_ssh_validate_user() {
	local user="$1"
	[[ -n "$user" && "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]
}

kj_ssh_read_host_port() {
	local host_prompt="$1"
	local port_prompt="$2"
	local default_port="${3:-22}"

	while true; do
		read -e -p "$host_prompt" KJ_SSH_HOST || return 1
		if kj_ssh_validate_host "$KJ_SSH_HOST"; then
			break
		fi
		echo "错误: 请输入有效的服务器地址。"
	done

	while true; do
		read -e -p "$port_prompt" KJ_SSH_PORT || return 1
		KJ_SSH_PORT=${KJ_SSH_PORT:-$default_port}
		if kj_ssh_validate_port "$KJ_SSH_PORT"; then
			break
		fi
		echo "错误: 端口必须是 1-65535 之间的数字。"
	done
}

kj_ssh_read_host_user_port() {
	local host_prompt="$1"
	local user_prompt="$2"
	local port_prompt="$3"
	local default_user="${4:-root}"
	local default_port="${5:-22}"

	kj_ssh_read_host_port "$host_prompt" "$port_prompt" "$default_port"

	while true; do
		read -e -p "$user_prompt" KJ_SSH_USER || return 1
		KJ_SSH_USER=${KJ_SSH_USER:-$default_user}
		if kj_ssh_validate_user "$KJ_SSH_USER"; then
			break
		fi
		echo "错误: 用户名格式不正确。"
	done
}

docker_migration_program() {
    cat <<'PYDOCKER_BACKUP'
import copy, time, uuid, fcntl, hashlib, http.client, json, os, posixpath, re, shutil, signal, socket, stat, subprocess, sys, tarfile, tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import quote

def require(ok, message):
    if not ok: raise ValueError(message)

def cli(*args):
    context = os.environ.get('DOCKER_CONTEXT')
    command = ['docker', '--context', context] if context else ['docker']
    p = subprocess.run([*command, *args], capture_output=True, timeout=1800)
    require(p.returncode == 0, 'Docker command failed: ' + args[0])
    return p.stdout.decode()

class Engine:
    def __init__(self):
        selected = os.environ.get('DOCKER_CONTEXT')
        endpoint = None if selected else os.environ.get('DOCKER_HOST')
        if not endpoint:
            context = json.loads(cli('context', 'inspect', *([selected] if selected else [])))
            endpoint = context[0]['Endpoints']['docker']['Host']
        require(endpoint.startswith('unix:///'), 'Only a local Unix-socket Docker context is supported')
        self.socket = endpoint[7:]
        self.version = ''
        version = self.api('GET', '/version')
        self.version = '/v' + version['ApiVersion']
        self.platform = version['Os'] + '/' + version['Arch']
        require(version['Os'] == 'linux', 'Linux Docker required')
    def api(self, method, path, data=None, missing=False):
        connection = http.client.HTTPConnection('localhost', timeout=180)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(180)
        sock.connect(self.socket)
        connection.sock = sock
        try:
            body = None if data is None else json.dumps(data).encode()
            connection.request(method, self.version + path, body=body, headers={'Content-Type':'application/json'})
            response = connection.getresponse()
            raw = response.read()
            if missing and response.status == 404: return None
            require(200 <= response.status < 300, 'Docker API failed: ' + method + ' ' + path.split('?')[0] + ' HTTP ' + str(response.status))
            return json.loads(raw) if raw else None
        finally: connection.close()
    def container(self, name, missing=False):
        return self.api('GET', '/containers/' + quote(name, safe='') + '/json', missing=missing)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()

def private(path, directory=False):
    i = path.lstat()
    require(path.is_absolute() and path.resolve() == path and i.st_uid == 0 and not i.st_mode & 0o022, 'Untrusted backup or restore path')
    require(stat.S_ISDIR(i.st_mode) if directory else stat.S_ISREG(i.st_mode) and i.st_nlink == 1, 'Not a regular private backup file/directory')
    return (i.st_dev, i.st_ino, i.st_mode, i.st_size, i.st_mtime_ns)

def empty_target(path):
    private(path, True)
    require(not any(path.iterdir()), 'Restore directory must already exist and be empty')
    for parent in path.parents:
        i = parent.stat()
        require(parent.resolve() == parent and i.st_uid == 0 and (not i.st_mode & 0o022 or i.st_mode & stat.S_ISVTX), 'Untrusted restore parent')
    return private(path, True)

def member_name(name):
    require(name and not name.startswith('/') and '\\' not in name and not any(ord(c)<32 for c in name), 'Unsafe archive path')
    parts = PurePosixPath(name).parts
    require('..' not in parts, 'Archive path traversal')
    return posixpath.normpath(name)

def archive_members(path):
    with tarfile.open(path, 'r:*') as archive:
        members = archive.getmembers()
    seen = {}
    for item in members:
        name = member_name(item.name)
        require(name not in seen, 'Duplicate archive path')
        require(item.isdir() or item.isfile() or item.issym() or item.islnk(), 'Special archive entry rejected')
        require(not item.mode & 0o6000 and not item.sparse, 'Set-ID or sparse archive requires a dedicated backup tool')
        require(0 <= item.uid < 2**32-1 and 0 <= item.gid < 2**32-1, 'Unrepresentable archive ownership')
        require(not any('xattr' in key.lower() or 'acl' in key.lower() for key in item.pax_headers), 'Extended archive metadata requires a dedicated backup tool')
        seen[name] = item
    for name, item in seen.items():
        for parent in PurePosixPath(name).parents:
            prior = seen.get(str(parent))
            require(prior is None or prior.isdir(), 'Archive member has a non-directory parent')
        if item.issym():
            require(item.linkname and not item.linkname.startswith('/') and '\\' not in item.linkname and '..' not in PurePosixPath(item.linkname).parts, 'Absolute or parent-traversing archive symlink')
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), item.linkname))
            require(target != '..' and not target.startswith('../'), 'Escaping archive symlink')
        if item.islnk():
            target = member_name(item.linkname)
            require(target in seen and seen[target].isfile(), 'Invalid archive hardlink')
    return members

def unpack(path, target, volume=False):
    require(target.is_dir() and not any(target.iterdir()), 'Extraction requires an empty directory')
    members = archive_members(path)
    require(all(PurePosixPath(m.name).parts[0] == 'payload' for m in members), 'Data archive has an unexpected root')
    if volume:
        members = copy.deepcopy(members)
        for m in members:
            m.name = m.name.removeprefix('payload').lstrip('/') or '.'
            if m.islnk(): m.linkname = m.linkname.removeprefix('payload').lstrip('/') or '.'
    # All parents and link targets were checked before the first write; links are last.
    ordered = [m for m in members if not(m.issym() or m.islnk())] + [m for m in members if m.issym() or m.islnk()]
    with tarfile.open(path, 'r:*') as archive:
        if hasattr(tarfile, 'fully_trusted_filter'):
            archive.extractall(target, members=ordered, numeric_owner=True, filter='fully_trusted')
        else:
            archive.extractall(target, members=ordered, numeric_owner=True)

def pack(source, destination):
    require(source.is_absolute() and source.resolve() == source, 'Symlink source root is unsupported')
    require(str(source) not in ('/', '/root', '/home', '/etc', '/usr', '/var', '/proc', '/sys', '/dev', '/run', '/tmp'), 'Refusing a whole-system directory')
    require(source.is_dir() or source.is_file(), 'Unsupported mount source')
    def metadata(info):
        relative = PurePosixPath(info.name).relative_to('payload')
        original = source.joinpath(*relative.parts)
        require(not os.listxattr(original, follow_symlinks=False), 'ACL/xattrs require a dedicated backup tool; not silently discarded')
        return info
    with tarfile.open(destination, 'x:gz', compresslevel=1) as archive:
        archive.add(source, arcname='payload', recursive=True, filter=metadata)
    os.chmod(destination, 0o600)
    archive_members(destination)

def supported(item):
    h = item['HostConfig']
    require(not item['State'].get('Paused') and not item['State'].get('Restarting') and not item['State'].get('Dead'), 'Paused/restarting/dead containers are unsupported')
    for key in ('Privileged', 'AutoRemove', 'VolumesFrom', 'Devices', 'DeviceRequests', 'DeviceCgroupRules', 'Links', 'ContainerIDFile', 'CgroupParent'):
        require(not h.get(key), 'Unsupported container setting: ' + key)
    for key in ('PidMode','IpcMode','UTSMode','UsernsMode'):
        require(h.get(key) in ('',None,'private','shareable'), 'Shared namespace setting is unsupported: ' + key)
    require(not str(h.get('NetworkMode','')).startswith('container:'), 'Container-shared networking is unsupported')
    for mount in item.get('Mounts', []):
        require(mount['Type'] in ('bind','volume','tmpfs'), 'Unsupported mount type')
        require(mount['Type'] != 'bind' or not any(mode in mount.get('Mode','').split(',') for mode in ('z','Z')), 'SELinux bind relabel mounts require manual recovery')
        require(mount.get('Propagation','') in ('','rprivate','private'), 'Shared mount propagation is unsupported')
    for mount in h.get('Mounts') or []:
        require(not mount.get('VolumeOptions',{}).get('Subpath') and not mount.get('BindOptions',{}).get('NonRecursive'), 'Advanced mount options require manual recovery')
    labels = item['Config'].get('Labels') or {}
    require(not any(k.startswith('com.docker.swarm.') for k in labels), 'Swarm workloads require Swarm recovery')

def project_context(item):
    labels = item['Config'].get('Labels') or {}
    name = labels.get('com.docker.compose.project')
    if not name: return None
    require(re.fullmatch(r'[a-z0-9][a-z0-9_-]*',name), 'Invalid Compose project name')
    work = Path(labels.get('com.docker.compose.project.working_dir',''))
    files = labels.get('com.docker.compose.project.config_files','').split(',')
    require(work.is_absolute() and work.resolve() == work and files and all(files), 'Missing Compose context')
    files = [str(Path(f) if Path(f).is_absolute() else work/f) for f in files]
    require(all(Path(f).resolve() == Path(f) and work in Path(f).parents for f in files), 'Compose files outside the project directory are unsupported')
    return name, str(work), files

def resources(engine, items):
    volumes, networks, projects, sources = {}, {}, {}, {}
    for item in items:
        supported(item)
        context = project_context(item)
        if context:
            name, work, files = context
            if name in projects: require(projects[name]['work']==work and projects[name]['files']==files, 'Compose project name collision')
            else:
                args=['compose','--project-directory',work,'-p',name]
                for f in files: args+=['-f',f]
                cfg=json.loads(cli(*args,'config','--format','json'))
                for section in ('configs','secrets'):
                    require(not cfg.get(section), 'Compose configs/secrets require a dedicated recovery workflow')
                for service in cfg['services'].values():
                    build=service.get('build') or {}
                    if isinstance(build,str): build={'context':build}
                    if build:
                        context_path=Path(build.get('context',''))
                        require(context_path==Path(work) or Path(work) in context_path.parents, 'Build context outside project is unsupported')
                    require(not service.get('env_file'), 'Unresolved Compose env_file is unsupported')
                projects[name]={'work':work,'files':files,'config':cfg}
                sources[work]={'kind':'project'}
        for mount in item.get('Mounts',[]):
            if mount['Type']=='tmpfs': continue
            source=mount['Source']
            sources.setdefault(source,{'kind':'data'})
            if mount['Type']=='volume':
                name=mount['Name'];v=engine.api('GET','/volumes/'+quote(name,safe=''))
                require(v['Driver']=='local' and not v.get('Options'), 'Only plain local volumes are supported')
                require(v['Mountpoint']==source, 'Volume source mismatch')
                volumes[name]=v
        for name,endpoint in (item.get('NetworkSettings',{}).get('Networks') or {}).items():
            if name in ('bridge','host','none'): continue
            n=engine.api('GET','/networks/'+quote(name,safe=''))
            require(n['Driver']=='bridge' and not n.get('Ingress') and n.get('Scope')=='local' and not (n.get('Options') or {}).get('com.docker.network.bridge.name'), 'Only local bridge networks are supported')
            require(not endpoint.get('Links'), 'Linked endpoints are unsupported')
            networks[name]=n
    services=[]
    for item in items:
        ctx=project_context(item)
        if ctx:
            service=(item['Config'].get('Labels') or {}).get('com.docker.compose.service')
            require(service, 'Compose service label missing')
            services.append((ctx[0],service))
    require(len(services)==len(set(services)), 'Scaled Compose services require a dedicated recovery workflow')
    # Each project is archived as a whole; keep mount snapshots separate for exact container data.
    for index,(source,record) in enumerate(sources.items()):
        record.update({'archive':'data-'+str(index)+'.tar.gz','source':source})
    return volumes,networks,projects,sources

def backup(engine, directory, names):
    require(not directory.exists() and not directory.is_symlink(), 'Backup destination already exists')
    all_items=[engine.container(x['Id']) for x in engine.api('GET','/containers/json?all=1')]
    wanted={x['Id'] for x in all_items if not names and x['State']['Running']}
    for name in names: wanted.add(engine.container(name)['Id'])
    for item in all_items:
        if item['Id'] in wanted:
            ctx=project_context(item)
            if ctx:
                for other in all_items:
                    if project_context(other) and project_context(other)[0]==ctx[0]:wanted.add(other['Id'])
    items=[x for x in all_items if x['Id'] in wanted]
    require(items,'No containers selected')
    volumes,networks,projects,sources=resources(engine,items)
    for item in all_items:
        if item['Id'] in wanted:continue
        for mount in item.get('Mounts',[]):
            if mount.get('Source'):
                a=Path(mount['Source'])
                require(not any(a==Path(s) or a in Path(s).parents or Path(s) in a.parents for s in sources), 'Data is also used by an unselected container')
    hypothetical={source:'/restore/data-'+str(i)+'/payload' for i,source in enumerate(sources)}
    for project in projects.values():canonical_project(project,hypothetical,items)
    directory.mkdir(mode=0o700)
    state={'containers':items,'platform':engine.platform,'volumes':volumes,'networks':networks,'projects':projects,'sources':sources,'version':2}
    (directory/'incomplete.json').write_text(json.dumps(state))
    stopped=[];created_images=[]
    known_images={x['Id'] for x in engine.api('GET','/images/json?all=1')}
    try:
        for item in items:
            require(engine.container(item['Id'])['Config']==item['Config'], 'Container configuration changed')
            if item['State']['Running']:
                stopped.append(item['Id'])
                engine.api('POST','/containers/'+item['Id']+'/stop?t=60')
        for item in items:require(not engine.container(item['Id'])['State']['Running'],'Container did not stop')
        for source,record in sources.items():pack(Path(source),directory/record['archive'])
        for item in items:
            image=engine.api('POST','/commit?container='+item['Id']+'&pause=false')['Id']
            if image not in known_images:created_images.append(image)
            item['Image']=image
        images={x['Image'] for x in items}
        cli('image','save','-o',str(directory/'images.tar'),*sorted(images))
        state['checksums']={p.name:digest(p) for p in directory.iterdir() if p.name!='incomplete.json'}
    finally:
        for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,signal.SIG_IGN)
        failures=[]
        for cid in stopped:
            try:
                current=engine.container(cid)
                if not current['State']['Running']:engine.api('POST','/containers/'+cid+'/start')
                require(engine.container(cid)['State']['Running'],'Backup restart failed')
            except Exception:failures.append(cid)
        for image in created_images:
            try: engine.api('DELETE','/images/'+quote(image,safe='')+'?force=0&noprune=1')
            except Exception: print('Temporary snapshot image retained: '+image,file=sys.stderr)
        require(not failures,'Backup incomplete: some original containers did not restart; inspect incomplete.json')
    for p in directory.iterdir():os.chmod(p,0o600)
    (directory/'manifest.json').write_text(json.dumps(state))
    os.chmod(directory/'manifest.json',0o600)
    (directory/'incomplete.json').unlink()
    print('Backup complete: '+str(directory))

def payload(item, relocated, project_dirs):
    config=copy.deepcopy(item['Config']);host=copy.deepcopy(item['HostConfig'])
    config['Image']=item['Image']
    for name, endpoint in (item.get('NetworkSettings',{}).get('Networks') or {}).items():
        if host.get('NetworkMode') == endpoint.get('NetworkID'): host['NetworkMode']=name
    host['Binds']=None
    host['Mounts']=[m for m in (host.get('Mounts') or []) if m['Type']=='tmpfs']
    for mount in item.get('Mounts',[]):
        kind=mount['Type']
        if kind=='tmpfs':continue
        source=mount['Name'] if kind=='volume' else relocated[mount['Source']]
        new={'Type':kind,'Source':source,'Target':mount['Destination'],'ReadOnly':not mount['RW']}
        if kind=='volume':new['VolumeOptions']={'NoCopy':True}
        elif mount.get('Propagation'):new['BindOptions']={'Propagation':mount['Propagation']}
        host['Mounts'].append(new)
    context=project_context(item)
    if context:
        name,_,_=context
        config['Labels']['com.docker.compose.image']=item['Image']
        config['Labels']['com.docker.compose.project.working_dir']=project_dirs[name]
        config['Labels']['com.docker.compose.project.config_files']=project_dirs[name]+'/compose.restore.json'
    endpoints={}
    for name,original in (item.get('NetworkSettings',{}).get('Networks') or {}).items():
        if name in ('bridge','host','none'):continue
        endpoint={k:copy.deepcopy(original[k]) for k in ('IPAMConfig','Aliases','DriverOpts','MacAddress') if original.get(k)}
        if 'Aliases' in endpoint:endpoint['Aliases']=[a for a in endpoint['Aliases'] if a not in (item['Id'],item['Id'][:12])]
        endpoints[name]=endpoint
    return dict(config,HostConfig=host,NetworkingConfig={'EndpointsConfig':endpoints})

def canonical_project(project, relocated, items):
    cfg=copy.deepcopy(project['config'])
    work=project['work']
    def relocate(source):
        require(source in relocated,'Compose references unarchived bind data')
        return relocated[source]
    for name,service in cfg['services'].items():
        runtime=[x for x in items if (x['Config'].get('Labels') or {}).get('com.docker.compose.service')==name and project_context(x) and project_context(x)[1]==work]
        require(runtime,'Compose service has no archived runtime container')
        require(len({x['Image'] for x in runtime})==1,'Compose service uses different images')
        service['image']=runtime[0]['Image']
        if service.get('build'):
            service.pop('build')
        for mount in service.get('volumes',[]):
            if mount.get('type')=='bind':mount['source']=relocate(mount['source'])
    return cfg

def restore(engine,directory,target):
    private(directory,True)
    require(not (directory/'incomplete.json').exists(),'Incomplete backup cannot be restored')
    manifest=directory/'manifest.json';private(manifest)
    state=json.loads(manifest.read_text())
    require(state.get('version')==2,'Unsupported backup format; legacy data must be recovered into an empty staging directory first')
    require(state['platform']==engine.platform,'Backup and Docker platform differ')
    fingerprint=digest(manifest)
    original_target=empty_target(target)
    items=state['containers'];require(items,'Empty backup')
    names=[x['Name'].lstrip('/') for x in items]
    require(len(set(names))==len(names) and all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',n) for n in names),'Invalid or duplicate container name')
    for item in items:supported(item)
    checksums=state['checksums']
    require('images.tar' in checksums,'Image archive missing')
    for name,checksum in checksums.items():
        require(re.fullmatch(r'(?:data-[0-9]+\.tar\.gz|images\.tar)',name),'Invalid backup member name')
        p=directory/name;private(p);require(digest(p)==checksum,'Backup checksum mismatch')
        archive_members(p)
    for source,record in state['sources'].items():
        require(record['archive'] in checksums and record['archive']!='images.tar' and record['source']==source,'Data archive missing or mismatched')
    for name,v in state['volumes'].items():
        require(v['Name']==name and v['Driver']=='local' and not v.get('Options') and v['Mountpoint'] in state['sources'],'Unsupported volume metadata')
    for name,n in state['networks'].items():
        require(n['Name']==name and n['Driver']=='bridge' and not n.get('Ingress') and n.get('Scope')=='local' and not (n.get('Options') or {}).get('com.docker.network.bridge.name'),'Unsupported network metadata')
    needed=sum(m.size for name in checksums if name!='images.tar' for m in archive_members(directory/name))
    require(shutil.disk_usage(target).free>needed*2+(directory/'images.tar').stat().st_size,'Insufficient free space for staged recovery')
    def conflicts():
        for name in names:require(engine.container(name,missing=True) is None,'Container already exists (running or stopped); nothing overwritten')
        for name in state['volumes']:require(engine.api('GET','/volumes/'+quote(name,safe=''),missing=True) is None,'Volume already exists; nothing overwritten')
        for name in state['networks']:require(engine.api('GET','/networks/'+quote(name,safe=''),missing=True) is None,'Network already exists; nothing overwritten')
        projects=state['projects']
        for current in engine.api('GET','/containers/json?all=1'):
            require((current.get('Labels') or {}).get('com.docker.compose.project') not in projects,'Compose project already exists')
    conflicts()
    relocated={source:str(target/('data-'+str(i))/'payload') for i,source in enumerate(state['sources'])}
    project_dirs={name:relocated[p['work']] for name,p in state['projects'].items()}
    configs={name:canonical_project(p,relocated,items) for name,p in state['projects'].items()}
    payloads=[payload(x,relocated,project_dirs) for x in items]
    require(empty_target(target)==original_target and digest(manifest)==fingerprint,'Restore inputs changed')
    conflicts()
    # All deterministic validation precedes changes. Unexpected failures leave explicit partial state, never delete existing resources.
    token=uuid.uuid4().hex
    progress={'transaction':token,'created_containers':[],'created_volumes':[],'created_networks':[],'complete':False}
    def save():
        (target/'restore-state.json').write_text(json.dumps(progress));os.chmod(target/'restore-state.json',0o600)
    save()
    try:
        for i,(source,record) in enumerate(state['sources'].items()):
            leaf=target/('data-'+str(i));leaf.mkdir(mode=0o700)
            require(digest(directory/record['archive'])==checksums[record['archive']],'Archive changed')
            unpack(directory/record['archive'],leaf)
        for name,cfg in configs.items():
            p=Path(project_dirs[name])/'compose.restore.json'
            require(not p.exists() and not p.is_symlink(),'Reserved Compose restore filename exists')
            p.write_text(json.dumps(cfg));os.chmod(p,0o600)
        require(digest(directory/'images.tar')==checksums['images.tar'],'Image archive changed')
        cli('image','load','-i',str(directory/'images.tar'))
        for name,v in state['volumes'].items():
            require(engine.api('GET','/volumes/'+quote(name,safe=''),missing=True) is None,'Volume appeared concurrently')
            labels=dict(v.get('Labels') or {}, **{'io.daimon.restore':token})
            new=engine.api('POST','/volumes/create',{'Name':name,'Driver':'local','Labels':labels})
            require(new.get('Labels',{}).get('io.daimon.restore')==token,'Volume appeared concurrently; retained without writes')
            progress['created_volumes'].append(name);save()
            destination=Path(new['Mountpoint'])
            require(destination.resolve()==destination and destination.is_dir() and not any(destination.iterdir()),'New volume is not empty')
            record=state['sources'][v['Mountpoint']]
            unpack(directory/record['archive'],destination,volume=True)
        for name,n in state['networks'].items():
            require(engine.api('GET','/networks/'+quote(name,safe=''),missing=True) is None,'Network appeared concurrently')
            data={k:n[k] for k in ('Name','Driver','Internal','Attachable','EnableIPv6','IPAM','Options','Labels') if k in n}
            data['CheckDuplicate']=True
            data['Labels']=dict(data.get('Labels') or {}, **{'io.daimon.restore':token})
            new=engine.api('POST','/networks/create',data)
            progress['created_networks'].append(new['Id']);save()
        restored=[]
        for item,body,name in zip(items,payloads,names):
            result=engine.api('POST','/containers/create?name='+quote(name,safe=''),body)
            cid=result['Id'];progress['created_containers'].append(cid);save()
            current=engine.container(cid)
            for key in ('Env','Entrypoint','Cmd','User','WorkingDir','Healthcheck'):
                require(current['Config'].get(key)==body.get(key),'Restored container config differs: '+key)
            require(current['HostConfig'].get('PortBindings')==body['HostConfig'].get('PortBindings'),'Restored port bindings differ')
            if item['State']['Running']:restored.append((item,cid))
        pending=list(restored);done=set()
        while pending:
            ready=[]
            for item,cid in pending:
                ctx=project_context(item)
                service=(item['Config'].get('Labels') or {}).get('com.docker.compose.service')
                dependencies=set(state['projects'][ctx[0]]['config']['services'][service].get('depends_on',{})) if ctx else set()
                running_services={(project_context(other)[0],(other['Config'].get('Labels') or {}).get('com.docker.compose.service')) for other,_ in restored if project_context(other)}
                if not ctx or all((ctx[0],dep) in done or (ctx[0],dep) not in running_services for dep in dependencies):ready.append((item,cid))
            require(ready,'Circular Compose startup dependencies')
            for item,cid in ready:
                engine.api('POST','/containers/'+cid+'/start')
                deadline=time.monotonic()+120
                while True:
                    current=engine.container(cid)['State']
                    require(current['Running'],'Restored container exited; inspect application health')
                    health=(current.get('Health') or {}).get('Status')
                    if health in (None,'healthy'):break
                    require(health!='unhealthy' and time.monotonic()<deadline,'Restored container healthcheck failed or timed out')
                    time.sleep(1)
                ctx=project_context(item)
                if ctx:done.add((ctx[0],(item['Config'].get('Labels') or {}).get('com.docker.compose.service')))
                pending.remove((item,cid))
        progress['complete']=True;save()
        print('Restore complete. Runtime state verified; application/data health requires its own checks. Data directory: '+str(target))
    except BaseException:
        save()
        print('Restore incomplete. Existing resources were not replaced; keep '+str(target)+'/restore-state.json for inspection.',file=sys.stderr)
        raise

def main():
    require(os.geteuid()==0,'Root required')
    os.umask(0o077)
    require(len(sys.argv)>=3 and sys.argv[1] in ('backup','restore'),'Invalid backup/restore arguments')
    lock=Path('/run/lock/daimon-docker-migration.lock')
    require(lock.parent.resolve()==lock.parent and lock.parent.stat().st_uid==0,'Untrusted lock directory')
    fd=os.open(lock,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
    i=os.fstat(fd);require(stat.S_ISREG(i.st_mode) and i.st_uid==0 and i.st_nlink==1 and not i.st_mode&0o022,'Unsafe migration lock')
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    def interrupted(signum,frame):raise InterruptedError('Docker backup/restore interrupted')
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,interrupted)
    engine=Engine()
    directory=Path(sys.argv[2])
    require(directory.is_absolute() and directory.parent==Path('/tmp') and re.fullmatch(r'docker_backup_[A-Za-z0-9][A-Za-z0-9._-]*',directory.name),'Backup must be a direct /tmp/docker_backup_* directory')
    if sys.argv[1]=='backup':backup(engine,directory,sys.argv[3:])
    else:
        require(len(sys.argv)==4,'An explicit empty restore directory is required')
        restore(engine,directory,Path(sys.argv[3]))

if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError,tarfile.TarError,subprocess.SubprocessError,http.client.HTTPException) as error:
        print('Docker backup/restore failed: '+str(error),file=sys.stderr)
        sys.exit(1)
PYDOCKER_BACKUP
}

docker_migration_engine() (
    umask 077
    local program
    command -v docker >/dev/null || { echo "未检测到 Docker，请先在 Docker 管理中安装 Docker。" >&2; return 1; }
    daimon_require_cmd python3 || return 1
    program=$(mktemp) || return 1
    trap 'rm -f -- "$program"' EXIT
    docker_migration_program > "$program" || return 1
    python3 "$program" "$@"
)

docker_ssh_migration() {

	docker_migration_backup_dir() {
		local path="${1%/}" resolved root
		root=$(realpath -e -- /tmp) || return 1
		[[ "$path" == /tmp/docker_backup_* && "${path##*/}" =~ ^docker_backup_[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
			[ -d "$path" ] && [ ! -L "$path" ] || {
			echo -e "${gl_hong}备份目录不存在或路径不受支持${gl_bai}" >&2; return 1
		}
		resolved=$(realpath -e -- "$path") || return 1
		[[ "$resolved" == "$root/${path##*/}" && "$path" == "/tmp/${path##*/}" ]] || {
			echo -e "${gl_hong}备份必须是 /tmp 下的直接目录，不允许路径跳转${gl_bai}" >&2; return 1
		}
		printf '%s\n' "$path"
	}

	is_compose_container() {
		local container=$1
		docker inspect "$container" | jq -e '.[0].Config.Labels["com.docker.compose.project"]' >/dev/null 2>&1
	}

	docker_migration_list_backups() {
		local BACKUP_ROOT="/tmp"
		echo -e "${gl_kjlan}当前备份列表:${gl_bai}"
		ls -1dt ${BACKUP_ROOT}/docker_backup_* 2>/dev/null || echo "无备份"
	}



	# ----------------------------
	# 备份
	# ----------------------------
	docker_migration_backup() {
		local containers confirm directory
		local -a selected=()
		command -v docker >/dev/null || { echo "Docker 未安装。"; return 1; }
		docker ps --format '{{.Names}}' || return 1
		read -r -p "容器名称（空格分隔，回车选择运行中的容器；Compose 自动包含整个项目）: " containers || return 1
		read -r -a selected <<< "$containers"
		echo "备份会停止所选容器及其 Compose 项目，完成后恢复原运行状态。包含可写层、镜像、挂载数据和 Compose 配置；不备份无关 /home/docker 文件。"
		read -r -p "输入 STOP_BACKUP 确认: " confirm || return 1
		[ "$confirm" = STOP_BACKUP ] || return 0
		directory="/tmp/docker_backup_$(date +%Y%m%d_%H%M%S)_${RANDOM}"
		docker_migration_engine backup "$directory" "${selected[@]}"
	}

	# ----------------------------
	# 还原
	# ----------------------------
	docker_migration_restore() {
		local directory target confirm
		read -r -p "请输入备份目录: " directory || return 1
		directory=$(docker_migration_backup_dir "$directory") || return 1
		read -r -p "请输入已创建的空恢复目录（不会覆盖原业务目录）: " target || return 1
		echo "只接受可信备份。同名容器（含停止态）、卷或网络会拒绝；恢复运行状态可能对外开放原端口。"
		read -r -p "输入 RESTORE 确认: " confirm || return 1
		[ "$confirm" = RESTORE ] || return 0
		docker_migration_engine restore "$directory" "$target"
	}


	# ----------------------------
	# 迁移
	# ----------------------------
	docker_migration_migrate() {
		send_stats "Docker迁移"
		local BACKUP_DIR TARGET_IP TARGET_USER TARGET_PORT
		read -e -p  "请输入要迁移的备份目录: " BACKUP_DIR || return 1
		BACKUP_DIR=$(docker_migration_backup_dir "$BACKUP_DIR") || return 1

		kj_ssh_read_host_user_port "目标服务器IP: " "目标服务器SSH用户名 [默认root]: " "目标服务器SSH端口 [默认22]: " "root" "22" || return 1
		TARGET_IP="$KJ_SSH_HOST"
		TARGET_USER="$KJ_SSH_USER"
		TARGET_PORT="$KJ_SSH_PORT"
		[[ "$TARGET_IP" == *:* ]] && TARGET_IP="[$TARGET_IP]"
		BACKUP_DIR=$(docker_migration_backup_dir "$BACKUP_DIR") || return 1

		echo -e "${gl_huang}传输备份中...${gl_bai}"
		if ! scp -P "$TARGET_PORT" -o StrictHostKeyChecking=no -r "$BACKUP_DIR" "$TARGET_USER@$TARGET_IP:/tmp/"; then
			echo -e "${gl_hong}迁移失败，请检查 SSH 连接${gl_bai}"; return 1
		fi
		echo -e "${gl_lv}迁移完成${gl_bai}"

	}

	# ----------------------------
	# 删除备份
	# ----------------------------
	docker_migration_delete_backup() {
		send_stats "Docker备份文件删除"
		local BACKUP_DIR confirm
		read -e -p  "请输入要删除的备份目录: " BACKUP_DIR || return 1
		BACKUP_DIR=$(docker_migration_backup_dir "$BACKUP_DIR") || return 1
		read -e -p "确认删除 $BACKUP_DIR？[y/N]: " confirm || return 1
		[[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0
		BACKUP_DIR=$(docker_migration_backup_dir "$BACKUP_DIR") || return 1
		rm -rf -- "$BACKUP_DIR" || {
			echo -e "${gl_hong}删除备份失败: ${BACKUP_DIR}${gl_bai}" >&2; return 1
		}
		echo -e "${gl_lv}已删除备份: ${BACKUP_DIR}${gl_bai}"
	}

	# ----------------------------
	# 主菜单
	# ----------------------------
	main_menu() {
		send_stats "Docker备份迁移还原"
		while true; do
			clear
			echo "------------------------"
			echo -e "Docker备份/迁移/还原工具"
			echo "------------------------"
			docker_migration_list_backups
			echo -e ""
			echo "------------------------"
			echo -e "1. 备份docker项目"
			echo -e "2. 迁移docker项目"
			echo -e "3. 还原docker项目"
			echo -e "4. 删除docker项目的备份文件"
			echo "------------------------"
			echo -e "0. 返回上一级选单"
			echo "------------------------"
			read -e -p  "请选择: " choice || return 1
			case $choice in
				1) docker_migration_backup ;;
				2) docker_migration_migrate ;;
				3) docker_migration_restore ;;
				4) docker_migration_delete_backup ;;
				0) return ;;
				*) echo -e "${gl_hong}无效选项${gl_bai}" ;;
			esac
		break_end
		done
	}

	main_menu
}

docker_compose_update_script_dir() {
	echo "${DAIMON_DOCKER_COMPOSE_UPDATE_DIR:-/root/linux-daimon/docker-compose-update}"
}

docker_compose_update_log_dir() {
	echo "/var/log/docker-compose-update"
}

docker_compose_update_sanitize_name() {
	echo "$1" | sed 's/[[:space:]\/\\:]/_/g; s/[^A-Za-z0-9_.-]/_/g'
}

docker_compose_update_project_id() {
	local project="$1"
	local workdir="$2"
	local config_files="$3"
	local digest
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s\0%s\0%s' "$project" "$workdir" "$config_files" | sha256sum | awk '{print $1}')
	else
		digest=$(printf '%s\0%s\0%s' "$project" "$workdir" "$config_files" | cksum | awk '{print $1}')
	fi
	printf '%.12s\n' "$digest"
}

docker_compose_update_discover_projects() {
	command -v docker >/dev/null 2>&1 || return 0
	local name project workdir config_files first_config key
	local -A project_map
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)
		workdir=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name" 2>/dev/null || true)
		config_files=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$name" 2>/dev/null || true)
		[ "$project" = "<no value>" ] && project=""
		[ "$workdir" = "<no value>" ] && workdir=""
		[ "$config_files" = "<no value>" ] && config_files=""
		if [ -z "$workdir" ] && [ -n "$config_files" ]; then
			first_config="${config_files%%,*}"
			workdir=$(dirname "$first_config" 2>/dev/null || true)
		fi
		if [ -z "$project" ] || [ -z "$workdir" ]; then
			continue
		fi
		key="${project}"$'\034'"${workdir}"$'\034'"${config_files}"
		project_map["$key"]=$(printf '%s\t%s\t%s' "$project" "$workdir" "$config_files")
	done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
	for key in "${!project_map[@]}"; do
		printf '%s\n' "${project_map[$key]}"
	done | sort
}

docker_compose_update_script_file() {
	local project="$1"
	local workdir="$2"
	local config_files="${3:-}"
	local safe_project project_id
	safe_project=$(docker_compose_update_sanitize_name "$project")
	project_id=$(docker_compose_update_project_id "$project" "$workdir" "$config_files")
	echo "$(docker_compose_update_script_dir)/compose_update_${safe_project}_${project_id}.sh"
}

docker_compose_update_legacy_script_file() {
	local project="$1"
	local workdir="$2"
	local safe_project safe_path
	safe_project=$(docker_compose_update_sanitize_name "$project")
	safe_path=$(docker_compose_update_sanitize_name "$workdir")
	echo "$(docker_compose_update_script_dir)/compose_update_${safe_project}_${safe_path}.sh"
}

docker_compose_update_cron_line() {
	local script_file="$1"
	local idx="${2:-1}"
	local minute hour
	minute=$(( (idx * 7) % 60 ))
	hour=$(( 3 + ((idx - 1) / 8) ))
	[ "$hour" -gt 6 ] && hour=6
	printf '* * * * * [ "$(TZ=Asia/Shanghai date +\\%%H:\\%%M)" = "%02d:%02d" ] && /bin/bash %s >> %s/cron_%s.log 2>&1' \
		"$hour" "$minute" "$script_file" "$(docker_compose_update_log_dir)" "$(basename "$script_file" .sh)"
}

docker_compose_update_status_text() {
	local script_file="$1"
	local legacy_script_file="$2"
	local project_id="$3"
	local cron_output=""
	cron_output=$(crontab -l 2>/dev/null || true)
	if [ -f "$script_file" ] && printf '%s\n' "$cron_output" | grep -Fq "$script_file"; then
		if bash -n "$script_file" 2>/dev/null && grep -Fqx "# compose-update-id: $project_id" "$script_file"; then
			if grep -Fqx '# compose-update-version: 2' "$script_file"; then
				echo -e "${gl_lv}已配置${gl_bai}"
			else
				echo -e "${gl_huang}旧版任务，需重新安装${gl_bai}"
			fi
		else
			echo -e "${gl_hong}脚本异常，请重新安装${gl_bai}"
		fi
	elif [ "$legacy_script_file" != "$script_file" ] && { [ -f "$legacy_script_file" ] || printf '%s\n' "$cron_output" | grep -Fq "$legacy_script_file"; }; then
		echo -e "${gl_huang}旧版任务，需重新安装${gl_bai}"
	elif [ -f "$script_file" ]; then
		echo -e "${gl_huang}脚本已存在，未加入定时${gl_bai}"
	elif printf '%s\n' "$cron_output" | grep -Fq "$script_file"; then
		echo -e "${gl_huang}定时任务存在，脚本不存在${gl_bai}"
	else
		echo -e "${gl_hong}未配置${gl_bai}"
	fi
}

docker_compose_update_show_status() {
	local idx=0 project workdir config_files script_file legacy_script_file project_id
	echo -e "${gl_kjlan}------------------------${gl_bai}"
	echo "Docker Compose 项目列表"
	echo -e "${gl_kjlan}------------------------${gl_bai}"
	while IFS=$'\t' read -r project workdir config_files; do
		[ -z "$project" ] && continue
		idx=$((idx + 1))
		project_id=$(docker_compose_update_project_id "$project" "$workdir" "$config_files")
		script_file=$(docker_compose_update_script_file "$project" "$workdir" "$config_files")
		legacy_script_file=$(docker_compose_update_legacy_script_file "$project" "$workdir")
		printf "%2d. %-24s %-42s %b\n" "$idx" "$project" "$(docker_compose_update_status_text "$script_file" "$legacy_script_file" "$project_id")" ""
		echo "    路径: $workdir"
		[ -n "$config_files" ] && echo "    配置: $config_files"
	done < <(docker_compose_update_discover_projects)
	if [ "$idx" -eq 0 ]; then
		echo -e "${gl_huang}未检测到带 com.docker.compose.* 标签的 Docker Compose 项目。${gl_bai}"
	fi
	echo -e "${gl_kjlan}------------------------${gl_bai}"
	echo "所有 Docker 容器"
	docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
	docker_compose_update_show_orphans
	echo -e "${gl_kjlan}------------------------${gl_bai}"
}

docker_compose_update_get_item_by_number() {
	local target="$1"
	local idx=0 project workdir config_files
	while IFS=$'\t' read -r project workdir config_files; do
		[ -z "$project" ] && continue
		idx=$((idx + 1))
		if [ "$idx" -eq "$target" ]; then
			printf '%s\t%s\t%s\t%s\n' "$idx" "$project" "$workdir" "$config_files"
			return 0
		fi
	done < <(docker_compose_update_discover_projects)
	return 1
}

docker_compose_update_all_numbers() {
	local idx=0 project workdir config_files
	while IFS=$'\t' read -r project workdir config_files; do
		[ -z "$project" ] && continue
		idx=$((idx + 1))
		printf "%s " "$idx"
	done < <(docker_compose_update_discover_projects)
}

docker_compose_update_write_script() {
	local project="$1"
	local workdir="$2"
	local config_files="$3"
	local script_file="$4"
	local project_id="$5"
	local temp_file
	mkdir -p "$(dirname "$script_file")" "$(docker_compose_update_log_dir)" || return 1
	temp_file=$(mktemp "${script_file}.tmp.XXXXXX") || return 1
	if ! {
		cat <<'EOF'
#!/bin/bash
set -Eeuo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
		printf '# compose-update-id: %s\n' "$project_id"
		printf '# compose-update-version: 2\n'
		printf 'COMPOSE_UPDATE_ID=%q\n' "$project_id"
		printf 'COMPOSE_PROJECT=%q\n' "$project"
		printf 'COMPOSE_PATH=%q\n' "$workdir"
		printf 'COMPOSE_CONFIG_FILES=%q\n' "$config_files"
		cat <<'EOF'
WAIT_TIMEOUT="${COMPOSE_UPDATE_WAIT_TIMEOUT:-120}"
PULL_ATTEMPTS="${COMPOSE_UPDATE_PULL_ATTEMPTS:-3}"
PULL_RETRY_DELAY="${COMPOSE_UPDATE_PULL_RETRY_DELAY:-10}"
PULL_TIMEOUT="${COMPOSE_UPDATE_PULL_TIMEOUT:-300}"
LOCK_FILE="/run/lock/docker-compose-update-${COMPOSE_UPDATE_ID}.lock"
LOCK_DIR="${LOCK_FILE}.d"
COMPOSE_ARGS=(-p "$COMPOSE_PROJECT")
TARGET_SERVICES=()
declare -A PREVIOUS_IMAGES=()
declare -A SERVICE_IMAGES=() EXPECTED_IMAGES=()

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
	log "错误: $*"
	exit 1
}

release_fallback_lock() {
	[ "${USING_FALLBACK_LOCK:-false}" = "true" ] && rmdir "$LOCK_DIR" 2>/dev/null || true
}

run_compose() {
	docker compose "${COMPOSE_ARGS[@]}" "$@"
}

restore_previous_images() {
	local image failed=0
	[ "${#PREVIOUS_IMAGES[@]}" -gt 0 ] || return 1
	for image in "${!PREVIOUS_IMAGES[@]}"; do
		if ! docker image tag "${PREVIOUS_IMAGES[$image]}" "$image" >/dev/null; then
			failed=1
		fi
	done
	return "$failed"
}

start_services() {
	local recreate="${1:-false}"
	local args=(up -d --no-deps --no-build --pull never --wait --wait-timeout "$WAIT_TIMEOUT")
	[ "$recreate" = "true" ] && args+=(--force-recreate)
	[ "${#TARGET_SERVICES[@]}" -gt 0 ] && args+=("${TARGET_SERVICES[@]}")
	run_compose "${args[@]}"
}

service_image() {
	local service="$1" ids cid image result=""
	ids=$(run_compose ps -q "$service") || return 1
	[ -n "$ids" ] || return 1
	while IFS= read -r cid; do
		[ "$(docker inspect -f '{{.State.Running}}' "$cid")" = true ] || return 1
		image=$(docker inspect -f '{{.Image}}' "$cid") || return 1
		[[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
		[ -z "$result" ] || [ "$result" = "$image" ] || return 1
		result="$image"
	done <<< "$ids"
	printf '%s\n' "$result"
}

verify_images() {
	local service expected
	for service in "${TARGET_SERVICES[@]}"; do
		expected="${EXPECTED_IMAGES[$service]}"
		[ "$(service_image "$service")" = "$expected" ] || return 1
	done
}

case "$WAIT_TIMEOUT" in
	''|*[!0-9]*) fail "COMPOSE_UPDATE_WAIT_TIMEOUT 必须是正整数" ;;
	0) fail "COMPOSE_UPDATE_WAIT_TIMEOUT 必须大于 0" ;;
esac
[[ "$PULL_ATTEMPTS" =~ ^[1-5]$ ]] || fail "COMPOSE_UPDATE_PULL_ATTEMPTS 必须为 1 到 5"
[[ "$PULL_RETRY_DELAY" =~ ^[0-9]+$ ]] && [ "$PULL_RETRY_DELAY" -le 300 ] || fail "拉取重试间隔必须为 0 到 300 秒"
[[ "$PULL_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$PULL_TIMEOUT" -ge 1 ] && [ "$PULL_TIMEOUT" -le 1800 ] || fail "单次拉取超时必须为 1 到 1800 秒"

mkdir -p /run/lock || fail "无法创建锁目录"
if command -v flock >/dev/null 2>&1; then
	exec 9>"$LOCK_FILE" || fail "无法打开锁文件"
	if ! flock -n 9; then
		log "已有更新任务正在运行，本次跳过"
		exit 0
	fi
else
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		log "已有更新任务正在运行，本次跳过"
		exit 0
	fi
	USING_FALLBACK_LOCK=true
	trap release_fallback_lock EXIT
fi

command -v docker >/dev/null 2>&1 || fail "未找到 docker 命令"
docker compose version >/dev/null 2>&1 || fail "Docker Compose 插件不可用"
command -v python3 >/dev/null 2>&1 || fail "需要 Python 3 解析 Compose 服务配置"
command -v timeout >/dev/null 2>&1 || fail "需要 timeout 限制镜像拉取耗时"
up_help=$(run_compose up --help 2>/dev/null) || fail "无法检查 Compose 功能"
for flag in --wait --pull --no-build; do
	grep -q -- "$flag" <<< "$up_help" || fail "Docker Compose 不支持 $flag，请先更新 Docker"
done
[ -d "$COMPOSE_PATH" ] || fail "项目目录不存在: $COMPOSE_PATH"
cd "$COMPOSE_PATH" || fail "无法进入项目目录: $COMPOSE_PATH"

if [ -n "$COMPOSE_CONFIG_FILES" ]; then
	IFS=',' read -r -a config_files <<< "$COMPOSE_CONFIG_FILES"
	for config_file in "${config_files[@]}"; do
		[ -f "$config_file" ] || fail "Compose 配置不存在: $config_file"
		COMPOSE_ARGS+=(-f "$config_file")
	done
fi

running_services=$(run_compose ps --services --status running 2>/dev/null) || fail "无法读取 Compose 项目状态"
mapfile -t TARGET_SERVICES < <(printf '%s\n' "$running_services" | sed '/^[[:space:]]*$/d' | sort -u)
log "开始更新项目: $COMPOSE_PROJECT"
log "项目路径: $COMPOSE_PATH"
[ -n "$COMPOSE_CONFIG_FILES" ] && log "配置文件: $COMPOSE_CONFIG_FILES"
if [ "${#TARGET_SERVICES[@]}" -gt 0 ]; then
	log "当前运行服务: ${TARGET_SERVICES[*]}"
else
	log "未检测到运行中的服务，为保留停服状态，本次跳过"
	exit 0
fi

config_json=$(run_compose config --format json 2>/dev/null) || fail "无法解析 Compose 配置"
service_plan=$(printf '%s' "$config_json" | python3 -c '
import json,re,sys
services=json.load(sys.stdin)["services"]
for name in sys.argv[1:]:
    service=services[name]
    image=service.get("image", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name): raise ValueError("Invalid service name")
    if service.get("build") is not None: mode="SKIPPED_BUILD"
    elif not image: mode="SKIPPED_NO_IMAGE"
    elif service.get("pull_policy")=="never": mode="SKIPPED_POLICY"
    elif "@sha256:" in image: mode="SKIPPED_PINNED"
    else: mode="PULL"
    if mode=="PULL" and (image.startswith("-") or any(c.isspace() for c in image)): raise ValueError("Invalid image reference")
    print(name, mode, image if mode=="PULL" else "-", sep="\t")
' "${TARGET_SERVICES[@]}" 2>/dev/null) || fail "无法分类运行中的服务"
unset config_json
TARGET_SERVICES=()
while IFS=$'\t' read -r service mode image; do
	if [ "$mode" != PULL ]; then
		log "$mode: $service 未自动更新；本地构建需单独更新源码并构建，固定镜像或禁止拉取策略保持不变"
		continue
	fi
	image_id=$(service_image "$service") || fail "无法确认 $service 的原运行镜像，未拉取或重建"
	if [ -n "${PREVIOUS_IMAGES[$image]:-}" ] && [ "${PREVIOUS_IMAGES[$image]}" != "$image_id" ]; then
		fail "共享镜像的服务运行不同版本，无法安全恢复"
	fi
	PREVIOUS_IMAGES["$image"]="$image_id"
	SERVICE_IMAGES["$service"]="$image"
	TARGET_SERVICES+=("$service")
done <<< "$service_plan"
[ "${#TARGET_SERVICES[@]}" -gt 0 ] || { log "SKIPPED: 没有可自动拉取更新的运行服务"; exit 0; }

pulled=false
for ((attempt=1; attempt<=PULL_ATTEMPTS; attempt++)); do
	log "正在拉取镜像 ($attempt/$PULL_ATTEMPTS)"
	if timeout --signal=TERM --kill-after=30s "$PULL_TIMEOUT" docker compose "${COMPOSE_ARGS[@]}" pull --policy always "${TARGET_SERVICES[@]}"; then
		pulled=true
		break
	fi
	[ "$attempt" -eq "$PULL_ATTEMPTS" ] || sleep "$PULL_RETRY_DELAY"
done
if [ "$pulled" != true ]; then
	restore_previous_images || log "警告: 部分旧镜像标签恢复失败"
	fail "镜像拉取重试耗尽，现有容器保持运行"
fi

changed=0
for service in "${TARGET_SERVICES[@]}"; do
	image="${SERVICE_IMAGES[$service]}"
	image_id=$(docker image inspect -f '{{.Id}}' "$image") || fail "拉取后镜像不存在: $image"
	[[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "镜像 ID 无效"
	EXPECTED_IMAGES["$service"]="$image_id"
	[ "$image_id" = "${PREVIOUS_IMAGES[$image]}" ] || changed=$((changed + 1))
done
if [ "$changed" -eq 0 ]; then
	verify_images || fail "镜像拉取期间运行容器发生变化，请检查项目"
	log "NO_CHANGE: 镜像未变化，没有重建容器"
	exit 0
fi

log "正在应用更新"
if ! start_services false || ! verify_images; then
	log "更新启动或健康检查失败，开始恢复旧镜像"
	for service in "${TARGET_SERVICES[@]}"; do
		EXPECTED_IMAGES["$service"]="${PREVIOUS_IMAGES[${SERVICE_IMAGES[$service]}]}"
	done
	if restore_previous_images && start_services true && verify_images; then
		fail "更新失败，已恢复到更新前镜像"
	fi
	fail "更新失败，自动恢复也未成功，请立即检查容器"
fi

log "UPDATED: 更新成功，$changed 个服务的镜像发生变化并通过运行/健康等待与镜像 ID 校验"
EOF
	} > "$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	if ! bash -n "$temp_file" || ! chmod 700 "$temp_file" || ! mv -f "$temp_file" "$script_file"; then
		rm -f "$temp_file"
		return 1
	fi
}

docker_compose_update_ensure_logrotate() {
	local config_file="/etc/logrotate.d/docker-compose-update"
	local temp_file
	temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || return 1
	if ! cat > "$temp_file" <<'EOF'
/var/log/docker-compose-update/*.log {
    daily
    rotate 14
    maxsize 10M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0600 root root
}
EOF
	then
		rm -f "$temp_file"
		return 1
	fi
	chmod 644 "$temp_file" && mv -f "$temp_file" "$config_file" || {
		rm -f "$temp_file"
		return 1
	}
}

docker_compose_update_update_crontab() {
	local action="$1"
	local script_file="$2"
	local legacy_script_file="$3"
	local cron_line="${4:-}"
	local lock_file="/run/lock/linux-daimon-crontab.lock"
	local current_file current_error next_file lock_fd
	mkdir -p /run/lock || return 1
	exec {lock_fd}>"$lock_file" || return 1
	if command -v flock >/dev/null 2>&1 && ! flock "$lock_fd"; then
		exec {lock_fd}>&-
		return 1
	fi
	current_file=$(mktemp) || { exec {lock_fd}>&-; return 1; }
	current_error=$(mktemp) || { rm -f "$current_file"; exec {lock_fd}>&-; return 1; }
	next_file=$(mktemp) || { rm -f "$current_file" "$current_error"; exec {lock_fd}>&-; return 1; }
	if ! LC_ALL=C crontab -l > "$current_file" 2> "$current_error"; then
		if grep -Fqi "no crontab for" "$current_error"; then
			: > "$current_file"
		else
			rm -f "$current_file" "$current_error" "$next_file"
			exec {lock_fd}>&-
			return 1
		fi
	fi
	awk -v current="$script_file" -v legacy="$legacy_script_file" '
		index($0, current) == 0 && (legacy == current || index($0, legacy) == 0) { print }
	' "$current_file" > "$next_file"
	[ "$action" = "install" ] && printf '%s\n' "$cron_line" >> "$next_file"
	if ! crontab "$next_file"; then
		rm -f "$current_file" "$current_error" "$next_file"
		exec {lock_fd}>&-
		return 1
	fi
	rm -f "$current_file" "$current_error" "$next_file"
	exec {lock_fd}>&-
}

docker_compose_update_install_one() {
	local idx="$1"
	local project="$2"
	local workdir="$3"
	local config_files="$4"
	local script_file legacy_script_file cron_line project_id config_file
	local -a compose_config_files
	root_use
	check_crontab_installed || return 1
	daimon_require_cmd python3 && daimon_require_cmd timeout && docker_compose_require_plugin || { echo "未配置自动更新。" >&2; return 1; }
	if ! docker compose up --help 2>/dev/null | grep -q -- '--wait'; then
		echo -e "${gl_hong}Docker Compose 版本过旧，不支持健康等待，请先更新 Docker。${gl_bai}"
		return 1
	fi
	if [ ! -d "$workdir" ]; then
		echo -e "${gl_hong}项目目录不存在: $workdir${gl_bai}"
		return 1
	fi
	if [ -n "$config_files" ]; then
		IFS=',' read -r -a compose_config_files <<< "$config_files"
		for config_file in "${compose_config_files[@]}"; do
			if [ "${config_file#/}" = "$config_file" ]; then
				config_file="$workdir/$config_file"
			fi
			if [ ! -f "$config_file" ]; then
				echo -e "${gl_hong}Compose 配置不存在: $config_file${gl_bai}"
				return 1
			fi
		done
	fi
	project_id=$(docker_compose_update_project_id "$project" "$workdir" "$config_files")
	script_file=$(docker_compose_update_script_file "$project" "$workdir" "$config_files")
	legacy_script_file=$(docker_compose_update_legacy_script_file "$project" "$workdir")
	cron_line=$(docker_compose_update_cron_line "$script_file" "$idx")
	if ! docker_compose_update_write_script "$project" "$workdir" "$config_files" "$script_file" "$project_id"; then
		echo -e "${gl_hong}自动更新脚本写入失败: $project${gl_bai}"
		return 1
	fi
	if ! docker_compose_update_update_crontab install "$script_file" "$legacy_script_file" "$cron_line"; then
		echo -e "${gl_hong}crontab 写入失败，脚本已保留但不会定时执行。${gl_bai}"
		return 1
	fi
	[ "$legacy_script_file" != "$script_file" ] && rm -f "$legacy_script_file"
	if ! docker_compose_update_ensure_logrotate; then
		echo -e "${gl_huang}警告: 日志轮转配置失败，请检查 /etc/logrotate.d。${gl_bai}"
	fi
	echo -e "${gl_lv}已配置 Docker Compose 自动更新: $project${gl_bai}"
	echo "脚本: $script_file"
	echo "定时: $cron_line"
}

docker_compose_update_remove_one() {
	local project="$1"
	local workdir="$2"
	local config_files="$3"
	local script_file legacy_script_file
	root_use
	script_file=$(docker_compose_update_script_file "$project" "$workdir" "$config_files")
	legacy_script_file=$(docker_compose_update_legacy_script_file "$project" "$workdir")
	if ! docker_compose_update_update_crontab remove "$script_file" "$legacy_script_file"; then
		echo -e "${gl_hong}crontab 更新失败，未删除自动更新脚本。${gl_bai}"
		return 1
	fi
	if ! rm -f "$script_file" "$legacy_script_file"; then
		echo -e "${gl_hong}自动更新脚本删除失败: $project${gl_bai}"
		return 1
	fi
	echo -e "${gl_lv}已卸载 Docker Compose 自动更新: $project${gl_bai}"
}

docker_compose_update_expected_files() {
	local project workdir config_files
	while IFS=$'\t' read -r project workdir config_files; do
		[ -n "$project" ] || continue
		docker_compose_update_script_file "$project" "$workdir" "$config_files"
		docker_compose_update_legacy_script_file "$project" "$workdir"
	done < <(docker_compose_update_discover_projects)
}

docker_compose_update_cron_script_files() {
	local script_dir
	script_dir=$(docker_compose_update_script_dir)
	crontab -l 2>/dev/null | awk -v prefix="$script_dir/compose_update_" '
		{
			for (i = 1; i <= NF; i++) {
				if (index($i, prefix) == 1 && $i ~ /\.sh$/) print $i
			}
		}
	' | sort -u
}

docker_compose_update_orphan_files() {
	local file
	local -A expected
	while IFS= read -r file; do
		[ -n "$file" ] && expected["$file"]=1
	done < <(docker_compose_update_expected_files)
	{
		find "$(docker_compose_update_script_dir)" -maxdepth 1 -type f -name 'compose_update_*.sh' -print 2>/dev/null
		docker_compose_update_cron_script_files
	} | sort -u | while IFS= read -r file; do
		[ -n "$file" ] || continue
		[ -n "${expected[$file]:-}" ] || printf '%s\n' "$file"
	done
}

docker_compose_update_show_orphans() {
	local file count=0
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if [ "$count" -eq 0 ]; then
			echo -e "${gl_huang}失效或已删除项目的自动更新任务:${gl_bai}"
		fi
		count=$((count + 1))
		echo "    $file"
	done < <(docker_compose_update_orphan_files)
}

docker_compose_update_cleanup_orphans() {
	local file script_dir
	local -a orphan_files=()
	mapfile -t orphan_files < <(docker_compose_update_orphan_files)
	if [ "${#orphan_files[@]}" -eq 0 ]; then
		echo -e "${gl_lv}没有失效任务。${gl_bai}"
		return 0
	fi
	read -e -p "确认删除以上 ${#orphan_files[@]} 个失效任务？(y/N): " confirm || return 1
	if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
		echo "已取消"
		return 0
	fi
	script_dir="$(docker_compose_update_script_dir)/"
	for file in "${orphan_files[@]}"; do
		case "$file" in
			"${script_dir}"compose_update_*.sh) ;;
			*) echo -e "${gl_hong}跳过非托管路径: $file${gl_bai}"; continue ;;
		esac
		if ! docker_compose_update_update_crontab remove "$file" "$file"; then
			echo -e "${gl_hong}失效任务的 crontab 清理失败: $file${gl_bai}"
			return 1
		fi
		rm -f "$file" || return 1
	done
	echo -e "${gl_lv}失效任务已清理。${gl_bai}"
}

docker_compose_update_handle_numbers() {
	local action="$1"
	local nums="$2"
	local n item idx project workdir config_files
	for n in $nums; do
		if ! [[ "$n" =~ ^[0-9]+$ ]]; then
			echo "跳过无效编号: $n"
			continue
		fi
		if ! item=$(docker_compose_update_get_item_by_number "$n"); then
			echo "跳过无效编号: $n"
			continue
		fi
		IFS=$'\t' read -r idx project workdir config_files <<< "$item"
		if [ "$action" = "install" ]; then
			docker_compose_update_install_one "$idx" "$project" "$workdir" "$config_files"
		else
			docker_compose_update_remove_one "$project" "$workdir" "$config_files"
		fi
	done
}

docker_compose_require_plugin() {
	docker compose version >/dev/null 2>&1 && return 0
	echo -e "${gl_kjlan}缺少 Docker Compose 插件，正在自动安装 docker-compose-plugin...${gl_bai}"
	install docker-compose-plugin || install docker-compose-v2
	if ! docker compose version >/dev/null 2>&1; then
		echo -e "${gl_hong}Docker Compose 插件安装失败，请检查 Docker 软件源。${gl_bai}" >&2
		return 1
	fi
}

docker_compose_auto_update_manager() {
	if ! command -v docker >/dev/null 2>&1; then
		echo -e "${gl_hong}未检测到 Docker，请先在 Docker 管理中安装 Docker。${gl_bai}"
		return 1
	fi
	docker_compose_require_plugin || return 1
	while true; do
		clear
		echo -e "Docker Compose 自动更新"
		echo -e "脚本目录: ${gl_kjlan}$(docker_compose_update_script_dir)${gl_bai}"
		echo -e "日志目录: ${gl_kjlan}$(docker_compose_update_log_dir)${gl_bai}"
		docker_compose_update_show_status
		echo -e "${gl_kjlan}1.   ${gl_bai}安装自动更新（支持多选，输入编号，如: 1 2）"
		echo -e "${gl_kjlan}2.   ${gl_bai}卸载自动更新（支持多选，输入编号，如: 2 4）"
		echo -e "${gl_kjlan}3.   ${gl_bai}一键安装（默认全选，可自行删除编号）"
		echo -e "${gl_kjlan}4.   ${gl_bai}一键卸载（默认全选，可自行删除编号）"
		echo -e "${gl_kjlan}5.   ${gl_bai}清理失效或已删除项目的任务"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回上一级菜单"
		echo -e "${gl_kjlan}------------------------${gl_bai}"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1)
				read -e -p "请输入要安装自动更新的项目编号（支持多选，空格分隔）: " nums || return 1
				docker_compose_update_handle_numbers install "$nums"
				;;
			2)
				read -e -p "请输入要卸载自动更新的项目编号（支持多选，空格分隔）: " nums || return 1
				docker_compose_update_handle_numbers remove "$nums"
				;;
			3)
				local nums
				nums="$(docker_compose_update_all_numbers)"
				read -e -i "$nums" -p "请确认/修改要安装的项目编号（默认全选，空格分隔）: " nums || return 1
				docker_compose_update_handle_numbers install "$nums"
				;;
			4)
				local nums
				nums="$(docker_compose_update_all_numbers)"
				read -e -i "$nums" -p "请确认/修改要卸载的项目编号（默认全选，空格分隔）: " nums || return 1
				read -e -p "确认卸载以上编号对应自动更新？(y/N): " confirm || return 1
				if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
					docker_compose_update_handle_numbers remove "$nums"
				else
					echo "已取消"
				fi
				;;
			5) docker_compose_update_cleanup_orphans ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

linux_docker() {

	while true; do
	  clear
	  # send_stats "docker管理"
	  echo -e "Docker管理"
	  docker_tato
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}1.   ${gl_bai}安装更新Docker环境"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}2.   ${gl_bai}查看Docker全局状态"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}3.   ${gl_bai}Docker容器管理"
	  echo -e "${gl_kjlan}4.   ${gl_bai}Docker镜像管理"
	  echo -e "${gl_kjlan}5.   ${gl_bai}Docker网络管理"
	  echo -e "${gl_kjlan}6.   ${gl_bai}Docker卷管理"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}7.   ${gl_bai}清理无用的docker容器和镜像网络数据卷"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}8.   ${gl_bai}更换Docker源"
	  echo -e "${gl_kjlan}9.   ${gl_bai}编辑daemon.json文件"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}10.  ${gl_bai}Docker Compose 自动更新"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}11.  ${gl_bai}开启Docker-ipv6访问"
	  echo -e "${gl_kjlan}12.  ${gl_bai}关闭Docker-ipv6访问"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}19.  ${gl_bai}备份/迁移/还原Docker环境"
	  echo -e "${gl_kjlan}20.  ${gl_bai}卸载Docker环境"
	  echo -e "${gl_kjlan}------------------------"
	  echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
	  echo -e "${gl_kjlan}------------------------${gl_bai}"
	  read -e -p "请输入你的选择: " sub_choice || return 1

	  case $sub_choice in
		  1)
			clear
			send_stats "安装docker环境"
			install_add_docker

			  ;;
		  2)
			  clear
			  if ! command -v docker >/dev/null 2>&1; then
				  echo "Docker 未安装，请先选择 1 安装 Docker 环境。"
			  elif ! docker info >/dev/null 2>&1; then
				  echo "Docker 服务不可用，请检查 Docker 状态后重试。"
			  else
			  local container_count=$(docker ps -a -q 2>/dev/null | wc -l)
			  local image_count=$(docker images -q 2>/dev/null | wc -l)
			  local network_count=$(docker network ls -q 2>/dev/null | wc -l)
			  local volume_count=$(docker volume ls -q 2>/dev/null | wc -l)

			  send_stats "docker全局状态"
			  echo "Docker版本"
			  docker -v
			  docker compose version

			  echo ""
			  echo -e "Docker镜像: ${gl_lv}$image_count${gl_bai} "
			  docker image ls
			  echo ""
			  echo -e "Docker容器: ${gl_lv}$container_count${gl_bai}"
			  docker ps -a
			  echo ""
			  echo -e "Docker卷: ${gl_lv}$volume_count${gl_bai}"
			  docker volume ls
			  echo ""
			  echo -e "Docker网络: ${gl_lv}$network_count${gl_bai}"
			  docker network ls
			  fi
			  echo ""

			  ;;
		  3)
			  docker_ps
			  [ "$?" -eq 90 ] && continue
			  ;;
		  4)
			  docker_image
			  [ "$?" -eq 90 ] && continue
			  ;;

		  5)
			  while true; do
				  clear
				  send_stats "Docker网络管理"
				  echo "Docker网络列表"
				  echo "------------------------------------------------------------"
				  docker network ls
				  echo ""

				  echo "------------------------------------------------------------"
				  container_ids=$(docker ps -q)
				  printf "%-25s %-25s %-25s\n" "容器名称" "网络名称" "IP地址"

				  for container_id in $container_ids; do
					  local container_info=$(docker inspect --format '{{ .Name }}{{ range $network, $config := .NetworkSettings.Networks }} {{ $network }} {{ $config.IPAddress }}{{ end }}' "$container_id")

					  local container_name=$(echo "$container_info" | awk '{print $1}')
					  local network_info=$(echo "$container_info" | cut -d' ' -f2-)

					  while IFS= read -r line; do
						  local network_name=$(echo "$line" | awk '{print $1}')
						  local ip_address=$(echo "$line" | awk '{print $2}')

						  printf "%-20s %-20s %-15s\n" "$container_name" "$network_name" "$ip_address"
					  done <<< "$network_info"
				  done

				  echo ""
				  echo "网络操作"
				  echo "------------------------"
				  echo "1. 创建网络"
				  echo "2. 加入网络"
				  echo "3. 退出网络"
				  echo "4. 删除网络"
				  echo "------------------------"
				  echo "0. 返回上一级选单"
				  echo "------------------------"
				  read -e -p "请输入你的选择: " sub_choice || return 1

				  case $sub_choice in
					  1)
						  send_stats "创建网络"
						  read -e -p "设置新网络名: " dockernetwork || return 1
						  docker network create $dockernetwork
						  ;;
					  2)
						  send_stats "加入网络"
						  read -e -p "加入网络名: " dockernetwork || return 1
						  read -e -p "那些容器加入该网络（多个容器名请用空格分隔）: " dockernames || return 1

						  for dockername in $dockernames; do
							  docker network connect $dockernetwork $dockername
						  done
						  ;;
					  3)
						  send_stats "加入网络"
						  read -e -p "退出网络名: " dockernetwork || return 1
						  read -e -p "那些容器退出该网络（多个容器名请用空格分隔）: " dockernames || return 1

						  for dockername in $dockernames; do
							  docker network disconnect $dockernetwork $dockername
						  done

						  ;;

					  4)
						  send_stats "删除网络"
						  read -e -p "请输入要删除的网络名: " dockernetwork || return 1
						  docker network rm $dockernetwork
						  ;;

					  0)
						  continue 2
						  ;;
					  *)
						  break  # 跳出循环，退出菜单
						  ;;
				  esac
			  done
			  ;;

		  6)
			  while true; do
				  clear
				  send_stats "Docker卷管理"
				  echo "Docker卷列表"
				  docker volume ls
				  echo ""
				  echo "卷操作"
				  echo "------------------------"
				  echo "1. 创建新卷"
				  echo "2. 删除指定卷"
				  echo "3. 删除所有卷"
				  echo "------------------------"
				  echo "0. 返回上一级选单"
				  echo "------------------------"
				  read -e -p "请输入你的选择: " sub_choice || return 1

				  case $sub_choice in
					  1)
						  send_stats "新建卷"
						  read -e -p "设置新卷名: " dockerjuan || return 1
						  docker volume create $dockerjuan

						  ;;
					  2)
						  read -e -p "输入删除卷名（多个卷名请用空格分隔）: " dockerjuans || return 1

						  for dockerjuan in $dockerjuans; do
							  docker volume rm $dockerjuan
						  done

						  ;;

					   3)
						  send_stats "删除所有卷"
						  read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有未使用的卷吗？(Y/N): ")" choice || return 1
						  case "$choice" in
							[Yy])
							  docker volume prune -f
							  ;;
							[Nn])
							  ;;
							*)
							  echo "无效的选择，请输入 Y 或 N。"
							  ;;
						  esac
						  ;;

					  0)
						  continue 2
						  ;;
					  *)
						  break  # 跳出循环，退出菜单
						  ;;
				  esac
			  done
			  ;;
		  7)
			  clear
			  send_stats "Docker清理"
			  read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}将清理无用的镜像容器网络，包括停止的容器，确定清理吗？(Y/N): ")" choice || return 1
			  case "$choice" in
				[Yy])
				  docker system prune -af --volumes
				  ;;
				[Nn])
				  ;;
				*)
				  echo "无效的选择，请输入 Y 或 N。"
				  ;;
			  esac
			  ;;
		  8)
			  clear
			  send_stats "Docker源"
			  docker_mirror_menu
			  [ "$?" -eq 90 ] && continue
			  ;;

		  9)
			  clear
			  docker_daemon_json_merge __edit__
			  ;;


		  10)
			  docker_compose_auto_update_manager
			  continue
			  ;;



		  11)
			  clear
			  send_stats "Docker v6 开"
			  docker_ipv6_on
			  ;;

		  12)
			  clear
			  send_stats "Docker v6 关"
			  docker_ipv6_off
			  ;;

		  19)
			  docker_ssh_migration
			  continue
			  ;;


		  20)
			  clear
			  send_stats "Docker卸载"
			  read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定卸载docker环境吗？(Y/N): ")" choice || return 1
			  case "$choice" in
				[Yy])
				  docker_uninstall_environment || return 1
				  ;;
				[Nn])
				  ;;
				*)
				  echo "无效的选择，请输入 Y 或 N。"
				  ;;
			  esac
			  ;;

		  0)
			  return
			  ;;
		  *)
			  echo "无效的输入!"
			  ;;
	  esac
	  break_end


	done


}

docker_tato() {
	if ! command -v docker >/dev/null 2>&1; then
		echo "Docker 未安装，可选择 1 安装 Docker 环境。"
		return 0
	fi

	local container_count=$(docker ps -a -q 2>/dev/null | wc -l)
	local image_count=$(docker images -q 2>/dev/null | wc -l)
	local network_count=$(docker network ls -q 2>/dev/null | wc -l)
	local volume_count=$(docker volume ls -q 2>/dev/null | wc -l)

	if command -v docker &> /dev/null; then
		echo -e "${gl_kjlan}------------------------"
		echo -e "${gl_lv}环境已经安装${gl_bai}  容器: ${gl_lv}$container_count${gl_bai}  镜像: ${gl_lv}$image_count${gl_bai}  网络: ${gl_lv}$network_count${gl_bai}  卷: ${gl_lv}$volume_count${gl_bai}"
	fi
}
