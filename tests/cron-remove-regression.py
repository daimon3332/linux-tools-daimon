import os
import re
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')


def function(name):
    start = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[start.start():SOURCE.index('\n}\n', start.end()) + 2]


@unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'requires native root filesystem and process inspection')
class Removal(unittest.TestCase):
    def invoke(self, failure='', linked=False, running=False):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            target = work / 'task.sh'
            target.write_text('sleep 60\n')
            target.chmod(0o700)
            if linked:
                target.rename(work / 'original')
                target.symlink_to(work / 'original')
            cron = work / 'cron'
            keep = f'0 2 * * * echo {target}\n0 3 * * * {target}.other\n'
            initial = keep + f'0 1 * * * /bin/bash {target}\n'
            cron.write_text(initial)
            names = ['crontab_sync_remove_one', 'server_retire_remove_script', 'server_retire_script_guard',
                     'server_retire_remove_cron_path', 'server_retire_filter_cron', 'rsync_cron_read']
            body = '\n'.join(function(n) for n in names) + r'''
root_use() { :; }
server_retire_sync_dirs() { echo "$WORK"; }
server_retire_update_dirs() { :; }
crontab_sync_runner_file() { echo "$WORK/runner.sh"; }
DAIMON_ROOT_DIR="$WORK"
DAIMON_SCRIPT_DIR="$WORK"
crontab() {
    if [ "$1" = -l ]; then
        [ "$FAILURE" != read ] || { echo 'permission denied' >&2; return 1; }
        cat "$WORK/cron"
    else
        [ "$FAILURE" != write ] || return 1
        cat > "$WORK/cron.next" && mv "$WORK/cron.next" "$WORK/cron"
    fi
}
crontab_sync_remove_one "$WORK/task.sh"
'''
            entry = work / 'entry.sh'
            entry.write_text(body)
            process = subprocess.Popen(['/bin/bash', str(target)], start_new_session=True) if running else None
            try:
                result = subprocess.run(['/bin/bash', str(entry)], capture_output=True, timeout=15,
                                        env=dict(os.environ, WORK=str(work), FAILURE=failure))
                return result.returncode, target.exists(), cron.read_text(), keep, initial
            finally:
                if process:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)

    def test_read_failure_preserves_script_and_cron(self):
        rc, exists, cron, _, initial = self.invoke('read')
        self.assertNotEqual(rc, 0)
        self.assertTrue(exists)
        self.assertEqual(cron, initial)

    def test_write_failure_preserves_script(self):
        rc, exists, cron, _, initial = self.invoke('write')
        self.assertNotEqual(rc, 0)
        self.assertTrue(exists)
        self.assertEqual(cron, initial)

    def test_exact_command_only(self):
        rc, exists, cron, keep, _ = self.invoke()
        self.assertEqual(rc, 0)
        self.assertFalse(exists)
        self.assertEqual(cron, keep)

    def test_symlink_refused(self):
        rc, exists, cron, _, initial = self.invoke(linked=True)
        self.assertNotEqual(rc, 0)
        self.assertTrue(exists)
        self.assertEqual(cron, initial)

    def test_running_script_refused(self):
        rc, exists, cron, _, initial = self.invoke(running=True)
        self.assertNotEqual(rc, 0)
        self.assertTrue(exists)
        self.assertEqual(cron, initial)


if __name__ == '__main__':
    unittest.main()
