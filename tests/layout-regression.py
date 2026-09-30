import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'docx'


class Layout(unittest.TestCase):
    def test_documents_are_centralized(self):
        for name in ('README.md', 'COMMANDS.md', 'CODING_GUIDELINES.md', 'USER_AGREEMENT.md'):
            self.assertTrue((DOCS / name).is_file(), name)
            if name != 'README.md':
                self.assertFalse((ROOT / name).exists(), name)

    def test_root_readme_is_navigation(self):
        readme = (ROOT / 'README.md').read_text(encoding='utf-8')
        self.assertLess(len(readme.splitlines()), 20)
        for name in ('README.md', 'COMMANDS.md', 'CODING_GUIDELINES.md', 'USER_AGREEMENT.md'):
            self.assertIn('docx/' + name, readme)

    def test_local_document_links_resolve(self):
        for path in [ROOT / 'README.md', *DOCS.glob('*.md')]:
            for target in re.findall(r'\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
                if '://' in target or target.startswith(('#', 'mailto:')):
                    continue
                target = target.split('#', 1)[0]
                if target:
                    self.assertTrue((path.parent / target).exists(), (path.name, target))

    def test_agreement_url_matches_published_layout(self):
        source = (ROOT / 'linux-toolbox.sh').read_text(encoding='utf-8')
        self.assertIn('DAIMON_AGREEMENT_URL="https://github.com/daimon3332/linux-tools-daimon/blob/master/docx/USER_AGREEMENT.md"', source)

    def test_legacy_directory_and_claude_are_absent(self):
        self.assertFalse((ROOT / 'daimon').exists())
        self.assertFalse((ROOT / '.claude').exists())

    def test_license_and_project_entry_remain_at_root(self):
        self.assertTrue((ROOT / 'LICENSE').is_file())
        self.assertTrue((ROOT / 'linux-toolbox.sh').is_file())


if __name__ == '__main__':
    unittest.main()
