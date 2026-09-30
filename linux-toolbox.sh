#!/bin/bash
DAIMON_NAME="linux-tools-daimon"
# DAIMON_MODULAR_BOOTSTRAP=1

case "${1:-}" in
    ssh-confirm|ssh-rollback)
        [ "$#" -eq 2 ] || { echo "用法: d $1 TOKEN" >&2; exit 1; }
        exec /usr/bin/python3 -I - "${1#ssh-}" "$2" <<'PYSSH_CONFIRM'
import os, re, stat, sys
from pathlib import Path
try:
    if os.geteuid() != 0 or not re.fullmatch(r'[a-f0-9]{32}', sys.argv[2]):
        raise ValueError('Root and a valid transaction token are required')
    worker = Path('/var/lib/daimon/ssh-change/worker.py')
    if worker.resolve() != worker:
        raise ValueError('Untrusted SSH recovery path')
    for parent in worker.parents:
        info = parent.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Untrusted SSH recovery directory')
    info = worker.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o022:
        raise ValueError('Untrusted SSH recovery worker')
    os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', str(worker), *sys.argv[1:]])
except (OSError, ValueError) as error:
    print('ERROR: ' + str(error), file=sys.stderr)
    sys.exit(1)
PYSSH_CONFIRM
        ;;
esac

daimon_bootstrap_dependency() {
    local tool="$1" package="$2"
    command -v "$tool" >/dev/null 2>&1 && return 0
    echo "需要 $tool，正在安装 $package..." >&2
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update &&
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "$package" || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package" || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add "$package" || return 1
    else
        echo "无法自动安装 $package，未覆盖原脚本。" >&2
        return 1
    fi
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool 安装后仍不可用。" >&2; return 1; }
}

daimon_bootstrap_manager() (
    umask 077
    local temporary country revision metadata url expected worker action="${1:-update}"
    revision="${DAIMON_UPDATE_REVISION:-master}"
    [[ "$revision" = master || "$revision" =~ ^[a-f0-9]{40}$ ]] || return 1
    temporary=$(mktemp -d) || return 1
    trap 'rm -f -- "$temporary/ref.json" "$temporary/package.py"; rmdir -- "$temporary"' EXIT
    country=$(curl -fsSL --connect-timeout 3 --max-time 5 https://ipinfo.io/json 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("country", ""))' 2>/dev/null || true)
    if [ "$revision" = master ]; then
        metadata="https://api.github.com/repos/daimon3332/linux-tools-daimon/git/ref/heads/master"
        local -a endpoints=("$metadata" "https://gh-proxy.com/$metadata" "https://ghproxy.net/$metadata")
        [ "$country" != CN ] || endpoints=("https://gh-proxy.com/$metadata" "https://ghproxy.net/$metadata" "$metadata")
        for url in "${endpoints[@]}"; do
            echo "获取版本: $url" >&2
            if curl -fsSL --connect-timeout 8 --max-time 25 "$url" -o "$temporary/ref.json"; then
                revision=$(python3 -c 'import json,re,sys; x=json.load(open(sys.argv[1]))["object"]; assert x["type"]=="commit" and re.fullmatch("[a-f0-9]{40}",x["sha"]); print(x["sha"])' "$temporary/ref.json" 2>/dev/null) && break
            fi
        done
        [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo "无法确定完整版本，未修改已安装脚本。" >&2; return 1; }
    fi
    worker="https://raw.githubusercontent.com/daimon3332/linux-tools-daimon/$revision/scripts/lib/package.py"
    local -a urls=("$worker" "https://gh-proxy.com/$worker" "https://ghproxy.net/$worker" "https://ghfast.top/$worker")
    [ "$country" != CN ] || urls=("https://gh-proxy.com/$worker" "https://ghproxy.net/$worker" "https://ghfast.top/$worker" "$worker")
    for url in "${urls[@]}"; do
        echo "获取完整版本安装器: $url" >&2
        if curl -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$temporary/package.py" &&
            python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$temporary/package.py"; then
            python3 "$temporary/package.py" "$action" "$revision" || return 1
            return 0
        fi
    done
    echo "无法获取完整组件安装器，未覆盖已安装版本。" >&2
    return 1
)

if [ "${1:-}" = --definitions ] && [ -f "$(dirname -- "${BASH_SOURCE[0]}")/runtime.json" ]; then
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lib/entry.sh" --definitions
fi
[ "$(id -u)" = 0 ] || { echo "请以 root 身份运行工具箱。" >&2; exit 1; }
daimon_bootstrap_dependency python3 python3 || exit 1
daimon_bootstrap_dependency curl curl || exit 1
export DAIMON_RUNTIME_ROOT="${DAIMON_RUNTIME_ROOT:-/root/linux-daimon}"
manager="$DAIMON_RUNTIME_ROOT/current/scripts/lib/package.py"
if [ "${1:-}" = --package-update ] || [ "${1:-}" = --package-stage ]; then
    action=update
    [ "$1" != --package-stage ] || action=stage
    shift
    if [ -f "$manager" ]; then
        python3 "$manager" "$action" "${1:-master}" || exit 1
    else
        export DAIMON_UPDATE_REVISION="${1:-master}"
        daimon_bootstrap_manager "$action" || exit 1
    fi
    exit 0
fi
if [ ! -f "$manager" ]; then
    daimon_bootstrap_manager || exit 1
fi
case "${1:-}" in
    --package-status) exec python3 "$manager" status ;;
esac
release=$(python3 "$manager" run) || exit 1
exec bash "$release/scripts/lib/entry.sh" "$@"
