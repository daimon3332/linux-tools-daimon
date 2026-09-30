#!/bin/bash

daimon_preferences_load() {
    local values
    values=$(python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" settings) || return 1
    while IFS='=' read -r key value; do
        value=${value#\"}; value=${value%\"}
        case "$key" in canshu|permission_granted|ENABLE_STATS) printf -v "$key" '%s' "$value" ;; *) return 1 ;; esac
    done <<< "$values"
}

daimon_preference_set() {
    python3 "$DAIMON_RELEASE_DIR/scripts/lib/package.py" setting "$1" "$2" || return 1
    printf -v "$1" '%s' "$2"
}

daimon_initialize() {
    mkdir -p "$DAIMON_SCRIPT_DIR" "$DAIMON_BACKUP_DIR" "$DAIMON_BACKUP_SH_DIR" "$DAIMON_TOOLS_DIR" "$DAIMON_DOCKER_COMPOSE_UPDATE_DIR" || return 1
    daimon_migrate_runtime_layout || return 1
    daimon_preferences_load || return 1
    quanju_canshu
    if [ "$permission_granted" != true ]; then
        UserLicenseAgreement
    fi
}
