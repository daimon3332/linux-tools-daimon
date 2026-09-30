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


class KeyView(unittest.TestCase):
    def invoke(self, existing=False):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            ssh = work / 'ssh'
            if existing:
                ssh.mkdir(mode=0o750)
                (ssh / 'authorized_keys').write_text('# preserved\n')
                (ssh / 'authorized_keys').chmod(0o640)
            def state():
                return {str(p.relative_to(work)): (p.read_bytes() if p.is_file() else None, p.stat().st_mode)
                        for p in work.rglob('*') if p.name != 'test.sh'}
            before = state()
            start = re.search(r'(?m)^\tssh_key_manager\(\) \{\n', SOURCE)
            body = SOURCE[start.start():SOURCE.index('\n\t}\n', start.end())+3]
            body = body.replace('/root/.ssh', ssh.as_posix())
            entry = work / 'test.sh'
            entry.write_bytes((body+'\nclear() { :; }\nbreak_end() { :; }\nssh_key_manager\n').encode())
            result = subprocess.run([BASH, entry.as_posix()], input=b'0\n', capture_output=True, timeout=15)
            return result, before, state()

    def test_missing_keys_directory_not_created_by_view(self):
        result, before, after = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, after)

    def test_view_preserves_existing_content_and_modes(self):
        result, before, after = self.invoke(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
