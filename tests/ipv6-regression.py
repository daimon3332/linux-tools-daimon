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


class IPv6(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='ipv6.')
        self.work = Path(self.temp.name)
        (self.work / 'etc/sysctl.d').mkdir(parents=True)
        (self.work / 'managed').mkdir()
        self.config = self.work / 'etc/sysctl.d/99-daimon-ipv6.conf'
        self.initial = b'# keep comment\nnet.ipv6.conf.all.disable_ipv6 = 0\n'
        self.config.write_bytes(self.initial)
        for name in ['all', 'default', 'lo', 'eth0', 'eth0.42']:
            path = self.work / 'proc/sys/net/ipv6/conf' / name
            path.mkdir(parents=True)
            (path / 'disable_ipv6').write_bytes(b'0\n')

    def tearDown(self):
        self.temp.cleanup()

    def flags(self):
        return {p.parent.name: p.read_bytes() for p in (self.work / 'proc').glob('**/disable_ipv6')}

    def invoke(self, action='disable', failure='', ssh=''):
        names = ['system_disable_ipv6', 'system_enable_ipv6', 'system_ipv6_status', 'daimon_config_commit']
        if 'daimon_ipv6_configure()' in SOURCE:
            names.append('daimon_ipv6_configure')
        body = '\n'.join(function(n) for n in names)
        for path in ['/etc/', '/proc/']:
            body = body.replace(path, self.work.as_posix() + path)
        body += r'''
root_use() { :; }; send_stats() { :; }
daimon_ipv6_network_policy() {
    echo "$1" >> "$WORK/network-calls"
    [ "$FAILURE" != "network-$1" ]
}
sysctl() {
    echo "$*" >> "$WORK/sysctl-calls"
    [ "$FAILURE" != apply ] || return 1
    if [ "$1" = -p ]; then
        value=$(awk '/all.disable_ipv6/ {print $NF}' "$2")
        for f in "$WORK"/proc/sys/net/ipv6/conf/*/disable_ipv6; do printf '%s\n' "$value" > "$f"; done
        if [ "$FAILURE" = partial ]; then return 1; fi
        if [ "$FAILURE" = mismatch ]; then echo 0 > "$WORK/proc/sys/net/ipv6/conf/lo/disable_ipv6"; fi
        if [ "$FAILURE" = signal ]; then kill -TERM "$BASHPID"; fi
    fi
}
ip() { echo "$*" >> "$WORK/ip-calls"; }
mv() {
    [ "$FAILURE" != write ] || return 1
    command mv "$@" || return
    if [ "$FAILURE" = rename-signal ] && [ ! -e "$WORK/signalled" ]; then touch "$WORK/signalled"; kill -TERM "$BASHPID"; fi
}
'''
        if os.name == 'nt':
            body += 'flock() { [ "$FAILURE" != lock ]; }\n'
        elif failure == 'lock':
            body += 'flock() { return 1; }\n'
        body += 'system_' + action + '_ipv6\n'
        script = self.work / 'entry.sh'
        script.write_bytes(body.encode())
        return subprocess.run([BASH, '--noprofile', '--norc', script.as_posix()], capture_output=True, timeout=15,
                              env=dict(os.environ, WORK=self.work.as_posix(), FAILURE=failure,
                                       SSH_CONNECTION=ssh, SSH_CLIENT='', DAIMON_ROOT_DIR=(self.work / 'managed').as_posix()))

    def test_disable_then_enable(self):
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(set(self.flags().values()), {b'1\n'})
        self.assertEqual(self.invoke('enable').returncode, 0)
        self.assertEqual(set(self.flags().values()), {b'0\n'})

    def test_write_failure_does_not_change_runtime(self):
        before = self.flags()
        result = self.invoke(failure='write')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.flags(), before)
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_directory_refused_without_runtime_change(self):
        self.config.unlink(); self.config.mkdir()
        before = self.flags()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.flags(), before)

    def test_apply_failure_cannot_report_success_or_reload_all_sysctl(self):
        result = self.invoke(failure='apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('IPv6 已禁用', result.stdout.decode())
        self.assertNotIn('--system', (self.work / 'sysctl-calls').read_text(encoding='utf-8'))
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_network_policy_failure_is_not_success(self):
        for failure in ['network-plan', 'network-apply']:
            with self.subTest(failure=failure):
                before = self.flags()
                result = self.invoke(failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.flags(), before)
                self.assertEqual(self.config.read_bytes(), self.initial)

    def test_ipv6_ssh_refused(self):
        before = self.flags()
        for connection in ['2001:db8::2 10000 2001:db8::1 22', '::ffff:192.0.2.2 10000 ::ffff:192.0.2.1 22']:
            with self.subTest(connection=connection):
                self.assertNotEqual(self.invoke(ssh=connection).returncode, 0)
                self.assertEqual(self.flags(), before)
                self.assertEqual(self.config.read_bytes(), self.initial)

    def test_lock_conflict_does_not_change_runtime(self):
        before = self.flags()
        self.assertNotEqual(self.invoke(failure='lock').returncode, 0)
        self.assertEqual(self.flags(), before)
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_missing_kernel_controls_fail_closed(self):
        for p in (self.work / 'proc').glob('**/disable_ipv6'):
            p.unlink()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_repeat_preserves_config(self):
        self.invoke(); before = self.config.read_bytes()
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_runtime_failure_restores_mixed_flags(self):
        (self.work / 'proc/sys/net/ipv6/conf/eth0.42/disable_ipv6').write_bytes(b'1\n')
        before = self.flags()
        for failure in ['partial', 'signal', 'mismatch']:
            with self.subTest(failure=failure):
                self.assertNotEqual(self.invoke(failure=failure).returncode, 0)
                self.assertEqual(self.config.read_bytes(), self.initial)
                self.assertEqual(self.flags(), before)

    def test_rename_signal_restores_config_without_runtime_change(self):
        before = self.flags()
        self.assertNotEqual(self.invoke(failure='rename-signal').returncode, 0)
        self.assertEqual(self.flags(), before)
        self.assertEqual(self.config.read_bytes(), self.initial)

    def test_failure_does_not_replay_dynamic_routes_or_kernel_local_routes(self):
        result = self.invoke(failure='partial')
        self.assertNotEqual(result.returncode, 0)
        calls = (self.work / 'ip-calls').read_text(encoding='utf-8') if (self.work / 'ip-calls').exists() else ''
        self.assertNotIn('restore', calls)
        self.assertIn('无法自动恢复', result.stdout.decode())

    def test_unknown_settings_are_not_executed_or_overwritten(self):
        self.config.write_bytes(self.initial + b'net.ipv4.ip_forward = 1\n')
        before = self.config.read_bytes()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((self.work / 'sysctl-calls').exists())

    def test_ipv4_ssh_allows_disable(self):
        self.assertEqual(self.invoke(ssh='192.0.2.2 10000 192.0.2.1 22').returncode, 0)

    def test_ipv6_ssh_allows_enable(self):
        self.assertEqual(self.invoke('enable', ssh='2001:db8::2 10000 2001:db8::1 22').returncode, 0)

    @unittest.skipIf(os.name == 'nt', 'POSIX symlink fixture')
    def test_symlink_target_preserved(self):
        target = self.work / 'unrelated'; target.write_bytes(b'preserve')
        self.config.unlink(); self.config.symlink_to(target)
        before = self.flags()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(target.read_bytes(), b'preserve')
        self.assertEqual(self.flags(), before)


if __name__ == '__main__':
    unittest.main()
