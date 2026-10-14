import importlib.util
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_package', ROOT/'scripts/lib/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class Package(unittest.TestCase):
    def test_complete_source_tree_hashes(self):
        data = package.verify(ROOT)
        self.assertGreater(len(data['files']), 25)
        self.assertEqual(sum(p.startswith('scripts/') and p[8:10].isdigit() for p in data['modules']), 21)

    def test_mainland_proxy_priority(self):
        revision = 'a'*40
        mainland = package.archive_urls(revision, 'CN')
        self.assertTrue(mainland[0].startswith('https://ghfast.top/'))
        for region in ('CN', 'HK'):
            self.assertFalse(any('gh-proxy.com' in u for u in package.archive_urls(revision, region)))
        self.assertTrue(any('codeload.github.com' in u for u in mainland))
        self.assertTrue(package.archive_urls(revision, 'HK')[0].startswith('https://codeload.github.com/'))

    def test_revision_from_api_and_git_refs(self):
        sha = 'b' * 40
        api = 'https://api.github.com/repos/x/y/git/ref/heads/master'
        self.assertEqual(package.revision_from(api, json.dumps({'object': {'type': 'commit', 'sha': sha}}).encode()), sha)
        refs = (b'001e# service=git-upload-pack\n0000015b' + b'c' * 40 + b' HEAD\x00multi_ack\n003f' +
                sha.encode() + b' refs/heads/master\n0000')
        self.assertEqual(package.revision_from('https://ghfast.top/https://github.com/x/y/info/refs?service=git-upload-pack', refs), sha)
        self.assertEqual(package.revision_from('https://github.com/x/y/info/refs', b'<html>blocked</html>'), '')

    def test_corruption_and_missing_module_refused(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'.tmp') as directory:
            destination = Path(directory)
            data = json.loads((ROOT/'runtime.json').read_text())
            (destination/'runtime.json').write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'missing'):
                package.verify(destination)
            (destination/'linux-toolbox.sh').write_text('corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                package.verify(destination)

    def test_manifest_cannot_escape_target(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'.tmp') as directory:
            target = Path(directory)
            data = json.loads((ROOT/'runtime.json').read_text())
            data['files']['../outside.sh'] = 'a'*64
            (target/'runtime.json').write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                package.manifest(target)

    def test_missing_menu_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'.tmp') as directory:
            target = Path(directory)
            data = json.loads((ROOT/'runtime.json').read_text())
            del data['files']['scripts/21-network-optimization.sh']
            (target/'runtime.json').write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'Menu module'):
                package.manifest(target)

    def test_archive_traversal_and_links_rejected(self):
        for name, kind in [('../outside',tarfile.REGTYPE),('release/file',tarfile.SYMTYPE)]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(dir=ROOT/'.tmp') as directory:
                buffer = io.BytesIO()
                with tarfile.open(fileobj=buffer,mode='w:gz') as archive:
                    member=tarfile.TarInfo(name);member.type=kind;member.linkname='/etc/passwd'
                    archive.addfile(member)
                buffer.seek(0)
                with tarfile.open(fileobj=buffer,mode='r:gz') as archive, self.assertRaisesRegex(ValueError, 'Unsafe'):
                    package.unpack(archive,Path(directory),'a'*40)

    def test_module_file_order_is_complete_and_no_entry_recursion(self):
        data = package.manifest(ROOT)
        self.assertNotIn('scripts/lib/entry.sh',data['modules'])
        self.assertEqual(len(data['modules']),len(set(data['modules'])))


if __name__ == '__main__':
    (ROOT/'.tmp').mkdir(exist_ok=True)
    unittest.main()
