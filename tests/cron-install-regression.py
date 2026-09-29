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
    def invoke(self, failure='', compound=False):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            target = str(work / 'task.sh')
            keep = f'# keep\n0 1 * * * echo {target}\n0 2 * * * {target}.other\n'
            existing = f'0 3 * * * /bin/bash {target}' + (' && /srv/business' if compound else '') + '\n'
            initial = keep + existing
            (work / 'cron').write_text(initial)
            body = '\n'.join(function(n) for n in ['crontab_sync_install_one', 'rsync_cron_read', 'server_retire_filter_cron']) + r'''
root_use() { :; }
rclone() { :; }
check_crontab_installed() { [ "$FAILURE" != dependency ]; }
crontab_sync_runner_file() { printf '%s\n' "$WORK/runner.sh"; }
crontab_sync_write_script() { echo changed > "$WORK/task.sh"; }
crontab() {
    if [ "$1" = -l ]; then
        [ "$FAILURE" != read ] || { echo 'permission denied' >&2; return 1; }
        cat "$WORK/cron"
    else
        cat > "$WORK/cron.next" && mv "$WORK/cron.next" "$WORK/cron"
    fi
}
crontab_sync_install_one imagebed "$WORK/task.sh" "0 4 * * * /bin/bash $WORK/task.sh"
'''
            entry = work / 'entry.sh'
            entry.write_text(body)
            result = subprocess.run(['/bin/bash', str(entry)], capture_output=True, timeout=15,
                                    env=dict(os.environ, WORK=str(work), FAILURE=failure))
            return result, (work / 'task.sh').exists(), (work / 'cron').read_text(), initial, keep, target

    def test_read_failure_before_script_mutation(self):
        result, changed, cron, initial, _, _ = self.invoke('read')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(changed)
        self.assertEqual(cron, initial)

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


if __name__ == '__main__':
    unittest.main()
