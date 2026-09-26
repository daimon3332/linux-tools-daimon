#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tcp-tuning-lab.sh"
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/tcp-interaction.XXXXXX") || exit 1
trap 'case "$WORK" in "$ROOT"/.tmp/tcp-interaction.*) rm -rf -- "$WORK" ;; esac' EXIT
load() { eval "$(sed -n "/^$1() {/,/^}/p" "$ROOT/linux-toolbox.sh")"; }
for fn in daimon_tcp_fw_open daimon_tcp_family_speed_block daimon_tcp_lab_menu_family daimon_tcp_lab_load daimon_tcp_public_ips; do
    load "$fn" || exit 1
done
passed=0 failed=0
check() {
    if ( "$2" ) > "$WORK/output" 2>&1; then echo "PASS $1"; passed=$((passed+1))
    else echo "FAIL $1"; cat "$WORK/output"; failed=$((failed+1)); fi
}
ipv6_rule_missing() {
    command() {
        if [ "$1" = -v ]; then
            case "$2" in iptables|ip6tables) return 0 ;; ufw|firewall-cmd|nft) return 1 ;; esac
        fi
        builtin command "$@"
    }
    iptables() { [ "$1" = -C ]; }
    ip6tables() { [ "$1" != -C ] || return 1; echo added > "$WORK/ipv6-rule"; }
    daimon_tcp_fw_persist() { :; }
    daimon_tcp_fw_open 50280 both || return 1
    [ -s "$WORK/ipv6-rule" ]
}
ufw_failure() {
    command() { if [ "$1" = -v ] && [ "$2" = ufw ]; then return 0; fi; builtin command "$@"; }
    ufw() { [ "$1" = status ] || return 1; echo 'Status: active'; }
    ! daimon_tcp_fw_open 50280 both
}
history_not_comparable() {
    DAIMON_TCP_FAMILY_RECORD="$WORK/family.conf"
    printf '4=100 100 0 %s old A client\n6=300 100 0 %s new A client\n' "$(date +%s)" "$(date +%s)" > "$DAIMON_TCP_FAMILY_RECORD"
    local output
    output=$(daimon_tcp_family_speed_block)
    [[ "$output" == *'不是同一会话'* ]] && [[ "$output" != *'节点优先用'* ]]
}
history_comparable() {
    DAIMON_TCP_FAMILY_RECORD="$WORK/paired.conf"
    gl_lv='' gl_bai=''
    printf '4=100 100 0 %s pair A client\n6=300 100 0 %s pair A client\n' "$(date +%s)" "$(date +%s)" > "$DAIMON_TCP_FAMILY_RECORD"
    local output
    output=$(daimon_tcp_family_speed_block)
    [[ "$output" == *'IPv6 更快'* ]]
}
family_back() {
    local status=0
    daimon_tcp_lab_menu_family tune <<< 0 || status=$?
    [ "$status" = 2 ]
}
prerequisite_failure() {
    DAIMON_TCP_STATE_DIR="$WORK/deps"
    command() { if [ "$1" = -v ] && [ "$2" = iperf3 ]; then return 1; fi; builtin command "$@"; }
    install() { echo "$1" > "$WORK/dependency"; return 1; }
    daimon_download_to() { echo unexpected > "$WORK/downloaded"; }
    ! daimon_tcp_lab_load && [ "$(cat "$WORK/dependency")" = iperf3 ] && [ ! -e "$WORK/downloaded" ]
}
empty_nft_ruleset() {
    command() {
        if [ "$1" = -v ]; then
            case "$2" in nft) return 0 ;; ufw|firewall-cmd|iptables) return 1 ;; esac
        fi
        builtin command "$@"
    }
    command -v python >/dev/null 2>&1 && python3() { command python "$@"; }
    nft() { printf '{"nftables":[{"chain":{"family":"ip","table":"filter","name":"INPUT","hook":"input","policy":"%s"}}]}\n' "$POLICY"; }
    POLICY=accept
    daimon_tcp_fw_open 50280 6 || return 1
    POLICY=drop
    ! daimon_tcp_fw_open 50280 6
}
ipv6_preference_retains_ipv4() {
    ip_address() { ipv4_address='2001:db8::1'; ipv6_address='2001:db8::1'; }
    ip() { :; }
    curl() { [ "$1" = -4 ] && echo 198.51.100.17; }
    local values
    values=$(daimon_tcp_public_ips) || return 1
    [[ "$values" == *198.51.100.17* ]] && [[ "$values" == *2001:db8::1* ]]
}
control_rule_is_family_scoped() {
    local prefix="${1:-::/0}" family="${2:-6}" marker="$WORK/control-rule"
    command() { if [ "$1" = -v ] && [ "$2" = ufw ]; then return 0; fi; builtin command "$@"; }
    ufw() {
        [ "$1" != --force ] || shift
        case "$1" in
            status)
                printf 'Status: active\n'
                if [ "$family" = 6 ]; then
                    printf '50281/tcp ALLOW Anywhere\n'
                    [ ! -f "$marker" ] || printf '50281/tcp (v6) ALLOW Anywhere (v6)\n'
                else
                    printf '50281/tcp (v6) ALLOW Anywhere (v6)\n'
                    [ ! -f "$marker" ] || printf '50281/tcp ALLOW Anywhere\n'
                fi
                ;;
            allow)
                [[ "$*" == "allow proto tcp from $prefix to $prefix port 50281" ]] || return 1
                touch "$marker"
                ;;
            delete)
                [[ "$*" == "delete allow proto tcp from $prefix to $prefix port 50281" ]] || return 1
                rm -f "$marker"
                ;;
        esac
        return 0
    }
    daimon_tcp_lab_control_open 50281 "$family" || return 1
    [ -f "$marker" ] || return 1
    daimon_tcp_lab_control_close 50281 || return 1
    [ ! -f "$marker" ]
}
control_ipv4_rule_is_scoped() { control_rule_is_family_scoped 0.0.0.0/0 4; }
check 'existing IPv4 rule still adds missing IPv6 rule' ipv6_rule_missing
check 'UFW allow failure propagates' ufw_failure
check 'different sessions do not recommend a protocol' history_not_comparable
check 'paired history can recommend the faster family' history_comparable
check 'protocol zero returns without an operation' family_back
check 'missing iperf installation failure stops component load' prerequisite_failure
check 'empty accept-policy nft tables do not block testing' empty_nft_ruleset
check 'IPv6-preferred discovery still obtains a real IPv4 endpoint' ipv6_preference_retains_ipv4
check 'IPv6 control rule is added and removed without deleting existing IPv4' control_rule_is_family_scoped
check 'IPv4 control rule preserves the existing IPv6 rule' control_ipv4_rule_is_scoped
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
