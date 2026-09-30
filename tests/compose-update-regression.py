import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')
OLD = 'sha256:' + '1' * 64
NEW = 'sha256:' + '2' * 64


def function(name, next_name):
    start = SOURCE.index(name + '() {')
    return SOURCE[start:SOURCE.index(next_name + '() {', start)]


FAKE_DOCKER = r'''#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/trace"
if [ "$1" = compose ]; then
    shift
    while [ "$1" = -p ] || [ "$1" = -f ]; do shift 2; done
    action=$1; shift
    case "$action" in
        version) echo 'Docker Compose version v5.5.1' ;;
        config)
            if [ "${1:-}" = --images ]; then echo fixture/app:latest
            else cat "$FIXTURE/config.json"; fi ;;
        ps)
            if [ "${1:-}" = --services ]; then printf '%s\n' "${RUNNING_SERVICES-app}"
            else echo fixture-container; fi ;;
        pull)
            if [ "${1:-}" = --help ]; then echo --ignore-buildable; exit 0; fi
            count=$(cat "$FIXTURE/pulls" 2>/dev/null || echo 0)
            count=$((count + 1)); echo "$count" > "$FIXTURE/pulls"
            if [ "$count" -le "${FAIL_PULLS:-0}" ]; then echo 'unexpected EOF' >&2; exit 1; fi
            echo "$NEW_IMAGE" > "$FIXTURE/tag" ;;
        up)
            if [ "${1:-}" = --help ]; then printf '%s\n' '--wait --pull --no-build'; exit 0; fi
            if [ "${FAIL_START:-0}" = 1 ] && [[ " $* " != *' --force-recreate '* ]]; then exit 1; fi
            if [ "${MISMATCH_START:-0}" = 1 ] && [[ " $* " != *' --force-recreate '* ]]; then echo "$OLD_IMAGE" > "$FIXTURE/running"
            else cp "$FIXTURE/tag" "$FIXTURE/running"; fi ;;
        *) exit 90 ;;
    esac
elif [ "$1 $2" = 'image inspect' ]; then
    cat "$FIXTURE/tag" 2>/dev/null || echo "$OLD_IMAGE"
elif [ "$1 $2" = 'image tag' ]; then
    echo "$3" > "$FIXTURE/tag"
elif [ "$1" = inspect ] || [ "$1 $2" = 'container inspect' ]; then
    if [[ "$*" == *'.State.Running'* ]]; then echo true
    elif [[ "$*" == *'.State.Health.Status'* ]]; then echo healthy
    else cat "$FIXTURE/running" 2>/dev/null || echo "$OLD_IMAGE"; fi
else exit 90; fi
'''


