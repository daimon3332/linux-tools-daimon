#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DAIMON_TEST_SOURCE:-$ROOT/linux-toolbox.sh}
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/debian-compat.XXXXXX") || exit 1
trap 'case "$WORK" in "$ROOT"/.tmp/debian-compat.*) rm -rf -- "$WORK" ;; esac' EXIT

load() {
    local body
    body=$(tr -d '\r' < "$SOURCE" | awk -v name="$1" '
        $0 ~ "^[[:space:]]*" name "\\(\\) [({]" {
            active=1; match($0,/[^[:space:]]/); indent=substr($0,1,RSTART-1)
            closing=($0~/\($/?")":"}")
        }
        active {print}
        active && $0==indent closing {exit}')
    [ -n "$body" ] || return 1
    body=${body//\/etc\/os-release/$WORK\/os-release}
    body=${body//\/etc\/fail2ban/$WORK\/fail2ban}
    body=${body//\/var\/log\/auth.log/$WORK\/missing-auth.log}
    body=${body//\/var\/log\/secure/$WORK\/missing-secure}
    eval "$body"
}

root_use() { :; }
clear() { :; }
break_end() { :; }
send_stats() { :; }
gl_lv='' gl_bai='' gl_hui=''

test_python_uses_debian_default() {
    load install_python_312 && load remove_python_312_all || return 1
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    : > "$WORK/calls"
    command() {
        if [ "$1" = -v ] && [ "$2" = apt ]; then return 0; fi
        builtin command "$@"
    }
    apt() { :; }
    apt-cache() { return 1; }
    add-apt-repository() { echo UNSAFE_PPA >> "$WORK/calls"; return 73; }
    install() { echo "INSTALL:$*" >> "$WORK/calls"; return 0; }
    python3() { echo 'Python 3.13.0'; }
    update-alternatives() { echo UNSAFE_ALTERNATIVES >> "$WORK/calls"; return 73; }
    remove() { echo UNSAFE_REMOVE >> "$WORK/calls"; return 73; }
    install_python_312 || return 1
    remove_python_312_all || return 1
    grep -Fxq 'INSTALL:python3 python3-venv python3-pip' "$WORK/calls" || return 1
    ! grep -Eq 'UNSAFE_|python3.12' "$WORK/calls"
}

test_journald_sshd_jail() {
    load debian_basics_supported && load fail2ban_auth_logpath && load fail2ban_write_sshd_jail || return 1
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    install() { echo "INSTALL:$*" >> "$WORK/calls"; }
    : > "$WORK/calls"
    F2B_JAIL="$WORK/fail2ban/jail.local"
    fail2ban_write_sshd_jail 22 >/dev/null || return 1
    grep -qx 'backend = systemd' "$F2B_JAIL" || return 1
    ! grep -Eq '^logpath = ' "$F2B_JAIL" || return 1
    grep -Fxq 'INSTALL:python3-systemd' "$WORK/calls"
}

test_basic_config_journald() {
    load debian_basics_supported && load f2b_basic_config || return 1
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    install() { :; }
    command() {
        if [ "$1" = -v ] && [ "$2" = fail2ban-client ]; then return 0; fi
        builtin command "$@"
    }
    read() { printf -v "${@: -1}" ''; }
    fail2ban-client() { :; }
    sleep() { :; }
    f2b_basic_config >/dev/null || return 1
    grep -qx 'backend = systemd' "$WORK/fail2ban/jail.d/sshd.local" || return 1
    ! grep -Eq '^logpath = ' "$WORK/fail2ban/jail.d/sshd.local"
}

for test in test_python_uses_debian_default test_journald_sshd_jail test_basic_config_journald; do
    if ( "$test" ); then echo "PASS $test"; else echo "FAIL $test"; exit 1; fi
done
