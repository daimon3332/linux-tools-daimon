#!/usr/bin/env bash
set -o pipefail
case "$(uname -s)" in MINGW*|MSYS*) echo 'SKIP: persistence permission tests require Linux/POSIX Python'; exit 77 ;; esac
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DAIMON_TEST_SOURCE:-$ROOT/linux-toolbox.sh}
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/network-persistence.XXXXXX") || exit 1
trap 'case "$WORK" in "$ROOT"/.tmp/network-persistence.*) rm -rf -- "$WORK" ;; esac' EXIT
if ! python3 --version >/dev/null 2>&1; then python3() { python "$@"; }; fi
eval "$(tr -d '\r' < "$SOURCE" | sed -n '/^daimon_network_persist() {/,/^}/p')"
declare -F daimon_network_persist >/dev/null || { echo 'FAIL persistence helper missing'; exit 1; }
passed=0 failed=0
check() {
    if ( "$2" ); then echo "PASS $1"; passed=$((passed+1))
    else echo "FAIL $1"; failed=$((failed+1)); fi
}
fixture() {
    local directory="$WORK/$1"
    mkdir -p "$directory/sysctl.d"
    DAIMON_SYSCTL_CONF="$directory/sysctl.conf"
    DAIMON_NETWORK_PRIORITY_CONF="$directory/sysctl.d/zz-daimon-network.conf"
    bbr="$directory/sysctl.d/99-daimon-bbr-fq.conf"
    network="$directory/sysctl.d/99-daimon-network-optimize.conf"
    printf '# user configuration\nvm.swappiness=0\n' > "$DAIMON_SYSCTL_CONF"
    printf 'net.ipv4.tcp_congestion_control=bbr\n' > "$bbr"
    printf 'vm.swappiness=10\nnet.ipv4.tcp_max_syn_backlog=262144\n' > "$network"
    printf 'net.ipv4.tcp_max_syn_backlog=8192\n' > "$directory/sysctl.d/99-zz-sing-box-daimon.conf"
}
precedence() {
    fixture precedence
    local original
    original=$(cat "$DAIMON_SYSCTL_CONF")
    daimon_network_persist "$bbr" "$network" || return 1
    # Simulate both documented loader orders against the actual generated files.
    local stream value
    for stream in boot reload; do
        value=$({ cat "$WORK/precedence/sysctl.d/"*.conf; [ "$stream" != reload ] || cat "$DAIMON_SYSCTL_CONF"; } |
            awk -F= '/^net.ipv4.tcp_max_syn_backlog[[:space:]]*=/ {v=$2} END {gsub(/ /,"",v); print v}')
        [ "$value" = 262144 ] || return 1
    done
    [ "$(head -n 2 "$DAIMON_SYSCTL_CONF")" = "$original" ]
}
idempotent() {
    fixture repeat
    daimon_network_persist "$bbr" "$network" || return 1
    cp "$DAIMON_SYSCTL_CONF" "$WORK/before"
    daimon_network_persist "$bbr" "$network" || return 1
    cmp -s "$DAIMON_SYSCTL_CONF" "$WORK/before"
}
clear_network() {
    fixture clear
    daimon_network_persist "$bbr" "$network" || return 1
    daimon_network_persist "$bbr" || return 1
    ! grep -q 'swappiness\|max_syn_backlog' "$DAIMON_NETWORK_PRIORITY_CONF" || return 1
    grep -q 'tcp_congestion_control = bbr' "$DAIMON_NETWORK_PRIORITY_CONF" &&
        grep -qx 'vm.swappiness=0' "$DAIMON_SYSCTL_CONF" &&
        ! grep -q 'swappiness = 10' "$DAIMON_SYSCTL_CONF"
}
collision() {
    fixture collision
    printf 'unmanaged\n' > "$DAIMON_NETWORK_PRIORITY_CONF"
    cp "$DAIMON_SYSCTL_CONF" "$WORK/collision-before"
    ! daimon_network_persist "$bbr" "$network" || return 1
    cmp -s "$DAIMON_SYSCTL_CONF" "$WORK/collision-before" &&
        [ "$(cat "$DAIMON_NETWORK_PRIORITY_CONF")" = unmanaged ]
}
malformed() {
    fixture malformed
    printf '# BEGIN daimon network overrides\n' >> "$DAIMON_SYSCTL_CONF"
    cp "$DAIMON_SYSCTL_CONF" "$WORK/malformed-before"
    ! daimon_network_persist "$bbr" "$network" || return 1
    cmp -s "$DAIMON_SYSCTL_CONF" "$WORK/malformed-before" && [ ! -e "$DAIMON_NETWORK_PRIORITY_CONF" ]
}
write_failure() {
    fixture failure
    DAIMON_NETWORK_PRIORITY_CONF="$WORK/missing/zz-daimon-network.conf"
    cp "$DAIMON_SYSCTL_CONF" "$WORK/failure-before"
    ! daimon_network_persist "$bbr" "$network" || return 1
    cmp -s "$DAIMON_SYSCTL_CONF" "$WORK/failure-before"
}
later_conflict() {
    fixture later
    printf 'net/ipv4/tcp_max_syn_backlog = 4096\n' > "$WORK/later/sysctl.d/zzz-custom.conf"
    cp "$DAIMON_SYSCTL_CONF" "$WORK/later-before"
    ! daimon_network_persist "$bbr" "$network" || return 1
    cmp -s "$DAIMON_SYSCTL_CONF" "$WORK/later-before" && [ ! -e "$DAIMON_NETWORK_PRIORITY_CONF" ]
}
check 'boot and reload overrides preserve user configuration' precedence
check 'repeated apply does not duplicate blocks' idempotent
check 'clear removes network overrides while retaining BBR' clear_network
check 'unmanaged priority file cannot be overwritten' collision
check 'malformed blocks are rejected without edits' malformed
check 'staging failure leaves existing configuration unchanged' write_failure
check 'a later external override is rejected before writing' later_conflict
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
