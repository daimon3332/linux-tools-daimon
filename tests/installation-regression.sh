#!/usr/bin/env bash
set -o pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DAIMON_TEST_SOURCE:-$ROOT/linux-toolbox.sh}
passed=0 failed=0
load() {
    local body
    body=$(tr -d '\r' < "$SOURCE" | awk -v name="$1" '
        $0 ~ "^[[:space:]]*" name "\\(\\) [({]" {
            active=1; match($0,/[^[:space:]]/); indent=substr($0,1,RSTART-1)
            closing=($0~/\($/?")":"}")
        }
        active {print}
        active && $0==indent closing {exit}')
    [ -n "$body" ] && eval "$body"
}
check() {
    local label="$1"; shift
    if ( "$@" ); then echo "PASS $label"; passed=$((passed+1))
    else echo "FAIL $label"; failed=$((failed+1)); fi
}
dependency_failure() {
    load "$1" || return 1
    root_use() { :; }
    install() { return 42; }
    tool_installed() { return 1; }
    command() { [ "${1:-}" = -v ] && [ "${2:-}" = apt ]; }
    # An installer must stop before any download, configuration, or shell restart.
    curl() { exit 91; }; git() { exit 91; }; mkdir() { exit 91; }
    touch() { exit 91; }; rm() { exit 91; }; tee() { exit 91; }
    gpg() { return 0; }; apt() { exit 91; }
    install_tool_by_id() { return 42; }
    ! "$1"
}
package_failure() {
    load install_tool_by_id || return 1
    install() { return 42; }
    configure_fd_alias() { exit 91; }
    ! install_tool_by_id "$1"
}
region() {
    load daimon_country && load daimon_is_cn && load daimon_strip_github_proxy &&
        load daimon_jsdelivr_url && load daimon_github_url_candidates || return 1
    local DAIMON_COUNTRY_CACHE="$1" result
    result=$(daimon_github_url_candidates https://github.com/example/tool/releases/download/v1/tool.zip)
    case "$1" in
        CN) [[ "$result" == https://gh-proxy.com/*$'\n'* ]] ;;
        *) [ "$result" = https://github.com/example/tool/releases/download/v1/tool.zip ] ;;
    esac
}
for fn in install_yazi_griffo install_nexttrace configure_blesh configure_starship configure_fzf; do
    check "$fn stops on dependency failure" dependency_failure "$fn"
done
for id in tree ripgrep fd; do check "$id preserves package failure" package_failure "$id"; done
for country in CN HK SG JP; do check "$country download routing" region "$country"; done
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
