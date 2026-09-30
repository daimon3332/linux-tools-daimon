#!/bin/bash

ssl_nginx_manager() {
	mkdir -p "$DAIMON_SCRIPT_DIR" || return 1
	{
	printf '#!/bin/bash\n'
	declare -f install ssh_current_ports rclone_restore_name_valid rclone_tree_safe rclone_assert_inactive rclone_require_space \
		rclone_nginx_prepare rclone_nginx_allow_ports rclone_nginx_cert_valid rclone_nginx_apply \
		rclone_nginx_target_for_key rclone_nginx_loaded_files rclone_nginx_check_manifest \
		rclone_nginx_write_bundle rclone_nginx_write_backup_script rclone_check_nginx_after_restore \
		crontab_sync_backup_dir crontab_sync_log_dir crontab_sync_log_run_dir crontab_sync_log_cache_file \
		crontab_sync_runner_file crontab_sync_write_runner crontab_sync_write_run_tools crontab_sync_cron_entry || return 1
	declare -f server_retire_nginx_remove server_retire_nginx_reload || return 1
	cat <<'DAIMON_CERT_NGINX_SCRIPT' || return 1
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

validate_domain() { [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
validate_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != "." ] && [ "$1" != ".." ]; }

ACME="$HOME/.acme.sh/acme.sh"
NGINX_WAS_RUNNING=false
ACME_WEBROOT="/var/www/acme-challenge"
ACME_RENEW_SCRIPT="/root/linux-daimon/cert-renew.sh"
ACME_RENEW_LOG="/var/log/acme.sh/renew.log"
ACME_RENEW_LOCK="/run/lock/daimon-acme-renew.lock"
CERT_EXISTED_BEFORE=false

install_deps() {
    if command -v apt >/dev/null 2>&1; then
        if ! apt update -y; then
            echo -e "${YELLOW}存在失效的软件源，继续使用现有软件包索引；不修改该软件源。${NC}"
        fi
        apt install -y curl socat lsof dnsutils ufw openssl || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl socat lsof bind-utils ufw openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl socat lsof bind-utils ufw openssl
    else
        echo -e "${RED}未找到支持的依赖安装器${NC}"
        return 1
    fi
}

install_acme() {
    if [ ! -f "$ACME" ]; then
        echo -e "${GREEN}正在安装 acme.sh...${NC}"
        install_deps || return 1
        if ! (set -o pipefail; curl -fsSL --connect-timeout 10 --max-time 300 https://get.acme.sh | sh -s email=asdad@163.com); then
            echo -e "${RED}acme.sh 下载或安装失败${NC}"
            return 1
        fi
        if [ ! -x "$ACME" ]; then
            echo -e "${RED}acme.sh 安装失败${NC}"
            return 1
        fi
        echo -e "${GREEN}acme.sh 安装成功${NC}"
    else
        echo -e "${GREEN}acme.sh 已安装${NC}"
    fi
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || {
        echo -e "${RED}acme.sh 默认 CA 配置失败${NC}"
        return 1
    }
}

install_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 nginx...${NC}"
        command -v apt >/dev/null 2>&1 || { echo -e "${RED}当前 Nginx 自动安装仅支持 apt${NC}"; return 1; }
        if ! apt update -y; then
            echo -e "${YELLOW}存在失效的软件源，继续使用现有软件包索引安装 Nginx；不修改该软件源。${NC}"
        fi
        apt install -y nginx || return 1
        command -v nginx >/dev/null 2>&1 || return 1
    fi
    systemctl start nginx || return 1
    systemctl enable nginx || return 1
    systemctl is-active --quiet nginx || return 1
    echo -e "${GREEN}nginx 已安装并启动${NC}"
    nginx_domain_enable_auto_backup >/dev/null 2>&1 || echo -e "${YELLOW}nginx 已启动，但自动备份配置失败${NC}"
}

ensure_ufw_80() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            ufw allow 80/tcp 2>/dev/null || true
            ufw allow 443/tcp 2>/dev/null || true
        fi
    fi
}

nginx_domain_write_renew_script() {
    mkdir -p "$(dirname "$ACME_RENEW_SCRIPT")" "$(dirname "$ACME_RENEW_LOG")" "$(dirname "$ACME_RENEW_LOCK")" || return 1
    cat > "$ACME_RENEW_SCRIPT" <<'EOF' || return 1
#!/bin/bash
set -u
ACME="${HOME}/.acme.sh/acme.sh"
LOG_FILE="/var/log/acme.sh/renew.log"
LOCK_DIR="/run/lock/daimon-acme-renew.lock.d"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT
status=0
{
    printf '[%s] acme.sh renewal started\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    if ! "$ACME" --cron --home "${HOME}/.acme.sh"; then
        status=1
        logger -t daimon-acme-renew "acme.sh renewal failed"
    fi
    if ! nginx -t; then
        status=1
        logger -t daimon-acme-renew "nginx config test failed after certificate renewal"
    elif ! systemctl reload nginx; then
        status=1
        logger -t daimon-acme-renew "nginx reload failed after certificate renewal"
    fi
    printf '[%s] acme.sh renewal finished status=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$status"
} >> "$LOG_FILE" 2>&1
exit "$status"
EOF
    chmod 700 "$ACME_RENEW_SCRIPT" || return 1
    cat > /etc/logrotate.d/daimon-acme-renew <<EOF || return 1
$ACME_RENEW_LOG {
    daily
    rotate 30
    size 10M
    missingok
    notifempty
    compress
    copytruncate
}
EOF
}

nginx_domain_ensure_renew_cron() {
    nginx_domain_write_renew_script || return 1
    nginx_domain_ensure_crontab || return 1
    local cron_line="0 3 * * * /bin/bash $ACME_RENEW_SCRIPT >> $ACME_RENEW_LOG 2>&1"
    (crontab -l 2>/dev/null | grep -vF 'acme.sh --cron' | grep -vF "$ACME_RENEW_SCRIPT" || true; echo "$cron_line") | crontab -
}

nginx_domain_config_matches() {
    local domain="$1" conf="$2"
    awk -v domain="$domain" '
        $1 == "server_name" {
            for (i=2; i<=NF; i++) {
                value=$i; gsub(/;/, "", value)
                if (value == domain) found=1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$conf"
}

nginx_domain_config_has_challenge() {
    local domain="$1" conf
    for conf in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        nginx_domain_config_matches "$domain" "$conf" || continue
        awk '
            BEGIN { depth=0; in_server=0; listen80=0; has_location=0; bad_return=0 }
            {
                line=$0
                if (line ~ /^[[:space:]]*server[[:space:]]*\{/) in_server=1
                if (in_server && depth == 1 && line ~ /^[[:space:]]*listen[[:space:]]+((\[::\]:)?80)([[:space:];]|$)/) listen80=1
                if (in_server && depth == 1 && line ~ /location[[:space:]]+\^~[[:space:]]+\/\.well-known\/acme-challenge\//) has_location=1
                if (in_server && depth == 1 && line ~ /^[[:space:]]*return[[:space:]]+301[[:space:]]+/) bad_return=1
                opens=line; gsub(/[^\{]/, "", opens)
                closes=line; gsub(/[^\}]/, "", closes)
                depth += length(opens) - length(closes)
                if (in_server && depth == 0) {
                    if (listen80 && has_location && !bad_return) found=1
                    in_server=0; listen80=0; has_location=0; bad_return=0
                }
            }
            END { exit(found ? 0 : 1) }
        ' "$conf" && return 0
    done
    return 1
}

nginx_domain_config_exists() {
    local domain="$1" conf
    for conf in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        nginx_domain_config_matches "$domain" "$conf" || continue
        grep -Eq 'listen[[:space:]]+((\[::\]:)?80)([[:space:];]|$)' "$conf" 2>/dev/null && return 0
    done
    return 1
}

nginx_domain_patch_challenge_file() {
    local src="$1" tmp
    tmp=$(mktemp "${src}.tmp.XXXXXX") || return 1
    awk '
        BEGIN { has_location=0; depth=0; in_server=0 }
        {
            line=$0
            lines[NR]=line
            if (line ~ /^[[:space:]]*server[[:space:]]*\{/) in_server=1
            if (line ~ /location[[:space:]]+\^~[[:space:]]+\/\.well-known\/acme-challenge\//) has_location=1
            if (in_server && depth == 1 && line ~ /^[[:space:]]*return[[:space:]]+301[[:space:]]+.*;[[:space:]]*$/) {
                indent=line
                sub(/[^[:space:]].*$/, "", indent)
                redirect=line
                sub(/^[[:space:]]*return[[:space:]]+301[[:space:]]+/, "", redirect)
                sub(/[[:space:]]*;[[:space:]]*$/, "", redirect)
                redirect_indent[NR]=indent
                redirect_value[NR]=redirect
            }
            if (in_server && depth == 1 && line ~ /^[[:space:]]*listen[[:space:]]+((\[::\]:)?80)([[:space:];]|$)/) listen80[NR]=1
            opens=line; gsub(/[^\{]/, "", opens)
            closes=line; gsub(/[^\}]/, "", closes)
            depth += length(opens) - length(closes)
            if (in_server && depth == 0) in_server=0
        }
        END {
            inserted=0
            for (i=1; i<=NR; i++) {
                if (redirect_value[i] != "") {
                    print redirect_indent[i] "if ($request_uri !~ ^/\\.well-known/acme-challenge/) {"
                    print redirect_indent[i] "    return 301 " redirect_value[i] ";"
                    print redirect_indent[i] "}"
                } else {
                    print lines[i]
                }
                if (!has_location && !inserted && listen80[i]) {
                    print "    location ^~ /.well-known/acme-challenge/ {"
                    print "        root /var/www/acme-challenge;"
                    print "        default_type text/plain;"
                    print "        try_files $uri =404;"
                    print "    }"
                    inserted=1
                }
            }
            exit((inserted || has_location) ? 0 : 1)
        }
    ' "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$src"
}

nginx_domain_ensure_challenge_route() {
    local domain="$1" conf backup patched=0 idx
    local -a patched_files backup_files
    nginx_domain_config_has_challenge "$domain" && return 0
    for conf in /etc/nginx/sites-available/*; do
        [ -f "$conf" ] || continue
        nginx_domain_config_matches "$domain" "$conf" || continue
        grep -Eq 'listen[[:space:]]+((\[::\]:)?80)([[:space:];]|$)' "$conf" 2>/dev/null || continue
        backup=$(mktemp /tmp/daimon-nginx-conf.XXXXXX) || return 1
        cp -a "$conf" "$backup" || { rm -f "$backup"; return 1; }
        if ! nginx_domain_patch_challenge_file "$conf"; then
            cp -a "$backup" "$conf"
            rm -f "$backup"
            return 1
        fi
        patched_files+=("$conf")
        backup_files+=("$backup")
        patched=1
    done
    [ "$patched" -eq 1 ] || return 1
    if nginx -t && systemctl reload nginx; then
        rm -f "${backup_files[@]}"
        return 0
    fi
    for idx in "${!patched_files[@]}"; do
        cp -a "${backup_files[$idx]}" "${patched_files[$idx]}"
    done
    rm -f "${backup_files[@]}"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    return 1
}

nginx_domain_temp_challenge_server() {
    local domain="$1" id file
    id=$(printf '%s' "$domain" | sha256sum | awk '{print substr($1,1,16)}')
    file="/etc/nginx/conf.d/daimon-acme-${id}.conf"
    mkdir -p /etc/nginx/conf.d
    cat > "$file" <<EOF
server {
    listen 80;
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
}
EOF
    if nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
        printf '%s\n' "$file"
    else
        rm -f "$file"
        return 1
    fi
}

nginx_domain_remove_temp_challenge_server() {
    local file="$1"
    [ -f "$file" ] || return 0
    rm -f "$file"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
}

nginx_domain_verify_challenge() {
    local domain="$1" token token_file response
    token="daimon-acme-$RANDOM-$$-$(date +%s)"
    token_file="$ACME_WEBROOT/.well-known/acme-challenge/$token"
    mkdir -p "$(dirname "$token_file")"
    printf '%s' "$token" > "$token_file"
    for _ in $(seq 1 10); do
        response=$(curl -fsS --max-time 8 -H "Host: $domain" "http://127.0.0.1/.well-known/acme-challenge/$token" 2>/dev/null || true)
        [ "$response" = "$token" ] && { rm -f "$token_file"; return 0; }
        sleep 0.5
    done
    rm -f "$token_file"
    return 1
}

show_dns() {
    local d="$1"
    if command -v dig >/dev/null 2>&1; then
        echo -e "${YELLOW}DNS A 记录: $(dig +short "$d" A | tr '\n' ' ')${NC}"
        echo -e "${YELLOW}DNS AAAA记录: $(dig +short "$d" AAAA | tr '\n' ' ')${NC}"
    fi
}

restart_nginx_if_needed() {
    if [ "$NGINX_WAS_RUNNING" = true ]; then
        systemctl start nginx
        echo -e "${GREEN}nginx 已重新启动${NC}"
    fi
}

show_cert_list() {
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}acme.sh 已注册的证书列表：${NC}"
    "$ACME" --list 2>/dev/null || echo -e "${YELLOW}暂无已注册的证书${NC}"
    echo ""
    echo -e "${GREEN}/root/domain 下的证书文件夹：${NC}"
    [ -d "/root/domain" ] && ls -la /root/domain/ 2>/dev/null || echo -e "${YELLOW}目录为空${NC}"
    echo -e "${GREEN}=========================================${NC}"
}

show_existing_nginx_and_certs() {
    echo -e "${YELLOW}已存在的 nginx 配置：${NC}"
    local found_nginx=false
    local conf key real_path name server_name listen proxy_pass
    declare -A seen_nginx=()
    for conf in /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
        [ -e "$conf" ] || continue
        real_path=$(readlink -f "$conf" 2>/dev/null || echo "$conf")
        name=$(basename "$conf")
        key="$name|$real_path"
        if [ -n "${seen_nginx[$key]:-}" ]; then
            continue
        fi
        seen_nginx[$key]=1
        found_nginx=true
        server_name=$(grep -E '^[[:space:]]*server_name[[:space:]]+' "$conf" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;[[:space:]]*$//')
        listen=$(grep -E '^[[:space:]]*listen[[:space:]]+' "$conf" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*listen[[:space:]]+//; s/;[[:space:]]*$//')
        proxy_pass=$(grep -E '^[[:space:]]*proxy_pass[[:space:]]+' "$conf" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*proxy_pass[[:space:]]+//; s/;[[:space:]]*$//')
        printf "  %-38s server_name=%s listen=%s proxy=%s\n" "$name" "${server_name:-未设置}" "${listen:-未设置}" "${proxy_pass:-无}"
    done
    [ "$found_nginx" = true ] || echo "  暂无 nginx 配置"
    echo "---"
    echo -e "${YELLOW}已存在的证书：${NC}"
    local found_cert=false
    local cert_dir cert_file domain expire_date formatted_date
    declare -A seen_cert=()
    for cert_dir in /root/domain/* /etc/letsencrypt/live/*; do
        [ -d "$cert_dir" ] || continue
        cert_file="$cert_dir/fullchain.pem"
        [ -f "$cert_file" ] || continue
        domain=$(basename "$cert_dir")
        if [ -n "${seen_cert[$domain]:-}" ]; then
            continue
        fi
        seen_cert[$domain]=1
        found_cert=true
        expire_date=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | awk -F'=' '{print $2}')
        formatted_date=$(date -d "$expire_date" '+%Y-%m-%d' 2>/dev/null || echo "未知")
        printf "  %-38s 到期时间=%s 路径=%s\n" "$domain" "$formatted_date" "$cert_file"
    done
    [ "$found_cert" = true ] || echo "  暂无证书"
    echo "---"
}

nginx_domain_cert_dir_for_domain() {
    local domain="$1" conf cert_path
    for conf in /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        nginx_domain_config_matches "$domain" "$conf" || continue
        cert_path=$(awk '$1 == "ssl_certificate" { gsub(/;/, "", $2); print $2; exit }' "$conf")
        case "$cert_path" in
            /root/domain/*/fullchain.pem) dirname "$cert_path"; return 0 ;;
        esac
    done
    # Keep the certificate layout compatible with cert_nginx.sh: /root/domain/<first-label>.
    printf '/root/domain/%s\n' "${domain%%.*}"
}

cleanup_nginx_and_cert() {
    echo -e "${YELLOW}申请失败；无法证明旧配置或证书属于本次操作，已保留，请核查。临时挑战配置由申请流程单独清理。${NC}"
}

cleanup_failed_cert_request() {
    cleanup_nginx_and_cert "$@"
}

nginx_domain_remove_cert_safe() {
    python3 - "$1" "$2" "$ACME" "$ACME_RENEW_LOCK" <<'PYCERT_REMOVE'
import fcntl, hashlib, json, os, re, shutil, stat, subprocess, sys
from pathlib import Path

def require(ok, message):
    if not ok: raise ValueError(message)

def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    require(result.returncode == 0, 'Cannot verify certificate usage or remove registration; files retained')
    return result.stdout

def stamp(path):
    info = path.lstat()
    require(path.resolve() == path and stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022,
            'Untrusted certificate file')
    return (info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns, hashlib.sha256(path.read_bytes()).digest())

def remove(domain, directory, acme, lock_path):
    require(os.geteuid() == 0, 'Root required')
    require(re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', domain), 'Invalid domain')
    root = Path('/root/domain')
    target = Path(directory)
    require(target.parent == root and target.name in (domain, domain.split('.')[0]) and target.resolve() == target,
            'Not a direct managed certificate directory')
    for parent in (target, *target.parents):
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022 and parent.resolve() == parent, 'Untrusted certificate directory')
    lock_path = Path(lock_path)
    require(lock_path.parent.resolve() == lock_path.parent and lock_path.parent.stat().st_uid == 0, 'Untrusted lock directory')
    mode = lock_path.parent.stat().st_mode
    require(not mode & 0o022 or mode & stat.S_ISVTX, 'Unsafe lock directory')
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022, 'Unsafe lock')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    files = sorted(target.iterdir())
    require(files and all(p.name in ('fullchain.pem', 'privkey.pem', 'cert.pem', 'chain.pem') for p in files), 'Unexpected certificate directory contents')
    original = {p: stamp(p) for p in files}
    san = run(['openssl', 'x509', '-in', str(target/'fullchain.pem'), '-noout', '-ext', 'subjectAltName']).splitlines()
    require(len(san) == 2 and san[1].strip().lower() == 'dns:' + domain.lower(), 'Certificate is shared, wildcard, or not exclusively for this domain')
    def unused():
        contents = []
        for base in (Path('/etc/nginx'), Path('/home/web/conf.d')):
            if base.exists():
                for path in base.rglob('*'):
                    if path.is_symlink(): require(path.exists() and not path.is_dir(), 'Linked configuration directory or unresolved link requires manual checking')
                    if path.is_file(): contents.append(path.read_text(errors='replace'))
        if shutil.which('nginx'): contents.append(run(['nginx', '-T']))
        for content in contents:
            require(str(target) not in content and not re.search(r'ssl_certificate(?:_key)?\s+[^;]*\$', content),
                    'Certificate still referenced by Nginx; remove its configuration first')
        acme_home = Path(acme).parent
        for path in acme_home.glob('*/*.conf'):
            if path.parent.name not in (domain, domain + '_ecc'):
                require(str(target) not in path.read_text(errors='replace'), 'Another renewal record uses this directory')
        if shutil.which('docker'):
            ids = run(['docker', 'ps', '-aq']).split()
            if ids:
                containers = json.loads(run(['docker', 'inspect', *ids]))
                for container in containers:
                    for mount in container.get('Mounts', []):
                        source = Path(mount.get('Source') or '/')
                        require(not (source == target or source in target.parents or target in source.parents), 'Certificate directory is mounted by a container')
        for proc in Path('/proc').iterdir():
            if not proc.name.isdecimal(): continue
            try:
                for entry in (proc/'fd').iterdir():
                    try:
                        path = entry.resolve()
                        require(path != target and target not in path.parents, 'Certificate files are open')
                    except FileNotFoundError: pass
            except (FileNotFoundError, ProcessLookupError): pass
    unused()
    require(original == {p: stamp(p) for p in sorted(target.iterdir())}, 'Certificate changed')
    home = Path(acme).parent
    ecc = (home/(domain + '_ecc')).is_dir()
    require(not (ecc and (home/domain).is_dir()), 'Both RSA and ECC renewal records exist; choose the exact record manually')
    run([acme, '--remove', '-d', domain] + (['--ecc'] if ecc else []))
    unused()
    require(original == {p: stamp(p) for p in sorted(target.iterdir())}, 'Certificate changed after deregistration; files retained')
    for path in files:
        require(stamp(path) == original[path], 'Certificate changed during removal')
        path.unlink()
    target.rmdir()
    print('Exclusive certificate removed; no shared directory was recursively deleted.')

if __name__ == '__main__':
    try: remove(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Certificate removal incomplete: ' + str(error), file=sys.stderr)
        sys.exit(1)
PYCERT_REMOVE
}

remove_cert() {
    echo -e "${GREEN}当前已注册的证书：${NC}"
    "$ACME" --list 2>/dev/null || echo -e "${YELLOW}暂无已注册的证书${NC}"
    echo ""

    read -p "请输入要移除的域名: " REMOVE_DOMAIN
    [ -z "$REMOVE_DOMAIN" ] && echo -e "${RED}域名不能为空${NC}" && return 1

    read -p "确认移除 $REMOVE_DOMAIN？[y/n]: " CONFIRM
    [ "$CONFIRM" != "y" ] && return 0

    validate_domain "$REMOVE_DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; return 1; }

    local cert_dir
    cert_dir=$(nginx_domain_cert_dir_for_domain "$REMOVE_DOMAIN") || return 1
    nginx_domain_remove_cert_safe "$REMOVE_DOMAIN" "$cert_dir"
}

remove_nginx_config() {
    echo -e "${GREEN}当前 nginx 配置文件：${NC}"
    echo ""

    local configs=()
    local i=1
    for f in /etc/nginx/sites-available/*; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        [ "$name" = "default" ] && continue
        configs+=("$name")
        echo "$i) $name"
        ((i++))
    done

    [ ${#configs[@]} -eq 0 ] && echo -e "${YELLOW}暂无自定义配置${NC}" && return 0

    echo ""
    read -p "请输入要删除的配置编号: " NUM

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#configs[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi

    local CONF_NAME="${configs[$((NUM-1))]}"
    read -p "确认删除 $CONF_NAME？[y/n]: " CONFIRM
    [ "$CONFIRM" != "y" ] && return 0

    server_retire_nginx_remove "/etc/nginx/sites-available/$CONF_NAME" ""
}

remove_nginx_and_cert() {
    echo -e "${GREEN}当前 nginx 配置文件：${NC}"
    echo ""

    local configs=()
    local i=1
    for f in /etc/nginx/sites-available/*; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        [ "$name" = "default" ] && continue
        configs+=("$name")
        echo "$i) $name"
        ((i++))
    done

    [ ${#configs[@]} -eq 0 ] && echo -e "${YELLOW}暂无自定义配置${NC}" && return 0

    echo ""
    read -p "请输入要删除的配置编号: " NUM

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#configs[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi

    local CONF_NAME="${configs[$((NUM-1))]}"

    # 从配置文件中提取证书路径
    local CONF_FILE="/etc/nginx/sites-available/$CONF_NAME"
    local CERT_DIR=$(grep -oP 'ssl_certificate \K[^;]+' "$CONF_FILE" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
    local DOMAIN=$(grep -oP 'server_name \K[^;]+' "$CONF_FILE" 2>/dev/null | head -1 | awk '{print $1}' || true)

    echo ""
    echo -e "${YELLOW}将删除以下内容：${NC}"
    echo "- nginx 配置: $CONF_FILE"
    [ -n "$CERT_DIR" ] && [ -d "$CERT_DIR" ] && echo "- 证书目录: $CERT_DIR"
    [ -n "$DOMAIN" ] && echo "- acme.sh 证书: $DOMAIN"
    echo ""

    read -p "确认删除？[y/n]: " CONFIRM
    [ "$CONFIRM" != "y" ] && return 0

    server_retire_nginx_remove "$CONF_FILE" "$DOMAIN" || return 1
    nginx_domain_remove_cert_safe "$DOMAIN" "$CERT_DIR" || {
        echo "Nginx 配置已移除；证书未完整移除，请按上方原因核查，不会强删共享目录。"
        return 1
    }
}

create_test_page() {
    read -p "请输入测试文件名称: " TEST_NAME || return 1
    validate_name "$TEST_NAME" || { echo -e "${RED}测试名称格式不合法${NC}"; return 1; }
    read -p "请输入测试端口号: " TEST_PORT || return 1
    validate_port "$TEST_PORT" || { echo -e "${RED}测试端口不合法${NC}"; return 1; }
    local path
    for path in "/var/www/$TEST_NAME" "/etc/nginx/sites-available/$TEST_NAME" "/etc/nginx/sites-enabled/$TEST_NAME"; do
        if [ -e "$path" ] || [ -L "$path" ] || [ "$(realpath -m -- "$path")" != "$path" ]; then
            echo -e "${RED}目标路径已存在或不安全，未覆盖: $path${NC}"
            return 1
        fi
    done

    install_nginx || return 1

    mkdir "/var/www/$TEST_NAME" || return 1
    cat > "/var/www/$TEST_NAME/index.html" << EOF || return 1
<!DOCTYPE html>
<html>
<head>
    <title>$TEST_NAME 测试页面</title>
</head>
<body>
    <h1>$TEST_NAME - 端口 $TEST_PORT 测试成功！</h1>
    <p>测试名称: $TEST_NAME</p>
    <p>监听端口: $TEST_PORT</p>
</body>
</html>
EOF

    cat > "/etc/nginx/sites-available/$TEST_NAME" << EOF || return 1
server {
    listen $TEST_PORT;
    server_name localhost;
    root /var/www/$TEST_NAME;
    index index.html;
}
EOF

    ln -s "/etc/nginx/sites-available/$TEST_NAME" /etc/nginx/sites-enabled/ || return 1

    if nginx -t && nginx -s reload; then
        printf '%s\n' "$TEST_NAME" > "/var/www/$TEST_NAME/.daimon-test-page" || return 1
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}测试页面创建成功！${NC}"
        echo "网页目录: /var/www/$TEST_NAME"
        echo "配置文件: /etc/nginx/sites-available/$TEST_NAME"
        echo "访问地址: http://127.0.0.1:$TEST_PORT"
        echo ""
        echo -e "${YELLOW}测试访问:${NC}"
        curl "http://127.0.0.1:$TEST_PORT" 2>/dev/null || echo -e "${RED}访问失败${NC}"
        echo -e "${GREEN}=========================================${NC}"
    else
        echo -e "${RED}nginx 配置检测失败${NC}"
        rm -f -- "/etc/nginx/sites-available/$TEST_NAME" "/etc/nginx/sites-enabled/$TEST_NAME"
        rm -rf -- "/var/www/$TEST_NAME"
        return 1
    fi
}

nginx_test_page_is_managed() {
    local name="$1" directory="/var/www/$1" config="/etc/nginx/sites-available/$1"
    validate_name "$name" && [ "$name" != html ] || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] && [ -f "$config" ] && [ ! -L "$config" ] || return 1
    [ "$(realpath -e -- "$directory")" = "$directory" ] && [ "$(realpath -e -- "$config")" = "$config" ] || return 1
    [ -f "$directory/.daimon-test-page" ] && [ ! -L "$directory/.daimon-test-page" ] || return 1
    grep -Fxq -- "$name" "$directory/.daimon-test-page"
}

remove_test_page() {
    echo -e "${GREEN}当前测试页面：${NC}"
    echo ""

    local tests=()
    local i=1
    for d in /var/www/*/; do
        [ -d "$d" ] || continue
        local name=$(basename "$d")
        nginx_test_page_is_managed "$name" || continue
        tests+=("$name")
        echo "$i) $name"
        ((i++))
    done

    [ ${#tests[@]} -eq 0 ] && echo -e "${YELLOW}暂无测试页面${NC}" && return 0

    echo ""
    read -p "请输入要删除的测试页面编号: " NUM || return 1

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#tests[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi

    local TEST_NAME="${tests[$((NUM-1))]}"
    read -p "确认删除 $TEST_NAME？[y/n]: " CONFIRM || return 1
    [ "$CONFIRM" != "y" ] && return 0

    nginx_test_page_is_managed "$TEST_NAME" || return 1
    rm -f -- "/etc/nginx/sites-enabled/$TEST_NAME" "/etc/nginx/sites-available/$TEST_NAME" || return 1
    rm -rf -- "/var/www/$TEST_NAME" || return 1

    nginx -t && nginx -s reload || return 1
    echo -e "${GREEN}测试页面 $TEST_NAME 已删除${NC}"
}


nginx_domain_backup_root() {
    echo "${DAIMON_BACKUP_DIR:-/root/linux-daimon/backup}/nginx-domain"
}

nginx_domain_auto_backup_dir() {
    echo "$(nginx_domain_backup_root)/auto_latest"
}

nginx_domain_auto_backup_script() {
    echo "${DAIMON_BACKUP_SH_DIR:-/root/linux-daimon/backup-sh}/Nginx_Domain_Local_Backup.sh"
}

nginx_domain_auto_backup_cron_line() {
    crontab_sync_cron_entry "0 4 * * * /bin/bash $(crontab_sync_runner_file) nginxdomain $(nginx_domain_auto_backup_script) >> /var/log/rclone/cron_Nginx_Domain_Local_Backup.log 2>&1"
}

nginx_domain_has_domains() {
    find /root/domain -mindepth 2 -maxdepth 2 -type f -name fullchain.pem -size +0c -print -quit 2>/dev/null | grep -q .
}

nginx_domain_write_auto_backup_script() {
    local script_file
    script_file="$(nginx_domain_auto_backup_script)"
    mkdir -p "$(dirname "$script_file")" /var/log/rclone || return 1
    rclone_nginx_write_backup_script "$script_file" || return 1
    chmod +x "$script_file"
}

nginx_domain_ensure_crontab() {
    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            if ! apt update -y; then
                echo -e "${YELLOW}存在失效的软件源，继续使用现有软件包索引安装 cron；不修改该软件源。${NC}"
            fi
            apt install -y cron || return 1
        fi
    fi
    command -v crontab >/dev/null 2>&1 || return 1
    systemctl enable cron || return 1
    systemctl start cron
}

nginx_domain_enable_auto_backup() {
	local script_file cron_line
	script_file="$(nginx_domain_auto_backup_script)"
	crontab_sync_write_run_tools || return 1
	cron_line="$(nginx_domain_auto_backup_cron_line)"
    nginx_domain_write_auto_backup_script || return 1
    nginx_domain_ensure_crontab || return 1
    (crontab -l 2>/dev/null | grep -vF "$script_file" || true; echo "$cron_line") | crontab -
}

nginx_domain_disable_auto_backup() {
    local script_file
    script_file="$(nginx_domain_auto_backup_script)"
    rm -f "$script_file"
    crontab -l 2>/dev/null | grep -vF "$script_file" | crontab - 2>/dev/null || true
    rm -rf "$(nginx_domain_auto_backup_dir).tmp"
}

nginx_domain_sync_auto_backup_state() {
    local script_file
    script_file="$(nginx_domain_auto_backup_script)"
    if [ -f "$script_file" ]; then
        /bin/bash "$script_file" >/dev/null 2>&1 || true
    fi
}

nginx_domain_auto_backup_status() {
    local script_file cron_line backup_dir cron_output
    script_file="$(nginx_domain_auto_backup_script)"
    cron_line="$(nginx_domain_auto_backup_cron_line)"
    backup_dir="$(nginx_domain_auto_backup_dir)"
    cron_output=$(crontab -l 2>/dev/null || true)
    if [ -f "$script_file" ] && echo "$cron_output" | grep -Fxq "$cron_line"; then
        if [ -d "$backup_dir" ]; then
            echo -e "${GREEN}已开启，最新备份: $backup_dir${NC}"
        else
            echo -e "${GREEN}已开启，等待生成备份${NC}"
        fi
    elif [ -f "$script_file" ] && echo "$cron_output" | grep -Fq "$script_file"; then
        echo -e "${YELLOW}已加入定时，任务行需要更新${NC}"
    else
        echo -e "${YELLOW}未开启${NC}"
    fi
}

backup_nginx_domain() {
    local script_file backup_dir
    if ! nginx_domain_has_domains; then
        echo -e "${YELLOW}未检测到域名证书，跳过备份，已有备份不会删除。${NC}"
        return 0
    fi
    nginx_domain_enable_auto_backup || return 1
    script_file="$(nginx_domain_auto_backup_script)"
    backup_dir="$(nginx_domain_auto_backup_dir)"
	/bin/bash "$(crontab_sync_runner_file)" nginxdomain "$script_file" || return 1
    echo -e "${GREEN}备份完成：$backup_dir${NC}"
}

restore_nginx_domain() {
    local backup_dir confirm
    backup_dir="$(nginx_domain_auto_backup_dir)"

    if [ ! -d "$backup_dir" ]; then
        echo -e "${YELLOW}暂无可恢复的自动备份：$backup_dir${NC}"
        return 0
    fi

    echo -e "${GREEN}将恢复最新备份：$backup_dir${NC}"
    [ -f "$backup_dir/manifest.txt" ] && sed 's/^/  /' "$backup_dir/manifest.txt" | head -n 5
    read -p "恢复会合并备份内容，同名文件保留本机现有版本，是否继续？[y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        return 0
    fi

    rclone_nginx_apply "$backup_dir" all keep
}

setup_cron() {
    nginx_domain_ensure_renew_cron || return 1
    echo -e "${GREEN}已配置 webroot 自动续期（每天凌晨3点）${NC}"
}

# 申请证书
issue_cert() {
    local DOMAIN="$1" temp_challenge="" existing_conf="" keylength=""
    local -a issue_args install_args

    validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; return 1; }
    install_acme || return 1
    show_dns "$DOMAIN"
    CERT_DIR=$(nginx_domain_cert_dir_for_domain "$DOMAIN")
    mkdir -p "$CERT_DIR"

    CERT_EXISTED_BEFORE=false
    if "$ACME" --list 2>/dev/null | grep -Fq "$DOMAIN" || [ -s "$CERT_DIR/fullchain.pem" ]; then
        CERT_EXISTED_BEFORE=true
        echo -e "${YELLOW}检测到已有证书，将使用 webroot 强制更新，不删除旧证书...${NC}"
    fi

    ensure_ufw_80
    mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
    if ! command -v nginx >/dev/null 2>&1 || ! systemctl is-active nginx >/dev/null 2>&1; then
        install_nginx || return 1
    fi
    if ! nginx_domain_ensure_challenge_route "$DOMAIN"; then
        if nginx_domain_config_exists "$DOMAIN"; then
            echo -e "${RED}$DOMAIN 已有 HTTP 配置，但无法安全加入 ACME challenge 路径，请检查对应 Nginx 配置${NC}"
            return 1
        fi
        if ! temp_challenge=$(nginx_domain_temp_challenge_server "$DOMAIN"); then
            echo -e "${RED}无法为 $DOMAIN 配置 ACME webroot 验证路径${NC}"
            return 1
        fi
    fi
    if ! nginx_domain_verify_challenge "$DOMAIN"; then
        echo -e "${RED}$DOMAIN 的 webroot challenge 本机验证失败，未向 CA 发起申请${NC}"
        nginx_domain_remove_temp_challenge_server "$temp_challenge"
        return 1
    fi

    issue_args=(-d "$DOMAIN" -w "$ACME_WEBROOT" --server letsencrypt --force)
    existing_conf=$(find "$HOME/.acme.sh/${DOMAIN}_ecc" "$HOME/.acme.sh/$DOMAIN" -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null || true)
    [ -n "$existing_conf" ] && keylength=$(nginx_domain_acme_conf_value "$existing_conf" Le_Keylength)
    [ -n "$keylength" ] && [ "$keylength" != "no" ] && issue_args+=(--keylength "$keylength")
    if ! "$ACME" --issue "${issue_args[@]}"; then
        echo -e "${RED}证书申请失败${NC}"
        nginx_domain_remove_temp_challenge_server "$temp_challenge"
        return 1
    fi

    install_args=(--fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" --reloadcmd "nginx -t && systemctl reload nginx" --force)
    [ -d "$HOME/.acme.sh/${DOMAIN}_ecc" ] && install_args+=(--ecc)
    if ! "$ACME" --install-cert -d "$DOMAIN" "${install_args[@]}"; then
        echo -e "${RED}证书安装失败${NC}"
        nginx_domain_remove_temp_challenge_server "$temp_challenge"
        return 1
    fi

    nginx_domain_remove_temp_challenge_server "$temp_challenge"

    if [ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/privkey.pem" ]; then
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}证书申请成功！${NC}"
        echo "证书路径: $CERT_DIR"
        ls -la "$CERT_DIR"
        echo -e "${GREEN}=========================================${NC}"
        setup_cron || echo -e "${YELLOW}证书已签发，但自动续期配置失败，请修复后重新配置续期${NC}"
        nginx_domain_enable_auto_backup >/dev/null 2>&1 || true
        return 0
    else
        echo -e "${RED}证书安装失败${NC}"
        return 1
    fi
}

# 配置 nginx
config_nginx() {
    local DOMAIN="$1"
    local NGINX_NAME="$2"
    local PORT="$3"
    local CERT_DIR

    validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; return 1; }
    validate_name "$NGINX_NAME" || { echo -e "${RED}配置名只能包含字母、数字、点、下划线和连字符${NC}"; return 1; }
    validate_port "$PORT" || { echo -e "${RED}端口号不合法${NC}"; return 1; }
    CERT_DIR=$(nginx_domain_cert_dir_for_domain "$DOMAIN")

    # 检查证书是否存在
    if [ ! -s "$CERT_DIR/fullchain.pem" ] || [ ! -s "$CERT_DIR/privkey.pem" ]; then
        echo -e "${RED}证书文件不存在: $CERT_DIR${NC}"
        echo -e "${RED}请先申请证书${NC}"
        return 1
    fi

    install_nginx || return 1

    NGINX_CONF="/etc/nginx/sites-available/$NGINX_NAME"

    cat > "$NGINX_CONF" << EOF || return 1
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
    if (\$request_uri !~ ^/\\.well-known/acme-challenge/) {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";

        proxy_buffering off;
        client_max_body_size 50M;
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/ || return 1

    if nginx -t; then
        systemctl reload nginx || return 1
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}nginx 配置成功！${NC}"
        echo "配置文件: $NGINX_CONF"
        echo "域名: $DOMAIN"
        echo "代理端口: $PORT"
        echo -e "${GREEN}=========================================${NC}"
        systemctl status nginx --no-pager
    else
        echo -e "${RED}nginx 配置检测失败${NC}"
        rm -f "$NGINX_CONF" "/etc/nginx/sites-enabled/$NGINX_NAME"
        return 1
    fi
}

nginx_domain_acme_conf_value() {
    local conf="$1" key="$2"
    awk -F= -v key="$key" '
        $1 == key {
            value=substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            first=substr(value, 1, 1); last=substr(value, length(value), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) value=substr(value, 2, length(value) - 2)
            print value
            exit
        }
    ' "$conf"
}

nginx_domain_migrate_existing_certs() {
    local conf domain alt keylength challenge_domain temp_challenge route_failed unsupported_alt cert_dir
    local confirm
    local success=0 failed=0 skipped=0
    local -a alt_args issue_args install_args challenge_domains temp_challenges
    [ "$(id -u)" -eq 0 ] || { echo -e "${RED}请使用 root 运行${NC}"; return 1; }
    [ -x "$ACME" ] || { echo -e "${RED}未检测到 acme.sh，请先申请或安装证书${NC}"; return 1; }
    echo -e "${YELLOW}将逐个强制重新签发可迁移证书，可能触发 CA 频率限制。${NC}"
    read -p "确认开始迁移？[y/N]: " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "已取消"; return 0; }
    install_nginx || return 1
    mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"

    while IFS= read -r conf; do
        domain=$(nginx_domain_acme_conf_value "$conf" Le_Domain)
        [ -n "$domain" ] || continue
        if [[ "$domain" == \** ]] || ! validate_domain "$domain"; then
            echo -e "${YELLOW}跳过不支持 webroot 的域名: $domain${NC}"
            skipped=$((skipped + 1))
            continue
        fi
        alt_args=()
        challenge_domains=("$domain")
        unsupported_alt=false
        alt=$(nginx_domain_acme_conf_value "$conf" Le_Alt)
        [ "$alt" = "no" ] && alt=""
        while IFS= read -r alt; do
            [ -n "$alt" ] || continue
            if [[ "$alt" == \** ]] || ! validate_domain "$alt"; then
                unsupported_alt=true
                break
            fi
            alt_args+=(-d "$alt")
            challenge_domains+=("$alt")
        done < <(printf '%s' "$alt" | tr ',' '\n')
        if [ "$unsupported_alt" = true ]; then
            echo -e "${YELLOW}跳过包含通配符或不支持 SAN 的证书: $domain${NC}"
            skipped=$((skipped + 1))
            continue
        fi
        keylength=$(nginx_domain_acme_conf_value "$conf" Le_Keylength)
        [ "$keylength" = "no" ] && keylength=""
        issue_args=(-d "$domain" "${alt_args[@]}" -w "$ACME_WEBROOT" --server letsencrypt --force)
        temp_challenges=()
        route_failed=false
        for challenge_domain in "${challenge_domains[@]}"; do
            if ! nginx_domain_ensure_challenge_route "$challenge_domain"; then
                if nginx_domain_config_exists "$challenge_domain"; then
                    route_failed=true
                    break
                fi
                temp_challenge=$(nginx_domain_temp_challenge_server "$challenge_domain" 2>/dev/null || true)
                [ -n "$temp_challenge" ] && temp_challenges+=("$temp_challenge") || { route_failed=true; break; }
            fi
            nginx_domain_verify_challenge "$challenge_domain" || { route_failed=true; break; }
        done
        if [ "$route_failed" = true ]; then
            for temp_challenge in "${temp_challenges[@]}"; do nginx_domain_remove_temp_challenge_server "$temp_challenge"; done
            echo -e "${RED}$domain 或其 SAN 没有可用的 ACME challenge 路径，已跳过${NC}"
            skipped=$((skipped + 1))
            continue
        fi
        [ -n "$keylength" ] && issue_args+=(--keylength "$keylength")
        echo -e "${YELLOW}正在迁移证书: $domain${NC}"
        if ! "$ACME" --issue "${issue_args[@]}"; then
            echo -e "${RED}$domain webroot 重新签发失败，保留旧证书${NC}"
            failed=$((failed + 1))
            for temp_challenge in "${temp_challenges[@]}"; do nginx_domain_remove_temp_challenge_server "$temp_challenge"; done
            continue
        fi
        cert_dir=$(nginx_domain_cert_dir_for_domain "$domain")
        mkdir -p "$cert_dir"
        install_args=(--fullchain-file "$cert_dir/fullchain.pem" --key-file "$cert_dir/privkey.pem" --reloadcmd "nginx -t && systemctl reload nginx" --force)
        [[ "$(dirname "$conf")" == *_ecc ]] && install_args+=(--ecc)
        if "$ACME" --install-cert -d "$domain" "${install_args[@]}"; then
            echo -e "${GREEN}$domain 迁移成功${NC}"
            success=$((success + 1))
        else
            echo -e "${RED}$domain 证书安装失败，保留旧证书${NC}"
            failed=$((failed + 1))
        fi
        for temp_challenge in "${temp_challenges[@]}"; do nginx_domain_remove_temp_challenge_server "$temp_challenge"; done
    done < <(find "$HOME/.acme.sh" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print 2>/dev/null | sort)
    setup_cron || true
    nginx -t && systemctl reload nginx || true
    echo -e "${GREEN}迁移完成：成功 $success，失败 $failed，跳过 $skipped${NC}"
    [ "$failed" -eq 0 ]
}

# -------------------- 主流程 --------------------

if [ "${1:-}" = "--install-renewal" ]; then
    install_acme || exit 1
    setup_cron || exit 1
    echo -e "${GREEN}Nginx + 域名续期脚本已安装${NC}"
    exit 0
fi

show_menu() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}       Nginx + 域名管理${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "域名备份: $(nginx_domain_auto_backup_status)"
    echo "---"
    show_existing_nginx_and_certs
    echo "1) 申请证书 + 配置 nginx"
    echo "2) 删除 nginx 配置 + 证书"
    echo "3) 申请证书 (webroot 模式)"
    echo "4) 移除证书"
    echo "5) 查看证书列表"
    echo "6) 配置 nginx"
    echo "7) 删除 nginx 配置"
    echo "8) 创建测试页面"
    echo "9) 删除测试页面"
    echo "10) 安装 nginx"
    echo "11) 备份域名 + nginx 配置"
    echo "12) 恢复域名 + nginx 配置"
    echo "13) 迁移/修复现有证书（webroot）"
    echo "0) 返回上一级菜单"
    echo -e "${GREEN}=========================================${NC}"
}

while true; do
    show_menu
    read -p "请选择操作 [0-13]: " ACTION

    case $ACTION in
        1)
            read -p "请输入域名: " DOMAIN
            validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; continue; }
            read -p "请输入 nginx 配置文件名称: " NGINX_NAME
            validate_name "$NGINX_NAME" || { echo -e "${RED}配置名不合法${NC}"; continue; }
            read -p "请输入代理端口号: " PORT
            validate_port "$PORT" || { echo -e "${RED}端口号不合法${NC}"; continue; }

            if issue_cert "$DOMAIN"; then
                restart_nginx_if_needed
                if ! config_nginx "$DOMAIN" "$NGINX_NAME" "$PORT"; then
                    cleanup_failed_cert_request "$DOMAIN" "$NGINX_NAME"
                fi
            else
                restart_nginx_if_needed
                cleanup_failed_cert_request "$DOMAIN" "$NGINX_NAME"
            fi
            ;;
        2)
            remove_nginx_and_cert
            ;;
        3)
            read -p "请输入域名: " DOMAIN
            validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; continue; }
            issue_cert "$DOMAIN"
            restart_nginx_if_needed
            ;;
        4)
            remove_cert
            ;;
        5)
            show_cert_list
            ;;
        6)
            read -p "请输入域名: " DOMAIN
            validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; continue; }
            read -p "请输入 nginx 配置文件名称: " NGINX_NAME
            validate_name "$NGINX_NAME" || { echo -e "${RED}配置名不合法${NC}"; continue; }
            read -p "请输入代理端口号: " PORT
            validate_port "$PORT" || { echo -e "${RED}端口号不合法${NC}"; continue; }
            config_nginx "$DOMAIN" "$NGINX_NAME" "$PORT"
            ;;
        7)
            remove_nginx_config
            ;;
        8)
            create_test_page
            ;;
        9)
            remove_test_page
            ;;
        10)
            install_nginx
            nginx -v 2>&1 || true
            systemctl status nginx --no-pager 2>/dev/null || true
            ;;
        11)
            backup_nginx_domain
            ;;
        12)
            restore_nginx_domain
            ;;
        13)
            nginx_domain_migrate_existing_certs
            ;;
        0)
            echo -e "${GREEN}返回上一级菜单${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac

    echo ""
    read -p "按回车键返回主菜单..."
done
DAIMON_CERT_NGINX_SCRIPT
	} > "$DAIMON_SCRIPT_DIR/cert_nginx.sh" || return 1
	chmod +x "$DAIMON_SCRIPT_DIR/cert_nginx.sh" || return 1
	if [ "${DAIMON_UPDATE_CERT_HELPER_ONLY:-0}" = "1" ]; then
		if bash "$DAIMON_SCRIPT_DIR/cert_nginx.sh" --install-renewal; then
			echo -e "${gl_lv}Nginx + 域名续期脚本已更新: $DAIMON_SCRIPT_DIR/cert_nginx.sh${gl_bai}"
			return 0
		fi
		echo -e "${gl_hong}Nginx + 域名续期脚本更新失败${gl_bai}"
		return 1
	fi
	bash "$DAIMON_SCRIPT_DIR/cert_nginx.sh"
}
