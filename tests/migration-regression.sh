#!/usr/bin/env bash
set -o pipefail
case "$(uname -s)" in MINGW*) export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" ;; esac
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$ROOT/.tmp"
WORK=$(mktemp -d "$ROOT/.tmp/migration.XXXXXX") || exit 1
trap 'case "$(realpath -- "$WORK")" in "$ROOT"/.tmp/migration.*) rm -rf -- "$WORK" ;; esac' EXIT
export TMPDIR="$WORK"
export DAIMON_RCLONE_RUNNER_FILE="$WORK/rclone-runner.sh"
export DAIMON_RCLONE_RUN_LOG_DIR="$WORK/run-logs"
export DAIMON_RCLONE_STATUS_CACHE="$WORK/status.tsv"
export DAIMON_RCLONE_STATUS_LOCK="$WORK/status.lock"
export DAIMON_LOCK_DIR="$WORK/locks"
export DAIMON_RESTORE_ROOT="$WORK/root"
export DAIMON_NGINX_DIR="$WORK/nginx"
mkdir -p "$DAIMON_RESTORE_ROOT" "$DAIMON_NGINX_DIR"
tr -d '\r' < "${DAIMON_TEST_SOURCE:-$ROOT/linux-toolbox.sh}" > "$WORK/source.sh"
SOURCE="$WORK/source.sh"
if ! python3 --version >/dev/null 2>&1; then
    python3() { python "$@" | tr -d '\r'; }
    export -f python3
fi

load_function() {
    local body
    body=$(awk -v name="$1" '
        $0 ~ "^[[:space:]]*" name "\\(\\) [({]" {
            if ($0 ~ /\{.*\}[[:space:]]*$/) {print; exit}
            active=1; match($0,/[^[:space:]]/); indent=substr($0,1,RSTART-1)
            closing=($0 ~ /\($/ ? ")" : "}")
        }
        active {print}
        active && $0 == indent closing {exit}
    ' "$SOURCE")
    [ -n "$body" ] && bash -n <<< "$body" && eval "$body"
}
while IFS= read -r fn; do
    load_function "$fn" || exit 1
done < <(awk '/^rclone_status_text\(\)/ {active=1} /^crontab_sync_backup_dir\(\)/ {active=0}
    active && /^[a-zA-Z_]+\(\) [({]/ {sub(/\(.*/, ""); print}' "$SOURCE")
for fn in crontab_sync_backup_dir crontab_sync_log_cache_file crontab_sync_log_run_dir crontab_sync_log_export_dir crontab_sync_runner_file crontab_sync_write_runner crontab_sync_write_run_tools crontab_sync_log_sanitize crontab_sync_log_copy crontab_sync_log_export crontab_sync_custom_files crontab_sync_root_name; do
    load_function "$fn" || exit 1
done
root_use() { :; }
passed=0 failed=0
check() {
    local name="$1"
    shift
    [[ "$name" == *"${DAIMON_TEST_FILTER:-}"* ]] || return 0
    if ( "$@" ) > "$WORK/test.out" 2>&1; then
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$name"
        cat "$WORK/test.out"
        failed=$((failed + 1))
    fi
}

test_missing_nginx() {
    command() {
        if [[ "$1" = -v && "$2" = nginx ]]; then return 1; fi
        builtin command "$@"
    }
    ! rclone_check_nginx_after_restore
}
test_reload_failure() {
    nginx() { return 0; }
    systemctl() { return 1; }
    ! rclone_check_nginx_after_restore
}
test_link_failure() {
    mkdir() { :; }
    rclone() { printf 'fixture-site\n'; }
    ln() { return 1; }
    ! rclone_rebuild_sites_enabled_links fixture:backup
}
test_no_link_fallback() {
    local output
    mkdir() { :; }
    rclone() { return 1; }
    find() { printf 'disabled-local-site\n'; }
    ln() { printf 'WRONG_SITE_ENABLED\n'; }
    output=$(rclone_rebuild_sites_enabled_links fixture:backup)
    local rc=$?
    [ "$rc" -ne 0 ] && [[ "$output" != *WRONG_SITE_ENABLED* ]]
}
test_names() {
    local input="$1" expected="$2"
    rclone() {
        case "$1" in
            lsd) printf '0 2026-09-08 00:00:00 -1 folder  two  spaces\n'
                for i in {2..9}; do printf '0 2026-09-08 00:00:00 -1 folder%s\n' "$i"; done ;;
            lsjson) printf '[{"Name":"folder  two  spaces","IsDir":true}'
                for i in {2..9}; do printf ',{"Name":"folder%s","IsDir":true}' "$i"; done
                printf ']\n' ;;
            *) return 1 ;;
        esac
    }
    rclone_select_remote_dirs_multi fixture:server fixture <<< "$input" || return 1
    [ "${RCLONE_SELECTED_DIRS[0]}" = "$expected" ]
}
test_error_privacy() {
    local output
    rclone() { printf 'invalid_grant https://fixture.invalid/?tempauth=PRIVATE_FIXTURE\n' >&2; return 1; }
    output=$(rclone_select_remote_dir fixture:server fixture)
    [ "$?" -ne 0 ] && [[ "$output" != *PRIVATE_FIXTURE* ]]
}
test_config_failure() {
    local output
    bitwarden_check_requirements() { :; }
    bitwarden_rclone_conf_file() { printf '%s\n' "$WORK/absent/rclone.conf"; }
    rclone_select_remote() { RCLONE_SELECTED_REMOTE=fixture; }
    rclone_remote_state() { printf 'invalid\n'; }
    rclone() { return 1; }
    docker() { return 1; }
    output=$(bitwarden_configure_rclone_conf)
    [ "$?" -ne 0 ] && [ ! -e "$WORK/absent/rclone.conf" ]
}
test_restore_active_volume() {
    local output
    bitwarden_check_requirements() { :; }
    bitwarden_restore_preflight() { return 1; }
    rclone() { case "$1" in ls) printf '100 backup.20260908.zip\n' ;; *) return 0 ;; esac; }
    docker() { printf 'UNSAFE_RESTORE_EXECUTED\n'; }
    output=$(bitwarden_restore_data <<< $'1\ny')
    [ "$?" -ne 0 ] && [[ "$output" != *UNSAFE_RESTORE_EXECUTED* ]]
}

test_folder_restore() {
    local mode="$1" root="$WORK/folder-$1" input="$WORK/input-$1" rc=0
    mkdir -p "$root/app" "$input"
    printf old > "$root/app/config"
    printf new > "$input/config"
    printf added > "$input/new-file"
    docker() { [ "$1" = ps ]; }
    rclone() {
        case "$1" in
            size) printf '{"bytes":16}\n' ;;
            copy) [ "$mode" != download ] && cp -a "$input/." "$3/" ;;
            check) [ "$mode" != checksum ] ;;
            *) return 1 ;;
        esac
    }
    if [ "$mode" = space ]; then rclone_require_space() { return 1; }; fi
    if [ "$mode" = rename ] || [ "$mode" = concurrent ]; then
        mv() {
            if [[ "$*" = *'/result '* ]]; then
                [ "$mode" != concurrent ] || mkdir -p "${@: -1}"
                return 1
            fi
            command mv "$@"
        }
    fi
    rclone_restore_folder fixture:app "$root" app "${2:-replace}" || rc=$?
    case "$mode" in
        success) [ "$rc" = 0 ] && [ "$(cat "$root/app/config")" = new ] && [ "$(cat "$root/app/new-file")" = added ] ;;
        keep) [ "$rc" = 0 ] && [ "$(cat "$root/app/config")" = old ] && [ "$(cat "$root/app/new-file")" = added ] ;;
        concurrent) [ "$rc" -ne 0 ] && [ "$(cat "$root"/.daimon-restore.*/previous/config)" = old ] ;;
        *) [ "$rc" -ne 0 ] && [ "$(cat "$root/app/config")" = old ] && [ ! -e "$root/app/new-file" ] ;;
    esac
}
test_live_mount_guard() {
    local MSYS2_ARG_CONV_EXCL='*' output
    export MSYS2_ARG_CONV_EXCL
    docker() {
        case "$1" in
            ps) printf 'fixture\n' ;;
            inspect) printf '[{"Name":"/active","Mounts":[{"Source":"/root/service/data"}]}]\n' ;;
            *) return 1 ;;
        esac
    }
    output=$(rclone_assert_inactive /root/service)
    [ "$?" -ne 0 ] && [[ "$output" = *active* ]]
}
test_daemon_guard() {
    docker() { return 1; }
    ! rclone_assert_inactive /root/service
}
test_remote_state() {
    local mode="$1" conf="$WORK/probe.conf"
    printf '[fixture]\ntype = local\n' > "$conf"
    rclone() {
        case "$mode" in
            valid) return 0 ;;
            invalid) echo 'invalid_grant PRIVATE_FIXTURE' >&2; return 1 ;;
            unknown) echo 'network timeout PRIVATE_FIXTURE' >&2; return 1 ;;
        esac
    }
    timeout() { shift; "$@"; }
    [ "$(rclone_remote_state "$conf" fixture:)" = "$mode" ]
}
test_nginx_transaction() {
    local scenario="$1" fixture="$WORK/nginx-$1" backup="$WORK/nginx-$1/source"
    local DAIMON_NGINX_DIR="$fixture/target" DAIMON_DOMAIN_DIR="$fixture/domain"
    mkdir -p "$backup/sites-available" "$backup/domain" "$DAIMON_NGINX_DIR/sites-available" "$DAIMON_NGINX_DIR/sites-enabled"
    printf original > "$DAIMON_NGINX_DIR/sites-available/local-disabled"
    printf incoming > "$backup/sites-available/new-site"
    printf 'new-site\n' > "$backup/enabled_sites.txt"
    rclone_nginx_prepare() { :; }
    rclone_nginx_allow_ports() { :; }
    rclone_assert_inactive() { :; }
    nginx() { [ "$scenario" != invalid ] || [ ! -f "$DAIMON_NGINX_DIR/sites-available/new-site" ]; }
    systemctl() { :; }
    if [ "$scenario" = missing ]; then rm "$backup/enabled_sites.txt"; fi
    if [ "$scenario" = link ]; then ln() { return 1; }; fi
    if [ "$scenario" = relative ]; then
        cp "$backup/sites-available/new-site" "$DAIMON_NGINX_DIR/sites-available/new-site"
        ln -s ../sites-available/new-site "$DAIMON_NGINX_DIR/sites-enabled/new-site" || return 1
    fi
    if [ "$scenario" = stopped ]; then
        systemctl() {
            case "$1" in
                is-active) [ -e "$fixture/running" ] ;;
                start) touch "$fixture/running" ;;
                stop) rm -f "$fixture/running" ;;
                enable) return 1 ;;
                *) return 0 ;;
            esac
        }
    fi
    if [ "$scenario" = success ] || [ "$scenario" = relative ]; then
        rclone_nginx_apply "$backup" all keep || return 1
        rclone_nginx_apply "$backup" all keep || return 1
        [ -L "$DAIMON_NGINX_DIR/sites-enabled/new-site" ] && [ ! -e "$DAIMON_NGINX_DIR/sites-enabled/local-disabled" ]
    else
        ! rclone_nginx_apply "$backup" all keep || return 1
        [ "$scenario" != stopped ] || [ ! -e "$fixture/running" ] || return 1
        [ ! -e "$DAIMON_NGINX_DIR/sites-available/new-site" ] && [ "$(cat "$DAIMON_NGINX_DIR/sites-available/local-disabled")" = original ]
    fi
}
test_compose_state() {
    local mode="$1" rc=0
    rclone_compose_run() {
        shift
        case "$*" in
            'config --format json') printf '{"services":{"app":{}}}\n' ;;
            'config --services') printf 'app\n' ;;
            'ps -a --format json')
                case "$mode" in
                    error) return 1 ;;
                    unhealthy) printf '[{"Service":"app","State":"running","Health":"unhealthy"}]\n' ;;
                    starting) printf '[{"Service":"app","State":"running","Health":"starting"}]\n' ;;
                    healthy) printf '[{"Service":"app","State":"running","Health":"healthy"}]\n' ;;
                esac ;;
        esac
    }
    rclone_compose_status "$WORK" || rc=$?
    case "$mode:$rc" in healthy:0|starting:1|error:2|unhealthy:3) return 0 ;; *) return 1 ;; esac
}
test_compose_missing_bind() {
    rclone_compose_run() {
        shift
        case "$*" in
            'config --format json') printf '{"name":"fixture","services":{"app":{"volumes":[{"type":"bind","source":"/missing-fixture-source"}]}}}\n' ;;
            'config --services') printf 'app\n' ;;
        esac
    }
    docker() { :; }
    ! rclone_compose_preflight "$WORK"
}
test_compose_null_ipam() {
    rclone_compose_run() {
        shift
        case "$*" in
            'config --format json') printf '{"name":"fixture","services":{"app":{"network_mode":"host","environment":{"HTTP_PROXY":"http://127.0.0.1:28781"}}}}\n' ;;
            'config --services') printf 'app\n' ;;
            *) return 1 ;;
        esac
    }
    docker() {
        case "$*" in
            'ps -aq'|'volume ls -q') return 0 ;;
            'network ls -q') echo fixture ;;
            'network inspect fixture') printf '[{"Name":"host","IPAM":{"Config":null}}]\n' ;;
            *) return 1 ;;
        esac
    }
    timeout() { shift; "$@"; }
    rclone_compose_preflight "$WORK" verify
}
test_compose_failed_ps_caller() {
    local output
    docker() { :; }
    rclone_compose_prepare() { :; }
    rclone_compose_add_project() { :; }
    rclone_compose_directories() { printf '%s\n' "$WORK/project"; }
    rclone_compose_context() { :; }
    rclone_compose_preflight() { :; }
    rclone_compose_volume_report() { :; }
    rclone_compose_status() { echo STATUS_CALLED; return 2; }
    rclone_compose_run() { printf 'UNSAFE_START\n'; }
    output=$(rclone_restore_docker_compose_projects <<< y)
    [ "$?" -ne 0 ] && [[ "$output" = *STATUS_CALLED* && "$output" != *UNSAFE_START* ]]
}

