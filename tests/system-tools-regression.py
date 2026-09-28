import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    match = re.search(r'(?m)^' + re.escape(name) + r'\(\) ([{(])\n', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    closing = '}' if match[1] == '{' else ')'
    return SOURCE[match.start():SOURCE.index('\n' + closing, match.end()) + 2]


class SystemTools(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='system-tools.')
        self.work = Path(self.temp.name)
        self.etc = self.work / 'etc'
        self.etc.mkdir()
        self.home = self.work / 'home'
        self.home.mkdir()
        for name in ['local-bin', 'system-bin']:
            (self.work / name).mkdir()
        (self.work / 'local-bin/d').write_bytes(b'#!/bin/sh\necho fixture\n')
        (self.etc / 'gai.conf').write_text('# owned policy\nlabel 2002::/16 2\nprecedence ::/0 40\nprecedence ::ffff:0:0/96 100\n', encoding='utf-8', newline='')
        (self.etc / 'hosts').write_text('127.0.0.1 localhost local-alias\n127.0.1.1 old-host kept-alias\n192.0.2.1 a.example other-alias\n192.0.2.2 unrelated\n', encoding='utf-8', newline='')
        (self.etc / 'hostname').write_text('old-host\n', encoding='utf-8', newline='')
        (self.etc / 'resolv.conf').write_bytes(b'nameserver 192.0.2.53\nsearch kept.test\n')
        (self.work / 'run/systemd/resolve').mkdir(parents=True)
        (self.home / '.bashrc').write_text('# user shell configuration\n', encoding='utf-8', newline='')
        (self.home / '.profile').write_text('# user login configuration\n', encoding='utf-8', newline='')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, names, action, inputs='', setup=''):
        optional = ['daimon_config_commit', 'daimon_env_write', 'daimon_env_name_valid', 'daimon_gai_preference',
                    'prefer_ipv6', 'daimon_hosts_edit', 'daimon_set_hostname', 'daimon_dns_commit', 'edit_dns_config']
        for name in optional:
            if name not in names and re.search(r'(?m)^' + name + r'\(\)', SOURCE):
                names = names + [name]
        body = '\n'.join(function(n) for n in names)
        body = body.replace('/etc/gai.conf', str(self.etc / 'gai.conf').replace('\\', '/'))
        body = body.replace('/etc/hosts', str(self.etc / 'hosts').replace('\\', '/'))
        body = body.replace('/etc/hostname', str(self.etc / 'hostname').replace('\\', '/'))
        body = body.replace('/etc/resolv.conf', (self.etc / 'resolv.conf').as_posix())
        body = body.replace('/etc/.daimon-resolv', (self.etc / '.daimon-resolv').as_posix())
        body = body.replace('/etc/.daimon-dns', (self.etc / '.daimon-dns').as_posix())
        body = body.replace('/run/systemd/resolve', (self.work / 'run/systemd/resolve').as_posix())
        body = body.replace('/run/NetworkManager', (self.work / 'run/NetworkManager').as_posix())
        body = body.replace('/run/resolvconf', (self.work / 'run/resolvconf').as_posix())
        body = body.replace('/usr/local/bin', (self.work / 'local-bin').as_posix())
        body = body.replace('/usr/bin', (self.work / 'system-bin').as_posix())
        body += '''
clear() { :; }; root_use() { :; }; send_stats() { :; }; break_end() { :; }
install() { echo unexpected-install; return 99; }
uname() { [ "$1" != -n ] || echo old-host; }
hostnamectl() { echo "$*" >> "$WORK/hostname-calls"; return 1; }
hostname() { echo "$*" >> "$WORK/hostname-calls"; return 1; }
systemctl() { echo unexpected-service-change; return 99; }
'''
        if os.name == 'nt':
            body += 'python3() { command python "$@"; }\n'
        body += setup + '\n' + action + '\n'
        syntax = subprocess.run([BASH, '-n'], input=body.encode(), capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode())
        script = self.work / 'entry.sh'
        script.write_bytes(body.encode())
        result = subprocess.run([BASH, '--noprofile', '--norc', str(script)], input=inputs.encode(),
                              env=dict(os.environ, WORK=self.work.as_posix(), HOME=self.home.as_posix(), TMPDIR=self.work.as_posix()),
                              capture_output=True, timeout=12)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def test_ipv6_preference_preserves_unrelated_policy(self):
        result = self.shell(['linux_Settings', 'prefer_ipv4'], 'linux_Settings', '4\n2\n0\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.etc / 'gai.conf'
        self.assertTrue(path.exists())
        self.assertIn('label 2002::/16 2', path.read_text())
        self.assertIn('precedence ::/0 40', path.read_text())
        self.assertNotIn('::ffff:0:0/96 100', path.read_text())

    def test_ipv4_preference_is_idempotent(self):
        result = self.shell(['prefer_ipv4'], 'prefer_ipv4; prefer_ipv4')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.etc / 'gai.conf').read_text()
        self.assertEqual(text.count('::ffff:0:0/96'), 1)
        self.assertIn('label 2002::/16 2', text)

    def test_ipv4_write_failure_is_not_success(self):
        path = self.etc / 'gai.conf'
        path.unlink(); path.mkdir()
        result = self.shell(['prefer_ipv4'], 'prefer_ipv4')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('已切换为', result.stdout)

    def test_hosts_deletion_is_literal_not_regex(self):
        result = self.shell(['linux_Settings'], 'linux_Settings', '9\n2\na.example\n0\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('a.example', (self.etc / 'hosts').read_text())
        self.assertIn('unrelated', (self.etc / 'hosts').read_text())
        before = (self.etc / 'hosts').read_bytes()
        self.shell(['linux_Settings'], 'linux_Settings', '9\n2\n.*\n0\n0\n')
        self.assertEqual(before, (self.etc / 'hosts').read_bytes())

    def test_hosts_invalid_record_is_rejected(self):
        before = (self.etc / 'hosts').read_bytes()
        self.shell(['linux_Settings'], 'linux_Settings', '9\n1\nnot-an-address example.test\n0\n0\n')
        self.assertEqual(before, (self.etc / 'hosts').read_bytes())

    def test_hostname_failure_preserves_files_and_does_not_claim_success(self):
        before = {name: (self.etc / name).read_bytes() for name in ['hostname', 'hosts']}
        result = self.shell(['linux_Settings'], 'linux_Settings', '8\nnew-host\n0\n0\n')
        for name, data in before.items():
            self.assertEqual(data, (self.etc / name).read_bytes())
        self.assertNotIn('主机名已更改为', result.stdout)

    def test_invalid_hostname_does_not_reach_system_commands(self):
        before = (self.etc / 'hostname').read_bytes()
        self.shell(['linux_Settings'], 'linux_Settings', '8\ninvalid/name\n0\n0\n')
        self.assertFalse((self.work / 'hostname-calls').exists())
        self.assertEqual(before, (self.etc / 'hostname').read_bytes())

    def test_env_value_is_literal_and_existing_shell_is_not_sourced(self):
        (self.home / '.bashrc').write_text('touch "$WORK/old-shell-executed"\n', encoding='utf-8', newline='')
        value = '$(touch "$WORK/injected") literal \' quote \\ backslash'
        result = self.shell(['env_menu'], 'env_menu', '2\nAUDIT_VALUE\n' + value + '\n1\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.work / 'injected').exists())
        self.assertFalse((self.work / 'old-shell-executed').exists())
        result = self.shell([], 'source "$HOME/.bashrc"; printf "%s" "$AUDIT_VALUE"')
        self.assertEqual(result.stdout, value)
        self.assertFalse((self.work / 'injected').exists())

    def test_env_invalid_name_and_target_leave_files_unchanged(self):
        for name, target in [('A.*', '1'), ('VALID', '3'), ('UID', '1')]:
            with self.subTest(name=name, target=target):
                before = (self.home / '.bashrc').read_bytes()
                self.shell(['env_menu'], 'env_menu', '2\n' + name + '\nvalue\n' + target + '\n0\n')
                self.assertEqual(before, (self.home / '.bashrc').read_bytes())

    def test_env_delete_preserves_other_exports_and_never_sources_files(self):
        (self.home / '.bashrc').write_text('export FIRST=one\nexport SECOND=two\ntouch "$WORK/sourced"\n', encoding='utf-8', newline='')
        self.shell(['env_menu'], 'env_menu', '3\nFIRST\n0\n')
        text = (self.home / '.bashrc').read_text()
        self.assertNotIn('export FIRST=', text)
        self.assertIn('export SECOND=two', text)
        self.assertFalse((self.work / 'sourced').exists())

    def test_env_edit_does_not_break_the_running_toolbox_environment(self):
        result = self.shell(['env_menu'], 'before=$PATH; env_menu; test "$PATH" = "$before"',
                            '2\nPATH\n/not-an-executable-path\n1\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("export PATH='/not-an-executable-path'", (self.home / '.bashrc').read_text())
        result = self.shell(['env_menu'], 'export AUDIT_DELETE=kept; env_menu; test "$AUDIT_DELETE" = kept',
                            '3\nAUDIT_DELETE\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_env_special_shell_attributes_are_rejected_without_side_effects(self):
        for setup in ['declare -i AUDIT_TYPED=7', 'declare -n AUDIT_TYPED=AUDIT_OTHER', 'declare -l AUDIT_TYPED=lower']:
            with self.subTest(setup=setup):
                (self.work / 'arithmetic-executed').unlink(missing_ok=True)
                before = (self.home / '.bashrc').read_bytes()
                value = 'a[$(touch "$WORK/arithmetic-executed")]'
                result = self.shell(['env_menu'], 'env_menu; test "$AUDIT_OTHER" = untouched',
                                    '2\nAUDIT_TYPED\n' + value + '\n1\n0\n',
                                    setup='AUDIT_OTHER=untouched; ' + setup)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.work / 'arithmetic-executed').exists())
                self.assertEqual(before, (self.home / '.bashrc').read_bytes())

    def test_env_internal_local_name_does_not_hide_readonly_variable(self):
        before = (self.home / '.bashrc').read_bytes()
        result = self.shell(['env_menu'], 'env_menu', '2\nname\nchanged\n1\n0\n', setup='readonly name=keep')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, (self.home / '.bashrc').read_bytes())

    def test_proxy_name_is_not_a_regex(self):
        path = self.work / 'github_proxy_sources.txt'
        path.write_text('business|https://example.test/one\n', encoding='utf-8', newline='')
        names = ['github_proxy_sources_file', 'github_proxy_init_sources', 'github_proxy_add_source']
        self.shell(names, 'github_proxy_add_source', '.*\nhttps://example.test/two\n', setup='DAIMON_SCRIPT_DIR="$WORK"')
        self.assertIn('business|', path.read_text())

    def test_proxy_delete_out_of_range_is_failure(self):
        path = self.work / 'github_proxy_sources.txt'
        path.write_text('business|https://example.test/one\n', encoding='utf-8', newline='')
        names = ['github_proxy_sources_file', 'github_proxy_init_sources', 'github_proxy_show_sources', 'github_proxy_delete_source']
        result = self.shell(names, 'github_proxy_delete_source', '99\n', setup='DAIMON_SCRIPT_DIR="$WORK"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('business|', path.read_text())

    def test_hosts_add_ipv6_is_idempotent_and_keeps_aliases(self):
        record = '2001:db8::123 app.example app-alias # owned fixture'
        result = self.shell([], 'daimon_hosts_edit add "$RECORD"; daimon_hosts_edit add "$RECORD"', setup='RECORD=' + "'" + record + "'")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.etc / 'hosts').read_text()
        self.assertEqual(text.count('2001:db8::123'), 1)
        self.assertIn('old-host kept-alias', text)

    def test_hostname_success_preserves_aliases_without_service_restart(self):
        result = self.hostname_action('daimon_set_hostname new-host')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.etc / 'hostname').read_text().strip(), 'new-host')
        text = (self.etc / 'hosts').read_text()
        self.assertIn('new-host kept-alias', text)
        self.assertIn('localhost local-alias', text)
        self.assertIn('a.example other-alias', text)
        self.assertNotIn('unexpected-service-change', result.stdout)
        self.assertFalse(list(self.etc.glob('.daimon-hostname.*')))

    def hostname_action(self, action, setup=''):
        (self.work / 'runtime').write_bytes(b'old-host\n')
        return self.shell([], action, setup='''
hostname() { printf '%s\\n' "$1" > "$WORK/runtime"; }
uname() { cat "$WORK/runtime"; }
''' + setup)

    def test_hostname_second_file_failure_restores_first_file_and_runtime(self):
        before = {name: (self.etc / name).read_bytes() for name in ['hostname', 'hosts']}
        result = self.hostname_action('daimon_set_hostname new-host', '''
eval "$(declare -f daimon_config_commit | sed '1s/daimon_config_commit/original_commit/')"
daimon_config_commit() { case "$2" in */new-hosts) return 1 ;; *) original_commit "$@" ;; esac; }
''')
        self.assertNotEqual(result.returncode, 0)
        for name, data in before.items():
            self.assertEqual(data, (self.etc / name).read_bytes())
        self.assertEqual((self.work / 'runtime').read_text().strip(), 'old-host')
        self.assertFalse(list(self.etc.glob('.daimon-hostname.*')))

    def test_hostname_term_restores_runtime(self):
        result = self.hostname_action('daimon_set_hostname new-host', '''
hostname() { printf '%s\\n' "$1" > "$WORK/runtime"; [ "$1" != new-host ] || kill -TERM "$BASHPID"; }
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.work / 'runtime').read_text().strip(), 'old-host')
        self.assertEqual((self.etc / 'hostname').read_text().strip(), 'old-host')

    def test_config_replace_failure_keeps_original(self):
        before = (self.etc / 'gai.conf').read_bytes()
        result = self.shell(['prefer_ipv4'], 'prefer_ipv4', setup='mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.etc / 'gai.conf').read_bytes())

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink ownership fixture')
    def test_symlink_configuration_is_rejected(self):
        target = self.work / 'unrelated'
        target.write_bytes(b'unrelated-data\n')
        path = self.etc / 'gai.conf'
        path.unlink(); path.symlink_to(target)
        result = self.shell(['prefer_ipv4'], 'prefer_ipv4')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b'unrelated-data\n')

    def test_proxy_existing_custom_sources_are_not_reinitialized(self):
        path = self.work / 'github_proxy_sources.txt'
        before = b'raw.githubusercontent.com|https://custom.example/path\n'
        path.write_bytes(before)
        result = self.shell(['github_proxy_sources_file', 'github_proxy_init_sources'], 'github_proxy_init_sources', setup='DAIMON_SCRIPT_DIR="$WORK"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, path.read_bytes())

    def test_proxy_partial_download_cannot_rank_as_success(self):
        path = self.work / 'github_proxy_sources.txt'
        path.write_bytes(b'custom|https://example.test/payload\n')
        names = ['github_proxy_sources_file', 'github_proxy_init_sources', 'github_proxy_speed_test']
        result = self.shell(names, 'github_proxy_speed_test', setup='DAIMON_SCRIPT_DIR="$WORK"; curl() { echo "200 0.5 3000 1500"; return 18; }')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('OK  HTTP:', result.stdout)
        self.assertIn('FAIL  HTTP:', result.stdout)

    def test_shortcut_failure_preserves_existing_aliases(self):
        names = ['linux_Settings', 'daimon_shortcut_available']
        if 'daimon_set_shortcut()' in SOURCE:
            names.append('daimon_set_shortcut')
        result = self.shell(names, 'linux_Settings', '1\naudit-shortcut\n0\n0\n', setup='''
daimon_shortcut_available() { return 0; }
find() { echo REMOVED_OLD_ALIASES; }
ln() { return 1; }
''')
        self.assertNotIn('REMOVED_OLD_ALIASES', result.stdout)
        self.assertNotIn('快捷键已设置:', result.stdout)

    def test_mirror_menu_does_not_execute_failed_partial_download(self):
        result = self.shell(['linux_Settings', 'daimon_run_cached_script'], 'linux_Settings', '2\n0\n', setup='''
curl() { echo 'touch "$WORK/partial-executed"'; return 18; }
daimon_download() { return 1; }
''')
        self.assertFalse((self.work / 'partial-executed').exists(), result.stdout)

    def test_cached_script_syntax_is_checked_before_execution(self):
        (self.work / 'broken.sh').write_bytes(b'touch "$WORK/partial-executed"\nif then\n')
        result = self.shell(['daimon_run_cached_script'], 'daimon_run_cached_script https://example.invalid broken.sh',
                            setup='DAIMON_SCRIPT_DIR="$WORK"; daimon_download() { return 0; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'partial-executed').exists())

    def test_cached_exec_script_syntax_is_checked_before_execution(self):
        (self.work / 'broken.sh').write_bytes(b'touch "$WORK/partial-executed"\nif then\n')
        result = self.shell(['daimon_exec_cached_script'], 'daimon_exec_cached_script https://example.invalid broken.sh',
                            setup='DAIMON_SCRIPT_DIR="$WORK"; daimon_download() { return 0; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'partial-executed').exists())

    def test_cached_script_permission_failure_is_not_success(self):
        (self.work / 'cached.sh').write_bytes(b'echo fixture\n')
        result = self.shell(['daimon_download'], 'daimon_download https://example.invalid cached.sh',
                            setup='DAIMON_SCRIPT_DIR="$WORK"; chmod() { return 1; }')
        self.assertNotEqual(result.returncode, 0)

    @unittest.skipIf(os.name == 'nt', 'POSIX shortcut fixture')
    def test_shortcut_success_cleans_only_owned_aliases_and_keeps_d(self):
        target = self.work / 'local-bin/d'
        for directory in ['local-bin', 'system-bin']:
            (self.work / directory / 'old').symlink_to(target)
            (self.work / directory / 'unrelated').symlink_to('/bin/true')
        result = self.shell(['daimon_shortcut_available', 'daimon_set_shortcut'], 'daimon_set_shortcut audit')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(target.is_file())
        for directory in ['local-bin', 'system-bin']:
            self.assertEqual((self.work / directory / 'audit').resolve(), target)
            self.assertFalse((self.work / directory / 'old').is_symlink())
            self.assertEqual(os.readlink(self.work / directory / 'unrelated'), '/bin/true')

    @unittest.skipIf(os.name == 'nt', 'POSIX shortcut fixture')
    def test_shortcut_second_install_failure_restores_first_alias(self):
        target = self.work / 'local-bin/d'
        for directory in ['local-bin', 'system-bin']:
            (self.work / directory / 'old').symlink_to(target)
        (self.work / 'local-bin/audit').symlink_to(target.parent / 'old')
        result = self.shell(['daimon_shortcut_available', 'daimon_set_shortcut'], 'daimon_set_shortcut audit', setup='''
mv() { case "${@: -1}" in "$WORK/system-bin/audit") return 1 ;; esac; command mv "$@"; }
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(self.work / 'local-bin/audit'), str(target.parent / 'old'))
        self.assertFalse((self.work / 'system-bin/audit').is_symlink())
        for directory in ['local-bin', 'system-bin']:
            self.assertTrue((self.work / directory / 'old').is_symlink())
            self.assertFalse(list((self.work / directory).glob('audit.*')))

    def test_dns_restore_without_running_manager_preserves_working_config(self):
        before = (self.etc / 'resolv.conf').read_bytes()
        result = self.shell(['restore_dns_config'], 'restore_dns_config', setup='chattr() { :; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.etc / 'resolv.conf').read_bytes())
        self.assertNotIn('已恢复', result.stdout)

    def test_dns_restore_rejects_missing_or_empty_manager_config(self):
        before = (self.etc / 'resolv.conf').read_bytes()
        (self.work / 'run/systemd/resolve/resolv.conf').write_bytes(b'# not configured\n')
        result = self.shell(['restore_dns_config'], 'restore_dns_config', setup='systemctl() { return 0; }; chattr() { :; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.etc / 'resolv.conf').read_bytes())

    @unittest.skipIf(os.name == 'nt', 'POSIX resolver symlink fixture')
    def test_dns_restore_relinks_manager_config_without_overwriting_it(self):
        target = self.work / 'run/systemd/resolve/resolv.conf'
        expected = b'nameserver 192.0.2.54\nsearch managed.test\n'
        target.write_bytes(expected)
        result = self.shell(['restore_dns_config'], 'restore_dns_config', setup='systemctl() { [ "$*" = "is-active --quiet systemd-resolved" ]; }; chattr() { :; }')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.etc / 'resolv.conf').is_symlink())
        self.assertEqual((self.etc / 'resolv.conf').resolve(), target)
        self.assertEqual(target.read_bytes(), expected)

    def test_dns_restore_replace_failure_preserves_working_config(self):
        before = (self.etc / 'resolv.conf').read_bytes()
        (self.work / 'run/systemd/resolve/resolv.conf').write_bytes(b'nameserver 192.0.2.54\n')
        result = self.shell(['restore_dns_config'], 'restore_dns_config', setup='systemctl() { return 0; }; chattr() { :; }; mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.etc / 'resolv.conf').read_bytes())

    def dns_setup(self):
        return 'ip_address() { ipv4_address=192.0.2.1; ipv6_address=""; }; chattr() { :; }; dns1_ipv4=1.1.1.1; dns2_ipv4=8.8.8.8; '

    def test_dns_optimization_preserves_search_and_options(self):
        path = self.etc / 'resolv.conf'
        path.write_bytes(b'nameserver 192.0.2.53\nsearch business.test\noptions edns0 timeout:2\n')
        result = self.shell(['set_dns'], 'set_dns', setup=self.dns_setup())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('search business.test', path.read_text())
        self.assertIn('options edns0 timeout:2', path.read_text())
        self.assertNotIn('192.0.2.53', path.read_text())

    @unittest.skipIf(os.name == 'nt', 'POSIX managed resolver fixture')
    def test_dns_optimization_does_not_overwrite_manager_symlink_target(self):
        path = self.etc / 'resolv.conf'
        original = path.read_bytes()
        target = self.work / 'run/systemd/resolve/resolv.conf'; target.write_bytes(original)
        path.unlink(); path.symlink_to(target)
        result = self.shell(['set_dns'], 'set_dns', setup=self.dns_setup())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(path.is_symlink())
        self.assertEqual(target.read_bytes(), original)

    def test_dns_optimization_replace_failure_preserves_config(self):
        path = self.etc / 'resolv.conf';before = path.read_bytes()
        result = self.shell(['set_dns'], 'set_dns', setup=self.dns_setup()+'mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, path.read_bytes())

    def test_dns_failed_editor_does_not_commit_partial_changes(self):
        before = (self.etc / 'resolv.conf').read_bytes()
        result = self.shell(['set_dns_ui'], 'set_dns_ui', '3\n0\n', setup='''
install() { :; }; chattr() { :; }
vim() { echo 'nameserver 192.0.2.99' > "${@: -1}"; return 1; }
''')
        self.assertEqual(before, (self.etc / 'resolv.conf').read_bytes(), result.stderr)

    def test_dns_editor_rejects_invalid_nameserver_and_preserves_config(self):
        before = (self.etc / 'resolv.conf').read_bytes()
        result = self.shell([], 'edit_dns_config', setup='''
install() { :; }; chattr() { :; }
vim() { echo 'nameserver invalid-address' > "${@: -1}"; }
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.etc / 'resolv.conf').read_bytes())

    def test_dns_editor_valid_config_is_committed(self):
        result = self.shell([], 'edit_dns_config', setup='''
install() { :; }; chattr() { :; }
vim() { printf 'nameserver 2001:db8::53\\nsearch edited.test\\n' > "${@: -1}"; }
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.etc / 'resolv.conf').read_text(), 'nameserver 2001:db8::53\nsearch edited.test\n')


if __name__ == '__main__':
    unittest.main()
