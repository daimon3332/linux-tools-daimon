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
    match = re.search(r'(?m)^' + name + r'\(\) \{\n', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    if name == 'ip_address':
        return SOURCE[match.start():SOURCE.index('\ninstall() {', match.end())].strip()
    return SOURCE[match.start():SOURCE.index('\n}', match.end()) + 2]


class SystemInfoTest(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='system-info.')
        self.work = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, names, action, setup=''):
        script = '\n'.join(function(name) for name in names) + '\n' + setup + '\n' + action + '\n'
        syntax = subprocess.run([BASH, '-n'], input=script.encode('utf-8'), capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode('utf-8'))
        result = subprocess.run([BASH, '--noprofile', '--norc'], input=script.encode('utf-8'),
                                env=dict(os.environ, WORK=self.work.as_posix()), capture_output=True, timeout=15)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def test_cpu_counts_nice_irq_and_steal(self):
        program = re.search(r"cpu_usage_percent=\$\(awk '([^']+)'", function('linux_info'))[1]
        for column in [2, 3, 4, 7, 8, 9]:
            with self.subTest(column=column):
                first = [0] * 10
                first[3] = 100
                second = first.copy()
                second[3] += 50
                second[column - 2] += 50
                fixture = self.work / 'cpu'
                fixture.write_text('\n'.join('cpu ' + ' '.join(map(str, row)) for row in [first, second]) + '\n', encoding='utf-8')
                result = self.shell([], 'awk ' + "'" + program + "'" + ' "$WORK/cpu"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '50')

    def test_cpu_unchanged_sample_is_not_division_by_zero(self):
        program = re.search(r"cpu_usage_percent=\$\(awk '([^']+)'", function('linux_info'))[1]
        (self.work / 'cpu').write_bytes(b'cpu 100 0 100 200 0 0 0 0 0 0\ncpu 100 0 100 200 0 0 0 0 0 0\n')
        result = self.shell([], "awk '" + program + "'" + ' "$WORK/cpu"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '0')

    def test_ssh_effective_config_wins_over_text_parser(self):
        result = self.shell(['sshd_effective_value', 'normalize_ssh_bool'], 'sshd_effective_value passwordauthentication', '''
sshd_config_value() { echo yes; }
sshd_bin_path() { echo fixture_sshd; }
fixture_sshd() { echo 'passwordauthentication no'; }
''')
        self.assertEqual(result.stdout.strip(), 'no')

    def test_ssh_query_failure_is_unknown_not_static_guess(self):
        result = self.shell(['sshd_effective_value', 'normalize_ssh_bool'], 'sshd_effective_value passwordauthentication', '''
sshd_config_value() { echo yes; }
sshd_bin_path() { echo fixture_sshd; }
fixture_sshd() { return 1; }
''')
        self.assertEqual(result.stdout.strip(), '')

    def test_partial_ssh_state_is_not_reported_disabled_or_port_22(self):
        result = self.shell(['system_info_ssh'], 'system_info_ssh', '''
service_status_text() { echo unknown; }
ss() { return 1; }
sshd_bin_path() { :; }
awk() { return 1; }
sshd_effective_value() { [ "$1" != passwordauthentication ] || echo no; }
''')
        self.assertIn('密码登录: 未知', result.stdout)
        self.assertIn('端口: 未知', result.stdout)

    def test_public_ip_families_are_explicit(self):
        result = self.shell(['ip_address'], 'ip_address; printf "%s|%s\\n" "$ipv4_address" "$ipv6_address"', '''
curl() {
    echo "$*" >> "$WORK/curl-args"
    case "$*" in
        *v6.ipinfo.io/ip*) echo 2001:db8::1 ;;
        */org*) echo AS64500 ;;
        *) case " $* " in *' -4 '*) echo 192.0.2.1 ;; *) echo 2001:db8::1 ;; esac ;;
    esac
}
''')
        self.assertEqual(result.stdout.strip(), '192.0.2.1|2001:db8::1')
        arguments = (self.work / 'curl-args').read_text()
        self.assertIn('-6', arguments)
        self.assertNotIn('http://', arguments)

    def test_cn_local_ipv4_skips_ipv6_and_uses_interface_fallback(self):
        setup = '''
curl() { case "$*" in */org*) echo CHINANET ;; *v6.ipinfo.io/ip*) : ;; *) echo 192.0.2.2 ;; esac; }
ip() { return 1; }
hostname() { echo 2001:db8::1; }
ifconfig() { echo '    inet 192.0.2.3 netmask 255.255.255.0'; }
'''
        result = self.shell(['ip_address'], 'ip_address; echo "$ipv4_address"', setup)
        self.assertEqual(result.stdout.strip(), '192.0.2.3')

    def test_cpu_iowait_is_idle_and_guest_is_not_double_counted(self):
        program = re.search(r"cpu_usage_percent=\$\(awk '([^']+)'", function('linux_info'))[1]
        (self.work / 'cpu').write_bytes(b'cpu 0 0 0 100 0 0 0 0 0 0\ncpu 50 0 0 100 50 0 0 0 50 0\n')
        result = self.shell([], "awk '" + program + "'" + ' "$WORK/cpu"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '50')

    def test_ssh_failed_query_does_not_leak_partial_output(self):
        result = self.shell(['sshd_effective_value', 'normalize_ssh_bool'], 'sshd_effective_value passwordauthentication', '''
sshd_bin_path() { echo fixture_sshd; }
fixture_sshd() { echo 'passwordauthentication yes'; return 1; }
''')
        self.assertEqual(result.stdout.strip(), '')

    def test_timezone_query_failure_has_readonly_fallback(self):
        result = self.shell(['current_timezone'], 'current_timezone', '''
timedatectl() { return 1; }
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip(), result.stderr)

    def info(self, setup=''):
        return self.shell(['linux_info'], 'linux_info', ('''python3() { command python "$@" | tr -d '\\r'; }
''' if os.name == 'nt' else '') + '''
clear() { :; }; send_stats() { :; }
ip_address() { ipv4_address=192.0.2.1; ipv6_address=''; }
lscpu() { echo 'Model name: Fixture CPU'; }
output_status() { rx=0; tx=0; }
current_timezone() { echo UTC; }
system_info_language() { echo en_US.UTF-8; }
for f in ssh ufw docker nginx fail2ban rclone bitwarden; do eval "system_info_$f() { echo fixture; }"; done
ss() { case " $* " in *' -H '*) : ;; *) echo HEADER ;; esac; }
sysctl() { echo fixture; }
curl() {
    echo "$*" > "$WORK/curl-args"
    echo '{"country":"SG","city":"Singapore","org":"AS64500 Test"}'
}
''' + setup)

    def test_compact_geolocation_json_and_bounded_request(self):
        result = self.info()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SG Singapore', result.stdout)
        self.assertIn('AS64500 Test', result.stdout)
        arguments = (self.work / 'curl-args').read_text()
        self.assertIn('https://', arguments)
        self.assertIn('--connect-timeout', arguments)
        self.assertIn('--max-time', arguments)

    def test_socket_counts_do_not_include_header(self):
        result = self.info()
        self.assertRegex(result.stdout, r'TCP\|UDP连接数:\s+0\|0')

    def test_failed_socket_queries_are_not_zero(self):
        result = self.info('ss() { echo partial; return 1; }')
        self.assertRegex(result.stdout, r'TCP\|UDP连接数:\s+未知\|未知')

    def test_missing_arm_frequency_is_explicit(self):
        result = self.info('cat() { case "$1" in /proc/cpuinfo) echo "processor : 0" ;; *) command cat "$@" ;; esac; }')
        self.assertRegex(result.stdout, r'CPU频率:\s+未知')

    def test_failed_geolocation_does_not_parse_error_body(self):
        result = self.info('curl() { echo \'{"country":"US","city":"Error","org":"Bad"}\'; return 22; }')
        self.assertIn('未知 未知', result.stdout)
        self.assertNotIn('US Error', result.stdout)

    def test_invalid_geolocation_is_unknown(self):
        result = self.info('curl() { echo invalid; }')
        self.assertIn('未知 未知', result.stdout)

    def test_geolocation_without_parser_does_not_install_anything(self):
        result = self.info('''
command() { case "$*" in '-v jq'|'-v python3') return 1 ;; *) builtin command "$@" ;; esac; }
install() { echo unexpected-install; return 99; }
''')
        self.assertIn('未知 未知', result.stdout)
        self.assertNotIn('unexpected-install', result.stdout)


if __name__ == '__main__':
    syntax = subprocess.run([BASH, '-n'], input=SOURCE.encode('utf-8'), capture_output=True)
    if syntax.returncode:
        raise SystemExit(syntax.stderr.decode('utf-8'))
    unittest.main()
