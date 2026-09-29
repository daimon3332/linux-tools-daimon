import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')


@unittest.skipUnless(os.name == 'posix' and shutil.which('jq'), 'requires native Bash and jq')
class RestoreOutput(unittest.TestCase):
    def test_environment_is_passed_without_logging_secrets(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            secret = 'audit-only-secret-7319'
            inspect = [{'Config': {'Image': 'fixture:local', 'Env': ['TOKEN='+secret], 'Entrypoint': [], 'Cmd': []},
                        'HostConfig': {'PortBindings': {}, 'RestartPolicy': {'Name': 'no'}}, 'Mounts': []}]
            (work / 'fixture_inspect.json').write_text(json.dumps(inspect))
            match = re.search(r'(?m)^\tdocker_migration_restore\(\) \{\n', SOURCE)
            body = SOURCE[match.start():SOURCE.index('\n\t}\n', match.end())+3] + r'''
send_stats() { :; }
install() { :; }
install_docker() { :; }
docker_migration_backup_dir() { printf '%s\n' "$1"; }
docker() { if [ "$1" = run ]; then printf '%s\n' "$@" > "$WORK/run-args"; fi; }
docker_migration_restore
'''
            entry = work / 'test.sh'
            entry.write_text(body)
            result = subprocess.run([BASH, str(entry)], input=str(work)+'\n', text=True, capture_output=True,
                                    timeout=15, env=dict(os.environ, WORK=str(work)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('TOKEN='+secret, (work / 'run-args').read_text())
            self.assertNotIn(secret, result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
