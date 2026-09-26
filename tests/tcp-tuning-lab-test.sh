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

candidate=$(daimon_tcp_lab_candidate 200 150 2)
[ "$candidate" = 9597152 ]
candidate=$(daimon_tcp_lab_candidate 200 150 4)
[ "$candidate" = 16777216 ]
if daimon_tcp_lab_candidate 1 50 2 >/dev/null; then
    echo 'floor candidate must not rewrite current 4 MiB ceiling' >&2
    exit 1
fi

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

echo 'PASS TCP candidate bounds, duplicate skip and stage contract'
