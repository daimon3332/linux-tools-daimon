#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$ROOT/.tmp"
SOURCE=$(mktemp "$ROOT/.tmp/test-source.XXXXXX") || exit 1
"${PYTHON_BIN:-python3}" "$ROOT/tests/source.py" "$ROOT" > "$SOURCE" || exit 1
trap 'rm -f -- "$SOURCE"' EXIT
bash -n "$SOURCE" || exit 1
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/docker-migration.XXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -f -- "$SOURCE"; case "$WORK" in "$ROOT"/.tmp/docker-migration.*) command rm -rf -- "$WORK" ;; esac' EXIT
mkdir -p "$WORK/docker_backup_fixture/child" "$WORK/unrelated"
load() {
    local body
    body=$(awk -v name="$1" '
        $0 ~ "^[[:space:]]*" name "\\(\\) \\{" {
            active=1; match($0,/[^[:space:]]/); indent=substr($0,1,RSTART-1)
        }
        active {print}
        active && $0 == indent "}" {exit}
    ' "$SOURCE")
    # Remap only the fixed backup root; never touch the host /tmp or Docker.
    [ -n "$body" ] && eval "${body//\/tmp/\$WORK}"
}
for name in docker_migration_delete_backup docker_migration_migrate docker_migration_restore; do
    load "$name" || exit 1
done
load docker_migration_backup_dir || true
send_stats() { :; }
install() { SIDE_EFFECT=1; return 0; }
install_docker() { SIDE_EFFECT=1; return 0; }
docker() { SIDE_EFFECT=1; return 0; }
rm() { REMOVED="$*"; return "${REMOVE_RC:-0}"; }
scp() { COPIED="$*"; return "${COPY_RC:-0}"; }
kj_ssh_read_host_user_port() { return "${INPUT_RC:-0}"; }
gl_hong='' gl_bai='' gl_kjlan='' gl_lv='' gl_huang=''
KJ_SSH_HOST=192.0.2.1 KJ_SSH_PORT=2222 KJ_SSH_USER=root TARGET_PASS=''
passed=0 failed=0 skipped=0
check() {
    local label="$1"; shift
    if ( "$@" ) > "$WORK/result" 2>&1; then
        echo "PASS $label"; passed=$((passed+1))
    else
        echo "FAIL $label"; cat "$WORK/result"; failed=$((failed+1))
    fi
}
reject() {
    local handler="$1" path="$2" REMOVED='' COPIED='' SIDE_EFFECT=0
    ! "$handler" <<< "$path"$'\ny' && [ -z "$REMOVED$COPIED" ] && [ "$SIDE_EFFECT" = 0 ]
}
for handler in docker_migration_delete_backup docker_migration_migrate docker_migration_restore; do
    for suffix in docker_backup_fixture/../unrelated docker_backup_fixture/child docker_backup_fixture/.. unrelated missing ''; do
        check "$handler rejects $suffix" reject "$handler" "$WORK/$suffix"
    done
done
if ln -s "$WORK/unrelated" "$WORK/docker_backup_link" 2>/dev/null && [ -L "$WORK/docker_backup_link" ]; then
    for handler in docker_migration_delete_backup docker_migration_migrate docker_migration_restore; do
        check "$handler rejects symlink" reject "$handler" "$WORK/docker_backup_link"
    done
else
    echo 'SKIP symlink cases: filesystem does not support symlinks'; skipped=$((skipped+3))
fi
delete_success() {
    local REMOVED=''
    docker_migration_delete_backup <<< "$WORK/docker_backup_fixture"$'\ny' &&
        [[ "$REMOVED" == *"$WORK/docker_backup_fixture" ]]
}
delete_cancel() {
    local REMOVED=''
    docker_migration_delete_backup <<< "$WORK/docker_backup_fixture"$'\nn' && [ -z "$REMOVED" ]
}
delete_failure() {
    local REMOVE_RC=42
    ! docker_migration_delete_backup <<< "$WORK/docker_backup_fixture"$'\ny'
}
migrate_cancel() {
    local INPUT_RC=1 COPIED=''
    ! docker_migration_migrate <<< "$WORK/docker_backup_fixture" && [ -z "$COPIED" ]
}
migrate_failure() {
    local COPY_RC=42
    ! docker_migration_migrate <<< "$WORK/docker_backup_fixture"
}
migrate_ipv6() {
    local KJ_SSH_HOST=2001:db8::1 COPIED=''
    docker_migration_migrate <<< "$WORK/docker_backup_fixture" &&
        [[ "$COPIED" == *"root@[2001:db8::1]:$WORK/" ]]
}
migrate_stale_password() {
    local TARGET_PASS=unrelated COPIED=''
    docker_migration_migrate <<< "$WORK/docker_backup_fixture" && [ -n "$COPIED" ]
}
check 'confirmed deletion calls remover' delete_success
check 'cancel does not delete' delete_cancel
check 'removal failure propagates' delete_failure
check 'SSH input cancellation never transfers' migrate_cancel
check 'transfer failure propagates' migrate_failure
check 'IPv6 scp destination is bracketed' migrate_ipv6
check 'unrelated password variable cannot suppress migration' migrate_stale_password
printf '%s passed; %s failed; %s skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" = 0 ]