test_compose_prepare_dependencies() {
    local mode="$1" installed=0 plugin=0 calls="$WORK/deps-$1"
    [ "$mode" != missing ] && installed=1
    [ "$mode" != existing ] || plugin=1
    : > "$calls"
    command() {
        if [ "$1:$2" = '-v:docker' ]; then [ "$installed" = 1 ]; else builtin command "$@"; fi
    }
    install_docker() { echo engine >> "$calls"; return 1; }
    install() { echo plugin >> "$calls"; [ "$mode" != failure ] || return 1; plugin=1; }
    docker() {
        case "$*" in
            info) return 0 ;;
            'compose version') [ "$plugin" = 1 ] ;;
            'compose up --help') echo --wait ;;
            *) return 1 ;;
        esac
    }
    if [ "$mode" = missing ] || [ "$mode" = failure ]; then
        ! rclone_compose_prepare
    else
        rclone_compose_prepare || return 1
        [ "$mode" != existing ] || [ ! -s "$calls" ]
    fi
}

test_verify_is_readonly_and_private() {
    local output log="$WORK/verify-curl"
    nginx() { echo 'server_name fixture.example;'; }
    getent() { echo '192.0.2.1 STREAM fixture.example'; }
    curl() { printf '%s\n' "$*" >> "$log"; echo 200; }
    rclone_restore_record() { echo UNEXPECTED_WRITE; return 1; }
    output=$(rclone_migration_verify <<< $'192.0.2.1\nhttps://fixture.example/health?token=PRIVATE_FIXTURE\n') || return 1
    [[ "$output" != *PRIVATE_FIXTURE* && "$output" != *UNEXPECTED_WRITE* ]] && grep -q -- '--resolve fixture.example:443:192.0.2.1' "$log"
}

test_rclone_menu_has_only_restore_workflows() {
    local output
    output=$(rclone_manager <<< 0) || return 1
    [[ "$output" == *'1.   安装 rclone'* ]] &&
        [[ "$output" == *'6.   Docker Compose 恢复'* ]] &&
        [[ "$output" == *'7.   自动同步记录'* ]] &&
        [[ "$output" == *'0.   返回主菜单'* ]] &&
        [[ "$output" != *'Docker named volume 清单/恢复'* ]] &&
        [[ "$output" != *'恢复后 DNS/HTTPS 只读验证'* ]] &&
        [[ "$output" != *'查看恢复记录'* ]]
}

