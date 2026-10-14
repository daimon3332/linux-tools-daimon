#!/bin/bash

validate_config_name() {
	[[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != "." ] && [ "$1" != ".." ]
}

sshkey_on() {
	ssh_transaction_apply PermitRootLogin prohibit-password PasswordAuthentication no \
		KbdInteractiveAuthentication no PubkeyAuthentication yes PermitEmptyPasswords no
}

ssh_public_key_valid() {
	local key="$1"
	[[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
	case "$key" in ssh-*' '*|ecdsa-sha2-*' '*|sk-*' '*) ;; *) return 1 ;; esac
	printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1
}

ssh_import_key_file() {
	(
	local file="$1" base_dir="${2:-$HOME}" mode="${3:-configure}" ssh_dir auth_keys tmp='' line added=0
	[[ "$mode" = configure || "$mode" = keys-only ]] || return 1
	[ ! -e /var/lib/daimon/ssh-change ] || { echo "SSH 事务尚未确认，暂不修改公钥。" >&2; return 1; }
	local -a keys=()
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		[[ ! "$line" =~ [^[:space:]] || "$line" =~ ^[[:space:]]*# ]] && continue
		ssh_public_key_valid "$line" || { echo "公钥格式或内容无效，未导入任何公钥。" >&2; return 1; }
		keys+=("$line")
	done < "$file"
	[ "${#keys[@]}" -gt 0 ] || { echo "未找到有效公钥。" >&2; return 1; }
	ssh_dir="$base_dir/.ssh"
	auth_keys="$ssh_dir/authorized_keys"
	[ -d "$base_dir" ] && [ ! -L "$ssh_dir" ] && [ ! -L "$auth_keys" ] &&
		{ [ ! -e "$auth_keys" ] || [ -f "$auth_keys" ]; } || {
		echo "SSH 密钥目录或文件不安全，未写入。" >&2; return 1
	}
	mkdir -p -- "$ssh_dir" && chmod 700 "$ssh_dir" || return 1
	tmp=$(mktemp "$ssh_dir/authorized_keys.tmp.XXXXXX") || return 1
	trap 'rm -f -- "$tmp"' EXIT
	if [ -f "$auth_keys" ]; then
		cp -p -- "$auth_keys" "$tmp" || return 1
	else
		chown --reference="$base_dir" "$ssh_dir" "$tmp" || return 1
	fi
	for line in "${keys[@]}"; do
		if ! grep -Fxq -- "$line" "$tmp" && ! grep -Fxq -- "$line"$'\r' "$tmp"; then
			if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then printf '\n' >> "$tmp" || return 1; fi
			printf '%s\n' "$line" >> "$tmp" || return 1
			added=$((added + 1))
		fi
	done
	if [ "$added" -gt 0 ]; then
		chmod 600 "$tmp" && mv -f -- "$tmp" "$auth_keys" || return 1
		echo "成功添加 $added 条公钥。"
	else
		echo "公钥已存在，无需重复添加。"
	fi
	if [ "$mode" = configure ] && [ "$(realpath -e -- "$base_dir")" = "$(realpath -e -- "$HOME")" ]; then
		sshkey_on
	else
		echo "仅导入公钥，未修改全局 SSH 登录策略。"
	fi
	)
}

sshkey_panel() {
  root_use
  while true; do
	  clear
	  local REAL_STATUS=$(grep -i "^PubkeyAuthentication" /etc/ssh/sshd_config | tr '[:upper:]' '[:lower:]')
	  if [[ "$REAL_STATUS" =~ "yes" ]]; then
		  IS_KEY_ENABLED="${gl_lv}已启用${gl_bai}"
	  else
            IS_KEY_ENABLED="${gl_hui}未启用${gl_bai}"
	  fi
        echo -e "用户密钥登录模式 ${IS_KEY_ENABLED}"
        echo "进阶玩法: https://blog.kejilion.pro/ssh-key"
        echo "------------------------------------------------"
        echo "将会生成密钥对，更安全的方式SSH登录"
	  echo "------------------------"
	  echo "1. 生成新密钥对                  2. 手动输入已有公钥"
	  echo "3. 从GitHub导入已有公钥          4. 从URL导入已有公钥"
	  echo "5. 编辑公钥文件                  6. 查看本机密钥"
	  echo "------------------------"
	  echo "0. 返回上一级选单"
	  echo "------------------------"
	  read -e -p "请输入你的选择: " host_dns || return 1
	  case $host_dns in
		  1)
              add_sshkey
			break_end
			  ;;
		  2)
			import_sshkey
			break_end
			  ;;
		  3)
			fetch_github_ssh_keys
			break_end
			  ;;
		  4)
			read -e -p "请输入您的远端公钥URL： " keys_url || return 1
			fetch_remote_ssh_keys "${keys_url}"
			break_end
			  ;;

		  5)
			daimon_require_cmd vim && vim ${HOME}/.ssh/authorized_keys
			break_end
			  ;;

		  6)
			echo "------------------------"
			echo "公钥信息"
			cat ${HOME}/.ssh/authorized_keys
			echo "------------------------"
			echo "私钥信息"
			cat ${HOME}/.ssh/sshkey
			echo "------------------------"
			break_end
			  ;;
		  *)
			  break  # 跳出循环，退出菜单
			  ;;
	  esac
  done


}

ssh_manager() {

	CONFIG_FILE="$HOME/.ssh_connections"
	KEY_DIR="$HOME/.ssh/ssh_manager_keys"

	# 检查配置文件和密钥目录是否存在，如果不存在则创建
	if [[ ! -f "$CONFIG_FILE" ]]; then
		touch "$CONFIG_FILE"
	fi

	if [[ ! -d "$KEY_DIR" ]]; then
		mkdir -p "$KEY_DIR"
		chmod 700 "$KEY_DIR"
	fi

	while true; do
		clear
		echo "SSH 远程连接工具"
		echo "可以通过SSH连接到其他Linux系统上"
		echo "------------------------"
		list_connections
		echo "1. 创建新连接        2. 使用连接        3. 删除连接"
		echo "------------------------"
		echo "0. 返回上一级选单"
		echo "------------------------"
		read -e -p "请输入你的选择: " choice || return 1
		case $choice in
			1) add_connection ;;
			2) use_connection ;;
			3) delete_connection ;;
			0) break ;;
			*) echo "无效的选择，请重试。" ;;
		esac
	done
}

ssh_current_ports() {
	local ports
	ports=$({
		ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
		sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
		[ -n "${SSH_CONNECTION:-}" ] && printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}'
	} | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {print $1}' | sort -nu)
	[ -n "$ports" ] || { echo "无法识别 SSH 端口，未启用防火墙。" >&2; return 1; }
	printf '%s\n' "$ports"
}

ssh_private_key_name_valid() {
	validate_config_name "$1" || return 1
	case "$1" in authorized_keys|authorized_keys2|known_hosts|known_hosts2|known_hosts.old|config|environment|rc|*.pub) return 1 ;; esac
}

