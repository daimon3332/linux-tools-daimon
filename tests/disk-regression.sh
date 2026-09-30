#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$ROOT/.tmp"
SOURCE=$(mktemp "$ROOT/.tmp/test-source.XXXXXX") || exit 1
"${PYTHON_BIN:-python3}" "$ROOT/tests/source.py" "$ROOT" > "$SOURCE" || exit 1
trap 'rm -f -- "$SOURCE"' EXIT
load() {
    local body
    body=$(awk -v name="$1" '$0 == name "() {" {active=1} active {print} active && $0 == "}" {exit}' "$SOURCE")
    [ -n "$body" ] && eval "$body"
}
load format_partition && load check_partition || exit 1
load disk_partition_unmounted || true
send_stats() { :; }
root_use() { :; }
function [() {
    if [[ "${1:-}" = -b ]]; then [[ "$2" = /dev/sda1 ]]; return; fi
    builtin [ "$@"
}
lsblk() {
    [ "${QUERY_FAIL:-0}" = 0 ] || return 1
    case "$*" in
        '-o NAME') printf 'NAME\nsda1\n' ;;
        *MOUNTPOINT*) printf '%s\n' "${MOUNTS:-}" ;;
        *) return 1 ;;
    esac
}
mkfs.ext4() { CALLED=1; return "${FORMAT_RC:-0}"; }
fsck() { CHECK_ARGS="$*"; return "${CHECK_RC:-0}"; }
check() {
    local label="$1"; shift
    if ( "$@" ); then printf 'PASS %s\n' "$label"; else printf 'FAIL %s\n' "$label"; failed=$((failed+1)); fi
}
mounted() {
    local MOUNTS=/var/lib/docker CALLED=0
    format_partition <<< $'sda1\n1\ny' >/dev/null
    [ "$CALLED" = 0 ]
}
invalid() {
    local CALLED=0
    ! format_partition <<< $'../sda1\n1\ny' >/dev/null && [ "$CALLED" = 0 ]
}
query_failure() {
    local QUERY_FAIL=1 CALLED=0
    ! format_partition <<< $'sda1\n1\ny' >/dev/null && [ "$CALLED" = 0 ]
}
cancel() {
    local CALLED=0
    format_partition <<< $'sda1\n1\nn' >/dev/null && [ "$CALLED" = 0 ]
}
failed_format() {
    local FORMAT_RC=1 CALLED=0
    ! format_partition <<< $'sda1\n1\ny' >/dev/null && [ "$CALLED" = 1 ]
}
successful_format() {
    local CALLED=0
    format_partition <<< $'sda1\n1\ny' >/dev/null && [ "$CALLED" = 1 ]
}
mounted_check() {
    local MOUNTS=/ CHECK_ARGS=''
    ! check_partition <<< sda1 >/dev/null && [ -z "$CHECK_ARGS" ]
}
readonly_check() {
    local CHECK_ARGS=''
    check_partition <<< sda1 >/dev/null && [[ "$CHECK_ARGS" == '-n /dev/sda1' ]]
}
failed=0
check 'mounted partition never reaches formatter' mounted
check 'invalid device name rejected' invalid
check 'device query failure is closed' query_failure
check 'cancel never reaches formatter' cancel
check 'format failure returns failure' failed_format
check 'unmounted confirmed partition reaches formatter' successful_format
check 'mounted filesystem is not checked' mounted_check
check 'filesystem status check is read-only' readonly_check
printf '%s failed\n' "$failed"
[ "$failed" = 0 ]
