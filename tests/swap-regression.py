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


class Swap(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='swap.')
        self.work = Path(self.temp.name)
        for name in ['etc', 'managed']:
            (self.work / name).mkdir()
        (self.work / 'etc/fstab').write_bytes(('# keep this\nUUID=other none swap sw 0 0\n'+(self.work/'swapfile').as_posix()+' none swap sw 0 0\n').encode())
        (self.work / 'swapfile').write_bytes(b'original-swap')
        (self.work / 'active').touch()
        self.shell('stat -c "%d:%i" "$WORK/swapfile" > "$DAIMON_ROOT_DIR/.swapfile-managed"')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, action, failure=''):
        names = ['daimon_swap_is_active', 'daimon_swap_is_managed', 'add_swap', 'delete_swap']
        for name in ['daimon_swap_transaction']:
            if re.search(r'(?m)^' + name + r'\(\)', SOURCE):
                names.append(name)
        body = '\n'.join(function(n) for n in names)
        for before, after in [('/swapfile', self.work/'swapfile'), ('/etc/fstab', self.work/'etc/fstab'),
                              ('/etc/.daimon-swap', self.work/'etc/.daimon-swap'),
                              ('/etc/local.d', self.work/'etc/local.d'), ('/etc/alpine-release', self.work/'etc/alpine-release')]:
            body = body.replace(before, after.as_posix())
        body += '''
root_use() { :; }
daimon_swap_is_active() { [ -f "$WORK/active" ]; }
swapon() {
    if [ "$FAILURE" = activation ] && [ ! -f "$WORK/activation-failed" ]; then touch "$WORK/activation-failed"; return 1; fi
    touch "$WORK/active"
    if [ "$FAILURE" = signal ] && [ ! -f "$WORK/activation-failed" ]; then touch "$WORK/activation-failed"; kill -TERM "$BASHPID"; fi
}
swapoff() { [ "$FAILURE" != swapoff ] || return 1; command rm -f "$WORK/active"; }
fallocate() { printf new-swap > "${@: -1}"; }
mkswap() { :; }
sed() { [ "$FAILURE" != fstab ] || return 1; command sed "$@"; }
mv() {
    if [ "$FAILURE" = fstab-commit ] && [ "${@: -1}" = "$WORK/etc/fstab" ]; then return 1; fi
    if [ "$FAILURE" = marker ] && [ "${@: -1}" = "$DAIMON_ROOT_DIR/.swapfile-managed" ]; then return 1; fi
    command mv "$@" || return
    if [ "$FAILURE" = signal-old-move ] && [[ "${@: -1}" == *swapfile.daimon.old.* ]]; then kill -TERM "$BASHPID"; fi
    if [ "$FAILURE" = signal-new-move ] && [ "${@: -1}" = "$WORK/swapfile" ] && [ ! -f "$WORK/move-signaled" ]; then touch "$WORK/move-signaled"; kill -TERM "$BASHPID"; fi
    if [ "$FAILURE" = signal-fstab-move ] && [ "${@: -1}" = "$WORK/etc/fstab" ] && [ ! -f "$WORK/move-signaled" ]; then touch "$WORK/move-signaled"; kill -TERM "$BASHPID"; fi
}
stat() {
    [ "$FAILURE" != stat ] || return 1
    command stat "$@"
}
'''
        if os.name == 'nt':
            body += 'flock() { :; }\n'
        body += action + '\n'
        script = self.work/'test.sh'
        script.write_bytes(body.encode())
        result = subprocess.run([BASH, '--noprofile', '--norc', script.as_posix()], capture_output=True, timeout=15,
                                env=dict(os.environ, WORK=self.work.as_posix(), DAIMON_ROOT_DIR=(self.work/'managed').as_posix(),
                                         FAILURE=failure, TMPDIR=self.work.as_posix()))
        return result

    def snapshot(self):
        return {name: (self.work/name).read_bytes() if (self.work/name).exists() else None
                for name in ['swapfile', 'active', 'etc/fstab', 'managed/.swapfile-managed']}

    def test_resize_fstab_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'fstab')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_delete_fstab_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('delete_swap', 'fstab')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_resize_fstab_commit_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'fstab-commit')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_delete_fstab_commit_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('delete_swap', 'fstab-commit')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_marker_commit_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'marker')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_activation_failure_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'activation')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_signal_during_activation_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'signal')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_first_creation_fstab_failure_leaves_no_active_swap(self):
        for name in ['swapfile', 'active', 'managed/.swapfile-managed']:
            (self.work/name).unlink()
        before = self.snapshot()
        result = self.shell('add_swap 32', 'fstab-commit')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_signal_after_old_file_rename_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'signal-old-move')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_signal_after_new_file_rename_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'signal-new-move')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_signal_after_fstab_rename_restores_everything(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'signal-fstab-move')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_marker_directory_is_rejected_before_activation(self):
        marker = self.work/'managed/.swapfile-managed'
        marker.unlink(); marker.mkdir()
        (self.work/'swapfile').unlink(); (self.work/'active').unlink()
        result = self.shell('add_swap 32')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work/'swapfile').exists())
        self.assertFalse((self.work/'active').exists())

    def test_swapoff_failure_keeps_original(self):
        before = self.snapshot()
        result = self.shell('add_swap 32', 'swapoff')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_delete_swapoff_failure_keeps_original(self):
        before = self.snapshot()
        result = self.shell('delete_swap', 'swapoff')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_sizes_preserve_everything(self):
        for size in ['0', '-1', 'abc', '1.5', '999999999999999999999999']:
            before = self.snapshot()
            self.assertNotEqual(self.shell('add_swap '+size).returncode, 0)
            self.assertEqual(self.snapshot(), before)

    def test_resize_success_keeps_other_swap_entries(self):
        result = self.shell('add_swap 32')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual((self.work/'swapfile').read_bytes(), b'new-swap')
        self.assertTrue((self.work/'active').exists())
        self.assertIn(b'UUID=other none swap sw 0 0', (self.work/'etc/fstab').read_bytes())
        self.assertEqual(self.shell('daimon_swap_is_managed').returncode, 0)

    def test_delete_success_preserves_other_swap_entries(self):
        result = self.shell('delete_swap')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse((self.work/'swapfile').exists())
        self.assertFalse((self.work/'active').exists())
        self.assertFalse((self.work/'managed/.swapfile-managed').exists())
        self.assertIn(b'UUID=other none swap sw 0 0', (self.work/'etc/fstab').read_bytes())


if __name__ == '__main__':
    unittest.main()
