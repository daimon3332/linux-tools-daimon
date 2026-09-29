import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    start = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    return SOURCE[start.start():SOURCE.index('\n}\n', start.end()) + 2]


class FirewallDeletion(unittest.TestCase):
    def invoke(self, rule, ports='22\n64400', fail=''):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            work = Path(directory)
            names = ['ufw_manager']
            if 'ufw_delete_allow_safe()' in SOURCE:
                names.append('ufw_delete_allow_safe')
            body = '\n'.join(function(name) for name in names) + r'''
root_use() { :; }
clear() { :; }
break_end() { :; }
id() { echo 0; }
ssh_current_ports() { [ "$FAILURE" != detect ] || return 1; printf '%s\n' "$PORTS"; }
ufw() {
    if [ "$1" = delete ]; then
        printf '%s\n' "$*" >> "$WORK/deletes"
        [ "$FAILURE" != delete ] || return 1
    fi
}
ufw_manager
'''
            entry = work / 'test.sh'
            entry.write_bytes(body.encode())
            result = subprocess.run([BASH, entry.as_posix()], input=f'4\n{rule}\n0\n'.encode(), capture_output=True,
                                    timeout=15, env=dict(os.environ, WORK=work.as_posix(), PORTS=ports, FAILURE=fail))
            calls = (work / 'deletes').read_text() if (work / 'deletes').exists() else ''
            return result, calls

    def test_current_ssh_port_not_deleted(self):
        for rule in ('22', '22/tcp', '64400/tcp', '1:65535/tcp'):
            with self.subTest(rule=rule):
                self.assertEqual(self.invoke(rule)[1], '')

    def test_detection_failure_refuses_deletion(self):
        self.assertEqual(self.invoke('8080/tcp', fail='detect')[1], '')

    def test_invalid_or_application_rules_refused(self):
        for rule in ('OpenSSH', '0', '65536', '22:1/tcp', '1:65535', '80 --force', '80;true'):
            with self.subTest(rule=rule):
                self.assertEqual(self.invoke(rule)[1], '')

    def test_non_ssh_tcp_and_udp_can_be_deleted(self):
        for rule in ('8080/tcp', '22/udp', '8000:8100/tcp'):
            with self.subTest(rule=rule):
                self.assertEqual(self.invoke(rule)[1].strip(), 'delete allow '+rule)

    def test_command_failure_not_followed_by_success_status(self):
        result, calls = self.invoke('8080/tcp', fail='delete')
        self.assertTrue(calls)
        self.assertIn('规则删除失败'.encode(), result.stdout)


if __name__ == '__main__':
    unittest.main()