test_credentials_transaction() {
    local mode="$1" fixture="$WORK/credentials-$1" output rc=0
    local fixture_target="$fixture/volume/rclone/rclone.conf"
    mkdir -p "$(dirname "$fixture_target")"
    printf '[BitwardenBackup]\ntype = local\nold = preserved\n[other]\ntype = local\nmarker = untouched\n' > "$fixture_target"
    cp "$fixture_target" "$fixture/original"
    bitwarden_check_requirements() { :; }
    bitwarden_rclone_conf_file() { printf '%s\n' "$fixture_target"; }
    bitwarden_volume_name() { echo fixture-volume; }
    bitwarden_backup_image() { echo sha256:fixture; }
    rclone_config_path() { printf '%s\n' "$fixture/source.conf"; }
    rclone_select_remote() { RCLONE_SELECTED_REMOTE=selected; }
    rclone() { printf '{"selected":{"type":"local","marker":"replacement","token":"PRIVATE_FIXTURE"}}\n'; }
    docker() {
        case "$1" in
            run)
                [[ "$*" = *'--entrypoint rclone'* ]] || return 0
                printf 'PRIVATE_FIXTURE\n'
                [ "$mode" != invalid ] || return 1
                [ "$mode" != concurrent ] || printf 'concurrent-update\n' > "$fixture_target"
                ;;
            volume) [[ "$*" != *--format* ]] || printf '%s\n' "$fixture/volume" ;;
            *) return 1 ;;
        esac
    }
    timeout() { shift; "$@"; }
    output=$(bitwarden_configure_rclone_conf) || rc=$?
    [[ "$output" != *PRIVATE_FIXTURE* ]] || return 1
    case "$mode" in
        invalid) [ "$rc" -ne 0 ] && cmp -s "$fixture_target" "$fixture/original" ;;
        concurrent) [ "$rc" -ne 0 ] && [ "$(cat "$fixture_target")" = concurrent-update ] ;;
        success) [ "$rc" = 0 ] && grep -q 'marker = replacement' "$fixture_target" && grep -q 'marker = untouched' "$fixture_target" && ! grep -q 'old = preserved' "$fixture_target" ;;
    esac
}
test_vault_archive() {
    local mode="$1" fixture="$WORK/archive-$1" rc=0
    mkdir -p "$fixture/extracted" "$fixture/previous"
    python3 - "$fixture" "$mode" <<'PY' || return 1
import io, json, sqlite3, sys, tarfile
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
with sqlite3.connect(root / "extracted/db.fixture.sqlite3") as conn:
    conn.execute("CREATE TABLE users(id INTEGER)")
    conn.execute("CREATE TABLE ciphers(id INTEGER)")
    conn.execute("INSERT INTO users VALUES (1)")
    conn.execute("INSERT INTO ciphers VALUES (1)")
(root / "extracted/config.fixture.json").write_text(json.dumps({"fixture":True}))
for kind in ("rsakey", "attachments", "sends"):
    with tarfile.open(root / ("extracted/" + kind + ".fixture.tar"), "w") as archive:
        path = "rsa_key.pem" if kind == "rsakey" else kind + "/file"
        if mode == "traversal" and kind == "attachments":
            path = "../escaped"
        info = tarfile.TarInfo(path)
        info.size = 7
        archive.addfile(info, io.BytesIO(b"fixture"))
if mode == "corrupt":
    (root / "extracted/db.fixture.sqlite3").write_bytes(b"not-a-database")
PY
    bitwarden_prepare_restored_files "$fixture/extracted" "$fixture/result" "$fixture/previous" || rc=$?
    if [ "$mode" = success ]; then
        [ "$rc" = 0 ] && [ -s "$fixture/result/db.sqlite3" ] && [ "$(cat "$fixture/result/attachments/file")" = fixture ] && [ "$(cat "$fixture/result/sends/file")" = fixture ]
    else
        [ "$rc" -ne 0 ] && [ ! -e "$fixture/escaped" ]
    fi
}
test_generated_sync_failure() {
    local kind="$1" fixture="$WORK/sync-$1"
    load_function crontab_sync_write_script || return 1
    crontab_sync_log_dir() { printf '%s\n' "$fixture/logs"; }
    crontab_sync_write_script "$kind" "$fixture/task.sh" || return 1
    rclone() { return 1; }
    export -f rclone
    mkdir -p "$fixture/locks" "$fixture/source"
    sed -e "s|^LOG_DIR=.*|LOG_DIR='$fixture/logs'|" -e "s|/run/lock|$fixture/locks|g" \
        -e "s|^SRC1=.*|SRC1='$fixture/source'|" "$fixture/task.sh" > "$fixture/isolated.sh"
    ! bash "$fixture/isolated.sh"
}

