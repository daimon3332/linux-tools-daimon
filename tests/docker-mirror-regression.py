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
    match = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[match.start():SOURCE.index('\n}', match.end()) + 2]


class Mirror(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='mirror.')
        self.work = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, failure='', args='5 1 registry.example', action='run'):
        names = ['docker_mirror_cleanup_test_image', 'docker_mirror_speed_run', 'docker_mirror_scheme_url',
                 'docker_mirror_normalize_host', 'docker_mirror_size_mb']
        body = '\n'.join(function(n) for n in names) + r'''
docker() {
    printf '%s\n' "$*" >> "$WORK/calls"
    case "$1 $2" in
        'info ') [ "$FAILURE" != daemon ] ;;
        'image inspect')
            if [ "$FAILURE" = inspect ]; then echo 'permission denied' >&2; return 1; fi
            if [ "$FAILURE" = cached ] || [ -f "$WORK/pulled" ]; then
                if [[ "$*" = *'.Size'* ]]; then echo 123456; elif [ "$FAILURE" = changed ]; then echo sha256:other; else echo sha256:fixture; fi
            else
                [ "$FAILURE" != blank_stdout ] || printf '\n'
                echo "Error response from daemon: No such image: ${!#}" >&2; return 1
            fi ;;
        'image rm') [ "$FAILURE" != cleanup ] || return 1; command rm -f "$WORK/pulled" ;;
        'image prune') : ;;
        'image ls') if [ "$FAILURE" = shared ]; then echo sha256:fixture; fi ;;
        'ps -aq') [ "$FAILURE" != discovery ] || return 1; [ "$FAILURE" != used ] || echo active-container ;;
        'pull registry.example/library/python:3.12-slim')
            [ "$FAILURE" != pull ] || return 1
            touch "$WORK/pulled" ;;
        *) return 1 ;;
    esac
}
timeout() { shift; "$@"; }
'''
        body += '\ndocker_mirror_' + ('speed_run ' + args if action == 'run' else 'cleanup_test_image registry.example/library/python:3.12-slim sha256:fixture') + '\n'
        entry = self.work / 'entry.sh'; entry.write_bytes(body.encode())
        p = subprocess.run([BASH, '--noprofile', '--norc', entry.as_posix()], capture_output=True, timeout=15,
                           env=dict(os.environ, WORK=self.work.as_posix(), FAILURE=failure, IMAGE='library/python:3.12-slim', PLATFORM=''))
        calls = (self.work / 'calls').read_text(encoding='utf-8') if (self.work / 'calls').exists() else ''
        return p, calls

    def test_success_only_removes_created_reference_without_force(self):
        p, calls = self.invoke()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('pull registry.example/', calls)
        self.assertNotIn('image prune', calls)
        self.assertNotIn('image rm -f', calls)
        self.assertFalse((self.work / 'pulled').exists())

    def test_existing_reference_is_not_pulled_or_deleted(self):
        p, calls = self.invoke('cached')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('pull ', calls)
        self.assertNotIn('image rm', calls)
        self.assertNotIn('image prune', calls)

    def test_missing_image_with_blank_inspect_stdout_is_pulled(self):
        p, calls = self.invoke('blank_stdout')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('pull registry.example/', calls)
        self.assertFalse((self.work / 'pulled').exists())

    def test_pull_failure_is_returned_without_global_cleanup(self):
        p, calls = self.invoke('pull')
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('image rm', calls)
        self.assertNotIn('image prune', calls)

    def test_unknown_inspection_failure_cannot_trigger_pull(self):
        p, calls = self.invoke('inspect')
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('pull ', calls)

    def test_daemon_failure_is_returned(self):
        p, calls = self.invoke('daemon')
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('pull ', calls)

    def test_used_reference_is_retained(self):
        p, calls = self.invoke('used')
        self.assertNotIn('image rm', calls)
        self.assertTrue((self.work / 'pulled').exists())

    def test_cleanup_failure_is_reported(self):
        p, calls = self.invoke('cleanup')
        self.assertNotEqual(p.returncode, 0)
        self.assertTrue((self.work / 'pulled').exists())

    def test_invalid_input_causes_no_docker_calls(self):
        for args in ['0 1 registry.example', '5 0 registry.example', '5 invalid registry.example',
                     '5 1 https://registry.example/path', '5 1 --help']:
            with self.subTest(args=args):
                (self.work / 'calls').unlink(missing_ok=True)
                p, calls = self.invoke(args=args)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(calls, '')

    def test_reference_changed_after_pull_is_retained(self):
        (self.work / 'pulled').touch()
        p, calls = self.invoke('changed', action='cleanup')
        self.assertEqual(p.returncode, 0)
        self.assertNotIn('image rm', calls)

    def test_container_discovery_failure_retains_image(self):
        p, calls = self.invoke('discovery')
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('image rm', calls)
        self.assertTrue((self.work / 'pulled').exists())

    def test_preexisting_untagged_image_is_not_removed(self):
        p, calls = self.invoke('shared')
        self.assertEqual(p.returncode, 0)
        self.assertNotIn('image rm', calls)
        self.assertTrue((self.work / 'pulled').exists())


if __name__ == '__main__':
    unittest.main()
