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
    start = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[start.start():SOURCE.index('\n}\n', start.end()) + 2]


class Selection(unittest.TestCase):
    def check_selection(self, selection, failed='', action='remove'):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            for name in ('a', 'b', 'c'):
                (work / name).touch()
            body = function('crontab_sync_handle_numbers') + r'''
crontab_sync_get_item_by_number() {
    local files=() n
    for n in a b c; do [ ! -f "$WORK/$n" ] || files+=("$WORK/$n"); done
    [ "$1" -ge 7 ] && [ "$1" -lt "$((7+${#files[@]}))" ] || return 1
    printf 'custom|%s|cron\n' "${files[$(($1-7))]}"
}
crontab_sync_remove_one() {
    printf '%s\n' "${1##*/}" >> "$WORK/calls"
    [ "${1##*/}" != "$FAIL" ] || return 1
    rm -f -- "$1"
}
crontab_sync_install_one() { crontab_sync_remove_one "$2"; }
crontab_sync_handle_numbers "$ACTION" "$SELECTION"
'''
            script = work / 'test.sh'
            script.write_bytes(body.encode())
            result = subprocess.run([BASH, script.as_posix()], capture_output=True, timeout=15,
                                    env=dict(os.environ, WORK=work.as_posix(), SELECTION=selection, FAIL=failed, ACTION=action))
            calls = (work / 'calls').read_text().splitlines() if (work / 'calls').exists() else []
            return result.returncode, calls

    def test_frozen_number_mapping(self):
        self.assertEqual(self.check_selection('7 8'), (0, ['a', 'b']))

    def test_duplicate_is_not_reindexed(self):
        self.assertEqual(self.check_selection('7 7'), (0, ['a']))

    def test_invalid_selection_has_no_mutations(self):
        rc, calls = self.check_selection('7 99')
        self.assertNotEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_failure_is_not_hidden(self):
        rc, _ = self.check_selection('7 8', failed='a')
        self.assertNotEqual(rc, 0)

    def test_unknown_action_has_no_mutations(self):
        rc, calls = self.check_selection('7', action='typo')
        self.assertNotEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_empty_is_noop(self):
        self.assertEqual(self.check_selection(''), (0, []))


if __name__ == '__main__':
    unittest.main()