test_generated_backup_policies() {
    local fixture="$WORK/policies" root_script emby_script
    load_function crontab_sync_write_script || return 1
    load_function crontab_sync_script_content_ok || return 1
    crontab_sync_log_dir() { printf '%s\n' "$fixture/logs"; }
    mkdir -p "$fixture"
    crontab_sync_write_script custom "$fixture/root.sh" || return 1
    crontab_sync_write_script emby "$fixture/emby.sh" || return 1
    root_script=$(cat "$fixture/root.sh")
    emby_script=$(cat "$fixture/emby.sh")
    [[ "$root_script" == *'SRC1="/root"'* ]] || return 1
    [[ "$root_script" == *'--exclude '\''/.cache/**'\'''* ]] || return 1
    [[ "$root_script" == *'--exclude '\''/emby/**'\'''* ]] || return 1
    [[ "$root_script" == *'PRIMARY="qq3303338052@outlook:$BACKUP_NAME"'* ]] || return 1
    [[ "$root_script" != *'DEST2='* ]] || return 1
    [[ "$root_script" == *'--bwlimit=0'* ]] || return 1
    [[ "$root_script" == *'flock -n 9'* ]] || return 1
    [[ "$emby_script" == *'SRC1="/root/emby"'* ]] || return 1
    [[ "$emby_script" == *'SECONDARY="kissska1:$BACKUP_NAME"'* ]] || return 1
    [[ "$emby_script" == *'--transfers=4'* ]] || return 1
    [[ "$emby_script" == *'--bwlimit=0'* ]] || return 1
    [[ "$emby_script" == *'flock -n 9'* ]] || return 1
    [[ "$emby_script" == *'docker stop --timeout 30'* ]] || return 1
    [[ "$emby_script" == *'docker start "$id"'* ]] || return 1
    [[ "$emby_script" == *'--exclude '\''/logs/**'\'''* ]] || return 1
    [[ "$emby_script" == *'casefold'* ]] || return 1
    crontab_sync_script_content_ok emby "$fixture/emby.sh" || return 1
    sed '/^# DAIMON_CHAIN_BACKUP_VERSION=/d' "$fixture/emby.sh" > "$fixture/old-emby.sh"
    ! crontab_sync_script_content_ok emby "$fixture/old-emby.sh" || return 1
    sed 's/^# DAIMON_CHAIN_BACKUP_VERSION=.*/# DAIMON_CHAIN_BACKUP_VERSION=0/' "$fixture/emby.sh" > "$fixture/throttled-emby.sh"
    ! crontab_sync_script_content_ok emby "$fixture/throttled-emby.sh" || return 1
    ! grep -qE 'before-restore|还原前备份|是否创建迁移备份|backup_resolv_conf_once|ssh_config_backup' "$SOURCE"
}

test_generated_emby_rejects_case_collision_before_sync() {
    test_emby_lifecycle collision
}

test_emby_lifecycle() {
    local mode="$1" fixture="$WORK/emby-$1" real_rclone
    command -v flock >/dev/null || { echo 'Linux flock is required'; return 1; }
    real_rclone=${DAIMON_TEST_REAL_RCLONE:-$(type -P rclone)}
    [ -x "$real_rclone" ] || { echo 'A real rclone is required for local-only filter tests'; return 1; }
    load_function crontab_sync_write_script || return 1
    load_function crontab_sync_script_content_ok || return 1
    crontab_sync_log_dir() { printf '%s\n' "$fixture/logs"; }
    mkdir -p "$fixture/src/data" "$fixture/logs" "$fixture/locks" "$fixture/bin"
    printf fixture > "$fixture/src/data/db.sqlite3"
    crontab_sync_write_script "$([ "$mode" = root-mounts ] && echo root || echo emby)" "$fixture/Emby.sh" || return 1
    sed -e "s|^SRC1=.*|SRC1=\"$fixture/src\"|" \
        -e "s|LOG_DIR=\"/var/log/rclone\"|LOG_DIR=\"$fixture/logs\"|" \
        "$fixture/Emby.sh" > "$fixture/isolated.sh"
    cat > "$fixture/bin/docker" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['EMBY_FIXTURE'])
mode = os.environ['EMBY_TEST_MODE']
args = sys.argv[1:]
op = args[0]
with (root / 'calls').open('a') as out:
    out.write('docker ' + ' '.join(args) + '\n')
state_file = root / 'state.json'
state = json.loads(state_file.read_text())
if op == 'info':
    sys.exit(17 if mode == 'info-failure' else 0)
if op == 'ps':
    print('\n'.join(key for key, value in state.items() if value))
elif op == 'inspect':
    if mode == 'inspect-failure': sys.exit(18)
    fmt = args[args.index('-f') + 1] if '-f' in args else args[args.index('--format') + 1]
    for key in args[3:]:
        if key not in state: sys.exit(19)
        if '.Mounts' in fmt:
            source = root / 'src' if key in ('a' * 64, 'b' * 64) else root / 'unrelated'
            if mode == 'parent-mount' and key == 'b' * 64: source = root
            if mode == 'readonly' and key == 'c' * 64: source = root / 'src'
            if mode == 'root-mounts' and key == 'c' * 64: source = root / 'src/emby'
            if mode == 'root-mounts' and key == 'b' * 64: source = root
            mounts = [{'Type': 'bind', 'Source': str(source), 'RW': mode == 'root-mounts' or key != 'c' * 64}]
            print(str(source) if 'range .Mounts' in fmt else (key + ' ' if '.Id' in fmt else '') + json.dumps(mounts))
        else:
            print(str(state[key]).lower() + (' none' if '.Health' in fmt else ''))
elif op in ('stop', 'start'):
    key = args[-1]
    if op == 'start' and (root / 'transfer.pid').exists():
        try: os.kill(int((root / 'transfer.pid').read_text()), 0)
        except ProcessLookupError: pass
        else: sys.exit('Transfer still running during container recovery')
    if mode == op + '-failure' and key == 'b' * 64: sys.exit(20)
    state[key] = op == 'start'
    state_file.write_text(json.dumps(state))
else:
    sys.exit(99)
PY
    cat > "$fixture/bin/rclone" <<'PY'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['EMBY_FIXTURE'])
args = sys.argv[1:]
mode = os.environ['EMBY_TEST_MODE']
with (root / 'calls').open('a') as out:
    out.write('rclone ' + ' '.join(args) + '\n')
if args[0] == 'lsjson' and args[1].startswith('qq3303338052@outlook:'):
    counter = root / 'generation-count'
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if mode == 'generation-failure': sys.exit(25)
    size = 2 if (mode == 'primary-mutation' and count > 1) or (mode == 'replication-mutation' and count > 2) else 1
    print(json.dumps([{'Path': 'data/db.sqlite3', 'Size': size, 'ModTime': '2026-09-13T00:00:00Z', 'Hashes': {'sha1': str(size)}}]))
    sys.exit(0)
if args[0] == 'lsjson':
    source = Path(args[1]).resolve()
    if source != (root / 'src').resolve(): sys.exit(99)
    result = subprocess.run([os.environ['EMBY_REAL_RCLONE'], '--config', '/dev/null', *args], capture_output=True)
    (root / 'inventory.json').write_bytes(result.stdout)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
if args[0] not in ('sync', 'check'): sys.exit(99)
secondary = args[1].startswith('qq3303338052@outlook:')
assert args[1:3] == (['qq3303338052@outlook:Emby', 'kissska1:Emby'] if secondary else [str(root / 'src'), 'qq3303338052@outlook:Emby'])
state = json.loads((root / 'state.json').read_text())
if secondary:
    assert state['a' * 64] and state['b' * 64], 'Secondary copy ran before writer recovery'
    if mode == 'secondary-' + args[0] + '-failure': sys.exit(26)
else:
    assert not state['a' * 64] and not state['b' * 64], 'Primary operation ran with writers active'
if args[0] == 'sync':
    if mode in ('term', 'int', 'runner-term'):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        (root / 'transfer.pid').write_text(str(os.getpid()))
        (root / 'transferring').touch()
        while True: time.sleep(0.1)
    if mode == 'sync-failure':
        print('ERROR: fixture sync failed password=PRIVATE_FIXTURE', file=sys.stderr)
        sys.exit(23)
    if mode == 'timeout': sys.exit(124)
    if mode == 'duplicate': print('NOTICE: Duplicate directory found in source - ignoring')
if (args[0], mode) in (('sync', 'auto-restart'), ('check', 'check-auto-restart')):
    import json
    state = json.loads((root / 'state.json').read_text())
    state['a' * 64] = True
    (root / 'state.json').write_text(json.dumps(state))
if args[0] == 'check' and mode == 'check-failure': sys.exit(24)
if args[0] == 'check' and mode == 'check-duplicate': print('NOTICE: Duplicate object found in destination - ignoring')
PY
    chmod 700 "$fixture/bin/docker" "$fixture/bin/rclone" "$fixture/isolated.sh"
    EMBY_FIXTURE="$fixture" EMBY_TEST_MODE="$mode" EMBY_REAL_RCLONE="$real_rclone" \
        DAIMON_LOCK_DIR="$fixture/locks" DAIMON_RCLONE_RUNNER_FILE="$DAIMON_RCLONE_RUNNER_FILE" \
        PATH="$fixture/bin:$PATH" python3 - <<'PY'
import fcntl, json, os, shlex, signal, subprocess, time
from pathlib import Path
root = Path(os.environ['EMBY_FIXTURE'])
mode = os.environ['EMBY_TEST_MODE']
initial = {'a' * 64: True, 'b' * 64: True, 'c' * 64: True, 'd' * 64: False}
(root / 'state.json').write_text(json.dumps(initial))
database_paths = {'data/db.sqlite3' + suffix for suffix in ('', '-wal', '-shm', '-journal')}
for path in database_paths: (root / 'src' / path).write_text('database fixture')
for path in ('logs/root.txt', 'root.log', 'data/logs/nested.txt', 'data/nested.log', '.migration-fixture/rollback/old', 'data/.migration-fixture/rollback/old'):
    file = root / 'src' / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text('excluded')
if mode in ('collision', 'excluded-collision'):
    parent = root / 'src' / ('logs' if mode == 'excluded-collision' else 'data')
    for path in ('Media/a.strm', 'media/b.strm'):
        file = parent / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(path)
    assert len([p for p in parent.iterdir() if p.name.lower() == 'media']) == 2, 'Case-sensitive Linux fixture required'
if mode == 'missing-source': (root / 'src').rename(root / 'missing')
if mode == 'empty-source':
    for path in database_paths: (root / 'src' / path).unlink()
if mode == 'pending-recovery':
    (root / 'locks/daimon-emby').mkdir()
    (root / 'locks/daimon-emby/containers.pending').write_text('a' * 64 + '\n')
lock = None
if mode in ('same-lock', 'shared-lock'):
    name = 'daimon-emby-root-backup.lock' if mode == 'same-lock' else 'daimon-rclone-backups.lock'
    lock = (root / 'locks' / name).open('w')
    fcntl.flock(lock, fcntl.LOCK_EX)
command = ['bash', str(root / 'isolated.sh')]
if mode == 'runner-term': command = ['bash', os.environ['DAIMON_RCLONE_RUNNER_FILE'], 'emby', str(root / 'isolated.sh')]
output = (root / 'output').open('w')
environment = os.environ.copy()
environment.pop('DAIMON_EMBY_BWLIMIT', None)
if mode == 'bandwidth-override': environment['DAIMON_EMBY_BWLIMIT'] = '768K'
process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True, env=environment)
try:
    if mode == 'shared-lock':
        time.sleep(0.3)
        assert process.poll() is None
        assert not (root / 'calls').exists(), 'Services touched before shared lock acquisition'
        lock.close()
    if mode in ('term', 'int', 'runner-term'):
        deadline = time.monotonic() + 8
        while not (root / 'transferring').exists() and process.poll() is None and time.monotonic() < deadline: time.sleep(0.03)
        assert (root / 'transferring').exists(), 'Transfer never started'
        process.send_signal(signal.SIGINT if mode == 'int' else signal.SIGTERM)
    rc = process.wait(timeout=12)
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    if lock and not lock.closed: lock.close()
    output.close()
calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
state = json.loads((root / 'state.json').read_text())
log = '\n'.join(p.read_text() for p in (root / 'logs').glob('*.log')) + (root / 'output').read_text()
print(log)
print(calls)
success = mode in ('root-mounts', 'success', 'bandwidth-override', 'parent-mount', 'readonly', 'shared-lock', 'excluded-collision')
assert (rc == 0) == (success or mode == 'same-lock'), ('unexpected exit', mode, rc)
if mode == 'sync-failure': assert rc == 23
if mode == 'check-failure': assert rc == 24
if mode == 'timeout': assert rc == 124
if mode in ('term', 'runner-term'): assert rc == 143
if mode == 'int': assert rc == 130
assert (root / 'logs/Emby.last-success').exists() == success
if mode == 'start-failure':
    assert state['a' * 64] and not state['b' * 64]
    assert any((root / 'locks').rglob('*.pending')), 'Recovery instructions lost'
else:
    assert state == initial, ('container state changed', state)
assert 'stop --timeout 30 ' + 'c' * 64 not in calls
assert 'start ' + 'd' * 64 not in calls
if mode in ('collision', 'missing-source', 'empty-source', 'info-failure', 'inspect-failure', 'same-lock', 'pending-recovery'):
    assert 'rclone sync ' not in calls and 'docker stop ' not in calls
if mode == 'collision': assert 'Media' in log and 'media' in log
if success:
    assert calls.index('docker stop ') < calls.index('rclone sync ') < calls.index('rclone check ') < calls.index('docker start ')
    sync_args = shlex.split(next(line for line in calls.splitlines() if line.startswith('rclone sync ')))
    bandwidth = [arg for arg in sync_args if arg.startswith('--bwlimit=')]
    assert bandwidth == ['--bwlimit=0'], ('unexpected bandwidth limit', bandwidth)
    assert calls.count('rclone sync ') == 2 and calls.count('rclone check ') == 2
    assert calls.index('docker start ') < calls.index('rclone sync qq3303338052@outlook:Emby kissska1:Emby')
    paths = {entry['Path'] for entry in json.loads((root / 'inventory.json').read_text()) if not entry['IsDir']}
    assert paths == database_paths, ('wrong database or log filters', paths)
