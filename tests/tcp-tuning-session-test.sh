#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/tcp-session.XXXXXX") || exit 1
trap 'case "$WORK" in "$ROOT"/.tmp/tcp-session.*) rm -rf -- "$WORK" ;; esac' EXIT
source "$ROOT/tcp-tuning-lab.sh"
PYTHON_BIN=python3
command -v python >/dev/null 2>&1 && PYTHON_BIN=python
passed=0 failed=0 skipped=0
check() {
    if ( "$2" ) > "$WORK/output" 2>&1; then
        echo "PASS $1"; passed=$((passed + 1))
    else
        if [ "$?" = 77 ]; then echo "SKIP $1 (Linux flock required)"; skipped=$((skipped + 1)); return; fi
        echo "FAIL $1"; cat "$WORK/output"; failed=$((failed + 1))
    fi
}
fixture() {
    DAIMON_TCP_STATE_DIR="$WORK/$1"
    DAIMON_TCP_LAB_DIR="$DAIMON_TCP_STATE_DIR/session.fixture"
    mkdir -p "$DAIMON_TCP_LAB_DIR"
    DAIMON_TCP_LAB_FAMILIES=4
    DAIMON_TCP_LAB_TCP_WMEM='4096 16384 33554432'
    DAIMON_TCP_LAB_WMEM=33554432
    DAIMON_TCP_SNAPSHOT="$DAIMON_TCP_STATE_DIR/runtime-snapshot.conf"
    DAIMON_TCP_LAB_COMMITTED=0
    DAIMON_TCP_LAB_CAPTURED=1
    DAIMON_TCP_LAB_CONTROL_OPEN=0
    DAIMON_TCP_LAB_HELPER_PID=""
    DAIMON_TCP_LAB_IPERF_PID=""
    DAIMON_TCP_LAB_FILES_CHANGED=0
    DAIMON_TCP_LAB_TX_START=0
    DAIMON_TCP_LAB_BUDGET=20000000000
    DAIMON_TCP_LAB_DURATION=12
    DAIMON_TCP_LAB_OMIT=2
    DAIMON_TCP_LAB_OUTCOME=restore
    DAIMON_TCP_LAB_MESSAGE='Original profile retained'
    CEILING=33554432
    printf 'net.core.wmem_max = 33554432\n' > "$DAIMON_TCP_LAB_DIR/runtime.conf"
    daimon_tcp_ram_mb() { echo 2048; }
    daimon_tcp_lab_candidate_list() { echo '4597152 67108864'; }
    daimon_tcp_lab_current_ceiling() { echo 33554432; }
    daimon_tcp_lab_tx_bytes() { echo 0; }
    daimon_tcp_read_key() { echo "$CEILING"; }
    daimon_tcp_write_key() { CEILING="$2"; }
    daimon_tcp_record_family() { :; }
    daimon_tcp_lab_profile_round() {
        local label="$1"
        if [ "$label" = A ]; then CEILING=33554432; else CEILING="$2"; fi
        printf '%s\t4\t100\t0\t100000000\t100\n' "$label" >> "$DAIMON_TCP_LAB_DIR/records.tsv"
    }
    daimon_tcp_lab_score() {
        if [ "$1" = choose ]; then
            echo '{"status":"candidate","profile":"B1","ceiling":4597152}'
        else
            printf '{"status":"%s"}\n' "$VERDICT"
        fi
    }
    daimon_tcp_lab_finish() { :; }
    daimon_tcp_lab_persist() { :; }
    daimon_tcp_snapshot() { printf '%s\n' "$CEILING" > "$DAIMON_TCP_SNAPSHOT"; }
    python3() { command python "$@"; }
    command -v python >/dev/null 2>&1 || unset -f python3
}
rejected_winner_restores() {
    fixture rejection
    VERDICT=restore
    daimon_tcp_lab_execute tune || return 1
    daimon_tcp_lab_cleanup 0 || return 1
    [ "$CEILING" = 33554432 ]
}
original_snapshot() {
    fixture snapshot
    VERDICT=keep
    daimon_tcp_lab_execute tune || return 1
    grep -q '33554432' "$DAIMON_TCP_SNAPSHOT"
}
candidate_gate() {
    daimon_tcp_ram_mb() { echo 2048; }
    DAIMON_TCP_LAB_TCP_WMEM='4096 16384 8388608'
    DAIMON_TCP_LAB_WMEM=8388608
    local values
    values=$(daimon_tcp_lab_candidate_list 190 164) || return 1
    [[ " $values " == *' 17677152 '* ]]
}
signal_restores() {
    command -v flock >/dev/null 2>&1 || return 77
    DAIMON_TCP_STATE_DIR="$WORK/signal"
    mkdir -p "$DAIMON_TCP_STATE_DIR"
    daimon_tcp_lab_run_inner() {
        fixture signal
        CURRENT="$DAIMON_TCP_STATE_DIR/live"
        daimon_tcp_write_key() { printf '%s\n' "$2" > "$CURRENT"; }
        daimon_tcp_read_key() { cat "$CURRENT"; }
        daimon_tcp_write_key net.core.wmem_max 4597152
        kill -TERM "$BASHPID"
    }
    local rc=0
    daimon_tcp_lab_run tune 4 || rc=$?
    [ "$rc" = 143 ] && [ "$(cat "$WORK/signal/live")" = 33554432 ]
}
concurrent_run_rejected() {
    command -v flock >/dev/null 2>&1 || return 77
    DAIMON_TCP_STATE_DIR="$WORK/locked"
    mkdir -p "$DAIMON_TCP_STATE_DIR"
    exec 8>"$DAIMON_TCP_STATE_DIR/session.lock"
    flock -n 8 || return 1
    daimon_tcp_lab_run_inner() { echo unexpected > "$WORK/unexpected"; }
    if daimon_tcp_lab_run tune 4; then return 1; fi
    [ ! -e "$WORK/unexpected" ]
}
budget_reserves_confirmation() {
    fixture budget
    printf 'A\t4\t1000\t0\t100000000\t100\n' > "$DAIMON_TCP_LAB_DIR/records.tsv"
    daimon_tcp_lab_tx_bytes() { echo 17000000000; }
    ! daimon_tcp_lab_can_afford 4
}
actual_score_keeps_or_restores() {
    fixture actual-score
    B_CALLS=0
    daimon_tcp_lab_profile_round() {
        local rate=100
        if [ "$1" != A ]; then
            CEILING="$2"
            if [ "$1" = B1 ]; then B_CALLS=$((B_CALLS+1)); rate=140; else rate=110; fi
            if [ "$B_CALLS" -gt 1 ] && [ "$SLOW_CONFIRM" = 1 ] && [ "$1" = B1 ]; then rate=97; fi
        else CEILING=33554432; fi
        printf '%s\t4\t%s\t0\t100000000\t100\n' "$1" "$rate" >> "$DAIMON_TCP_LAB_DIR/records.tsv"
    }
    daimon_tcp_lab_score() {
        command "$PYTHON_BIN" "$ROOT/tcp-tuning-score.py" "$1" "$DAIMON_TCP_LAB_DIR/records.tsv" 4 "$2" "${3:-}"
    }
    local real_round real_score
    real_round=$(declare -f daimon_tcp_lab_profile_round)
    real_score=$(declare -f daimon_tcp_lab_score)
    SLOW_CONFIRM=0
    daimon_tcp_lab_execute tune || return 1
    [ "$DAIMON_TCP_LAB_COMMITTED" = 1 ] && [ "$B_CALLS" = 3 ] || return 1
    fixture actual-reject
    eval "$real_round"
    eval "$real_score"
    B_CALLS=0; SLOW_CONFIRM=1
    daimon_tcp_lab_execute tune || return 1
    [ "$DAIMON_TCP_LAB_COMMITTED" = 0 ] && [ "$CEILING" = 33554432 ]
}
report_retained_ceiling() {
    fixture report
    DAIMON_TCP_PROFILE="$DAIMON_TCP_STATE_DIR/profile.json"
    DAIMON_TCP_LAB_WINNING_CEILING=0
    printf 'A\t4\t100\t0\t100000000\t100\n' > "$DAIMON_TCP_LAB_DIR/records.tsv"
    daimon_tcp_lab_save_report 0 || return 1
    local report="$DAIMON_TCP_PROFILE"
    command -v cygpath >/dev/null 2>&1 && report=$(cygpath -w "$report")
    command "$PYTHON_BIN" -c 'import json,sys; assert json.load(open(sys.argv[1]))["ceiling_bytes"] == 33554432' "$report"
}
budget_stops_active_round() {
    fixture active-budget
    DAIMON_TCP_LAB_IP4=127.0.0.1
    DAIMON_TCP_LAB_IP6=''
    DAIMON_TCP_LAB_PORT=50280
    DAIMON_TCP_LAB_ROUND=0
    DAIMON_TCP_LAB_WAIT=10
    iperf3() { exec sleep 30; }
    daimon_tcp_lab_budget_used() { echo 20000000000; }
    if daimon_tcp_lab_round B1 4; then return 1; fi
    [ -z "$DAIMON_TCP_LAB_IPERF_PID" ] && [ -z "$(jobs -pr)" ]
}
check 'rejected confirmation restores original runtime' rejected_winner_restores
check 'accepted winner snapshots the original runtime' original_snapshot
check 'near 2x-BDP still explores distinct 4x-BDP' candidate_gate
check 'TERM restores the original runtime and returns failure' signal_restores
check 'concurrent sessions cannot touch the same profile' concurrent_run_rejected
check 'traffic budget reserves independent confirmation' budget_reserves_confirmation
check 'real A/B/A scorer accepts gains and rejects slower confirmations' actual_score_keeps_or_restores
check 'restored report includes the retained original ceiling' report_retained_ceiling
check 'budget stop terminates only the active benchmark process' budget_stops_active_round
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
