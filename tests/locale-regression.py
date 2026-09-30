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
    match = re.search(r'(?m)^'+name+r'\(\) ([{(])\n', SOURCE)
    closing = '}' if match[1] == '{' else ')'
    return SOURCE[match.start():SOURCE.index('\n'+closing, match.end())+2]


class Locales(unittest.TestCase):
    def setUp(self):
        (ROOT/'.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT/'.tmp', prefix='locale.')
        self.work = Path(self.temp.name)
        (self.work/'etc/default').mkdir(parents=True)
        (self.work/'managed').mkdir()
        (self.work/'etc/os-release').write_bytes(b'ID=ubuntu\n')
        self.gen = self.work/'etc/locale.gen'
        self.config = self.work/'etc/default/locale'
        self.gen.write_bytes(b'# keep\n# en_US.UTF-8 UTF-8\n')
        self.config.write_bytes(b'LANG=C.UTF-8\nLC_TIME=C.UTF-8\n')
        self.initial = (self.gen.read_bytes(), self.config.read_bytes())

    def tearDown(self):
        self.temp.cleanup()

    def run_locale(self, failure='', lang='en_US.UTF-8'):
        names = ['update_locale', 'daimon_config_commit']
        if 'daimon_debian_locale()' in SOURCE:names.append('daimon_debian_locale')
        body = '\n'.join(function(n) for n in names).replace('/etc/', self.work.as_posix()+'/etc/')
        body += r'''
install() { [ "$FAILURE" != install ]; }
locale-gen() { [ "$FAILURE" != signal ] || kill -TERM "$BASHPID"; [ "$FAILURE" != generate ]; }
locale() { printf 'C\nC.utf8\nen_US.utf8\n'; }
update-locale() {
    [ "$FAILURE" != configure ] || return 1
    [ "$1" = --locale-file ] || return 91
    sed '/^LANG=/d' "$2" > "$WORK/content" || return 1
    printf '%s\n' "$3" >> "$WORK/content"
    cat "$WORK/content" > "$2"
}
mv() {
    if [ "$FAILURE" = commit ] && [ "${@: -1}" = "$WORK/etc/default/locale" ]; then return 1; fi
    command mv "$@"
}
'''
        if os.name=='nt':body+='flock() { :; }\n'
        body+='update_locale "$LANG_INPUT" "$LANG_INPUT" false\n'
        entry=self.work/'entry.sh';entry.write_bytes(body.encode())
        return subprocess.run([BASH,'--noprofile','--norc',entry.as_posix()],capture_output=True,timeout=20,
                              env=dict(os.environ,WORK=self.work.as_posix(),FAILURE=failure,LANG_INPUT=lang,
                                       DAIMON_ROOT_DIR=(self.work/'managed').as_posix()))

    def test_preserves_unrelated_locale_category(self):
        result=self.run_locale()
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'LANG=en_US.UTF-8\n',self.config.read_bytes())
        self.assertIn(b'LC_TIME=C.UTF-8\n',self.config.read_bytes())

    def test_generation_failure_restores_selection(self):
        result=self.run_locale('generate')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    def test_native_configuration_failure_restores_selection(self):
        result=self.run_locale('configure')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    def test_configuration_commit_failure_restores_selection(self):
        result=self.run_locale('commit')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    def test_signal_restores_selection(self):
        result=self.run_locale('signal')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    @unittest.skipIf(os.name=='nt','POSIX symlink fixture')
    def test_native_debian_symlink_is_preserved(self):
        target=self.work/'etc/locale.conf';target.write_bytes(self.config.read_bytes())
        self.config.unlink();self.config.symlink_to(target)
        result=self.run_locale()
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertTrue(self.config.is_symlink())
        self.assertIn(b'LANG=en_US.UTF-8',target.read_bytes())
        self.assertIn(b'LC_TIME=C.UTF-8',target.read_bytes())

    @unittest.skipIf(os.name=='nt','POSIX symlink fixture')
    def test_unrelated_symlink_target_is_preserved(self):
        target=self.work/'unrelated';target.write_bytes(b'preserve')
        self.config.unlink();self.config.symlink_to(target)
        result=self.run_locale()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(target.read_bytes(),b'preserve')
        self.assertEqual(self.gen.read_bytes(),self.initial[0])

    def test_install_failure_preserves_configuration(self):
        result=self.run_locale('install')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    def test_invalid_locale_does_not_mutate(self):
        result=self.run_locale(lang='en_US.UTF-8\nLC_ALL=invalid')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.gen.read_bytes(),self.config.read_bytes()),self.initial)

    def test_repeat_does_not_duplicate_generation_entry(self):
        self.assertEqual(self.run_locale().returncode,0)
        first=self.gen.read_bytes()
        self.assertEqual(self.run_locale().returncode,0)
        self.assertEqual(self.gen.read_bytes(),first)
        self.assertEqual(first.count(b'en_US.UTF-8 UTF-8'),1)


if __name__=='__main__':
    unittest.main()