PY
}

test_rclone_runner_live_status_and_warning() {
    local fixture="$WORK/runner-live"
    mkdir -p "$fixture"
    export DAIMON_RCLONE_STATUS_CACHE="$fixture/status.tsv"
    export DAIMON_RCLONE_RUN_LOG_DIR="$fixture/runs"
    export DAIMON_RCLONE_STATUS_LOCK="$fixture/status.lock"
    crontab_sync_write_runner "$fixture/runner.sh" || return 1
    python3 - "$fixture" <<'PY'
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
runner = root / 'runner.sh'
cache = root / 'status.tsv'
for name, body in {
    'long': 'trap "exit 143" TERM\ntouch "' + str(root / 'ready') + '"\nwhile :; do sleep 0.1; done',
    'success': 'exit 0',
    'warning': 'echo "Duplicate object found in destination - ignoring password=PRIVATE_FIXTURE"'
}.items():
    file = root / (name + '.sh')
    file.write_text('#!/bin/bash\n' + body + '\n')
    file.chmod(0o700)
process = subprocess.Popen(['bash', str(runner), 'long', str(root / 'long.sh')], start_new_session=True)
try:
    deadline = time.monotonic() + 5
    while not (root / 'ready').exists() and time.monotonic() < deadline: time.sleep(0.02)
    assert (root / 'ready').exists()
    rows = [line.split('\t') for line in cache.read_text().splitlines()]
    for row in rows:
        if row[4] == 'long': row[0] = str(int(time.time()) - 7200)
    cache.write_text(''.join('\t'.join(row) + '\n' for row in rows))
    subprocess.run(['bash', str(runner), 'success', str(root / 'success.sh')], check=True)
    rows = [line.split('\t') for line in cache.read_text().splitlines()]
    assert next(row for row in rows if row[4] == 'long')[6] == '执行中'
finally:
    process.send_signal(signal.SIGTERM)
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
assert process.returncode == 143
subprocess.run(['bash', str(runner), 'warning', str(root / 'warning.sh')], check=True)
rows = [line.split('\t') for line in cache.read_text().splitlines()]
warning = next(row for row in rows if row[4] == 'warning')
assert warning[6] == '有警告' and warning[7] == '0'
assert 'PRIVATE_FIXTURE' not in cache.read_text() and '[REDACTED]' in warning[11]
assert next(row for row in rows if row[4] == 'long')[6] == '中断/未知'
PY
}
test_chain_upgrade() {
    local mode="$1" fixture="$WORK/upgrade-$1"
    mkdir -p "$fixture/tasks" "$fixture/logs" "$fixture/locks" "$fixture/bin"
    export DAIMON_BACKUP_SH_DIR="$fixture/tasks" DAIMON_LOCK_DIR="$fixture/locks"
    export UPGRADE_FIXTURE="$fixture" UPGRADE_MODE="$mode"
    load_function crontab_sync_upgrade_installed || return 1
    load_function crontab_sync_write_script || return 1
    load_function crontab_sync_root_name || return 1
    crontab_sync_log_dir() { printf '%s/logs\n' "$UPGRADE_FIXTURE"; }
    cat > "$fixture/bin/crontab" <<'PY'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
root = Path(os.environ['UPGRADE_FIXTURE'])
path = root / 'cron'
if sys.argv[1] == '-l':
    sys.stdout.buffer.write(path.read_bytes())
else:
    if os.environ['UPGRADE_MODE'] == 'cron-failure': sys.exit(1)
    path.write_bytes(sys.stdin.buffer.read())
PY
    chmod 700 "$fixture/bin/crontab"
    export PATH="$fixture/bin:$PATH"
    DAIMON_SKIP_RUNNER_WRITE=1 crontab_sync_write_script root "$fixture/tasks/Server-A.sh" || return 1
    DAIMON_SKIP_RUNNER_WRITE=1 crontab_sync_write_script emby "$fixture/tasks/Emby_Root_Backup.sh" || return 1
    sed -i 's/DAIMON_CHAIN_BACKUP_VERSION=1/DAIMON_CHAIN_BACKUP_VERSION=0/' "$fixture/tasks/Server-A.sh" "$fixture/tasks/Emby_Root_Backup.sh"
    printf '#!/bin/bash\necho unrelated\n' > "$fixture/tasks/unrelated.sh"
    if [ "$mode" = custom-id ]; then
        printf '# preserved\n45 4 * * * /bin/bash %s/tasks/.rclone-runner.sh custom:Server-A %s/tasks/Server-A.sh\n7 2 * * * echo unrelated\n' "$fixture" "$fixture" > "$fixture/cron"
    else
        cp "$fixture/tasks/Server-A.sh" "$fixture/tasks/Root_Backup.sh"
        printf '# preserved\n25 4 * * * /bin/bash %s/tasks/Root_Backup.sh\n45 4 * * * /bin/bash %s/tasks/Server-A.sh\n7 2 * * * echo unrelated\n' "$fixture" "$fixture" > "$fixture/cron"
    fi
    if [ "$mode" = ambiguous ]; then cp "$fixture/tasks/Server-A.sh" "$fixture/tasks/Server-B.sh"; fi
    if [ "$mode" = unknown ]; then printf '#!/bin/bash\necho custom\n' > "$fixture/tasks/Root_Backup.sh"; fi
    if [ "$mode" = symlink ]; then mv "$fixture/tasks/Root_Backup.sh" "$fixture/linked.sh"; ln -s "$fixture/linked.sh" "$fixture/tasks/Root_Backup.sh"; fi
    if [ "$mode" = lock ]; then exec 5>"$fixture/locks/daimon-backup-scripts.lock"; flock -x 5; fi
    python3 - <<'PY'
import hashlib, os
from pathlib import Path
root = Path(os.environ['UPGRADE_FIXTURE'])
(root / 'before').write_text(repr({p.name: p.read_bytes() for p in (root / 'tasks').iterdir()}))
(root / 'cron-before').write_bytes((root / 'cron').read_bytes())
PY
    local rc=0
    crontab_sync_upgrade_installed > "$fixture/output" 2>&1 || rc=$?
    cat "$fixture/output"
    if [ "$mode" = success ] || [ "$mode" = custom-id ]; then
        [ "$rc" = 0 ] || return 1
        [ "$(cat "$fixture/tasks/.root-backup-name")" = Server-A ] || return 1
        [ ! -e "$fixture/tasks/Root_Backup.sh" ] || return 1
        [ "$(grep -c 'Server-A.sh' "$fixture/cron")" = 1 ] || return 1
        grep -q '^# preserved$' "$fixture/cron" || return 1
        grep -q '^7 2 ' "$fixture/cron" || return 1
        if [ "$mode" = success ]; then
            grep -q '^25 4 ' "$fixture/cron" || return 1
        else
            grep -q '^45 4 .*\.rclone-runner\.sh root .*Server-A\.sh' "$fixture/cron" || return 1
            ! grep -q 'custom:Server-A' "$fixture/cron" || return 1
        fi
        crontab_sync_upgrade_installed > "$fixture/output" 2>&1 || return 1
        grep -q 'BACKUP_UPGRADE current' "$fixture/output" || return 1
    else
        [ "$rc" != 0 ] || return 1
        python3 - <<'PY'
import ast, os
from pathlib import Path
root = Path(os.environ['UPGRADE_FIXTURE'])
assert ast.literal_eval((root / 'before').read_text()) == {p.name: p.read_bytes() for p in (root / 'tasks').iterdir()}
assert (root / 'cron-before').read_bytes() == (root / 'cron').read_bytes()
PY
    fi
}

test_generated_root_backup_policy() {
    local fixture="$WORK/root-backup" script cron
    load_function crontab_sync_write_script || return 1
    load_function crontab_sync_cron_line_by_id || return 1
    load_function crontab_sync_cron_entry || return 1
    crontab_sync_log_dir() { printf '%s\n' "$fixture/logs"; }
    mkdir -p "$fixture"
    crontab_sync_write_script root "$fixture/Server-A.sh" || return 1
    script=$(cat "$fixture/Server-A.sh")
    bash -n "$fixture/Server-A.sh" || return 1
    grep -Fq 'BACKUP_NAME="Server-A"' "$fixture/Server-A.sh" || return 1
    grep -Fq -- '--bwlimit=0' "$fixture/Server-A.sh" || return 1
    grep -Fq 'docker inspect -f' "$fixture/Server-A.sh" || return 1
    grep -Fq 'mount["Type"] != "bind"' "$fixture/Server-A.sh" || return 1
    grep -Fq 'os.path.commonpath((root, path))' "$fixture/Server-A.sh" || return 1
    grep -Fq 'sys.argv[4] == "root"' "$fixture/Server-A.sh" || return 1
    grep -Fq 'BACKUP_OK=1' "$fixture/Server-A.sh" || return 1
    grep -Fq 'date -Is > "$SUCCESS_FILE"' "$fixture/Server-A.sh" || return 1
    grep -Fq 'docker stop --timeout 30' "$fixture/Server-A.sh" || return 1
    grep -Fq 'docker start "$id"' "$fixture/Server-A.sh" || return 1
    cron=$(crontab_sync_cron_line_by_id root /root/linux-daimon/backup-sh/Root_Backup.sh)
    [[ "$cron" == *'TZ=Asia/Shanghai date +\%H:\%M'* && "$cron" == *'"04:25"'* ]] || return 1
    ! crontab_sync_cron_entry '99 99 * * * echo invalid'
}

