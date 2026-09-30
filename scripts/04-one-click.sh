#!/bin/bash

daimon_network_verify_bbr_fq() {
	[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] &&
		[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] &&
		daimon_network_verify_active_fq
}

daimon_network_verify_active_fq() {
	local interfaces iface queues
	daimon_require_cmd tc >&2 || return 1
	interfaces=$({ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null |
		awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
	[ -n "$interfaces" ] || { echo "没有默认路由，无法验证实际队列。" >&2; return 1; }
	for iface in $interfaces; do
		queues=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
		if ! printf '%s\n' "$queues" | awk '
			$1 == "qdisc" && $2 != "ingress" && $2 != "clsact" {
				if ($0 ~ / root([[:space:]]|$)/) root=$2
				if ($0 ~ / parent /) {leaves++; if($2!="fq") other++}
			}
			END {exit !(root=="fq" || (root=="mq" && leaves>0 && other==0))}
		'; then
			echo "网卡 $iface 的实际队列不是 fq / mq+fq；未覆盖现有队列，请先确认队列配置。" >&2
			return 1
		fi
	done
}

daimon_network_show_other_bbr_configs() {
	local found
	found=$(grep -HnE '^[[:space:]]*net\.(ipv4\.tcp_congestion_control|core\.default_qdisc)[[:space:]]*=' \
		/etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | grep -vF "$DAIMON_BBR_FQ_CONF:" || true)
	if [ -n "$found" ]; then
		echo -e "${gl_huang}检测到其他 BBR/队列配置来源，请确认没有冲突：${gl_bai}"
		printf '%s\n' "$found"
	fi
}

daimon_network_enable_bbr_fq() {
	local tmp old_conf="" old_cc old_qdisc rollback_failed=0
	if ! daimon_network_bbr_supported; then
		echo -e "${gl_hong}当前内核不支持 BBR，未写入任何 BBR/FQ 配置。${gl_bai}"
		echo "请进入主菜单 13 的 BBR 管理，明确选择并安装适合当前系统的内核。"
		return 2
	fi
	daimon_network_verify_active_fq || return 1

	old_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || return 1
	old_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
	mkdir -p /etc/sysctl.d || return 1
	tmp=$(mktemp) || return 1
	if [ -f "$DAIMON_BBR_FQ_CONF" ]; then
		old_conf=$(mktemp) || { rm -f "$tmp"; return 1; }
		cp -a "$DAIMON_BBR_FQ_CONF" "$old_conf" || { rm -f "$tmp" "$old_conf"; return 1; }
	fi
	cat > "$tmp" <<'EOF'
# linux-tools-daimon BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
	if command install -m 644 "$tmp" "$DAIMON_BBR_FQ_CONF" &&
		sysctl -p "$DAIMON_BBR_FQ_CONF" >/dev/null 2>&1 && daimon_network_verify_bbr_fq &&
		{ [ "${DAIMON_NETWORK_DEFER_PERSIST:-0}" = 1 ] || daimon_network_persist "$DAIMON_BBR_FQ_CONF" "$DAIMON_NETWORK_OPTIMIZE_CONF"; }; then
		rm -f "$tmp" "$old_conf"
		return 0
	fi
	rm -f "$tmp"

	if [ -n "$old_conf" ]; then
		cp -a "$old_conf" "$DAIMON_BBR_FQ_CONF" || rollback_failed=1
	else
		rm -f "$DAIMON_BBR_FQ_CONF" || rollback_failed=1
	fi
	sysctl -w "net.core.default_qdisc=$old_qdisc" "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null || rollback_failed=1
	[ "$(sysctl -n net.core.default_qdisc)" = "$old_qdisc" ] || rollback_failed=1
	[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "$old_cc" ] || rollback_failed=1
	if [ "$rollback_failed" -eq 0 ]; then
		rm -f "$old_conf"
		echo -e "${gl_hong}BBR + FQ 验证失败，原配置和运行态已恢复。${gl_bai}"
	else
		echo -e "${gl_hong}BBR + FQ 回滚不完整；原配置备份: ${old_conf:-无}；原算法: $old_cc；原队列: $old_qdisc${gl_bai}"
	fi
	daimon_network_show_other_bbr_configs
	return 1
}

one_click_enable_bbr_fq() {
	root_use
	local status
	daimon_network_enable_bbr_fq
	status=$?
	[ "$status" -eq 0 ] || return "$status"
	echo -e "${gl_lv}已开启 BBR + FQ 加速${gl_bai}"
	sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
}

one_click_install_docker_auto() {
	root_use
	if command -v docker >/dev/null 2>&1; then
		if docker --version && docker compose version && docker info >/dev/null 2>&1; then
			echo "Docker 与 Compose 已可用，保留现有安装和配置。"
			return 0
		fi
		echo "检测到已有 Docker，但服务或 Compose 不可用；请先修复，不自动卸载现有安装。"
		return 1
	fi
	install curl || return 1
	local country mirror
	country=$(daimon_country)
	if [ "$country" = "CN" ]; then
		mirror=1
		echo "检测到国家/地区: CN，使用国内 Docker 镜像源（阿里云，失败切清华/官方）"
	else
		mirror=2
		echo "检测到国家/地区: ${country:-未知}，使用 Docker 官方源"
	fi

	mkdir -p "$DAIMON_SCRIPT_DIR" || return 1
	cat > "$DAIMON_SCRIPT_DIR/install-docker-auto.sh" <<'EOF' || return 1
#!/bin/bash
set -eo pipefail
MIRROR=${1:-2}
DOCKER_OFFICIAL="https://download.docker.com"
ALIYUN_MIRROR="https://mirrors.aliyun.com/docker-ce"
TUNA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
if [ "$MIRROR" = "1" ]; then
    DOWNLOAD_URL="$ALIYUN_MIRROR"
    BACKUP_URL="$TUNA_MIRROR"
    echo "使用镜像: 阿里云 (备用: 清华)"
else
    DOWNLOAD_URL="$DOCKER_OFFICIAL"
    BACKUP_URL=""
    echo "使用镜像: Docker官方"
fi
if [ "$(id -u)" != "0" ]; then SUDO="sudo"; else SUDO=""; fi
cleanup_old() {
    echo "清理旧版本..."
    case "$DISTRO" in
        ubuntu|debian|raspbian) $SUDO apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true ;;
        centos|rhel|rocky|almalinux) $SUDO yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true ;;
        fedora) $SUDO dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine 2>/dev/null || true ;;
    esac
}
detect_distro() {
    if [ -r /etc/os-release ]; then . /etc/os-release; DISTRO=$ID; DISTRO_VERSION=$VERSION_ID
    elif [ -r /etc/debian_version ]; then DISTRO="debian"; DISTRO_VERSION=$(cat /etc/debian_version)
    elif [ -r /etc/redhat-release ]; then DISTRO="centos"
    else echo "无法检测系统"; exit 1; fi
}
get_debian_codename() {
    case "$1" in
        ubuntu) case "$DISTRO_VERSION" in 24.04) echo noble ;; 23.10) echo mantic ;; 23.04) echo lunar ;; 22.04) echo jammy ;; 20.04) echo focal ;; 18.04) echo bionic ;; *) lsb_release -cs 2>/dev/null || echo jammy ;; esac ;;
        debian|raspbian) case "${DISTRO_VERSION%%.*}" in 13) echo trixie ;; 12) echo bookworm ;; 11) echo bullseye ;; 10) echo buster ;; *) echo bookworm ;; esac ;;
    esac
}
test_url() { curl -fsSL --connect-timeout 5 "$1" >/dev/null 2>&1; }
select_mirror() {
    local gpg_path="linux/ubuntu/gpg"
    [ "$DISTRO" = "debian" ] || [ "$DISTRO" = "raspbian" ] && gpg_path="linux/debian/gpg"
    if test_url "$DOWNLOAD_URL/$gpg_path"; then echo "镜像源可用: $DOWNLOAD_URL"; return 0
    elif [ -n "$BACKUP_URL" ] && test_url "$BACKUP_URL/$gpg_path"; then echo "主镜像不可用，切换到备用源: $BACKUP_URL"; DOWNLOAD_URL="$BACKUP_URL"; return 0
    elif [ "$MIRROR" = "1" ]; then echo "国内镜像均不可用，切换到官方源"; DOWNLOAD_URL="$DOCKER_OFFICIAL"; return 0
    else echo "无法连接到镜像源"; return 1; fi
}
install_debian() {
    local codename=$(get_debian_codename "$DISTRO") repo_distro="$DISTRO"
    [ "$DISTRO" = "raspbian" ] && repo_distro="debian"
    echo "系统: $DISTRO $DISTRO_VERSION ($codename)"
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt update -y || true
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$DOWNLOAD_URL/linux/$repo_distro/gpg" | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOWNLOAD_URL/linux/$repo_distro $codename stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
install_rhel() {
    echo "系统: $DISTRO $DISTRO_VERSION"
    $SUDO yum install -y yum-utils
    $SUDO yum-config-manager --add-repo "$DOWNLOAD_URL/linux/centos/docker-ce.repo"
    [ "$DOWNLOAD_URL" != "$DOCKER_OFFICIAL" ] && $SUDO sed -i "s|https://download.docker.com|$DOWNLOAD_URL|g" /etc/yum.repos.d/docker-ce.repo
    $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
install_fedora() {
    echo "系统: Fedora $DISTRO_VERSION"
    $SUDO dnf install -y dnf-plugins-core
    $SUDO dnf config-manager --add-repo "$DOWNLOAD_URL/linux/fedora/docker-ce.repo"
    [ "$DOWNLOAD_URL" != "$DOCKER_OFFICIAL" ] && $SUDO sed -i "s|https://download.docker.com|$DOWNLOAD_URL|g" /etc/yum.repos.d/docker-ce.repo
    $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
start_docker() { if command -v systemctl >/dev/null 2>&1; then $SUDO systemctl enable docker; $SUDO systemctl start docker; fi; }
show_result() { echo; echo "========================================"; echo "Docker 安装完成!"; echo "========================================"; docker --version; docker compose version; }
main() {
    detect_distro
    cleanup_old
    select_mirror
    case "$DISTRO" in
        ubuntu|debian|raspbian) install_debian ;;
        centos|rhel|rocky|almalinux) install_rhel ;;
        fedora) install_fedora ;;
        *) echo "不支持的系统: $DISTRO"; exit 1 ;;
    esac
    start_docker
    show_result
}
main
EOF
	chmod +x "$DAIMON_SCRIPT_DIR/install-docker-auto.sh" || return 1
	bash "$DAIMON_SCRIPT_DIR/install-docker-auto.sh" "$mirror" || return 1
	if [ "$country" = CN ] && [ ! -e /etc/docker/daemon.json ]; then
		install_add_docker_cn || return 1
	fi
	docker --version && docker compose version && docker info >/dev/null 2>&1
}

