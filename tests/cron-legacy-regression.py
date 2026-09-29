import os, re, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')
def fn(name):
    m = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[m.start():SOURCE.index('\n}\n', m.end()) + 2]
class Legacy(unittest.TestCase):
    def test_startup_detection_never_modifies_scripts_or_cron(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as d:
            work = Path(d)
            old = work / 'bitwarden.sh'
            old.write_text('#!/bin/bash\nrclone sync Infini-cloud:data dest:data\n')
            custom = work / 'custom.sh'
            custom.write_text('echo Infini-cloud\n')
            body = fn('crontab_sync_reconcile_legacy') + r"""
crontab_sync_backup_dir() { echo "$WORK"; }
crontab_sync_log_dir() { echo "$WORK"; }
crontab_sync_legacy_script_file_by_id() { echo "$WORK/$1.sh"; }
crontab_sync_script_file_by_id() { echo "$WORK/new-$1.sh"; }
crontab_sync_remote_ready() { echo remote >> "$WORK/trace"; return 1; }
crontab() { echo cron >> "$WORK/trace"; return 1; }
crontab_sync_reconcile_legacy
"""
            p = subprocess.run([BASH, '-c', body], capture_output=True, env=dict(os.environ, WORK=work.as_posix()), timeout=10)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse((work/'trace').exists())
            self.assertEqual(custom.read_text(), 'echo Infini-cloud\n')
            self.assertIn('Infini-cloud:data', old.read_text())
@unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'Native root required')
class Migration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp')
        self.work = Path(self.tmp.name)
        (self.work/'locks').mkdir()
        self.file = self.work/'bitwarden.sh'
        self.original = b'#!/bin/bash\n# preserve direction\nrclone sync "Infini-cloud:data" "OneDrive:data"\n'
        self.file.write_bytes(self.original)
    def tearDown(self):
        self.tmp.cleanup()
    def run_migration(self, extra=''):
        body = fn('crontab_sync_migrate_legacy_file') + r"""
crontab_sync_legacy_script_file_by_id() { echo "$WORK/$1.sh"; }
crontab_sync_remote_ready() { return "${REMOTE_RC:-0}"; }
DAIMON_LOCK_DIR="$WORK/locks"
""" + extra + '\ncrontab_sync_migrate_legacy_file bitwarden\n'
        return subprocess.run([BASH, '-c', body], capture_output=True, env=dict(os.environ, WORK=str(self.work)), timeout=15)
    def test_literal_only_path_direction_and_custom_preserved(self):
        custom = self.work/'custom.sh';custom.write_bytes(self.original)
        p = self.run_migration()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.file.read_bytes(), self.original.replace(b'Infini-cloud:', b'kissska1:'))
        self.assertEqual(custom.read_bytes(), self.original)
        self.assertFalse(list(self.work.glob('.legacy-migrate.*')))
    def test_remote_failure_preserves_file(self):
        self.assertNotEqual(self.run_migration('REMOTE_RC=1').returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original)
    def test_invalid_syntax_preserves_file(self):
        self.file.write_bytes(self.original+b'if broken\n')
        self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original+b'if broken\n')
        self.assertFalse(list(self.work.glob('.legacy-migrate.*')))
    def test_hardlink_preserved(self):
        os.link(self.file, self.work/'sentinel')
        self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original)
    def test_symlink_preserved(self):
        self.file.rename(self.work/'sentinel');self.file.symlink_to(self.work/'sentinel')
        self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertTrue(self.file.is_symlink())
    def test_untrusted_permissions_preserved(self):
        self.file.chmod(0o666)
        self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original)
    def test_native_lock_conflict(self):
        import fcntl
        with (self.work/'locks/daimon-backup-scripts.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original)
    def test_open_script_preserved(self):
        with self.file.open('rb'):
            self.assertNotEqual(self.run_migration().returncode, 0)
        self.assertEqual(self.file.read_bytes(), self.original)

if __name__ == '__main__':
    (ROOT / '.tmp').mkdir(exist_ok=True)
    unittest.main()
