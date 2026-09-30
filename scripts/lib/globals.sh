#!/bin/bash

sh_v="1.0.0"

gl_hui='\e[37m'

gl_hong='\033[31m'

gl_lv='\033[32m'

gl_huang='\033[33m'

gl_lan='\033[34m'

gl_bai='\033[0m'

gl_zi='\033[35m'

gl_kjlan='\033[96m'

canshu="default"

permission_granted="false"

ENABLE_STATS="false"

DAIMON_NAME="linux-tools-daimon"

DAIMON_BIN="d"

DAIMON_ROOT_DIR="${DAIMON_RUNTIME_ROOT:-/root/linux-daimon}"

DAIMON_SCRIPT_DIR="$DAIMON_ROOT_DIR/daimon"

DAIMON_BACKUP_DIR="$DAIMON_ROOT_DIR/backup"

DAIMON_BACKUP_SH_DIR="$DAIMON_ROOT_DIR/backup-sh"

DAIMON_TOOLS_DIR="$DAIMON_ROOT_DIR/tools"

DAIMON_FZF_DIR="$DAIMON_TOOLS_DIR/fzf"

DAIMON_DOCKER_COMPOSE_UPDATE_DIR="$DAIMON_ROOT_DIR/docker-compose-update"

DAIMON_UPDATE_URL="https://daimon-linux-scripts.333186.xyz/linux-toolbox.sh"

DAIMON_UPDATE_GITHUB_URL="https://raw.githubusercontent.com/daimon3332/linux-tools-daimon/master/linux-toolbox.sh"

DAIMON_UPDATE_GITHUB_PROXY_URL="https://gh-proxy.com/raw.githubusercontent.com/daimon3332/linux-tools-daimon/master/linux-toolbox.sh"

DAIMON_LOCAL_SCRIPT="$DAIMON_ROOT_DIR/linux-toolbox.sh"

DAIMON_OLD_LOCAL_SCRIPT="$DAIMON_ROOT_DIR/daimon.sh"

DAIMON_REPO_URL="https://github.com/daimon3332/linux-tools-daimon"

DAIMON_AGREEMENT_URL="https://github.com/daimon3332/linux-tools-daimon/blob/master/docx/USER_AGREEMENT.md"

DAIMON_GITHUB_PROXY_PRIMARY="https://gh-proxy.com/"

DAIMON_CERT_HELPER_MARKER="$DAIMON_ROOT_DIR/.update-cert-helper"

DAIMON_BBR_FQ_CONF="/etc/sysctl.d/99-daimon-bbr-fq.conf"

DAIMON_NETWORK_OPTIMIZE_CONF="/etc/sysctl.d/99-daimon-network-optimize.conf"

DAIMON_NETWORK_LEGACY_CONF="/etc/sysctl.d/99-network-optimize.conf"

DAIMON_TCP_TUNING_CONF="/etc/sysctl.d/zzzz-daimon-tcp-tuning.conf"

DAIMON_TCP_BBR_CONF="${DAIMON_BBR_FQ_CONF:-/etc/sysctl.d/99-daimon-bbr-fq.conf}"

DAIMON_TCP_STATE_DIR="${DAIMON_ROOT_DIR:-/root/linux-daimon}/tcp-tuning"

DAIMON_TCP_SNAPSHOT="$DAIMON_TCP_STATE_DIR/runtime-snapshot.conf"

DAIMON_TCP_PROFILE="$DAIMON_TCP_STATE_DIR/profile.json"

DAIMON_TCP_MEASURE_RESULT="$DAIMON_TCP_STATE_DIR/last-measure.conf"

DAIMON_TCP_BEFORE_RESULT="$DAIMON_TCP_STATE_DIR/before-measure.conf"

DAIMON_TCP_FAMILY_RECORD="$DAIMON_TCP_STATE_DIR/family-speed.conf"

DAIMON_TCP_MANAGED_KEYS=(
	net.core.default_qdisc
	net.ipv4.tcp_congestion_control
	net.core.rmem_max
	net.core.wmem_max
	net.core.rmem_default
	net.core.wmem_default
	net.ipv4.tcp_rmem
	net.ipv4.tcp_wmem
	net.ipv4.tcp_mem
	net.ipv4.tcp_limit_output_bytes
	net.ipv4.tcp_window_scaling
	net.ipv4.tcp_moderate_rcvbuf
	net.ipv4.tcp_adv_win_scale
	net.core.netdev_max_backlog
	net.ipv4.tcp_max_syn_backlog
	net.ipv4.tcp_slow_start_after_idle
	net.ipv4.tcp_mtu_probing
	net.ipv4.tcp_fastopen
	net.ipv4.tcp_fin_timeout
	net.ipv4.tcp_tw_reuse
	net.core.somaxconn
	net.ipv4.ip_local_port_range
	fs.file-max
	vm.swappiness
)

DAIMON_TCP_FW_METHOD=""

DAIMON_TCP_IPERF_PID=""

DAIMON_TCP_RTT_SAMPLES=""
