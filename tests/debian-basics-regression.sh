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
        $0 ~ "^[[:space:]]*" name "\\(\\) [({]" {active=1; match($0,/[^[:space:]]/); indent=substr($0,1,RSTART-1); closing=($0~/\($/?")":"}")}
        active {print}
        active && $0==indent closing {exit}')
    [ -n "$body" ] || return 1
    body=${body//\/etc\/os-release/$WORK\/os-release}
    eval "$body"
}
load daimon_is_debian && load debian_basics_install && load debian_basics_menu || { echo FAIL_MISSING_FUNCTIONS; exit 1; }
break_end() { :; }
dpkg-query() {
    local package="${@: -1}"
    grep -Fxq "$package" "$WORK/installed" 2>/dev/null && printf 'install ok installed' || return 1
}
apt-get() {
    printf '%s\n' "$*" >> "$WORK/apt.calls"
    case "$1" in
        update) [ ! -e "$WORK/fail-update" ] ;;
        install)
            [ ! -e "$WORK/fail-install" ] || return 42
            [[ " $* " == *' --no-install-recommends '* && " $* " == *' --no-remove '* ]] || return 43
            local package
            for package in "$@"; do
                case "$package" in ca-certificates|curl|wget|jq) printf '%s\n' "$package" >> "$WORK/installed" ;; esac
            done ;;
        *) return 44 ;;
    esac
}
check() { if "$@"; then echo "PASS $1"; else echo "FAIL $1"; exit 1; fi; }
test_install_repeat() {
    printf 'ID=debian\nVERSION_ID=generic\n' > "$WORK/os-release"
    : > "$WORK/installed"; : > "$WORK/apt.calls"
    debian_basics_install ca-certificates curl wget jq || return 1
    [ "$(wc -l < "$WORK/installed")" -eq 4 ] || return 1
    [ "$(grep -c '^update' "$WORK/apt.calls")" -eq 1 ] || return 1
    [ "$(grep -c '^install' "$WORK/apt.calls")" -eq 1 ] || return 1
    ! grep -Eq ' (git|python3)( |$)' "$WORK/apt.calls" || return 1
    debian_basics_install ca-certificates curl wget jq || return 1
    [ "$(wc -l < "$WORK/apt.calls")" -eq 2 ]
}
test_reject() {
    printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$WORK/os-release"
    ! daimon_is_debian || return 1
    : > "$WORK/apt.calls"
    ! debian_basics_install curl >/dev/null 2>&1 || return 1
    [ ! -s "$WORK/apt.calls" ] || return 1
    printf 'ID=debian\nVERSION_ID=generic\n' > "$WORK/os-release"
    ! debian_basics_install git >/dev/null 2>&1 || return 1
    [ ! -s "$WORK/apt.calls" ]
}
test_menu() {
    printf 'ID=debian\nVERSION_ID=generic\n' > "$WORK/os-release"
    : > "$WORK/installed"; : > "$WORK/apt.calls"
    clear() { :; }
    read() { printf -v "${@: -1}" ''; }
    debian_basics_menu || return 1
    [ "$(sort -u "$WORK/installed" | tr '\n' ' ')" = 'ca-certificates curl jq wget ' ] || return 1
    ! grep -Eq ' (git|python3)( |$)' "$WORK/apt.calls"
}
test_all_installed() {
    printf 'ID=debian\nVERSION_ID=generic\n' > "$WORK/os-release"
    printf '%s\n' ca-certificates curl wget jq > "$WORK/installed"; : > "$WORK/apt.calls"
    read() { return 99; }
    debian_basics_menu || return 1
    [ ! -s "$WORK/apt.calls" ]
}
test_failures() {
    printf 'ID=debian\nVERSION_ID=generic\n' > "$WORK/os-release"
    : > "$WORK/installed"; : > "$WORK/apt.calls"; touch "$WORK/fail-update"
    ! debian_basics_install jq >/dev/null 2>&1 || return 1
    [ "$(grep -c '^install' "$WORK/apt.calls" || true)" -eq 0 ] || return 1
    rm "$WORK/fail-update"; touch "$WORK/fail-install"
    ! debian_basics_install jq >/dev/null 2>&1 || return 1
    rm "$WORK/fail-install"
    [ ! -s "$WORK/installed" ]
}
for test in test_install_repeat test_reject test_menu test_all_installed test_failures; do
    check "$test"
done