ssh_private_key_directory() {
	[ "$EUID" -eq 0 ] && [ "$(realpath -e /root)" = /root ] && [ -O /root ] || return 1
	local mode
	mode=$(stat -c %a -- /root) || return 1
	(( (8#${mode} & 022) == 0 )) || return 1
	[ ! -L /root/.ssh ] || return 1
	if [ "${1:-}" = create ] && [ ! -e /root/.ssh ]; then (umask 077; mkdir /root/.ssh) || return 1; fi
	[ -d /root/.ssh ] && [ -O /root/.ssh ] || return 1
	mode=$(stat -c %a -- /root/.ssh) || return 1
	(( (8#${mode} & 022) == 0 ))
}

ssh_private_key_install() (
	local name="$1" staged target
	ssh_private_key_name_valid "$name" && ssh_private_key_directory create || { echo "私钥名称或目录不安全。" >&2; return 1; }
	target="/root/.ssh/$name"
	[ ! -e "$target" ] && [ ! -L "$target" ] || { echo "文件已存在，未覆盖。" >&2; return 1; }
	umask 077
	staged=$(mktemp /root/.ssh/.private-key.XXXXXX) || return 1
	trap 'rm -f -- "$staged"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	cat > "$staged" || return 1
	if ! ssh-keygen -y -f "$staged" >/dev/null; then
		echo "私钥内容或口令无效，未保存。" >&2
		return 1
	fi
	ln -- "$staged" "$target" || { echo "无法保存私钥，未覆盖已有文件。" >&2; return 1; }
	echo "私钥已校验并保存。"
)

ssh_private_key_remove() {
	local name="$1" target identity mode
	ssh_private_key_name_valid "$name" && ssh_private_key_directory || return 1
	target="/root/.ssh/$name"
	[ -f "$target" ] && [ ! -L "$target" ] && [ -O "$target" ] && [ "$(stat -c %h -- "$target")" = 1 ] || return 1
	mode=$(stat -c %a -- "$target") || return 1
	(( (8#${mode} & 077) == 0 )) || { echo "私钥权限过宽，未读取或删除。" >&2; return 1; }
	identity=$(stat -c '%d:%i:%s:%Y:%Z:%f:%u:%g' -- "$target") || return 1
	ssh-keygen -y -f "$target" >/dev/null || { echo "不是可验证的私钥或口令无效，未删除。" >&2; return 1; }
	[ ! -L "$target" ] && [ "$(stat -c '%d:%i:%s:%Y:%Z:%f:%u:%g' -- "$target")" = "$identity" ] || return 1
	rm -- "$target"
}

ssh_transaction_program() {
	cat <<'PYSSH_TXN'
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

OPTIONS = {key.lower(): key for key in (
    'Port', 'PasswordAuthentication', 'KbdInteractiveAuthentication',
    'PubkeyAuthentication', 'PermitRootLogin', 'PermitEmptyPasswords', 'AuthorizedKeysFile')}
BEGIN = '# BEGIN DAIMON SSH TRANSACTION OPTIONS'
END = '# END DAIMON SSH TRANSACTION OPTIONS'
CONFIG = Path('/etc/ssh/sshd_config')
KEYS = Path('/root/.ssh/authorized_keys')
PENDING = Path('/var/lib/daimon/ssh-change')
UNIT = Path('/etc/systemd/system/daimon-ssh-recover.service')
WANTED = Path('/etc/systemd/system/multi-user.target.wants/daimon-ssh-recover.service')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def option(key, value):
    key = key.lower()
    if key == 'challengeresponseauthentication':
        key = 'kbdinteractiveauthentication'
    require(key in OPTIONS, 'Unsupported SSH option')
    if key == 'port':
        require(value.isascii() and value.isdecimal() and 1 <= int(value) <= 65535, 'Invalid SSH port')
        value = str(int(value))
    elif key == 'authorizedkeysfile':
        require(value == '.ssh/authorized_keys', 'Unsupported managed authorized_keys location')
    elif key == 'permitrootlogin':
        require(value in ('yes', 'no', 'prohibit-password', 'without-password'), 'Invalid root-login policy')
        if value == 'without-password':
            value = 'prohibit-password'
    else:
        require(value in ('yes', 'no'), 'Invalid authentication policy')
    return key, value


def candidate(original, changes):
    lines = original.splitlines(keepends=True)
    managed = {}
    if lines and lines[0].rstrip('\r\n') == BEGIN:
        end = next((i for i, line in enumerate(lines[1:], 1) if line.rstrip('\r\n') == END), None)
        require(end is not None, 'Incomplete managed SSH configuration block')
        for line in lines[1:end]:
            fields = line.split()
            require(len(fields) == 2, 'Invalid managed SSH configuration block')
            key, value = option(*fields)
            require(key not in managed, 'Duplicate managed SSH option')
            managed[key] = value
        lines = lines[end + 1:]
    for key, value in changes:
        key, value = option(key, value)
        managed[key] = value
    require(managed, 'No SSH changes requested')
    if 'port' in managed:
        # Port is forbidden inside Match; the caller first validates the original configuration.
        lines = [line for line in lines if not re.match(r'^\s*Port\s+', line, re.I)]
    header = [BEGIN] + [OPTIONS[key] + ' ' + value for key, value in sorted(managed.items())] + [END]
    return '\n'.join(header) + '\n' + ''.join(lines), managed


def trusted_file(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Symlink or non-absolute configuration path')
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and
            not info.st_mode & 0o022, 'Untrusted configuration file')
    return info


def run(*args, timeout=30):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd='/',
                          env=dict(os.environ, LC_ALL='C', PATH='/usr/sbin:/usr/bin:/sbin:/bin'))


def command(*args, timeout=30):
    result = run(*args, timeout=timeout)
    require(result.returncode == 0, 'Command failed: ' + args[0] + ': ' + result.stderr.strip())
    return result.stdout


def connection_context(connection, port=None):
    fields = connection.split()
    require(len(fields) == 4 and fields[1].isdecimal() and fields[3].isdecimal(), 'An SSH connection is required')
    import ipaddress
    remote = str(ipaddress.ip_address(fields[0]))
    local = str(ipaddress.ip_address(fields[2]))
    return 'user=root,host=' + remote + ',addr=' + remote + ',laddr=' + local + ',lport=' + str(port or fields[3])


def effective(config, context):
    output = command('/usr/sbin/sshd', '-T', '-f', str(config), '-C', context)
    values = {}
    for line in output.splitlines():
        key, value = line.split(' ', 1)
        values.setdefault(key, []).append(value)
    return values


def check_policy(values, desired):
    for key, expected in desired.items():
        actual = values.get(key, [])
        if key == 'permitrootlogin':
            actual = ['prohibit-password' if value == 'without-password' else value for value in actual]
        require(actual == [expected], 'An Include, Match or duplicate directive conflicts with requested ' + OPTIONS[key])


def trusted_directory(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Untrusted directory path')
    for parent in (path, *path.parents):
        info = parent.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'Untrusted directory owner or permissions')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, content, mode=0o600, uid=0, gid=0):
    path = Path(path)
    trusted_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix='.ssh-change-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), uid, gid)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def service_properties(name):
    result = run('/usr/bin/systemctl', 'show', name, '--no-pager',
                 '-p', 'Id', '-p', 'LoadState', '-p', 'ActiveState', '-p', 'MainPID',
                 '-p', 'DropInPaths', '-p', 'UnitFileState')
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    require(result.returncode == 0 or properties.get('LoadState') == 'not-found', 'Cannot inspect systemd unit ' + name)
    return properties


def settled_service(name):
    deadline = time.monotonic() + 20
    while True:
        service = service_properties(name)
        if service.get('ActiveState') != 'reloading':
            return service
        require(time.monotonic() < deadline, 'SSH reload has not settled; recovery state was retained')
        time.sleep(0.25)


def preflight_service():
    require(os.geteuid() == 0 and Path('/run/systemd/system').is_dir(), 'Root and systemd are required')
    service = service_properties('ssh.service')
    if service.get('LoadState') != 'loaded':
        service = service_properties('sshd.service')
    require(service.get('LoadState') == 'loaded' and service.get('ActiveState') == 'active',
            'SSH must already be active; no inactive service will be started')
    require(not service.get('DropInPaths'), 'Custom SSH service drop-ins require explicit manual handling')
    require(service.get('MainPID', '').isdecimal() and int(service['MainPID']) > 1, 'SSH listener PID is unknown')
    process = Path('/proc') / service['MainPID']
    title = (process / 'cmdline').read_bytes().rstrip(b'\0')
    require(re.fullmatch(rb'sshd: /usr/sbin/sshd -D \[listener\](?: [0-9]+ of [0-9-]+ startups)?', title),
            'Unsupported sshd startup options; no service units were changed')
    require((process / 'exe').resolve() == Path('/usr/sbin/sshd').resolve(), 'Unexpected SSH listener executable')
    environment = dict(value.split(b'=', 1) for value in (process / 'environ').read_bytes().split(b'\0') if b'=' in value)
    require(not environment.get(b'SSHD_OPTS', b'').strip(), 'Nonempty SSHD_OPTS are unsupported')
    for name in ('ssh.socket', 'sshd.socket'):
        socket = service_properties(name)
        require(socket.get('LoadState') == 'not-found' or
                (socket.get('ActiveState') == 'inactive' and socket.get('UnitFileState') in ('disabled', 'masked', '')),
                'SSH socket activation is unsupported; existing sockets were not disabled')
    return service['Id']


def root_authentication_available(values):
    value = lambda key: values.get(key, [''])[0]
    root_mode = value('permitrootlogin')
    require(root_mode in ('yes', 'without-password', 'prohibit-password'), 'Root SSH login would be disabled')
    password_set = False
    for line in Path('/etc/shadow').read_text().splitlines():
        fields = line.split(':')
        if fields[0] == 'root':
            password_set = bool(fields[1]) and not fields[1].startswith(('!', '*'))
            break
    password = password_set and root_mode == 'yes' and value('passwordauthentication') == 'yes'
    keyboard = password_set and root_mode == 'yes' and value('kbdinteractiveauthentication') == 'yes'
    publickey = False
    if value('pubkeyauthentication') == 'yes':
        for filename in value('authorizedkeysfile').split():
            filename = filename.replace('%h', '/root').replace('%u', 'root').replace('%U', '0')
            path = Path(filename)
            if not path.is_absolute():
                path = Path('/root') / path
            try:
                trusted_directory(path.parent)
                trusted_file(path)
                command('/usr/bin/ssh-keygen', '-lf', str(path))
                publickey = True
                break
            except (OSError, ValueError, subprocess.SubprocessError):
                continue
    factors = {'publickey': publickey, 'password': password,
               'keyboard-interactive': keyboard, 'keyboard-interactive:pam': keyboard}
    methods = value('authenticationmethods')
    usable = publickey or password or keyboard if methods == 'any' else any(
        all(factors.get(part, False) for part in alternative.split(',')) for alternative in methods.split())
    require(usable, 'No supported root authentication method remains; current settings were preserved')


def key_candidate(original, number):
    lines = original.splitlines(keepends=True)
    require(number.isascii() and number.isdecimal() and 1 <= int(number) <= len(lines), 'Invalid public-key line')
    selected = lines[int(number) - 1].strip()
    require(selected and not selected.startswith(b'#'), 'Selected line is not a public key')
    del lines[int(number) - 1]
    require(any(line.strip() and not line.lstrip().startswith(b'#') for line in lines), 'The last public key cannot be deleted')
    return b''.join(lines)


def target_file(state):
    return KEYS if state.get('kind') == 'keys' else CONFIG


def ufw_snapshot():
    import shlex
    require(shutil.which('ufw') == '/usr/sbin/ufw', 'The standard UFW executable is required')
    trusted_directory('/etc/ufw')
    config = {}
    for name in ('/etc/default/ufw', '/etc/ufw/ufw.conf', '/etc/ufw/before.rules', '/etc/ufw/after.rules',
                 '/etc/ufw/before6.rules', '/etc/ufw/after6.rules', '/etc/ufw/sysctl.conf'):
        path = Path(name)
        trusted_file(path)
        config[name] = digest(path.read_bytes())
    for name in ('ufw.conf', 'user.rules', 'user6.rules'):
        trusted_file(Path('/etc/ufw') / name)
    status = command('/usr/sbin/ufw', 'status')
    require(status.startswith(('Status: active\n', 'Status: inactive\n')), 'Unknown UFW status')
    rules = []
    for line in command('/usr/sbin/ufw', 'show', 'added').splitlines():
        if line.startswith('ufw '):
            rules.append(shlex.split(line)[1:])
    return {'active': status.startswith('Status: active'), 'rules': rules, 'config': config}


def open_rule(value):
    match = re.fullmatch(r'([0-9]{1,5})/(tcp|udp)', value)
    require(match and 1 <= int(match.group(1)) <= 65535, 'Invalid port to open')
    return str(int(match.group(1))) + '/' + match.group(2)


def firewall_plan(old_ports, ports, enable, token, open_ports=()):
    # enable: the one-click setup, which also closes 22 and turns UFW on.
    baseline = ufw_snapshot()
    if not baseline['active'] and not enable:
        return None
    missing = []
    for port in dict.fromkeys(ports):
        require(option('port', port)[1] == port, 'Invalid firewall port')
        if not any(rule[:2] == ['allow', port + '/tcp'] for rule in baseline['rules']):
            missing.append(port)
    deny, removed = [], []
    if enable and '22' not in ports and not any(rule[:2] == ['deny', '22/tcp'] for rule in baseline['rules']):
        deny.append('22')
        # UFW keeps one rule per port/protocol: an allow for 22/tcp blocks the deny,
        # so it is taken out now and put back at the same position on recovery.
        removed = [[rule, index] for index, rule in enumerate(baseline['rules']) if rule[1:2] == ['22/tcp']]
    opened = [rule for rule in dict.fromkeys(open_rule(value) for value in open_ports)
              if not any(existing[:2] == ['allow', rule] for existing in baseline['rules'])]
    return {'baseline': baseline, 'ports': missing, 'deny': deny, 'removed': removed, 'open': opened,
            'tag': 'daimon-ssh-' + token, 'enable': enable, 'activate': enable and not baseline['active']}


def firewall_owned(fw):
    return ([['deny', port + '/tcp', 'comment', fw['tag']] for port in fw.get('deny', [])] +
            [['allow', port + '/tcp', 'comment', fw['tag']] for port in fw['ports']] +
            [['allow', rule, 'comment', fw['tag']] for rule in fw.get('open', [])])


def firewall_config(snapshot, fw):
    # Turning UFW on rewrites ENABLED= in ufw.conf; that is the one change we own.
    config = dict(snapshot['config'])
    if fw.get('activate'):
        config.pop('/etc/ufw/ufw.conf', None)
    return config


def firewall_check(fw, complete=False, boot=False):
    baseline = fw['baseline']
    current = ufw_snapshot()
    require(firewall_config(current, fw) == firewall_config(baseline, fw) and
            (boot or fw.get('activate') or current['active'] == baseline['active']),
            'UFW 策略或启用状态被外部修改，已保留恢复数据')
    owned = firewall_owned(fw)
    removed = [rule for rule, _ in fw.get('removed', [])]
    remaining = [rule for rule in current['rules'] if rule not in owned and rule not in removed]
    require(remaining == [rule for rule in baseline['rules'] if rule not in removed],
            'UFW 规则被外部修改，已保留恢复数据')
    require(all(current['rules'].count(rule) <= 1 for rule in owned + removed), 'Duplicate owned UFW rule')
    if complete:
        require(all(rule in current['rules'] for rule in owned), 'SSH 所需的防火墙规则缺失')
        require(not any(rule in current['rules'] for rule in removed), '端口 22 的旧放行规则仍然存在')
        require(current['active'] or not fw.get('enable'), 'UFW 未启用')
    return current, owned


def firewall_apply(fw):
    if fw is None:
        return
    current, _ = firewall_check(fw)
    for rule, _ in fw.get('removed', []):
        command('/usr/sbin/ufw', '--force', 'delete', *rule)
        current, _ = firewall_check(fw)
    for rule in firewall_owned(fw):
        # A deny must precede any existing allow for 22; "insert 1" needs a rule to exist.
        position = ['insert', '1'] if current['rules'] else []
        command('/usr/sbin/ufw', *position, *rule)
        current, _ = firewall_check(fw)
    if fw.get('activate'):
        command('/usr/sbin/ufw', '--force', 'enable', timeout=60)
    firewall_check(fw, True)


def firewall_restore(fw, boot=False):
    if fw is None:
        return
    current, owned = firewall_check(fw, boot=boot)
    for rule in owned:
        if rule in current['rules']:
            command('/usr/sbin/ufw', '--force', 'delete', *rule)
            current, _ = firewall_check(fw, boot=boot)
    for rule, index in fw.get('removed', []):
        if rule not in current['rules']:
            position = ['insert', str(index + 1)] if index < len(current['rules']) else []
            command('/usr/sbin/ufw', *position, *rule)
            current, _ = firewall_check(fw, boot=boot)
    if fw.get('activate') and current['active']:
        command('/usr/sbin/ufw', '--force', 'disable', timeout=60)
        current, _ = firewall_check(fw, boot=boot)
    require(current['rules'] == fw['baseline']['rules'], 'UFW 规则恢复校验失败')
    require(not fw.get('activate') or not current['active'], 'UFW 未能恢复为关闭状态')


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def ssh_session_started():
    pid = os.getppid()
    starts = []
    executables = {Path('/usr/sbin/sshd').resolve(), Path('/usr/lib/openssh/sshd-session').resolve()}
    for _ in range(64):
        if pid <= 1:
            require(starts, 'Cannot identify the independently authenticated SSH session')
            return min(starts)
        process = Path('/proc') / str(pid)
        fields = (process / 'stat').read_text().rsplit(')', 1)[1].split()
        if (process / 'exe').resolve() in executables and b'[listener]' not in (process / 'cmdline').read_bytes():
            starts.append(int(fields[19]) / os.sysconf('SC_CLK_TCK'))
        pid = int(fields[1])
    raise ValueError('SSH process ancestry exceeded the safety limit')


def load_state():
    trusted_directory(PENDING)
    trusted_file(PENDING / 'state.json')
    state = json.loads((PENDING / 'state.json').read_text())
    require(state.get('version') == 1 and re.fullmatch(r'[a-f0-9]{32}', state.get('token', '')),
            'Invalid pending SSH transaction')
    require(state.get('service') in ('ssh.service', 'sshd.service'), 'Invalid pending SSH service')
    require(state.get('timer') == 'daimon-ssh-rollback-' + state['token'][:12], 'Invalid rollback timer')
    require(isinstance(state.get('metadata'), list) and len(state['metadata']) == 3 and
            all(type(value) is int for value in state['metadata']) and
            0 <= state['metadata'][0] <= 0o777 and not state['metadata'][0] & 0o022 and
            state['metadata'][1] == 0 and state['metadata'][2] >= 0, 'Invalid recovery file metadata')
    require(state.get('kind', 'config') in ('config', 'keys'), 'Invalid transaction resource')
    fw = state.get('firewall')
    if fw is not None:
        require(isinstance(fw, dict) and fw.get('tag') == 'daimon-ssh-' + state['token'] and
                isinstance(fw.get('ports'), list) and len(set(fw['ports'])) == len(fw['ports']) and
                all(option('port', port)[1] == port for port in fw['ports']) and
                fw.get('deny', []) in ([], ['22']) and type(fw.get('activate', False)) is bool and
                isinstance(fw.get('removed', []), list) and isinstance(fw.get('open', []), list) and
                all(isinstance(rule, str) and open_rule(rule) == rule for rule in fw.get('open', [])) and
                all(isinstance(item, list) and len(item) == 2 and isinstance(item[0], list) and
                    item[0][1:2] == ['22/tcp'] and all(isinstance(x, str) for x in item[0]) and
                    type(item[1]) is int and 0 <= item[1] < len(fw['baseline'].get('rules', []))
                    for item in fw.get('removed', [])) and
                isinstance(fw.get('baseline'), dict) and
                fw['baseline'].get('active') is (not fw.get('activate', False)) and
                isinstance(fw['baseline'].get('config'), dict) and isinstance(fw['baseline'].get('rules'), list),
                'Invalid firewall recovery intent')
    require(isinstance(state.get('desired'), dict) and state['desired'] and
            all(option(key, value) == (key, value) for key, value in state['desired'].items()),
            'Invalid pending SSH policy')
    require(isinstance(state.get('ports'), list) and state['ports'] and
            all(option('port', port)[1] == port for port in state['ports']), 'Invalid pending SSH ports')
    require(all(type(state.get(key)) in (int, float) and 0 < state[key] < float('inf')
                for key in ('started', 'deadline')) and state['deadline'] > state['started'],
            'Invalid confirmation window')
    connection_context(state.get('connection', ''))
    require(isinstance(state.get('boot_id'), str) and state['boot_id'], 'Invalid pending boot identity')
    for key in ('original_hash', 'candidate_hash', 'unit_hash'):
        require(isinstance(state.get(key), str) and re.fullmatch(r'[a-f0-9]{64}', state[key]),
                'Invalid recovery integrity metadata')
    for name in ('original', 'candidate'):
        trusted_file(PENDING / name)
        require(digest((PENDING / name).read_bytes()) == state[name + '_hash'], 'Recovery file integrity check failed')
    return state


def cleanup(state):
    allowed = {'worker.py', 'original', 'candidate', 'state.json'}
    require(set(path.name for path in PENDING.iterdir()) <= allowed, 'Unexpected recovery files; retained for inspection')
    if UNIT.exists() or UNIT.is_symlink():
        trusted_file(UNIT)
        require(digest(UNIT.read_bytes()) == state['unit_hash'], 'Recovery unit changed; it was not removed')
    if WANTED.exists() or WANTED.is_symlink():
        require(WANTED.is_symlink() and os.readlink(WANTED) == str(UNIT), 'Recovery dependency changed; it was not removed')
    timer = state['timer'] + '.timer'
    if service_properties(timer).get('LoadState') != 'not-found':
        command('/usr/bin/systemctl', 'stop', timer)
    if WANTED.is_symlink():
        WANTED.unlink()
        sync_directory(WANTED.parent)
    if UNIT.exists():
        UNIT.unlink()
        sync_directory(UNIT.parent)
    command('/usr/bin/systemctl', 'daemon-reload')
    for path in PENDING.iterdir():
        trusted_file(path)
    for name in ('original', 'candidate', 'worker.py', 'state.json'):
        path = PENDING / name
        if path.exists():
            path.unlink()
    PENDING.rmdir()
    sync_directory(PENDING.parent)


def recover(state):
    target = target_file(state)
    trusted_file(target)
    current = digest(target.read_bytes())
    require(current in (state['original_hash'], state['candidate_hash']),
            'SSH configuration was changed externally; no unknown changes were overwritten')
    command('/usr/sbin/sshd', '-t', '-f', str(CONFIG if state.get('kind') == 'keys' else PENDING / 'original'))
    if current != state['original_hash']:
        atomic_write(target, (PENDING / 'original').read_bytes(), *state['metadata'])
    service = settled_service(state['service'])
    if service.get('ActiveState') == 'active':
        require(preflight_service() == state['service'], 'SSH service changed; reload requires manual verification')
        command('/usr/bin/systemctl', 'reload', state['service'])
        require(settled_service(state['service']).get('ActiveState') == 'active',
                'Restored SSH configuration did not leave an active service; recovery state was retained')
    if state.get('firewall'):
        firewall_restore(state['firewall'], boot=boot_id() != state['boot_id'])
    cleanup(state)
    print('未确认的 SSH 变更已恢复为原配置。')


def confirm(state, token):
    require(secrets.compare_digest(token, state['token']), 'Invalid confirmation token')
    require(boot_id() == state['boot_id'] and time.monotonic() < state['deadline'], 'Confirmation expired; rollback is required')
    connection = os.environ.get('SSH_CONNECTION', '')
    require(connection != state['connection'], 'Confirm from a new, independently authenticated SSH connection')
    require(ssh_session_started() > state['started'], 'The confirming SSH session predates this change')
    context = connection_context(connection)
    require(connection.split()[3] in state['ports'], 'The new SSH connection used the wrong destination port')
    require(preflight_service() == state['service'], 'SSH service changed during confirmation')
    target = target_file(state)
    trusted_file(target)
    require(digest(target.read_bytes()) == state['candidate_hash'], 'SSH configuration changed during confirmation')
    policy = effective(CONFIG, context)
    check_policy(policy, state['desired'])
    root_authentication_available(policy)
    if state.get('firewall'):
        firewall_check(state['firewall'], True)
    cleanup(state)
    if state.get('kind', 'config') == 'config':
        # Tells the next toolbox start to re-point Fail2ban at the confirmed port.
        atomic_write(PENDING.parent / 'ssh-port-confirmed', b'')
    print('SSH 变更已确认生效。')


def apply(changes, edited=None, base_hash=None, key_line=None, enable_ufw=False, open_ports=()):
    require(not PENDING.exists() and not PENDING.is_symlink(), 'An earlier SSH transaction still requires confirmation or recovery')
    require(not UNIT.exists() and not UNIT.is_symlink() and not WANTED.exists() and not WANTED.is_symlink(),
            'Recovery unit paths are already occupied; no existing units were changed')
    service = preflight_service()
    target = KEYS if key_line is not None else CONFIG
    trusted_directory(CONFIG.parent)
    trusted_directory(target.parent)
    info = trusted_file(target)
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns,
                             item.st_ctime_ns, item.st_mode, item.st_uid, item.st_gid)
    original = target.read_bytes()
    if base_hash is not None:
        require(digest(original) == base_hash, 'The file changed after it was displayed or opened; retry')
    command('/usr/sbin/sshd', '-t', '-f', str(CONFIG))
    connection = os.environ.get('SSH_CONNECTION', '')
    old_context = connection_context(connection)
    old_policy = effective(CONFIG, old_context)
    if edited is not None:
        edited = Path(edited)
        trusted_file(edited)
        text = edited.read_text()
        desired = None
    elif key_line is not None:
        require(old_policy.get('authorizedkeysfile') == ['.ssh/authorized_keys'] and
                old_policy.get('pubkeyauthentication') == ['yes'], 'Only the standard active root authorized_keys file is supported')
        text = key_candidate(original, key_line).decode()
        desired = {'pubkeyauthentication': 'yes', 'authorizedkeysfile': '.ssh/authorized_keys'}
    else:
        text, desired = candidate(original.decode(), changes)
    descriptor, staged = tempfile.mkstemp(prefix='.ssh-change-', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(text)
        if key_line is not None:
            command('/usr/bin/ssh-keygen', '-lf', staged)
            policy = old_policy
        else:
            command('/usr/sbin/sshd', '-t', '-f', staged)
            provisional = effective(staged, old_context)
            ports = provisional.get('port', [])
            require(ports and all(option('port', port)[1] == port for port in ports), 'No valid SSH port')
            if desired is None:
                desired = {key: option(key, values[0])[1] for key, values in provisional.items()
                           if key in OPTIONS and key != 'port' and len(values) == 1}
            policy = effective(staged, connection_context(connection, ports[0]))
            check_policy(policy, desired)
            root_authentication_available(policy)
    finally:
        os.unlink(staged)
    token = secrets.token_hex(16)
    firewall = None
    if enable_ufw or (policy['port'] != old_policy['port'] and shutil.which('ufw')):
        firewall = firewall_plan(old_policy['port'], policy['port'], enable_ufw, token, open_ports)
    if text.encode() == original and not (firewall and (firewall['ports'] or firewall['deny'] or
                                                      firewall['removed'] or firewall['open'] or firewall['activate'])):
        print('SSH 配置已是目标状态，无需修改。')
        return
    if not PENDING.parent.exists():
        trusted_directory(PENDING.parent.parent)
        PENDING.parent.mkdir(mode=0o700)
    trusted_directory(PENDING.parent)
    trusted_directory(UNIT.parent)
    trusted_directory(WANTED.parent)
    PENDING.mkdir(mode=0o700)
    unit = ('[Unit]\nDescription=Recover unconfirmed Daimon SSH configuration\nDefaultDependencies=no\n'
            # ufw cannot edit rules before ufw.service has loaded its chains.
            'After=local-fs.target ufw.service\nBefore=ssh.service sshd.service ssh.socket sshd.socket\n'
            'ConditionPathExists=' + str(PENDING / 'state.json') + '\n[Service]\nType=oneshot\n'
            'RuntimeDirectory=sshd\nRuntimeDirectoryMode=0755\nRuntimeDirectoryPreserve=yes\n'
            'ExecStart=/usr/bin/python3 -I ' + str(PENDING / 'worker.py') + ' rollback ' + token + '\n'
            'TimeoutStartSec=90\n[Install]\nWantedBy=multi-user.target\n').encode()
    state = {'version': 1, 'token': token, 'timer': 'daimon-ssh-rollback-' + token[:12],
             'service': service, 'boot_id': boot_id(), 'connection': connection,
             'started': time.monotonic(), 'deadline': time.monotonic() + 180,
             'desired': desired, 'ports': [port for port in policy['port'] if port not in old_policy['port']] or policy['port'],
             'kind': 'keys' if key_line is not None else 'config', 'firewall': firewall,
             'original_hash': digest(original), 'candidate_hash': digest(text.encode()),
             'unit_hash': digest(unit), 'metadata': [stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid]}
    try:
        atomic_write(PENDING / 'worker.py', Path(__file__).read_bytes(), 0o700)
        atomic_write(PENDING / 'original', original)
        atomic_write(PENDING / 'candidate', text.encode())
        atomic_write(PENDING / 'state.json', json.dumps(state).encode())
        atomic_write(UNIT, unit, 0o644)
        os.symlink(str(UNIT), WANTED)
        sync_directory(WANTED.parent)
        command('/usr/bin/systemctl', 'daemon-reload')
        require(command('/usr/bin/systemctl', 'is-enabled', UNIT.name).strip() == 'enabled', 'Boot recovery was not enabled')
        command('/usr/bin/systemd-run', '--quiet', '--collect', '--unit=' + state['timer'], '--on-active=180s',
                '--timer-property=AccuracySec=1s', '--timer-property=RemainAfterElapse=no', '--property=Type=exec',
                '/usr/bin/python3', '-I', str(PENDING / 'worker.py'), 'rollback', token)
        require(service_properties(state['timer'] + '.timer').get('ActiveState') == 'active', 'Rollback timer is not armed')
        require(identity(trusted_file(target)) == identity(info) and target.read_bytes() == original,
                'SSH configuration changed while preparing recovery')
        require(preflight_service() == service, 'SSH service changed while preparing recovery')
        firewall_apply(firewall)
        atomic_write(target, text.encode(), *state['metadata'])
        command('/usr/bin/systemctl', 'reload', service)
        require(settled_service(service).get('ActiveState') == 'active', 'SSH reload did not leave the service active')
    except BaseException:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        try:
            recover(state)
        except BaseException as error:
            print('Recovery incomplete; private recovery state retained at ' + str(PENDING) + ': ' + str(error), file=sys.stderr)
        raise
    print('SSH 变更已应用，等待确认。请在 180 秒内新开一个终端，用端口 ' + ','.join(state['ports']) +
          ' 重新登录，输入 d 并按提示确认（或执行 d ssh-confirm ' + token + '）。')
    print('不确认时，180 秒后或下次重启会自动恢复原配置；当前连接不受影响，请不要关闭。')


def main(arguments):
    import fcntl
    require(os.geteuid() == 0, 'Root is required')
    require(arguments and arguments[0] in ('apply', 'confirm', 'rollback'), 'Invalid SSH transaction action')
    lock = Path('/run/lock/daimon-ssh-change.lock')
    require(lock.parent.resolve() == lock.parent and lock.parent.stat().st_uid == 0, 'Untrusted SSH lock directory')
    mode = lock.parent.stat().st_mode
    require(not mode & 0o022 or mode & stat.S_ISVTX, 'SSH lock directory is writable without sticky protection')
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022,
                'Untrusted SSH transaction lock')
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if arguments[0] == 'rollback' else fcntl.LOCK_NB))
        def interrupted(signum, frame):
            raise InterruptedError('SSH transaction interrupted by signal ' + str(signum))
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, interrupted)
        if arguments[0] == 'apply':
            args = arguments[1:]
            if args and args[0] == '--edit':
                require(len(args) == 3, 'Expected staged file and original hash')
                apply([], edited=args[1], base_hash=args[2])
            elif args and args[0] == '--delete-key':
                require(len(args) == 3, 'Expected public-key line and original hash')
                apply([], key_line=args[1], base_hash=args[2])
            else:
                enable = bool(args and args[0] == '--ufw')
                if enable:
                    args = args[1:]
                opened = []
                while enable and args[:1] == ['--open']:
                    require(len(args) >= 2, 'Expected a port to open')
                    opened.append(args[1])
                    args = args[2:]
                require(args and len(args) % 2 == 0, 'Expected SSH option/value pairs')
                apply(list(zip(args[::2], args[1::2])), enable_ufw=enable, open_ports=opened)
        else:
            require(len(arguments) == 2, 'A transaction token is required')
            state = load_state()
            require(secrets.compare_digest(arguments[1], state['token']), 'Stale or invalid transaction token')
            if arguments[0] == 'confirm':
                confirm(state, arguments[1])
            else:
                recover(state)
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('错误: ' + str(error), file=sys.stderr)
        sys.exit(1)
PYSSH_TXN
}

ssh_socket_to_service() {
    local unit service answer
    for unit in ssh.socket sshd.socket; do
        systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit" 2>/dev/null || continue
        service="${unit%.socket}.service"
        echo "检测到 $unit 套接字激活（Ubuntu 22.10+ 默认）。修改 SSH 需要先切换为常规 $service；当前连接不受影响。"
        read -e -p "切换为常规 $service 并继续？(y/N): " answer || return 1
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消，未修改 SSH。"; return 1; }
        if systemctl disable --now "$unit" && systemctl daemon-reload && systemctl enable "$service" &&
            systemctl restart "$service" && systemctl is-active --quiet "$service" && ! systemctl is-active --quiet "$unit"; then
            echo "已切换为常规 $service。"
        else
            echo "切换失败，正在恢复 $unit。" >&2
            systemctl stop "$service"
            systemctl enable --now "$unit"
            return 1
        fi
    done
}

# UFW denies every unlisted inbound port once enabled; name the listeners it will cut off.
ssh_one_click_blocked_ports() {
	local new_port="$1" allowed ssh_ports
	LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active' && return 0
	allowed=$(ufw show added 2>/dev/null | awk '$2=="allow" {split($3,a,"/"); print a[1]}')
	ssh_ports=$(ssh_current_ports 2>/dev/null)
	ss -H -tuln 2>/dev/null | awk '{print $1, $5}' |
		awk '$2 !~ /^(127\.|\[?::1\]?:|\[?::ffff:127\.)/ {n=split($2,a,":"); print a[n] "/" $1}' |
		sort -t/ -k1,1n -u | while IFS=/ read -r port proto; do
			[ "$port" = "$new_port" ] && continue
			# DHCP client replies are already allowed by UFW's built-in rules.
			[ "$proto" = udp ] && { [ "$port" = 68 ] || [ "$port" = 546 ]; } && continue
			[ "$proto" = tcp ] && printf '%s\n' "$ssh_ports" | grep -qx "$port" && continue
			printf '%s\n' "$allowed" | grep -qx "$port" && continue
			printf '%s/%s\n' "$port" "$proto"
		done
}

# Offered when "d" starts from the new connection a pending SSH change is waiting for.
ssh_pending_confirm_prompt() {
	local state=/var/lib/daimon/ssh-change/state.json info token answer
	[ "$EUID" -eq 0 ] && [ -f "$state" ] && [ -n "${SSH_CONNECTION:-}" ] || return 0
	info=$(/usr/bin/python3 -I -c '
import json, os, sys
s = json.load(open(sys.argv[1]))
c = os.environ.get("SSH_CONNECTION", "")
if c and c != s["connection"] and c.split()[3] in s["ports"]:
    print(s["token"])' "$state" 2>/dev/null) || return 0
	token=${info%%$'\n'*}
	[[ "$token" =~ ^[a-f0-9]{32}$ ]] || return 0
	echo -e "${gl_huang}检测到待确认的 SSH 变更，当前连接已通过新端口登录。${gl_bai}"
	read -e -p "确认使 SSH 变更生效？[Y/n]: " answer || return 0
	[[ "${answer:-y}" =~ ^[Yy]$ ]] || { echo "未确认，变更将在超时后自动恢复。"; return 0; }
	bash "$DAIMON_RELEASE_DIR/linux-toolbox.sh" ssh-confirm "$token" && fail2ban_sync_after_confirm
	break_end
}

ssh_transaction_apply() (
    umask 077
    [ "$EUID" -eq 0 ] && [ -x /usr/bin/python3 ] || { echo "SSH 安全事务需要 root 和系统 Python 3。" >&2; return 1; }
    ssh_socket_to_service || return 1
    local program
    program=$(mktemp /run/daimon-ssh-program.XXXXXX) || return 1
    trap 'rm -f -- "$program"' EXIT
    ssh_transaction_program > "$program" || return 1
    /usr/bin/python3 -I "$program" apply "$@"
)

ssh_config_edit() (
    umask 077
    local work original
    [ ! -e /var/lib/daimon/ssh-change ] || { echo "已有 SSH 变更待确认或恢复。" >&2; return 1; }
    daimon_require_cmd vim || { echo "未修改配置。" >&2; return 1; }
    work=$(mktemp -d /run/daimon-ssh-edit.XXXXXX) || return 1
    trap 'rm -f -- "$work/sshd_config"; rmdir -- "$work"' EXIT
    cp -- /etc/ssh/sshd_config "$work/sshd_config" || return 1
    original=$(sha256sum "$work/sshd_config") || return 1
    original=${original%% *}
    vim -n -i NONE -u NONE -- "$work/sshd_config" || return 1
    ssh_transaction_apply --edit "$work/sshd_config" "$original"
)

ssh_config_manager() {
	local SSH_CONFIG="/etc/ssh/sshd_config"
	local DEFAULT_SSH_PORT="64400"

	ssh_auth_status() {
		local key="$1"
		sshd -T 2>/dev/null | awk -v k="$key" '$1==k{print $2; found=1} END{if(!found) print "unknown"}'
	}

	ssh_add_public_key() (
		local public_key="$1" staged
		ssh_public_key_valid "$public_key" || { echo "公钥格式或内容无效，未写入。" >&2; return 1; }
		umask 077
		staged=$(mktemp) || return 1
		trap 'rm -f -- "$staged"' EXIT
		printf '%s\n' "$public_key" > "$staged" || return 1
		ssh_import_key_file "$staged" /root keys-only
	)

	ssh_key_manager() {
		while true; do
			clear
			echo "SSH 公钥和私钥管理"
			echo "------------------------"
			echo "当前公钥:"
			local key_hash
			key_hash=$(sha256sum /root/.ssh/authorized_keys 2>/dev/null)
			key_hash=${key_hash%% *}
			nl -ba /root/.ssh/authorized_keys 2>/dev/null || true
			echo "------------------------"
			echo "当前私钥:"
			find /root/.ssh -maxdepth 1 -type f ! -name '*.pub' ! -name 'authorized_keys' ! -name 'known_hosts' ! -name 'config' -printf '%f\n' 2>/dev/null | nl -ba || true
			echo "------------------------"
			echo -e "${gl_kjlan}1.   ${gl_bai}添加公钥"
			echo -e "${gl_kjlan}2.   ${gl_bai}删除公钥"
			echo -e "${gl_kjlan}3.   ${gl_bai}添加私钥"
			echo -e "${gl_kjlan}4.   ${gl_bai}删除私钥"
			echo -e "${gl_kjlan}0.   ${gl_bai}返回上一级菜单"
			read -e -p "请输入你的选择: " sub_choice || return 1
			case "$sub_choice" in
				1) read -e -p "请粘贴公钥: " public_key || return 1; ssh_add_public_key "$public_key" ;;
				2) read -e -p "请输入要删除的公钥行号: " line_no || return 1; ssh_transaction_apply --delete-key "$line_no" "$key_hash" ;;
				3)
					read -e -p "请输入私钥文件名（默认 id_ed25519）: " key_name || return 0
					key_name=${key_name:-id_ed25519}
					if ! ssh_private_key_name_valid "$key_name" || [ -e "/root/.ssh/$key_name" ] || [ -L "/root/.ssh/$key_name" ]; then
						echo "文件名无效或文件已存在，未覆盖任何文件。"
					else
						echo "请粘贴私钥内容，结束后按 Ctrl+D:"
						ssh_private_key_install "$key_name"
					fi
					;;
				4)
					read -e -p "请输入要删除的私钥文件名: " key_name || return 0
					if ssh_private_key_name_valid "$key_name" && [ -f "/root/.ssh/$key_name" ] && [ ! -L "/root/.ssh/$key_name" ]; then
						ssh_private_key_remove "$key_name"
					else
						echo "文件名无效或不是私钥文件，未删除。"
					fi
					;;
				0) return ;;
				*) echo "无效的输入!" ;;
			esac
			break_end
		done
	}

	while true; do
		clear
		root_use
		echo "SSH 配置"
		echo "------------------------"
		echo -e "当前 SSH 端口: ${gl_huang}$(ssh_current_ports | paste -sd, -)${gl_bai}"
		echo -e "密码登录 PasswordAuthentication: ${gl_huang}$(ssh_auth_status passwordauthentication)${gl_bai}"
		echo -e "密钥登录 PubkeyAuthentication: ${gl_huang}$(ssh_auth_status pubkeyauthentication)${gl_bai}"
		echo "------------------------"
		echo -e "${gl_kjlan}1.   ${gl_bai}修改 SSH 端口"
		echo -e "${gl_kjlan}2.   ${gl_bai}禁用/开启密码登录"
		echo -e "${gl_kjlan}3.   ${gl_bai}开启/禁用密钥登录"
		echo -e "${gl_kjlan}4.   ${gl_bai}一键配置（关闭密码登录、关闭 22、改用 $DEFAULT_SSH_PORT、开启密钥登录、开启 UFW）"
		echo -e "${gl_kjlan}5.   ${gl_bai}公钥和私钥管理"
		echo -e "${gl_kjlan}6.   ${gl_bai}修改 sshd_config 配置文件"
		echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
		read -e -p "请输入你的选择: " sub_choice || return 1
		case "$sub_choice" in
			1)
				read -e -p "请输入新 SSH 端口（默认 $DEFAULT_SSH_PORT）: " new_port || return 1
				new_port=${new_port:-$DEFAULT_SSH_PORT}
				if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
					ssh_transaction_apply Port "$new_port"
				else
					echo "端口不合法"
				fi
				;;
			2)
				echo "1. 禁用密码登录    2. 开启密码登录"
				read -e -p "请选择: " mode || return 1
				case "$mode" in
					1) ssh_transaction_apply PasswordAuthentication no KbdInteractiveAuthentication no PermitEmptyPasswords no ;;
					2) ssh_transaction_apply PasswordAuthentication yes KbdInteractiveAuthentication yes PermitRootLogin yes ;;
					*) echo "无效的输入，未修改 SSH。" ;;
				esac
				;;
			3)
				echo "1. 开启密钥登录    2. 禁用密钥登录"
				read -e -p "请选择: " mode || return 1
				case "$mode" in
					1)
						read -e -p "请粘贴公钥（可直接回车跳过）: " public_key || return 1
						if [ -n "$public_key" ] && ! ssh_add_public_key "$public_key"; then break_end; continue; fi
						ssh_transaction_apply PubkeyAuthentication yes AuthorizedKeysFile .ssh/authorized_keys
						;;
					2) ssh_transaction_apply PubkeyAuthentication no ;;
					*) echo "无效的输入，未修改 SSH。" ;;
				esac
				;;
			4)
				read -e -p "请粘贴公钥（回车使用已有公钥）: " public_key || return 1
				if [ -n "$public_key" ] && ! ssh_add_public_key "$public_key"; then break_end; continue; fi
				read -e -p "请输入 SSH 端口（默认 $DEFAULT_SSH_PORT）: " new_port || return 1
				new_port=${new_port:-$DEFAULT_SSH_PORT}
				if ! validate_tcp_port "$new_port"; then echo "端口不合法"; break_end; continue; fi
				daimon_require_cmd ufw || { break_end; continue; }
				blocked=$(ssh_one_click_blocked_ports "$new_port")
				open_args=()
				if [ -n "$blocked" ]; then
					echo -e "${gl_huang}检测到以下端口正在监听，开启 UFW 后默认无法从外部访问：${gl_bai}"
					printf '  %s\n' $blocked
					read -e -p "是否在 UFW 中放行以上端口？[Y/n]: " answer || return 1
					if [[ "${answer:-y}" =~ ^[Yy]$ ]]; then
						for port in $blocked; do open_args+=(--open "$port"); done
					else
						echo "以上端口不放行，之后可在 UFW 管理中放行。"
					fi
				fi
				ssh_transaction_apply --ufw "${open_args[@]}" Port "$new_port" PubkeyAuthentication yes AuthorizedKeysFile .ssh/authorized_keys PasswordAuthentication no KbdInteractiveAuthentication no PermitEmptyPasswords no PermitRootLogin prohibit-password
				;;
			5) ssh_key_manager; continue ;;
			6) ssh_config_edit ;;
			0) return ;;
			*) echo "无效的输入!" ;;
		esac
		break_end
	done
}

