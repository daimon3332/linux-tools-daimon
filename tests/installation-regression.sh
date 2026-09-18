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
update_source() {
    load daimon_download_update_file || return 1
    local DAIMON_UPDATE_URL=https://stale.example/toolbox.sh
    local DAIMON_UPDATE_GITHUB_URL=https://raw.githubusercontent.com/owner/repo/master/linux-toolbox.sh
    daimon_update_fallback_url() { echo "$DAIMON_UPDATE_GITHUB_URL"; }
    daimon_try_download_url() { [ "$1" = "$DAIMON_UPDATE_GITHUB_URL" ] || exit 91; }
    daimon_validate_update_file() { :; }
    daimon_download_update_file unused
}
apt_indexes_preserved() {
    load "$1" || return 1
    root_use() { :; }; install() { :; }; daimon_download_to() { :; }
    chmod() { :; }; daimon_url() { echo https://example.test/; }
    command() { [ "${1:-}" = -v ] && [ "${2:-}" = apt ] || [ "${1:-}" = install ]; }
    local body
    body=$(declare -f "$1")
    body=${body//\/etc\/apt\/sources.list.d\/yazi.list/\/dev\/null}
    body=${body//\/etc\/apt\/sources.list.d\/nexttrace.sources/\/dev\/null}
    eval "$body"
    apt-get() {
        if [ "$1" = update ]; then
            [[ " $* " == *' APT::Get::List-Cleanup=0 '* ]] || return 92
        fi
    }
    yazi() { :; }; ya() { :; }; nexttrace() { :; }
    "$1"
}
system_python_preserved() {
    load remove_python_312_all || return 1
    update-alternatives() { :; }; rm() { :; }
    command() { [ "$1" = -v ] && printf '/usr/bin/%s\n' "$2"; }
    readlink() { echo /usr/bin/python3.12; }
    function [() {
        if [[ "${1:-}:${2:-}" = -x:/usr/bin/python3.12 ]]; then return 0; fi
        builtin [ "$@"
    }
    remove() { exit 91; }
    remove_python_312_all
}
settings_preserved() {
    load "$1" || return 1
    function [() {
        if [[ "${1:-}:${2:-}" = '!:-e' && "${3:-}" = */.claude/settings.json ]]; then return 1; fi
        if [[ "${1:-}:${2:-}" = '!:-e' && "${3:-}" = */.codex/config.toml ]]; then return 1; fi
        if [[ "${1:-}" = -e && "${2:-}" = */.claude/settings.json ]]; then return 0; fi
        if [[ "${1:-}" = -e && "${2:-}" = */.codex/config.toml ]]; then return 0; fi
        builtin [ "$@"
    }
    mkdir() { exit 91; }
    "$1"
}
proxy_first_no_sigpipe() {
    load daimon_url || return 1
    daimon_github_url_candidates() {
        echo https://first.example/file
        local n
        for ((n=0;n<5000;n++)); do echo https://next.example/file; done
    }
    local result
    result=$(daimon_url unused) || return 1
    [ "$result" = https://first.example/file ]
}
for fn in install_yazi_griffo install_nexttrace configure_blesh configure_starship configure_fzf; do
    check "$fn stops on dependency failure" dependency_failure "$fn"
done
for id in tree ripgrep fd; do check "$id preserves package failure" package_failure "$id"; done
for country in CN HK SG JP; do check "$country download routing" region "$country"; done
check 'updates prefer the canonical repository over a stale mirror' update_source
check 'Yazi repository refresh preserves other package indexes' apt_indexes_preserved install_yazi_griffo
check 'NextTrace repository refresh preserves other package indexes' apt_indexes_preserved install_nexttrace
check 'Python removal preserves the operating system interpreter' system_python_preserved
check 'Claude installation preserves existing settings' settings_preserved configure_claude_code_settings
check 'Codex installation preserves existing settings' settings_preserved configure_codex_settings
check 'proxy selection drains candidates under pipefail' proxy_first_no_sigpipe
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
