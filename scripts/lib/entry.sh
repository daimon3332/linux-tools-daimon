#!/bin/bash

daimon_boot_value() {
    [ "${DAIMON_BOOT%%$'\n'*}" = "$DAIMON_RELEASE_DIR" ] || return 1
    printf '%s\n' "$DAIMON_BOOT" | sed -n "s/^$1=//p"
}

daimon_load_modules() {
    local module modules
    modules=$(daimon_boot_value module) && [ -n "$modules" ] ||
        modules=$(python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" modules "$DAIMON_RELEASE_DIR") || return 1
    while IFS= read -r module; do
        [[ "$module" =~ ^scripts/[A-Za-z0-9_/.-]+\.sh$ && "$module" != *..* ]] || return 1
        source "$DAIMON_RELEASE_DIR/$module" || return 1
    done <<< "$modules"
}

DAIMON_RELEASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
daimon_load_modules || exit 1
if [ "${1:-}" = --definitions ]; then
    exit 0
fi
if [ "${1:-}" = --migrate-backups ]; then
    crontab_sync_upgrade_installed
    exit $?
fi
daimon_initialize || exit 1
daimon_dispatch "$@"
