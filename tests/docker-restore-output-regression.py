from source import read_source
import os,re,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=read_source(ROOT)
BASH=os.environ.get('BASH_BIN','/bin/bash')
class RestoreRouting(unittest.TestCase):
    def test_restore_requires_confirmation_and_passes_paths_without_shell_expansion(self):
        (ROOT/'.tmp').mkdir(exist_ok=True)
        for confirmation in ('RESTORE','n',''):
            with self.subTest(confirmation=confirmation), tempfile.TemporaryDirectory(dir=ROOT/'.tmp') as directory:
                work=Path(directory)
                m=re.search(r'(?m)^\tdocker_migration_restore\(\) \{\n',SOURCE)
                body=SOURCE[m.start():SOURCE.index('\n\t}\n',m.end())+3]+r'''
docker_migration_backup_dir() { printf '%s\n' "$1"; }
docker_migration_engine() { printf '%s\n' "$@" > "$TRACE"; }
docker_migration_restore
'''
                target='/root/restore space; literal'
                p=subprocess.run([BASH,'-c',body],input=('/tmp/docker_backup_fixture\n'+target+'\n'+confirmation+'\n').encode(),capture_output=True,timeout=15,env=dict(os.environ,TRACE=(work/'trace').as_posix()))
                self.assertEqual(p.returncode,0,p.stderr)
                if confirmation=='RESTORE':self.assertEqual((work/'trace').read_text().splitlines(),['restore','/tmp/docker_backup_fixture',target])
                else:self.assertFalse((work/'trace').exists())
if __name__=='__main__':unittest.main()