test_rclone_runner_records_status() {
    local fixture="$WORK/runner" runner cache log success_script failure_script old_epoch stale_epoch
    mkdir -p "$fixture"
    runner="$fixture/runner.sh"
    cache="$fixture/status.tsv"
    export DAIMON_RCLONE_RUNNER_FILE="$runner"
    export DAIMON_RCLONE_STATUS_CACHE="$cache"
    export DAIMON_RCLONE_RUN_LOG_DIR="$fixture/runs"
    export DAIMON_RCLONE_STATUS_LOCK="$fixture/status.lock"
    success_script="$fixture/success.sh"
    failure_script="$fixture/failure.sh"
    printf '#!/bin/bash\nprintf "sync ok\\n"\n' > "$success_script"
    printf '#!/bin/bash\nprintf "error password=PRIVATE_FIXTURE\\n"\nexit 7\n' > "$failure_script"
    chmod 700 "$success_script" "$failure_script"
    crontab_sync_write_runner "$runner" || return 1
    bash "$runner" success "$success_script" || return 1
    grep -q $'\tsuccess\tsync\t成功\t0\t' "$cache" || return 1
    if bash "$runner" failure "$failure_script"; then return 1; fi
    grep -q $'\tfailure\tsync\t失败\t7\t' "$cache" || return 1
    ! grep -q 'PRIVATE_FIXTURE' "$cache" || return 1
    log=$(awk -F '\t' '$5 == "failure" {print $11}' "$cache")
    [ -f "$log" ] || return 1
    grep -q 'PRIVATE_FIXTURE' "$log" || return 1
    stale_epoch=$(($(date +%s) - 7200))
    printf '%s\tstale\t-\tstale-run\tstale\tsync\t执行中\t-\t0\t1\t%s\t-\n' "$stale_epoch" "$log" >> "$cache"
    old_epoch=$(($(date +%s) - 31 * 86400))
    printf '%s\told\told\told-run\told\tsync\t成功\t0\t1\t1\t%s\t-\n' "$old_epoch" "$log" >> "$cache"
    bash "$runner" success "$success_script" || return 1
    grep -q $'\tstale\tsync\t中断/未知\t-\t' "$cache" || return 1
    ! grep -q $'\told\tsync\t' "$cache"
}

test_rclone_runner_cache_failure() {
    local tool="$1" task_rc="$2" fixture="$WORK/runner-cache-$1-$2" rc=0 expected="$2"
    mkdir -p "$fixture"
    export DAIMON_RCLONE_STATUS_CACHE="$fixture/status.tsv"
    export DAIMON_RCLONE_RUN_LOG_DIR="$fixture/runs"
    export DAIMON_RCLONE_STATUS_LOCK="$fixture/status.lock"
    export RUNNER_CACHE_FAILURE="$tool" RUNNER_FAIL_AFTER="$fixture/task-finished"
    crontab_sync_write_runner "$fixture/runner.sh" || return 1
    printf '#!/bin/bash\ntouch "$RUNNER_FAIL_AFTER"\nexit %s\n' "$task_rc" > "$fixture/task.sh"
    chmod 700 "$fixture/task.sh"
    mktemp() { [ "$RUNNER_CACHE_FAILURE" != mktemp ] || [ ! -e "$RUNNER_FAIL_AFTER" ] || return 71; command mktemp "$@"; }
    awk() { [ "$RUNNER_CACHE_FAILURE" != awk ] || [ ! -e "$RUNNER_FAIL_AFTER" ] || return 71; command awk "$@"; }
    mv() { [ "$RUNNER_CACHE_FAILURE" != mv ] || [ ! -e "$RUNNER_FAIL_AFTER" ] || return 71; command mv "$@"; }
    export -f mktemp awk mv
    bash "$fixture/runner.sh" fixture "$fixture/task.sh" || rc=$?
    [ "$expected" -ne 0 ] || expected=1
    [ "$rc" -eq "$expected" ] || { printf 'Cache %s failure: expected %s, got %s\n' "$tool" "$expected" "$rc"; return 1; }
    [ -e "$RUNNER_FAIL_AFTER" ] && grep -q $'\t执行中\t' "$DAIMON_RCLONE_STATUS_CACHE" \
        && ! grep -q $'\t成功\t' "$DAIMON_RCLONE_STATUS_CACHE"
}

test_rclone_runner_is_not_custom_task() {
    local fixture="$WORK/custom-list"
    mkdir -p "$fixture"
    export DAIMON_BACKUP_SH_DIR="$fixture"
    touch "$fixture/.rclone-runner.sh" "$fixture/fixture.sh"
    [ "$(crontab_sync_custom_files)" = fixture.sh ]
}

test_rclone_log_copy_and_export_are_redacted() {
    local fixture="$WORK/log-actions" log output exported
    mkdir -p "$fixture"
    log="$fixture/run.log"
    printf '%s\n' 'Authorization: Bearer PRIVATE_BEARER' 'error {"password": "PRIVATE_PASSWORD"}' 'url?tempauth=PRIVATE_AUTH' > "$log"
    cpcat() {
        printf 'CPCAT_CALLED\n'
        grep -q '\[REDACTED\]' "$1" && ! grep -q 'PRIVATE_' "$1"
    }
    output=$(crontab_sync_log_copy "$log") || return 1
    [[ "$output" == *CPCAT_CALLED* ]] || return 1
    export DAIMON_RCLONE_EXPORT_DIR="$fixture/export"
    crontab_sync_log_export "$log" >/dev/null || return 1
    exported="$fixture/export/run.redacted.log"
    [ -f "$exported" ] && grep -q '\[REDACTED\]' "$exported" && ! grep -q 'PRIVATE_' "$exported"
}

test_remote_names_privacy() {
    local output
    rclone() { printf '{"fixture":{"type":"local","token":"PRIVATE_FIXTURE"}}\n'; }
    output=$(rclone_config_remotes "$WORK/conf") || return 1
    [ "$output" = $'fixture\tlocal' ]
}
test_compose_context_labels() {
    local fixture="$WORK/context" actual
    local MSYS2_ARG_CONV_EXCL='*'
    export MSYS2_ARG_CONV_EXCL
    mkdir -p "$fixture"
    printf 'services: {}\n' > "$fixture/base.yml"
    printf 'services: {}\n' > "$fixture/override.yml"
    docker() {
        case "$1" in
            ps) echo fixture ;;
            inspect) printf '[{"Config":{"Labels":{"com.docker.compose.project":"explicit","com.docker.compose.project.working_dir":"%s","com.docker.compose.project.config_files":"%s/base.yml,%s/override.yml"}}}]\n' "$fixture" "$fixture" "$fixture" ;;
        esac
    }
    rclone_compose_context "$fixture" || return 1
    actual=$(printf '%s\n' "${RCLONE_COMPOSE_ARGS[@]}")
    [ "$actual" = "$(printf '%s\n' -p explicit -f "$fixture/base.yml" -f "$fixture/override.yml")" ]
}
test_compose_context_clean_host() {
    local fixture="$WORK/clean-compose" actual
    mkdir -p "$fixture"
    printf 'name: clean-project\nservices:\n  app:\n    image: busybox\n' > "$fixture/compose.yml"
    docker() {
        case "$1" in
            ps) return 0 ;;
            compose) return 0 ;;
            *) return 1 ;;
        esac
    }
    rclone_compose_run() {
        shift
        case "$*" in
            'config --format json') printf '{"name":"clean-project","services":{}}\n' ;;
            *) return 0 ;;
        esac
    }
    rclone_compose_context "$fixture" || return 1
    actual=$(printf '%s\n' "${RCLONE_COMPOSE_ARGS[@]}")
    [ "$actual" = "$(printf '%s\n' -p clean-project)" ]
}
test_ufw_restore_ports() {
    local scenario="$1" log="$WORK/ufw-$1.log" state=inactive rc=0
    [ "$scenario" != active ] || state=active
    [ "$scenario" != unknown ] || state=unknown
    : > "$log"
    ssh_current_ports() { [ "$scenario" != missing-ssh ] && printf '64400\n'; }
    command() {
        case "$2" in
            ufw) return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    ufw() {
        printf '%s\n' "$*" >> "$log"
        [ "$scenario:$*" != 'ssh-failure:allow 64400/tcp' ] || return 1
        case "$1" in status) printf 'Status: %s\n' "$state" ;; '--force') [ "$scenario" != enable-failure ] || return 1; state=active ;; esac
    }
    rclone_nginx_allow_ports || rc=$?
    case "$scenario" in
        active|inactive)
            [ "$rc" = 0 ] && grep -Fxq 'allow 64400/tcp' "$log" && grep -Fxq 'allow 80/tcp' "$log" && grep -Fxq 'allow 443/tcp' "$log" && grep -Fxq 'allow from 172.16.0.0/12' "$log" || return 1
            [ "$scenario" != inactive ] || grep -Fxq -- '--force enable' "$log" ;;
        enable-failure) [ "$rc" -ne 0 ] ;;
        *) [ "$rc" -ne 0 ] && ! grep -q -- '--force enable' "$log" ;;
    esac
}

