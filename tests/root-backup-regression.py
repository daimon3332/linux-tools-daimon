#!/usr/bin/env python3
"""Exercise the generated root task without stopping production containers."""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import json
import time

SOURCE = pathlib.Path(os.environ.get('DAIMON_TEST_SOURCE', pathlib.Path(__file__).resolve().parents[1] / 'linux-toolbox.sh')).read_text(encoding='utf-8')


def function(name):
    match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
    if not match:
        raise AssertionError('Missing function: ' + name)
    return match.group()


class Recovery(unittest.TestCase):
    def test_application_first_does_not_block_database_start(self):
        script = r'''
set -o pipefail
TASK_KIND=root
OWNS_STATE=1
STATE_FILE=/dev/fd/3
SECONDS=0
app_running=false db_running=false
container_state() {
 case "$1" in
 app) if [ "$app_running" = false ]; then echo 'false none'; elif [ "$db_running" = false ]; then echo 'true starting'; else echo 'true healthy'; fi ;;
 db) echo "$db_running none" ;;
 esac
}
timeout() {
 case "$*" in
 '60s docker start app') app_running=true; echo START_APP ;;
 '60s docker start db') db_running=true; echo START_DB ;;
 *) return 1 ;;
 esac
}
sleep() { SECONDS=$((SECONDS+60)); }
rm() { :; }
'''
        script += function('recover_writers') + '\nrecover_writers 3<<<$\'app\\ndb\'\nrc=$?\ncat "$LOG_FILE"\nexit "$rc"\n'
        binary = os.environ.get('BASH_BIN', 'bash')
        root = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root, prefix='root-recovery.') as work:
            env = dict(os.environ, LOG_FILE=pathlib.Path(work, 'test.log').as_posix())
            result = subprocess.run([binary, '-s'], input=script, text=True, encoding='utf-8', capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux filesystem/log integration tests')
class LogPolicy(unittest.TestCase):
    def setUp(self):
        root = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        root.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=root, prefix='root-policy.')
        self.work = pathlib.Path(self.directory.name)
        self.runs = self.work / 'runs'
        self.runs.mkdir()
        self.cache = self.work / 'status.tsv'
        self.active = self.runs / '20260920-010101-123-root.log'
        self.env = dict(os.environ, DAIMON_LOG_FILE_BYTES='8192', DAIMON_LOG_TOTAL_BYTES='32768',
                        DAIMON_LOG_MIN_FREE_BYTES='1', DAIMON_LOG_MIN_FREE_INODES='1')

    def tearDown(self):
        self.directory.cleanup()

    def policy(self, mode='prepare', env=None):
        script = function('log_policy') + '\nlog_policy "$@"\n'
        return subprocess.run(['bash', '-c', script, 'policy', mode, str(self.runs), str(self.cache), str(self.active)],
                              env=env or self.env, capture_output=True, text=True)

    def test_space_failure_prevents_log_creation(self):
        result = self.policy(env=dict(self.env, DAIMON_LOG_MIN_FREE_BYTES=str(2**62)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.active.exists())

    def test_inode_failure_prevents_log_creation(self):
        result = self.policy(env=dict(self.env, DAIMON_LOG_MIN_FREE_INODES=str(2**62)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.active.exists())

    def test_retention_removes_only_owned_inactive_logs(self):
        stale = self.runs / '20200101-010101-456-root.log'
        stale.write_bytes(b'x' * 40000)
        unrelated = self.runs / 'business.log'
        unrelated.write_text('keep')
        result = self.policy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        self.assertEqual(unrelated.read_text(), 'keep')

    def test_active_log_is_never_removed_for_budget(self):
        import fcntl
        protected = self.runs / '20260920-010101-789-root.log'
        protected.write_bytes(b'x' * 40000)
        with protected.open('rb') as fd:
            fcntl.flock(fd, fcntl.LOCK_EX)
            result = self.policy()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(protected.exists())

    def test_symlink_is_rejected(self):
        protected = self.work / 'protected'
        protected.write_text('keep')
        self.active.symlink_to(protected)
        self.assertNotEqual(self.policy().returncode, 0)
        self.assertEqual(protected.read_text(), 'keep')

    def test_monitor_bounds_current_log_without_orphans(self):
        self.assertEqual(self.policy().returncode, 0)
        script = function('log_policy') + '\nlog_policy "$@"\n'
        proc = subprocess.Popen(['bash', '-c', script, 'policy', 'monitor', str(self.runs), str(self.cache),
                                 str(self.active), str(os.getpid())], env=self.env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        try:
            with self.active.open('ab') as out:
                out.write(b'content\n' * 3000)
            deadline = time.monotonic() + 5
            while self.active.stat().st_size > 8192 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertLessEqual(self.active.stat().st_size, 8192)
            self.assertIn('LOG_ROTATED', self.active.read_text())
        finally:
            proc.terminate()
            proc.wait(timeout=5)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux disk checks')
class Space(unittest.TestCase):
    def test_root_work_space_failure(self):
        env = dict(os.environ, DAIMON_BACKUP_MIN_FREE_BYTES=str(2**62))
        result = subprocess.run(['bash', '-c', 'WORK_BASE=/tmp STATE_DIR=/tmp LOG_DIR=/tmp\n' +
                                 function('root_space_ok') + '\nroot_space_ok'], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_root_inode_failure(self):
        env = dict(os.environ, DAIMON_BACKUP_MIN_FREE_INODES=str(2**62))
        result = subprocess.run(['bash', '-c', 'WORK_BASE=/tmp STATE_DIR=/tmp LOG_DIR=/tmp\n' +
                                 function('root_space_ok') + '\nroot_space_ok'], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
