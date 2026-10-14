#!/bin/bash

ssl_nginx_manager() {
	mkdir -p "$DAIMON_SCRIPT_DIR" || return 1
	{
	printf '#!/bin/bash\n'
	declare -f install ssh_current_ports rclone_restore_name_valid rclone_tree_safe rclone_assert_inactive rclone_require_space \
		rclone_nginx_prepare rclone_nginx_allow_ports rclone_nginx_cert_valid rclone_nginx_apply \
		rclone_nginx_target_for_key rclone_nginx_loaded_files rclone_nginx_check_manifest \
		rclone_nginx_write_bundle rclone_nginx_write_backup_script rclone_check_nginx_after_restore rclone_nginx_restore_renewal \
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
ISSUE_METHOD=""
DNS_API=""
DNS_KEYS_TYPED=false

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

# One line per certificate, fields separated by "|":
# domain|expiry|renewal|fullchain path|managed by acme.sh|referenced by Nginx|names
nginx_domain_cert_rows() {
    python3 - "$HOME/.acme.sh" <<'PYCERT_ROWS'
import os, re, subprocess, sys
from pathlib import Path

home = Path(sys.argv[1])

def values(path):
    data = {}
    for line in path.read_text(errors='replace').splitlines():
        key, sep, value = line.partition('=')
        if sep:
            data[key.strip()] = value.strip().strip('\'"')
    return data

def info(path):
    result = subprocess.run(['openssl', 'x509', '-in', str(path), '-noout', '-enddate', '-ext', 'subjectAltName'],
                            capture_output=True, text=True)
    if result.returncode:
        return '', []
    end = re.search(r'notAfter=(.+)', result.stdout)
    expiry = ''
    if end:
        expiry = subprocess.run(['date', '-d', end.group(1).strip(), '+%F'], capture_output=True, text=True).stdout.strip()
    return expiry, re.findall(r'DNS:([^,\s]+)', result.stdout)

records = {}
for conf in (sorted(home.glob('*/*.conf')) if home.is_dir() else []):
    name = conf.parent.name[:-4] if conf.parent.name.endswith('_ecc') else conf.parent.name
    if conf.name != name + '.conf':
        continue
    data = values(conf)
    domain = data.get('Le_Domain')
    if not domain:
        continue
    webroot = data.get('Le_Webroot', '')
    cer = conf.parent / (domain + '.cer')
    records[domain] = {'cer': cer if cer.is_file() else None, 'path': data.get('Le_RealFullChainPath', ''),
                       'method': 'DNS' if webroot.startswith('dns_') else 'TLS' if webroot == 'alpn' else 'HTTP'}

paths, used = {}, set()
for base in (Path('/etc/nginx/sites-available'), Path('/etc/nginx/conf.d')):
    for conf in (sorted(base.glob('*')) if base.is_dir() else []):
        if conf.is_file():
            for cert in re.findall(r'^\s*ssl_certificate\s+([^;\s]+)\s*;', conf.read_text(errors='replace'), re.M):
                paths[cert] = True
                used.add(cert)
root = Path('/root/domain')
for cert in (sorted(root.glob('*/fullchain.pem')) if root.is_dir() else []):
    paths.setdefault(str(cert), True)

rows, seen = [], set()
for path in sorted(paths):
    if not os.path.isfile(path):
        continue
    expiry, names = info(path)
    record = next((d for d, r in records.items() if r['path'] == path), None)
    domain = record or (names[0] if names else Path(path).parent.name)
    managed = record is not None and records[record]['cer'] is not None
    if record:
        seen.add(record)
    renew = '自动续期(' + records[record]['method'] + ')' if managed else '无'
    ordered = [domain] + [n for n in names if n != domain]
    rows.append([domain, expiry or '未知', renew, path, '1' if managed else '0', '1' if path in used else '0', ','.join(ordered)])
for domain, record in sorted(records.items()):
    if domain in seen:
        continue
    if record['cer']:
        expiry, names = info(record['cer'])
        ordered = [domain] + [n for n in names if n != domain]
        rows.append([domain, expiry or '未知', '自动续期(' + record['method'] + ')', '', '1', '0', ','.join(ordered)])
    else:
        rows.append([domain, '申请未完成', '-', '', '1', '0', domain])
for row in rows:
    print('|'.join(row))
PYCERT_ROWS
}

nginx_domain_print_cert_rows() {
    local i=0 row domain expiry renew path managed used names
    [ "$#" -gt 0 ] || { echo -e "${YELLOW}暂无证书${NC}"; return 0; }
    printf '  %-4s %-32s %-12s %-16s %s\n' 编号 域名 到期 续期 证书路径
    for row in "$@"; do
        i=$((i + 1))
        IFS='|' read -r domain expiry renew path managed used names <<< "$row"
        printf '  %-4s %-32s %-12s %-16s %s\n' "$i" "$domain" "$expiry" "$renew" "${path:--}"
    done
}

show_cert_list() {
    local -a rows=()
    mapfile -t rows < <(nginx_domain_cert_rows)
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}证书列表：${NC}"
    nginx_domain_print_cert_rows "${rows[@]}"
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
    [ "${CERT_EXISTED_BEFORE:-false}" != true ] || echo -e "${YELLOW}原有证书和 Nginx 配置保持不变。${NC}"
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
    local choice domain expiry renew path managed used names confirm
    local -a rows=() args=()
    mapfile -t rows < <(nginx_domain_cert_rows)
    echo -e "${GREEN}当前证书：${NC}"
    nginx_domain_print_cert_rows "${rows[@]}"
    [ "${#rows[@]}" -gt 0 ] || return 0
    read -p "请输入要移除的证书编号（0 返回）: " choice || return 0
    [ "$choice" = 0 ] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#rows[@]}" ]; then
        echo -e "${RED}无效编号${NC}"
        return 0
    fi
    IFS='|' read -r domain expiry renew path managed used names <<< "${rows[choice-1]}"
    if [ "$used" = 1 ]; then
        echo -e "${YELLOW}$domain 的证书正在被 Nginx 配置使用；请先用菜单 7 删除对应配置，或用菜单 2 一起删除${NC}"
        return 0
    fi
    if [ -n "$path" ] && [ "$managed" != 1 ]; then
        echo -e "${YELLOW}$domain 的证书没有 acme.sh 续期记录，不是本工具签发的，未自动删除：$path${NC}"
        return 0
    fi
    read -p "确认移除 $domain 的证书？[y/N]: " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    if [ -z "$path" ]; then
        # Only an acme.sh record (e.g. a request that never completed); no files are installed.
        [ -d "$HOME/.acme.sh/${domain}_ecc" ] && args+=(--ecc)
        "$ACME" --remove -d "$domain" "${args[@]}" || { echo -e "${RED}移除失败${NC}"; return 1; }
        rmdir "/root/domain/${domain%%.*}" "/root/domain/$domain" 2>/dev/null || true
        echo -e "${GREEN}已移除 $domain 的证书记录${NC}"
    else
        nginx_domain_remove_cert_safe "$domain" "$(dirname "$path")"
    fi
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
    echo -e "${GREEN}已配置自动续期（每天凌晨3点检查）${NC}"
}

# ---- certificate validation ----
# HTTP needs port 80 reachable from the internet, which mainland providers block
# for domains not filed with them. TLS-ALPN answers on 443 instead (Nginx pauses
# while acme.sh listens there); DNS goes through the DNS provider's API.
nginx_domain_choose_method() {
    local exclude="${1:-}" choice default=1
    [ "$exclude" = http ] && default=2
    echo "请选择证书验证方式："
    [ "$exclude" = http ] || echo "  1. HTTP 验证（需要公网能通过 80 端口访问此域名）"
    echo "  2. TLS 验证（443 端口，无需密钥；申请和续期时 Nginx 暂停约 10-30 秒）"
    echo "  3. DNS 验证（DNS 服务商 API，不停机；支持 DNSPod、Cloudflare、阿里云等）"
    read -p "请选择 [回车=$default]: " choice || return 1
    case "${choice:-$default}" in
        1) [ "$exclude" != http ] || { echo -e "${RED}无效选择${NC}"; return 1; }; ISSUE_METHOD=http ;;
        2) ISSUE_METHOD=alpn; nginx_domain_ensure_socat || return 1 ;;
        3) ISSUE_METHOD=dns; nginx_domain_choose_dns || return 1 ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
}

