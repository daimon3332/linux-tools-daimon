import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH=os.environ.get('BASH_BIN','/bin/bash')


def function(name):
    match=re.search(r'(?m)^'+name+r'\(\) ([{(])\n',SOURCE)
    closing='}' if match[1]=='{' else ')'
    return SOURCE[match.start():SOURCE.index('\n'+closing,match.end())+2]


class Journal(unittest.TestCase):
    def setUp(self):
        (ROOT/'.tmp').mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp',prefix='journal.')
        self.work=Path(self.temp.name)
        (self.work/'etc/systemd/journald.conf.d').mkdir(parents=True)
        (self.work/'managed').mkdir()
        self.config=self.work/'etc/systemd/journald.conf.d/99-daimon-journal.conf'
        self.config.write_bytes(b'[Journal]\nStorage=persistent\nSystemMaxUse=8M\n')
        self.initial=self.config.read_bytes()

    def tearDown(self):
        self.temp.cleanup()

    def menu(self,values=None,failure='',inputs=None):
        names=['journalctl_log_manager','daimon_config_commit']
        for name in ['daimon_journal_size_valid','daimon_journal_configure']:
            if name+'()' in SOURCE:names.append(name)
        body='\n'.join(function(n) for n in names).replace('/etc/',self.work.as_posix()+'/etc/')
        body+=r'''
root_use() { :; }; clear() { :; }; send_stats() { :; }; break_end() { :; }
systemd-analyze() { [ "$2" != invalid-time ]; }
systemctl() {
    if [ "$1" = is-active ]; then [ "$FAILURE" != inactive ]; return; fi
    echo "$*" >> "$WORK/service-calls"
    if [ "$FAILURE" = signal ] && [ ! -e "$WORK/signal-sent" ]; then touch "$WORK/signal-sent"; kill -TERM "$BASHPID"; fi
    [ "$FAILURE" != restart ]
}
service() { return 1; }
journalctl() { echo "$*" >> "$WORK/journal-calls"; }
mv() {
    if [ "$FAILURE" = write ]; then return 1; fi
    command mv "$@"
}
'''
        if os.name=='nt':body+='flock() { :; }\n'
        body+='journalctl_log_manager\n'
        script=self.work/'entry.sh';script.write_bytes(body.encode())
        if inputs is None:inputs='1\n'+'\n'.join(values or ['16M','128M','4M','7d'])+'\n0\n'
        return subprocess.run([BASH,'--noprofile','--norc',script.as_posix()],input=inputs.encode(),capture_output=True,timeout=15,
                              env=dict(os.environ,WORK=self.work.as_posix(),DAIMON_ROOT_DIR=(self.work/'managed').as_posix(),FAILURE=failure))

    def test_preserves_other_journal_configuration(self):
        result=self.menu()
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'Storage=persistent',self.config.read_bytes())
        self.assertIn(b'SystemMaxUse=16M',self.config.read_bytes())

    def test_restart_failure_restores_configuration(self):
        result=self.menu(failure='restart')
        self.assertNotIn('日志配置已更新',result.stdout.decode())
        self.assertEqual(self.config.read_bytes(),self.initial)

    def test_write_failure_preserves_configuration(self):
        self.menu(failure='write')
        self.assertEqual(self.config.read_bytes(),self.initial)
        self.assertFalse((self.work/'service-calls').exists())

    def test_signal_restores_configuration(self):
        self.menu(failure='signal')
        self.assertEqual(self.config.read_bytes(),self.initial)

    def test_default_values(self):
        self.menu(values=['','','',''])
        self.assertIn(b'SystemMaxUse=500M',self.config.read_bytes())
        self.assertIn(b'MaxRetentionSec=1month',self.config.read_bytes())
        self.assertIn(b'Storage=persistent',self.config.read_bytes())

    def test_inactive_service_is_not_started(self):
        self.menu(failure='inactive')
        self.assertFalse((self.work/'service-calls').exists())
        self.assertIn(b'SystemMaxUse=16M',self.config.read_bytes())

    def test_invalid_size_preserves_configuration(self):
        for size in ['invalid','-1M','999999999999999999E','1M\rStorage=none']:
            with self.subTest(size=size):
                self.menu(values=[size,'128M','4M','7d'])
                self.assertEqual(self.config.read_bytes(),self.initial)

    def test_invalid_retention_preserves_configuration(self):
        self.menu(values=['16M','128M','4M','invalid-time'])
        self.assertEqual(self.config.read_bytes(),self.initial)

    def test_repeat_is_idempotent(self):
        self.menu();before=self.config.read_bytes();self.menu()
        self.assertEqual(self.config.read_bytes(),before)

    def test_eof_preserves_configuration(self):
        self.menu(inputs='1\n16M\n')
        self.assertEqual(self.config.read_bytes(),self.initial)
        self.assertFalse((self.work/'service-calls').exists())

    def test_return_preserves_configuration(self):
        self.menu(inputs='0\n')
        self.assertEqual(self.config.read_bytes(),self.initial)
        self.assertFalse((self.work/'service-calls').exists())

    @unittest.skipIf(os.name=='nt','POSIX symlink fixture')
    def test_symlink_target_is_preserved(self):
        target=self.work/'unrelated';target.write_bytes(b'preserve')
        self.config.unlink();self.config.symlink_to(target)
        self.menu()
        self.assertEqual(target.read_bytes(),b'preserve')
        self.assertTrue(self.config.is_symlink())


if __name__=='__main__':
    unittest.main()
