from source import read_source
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = read_source(ROOT)
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([{(])\n', SOURCE)
    closing = '}' if match[1] == '{' else ')'
    return SOURCE[match.start():SOURCE.index('\n' + closing, match.end()) + 2]


class BackupDelete(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='backup-delete.')
        self.work = Path(self.temp.name)
        self.backups = self.work / 'backups'
        self.backups.mkdir()
        self.backup = self.backups / 'etc_20260929.tar.gz'
        self.backup.write_bytes(b'owned backup')
        self.other = self.work / 'other.tar.gz'
        self.other.write_bytes(b'other data')

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, inputs='etc_20260929.tar.gz\ny\n', failure=''):
        names = ['delete_backup']
        if 'daimon_backup_delete_target()' in SOURCE:
            names.append('daimon_backup_delete_target')
        body = '\n'.join(function(name) for name in names) + r'''
send_stats() { :; }
rm() {
    printf '%s\n' "$*" >> "$WORK/remove-calls"
    [ "$FAILURE" != remove ] || return 1
    command rm "$@"
}
read() {
    builtin read "$@" || return $?
    if [ "$FAILURE" = replace ] && [ "${!#}" = confirm ]; then
        printf 'replacement' > "$BACKUP_DIR/replacement"
        command mv -f "$BACKUP_DIR/replacement" "$BACKUP_DIR/etc_20260929.tar.gz"
    fi
}
delete_backup
'''
        entry = self.work / 'entry.sh'
        entry.write_bytes(body.encode())
        return subprocess.run([BASH, '--noprofile', '--norc', entry.as_posix()], input=inputs.encode(),
                              capture_output=True, timeout=15,
                              env=dict(os.environ, WORK=self.work.as_posix(), BACKUP_DIR=self.backups.as_posix(), FAILURE=failure))

    def test_confirmed_backup_removed(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.other.read_bytes(), b'other data')

    def test_parent_escape_rejected(self):
        result = self.invoke('../other.tar.gz\ny\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.other.read_bytes(), b'other data')
        self.assertFalse((self.work / 'remove-calls').exists())

    def test_cancel_invalid_and_eof_do_not_delete(self):
        for inputs in ['etc_20260929.tar.gz\nn\n', 'etc_20260929.tar.gz\ninvalid\n', 'etc_20260929.tar.gz\n', '']:
            with self.subTest(inputs=inputs):
                self.backup.write_bytes(b'owned backup')
                self.invoke(inputs)
                self.assertTrue(self.backup.exists())
        self.assertFalse((self.work / 'remove-calls').exists())

    def test_non_archive_is_not_deleted(self):
        path = self.backups / 'business.txt'
        path.write_bytes(b'business')
        self.assertNotEqual(self.invoke('business.txt\ny\n').returncode, 0)
        self.assertEqual(path.read_bytes(), b'business')

    def test_delete_error_is_returned(self):
        result = self.invoke(failure='remove')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('备份删除成功', result.stdout.decode())
        self.assertTrue(self.backup.exists())

    def test_replacement_during_confirmation_is_preserved(self):
        result = self.invoke(failure='replace')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.backup.read_bytes(), b'replacement')
        self.assertFalse((self.work / 'remove-calls').exists())

    def test_missing_and_directory_are_refused(self):
        (self.backups / 'directory.tar.gz').mkdir()
        for name in ['missing.tar.gz', 'directory.tar.gz']:
            self.assertNotEqual(self.invoke(name + '\ny\n').returncode, 0)

    @unittest.skipIf(os.name == 'nt', 'POSIX directory permissions')
    def test_shared_writable_root_is_refused(self):
        self.backups.chmod(0o777)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertTrue(self.backup.exists())

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink fixture')
    def test_symlink_and_linked_backup_root_are_refused(self):
        link = self.backups / 'linked.tar.gz'
        link.symlink_to(self.other)
        self.assertNotEqual(self.invoke('linked.tar.gz\ny\n').returncode, 0)
        self.assertTrue(link.is_symlink())
        original = self.backups
        self.backups = self.work / 'linked-root'
        self.backups.symlink_to(original, target_is_directory=True)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertTrue(self.backup.exists())

    @unittest.skipIf(os.name == 'nt', 'POSIX ownership and hardlink fixture')
    def test_hardlinked_archive_is_refused(self):
        os.link(self.backup, self.work / 'backup-link')
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertTrue(self.backup.exists())


if __name__ == '__main__':
    unittest.main()