test_nginx_include_bundle() {
    local scenario="$1" fixture="$WORK/includes-$1" output
    local DAIMON_NGINX_DIR="$fixture/nginx" DAIMON_DOMAIN_DIR="$fixture/domain" DAIMON_WEB_DIR="$fixture/web"
    mkdir -p "$DAIMON_NGINX_DIR"/{sites-available,sites-enabled,conf.d,stream.d} "$DAIMON_DOMAIN_DIR" "$DAIMON_WEB_DIR"/{conf.d,stream.d} "$fixture/bundle"
    printf original > "$DAIMON_NGINX_DIR/nginx.conf"
    printf fixture > "$DAIMON_NGINX_DIR/conf.d/app.conf"
    printf fixture > "$DAIMON_WEB_DIR/stream.d/app.conf"
    nginx() { printf '# configuration file %s/nginx.conf:\n# configuration file %s/conf.d/app.conf:\n' "$DAIMON_NGINX_DIR" "$DAIMON_NGINX_DIR"; }
    rclone_nginx_write_bundle "$fixture/bundle" || return 1
    [ -f "$fixture/bundle/nginx.conf" ] && [ -f "$fixture/bundle/home-web-stream.d/app.conf" ] || return 1
    rclone_nginx_prepare() { :; }
    rclone_nginx_allow_ports() { :; }
    rclone_assert_inactive() { :; }
    systemctl() { :; }
    printf replacement > "$fixture/bundle/nginx.conf"
    if [ "$scenario" = missing ]; then nginx() { printf '# configuration file %s/nginx.conf:\n' "$DAIMON_NGINX_DIR"; }; fi
    if [ "$scenario" = missing ]; then
        ! rclone_nginx_apply "$fixture/bundle" all replace || return 1
        [ "$(cat "$DAIMON_NGINX_DIR/nginx.conf")" = original ]
    else
        rclone_nginx_apply "$fixture/bundle" all replace || return 1
        [ "$(cat "$DAIMON_NGINX_DIR/nginx.conf")" = replacement ]
    fi
}

test_nginx_conf_only_bundle() {
    local fixture="$WORK/conf-only"
    local DAIMON_NGINX_DIR="$fixture/nginx" DAIMON_DOMAIN_DIR="$fixture/domain" DAIMON_WEB_DIR="$fixture/web"
    mkdir -p "$DAIMON_NGINX_DIR/conf.d" "$DAIMON_DOMAIN_DIR" "$fixture/bundle"
    printf fixture > "$DAIMON_NGINX_DIR/nginx.conf"
    printf fixture > "$DAIMON_NGINX_DIR/conf.d/app.conf"
    nginx() { printf '# configuration file %s/nginx.conf:\n# configuration file %s/conf.d/app.conf:\n' "$DAIMON_NGINX_DIR" "$DAIMON_NGINX_DIR"; }
    rclone_nginx_write_bundle "$fixture/bundle" || return 1
    rclone_nginx_prepare() { :; }
    rclone_nginx_allow_ports() { :; }
    rclone_assert_inactive() { :; }
    systemctl() { :; }
    rclone_nginx_apply "$fixture/bundle" all replace || return 1
    [ -f "$DAIMON_NGINX_DIR/conf.d/app.conf" ] && [ ! -s "$fixture/bundle/enabled_sites.txt" ]
}

test_volume_restore_transaction() {
    local scenario="$1" fixture="$WORK/volume-$1" rc=0
    mkdir -p "$fixture/package" "$fixture/volume/_data" "$fixture/source"
    printf old > "$fixture/volume/_data/item"
    printf new > "$fixture/source/item"
    tar -czpf "$fixture/package/data.tar.gz" -C "$fixture/source" . || return 1
    python3 - "$fixture/package" "$scenario" <<'PY' || return 1
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1])
h=hashlib.sha256((p/'data.tar.gz').read_bytes()).hexdigest()
(p/'volume.json').write_text(json.dumps(dict(version=1,name='fixture',sha256=h if sys.argv[2]!='checksum' else 'invalid')))
PY
    docker() { :; }
    rclone_volume_mount() { printf '%s\n' "$fixture/volume/_data"; }
    rclone_assert_inactive() { [ "$scenario" != active ]; }
    mountpoint() { return 1; }
    rclone() {
        case "$1" in
            size) printf '{"bytes":4096}\n' ;;
            copy) [ "$scenario" != download ] && cp -a "$fixture/package" "$3" ;;
            check) return 0 ;;
            *) return 1 ;;
        esac
    }
    if [ "$scenario" = rename ]; then
        mv() { [[ "$*" != *'/new '* ]] && command mv "$@"; }
    fi
    rclone_restore_volume fixture:package fixture <<< 'RESTORE fixture' || rc=$?
    if [ "$scenario" = success ]; then [ "$rc" = 0 ] && [ "$(cat "$fixture/volume/_data/item")" = new ]; else [ "$rc" -ne 0 ] && [ "$(cat "$fixture/volume/_data/item")" = old ]; fi
}

test_volume_export_roundtrip() {
    local scenario="$1" fixture="$WORK/volume-export-$1" output rc=0
    local remote_root="$fixture/remote"
    mkdir -p "$fixture/volume/_data/nested"
    printf original > "$fixture/volume/_data/nested/item"
    chmod 700 "$fixture/volume/_data/nested"
    chmod 640 "$fixture/volume/_data/nested/item"
    docker() { case "$*" in 'volume ls -q') printf 'fixture\n' ;; *) return 0 ;; esac; }
    rclone_volume_mount() { printf '%s\n' "$fixture/volume/_data"; }
    rclone_assert_inactive() { [ "$scenario" != active ]; }
    mountpoint() { return 1; }
    rclone_select_remote() { RCLONE_SELECTED_REMOTE=fixture; }
    rclone() {
        local source="${2/#fixture:/$fixture/remote/}" target="${3/#fixture:/$fixture/remote/}"
        case "$1" in
            mkdir) mkdir -p "$source" ;;
            lsjson) python3 - "$source" <<'PY'
import json,sys
from pathlib import Path
print(json.dumps([dict(Name=p.name,IsDir=p.is_dir()) for p in Path(sys.argv[1]).iterdir()]))
PY
                ;;
            copy) mkdir -p "$target" && cp -a "$source/." "$target/" ;;
            check) diff -r "$source" "$target" ;;
            size) printf '{"bytes":4096}\n' ;;
            *) return 1 ;;
        esac
    }
    if [ "$scenario" = existing ]; then
        mkdir -p "$remote_root/server/linux-daimon/backup/docker-volumes/fixture"
        printf sentinel > "$remote_root/server/linux-daimon/backup/docker-volumes/fixture/data.tar.gz"
    fi
    output=$(rclone_export_named_volumes <<< $'1\nserver\nEXPORT') || rc=$?
    if [ "$scenario" = active ]; then
        [ "$rc" -ne 0 ] && [ ! -e "$remote_root/server/linux-daimon/backup/docker-volumes/fixture" ]
        return $?
    fi
    if [ "$scenario" = existing ]; then
        [ "$rc" -ne 0 ] && [ "$(cat "$remote_root/server/linux-daimon/backup/docker-volumes/fixture/data.tar.gz")" = sentinel ]
        return $?
    fi
    [ "$rc" = 0 ] || { printf '%s\n' "$output"; return 1; }
    printf modified > "$fixture/volume/_data/nested/item"
    rclone_restore_volume fixture:server/linux-daimon/backup/docker-volumes/fixture fixture <<< 'RESTORE fixture' || return 1
    [ "$(cat "$fixture/volume/_data/nested/item")" = original ] || return 1
    if [ "$(uname -s)" = Linux ]; then
        [ "$(stat -c %a "$fixture/volume/_data/nested/item")" = 640 ] && [ "$(stat -c %a "$fixture/volume/_data/nested")" = 700 ]
    fi
}

