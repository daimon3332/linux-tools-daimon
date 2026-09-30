from source import read_source
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = read_source(ROOT)
BASH = os.environ.get('BASH_BIN', '/bin/bash')
TARGET = '/root/linux-daimon/backup-sh/task.sh'
RUNNER = '/root/linux-daimon/backup-sh/.rclone-runner.sh'


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([{(])\n', SOURCE)
    return SOURCE[match.start():SOURCE.index('\n' + ('}' if match[1] == '{' else ')'), match.end()) + 2]


class RetireCron(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='retire-cron.')
        self.work = Path(self.temp.name)
        self.cron = self.work / 'cron'

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, content, failure=''):
        self.cron.write_bytes(content.encode())
        names = ['server_retire_remove_cron_path', 'rsync_cron_read']
        if 'server_retire_filter_cron()' in SOURCE:
            names.append('server_retire_filter_cron')
        body = '\n'.join(function(n) for n in names) + r'''
python3() (set -o pipefail; "$PYTHON_BIN" "$@" | tr -d '\r')
crontab_sync_runner_file() { echo /root/linux-daimon/backup-sh/.rclone-runner.sh; }
crontab() {
    if [ "$1" = -l ]; then
        if [ "$FAILURE" = read ]; then echo 'permission denied' >&2; return 1; fi
        if [ "$FAILURE" = absent ]; then echo 'no crontab for root' >&2; return 1; fi
        if [ "$FAILURE" = concurrent ]; then
            if [ -f "$WORK/read-once" ]; then echo '0 5 * * * /srv/new-job'; return 0; fi
            touch "$WORK/read-once"
        fi
        cat "$WORK/cron"
    else
        echo write >> "$WORK/writes"
        [ "$FAILURE" != write ] || return 1
        cat > "$WORK/cron.next" && mv "$WORK/cron.next" "$WORK/cron"
    fi
}
server_retire_remove_cron_path /root/linux-daimon/backup-sh/task.sh
'''
        path = self.work / 'entry.sh'; path.write_bytes(body.encode())
        return subprocess.run([BASH, '--noprofile', '--norc', path.as_posix()], capture_output=True, timeout=15,
                              env=dict(os.environ, WORK=self.work.as_posix(), FAILURE=failure,
                                       PYTHON_BIN=Path(sys.executable).as_posix(), MSYS2_ARG_CONV_EXCL='*'))

    def test_read_failure_cannot_write(self):
        content = '0 3 * * * /srv/business\n'
        self.assertNotEqual(self.invoke(content, 'read').returncode, 0)
        self.assertEqual(self.cron.read_text(), content)
        self.assertFalse((self.work / 'writes').exists())

    def test_exact_commands_removed_and_mentions_preserved(self):
        keep = '# comment\n\nMAILTO="root"\n0 2 * * * echo ' + TARGET + '\n0 3 * * * ' + TARGET + '.other\n'
        content = keep + '0 4 * * * /bin/bash "' + TARGET + '" >> /var/log/job.log 2>&1\n@reboot ' + TARGET + '\n'
        self.assertEqual(self.invoke(content).returncode, 0)
        self.assertEqual(self.cron.read_text(), keep)

    def test_shanghai_runner_removed(self):
        line = '* * * * * [ "$(TZ=Asia/Shanghai date +\\%H:\\%M)" = "05:45" ] && [ "$(TZ=Asia/Shanghai date +\\%w)" = "0" ] && /bin/bash ' + RUNNER + ' emby ' + TARGET + ' >> /var/log/job.log 2>&1\n'
        self.assertEqual(self.invoke(line + '0 1 * * * /srv/keep\n').returncode, 0)
        self.assertEqual(self.cron.read_text(), '0 1 * * * /srv/keep\n')

    def test_chained_business_command_is_not_removed(self):
        content = '0 3 * * * ' + TARGET + ' && /srv/business\n'
        self.assertNotEqual(self.invoke(content).returncode, 0)
        self.assertEqual(self.cron.read_text(), content)
        self.assertFalse((self.work / 'writes').exists())

    def test_absent_crontab_is_not_created(self):
        self.assertEqual(self.invoke('', 'absent').returncode, 0)
        self.assertFalse((self.work / 'writes').exists())

    def test_unchanged_crontab_is_not_rewritten(self):
        self.assertEqual(self.invoke('0 3 * * * /srv/business\n').returncode, 0)
        self.assertFalse((self.work / 'writes').exists())

    def test_write_failure_returned(self):
        content = '0 3 * * * ' + TARGET + '\n'
        self.assertNotEqual(self.invoke(content, 'write').returncode, 0)
        self.assertEqual(self.cron.read_text(), content)

    def test_concurrent_edit_is_not_overwritten(self):
        self.assertNotEqual(self.invoke('0 3 * * * ' + TARGET + '\n', 'concurrent').returncode, 0)
        self.assertFalse((self.work / 'writes').exists())

    def test_unknown_wrapper_and_shell_expansion_are_refused(self):
        for command in ['env MODE=1 /bin/bash ' + TARGET,
                        'bash -c "' + TARGET + '"',
                        TARGET + '&&(/srv/business)',
                        TARGET + ' "$(/srv/business)"']:
            with self.subTest(command=command):
                content = '0 3 * * * ' + command + '\n'
                self.assertNotEqual(self.invoke(content).returncode, 0)
                self.assertEqual(self.cron.read_text(), content)

    def test_malformed_shell_is_not_rewritten(self):
        content = '0 3 * * * /bin/bash "' + TARGET + '\n'
        self.assertNotEqual(self.invoke(content).returncode, 0)
        self.assertEqual(self.cron.read_text(), content)


if __name__ == '__main__':
    unittest.main()
