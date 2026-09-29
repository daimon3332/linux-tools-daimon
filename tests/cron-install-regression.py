import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')


def function(name):
    start = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[start.start():SOURCE.index('\n}\n', start.end()) + 2]


@unittest.skipUnless(os.name == 'posix', 'requires native Bash and Python cron parser')
class InstallPreflight(unittest.TestCase):
    def invoke(self, failure='', compound=False, preexisting=False):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            target = str(work / 'task.sh')
            keep = f'# keep\n0 1 * * * echo {target}\n0 2 * * * {target}.other\n'
            existing = f'0 3 * * * /bin/bash {target}' + (' && /srv/business' if compound else '') + '\n'
            initial = keep + existing
            (work / 'cron').write_text(initial)
            if preexisting:
                (work / 'task.sh').write_text('original task\n')
                (work / 'runner.sh').write_text('original runner\n')
            body = '\n'.join(function(n) for n in ['crontab_sync_install_one', 'rsync_cron_read', 'server_retire_filter_cron']) + r'''
root_use() { :; }
rclone() { :; }
check_crontab_installed() { [ "$FAILURE" != dependency ]; }
crontab_sync_runner_file() { printf '%s\n' "$WORK/runner.sh"; }
crontab_sync_write_script() { [ "$FAILURE" != generate ] || return 1; echo changed > "$2"; chmod 700 "$2"; }
crontab_sync_write_runner() { [ "$FAILURE" != runner ] || return 1; echo changed > "$1"; chmod 700 "$1"; }
server_retire_script_guard() {
    if [ -e "$1" ]; then stat -c '%d:%i:%s:%Y:%Z' -- "$1"; else echo absent; fi
}
export DAIMON_LOCK_DIR="$WORK/run"
crontab() {
    if [ "$1" = -l ]; then
        [ "$FAILURE" != read ] || { echo 'permission denied' >&2; return 1; }
        cat "$WORK/cron"
    else
        [ "$FAILURE" != write ] || return 1
        if [ "$FAILURE" = bad_rollback ] && [ -e "$WORK/written" ]; then return 0; fi
        cat > "$WORK/cron.next" && mv "$WORK/cron.next" "$WORK/cron"
        if [[ "$FAILURE" = after_write || "$FAILURE" = bad_rollback ]] && [ ! -e "$WORK/written" ]; then
            touch "$WORK/written"; return 1
        fi
    fi
}
crontab_sync_install_one imagebed "$WORK/task.sh" "0 4 * * * /bin/bash $WORK/task.sh"
'''
            entry = work / 'entry.sh'
            entry.write_text(body)
            result = subprocess.run(['/bin/bash', str(entry)], capture_output=True, timeout=15,
                                    env=dict(os.environ, WORK=str(work), FAILURE=failure))
            result.task_contents = (work / 'task.sh').read_text() if (work / 'task.sh').exists() else None
            result.runner_contents = (work / 'runner.sh').read_text() if (work / 'runner.sh').exists() else None
            result.pending = list(work.glob('.cron-install.*'))
            return result, (work / 'task.sh').exists(), (work / 'cron').read_text(), initial, keep, target

    def test_read_failure_before_script_mutation(self):
        result, changed, cron, initial, _, _ = self.invoke('read')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(changed)
        self.assertEqual(cron, initial)
        self.assertIsNone(result.runner_contents)
        self.assertEqual(result.pending, [])

    def test_write_failure_preserves_existing_files(self):
        result, _, cron, initial, _, _ = self.invoke('write', preexisting=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.task_contents, 'original task\n')
        self.assertEqual(result.runner_contents, 'original runner\n')
        self.assertEqual(cron, initial)
        self.assertEqual(result.pending, [])

    def test_staging_failure_preserves_existing_files(self):
        for failure in ('generate', 'runner'):
            result, _, cron, initial, _, _ = self.invoke(failure, preexisting=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.task_contents, 'original task\n')
            self.assertEqual(result.runner_contents, 'original runner\n')
            self.assertEqual(cron, initial)
            self.assertEqual(result.pending, [])

    def test_failed_command_after_cron_commit_restores_everything(self):
        result, _, cron, initial, _, _ = self.invoke('after_write', preexisting=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.task_contents, 'original task\n')
        self.assertEqual(result.runner_contents, 'original runner\n')
        self.assertEqual(cron, initial)
        self.assertEqual(result.pending, [])

    def test_false_successful_cron_rollback_keeps_recovery_files(self):
        result, _, cron, initial, _, _ = self.invoke('bad_rollback', preexisting=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(cron, initial)
        self.assertEqual(result.task_contents, 'changed\n')
        self.assertEqual(result.runner_contents, 'changed\n')
        self.assertEqual(len(result.pending), 1)

    def test_dependency_failure_before_script_mutation(self):
        result, changed, cron, initial, _, _ = self.invoke('dependency')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(changed)
        self.assertEqual(cron, initial)

    def test_replace_exact_command_only(self):
        result, changed, cron, _, keep, target = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(changed)
        self.assertEqual(cron, keep + f'0 4 * * * /bin/bash {target}\n')

    def test_ambiguous_reference_before_script_mutation(self):
        result, changed, cron, initial, _, _ = self.invoke(compound=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(changed)
        self.assertEqual(cron, initial)

    def test_write_failure_removes_new_script(self):
        result, changed, cron, initial, _, _ = self.invoke('write')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(changed)
        self.assertEqual(cron, initial)


if __name__ == '__main__':
    unittest.main()