one_click_network_auto_optimize() {
	one_click_enable_bbr_fq || return 1
	echo "已保留 BBR + FQ；缓冲参数请到主菜单 21「网络自适应优化」按本地 iperf3 实测后再应用。"
}

one_click_auto_dns_optimize() {
	root_use
	local country
	country=$(daimon_country)
	if [ "$country" = "CN" ]; then
		local dns1_ipv4="223.5.5.5"
		local dns2_ipv4="119.29.29.29"
		local dns1_ipv6="2400:3200::1"
		local dns2_ipv6="2402:4e00::"
		echo "检测到国家/地区: CN，自动使用国内 DNS 优化"
		set_dns || return 1
	else
		local dns1_ipv4="1.1.1.1"
		local dns2_ipv4="8.8.8.8"
		local dns1_ipv6="2606:4700:4700::1111"
		local dns2_ipv6="2001:4860:4860::8888"
		echo "检测到国家/地区: ${country:-未知}，自动使用国外 DNS 优化"
		set_dns || return 1
	fi
}

one_click_set_timezone_locale() {
	root_use
	set_timedate Asia/Shanghai || return 1
	update_locale "en_US.UTF-8" "en_US.UTF-8" false || return 1
	echo "已设置时区为 Asia/Shanghai，本地语言为 en_US.UTF-8"
}

