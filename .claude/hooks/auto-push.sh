#!/usr/bin/env bash
# PostToolUse hook: commit + push linux-toolbox.sh after Edit/Write, only if bash -n passes.
set -uo pipefail

REPO="D:/linux-script/daimon"
TARGET="linux-toolbox.sh"

emit() { printf '{"systemMessage":%s}\n' "$(printf '%s' "$1" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; }

FILE=$(python -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
ti=d.get("tool_input") or {}
tr=d.get("tool_response") or {}
p=tr.get("filePath") or ti.get("file_path") or ""
print(p)
' 2>/dev/null)

case "${FILE//\\//}" in
	*linux-toolbox.sh) ;;
	*) exit 0 ;;
esac

cd "$REPO" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git diff --quiet -- "$TARGET" && git diff --cached --quiet -- "$TARGET" && exit 0

if ! ERR=$(bash -n "$TARGET" 2>&1); then
	emit "auto-push skipped: $TARGET has a syntax error, nothing committed. $ERR"
	exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
git add -- "$TARGET" || { emit "auto-push failed: git add"; exit 0; }
git commit -q -m "chore: auto-commit $TARGET" || { emit "auto-push: nothing to commit"; exit 0; }

if PUSH=$(git push origin "$BRANCH" 2>&1); then
	emit "auto-push: committed and pushed $TARGET to origin/$BRANCH"
else
	emit "auto-push: committed locally but push FAILED (run git push manually). $PUSH"
fi
exit 0