add_sshkey() {
	chmod 700 "${HOME}"
	mkdir -p "${HOME}/.ssh"
	chmod 700 "${HOME}/.ssh"
	touch "${HOME}/.ssh/authorized_keys"

	ssh-keygen -t ed25519 -C "xxxx@gmail.com" -f "${HOME}/.ssh/sshkey" -N "" || return 1

	cat "${HOME}/.ssh/sshkey.pub" >> "${HOME}/.ssh/authorized_keys" || return 1
	chmod 600 "${HOME}/.ssh/authorized_keys" || return 1

	ip_address
	echo -e "私钥信息已生成，务必复制保存，可保存成 ${gl_huang}${ipv4_address}_ssh.key${gl_bai} 文件，用于以后的SSH登录"

	echo "--------------------------------"
	cat "${HOME}/.ssh/sshkey"
	echo "--------------------------------"

	sshkey_on
}

fetch_github_ssh_keys() {

	local username="$1"
	local base_dir="${2:-$HOME}"

	echo "操作前，请确保您已在 GitHub 账户中添加了 SSH 公钥："
	echo "  1. 登录 ${gh_https_url}github.com/settings/keys"
	echo "  2. 点击 New SSH key 或 Add SSH key"
	echo "  3. Title 可随意填写（例如：Home Laptop 2026）"
	echo "  4. 将本地公钥内容（通常是 ~/.ssh/id_ed25519.pub 或 id_rsa.pub 的全部内容）粘贴到 Key 字段"
	echo "  5. 点击 Add SSH key 完成添加"
	echo ""
	echo "添加完成后，GitHub 会公开提供您的所有公钥，地址为："
	echo "  ${gh_https_url}github.com/您的用户名.keys"
	echo ""


	if [[ -z "${username}" ]]; then
		read -e -p "请输入您的 GitHub 用户名（username，不含 @）： " username || return 1
	fi

	if [[ -z "${username}" ]]; then
		echo "错误：GitHub 用户名不能为空" >&2
		return 1
	fi

	keys_url="${gh_https_url}github.com/${username}.keys"

	fetch_remote_ssh_keys "${keys_url}" "${base_dir}"

}

