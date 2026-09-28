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
        (self.etc / 'gai.conf').write_text('# owned policy\nlabel 2002::/16 2\nprecedence ::/0 40\nprecedence ::ffff:0:0/96 100\n', encoding='utf-8', newline='')
        (self.etc / 'hosts').write_text('127.0.0.1 localhost local-alias\n127.0.1.1 old-host kept-alias\n192.0.2.1 a.example other-alias\n192.0.2.2 unrelated\n', encoding='utf-8', newline='')
        (self.etc / 'hostname').write_text('old-host\n', encoding='utf-8', newline='')
        (self.home / '.bashrc').write_text('# user shell configuration\n', encoding='utf-8', newline='')
        (self.home / '.profile').write_text('# user login configuration\n', encoding='utf-8', newline='')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, names, action, inputs='', setup=''):
        optional = ['daimon_config_commit', 'daimon_env_write', 'daimon_env_name_valid', 'daimon_gai_preference',
                    'prefer_ipv6', 'daimon_hosts_edit', 'daimon_set_hostname']
        for name in optional:
            if name not in names and re.search(r'(?m)^' + name + r'\(\)', SOURCE):
                names = names + [name]
        body = '\n'.join(function(n) for n in names)
        body = body.replace('/etc/gai.conf', str(self.etc / 'gai.conf').replace('\\', '/'))
        body = body.replace('/etc/hosts', str(self.etc / 'hosts').replace('\\', '/'))
        body = body.replace('/etc/hostname', str(self.etc / 'hostname').replace('\\', '/'))
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


if __name__ == '__main__':
    unittest.main()
