#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/tcp-lab.XXXXXX")
trap 'case "$WORK" in "$ROOT"/.tmp/tcp-lab.*) rm -rf -- "$WORK" ;; esac' EXIT
source "$ROOT/tcp-tuning-lab.sh"

DAIMON_TCP_STATE_DIR="$WORK"
DAIMON_TCP_LAB_DIR="$WORK/session"
DAIMON_TCP_LAB_PORT=50280
DAIMON_TCP_LAB_DURATION=12
DAIMON_TCP_LAB_OMIT=2
DAIMON_TCP_LAB_TCP_WMEM='4096 16384 4194304'
DAIMON_TCP_LAB_WMEM=4194304
mkdir "$DAIMON_TCP_LAB_DIR"
daimon_tcp_ram_mb() { echo 512; }

# 现有上限低于 BDP 目标：上调阶梯
list=$(daimon_tcp_lab_candidate_list 200 150)
[ "$list" = '9597152 16777216' ]
list=$(daimon_tcp_lab_candidate_list 1 50)
[ "$list" = '8388608' ]

DAIMON_TCP_LAB_TCP_WMEM='4096 16384 33554432'
DAIMON_TCP_LAB_WMEM=33554432
list=$(daimon_tcp_lab_candidate_list 190 164)
[ "$list" = '9887152 16777216' ]

DAIMON_TCP_LAB_TCP_WMEM='4096 16384 8388608'
DAIMON_TCP_LAB_WMEM=8388608
list=$(daimon_tcp_lab_candidate_list 190 164)
[ "$list" = '4194304 16777216' ]

# 对半值与 BDP 目标接近：只保留目标候选
DAIMON_TCP_LAB_TCP_WMEM='4096 16384 20971520'
DAIMON_TCP_LAB_WMEM=20971520
list=$(daimon_tcp_lab_candidate_list 190 164)
[ "$list" = '9887152' ]

daimon_tcp_ram_mb() { echo 4096; }
DAIMON_TCP_LAB_TCP_WMEM='4096 16384 134217728'
DAIMON_TCP_LAB_WMEM=134217728
list=$(daimon_tcp_lab_candidate_list 100 100)
[ "$list" = '4597152 67108864 7097152' ]
daimon_tcp_ram_mb() { echo 512; }

daimon_tcp_write_key() { printf '%s' "$2" > "$WORK/key-$1"; }
daimon_tcp_read_key() { cat "$WORK/key-$1" 2>/dev/null; }
printf '33554432' > "$WORK/key-net.core.wmem_max"
printf '4096 16384 33554432' > "$WORK/key-net.ipv4.tcp_wmem"
DAIMON_TCP_LAB_TCP_WMEM='4096 2097152 33554432'
daimon_tcp_lab_apply_ceiling 4194304
[ "$(cat "$WORK/key-net.core.wmem_max")" = 4194304 ]
[ "$(cat "$WORK/key-net.ipv4.tcp_wmem")" = '4096 2097152 4194304' ]
daimon_tcp_lab_apply_ceiling 1048576
[ "$(cat "$WORK/key-net.ipv4.tcp_wmem")" = '4096 1048576 1048576' ]

# 下调获胜后的持久化与重载校验
daimon_network_persist() { cp -f "$1" "$DAIMON_TCP_TUNING_CONF"; }
daimon_network_verify_sysctl_file() { [ -s "$1" ]; }
sysctl() {
    if [ "${1:-}" = --system ]; then
        echo 'Unexpected global sysctl reload' >&2
        return 1
    fi
    local line key value
    while IFS= read -r line; do
        case "$line" in *' = '*)
            key="${line%% = *}"; value="${line##* = }"
            daimon_tcp_write_key "$key" "$value"
            ;;
        esac
    done < "$DAIMON_TCP_TUNING_CONF"
}
DAIMON_TCP_TUNING_CONF="$WORK/99-daimon-tcp.conf"
daimon_tcp_lab_persist 67108864
[ "$(daimon_tcp_read_key net.core.wmem_max)" = 67108864 ]
[ "$(daimon_tcp_read_key net.ipv4.tcp_wmem)" = '4096 2097152 67108864' ]
grep -q '^net.ipv4.tcp_wmem = 4096 2097152 67108864$' "$DAIMON_TCP_TUNING_CONF"

daimon_tcp_lab_stage_json ready 3 6 '2400:c620:22:295::12'
json_path="$DAIMON_TCP_LAB_DIR/stage.json"
command -v cygpath >/dev/null 2>&1 && json_path=$(cygpath -w "$json_path")
python_bin=python3
command -v python >/dev/null 2>&1 && python_bin=python
"$python_bin" - "$json_path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert data['state'] == 'ready'
assert data['family'] == 6
assert data['host'] == '2400:c620:22:295::12'
assert data['id'] == 3
assert data['duration'] == 12
PY

echo 'PASS TCP candidate ladder, ceiling apply and stage contract'