kj_ssh_read_auth() {
	local key_file="$1"
	local password_or_key=""

	echo "请选择身份验证方式:"
	echo "1. 密码"
	echo "2. 密钥"
	read -e -p "请输入选择 (1/2): " auth_choice || return 1

	case $auth_choice in
		1)
			read -s -p "请输入密码: " password_or_key || return 1
			echo
			if [ -z "$password_or_key" ]; then
				echo "错误: 密码不能为空。"
				return 1
			fi
			KJ_SSH_AUTH_METHOD="password"
			KJ_SSH_AUTH_SECRET="$password_or_key"
			;;
		2)
			echo "请粘贴密钥内容 (粘贴完成后按两次回车)："
			while IFS= read -r line; do
				if [[ -z "$line" && "$password_or_key" == *"-----BEGIN"* ]]; then
					break
				fi
				if [[ -n "$line" || "$password_or_key" == *"-----BEGIN"* ]]; then
					password_or_key+="${line}"$'\n'
				fi
			done

			if [[ "$password_or_key" != *"-----BEGIN"* || "$password_or_key" != *"PRIVATE KEY-----"* ]]; then
				echo "无效的密钥内容！"
				return 1
			fi

			mkdir -p "$(dirname "$key_file")"
			echo -n "$password_or_key" > "$key_file"
			chmod 600 "$key_file"
			KJ_SSH_AUTH_METHOD="key"
			KJ_SSH_AUTH_SECRET="$key_file"
			;;
		*)
			echo "无效的选择！"
			return 1
			;;
	esac
}

