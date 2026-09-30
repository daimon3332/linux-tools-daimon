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


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([{(])\n', SOURCE)
    end = SOURCE.index('\n' + ('}' if match[1] == '{' else ')') + '\n\n', match.end())
    return SOURCE[match.start():end + 2]


class Config(unittest.TestCase):
    def setUp(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.tmp', prefix='docker-config.')
        self.work = Path(self.temp.name)
        (self.work / 'docker').mkdir()
        (self.work / 'os-release').write_text('ID=ubuntu\n', encoding='utf-8')
        self.config = self.work / 'docker/daemon.json'
        self.original = '{"log-driver":"local","live-restore":true,"registry-mirrors":["https://old.example"]}\n'
        self.config.write_text(self.original, encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, action, inputs='', extra=''):
        names = ['docker_daemon_json_merge', 'install_add_docker_cn', 'docker_mirror_menu',
                 'linuxmirrors_install_docker', 'docker_ipv6_on', 'docker_ipv6_off']
        if re.search(r'(?m)^docker_config_require_tool\(\)', SOURCE):
            names.insert(0, 'docker_config_require_tool')
        definitions = '\n'.join(function(n) for n in names)
        definitions = definitions.replace('/etc/docker', (self.work/'docker').as_posix())
        definitions = definitions.replace('/etc/os-release', (self.work/'os-release').as_posix())
        definitions = definitions.replace('/run/lock', self.work.as_posix())
        setup = r"""
root_use() { :; }; clear() { :; }; install() { echo dependency >> "$WORK/calls"; return 90; }
enable() { echo enable >> "$WORK/calls"; }
start() { echo start >> "$WORK/calls"; }
restart() { echo restart >> "$WORK/calls"; return "${RESTART_RC:-0}"; }
curl() { echo "${COUNTRY:-SG}"; }
daimon_country() { echo "${COUNTRY:-SG}"; }
daimon_run_cached_script() { echo installer >> "$WORK/calls"; }
dockerd() { echo validate >> "$WORK/calls"; return "${VALIDATE_RC:-0}"; }
systemctl() {
    case "$1" in
        show) echo "${ACTIVE:-active}" ;;
        is-active) [ "${ACTIVE:-active}" = active ] ;;
        restart) echo restart >> "$WORK/calls"; return "${RESTART_RC:-0}" ;;
        *) echo "$*" >> "$WORK/calls"; return 91 ;;
    esac
}
"""
        entry = self.work/'entry.sh'
        entry.write_bytes((definitions+'\n'+setup+'\n'+extra+'\n'+action+'\n').encode())
        p = subprocess.run([BASH, '--noprofile', '--norc', entry.as_posix()], input=inputs.encode(),
                           capture_output=True, timeout=20, env=dict(os.environ, WORK=self.work.as_posix()))
        return p, (self.work/'calls').read_text() if (self.work/'calls').exists() else ''

    def test_foreign_installer_does_not_apply_cn_mirrors(self):
        p, calls = self.invoke('linuxmirrors_install_docker', extra='install_add_docker_cn() { echo CN >> "$WORK/calls"; }')
        self.assertEqual(p.returncode, 0)
        self.assertNotIn('CN', calls)

    def test_cn_installer_propagates_configuration_failure(self):
        p, calls = self.invoke('linuxmirrors_install_docker', extra='COUNTRY=CN; install_add_docker_cn() { return 47; }')
        self.assertNotEqual(p.returncode, 0)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_ubuntu_merge_preserves_unrelated_fields(self):
        p, calls = self.invoke('install_add_docker_cn')
        self.assertEqual(p.returncode, 0, p.stderr)
        result = json.loads(self.config.read_text())
        self.assertEqual(result['log-driver'], 'local')
        self.assertTrue(result['live-restore'])
        self.assertIn('validate', calls)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_failure_restores_bytes_and_permissions(self):
        self.config.chmod(0o600)
        for setting in ['VALIDATE_RC=1', 'RESTART_RC=1']:
            p, _ = self.invoke('install_add_docker_cn', extra=setting)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(self.config.read_text(), self.original)
            self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_inactive_service_not_started_or_enabled(self):
        p, calls = self.invoke('install_add_docker_cn', extra='ACTIVE=inactive')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('start', calls)
        self.assertNotIn('enable', calls)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_invalid_existing_configuration_untouched(self):
        for content in ['', '[]', '{broken', '{}\n{}\n']:
            self.config.write_text(content)
            p, _ = self.invoke('install_add_docker_cn')
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(self.config.read_text(), content)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_links_refused_before_mutation(self):
        other=self.work/'sentinel';other.write_text(self.original)
        self.config.unlink();self.config.symlink_to(other)
        p, _=self.invoke('install_add_docker_cn')
        self.assertNotEqual(p.returncode,0)
        self.assertEqual(other.read_text(),self.original)
        self.assertTrue(self.config.is_symlink())

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_repeated_update_does_not_restart_again(self):
        p, _=self.invoke('install_add_docker_cn')
        self.assertEqual(p.returncode,0,p.stderr)
        (self.work/'calls').unlink()
        p,calls=self.invoke('install_add_docker_cn')
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertNotIn('restart',calls)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_failed_new_config_is_removed(self):
        self.config.unlink()
        p,_=self.invoke('install_add_docker_cn',extra='RESTART_RC=1')
        self.assertNotEqual(p.returncode,0)
        self.assertFalse(self.config.exists())

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_hardlink_is_refused(self):
        other=self.work/'hardlink';os.link(self.config,other)
        p,_=self.invoke('install_add_docker_cn')
        self.assertNotEqual(p.returncode,0)
        self.assertEqual(other.read_text(),self.original)

    def test_invalid_menu_selection_is_atomic(self):
        p,calls=self.invoke('docker_mirror_menu','1 9\n')
        self.assertNotEqual(p.returncode,0)
        self.assertEqual(self.config.read_text(),self.original)
        self.assertEqual(calls,'')

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_editor_failure_or_invalid_json_keeps_original(self):
        for editor in ['return 1', 'printf invalid > "$1"']:
            p,_=self.invoke('docker_daemon_json_merge __edit__',extra='vim() { '+editor+'; }')
            self.assertNotEqual(p.returncode,0)
            self.assertEqual(self.config.read_text(),self.original)

    @unittest.skipUnless(shutil.which('jq') and os.name == 'posix', 'Native jq/POSIX required')
    def test_ipv6_keeps_existing_prefix(self):
        data=json.loads(self.original);data['fixed-cidr-v6']='fd42:1234::/64'
        self.config.write_text(json.dumps(data))
        p,_=self.invoke('docker_ipv6_on')
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(json.loads(self.config.read_text())['fixed-cidr-v6'],data['fixed-cidr-v6'])

    def test_cancel_does_not_install_dependencies(self):
        p, calls=self.invoke('docker_mirror_menu','0\n')
        self.assertEqual(p.returncode,90)
        self.assertEqual(calls,'')

    def test_missing_dependency_reports_failure(self):
        extra = '''
id() { echo 0; }
command() {
    if [ "$1" = -v ] && [ "$2" = jq ]; then return 1; fi
    builtin command "$@"
}
'''
        for action, inputs in [('docker_mirror_menu', '3\n'), ('docker_daemon_json_merge __edit__', '')]:
            with self.subTest(action=action):
                p, calls = self.invoke(action, inputs, extra)
                self.assertNotEqual(p.returncode, 0)
                self.assertIn('jq', p.stderr.decode('utf-8'))
                self.assertEqual(self.config.read_text(), self.original)
                self.assertNotIn('restart', calls)

    def test_successful_installer_without_command_is_not_success(self):
        extra = '''
id() { echo 0; }
install() { return 0; }
command() {
    if [ "$1" = -v ] && [ "$2" = jq ]; then return 1; fi
    builtin command "$@"
}
'''
        p, _ = self.invoke('docker_daemon_json_merge __edit__', extra=extra)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('jq', p.stderr.decode('utf-8'))
        self.assertEqual(self.config.read_text(), self.original)


if __name__ == '__main__':
    unittest.main()
