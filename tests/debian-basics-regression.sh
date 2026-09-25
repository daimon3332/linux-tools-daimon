#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DAIMON_TEST_SOURCE:-$ROOT/linux-toolbox.sh}
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/debian-basics.XXXXXX") || exit 1
trap 'case "$WORK" in "$ROOT"/.tmp/debian-basics.*) rm -rf -- "$WORK" ;; esac' EXIT

load() {
    local body
    body=$(tr -d '\r' < "$SOURCE" | awk -v name="$1" '
        $0 ~ "^" name "\\(\\) \\{" {active=1}
        active {print}
        active && $0=="}" {exit}
    ')
    [ -n "$body" ] || return 1
    body=${body//\/etc\/os-release/$WORK\/os-release}
    eval "$body"
}

load debian_basics_supported && load debian_basics_install && load debian_basics_menu || { echo 'FAIL missing Debian basics functions'; exit 1; }
break_end() { :; }

dpkg-query() {
    local package="${@: -1}"
    if grep -Fxq "$package" "$WORK/installed" 2>/dev/null; then
        printf 'install ok installed'
    else
        return 1
    fi
}

apt-get() {
    printf '%s\n' "$*" >> "$WORK/apt.calls"
    case "$1" in
        update) [ ! -e "$WORK/fail-update" ] ;;
        install)
            [ ! -e "$WORK/fail-install" ] || return 42
            [[ " $* " == *' --no-install-recommends '* ]] || return 43
            [[ " $* " == *' --no-remove '* ]] || return 44
            local package
            for package in "$@"; do
                case "$package" in
                    ca-certificates|curl|wget|git|jq|python3|gnupg|tar|unzip|openssl|sudo|socat|openssh-client|procps|iproute2|lsof)
                        printf '%s\n' "$package" >> "$WORK/installed" ;;
                esac
            done
            ;;
        *) return 45 ;;
    esac
}

check() {
    local name="$1"; shift
    if ( "$@" ); then echo "PASS $name"; else echo "FAIL $name"; exit 1; fi
}

test_first_and_repeat() {
    local version="$1"
    printf 'ID=debian\nVERSION_ID="%s"\n' "$version" > "$WORK/os-release"
    : > "$WORK/installed"
    : > "$WORK/apt.calls"
    debian_basics_install ca-certificates curl wget git jq python3 || return 1
    [ "$(wc -l < "$WORK/installed")" -eq 6 ] || return 1
    [ "$(grep -c '^update' "$WORK/apt.calls")" -eq 1 ] || return 1
    [ "$(grep -c '^install' "$WORK/apt.calls")" -eq 1 ] || return 1
    debian_basics_install ca-certificates curl wget git jq python3 || return 1
    [ "$(wc -l < "$WORK/apt.calls")" -eq 2 ]
}

test_invalid_and_unsupported() {
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    : > "$WORK/apt.calls"
    ! debian_basics_install curl made-up-package >/dev/null 2>&1 || return 1
    [ ! -s "$WORK/apt.calls" ] || return 1
    printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$WORK/os-release"
    ! debian_basics_install curl >/dev/null 2>&1 || return 1
    [ ! -s "$WORK/apt.calls" ]
}

test_failures() {
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    : > "$WORK/installed"
    touch "$WORK/fail-update"
    ! debian_basics_install curl >/dev/null 2>&1 || return 1
    [ "$(grep -c '^install' "$WORK/apt.calls" || true)" -eq 0 ] || return 1
    rm "$WORK/fail-update"
    touch "$WORK/fail-install"
    ! debian_basics_install curl >/dev/null 2>&1 || return 1
    rm "$WORK/fail-install"
    [ ! -s "$WORK/installed" ]
}

test_menu_selection() {
    printf 'ID=debian\nVERSION_ID=12\n' > "$WORK/os-release"
    : > "$WORK/installed"
    : > "$WORK/apt.calls"
    clear() { :; }
    read() { printf -v "${@: -1}" '1 1 6'; }
    debian_basics_menu || return 1
    [ "$(grep -c '^install' "$WORK/apt.calls")" -eq 1 ] || return 1
    [ "$(wc -l < "$WORK/installed")" -eq 2 ] || return 1
    : > "$WORK/apt.calls"
    read() { printf -v "${@: -1}" '1 nope 6'; }
    ! debian_basics_menu >/dev/null 2>&1 || return 1
    [ ! -s "$WORK/apt.calls" ]
}

test_default_selection() {
    printf 'ID=debian\nVERSION_ID=13\n' > "$WORK/os-release"
    : > "$WORK/installed"
    : > "$WORK/apt.calls"
    clear() { :; }
    read() {
        local arg previous=''
        for arg in "$@"; do
            if [ "$previous" = -i ]; then printf -v "${@: -1}" '%s' "$arg"; return 0; fi
            previous="$arg"
        done
        return 1
    }
    debian_basics_menu || return 1
    [ "$(sort -u "$WORK/installed" | tr '\n' ' ')" = 'ca-certificates curl jq wget ' ] || return 1
    ! grep -Eq '(^|[[:space:]])(git|python3)([[:space:]]|$)' "$WORK/apt.calls"
}

check 'Debian 12 first installation and repeat' test_first_and_repeat 12
check 'Debian 13 first installation and repeat' test_first_and_repeat 13
check 'unknown package and non-Debian reject before APT' test_invalid_and_unsupported
check 'APT failures propagate without claiming success' test_failures
check 'menu validates and deduplicates selection before APT' test_menu_selection
check 'default selection omits git and python3' test_default_selection