list_connections() {
	echo "已保存的连接:"
	echo "------------------------"
	cat "$CONFIG_FILE" | awk -F'|' '{print NR " - " $1 " (" $2 ")"}'
	echo "------------------------"
}

add_connection() {
	echo "创建新连接示例："
	echo "  - 连接名称: my_server"
	echo "  - IP地址: 192.168.1.100"
	echo "  - 用户名: root"
	echo "  - 端口: 22"
	echo "------------------------"
	read -e -p "请输入连接名称: " name || return 1

	kj_ssh_read_host_user_port "请输入IP地址: " "请输入用户名 (默认: root): " "请输入端口号 (默认: 22): " "root" "22"
	if ! kj_ssh_read_auth "$KEY_DIR/$name.key"; then
		return
	fi

	echo "$name|$KJ_SSH_HOST|$KJ_SSH_USER|$KJ_SSH_PORT|$KJ_SSH_AUTH_SECRET" >> "$CONFIG_FILE"
	echo "连接已保存!"
}

delete_connection() {
	read -e -p "请输入要删除的连接编号: " num || return 1

	local connection=$(sed -n "${num}p" "$CONFIG_FILE")
	if [[ -z "$connection" ]]; then
		echo "错误：未找到对应的连接。"
		return
	fi

	IFS='|' read -r name ip user port password_or_key <<< "$connection"

	# 如果连接使用的是密钥文件，则删除该密钥文件
	if [[ "$password_or_key" == "$KEY_DIR"* ]]; then
		rm -f "$password_or_key"
	fi

	sed -i "${num}d" "$CONFIG_FILE"
	echo "连接已删除!"
}