one_click_config_manager() {
	local sub_choice
	one_click_config_run_item() {
		export DEBIAN_FRONTEND=noninteractive
		export NEEDRESTART_MODE=a
		export APT_LISTCHANGES_FRONTEND=none
		case "$1" in
			2) linux_update ;;
			3) linux_clean ;;
			4) add_swap 1024 ;;
			5) one_click_auto_dns_optimize ;;
			6) one_click_enable_bbr_fq ;;
			7) one_click_install_docker_auto ;;
			8) one_click_network_auto_optimize ;;
			9) linux_tools thirdparty-install-all ;;
			10) one_click_set_timezone_locale ;;
			*) echo "无效配置编号: $1"; return 1 ;;
		esac
	}

	one_click_config_run_all() {
		local nums n DAIMON_DEFER_SHELL_RESTART=1 DAIMON_BATCH_MODE=1
		local -a selected=() succeeded=() failed=()
		export DEBIAN_FRONTEND=noninteractive
		export NEEDRESTART_MODE=a
		export APT_LISTCHANGES_FRONTEND=none
		nums="${1:-2 3 4 5 6 7 8 9 10}"
		if [ "$#" -eq 0 ]; then
			read -e -i "$nums" -p "请确认/修改要执行的配置编号（默认全选，空格分隔）: " nums || return 1
		fi
		if [ -z "${nums//[[:space:]]/}" ] || [ "$nums" = 0 ]; then
			echo "未选择任何配置项"
			return
		fi
		for n in $nums; do
			if ! [[ "$n" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$n))" -lt 2 ] || [ "$((10#$n))" -gt 10 ]; then
				echo "无效配置编号: $n；未执行任何配置"
				return 1
			fi
			n=$((10#$n))
			[[ " ${selected[*]} " == *" $n "* ]] || selected+=("$n")
		done
		for n in "${selected[@]}"; do
			echo "正在执行配置项: $n"
			if one_click_config_run_item "$n"; then
				succeeded+=("$n")
			else
				failed+=("$n")
				echo "配置项 $n 执行失败，继续后续配置"
			fi
		done
		echo "成功配置项: ${succeeded[*]:-无}"
		if [ "${#failed[@]}" -gt 0 ]; then
			echo "失败配置项: ${failed[*]}；请根据上方错误重试"
		else
			echo "全部配置成功"
		fi
		echo "配置流程结束，正在使用 exec bash 重新进入命令行..."
		hash -r
		exec bash
		return 1
	}

	while true; do
		clear
		echo "一键配置"
		echo "------------------------"
		echo -e "${gl_kjlan}1.   ${gl_bai}配置全部（默认回车，执行前可删减编号）"
		echo -e "${gl_kjlan}2.   ${gl_bai}系统更新"
		echo -e "${gl_kjlan}3.   ${gl_bai}系统清理"
		echo -e "${gl_kjlan}4.   ${gl_bai}设置虚拟内存 1G"
		echo -e "${gl_kjlan}5.   ${gl_bai}优化 DNS 地址"
		echo -e "${gl_kjlan}6.   ${gl_bai}开启 BBR 加速（BBR + FQ）"
		echo -e "${gl_kjlan}7.   ${gl_bai}安装 Docker（自动判断国内/国外源）"
		echo -e "${gl_kjlan}8.   ${gl_bai}网络优化：开启 BBR + FQ（缓冲参数到主菜单 21 实测调优）"
		echo -e "${gl_kjlan}9.   ${gl_bai}安装第三方工具（全部安装，可在第三方工具菜单精细调整）"
		echo -e "${gl_kjlan}10.  ${gl_bai}修改时区和本地语言（Asia/Shanghai + en_US.UTF-8）"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		echo "------------------------"
		read -e -p "请输入你的选择（默认 1 配置全部）: " sub_choice || return 1
		case "$sub_choice" in
			""|1) one_click_config_run_all; continue ;;
			9) one_click_config_run_all 9; continue ;;
			2|3|4|5|6|7|8|10) one_click_config_run_item "$sub_choice" || echo "配置项 $sub_choice 执行失败" ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}
