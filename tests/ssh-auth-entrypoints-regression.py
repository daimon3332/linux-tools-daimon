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
    match = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[match.start():SOURCE.index('\n}\n', match.end()) + 2]


class AuthenticationRouting(unittest.TestCase):
    def invoke(self, inputs, entry='ssh_config_manager', extra=''):
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            trace = Path(directory) / 'trace'
            config = Path(directory) / 'sshd_config'
            config.write_text('PasswordAuthentication yes\nPubkeyAuthentication yes\n', encoding='utf-8')
            definitions = '\n'.join(function(name) for name in ('ssh_config_manager', 'add_sshpasswd', 'new_ssh_port'))
            definitions = definitions.replace('/etc/ssh', '$FIXTURE_SSH')
            script = definitions + r'''
clear() { :; }
root_use() { :; }
id() { echo 0; }
break_end() { :; }
send_stats() { :; }
ssh_current_ports() { echo 22; }
sshd() { printf '%s\n' 'passwordauthentication no' 'pubkeyauthentication yes'; }
ssh_public_key_valid() { return 1; }
ssh_transaction_apply() { printf 'transaction %s\n' "$*" >> "$TRACE"; return "${TXN_RC:-0}"; }
passwd() { echo passwd >> "$TRACE"; return "${PASSWD_RC:-0}"; }
sed() { echo unsafe-sed >> "$TRACE"; return 90; }
rm() { echo unsafe-rm >> "$TRACE"; return 90; }
systemctl() { echo unsafe-systemctl >> "$TRACE"; return 90; }
service() { echo unsafe-service >> "$TRACE"; return 90; }
command() {
    case "$1" in systemctl|service) echo unsafe-service >> "$TRACE"; return 90 ;; esac
    builtin command "$@"
}
''' + extra + '\n' + entry
            result = subprocess.run([BASH, '--noprofile', '--norc', '-c', script], input=inputs.encode('utf-8'),
                                    capture_output=True, timeout=15,
                                    env=dict(os.environ, TRACE=trace.as_posix(), FIXTURE_SSH=Path(directory).as_posix()))
            result.stdout = result.stdout.decode('utf-8')
            result.stderr = result.stderr.decode('utf-8')
            return result, trace.read_text(encoding='utf-8').splitlines() if trace.exists() else []

    def test_password_disable_is_one_transaction(self):
        result, trace = self.invoke('2\n1\n0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['transaction PasswordAuthentication no KbdInteractiveAuthentication no PermitEmptyPasswords no'])

    def test_legacy_port_does_not_remove_firewalls_or_includes(self):
        result, trace = self.invoke('', 'new_ssh_port 2224')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['transaction Port 2224'])

    def test_password_enable_is_one_transaction(self):
        _, trace = self.invoke('2\n2\n0\n')
        self.assertEqual(trace, ['transaction PasswordAuthentication yes KbdInteractiveAuthentication yes PermitRootLogin yes'])

    def test_key_enable_without_new_key(self):
        _, trace = self.invoke('3\n1\n\n0\n')
        self.assertEqual(trace, ['transaction PubkeyAuthentication yes AuthorizedKeysFile .ssh/authorized_keys'])

    def test_key_disable_is_one_transaction(self):
        _, trace = self.invoke('3\n2\n0\n')
        self.assertEqual(trace, ['transaction PubkeyAuthentication no'])

    def test_invalid_choice_or_eof_does_not_apply(self):
        for inputs in ('2\n9\n0\n', '3\n9\n0\n', '2\n', '3\n1\n'):
            with self.subTest(inputs=inputs):
                _, trace = self.invoke(inputs)
                self.assertEqual(trace, [])

    def test_invalid_key_does_not_change_authentication(self):
        _, trace = self.invoke('3\n1\ninvalid-key\n0\n')
        self.assertEqual(trace, [])

    def test_password_failure_preserves_ssh_policy(self):
        result, trace = self.invoke('', 'add_sshpasswd root', 'PASSWD_RC=1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ['passwd'])

    def test_legacy_password_routes_transaction(self):
        result, trace = self.invoke('', 'add_sshpasswd root')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['passwd', 'transaction PasswordAuthentication yes PermitRootLogin yes'])

    def test_transaction_failure_is_not_reported_as_password_rollback(self):
        result, trace = self.invoke('', 'add_sshpasswd root', 'TXN_RC=1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(trace), 2)
        self.assertIn('密码已修改', result.stderr)


if __name__ == '__main__':
    (ROOT / '.tmp').mkdir(exist_ok=True)
    unittest.main()
