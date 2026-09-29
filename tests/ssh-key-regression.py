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
    if not match:
        raise AssertionError('Missing function: ' + name)
    return SOURCE[match.start():SOURCE.index('\n}', match.end()) + 2]


class SSHKeyTest(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='ssh-key.')
        self.work = Path(self.temp.name)
        (self.work / '.ssh').mkdir()
        self.auth = self.work / '.ssh/authorized_keys'
        self.auth.write_text('# existing keys\n', encoding='utf-8', newline='')
        self.config_dir = self.work / 'etc-ssh'
        self.config_dir.mkdir()
        for directory in ['sshd_config.d', 'ssh_config.d']:
            (self.config_dir / directory).mkdir()
            (self.config_dir / directory / 'business.conf').write_text('# existing include\n', encoding='utf-8', newline='')
        self.config = self.config_dir / 'sshd_config'
        self.original = 'Port 64400\nPasswordAuthentication yes\nPubkeyAuthentication no\nMatch User guest\n    PasswordAuthentication no\n'
        self.config.write_text(self.original, encoding='utf-8', newline='')
        result = self.shell('ssh-keygen -q -t ed25519 -N "" -f "$HOME/fixture"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.key = (self.work / 'fixture.pub').read_text().strip()

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, action, extra=''):
        names = ['sshkey_on', 'import_sshkey', 'fetch_remote_ssh_keys']
        names += re.findall(r'(?m)^((?:sshkey_[a-z_]+|ssh_public_key_valid|ssh_import_key_file))\(\) \{', SOURCE)
        definitions = '\n'.join(function(name) for name in dict.fromkeys(names))
        definitions = definitions.replace('/etc/ssh', '$HOME/etc-ssh')
        setup = '''
gl_hong='' gl_lv='' gl_bai=''
ssh_transaction_apply() {
    printf '%s\\n' "$@" > "$HOME/transaction-arguments"
    return "${TRANSACTION_RC:-0}"
}
curl() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$HOME/download" "$2"; return; fi
        shift
    done
    return 1
}
'''
        script = definitions + '\n' + setup + extra + '\n' + action + '\n'
        env = dict(os.environ, HOME=self.work.as_posix(), TMPDIR=self.work.as_posix(), LC_ALL='C.UTF-8')
        result = subprocess.run([BASH, '--noprofile', '--norc'], input=script.encode('utf-8'),
                                env=env, capture_output=True, timeout=15)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def fetch(self, content, extra=''):
        (self.work / 'download').write_text(content, encoding='utf-8', newline='')
        return self.shell('fetch_remote_ssh_keys https://example.test/keys', extra)

    def test_invalid_key_never_writes_or_restarts(self):
        result = self.shell('import_sshkey "ssh-ed25519 not-a-key"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auth.read_text(), '# existing keys\n')
        self.assertFalse((self.work / 'transaction-arguments').exists())

    def test_invalid_download_is_rejected(self):
        result = self.fetch('<html>Not a public key</html>\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auth.read_text(), '# existing keys\n')
        self.assertFalse((self.work / 'transaction-arguments').exists())

    def test_mixed_download_is_atomic(self):
        result = self.fetch(self.key + '\nssh-ed25519 invalid\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auth.read_text(), '# existing keys\n')

    def test_download_last_line_without_newline(self):
        result = self.fetch(self.key)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.key, self.auth.read_text().splitlines())

    def test_existing_last_line_is_not_joined_to_new_key(self):
        self.auth.write_text('# no newline', encoding='utf-8', newline='')
        result = self.fetch(self.key + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.auth.read_text().splitlines(), ['# no newline', self.key])

    def test_crlf_and_duplicates(self):
        result = self.fetch('# keys\r\n\r\n' + self.key + '\r\n' + self.key + '\r\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.auth.read_text().splitlines().count(self.key), 1)

    def test_transaction_failure_reaches_download_caller(self):
        result = self.fetch(self.key + '\n', extra='TRANSACTION_RC=1')
        self.assertNotEqual(result.returncode, 0)

    def test_repeated_import_does_not_duplicate_key(self):
        self.assertEqual(self.fetch(self.key + '\n').returncode, 0)
        self.assertEqual(self.fetch(self.key + '\n').returncode, 0)
        self.assertEqual(self.auth.read_text().splitlines().count(self.key), 1)

    def test_duplicate_key_can_retry_failed_mode_change(self):
        self.assertNotEqual(self.fetch(self.key + '\n', extra='TRANSACTION_RC=1').returncode, 0)
        self.assertEqual(self.fetch(self.key + '\n').returncode, 0)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertIn('PermitRootLogin\nprohibit-password', (self.work / 'transaction-arguments').read_text())

    def test_other_user_import_preserves_global_authentication(self):
        (self.work / 'other-user').mkdir()
        (self.work / 'download').write_text(self.key, encoding='utf-8', newline='')
        result = self.shell('fetch_remote_ssh_keys https://example.test/keys "$HOME/other-user"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.key, (self.work / 'other-user/.ssh/authorized_keys').read_text())
        self.assertEqual(self.config.read_text(), self.original)
        self.assertFalse((self.work / 'transaction-arguments').exists())

    def test_key_replacement_failure_preserves_existing_keys(self):
        result = self.fetch(self.key + '\n', extra='mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.auth.read_text(), '# existing keys\n')
        self.assertFalse((self.work / 'transaction-arguments').exists())

    def test_key_mode_routes_one_transaction_without_direct_config_writes(self):
        result = self.shell('sshkey_on')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual((self.work / 'transaction-arguments').read_text().splitlines(), [
            'PermitRootLogin', 'prohibit-password', 'PasswordAuthentication', 'no',
            'KbdInteractiveAuthentication', 'no', 'PubkeyAuthentication', 'yes', 'PermitEmptyPasswords', 'no'])

    def test_keys_only_import_does_not_change_authentication(self):
        (self.work / 'download').write_text(self.key, encoding='utf-8')
        result = self.shell('ssh_import_key_file "$HOME/download" "$HOME" keys-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.key, self.auth.read_text())
        self.assertFalse((self.work / 'transaction-arguments').exists())
        self.assertEqual(self.config.read_text(), self.original)

    @unittest.skipIf(os.name == 'nt', 'Real symlinks are verified on Linux')
    def test_symlink_authorized_keys_is_rejected(self):
        protected = self.work / 'protected'
        protected.write_text('protected\n', encoding='utf-8')
        self.auth.unlink()
        self.auth.symlink_to(protected)
        result = self.fetch(self.key + '\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(protected.read_text(), 'protected\n')


if __name__ == '__main__':
    syntax = subprocess.run([BASH, '-n'], input=SOURCE.encode('utf-8'), capture_output=True)
    if syntax.returncode:
        raise SystemExit(syntax.stderr.decode('utf-8'))
    unittest.main()
