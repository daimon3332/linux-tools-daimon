import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    match = re.search(r'(?m)^([ \t]*)' + name + r'\(\) \{\n', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    end = SOURCE.index('\n' + match[1] + '}', match.end())
    return SOURCE[match.start():end + len(match[1]) + 2]


class RsyncTest(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='rsync.')
        self.work = Path(self.temp.name)
        self.tasks = self.work / '.rsync_tasks'
        self.tasks.write_text('backup|/local/data|root@192.0.2.1|/remote/backup|22|-avz --delete|password|fixture\n', encoding='utf-8')
        self.cron = self.work / 'cron'
        self.cron.write_text('', encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, action, input='', extra=''):
        names = ['validate_config_name', 'validate_tcp_port', 'run_task', 'schedule_task',
                 'delete_task_schedule', 'delete_task', 'add_task', 'view_tasks', 'list_tasks']
        names += re.findall(r'(?m)^(rsync_[a-z_]+)\(\) \{', SOURCE)
        definitions = '\n'.join(function(name) for name in dict.fromkeys(names))
        setup = '''
send_stats() { :; }
install() { return 0; }
shuf() { echo 7; }
sshpass() { printf '%s\\n' "$@" > "$HOME/args"; return "${SYNC_RC:-0}"; }
rsync() { printf '%s\\n' "$@" > "$HOME/args"; return "${SYNC_RC:-0}"; }
crontab() {
    if [ "$1" = -l ]; then
        [ "${CRON_READ_FAIL:-0}" = 0 ] || { echo 'permission denied' >&2; return 1; }
        cat "$HOME/cron"
    else
        [ "${CRON_WRITE_FAIL:-0}" = 0 ] || return 1
        cat > "$HOME/cron"
    fi
}
CONFIG_FILE="$HOME/.rsync_tasks"
KEY_DIR="$HOME/.ssh/ssh_manager_keys"
'''
        env = dict(os.environ, HOME=self.work.as_posix(), LC_ALL='C.UTF-8')
        script = definitions + '\n' + setup + extra + '\n' + action + " <<'RSYNC_TEST_INPUT'\n" + input + '\nRSYNC_TEST_INPUT\n'
        syntax = subprocess.run([BASH, '-n'], input=script.encode('utf-8'), capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode('utf-8'))
        result = subprocess.run([BASH, '--noprofile', '--norc'], input=script.encode('utf-8'),
                                capture_output=True, env=env, timeout=10)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def test_push_and_pull(self):
        for direction, source, target in [('push', '/local/data', 'root@192.0.2.1:/remote/backup'),
                                           ('pull', 'root@192.0.2.1:/remote/backup', '/local/data')]:
            with self.subTest(direction=direction):
                result = self.shell('run_task ' + direction + ' 1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.work / 'args').read_text().splitlines()[-2:], [source, target])

    def test_failure_propagates(self):
        self.assertNotEqual(self.shell('run_task push 1', extra='SYNC_RC=23').returncode, 0)

    def test_invalid_and_missing_task_numbers(self):
        for number in ['0', '-1', '01', '1;d', '1,2', '9999999999999999999999999', '2']:
            with self.subTest(number=number):
                result = self.shell('run_task push ' + shlex.quote(number))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.work / 'args').exists())

    def test_cron_deletes_only_exact_number(self):
        lines = ['0 * * * * k rsync_run ' + str(n) for n in [1, 10, 11]]
        self.cron.write_text('\n'.join(lines) + '\n')
        result = self.shell('delete_task_schedule', '1\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cron.read_text().splitlines(), lines[1:])

    def test_schedule_uses_current_shortcut_and_exact_duplicate(self):
        self.cron.write_text('0 * * * * k rsync_run 10\n')
        result = self.shell('schedule_task', '1\n1\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/usr/local/bin/d rsync_run 1\n', self.cron.read_text())

    def test_cron_errors_preserve_existing_jobs(self):
        original = '0 * * * * unrelated-job\n'
        for flag in ['CRON_READ_FAIL', 'CRON_WRITE_FAIL']:
            for action, input in [('schedule_task', '1\n1\n'), ('delete_task_schedule', '1\n')]:
                with self.subTest(flag=flag, action=action):
                    self.cron.write_text(original)
                    result = self.shell(action, input, flag + '=1')
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.cron.read_text(), original)

    def test_invalid_delete_preserves_tasks(self):
        original = self.tasks.read_text()
        for number in ['0', '1,2', '1;d', '999']:
            result = self.shell('delete_task', number + '\n')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(self.tasks.read_text(), original)

    def test_task_deletion_reindexes_only_owned_schedules(self):
        task = self.tasks.read_text()
        self.tasks.write_text(task + task.replace('backup|', 'second|'))
        self.cron.write_text('0 * * * * /usr/local/bin/d rsync_run 1\n'
                             '1 * * * * /usr/local/bin/d rsync_run 2\n'
                             '2 * * * * echo k rsync_run 2\n')
        result = self.shell('delete_task', '1\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tasks.read_text(), task.replace('backup|', 'second|'))
        self.assertEqual(self.cron.read_text(), '1 * * * * /usr/local/bin/d rsync_run 1\n'
                                               '2 * * * * echo k rsync_run 2\n')

    def test_cron_failure_does_not_delete_task(self):
        original = self.tasks.read_text()
        result = self.shell('delete_task', '1\n', 'CRON_WRITE_FAIL=1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.tasks.read_text(), original)

    def test_new_task_rejects_path_traversal_before_auth(self):
        result = self.shell('add_task', '../outside\n/local\n/remote\n',
                            'kj_ssh_parse_remote() { echo AUTH_REACHED; exit 91; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('AUTH_REACHED', result.stdout)

    def test_new_task_and_duplicate(self):
        setup = '''
kj_ssh_parse_remote() { KJ_SSH_REMOTE="$1"; }
kj_ssh_read_port() { KJ_SSH_PORT=22; }
kj_ssh_read_auth() { KJ_SSH_AUTH_METHOD=password; KJ_SSH_AUTH_SECRET=fixture; }
'''
        answers = 'new-task\n/local/new\n/remote/new\nroot@192.0.2.1\n1\n'
        result = self.shell('add_task', answers, setup)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('new-task|/local/new|root@192.0.2.1|/remote/new|22|-avz|password|fixture', self.tasks.read_text())
        original = self.tasks.read_text()
        self.assertNotEqual(self.shell('add_task', answers, setup).returncode, 0)
        self.assertEqual(self.tasks.read_text(), original)

    def test_task_replacement_failure_restores_cron(self):
        self.cron.write_text('0 * * * * /usr/local/bin/d rsync_run 1\n')
        original, cron = self.tasks.read_text(), self.cron.read_text()
        result = self.shell('delete_task', '1\n', 'mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.tasks.read_text(), original)
        self.assertEqual(self.cron.read_text(), cron)

    def test_eof_never_modifies_tasks_or_cron(self):
        for action in ['add_task', 'delete_task', 'schedule_task', 'delete_task_schedule']:
            with self.subTest(action=action):
                before = self.tasks.read_text(), self.cron.read_text()
                self.assertNotEqual(self.shell(action).returncode, 0)
                self.assertEqual((self.tasks.read_text(), self.cron.read_text()), before)


if __name__ == '__main__':
    unittest.main()
