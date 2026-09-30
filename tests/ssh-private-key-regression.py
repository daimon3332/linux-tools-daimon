from source import read_source
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = read_source(ROOT)


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([({])\n', SOURCE)
    closing = ')' if match[1] == '(' else '}'
    return SOURCE[match.start():SOURCE.index('\n' + closing + '\n', match.end()) + 2]


@unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'requires native root-owned Linux key fixtures')
class PrivateKeyTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='private-key-')
        self.work = Path(self.temp.name).resolve()
        self.ssh = self.work / '.ssh'
        self.ssh.mkdir(mode=0o700)
        self.seed = self.work / 'seed'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.seed)], check=True,
                       capture_output=True, timeout=30)
        self.private = self.seed.read_bytes()
        self.public = self.seed.with_suffix('.pub').read_bytes()

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, action='install', name='test-key', content=None, password=''):
        names = ['validate_config_name', 'ssh_private_key_name_valid', 'ssh_private_key_directory',
                 'ssh_private_key_install', 'ssh_private_key_remove']
        script = '\n'.join(function(n) for n in names).replace('/root', str(self.work))
        script += '\nssh_private_key_' + action + ' "$1"\n'
        askpass = self.work / 'askpass'
        askpass.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_KEY_PASSWORD"\n')
        askpass.chmod(0o700)
        result = subprocess.run(['bash', '--noprofile', '--norc', '-c', script, 'test', name],
                                input=self.private if content is None else content, capture_output=True, timeout=30,
                                env=dict(os.environ, SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE='force',
                                         DISPLAY=':0', TEST_KEY_PASSWORD=password))
        self.assertNotIn(self.private, result.stdout + result.stderr)
        self.assertEqual(list(self.ssh.glob('.private-key.*')), [])
        return result

    def test_install_validate_permissions_and_remove(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.ssh / 'test-key'
        self.assertEqual(target.read_bytes(), self.private)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(target.stat().st_nlink, 1)
        self.assertEqual(self.invoke('remove').returncode, 0)
        self.assertFalse(target.exists())

    def test_invalid_public_or_truncated_data_not_published(self):
        for data in (b'not a key\n', self.public, self.private[:80], b''):
            with self.subTest(kind=data[:20]):
                self.assertNotEqual(self.invoke(content=data).returncode, 0)
                self.assertFalse((self.ssh / 'test-key').exists())

    def test_existing_file_and_symlink_never_overwritten(self):
        target = self.ssh / 'test-key'
        target.write_bytes(b'existing')
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(target.read_bytes(), b'existing')
        target.unlink()
        target.symlink_to(self.seed)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.seed.read_bytes(), self.private)

    def test_directory_symlink_and_writable_directory_rejected(self):
        self.ssh.rmdir()
        other = self.work / 'other'
        other.mkdir()
        self.ssh.symlink_to(other, target_is_directory=True)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(list(other.iterdir()), [])
        self.ssh.unlink()
        self.ssh.mkdir(mode=0o777)
        self.ssh.chmod(0o777)
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_reserved_names_and_traversal_rejected(self):
        for name in ('authorized_keys', 'authorized_keys2', 'config', 'environment', 'rc', '../outside', 'key.pub'):
            with self.subTest(name=name):
                self.assertNotEqual(self.invoke(name=name).returncode, 0)
        self.assertEqual(list(self.ssh.iterdir()), [])

    def test_unrelated_file_or_shared_key_not_deleted(self):
        target = self.ssh / 'test-key'
        target.write_bytes(b'not a key')
        target.chmod(0o600)
        self.assertNotEqual(self.invoke('remove').returncode, 0)
        self.assertEqual(target.read_bytes(), b'not a key')
        target.unlink()
        os.link(self.seed, target)
        self.assertNotEqual(self.invoke('remove').returncode, 0)
        self.assertTrue(target.exists())

    def test_encrypted_openssh_and_pem_require_correct_passphrase(self):
        for kind, options in (('ed25519', []), ('rsa', ['-b', '2048', '-m', 'PEM'])):
            with self.subTest(kind=kind):
                seed = self.work / ('encrypted-' + kind)
                subprocess.run(['ssh-keygen', '-q', '-t', kind, *options, '-N', 'fixture-passphrase', '-f', str(seed)],
                               check=True, capture_output=True, timeout=60)
                data = seed.read_bytes()
                self.assertNotEqual(self.invoke(content=data, password='wrong').returncode, 0)
                self.assertFalse((self.ssh / 'test-key').exists())
                self.assertEqual(self.invoke(content=data, password='fixture-passphrase').returncode, 0)
                self.assertEqual(self.invoke('remove', password='fixture-passphrase').returncode, 0)


if __name__ == '__main__':
    unittest.main()