class ComposeUpdate(unittest.TestCase):
    def invoke(self, services=None, **env):
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            path = work.as_posix()
            if os.name == 'nt':
                path = subprocess.check_output([BASH, '-c', 'cygpath -u "$1"', 'fixture', path], text=True).strip()
            config = {'services': services or {'app': {'image': 'fixture/app:latest', 'environment': {'TOKEN': 'private-test-token'}}}}
            (work / 'config.json').write_text(json.dumps(config), encoding='utf-8')
            (work / 'docker').write_text(FAKE_DOCKER, encoding='utf-8')
            (work / 'docker').chmod(0o700)
            (work / 'python3').write_text('#!/bin/bash\nexec ' + shlex.quote(sys.executable.replace('\\', '/')) + ' "$@"\n', encoding='utf-8')
            (work / 'python3').chmod(0o700)
            generated = work / 'update.sh'
            definitions = function('docker_compose_update_write_script', 'docker_compose_update_ensure_logrotate')
            script = definitions + '\ndocker_compose_update_log_dir() { echo "$FIXTURE"; }\n'
            script += 'docker_compose_update_write_script fixture "$FIXTURE" "" "$FIXTURE/update.sh" test-fixture\n'
            variables = dict(os.environ, FIXTURE=path, OLD_IMAGE=OLD, NEW_IMAGE=NEW,
                             COMPOSE_UPDATE_PULL_RETRY_DELAY='0')
            variables.update(env)
            p = subprocess.run([BASH, '--noprofile', '--norc'], input=script.encode(), env=variables, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            content = generated.read_text(encoding='utf-8')
            content = re.sub(r'^PATH=.*$', 'PATH="$FIXTURE:$PATH"', content, flags=re.M)
            content = content.replace('LOCK_FILE="/run/lock/docker-compose-update-${COMPOSE_UPDATE_ID}.lock"', 'LOCK_FILE="$FIXTURE/update.lock"')
            content = content.replace('mkdir -p /run/lock', 'mkdir -p "$FIXTURE"')
            p = subprocess.run([BASH, '--noprofile', '--norc'], input=content.encode(), env=variables, capture_output=True, timeout=20)
            trace = (work / 'trace').read_text(encoding='utf-8').splitlines() if (work / 'trace').exists() else []
            self.assertNotIn('private-test-token', p.stdout.decode('utf-8') + p.stderr.decode('utf-8'))
            return p.returncode, p.stdout.decode('utf-8'), p.stderr.decode('utf-8'), trace

    def test_transient_pull_retried_before_start(self):
        rc, out, err, trace = self.invoke(FAIL_PULLS='2')
        self.assertEqual(rc, 0, err + out)
        pulls = [i for i, line in enumerate(trace) if ' pull ' in line and '--help' not in line]
        starts = [i for i, line in enumerate(trace) if ' up ' in line and '--help' not in line]
        self.assertEqual(len(pulls), 3)
        self.assertTrue(starts and min(starts) > max(pulls))

    def test_exhausted_pull_keeps_containers_running(self):
        rc, out, err, trace = self.invoke(FAIL_PULLS='9')
        self.assertNotEqual(rc, 0)
        self.assertEqual(sum(' pull ' in line and '--help' not in line for line in trace), 3)
        self.assertFalse(any(' up ' in line and '--help' not in line for line in trace))

    def test_build_only_skipped_without_false_success(self):
        rc, out, err, trace = self.invoke({'app': {'build': {'context': '.'}}})
        self.assertEqual(rc, 0, err + out)
        self.assertIn('SKIPPED_BUILD', out)
        self.assertNotIn('更新成功', out)
        self.assertFalse(any((' pull ' in line or ' up ' in line) and '--help' not in line for line in trace))

    def test_unchanged_image_does_not_recreate(self):
        rc, out, err, trace = self.invoke(NEW_IMAGE=OLD)
        self.assertEqual(rc, 0, err + out)
        self.assertIn('NO_CHANGE', out)
        self.assertFalse(any(' up ' in line and '--help' not in line for line in trace))

    def test_start_and_rollback_never_pull_or_build_again(self):
        rc, out, err, trace = self.invoke(FAIL_START='1')
        self.assertNotEqual(rc, 0)
        starts = [line for line in trace if ' up ' in line and '--help' not in line]
        self.assertEqual(len(starts), 2, out + err)
        self.assertTrue(all('--pull never' in line and '--no-build' in line for line in starts))
        self.assertTrue(any('--force-recreate' in line for line in starts))

    def test_mixed_project_leaves_build_service_out(self):
        rc, out, err, trace = self.invoke({'app': {'image': 'fixture/app:latest'}, 'builder': {'build': '.'}}, RUNNING_SERVICES='app\nbuilder')
        self.assertEqual(rc, 0, err + out)
        for line in trace:
            if (' pull ' in line or ' up ' in line) and '--help' not in line:
                self.assertNotIn('builder', line)

    def test_schedule_explicit_shanghai_guard_and_stagger(self):
        definitions = function('docker_compose_update_cron_line', 'docker_compose_update_status_text')
        script = definitions + '\ndocker_compose_update_log_dir() { echo /var/log/docker-compose-update; }\n'
        script += 'docker_compose_update_cron_line /root/linux-daimon/docker-compose-update/update.sh 5\n'
        p = subprocess.run([BASH, '--noprofile', '--norc'], input=script.encode(), capture_output=True)
        line = p.stdout.decode()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(line.startswith('* * * * * '), line)
        self.assertIn('TZ=Asia/Shanghai', line)
        self.assertIn('date +\\%H:\\%M', line)
        self.assertIn('03:35', line)

    def test_result_image_mismatch_triggers_rollback(self):
        rc, out, err, trace = self.invoke(MISMATCH_START='1')
        self.assertNotEqual(rc, 0)
        self.assertIn('已恢复', out)
        self.assertTrue(any('--force-recreate' in line for line in trace))

    def test_invalid_retry_options_never_pull(self):
        for key, value in [('COMPOSE_UPDATE_PULL_ATTEMPTS', '0'), ('COMPOSE_UPDATE_PULL_ATTEMPTS', '6'),
                           ('COMPOSE_UPDATE_PULL_RETRY_DELAY', '-1'), ('COMPOSE_UPDATE_PULL_TIMEOUT', '0')]:
            with self.subTest(key=key):
                rc, out, err, trace = self.invoke(**{key: value})
                self.assertNotEqual(rc, 0)
                self.assertEqual(trace, [])

    def test_fixed_digest_and_never_policy_are_not_updated(self):
        for config, reason in [({'image': 'fixture/app@' + OLD}, 'SKIPPED_PINNED'),
                               ({'image': 'fixture/app:latest', 'pull_policy': 'never'}, 'SKIPPED_POLICY')]:
            with self.subTest(reason=reason):
                rc, out, err, trace = self.invoke({'app': config})
                self.assertEqual(rc, 0, err + out)
                self.assertIn(reason, out)
                self.assertFalse(any(' pull ' in line for line in trace))

    def test_stopped_project_not_started(self):
        rc, out, err, trace = self.invoke(RUNNING_SERVICES='')
        self.assertEqual(rc, 0, err + out)
        self.assertFalse(any((' pull ' in line or ' up ' in line) and '--help' not in line for line in trace))


if __name__ == '__main__':
    (ROOT / '.tmp').mkdir(exist_ok=True)
    unittest.main()
