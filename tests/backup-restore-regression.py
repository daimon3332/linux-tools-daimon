from source import read_source
import io
import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = read_source(ROOT)
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    if not match:
        raise AssertionError('Missing safe restore function: ' + name)
    return SOURCE[match.start():SOURCE.index('\n}\n', match.end()) + 2]


class Menu(unittest.TestCase):
    def test_restore_never_targets_live_root(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'fixture.tar.gz').touch()
            (work / 'destination').mkdir()
            body = function('restore_backup') + r'''
daimon_require_cmd() { command -v "$1" >/dev/null 2>&1; }
send_stats() { :; }
tar() { printf 'UNSAFE_LIVE_EXTRACTION %s\n' "$*"; }
daimon_backup_delete_target() { printf '%s\n' "$BACKUP_DIR/$1"; }
daimon_backup_extract_safe() { printf 'SAFE_EXTRACTION\n'; }
BACKUP_DIR="$WORK"
if command -v cygpath >/dev/null 2>&1; then BACKUP_DIR=$(cygpath -u "$WORK"); fi
restore_backup
'''
            entry = work / 'entry.sh'
            entry.write_text(body, encoding='utf-8')
            result = subprocess.run([BASH, str(entry)], input=('fixture.tar.gz\n'+str(work / 'destination')+'\ny\n').encode(),
                                    capture_output=True, env=dict(os.environ, WORK=str(work)), timeout=15)
            self.assertNotIn(b'UNSAFE_LIVE_EXTRACTION', result.stdout)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b'SAFE_EXTRACTION', result.stdout)


@unittest.skipUnless(os.name == 'posix', 'requires native directory descriptors')
class Extraction(unittest.TestCase):
    def invoke(self, entries, prepare=None):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            destination = work / 'destination'
            destination.mkdir(mode=0o700)
            archive = work / 'fixture.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                for name, kind in entries:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.mode = 0o6755
                    member.linkname = '../outside'
                    data = b'audit restore contents\n' if kind == tarfile.REGTYPE else b''
                    member.size = len(data)
                    output.addfile(member, io.BytesIO(data))
            archive.chmod(0o600)
            if prepare:
                prepare(work, destination, archive)
            entry = work / 'entry.sh'
            entry.write_text(function('daimon_backup_extract_safe') + '\ndaimon_backup_extract_safe "$1" "$2"\n')
            result = subprocess.run([BASH, str(entry), str(archive), str(destination)], capture_output=True, timeout=15)
            files = {str(p.relative_to(destination)): p.read_bytes() for p in destination.rglob('*') if p.is_file()}
            modes = {str(p.relative_to(destination)): p.stat().st_mode & 0o7777 for p in destination.rglob('*')}
            return result, files, modes

    def test_nested_files_and_directories(self):
        result, files, modes = self.invoke([('./', tarfile.DIRTYPE), ('etc/', tarfile.DIRTYPE), ('etc/a', tarfile.REGTYPE)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {'etc/a': b'audit restore contents\n'})
        self.assertEqual(modes, {'etc': 0o755, 'etc/a': 0o755})

    def test_unsafe_members_refused_before_any_extraction(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('a/../escape', tarfile.REGTYPE), ('link', tarfile.SYMTYPE),
                           ('link', tarfile.LNKTYPE), ('device', tarfile.CHRTYPE), ('fifo', tarfile.FIFOTYPE),
                           ('line\nbreak', tarfile.REGTYPE), ('a\\b', tarfile.REGTYPE), ('a', tarfile.REGTYPE),
                           ('a/b', tarfile.REGTYPE)]:
            with self.subTest(name=name, kind=kind):
                result, files, _ = self.invoke([('a', tarfile.REGTYPE), (name, kind)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(files, {})

    def test_nonempty_destination_untouched(self):
        result, files, _ = self.invoke([('data', tarfile.REGTYPE)], lambda w, d, a: (d / 'keep').write_text('original'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {'keep': b'original'})

    def test_symlink_destination_refused(self):
        def prepare(work, destination, archive):
            destination.rename(work / 'actual')
            destination.symlink_to(work / 'actual', target_is_directory=True)
        result, files, _ = self.invoke([('data', tarfile.REGTYPE)], prepare)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {})

    def test_untrusted_or_corrupt_archive_refused(self):
        for prepare in [lambda w, d, a: a.write_bytes(b'corrupt'),
                        lambda w, d, a: a.chmod(0o666),
                        lambda w, d, a: os.link(a, w / 'hardlink')]:
            result, files, _ = self.invoke([('data', tarfile.REGTYPE)], prepare)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(files, {})

    def test_empty_archive_refused(self):
        result, files, _ = self.invoke([])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files, {})


if __name__ == '__main__':
    unittest.main()
