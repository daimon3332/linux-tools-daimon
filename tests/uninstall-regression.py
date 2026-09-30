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
OWNED = b'#!/bin/bash\nDAIMON_NAME="linux-tools-daimon"\n'


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([{(])\n', SOURCE)
    closing = '}' if match[1] == '{' else ')'
    return SOURCE[match.start():SOURCE.index('\n' + closing, match.end()) + 2]


class Uninstall(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='uninstall.')
        self.work = Path(self.temp.name)
        for name in ['local-bin', 'system-bin', 'managed', 'managed/backup-sh']:
            (self.work / name).mkdir()
        for name in ['local-bin/d', 'managed/linux-toolbox.sh', 'managed/daimon.sh']:
            (self.work / name).write_bytes(OWNED)
        self.cron = self.work / 'cron'
        self.cron.write_bytes(b'0 3 * * * /srv/kejilion.sh-job\n0 4 * * * /root/linux-daimon/backup-sh/job.sh\n')
        self.cron_before = self.cron.read_bytes()
        (self.work / 'managed/backup-sh/job.sh').write_bytes(b'preserve-backup')

    def tearDown(self):
        self.temp.cleanup()

    def menu(self, inputs='20\nY\n0\n', failure=''):
        names = ['linux_Settings']
        if 'daimon_uninstall_toolbox()' in SOURCE:
            names.append('daimon_uninstall_toolbox')
        body = '\n'.join(function(n) for n in names)
        body = body.replace('/usr/local/bin', (self.work / 'local-bin').as_posix())
        body = body.replace('/usr/bin', (self.work / 'system-bin').as_posix())
        body += r'''
root_use() { return 1; }; clear() { :; }; send_stats() { :; }; break_end() { :; }
id() { if [ "$1" = -u ]; then if [ "$FAILURE" = nonroot ]; then echo 1000; else echo 0; fi; else command id "$@"; fi; }
crontab() {
    echo "$*" >> "$WORK/cron-calls"
    if [ "$1" = -l ]; then [ "$FAILURE" != cron-read ] || return 1; cat "$WORK/cron"; else cat > "$WORK/cron.new"; mv "$WORK/cron.new" "$WORK/cron"; fi
}
rm() {
    if [ "$FAILURE" = remove ]; then return 1; fi
    command rm "$@"
}
linux_Settings
'''
        path = self.work / 'entry.sh'; path.write_bytes(body.encode())
        return subprocess.run([BASH, '--noprofile', '--norc', path.as_posix()], input=inputs.encode(),
                              capture_output=True, timeout=15, env=dict(os.environ, WORK=self.work.as_posix(), FAILURE=failure,
                              DAIMON_LOCAL_SCRIPT=(self.work / 'managed/linux-toolbox.sh').as_posix(),
                              DAIMON_OLD_LOCAL_SCRIPT=(self.work / 'managed/daimon.sh').as_posix()))

    def test_uninstall_preserves_all_cron_and_auxiliary_scripts(self):
        result = self.menu()
        self.assertIn('脚本已卸载', result.stdout.decode())
        self.assertEqual(self.cron.read_bytes(), self.cron_before)
        self.assertEqual((self.work / 'managed/backup-sh/job.sh').read_bytes(), b'preserve-backup')
        for name in ['local-bin/d', 'managed/linux-toolbox.sh', 'managed/daimon.sh']:
            self.assertFalse((self.work / name).exists())

    def test_cron_read_failure_cannot_clear_crontab(self):
        self.menu(failure='cron-read')
        self.assertEqual(self.cron.read_bytes(), self.cron_before)

    def test_delete_failure_cannot_report_success(self):
        result = self.menu(failure='remove')
        self.assertNotIn('脚本已卸载', result.stdout.decode())
        self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)

    def test_unrelated_command_is_preserved_before_any_delete(self):
        path = self.work / 'system-bin/d'; path.write_bytes(b'unrelated command')
        result = self.menu()
        self.assertNotIn('脚本已卸载', result.stdout.decode())
        self.assertEqual(path.read_bytes(), b'unrelated command')
        self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)

    def test_unknown_managed_file_is_preserved(self):
        path = self.work / 'managed/daimon.sh'; path.write_bytes(b'user data')
        self.menu()
        self.assertEqual(path.read_bytes(), b'user data')
        self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)

    def test_cancel_and_eof_make_no_changes(self):
        for inputs in ['20\nN\n0\n', '20\n', '0\n']:
            self.menu(inputs)
            self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)
            self.assertEqual(self.cron.read_bytes(), self.cron_before)

    def test_repeat_is_safe(self):
        self.menu()
        result = self.menu()
        self.assertIn('脚本已卸载', result.stdout.decode())
        self.assertEqual(self.cron.read_bytes(), self.cron_before)

    def test_directory_is_not_deleted(self):
        path = self.work / 'managed/daimon.sh'; path.unlink(); path.mkdir()
        result = self.menu()
        self.assertNotIn('脚本已卸载', result.stdout.decode())
        self.assertTrue(path.is_dir())
        self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)

    def test_nonroot_is_refused_before_delete(self):
        result = self.menu(failure='nonroot')
        self.assertNotIn('脚本已卸载', result.stdout.decode())
        self.assertEqual((self.work / 'local-bin/d').read_bytes(), OWNED)

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink fixture')
    def test_removes_only_links_resolving_to_toolbox(self):
        for name in ['system-bin/d', 'system-bin/custom', 'local-bin/custom']:
            (self.work / name).symlink_to(self.work / 'local-bin/d')
        other = self.work / 'other'; other.write_bytes(b'other')
        (self.work / 'local-bin/other').symlink_to(other)
        self.menu()
        for name in ['system-bin/d', 'system-bin/custom', 'local-bin/custom']:
            self.assertFalse((self.work / name).is_symlink())
        self.assertTrue((self.work / 'local-bin/other').is_symlink())
        self.assertEqual(other.read_bytes(), b'other')


if __name__ == '__main__':
    unittest.main()