test_nginx_generated_bundle_script() {
    local script="$WORK/nginx-generated.sh"
    rclone_nginx_write_backup_script "$script" && bash -n "$script" && grep -q 'config-files.json' "$script"
}
test_volume_archive_rejects_links() {
    local archive="$WORK/link-volume.tar.gz" target="$WORK/link-target"
    mkdir -p "$WORK/link-source"
    printf fixture > "$WORK/link-source/file"
    ln -s file "$WORK/link-source/link"
    tar -czf "$archive" -C "$WORK/link-source" . || return 1
    ! rclone_volume_archive "$archive" size
}
test_restore_record_atomic() {
    local root="$WORK/record" value
    mkdir -p "$root"
    DAIMON_RESTORE_ROOT="$root"
    rclone_restore_record compose /root/app running checked || return 1
    value=$(python3 - "$root/linux-daimon/restore-status.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data[0]["status"] == "running"
print(data[0]["detail"])
PY
)
    [ "$value" = checked ]
}
test_missing_certificate_files() {
    local fixture="$WORK/certificates"
    mkdir -p "$fixture"
    ! rclone_nginx_cert_valid "$fixture"
}
test_symlink_restore_guard() {
    local fixture="$WORK/symlink"
    mkdir -p "$fixture/real"
    ln -s "$fixture/real" "$fixture/alias" || return 1
    ! rclone_tree_safe "$fixture/alias"
}

test_retire_cron_exact_cleanup() {
    local fixture="$WORK/retire-cron" current_file="$WORK/retire-cron.current" next_file="$WORK/retire-cron.next"
    mkdir -p "$fixture"
    printf '%s\n' "# keep /root/linux-daimon/backup-sh/task.sh in documentation" "0 1 * * * /root/linux-daimon/backup-sh/task.sh" "0 2 * * * /root/linux-daimon/backup-sh/task.sh-extra" "0 3 * * * /root/keep.sh" > "$current_file"
    load_function server_retire_remove_cron_path || return 1
    crontab() {
        if [ "$1" = "-l" ]; then cat "$current_file"; return 0; fi
        cat > "$next_file"
        cp "$next_file" "$current_file"
    }
    server_retire_remove_cron_path /root/linux-daimon/backup-sh/task.sh || return 1
    grep -Fq 'documentation' "$current_file" && ! grep -Fxq '0 1 * * * /root/linux-daimon/backup-sh/task.sh' "$current_file" && grep -Fq 'task.sh-extra' "$current_file" && grep -Fq '/root/keep.sh' "$current_file"
}

test_retire_compose_preserves_volumes() {
    local fixture="$WORK/retire-compose" log="$WORK/retire-compose.log"
    mkdir -p "$fixture"
    load_function server_retire_compose_stop || return 1
    root_use() { :; }
    docker() {
        printf '%s\n' "$*" >> "$log"
        [[ "$*" != *' -v '* && "$*" != *' --volumes '* ]]
    }
    server_retire_compose_stop fixture "$fixture" "" || return 1
    grep -q 'compose -p fixture down' "$log"
}

test_retire_script_path_guard() {
    local fixture="$WORK/retire-guard"
    mkdir -p "$fixture"
    load_function server_retire_remove_script || return 1
    root_use() { :; }
    ! server_retire_remove_script /tmp/not-managed.sh
}

test_retire_bulk_order() {
    local log="$WORK/retire-order.log"
    : > "$log"
    load_function server_retire_apply_token || return 1
    load_function server_retire_apply_tokens_for_prefix || return 1
    server_retire_apply_token() { printf '%s\n' "$1" >> "$log"; }
    server_retire_apply_tokens_for_prefix N 'N1 N10 N2' || return 1
    [ "$(tr '\n' ' ' < "$log")" = 'N10 N2 N1 ' ]
}

check 'missing nginx must fail' test_missing_nginx
check 'reload and restart failure must fail' test_reload_failure
check 'link failure must propagate' test_link_failure
check 'remote failure must not enable unrelated sites' test_no_link_fallback
check 'directory names preserve repeated spaces' test_names 1 'folder  two  spaces'
check 'directory selection accepts decimal 08' test_names 08 folder8
check 'remote errors never expose authorization URLs' test_error_privacy
check 'credential failure preserves original configuration' test_config_failure
check 'active volume preflight stops the restore caller' test_restore_active_volume
for mode in success download checksum space rename concurrent; do
    check "directory transaction $mode" test_folder_restore "$mode"
done
check 'directory conflict keep policy adds only missing files' test_folder_restore keep keep
check 'live nested bind mount blocks parent restoration' test_live_mount_guard
check 'daemon query failure blocks restoration' test_daemon_guard
for mode in valid invalid unknown; do check "remote status $mode" test_remote_state "$mode"; done
for mode in success missing invalid link relative stopped; do check "Nginx transaction $mode" test_nginx_transaction "$mode"; done
for mode in healthy unhealthy starting error; do check "Compose state $mode" test_compose_state "$mode"; done
check 'missing bind source prevents Compose startup' test_compose_missing_bind
check 'Compose accepts null IPAM config when validating a host proxy' test_compose_null_ipam
check 'failed Compose status query cannot become startup' test_compose_failed_ps_caller
for mode in missing existing plugin failure; do check "Compose dependency $mode" test_compose_prepare_dependencies "$mode"; done
check 'public verification remains read-only and hides URL secrets' test_verify_is_readonly_and_private
check 'rclone menu exposes only requested restore workflows' test_rclone_menu_has_only_restore_workflows
for mode in success invalid concurrent; do check "credential transaction $mode" test_credentials_transaction "$mode"; done
for mode in success corrupt traversal; do check "Vaultwarden archive $mode" test_vault_archive "$mode"; done
for kind in bitwarden custom; do check "generated $kind sync propagates failure" test_generated_sync_failure "$kind"; done
check 'generated backup policies exclude bulky data and avoid pre-operation backups' test_generated_backup_policies
check 'generated Emby backup rejects case collisions before sync' test_generated_emby_rejects_case_collision_before_sync
for mode in root-mounts generation-failure primary-mutation replication-mutation secondary-sync-failure secondary-check-failure success bandwidth-override info-failure inspect-failure stop-failure sync-failure check-failure start-failure term int runner-term timeout duplicate check-duplicate auto-restart check-auto-restart parent-mount readonly missing-source empty-source pending-recovery same-lock shared-lock excluded-collision; do
    check "generated Emby lifecycle $mode" test_emby_lifecycle "$mode"
done
for mode in success custom-id ambiguous unknown symlink lock cron-failure; do
    check "chain upgrade $mode" test_chain_upgrade "$mode"
done
check 'generated root backup freezes bind-mounted Docker services' test_generated_root_backup_policy
check 'rclone runner records, redacts, and expires statuses' test_rclone_runner_records_status
check 'rclone runner preserves live tasks and redacts warnings' test_rclone_runner_live_status_and_warning
for tool in mktemp awk mv; do
    for task_rc in 0 23 143; do check "rclone runner cache failure $tool after $task_rc" test_rclone_runner_cache_failure "$tool" "$task_rc"; done
done
check 'rclone runner is excluded from custom tasks' test_rclone_runner_is_not_custom_task
check 'rclone log copy and export redact credentials' test_rclone_log_copy_and_export_are_redacted
check 'remote names and types do not expose tokens' test_remote_names_privacy
check 'Compose labels preserve project name and override files' test_compose_context_labels
check 'clean Compose hosts derive project name from config' test_compose_context_clean_host
for mode in active inactive missing-ssh unknown ssh-failure enable-failure; do check "UFW restore $mode" test_ufw_restore_ports "$mode"; done
for mode in success missing; do check "Nginx include bundle $mode" test_nginx_include_bundle "$mode"; done
check 'Nginx conf-only bundle roundtrip' test_nginx_conf_only_bundle
for mode in success download checksum active rename; do check "volume restore transaction $mode" test_volume_restore_transaction "$mode"; done
for mode in success active existing; do check "volume export roundtrip $mode" test_volume_export_roundtrip "$mode"; done
check 'generated Nginx script carries its bundle dependencies' test_nginx_generated_bundle_script
check 'volume archives reject symlink entries' test_volume_archive_rejects_links
check 'restore report writes atomically without secrets' test_restore_record_atomic
check 'missing certificate files fail validation' test_missing_certificate_files
check 'symlink restoration target is rejected' test_symlink_restore_guard
check 'retirement cron cleanup removes only exact managed path' test_retire_cron_exact_cleanup
check 'retirement Compose stop preserves volumes' test_retire_compose_preserves_volumes
check 'retirement script path guard rejects unmanaged paths' test_retire_script_path_guard
check 'retirement bulk processing keeps descending indexes' test_retire_bulk_order

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