use_connection() {
	read -e -p "请输入要使用的连接编号: " num || return 1

	local connection=$(sed -n "${num}p" "$CONFIG_FILE")
	if [[ -z "$connection" ]]; then
		echo "错误：未找到对应的连接。"
		return
	fi

	IFS='|' read -r name ip user port password_or_key <<< "$connection"

	echo "正在连接到 $name ($ip)..."
	if [[ -f "$password_or_key" ]]; then
		# 使用密钥连接
		ssh -o StrictHostKeyChecking=no -i "$password_or_key" -p "$port" "$user@$ip"
		if [[ $? -ne 0 ]]; then
			echo "连接失败！请检查以下内容："
			echo "1. 密钥文件路径是否正确：$password_or_key"
			echo "2. 密钥文件权限是否正确（应为 600）。"
			echo "3. 目标服务器是否允许使用密钥登录。"
		fi
	else
		# 使用密码连接
		daimon_require_cmd sshpass || return 1
		sshpass -p "$password_or_key" ssh -o StrictHostKeyChecking=no -p "$port" "$user@$ip"
		if [[ $? -ne 0 ]]; then
			echo "连接失败！请检查以下内容："
			echo "1. 用户名和密码是否正确。"
			echo "2. 目标服务器是否允许密码登录。"
			echo "3. 目标服务器的 SSH 服务是否正常运行。"
		fi
	fi
}