nginx_domain_ensure_socat() {
    command -v socat >/dev/null 2>&1 && return 0
    echo -e "${YELLOW}TLS 验证需要 socat，正在安装...${NC}"
    install socat >/dev/null 2>&1 || true
    command -v socat >/dev/null 2>&1 || { echo -e "${RED}socat 安装失败，无法使用 TLS 验证${NC}"; return 1; }
}

nginx_domain_saved_value() {
    local conf="$HOME/.acme.sh/account.conf"
    [ -f "$conf" ] || return 0
    nginx_domain_acme_conf_value "$conf" "SAVED_$1"
}

# acme.sh stores provider credentials in account.conf (root only) on first use,
# and renewals read them from there.
nginx_domain_choose_dns() {
    local choice var value answer saved=false
    local -a required=() optional=()
    echo "请选择 DNS 服务商："
    echo "  1. 腾讯云 DNSPod"
    echo "  2. Cloudflare"
    echo "  3. 阿里云"
    echo "  4. 其他（acme.sh 支持的任意 DNS 服务商）"
    read -p "请选择 [1-4]: " choice || return 1
    case "$choice" in
        1) DNS_API=dns_tencent; required=(Tencent_SecretId Tencent_SecretKey)
           echo "密钥申请：腾讯云控制台 → 访问管理 → 用户列表 → 新建用户（只勾选编程访问）→ 授权 QcloudDNSPodFullAccess。" ;;
        2) DNS_API=dns_cf; required=(CF_Token); optional=(CF_Zone_ID)
           echo "令牌申请：Cloudflare 控制台 → 我的个人资料 → API 令牌 → 创建令牌 → 使用「编辑区域 DNS」模板。"
           echo "该模板的令牌还需要填区域 ID（域名概览页右侧「API」处的 Zone ID）；只有令牌带「区域:读取」权限时才可留空。" ;;
        3) DNS_API=dns_ali; required=(Ali_Key Ali_Secret)
           echo "密钥申请：阿里云 RAM 控制台 → 创建用户（OpenAPI 调用访问）→ 授权 AliyunDNSFullAccess。" ;;
        4) read -p "请输入 acme.sh DNS 插件名（如 dns_huaweicloud，列表见 github.com/acmesh-official/acme.sh/wiki/dnsapi）: " DNS_API || return 1
           [[ "$DNS_API" =~ ^dns_[a-z0-9_]+$ && -f "$HOME/.acme.sh/dnsapi/$DNS_API.sh" ]] || { echo -e "${RED}找不到该 DNS 插件${NC}"; return 1; }
           mapfile -t optional < <(sed -n "/^${DNS_API}_info=/,/^'/p" "$HOME/.acme.sh/dnsapi/$DNS_API.sh" | awk '/^ [A-Za-z_][A-Za-z0-9_]* /{print $1}')
           ((${#optional[@]})) || { echo -e "${RED}该插件没有声明所需变量，请按 acme.sh 文档手动配置${NC}"; return 1; }
           echo "该插件使用的变量：${optional[*]}（按插件文档填写，不需要的回车跳过）" ;;
        *) echo -e "${RED}无效选择${NC}"; return 1 ;;
    esac
    if ((${#required[@]})); then
        saved=true
        for var in "${required[@]}"; do [ -n "$(nginx_domain_saved_value "$var")" ] || saved=false; done
    else
        for var in "${optional[@]}"; do [ -n "$(nginx_domain_saved_value "$var")" ] && saved=true; done
    fi
    if [ "$saved" = true ]; then
        read -p "使用已保存的 $DNS_API 密钥？[Y/n]: " answer || return 1
        if [[ "${answer:-y}" =~ ^[Yy]$ ]]; then
            unset "${required[@]}" "${optional[@]}"
            DNS_KEYS_TYPED=false
            return 0
        fi
    fi
    DNS_KEYS_TYPED=true
    for var in "${required[@]}" "${optional[@]}"; do
        read -s -p "$var（输入不显示，回车跳过）: " value || return 1
        echo
        if [ -n "$value" ]; then
            export "$var=$value"
        elif [[ " ${required[*]} " == *" $var "* ]]; then
            echo -e "${RED}$var 不能为空${NC}"
            return 1
        fi
    done
}

# Issues one certificate covering all given names with ISSUE_METHOD.
nginx_domain_acme_issue() {
    local keylength="$1" domain temp log status=0
    shift
    local -a args=() temps=()
    for domain in "$@"; do args+=(-d "$domain"); done
    if [ "$ISSUE_METHOD" != dns ] && [[ "$*" == *'*'* ]]; then
        echo -e "${RED}通配符证书只能用 DNS 验证${NC}"
        return 1
    fi
    case "$ISSUE_METHOD" in
        dns) args+=(--dns "$DNS_API") ;;
        alpn)
            ensure_ufw_80
            # Saved with the certificate, so renewals pause Nginx the same way.
            args+=(--alpn --pre-hook "systemctl stop nginx 2>/dev/null; true"
                   --post-hook "systemctl is-enabled --quiet nginx 2>/dev/null && systemctl start nginx; true")
            systemctl is-active --quiet nginx 2>/dev/null && echo -e "${YELLOW}验证期间 Nginx 将暂停约 10-30 秒...${NC}"
            ;;
        *)
            ensure_ufw_80
            mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
            if ! command -v nginx >/dev/null 2>&1 || ! systemctl is-active nginx >/dev/null 2>&1; then
                install_nginx || return 1
            fi
            for domain in "$@"; do
                if ! nginx_domain_ensure_challenge_route "$domain"; then
                    if nginx_domain_config_exists "$domain"; then
                        echo -e "${RED}$domain 已有 HTTP 配置，但无法安全加入 ACME challenge 路径，请检查对应 Nginx 配置${NC}"
                        status=1
                        break
                    fi
                    if ! temp=$(nginx_domain_temp_challenge_server "$domain"); then
                        echo -e "${RED}无法为 $domain 配置 ACME webroot 验证路径${NC}"
                        status=1
                        break
                    fi
                    temps+=("$temp")
                fi
                if ! nginx_domain_verify_challenge "$domain"; then
                    echo -e "${RED}$domain 的 webroot challenge 本机验证失败，未向 CA 发起申请${NC}"
                    status=1
                    break
                fi
            done
            args+=(-w "$ACME_WEBROOT")
            ;;
    esac
    # acme.sh saves typed keys before it knows they work; keep a wrong key from
    # replacing a saved one or being offered again.
    local account="$HOME/.acme.sh/account.conf" account_backup=""
    if [ "$ISSUE_METHOD" = dns ] && [ "$DNS_KEYS_TYPED" = true ] && [ -f "$account" ]; then
        account_backup=$(mktemp) && cp -p "$account" "$account_backup" || account_backup=""
    fi
    if [ "$status" -eq 0 ]; then
        args+=(--server letsencrypt --force)
        [ -n "$keylength" ] && [ "$keylength" != "no" ] && args+=(--keylength "$keylength")
        log=$(mktemp)
        { if "$ACME" --issue "${args[@]}"; then echo 0 > "$log.rc"; else echo 1 > "$log.rc"; fi; } 2>&1 | tee "$log"
        status=$(cat "$log.rc" 2>/dev/null || echo 1)
        if [ "$status" -ne 0 ] && [ "$ISSUE_METHOD" = http ]; then
            if grep -qE 'dnspod\.qcloud\.com|webblock' "$log"; then
                echo -e "${RED}HTTP 验证被服务商拦截：该域名没有在本服务器所在的云服务商备案接入，80 端口的访问被跳转到拦截页。${NC}"
            elif grep -qE 'reader size limit exceeded|Invalid response from' "$log"; then
                echo -e "${RED}Let's Encrypt 在 80 端口收到的不是验证文件，而是其他网页（国内服务器上通常是云服务商的未备案拦截页）。${NC}"
            fi
            echo -e "${YELLOW}提示：中国大陆服务器上未备案的域名无法使用 HTTP 验证，请改用 TLS（443）或 DNS 验证。${NC}"
        fi
        rm -f "$log" "$log.rc"
    fi
    if [ -n "$account_backup" ]; then
        if [ "$status" -ne 0 ]; then
            cp -p "$account_backup" "$account" && echo -e "${YELLOW}本次输入的密钥未生效，未保存。${NC}"
        else
            DNS_KEYS_TYPED=false
        fi
        rm -f "$account_backup"
    fi
    for temp in "${temps[@]}"; do nginx_domain_remove_temp_challenge_server "$temp"; done
    if [ "$ISSUE_METHOD" = alpn ] && systemctl is-enabled --quiet nginx 2>/dev/null && ! systemctl is-active --quiet nginx; then
        systemctl start nginx || echo -e "${RED}Nginx 重新启动失败，请立即检查：systemctl status nginx${NC}"
    fi
    return "$status"
}

nginx_domain_acme_install() {
    local domain="$1" cert_dir="$2"
    # A stopped Nginx (fresh TLS-validated install) is not a reload failure.
    local -a args=(--fullchain-file "$cert_dir/fullchain.pem" --key-file "$cert_dir/privkey.pem"
                   --reloadcmd "nginx -t && systemctl reload nginx || ! systemctl is-active --quiet nginx" --force)
    mkdir -p "$cert_dir" || return 1
    [ -d "$HOME/.acme.sh/${domain}_ecc" ] && args+=(--ecc)
    "$ACME" --install-cert -d "$domain" "${args[@]}"
}

# A request that never produced a certificate leaves only a key, CSR and
# record behind; drop them so the new request starts clean.
nginx_domain_clear_stale_request() {
    local domain="$1" dir removed=false
    local -a ecc
    for dir in "$HOME/.acme.sh/${domain}_ecc" "$HOME/.acme.sh/$domain"; do
        [ -f "$dir/$domain.conf" ] && [ ! -s "$dir/$domain.cer" ] || continue
        ecc=()
        [ "$dir" = "$HOME/.acme.sh/${domain}_ecc" ] && ecc=(--ecc)
        "$ACME" --remove -d "$domain" "${ecc[@]}" >/dev/null 2>&1 && removed=true
    done
    rmdir "/root/domain/${domain%%.*}" "/root/domain/$domain" 2>/dev/null || true
    [ "$removed" = false ] || echo -e "${YELLOW}已清除 $domain 之前未完成的申请记录${NC}"
}

# 申请证书
issue_cert() {
    local DOMAIN="$1" existing_conf="" keylength="" retry

    validate_domain "$DOMAIN" || { echo -e "${RED}域名格式不正确${NC}"; return 1; }
    install_acme || return 1
    [ -n "${ISSUE_METHOD:-}" ] || nginx_domain_choose_method || return 1
    show_dns "$DOMAIN"
    CERT_DIR=$(nginx_domain_cert_dir_for_domain "$DOMAIN")

    nginx_domain_clear_stale_request "$DOMAIN"
    CERT_EXISTED_BEFORE=false
    if [ -s "$CERT_DIR/fullchain.pem" ] || [ -s "$HOME/.acme.sh/${DOMAIN}_ecc/$DOMAIN.cer" ] || [ -s "$HOME/.acme.sh/$DOMAIN/$DOMAIN.cer" ]; then
        CERT_EXISTED_BEFORE=true
        echo -e "${YELLOW}检测到已有证书，将强制更新；新证书签发成功前不改动旧证书...${NC}"
    fi
    existing_conf=$(find "$HOME/.acme.sh/${DOMAIN}_ecc" "$HOME/.acme.sh/$DOMAIN" -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null || true)
    [ -n "$existing_conf" ] && keylength=$(nginx_domain_acme_conf_value "$existing_conf" Le_Keylength)

    if ! nginx_domain_acme_issue "$keylength" "$DOMAIN"; then
        retry=n
        if [ "$ISSUE_METHOD" = http ]; then
            read -p "是否改用其他验证方式重试？[Y/n]: " retry || retry=n
            retry=${retry:-y}
        fi
        if ! [[ "$retry" =~ ^[Yy]$ ]] || ! nginx_domain_choose_method http || ! nginx_domain_acme_issue "$keylength" "$DOMAIN"; then
            echo -e "${RED}证书申请失败${NC}"
            return 1
        fi
    fi

    if ! nginx_domain_acme_install "$DOMAIN" "$CERT_DIR"; then
        echo -e "${RED}证书安装失败${NC}"
        return 1
    fi

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
    if command -v ss >/dev/null 2>&1 && [ -z "$(ss -Htln "sport = :$PORT" 2>/dev/null)" ]; then
        echo -e "${YELLOW}提示：本机端口 $PORT 当前没有服务在监听，配置完成后访问会返回 502；请确认后端服务已启动。${NC}"
    fi

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
    local row domain expiry renew path managed used list selection item keylength conf
    local success=0 failed=0
    local -a rows=() candidates=() chosen=() names=()
    [ "$(id -u)" -eq 0 ] || { echo -e "${RED}请使用 root 运行${NC}"; return 1; }
    install_acme || return 1
    mapfile -t rows < <(nginx_domain_cert_rows)
    for row in "${rows[@]}"; do
        IFS='|' read -r domain expiry renew path managed used list <<< "$row"
        [ -n "$path" ] && [ "$expiry" != "未知" ] && candidates+=("$row")
    done
    ((${#candidates[@]})) || { echo -e "${YELLOW}没有可迁移的证书${NC}"; return 0; }
    echo "以下证书可以重新签发、装回原路径，并由 acme.sh 自动续期："
    nginx_domain_print_cert_rows "${candidates[@]}"
    read -p "请输入要迁移的编号（空格分隔；回车=全部「续期:无」的证书；0 返回）: " selection || return 0
    [ "$selection" = 0 ] && return 0
    if [ -z "$selection" ]; then
        for row in "${candidates[@]}"; do
            IFS='|' read -r domain expiry renew path managed used list <<< "$row"
            [ "$managed" = 1 ] || chosen+=("$row")
        done
    else
        for item in $selection; do
            if ! [[ "$item" =~ ^[0-9]+$ ]] || [ "$item" -lt 1 ] || [ "$item" -gt "${#candidates[@]}" ]; then
                echo -e "${RED}无效编号: $item${NC}"
                return 0
            fi
            chosen+=("${candidates[item-1]}")
        done
    fi
    ((${#chosen[@]})) || { echo -e "${GREEN}所有证书都已有自动续期，无需迁移${NC}"; return 0; }
    echo -e "${YELLOW}将重新签发 ${#chosen[@]} 张证书（Let's Encrypt 对同一主域名每周最多签发 50 张）。${NC}"
    nginx_domain_choose_method || return 1
    read -p "确认开始迁移？[y/N]: " item || return 0
    [[ "$item" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    for row in "${chosen[@]}"; do
        IFS='|' read -r domain expiry renew path managed used list <<< "$row"
        IFS=',' read -ra names <<< "$list"
        keylength=""
        conf=$(find "$HOME/.acme.sh/${domain}_ecc" "$HOME/.acme.sh/$domain" -maxdepth 1 -type f -name "$domain.conf" -print -quit 2>/dev/null || true)
        [ -n "$conf" ] && keylength=$(nginx_domain_acme_conf_value "$conf" Le_Keylength)
        echo -e "${YELLOW}正在迁移证书: $domain${NC}"
        if nginx_domain_acme_issue "$keylength" "${names[@]}" && nginx_domain_acme_install "$domain" "$(dirname "$path")"; then
            echo -e "${GREEN}$domain 迁移成功${NC}"
            success=$((success + 1))
        else
            echo -e "${RED}$domain 迁移失败，原证书保留${NC}"
            failed=$((failed + 1))
        fi
    done
    setup_cron || true
    { nginx -t && systemctl reload nginx; } || true
    echo -e "${GREEN}迁移完成：成功 $success，失败 $failed${NC}"
    [ "$failed" -eq 0 ]
}

# -------------------- 主流程 --------------------

if [ "${1:-}" = "--install-renewal" ]; then
    install_acme || exit 1
    setup_cron || exit 1
    # Regenerate the daily backup script so it carries the current backup contents.
    if nginx_domain_has_domains; then
        nginx_domain_enable_auto_backup || echo -e "${YELLOW}域名自动备份脚本更新失败${NC}"
    fi
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
    echo "3) 申请证书"
    echo "4) 移除证书"
    echo "5) 查看证书列表"
    echo "6) 配置 nginx"
    echo "7) 删除 nginx 配置"
    echo "8) 创建测试页面"
    echo "9) 删除测试页面"
    echo "10) 安装 nginx"
    echo "11) 备份域名 + nginx 配置"
    echo "12) 恢复域名 + nginx 配置"
    echo "13) 迁移/修复现有证书（接管自动续期）"
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

            ISSUE_METHOD=""
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
            ISSUE_METHOD=""
            issue_cert "$DOMAIN" || true
            restart_nginx_if_needed
            ;;
        4)
            remove_cert || true
            ;;
        5)
            show_cert_list || true
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
            nginx_domain_migrate_existing_certs || true
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
