#!/usr/bin/env python3
"""Exercise actual menu completion in a PTY, isolating installer side effects."""
import os
import pathlib
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = pathlib.Path(os.environ.get('DAIMON_TEST_SOURCE', pathlib.Path(__file__).resolve().parents[1] / 'linux-toolbox.sh')).read_text(encoding='utf-8')


def function(name):
    match = re.search(r'(?m)^([ \t]*)' + re.escape(name) + r'\(\) \{\n', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    following = {'linux_tools':'linux_bbr', 'one_click_install_docker_auto':'daimon_network_cleanup_old_qdisc_service'}
    if name in following:
        return SOURCE[match.start():SOURCE.index('\n'+following[name]+'() {',match.end())].rstrip()
    end = SOURCE.index('\n' + match[1] + '}', match.end())
    return SOURCE[match.start():end + len(match[1]) + 2]


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux PTY and installer fixtures')
class OneClick(unittest.TestCase):
    def setUp(self):
        base = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base, prefix='one-click.')
        self.work = pathlib.Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def terminal(self, selection='9 10', failure='', menu='1'):
        import pty
        tools = function('linux_tools')
        tools = tools.replace(function('install_tool_by_id'), '''  install_tool_by_id() {
    echo "INSTALL:$1"
    [ "$1" != "${FAIL_TOOL:-}" ]
  }''')
        tools = tools.replace(function('tool_installed'), '  tool_installed() { return 0; }')
        bins = self.work/'bin'
        bins.mkdir(exist_ok=True)
        shim = bins/'bash'
        shim.write_text('#!/bin/sh\nexec /bin/bash --noprofile --rcfile "$FIXTURE/rc" -i\n')
        shim.chmod(0o700)
        (self.work/'rc').write_text('printf "SHELL_READY:%s\\n" "$$"\nexit 0\n')
        setup = '''clear() { :; }
root_use() { :; }
send_stats() { :; }
daimon_country() { echo CN; }
one_click_set_timezone_locale() { echo TIMEZONE; }
linux_update() { echo UPDATE; break_end; }
linux_clean() { echo CLEAN; }
add_swap() { echo SWAP; }
one_click_auto_dns_optimize() { echo DNS; }
one_click_enable_bbr_fq() { echo BBR; }
one_click_install_docker_auto() { echo DOCKER; }
one_click_network_auto_optimize() { echo NETWORK; }
'''
        script = self.work/'menu.sh'
        script.write_text(setup + function('break_end') + '\n' + tools + '\n' + function('one_click_config_manager') + '\none_click_config_manager\n')
        subprocess.run(['/bin/bash','-n',str(script)],check=True,capture_output=True)
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(FIXTURE=str(self.work), FAIL_TOOL=failure, TERM='xterm', PATH=str(bins)+':'+os.environ['PATH'])
            os.execv('/bin/bash', ['/bin/bash', '--noprofile', '--norc', str(script)])
        output = bytearray()
        status = None
        stage = 0
        try:
            until = time.monotonic() + 12
            while time.monotonic() < until:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output.extend(data)
                    text = output.decode(errors='replace')
                    if stage == 0 and '请输入你的选择（默认 1 配置全部）:' in text:
                        os.write(fd, menu.encode()+b'\n')
                        stage = 1
                    if stage == 1 and '请确认/修改要执行的配置编号' in text:
                        os.write(fd, b'\x15'+selection.encode()+b'\n')
                        stage = 2
                    if stage == 2 and text.count('请输入你的选择（默认 1 配置全部）:') > 1:
                        os.write(fd, b'0\n')
                        stage = 3
                    if '按任意键继续' in text:
                        break
                exited, code = os.waitpid(pid, os.WNOHANG)
                if exited:
                    status = code
                    break
            if status is None:
                exited, status = os.waitpid(pid, os.WNOHANG)
                if not exited:
                    os.kill(pid, signal.SIGTERM)
                    _, status = os.waitpid(pid, 0)
        finally:
            os.close(fd)
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace'), pid

    def test_batch_reaches_timezone_and_execs_same_process(self):
        rc, text, pid = self.terminal()
        self.assertEqual(rc, 0, text)
        self.assertEqual(text.count('INSTALL:'), 15, text)
        self.assertNotIn('按任意键继续', text)
        self.assertLess(text.index('INSTALL:iperf3'), text.index('TIMEZONE'))
        self.assertLess(text.index('TIMEZONE'), text.index('SHELL_READY:'))
        self.assertEqual(text.count('SHELL_READY:'), 1)
        self.assertIn('SHELL_READY:'+str(pid), text)

    def test_failed_tool_still_runs_later_steps_and_reports_failure(self):
        rc, text, pid = self.terminal(failure='bat')
        self.assertEqual(rc, 0, text)
        self.assertIn('工具安装或验证失败: bat', text)
        self.assertIn('失败配置项: 9', text)
        self.assertIn('TIMEZONE', text)
        self.assertIn('SHELL_READY:'+str(pid), text)
        self.assertNotIn('全部配置成功', text)

    def test_nested_pause_is_suppressed_and_no_tool_selection_still_finishes(self):
        rc, text, pid = self.terminal('2 10')
        self.assertEqual(rc, 0, text)
        self.assertNotIn('按任意键继续', text)
        self.assertIn('SHELL_READY:'+str(pid), text)

    def test_invalid_selection_executes_nothing(self):
        _, text, _ = self.terminal('2 typo 10')
        self.assertNotIn('UPDATE', text)
        self.assertNotIn('TIMEZONE', text)
        self.assertNotIn('SHELL_READY:', text)

    def test_cancel_and_empty_selection_make_no_changes(self):
        for selection in ('', '0', '   '):
            with self.subTest(selection=selection):
                rc, text, _ = self.terminal(selection)
                self.assertEqual(rc,0,text)
                self.assertNotIn('INSTALL:',text)
                self.assertNotIn('SHELL_READY:',text)

    def test_direct_tool_option_reports_failure_before_exec(self):
        rc,text,pid=self.terminal(menu='9',failure='bat')
        self.assertEqual(rc,0,text)
        self.assertIn('失败配置项: 9',text)
        self.assertIn('SHELL_READY:'+str(pid),text)

    def test_full_batch_normalizes_and_deduplicates_selection(self):
        rc,text,pid=self.terminal('2 3 4 5 6 7 8 09 9 10')
        self.assertEqual(rc,0,text)
        self.assertEqual(text.count('INSTALL:'),15,text)
        self.assertIn('全部配置成功',text)
        self.assertIn('SHELL_READY:'+str(pid),text)

    def shell(self, names, setup, command):
        return subprocess.run(['/bin/bash', '-c', '\n'.join(function(name) for name in names)+'\n'+setup+'\n'+command],
                              cwd=self.work, capture_output=True, text=True, timeout=10)

    def test_dns_failure_reaches_caller(self):
        for region in ('CN','HK'):
            result = self.shell(['one_click_auto_dns_optimize'], 'root_use() { :; }; daimon_country() { echo '+region+'; }; set_dns() { return 42; }; send_stats() { :; }', 'one_click_auto_dns_optimize')
            self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_timezone_and_locale_failures_are_not_success(self):
        for name in ('set_timedate', 'update_locale'):
            setup = 'root_use() { :; }; send_stats() { :; }; set_timedate() { :; }; update_locale() { :; }; '+name+'() { return 42; }'
            result = self.shell(['one_click_set_timezone_locale'], setup, 'one_click_set_timezone_locale')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn('已设置时区', result.stdout)

    def test_docker_installer_failure_does_not_run_followup(self):
        setup = 'root_use() { :; }; install() { :; }; command() { if [ "$*" = "-v docker" ]; then return 1; fi; builtin command "$@"; }; daimon_country() { echo CN; }; curl() { echo CN; }; bash() { return 42; }; install_add_docker_cn() { echo FOLLOWUP; }; DAIMON_SCRIPT_DIR='+str(self.work)
        result = self.shell(['one_click_install_docker_auto'], setup, 'one_click_install_docker_auto')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('FOLLOWUP', result.stdout)

    def test_existing_docker_is_verified_without_reinstall(self):
        for broken in ('0','1'):
            setup='root_use() { :; }; install() { echo REINSTALL; }; docker() { return '+broken+'; }; install_add_docker_cn() { echo RECONFIGURE; }; DAIMON_SCRIPT_DIR='+str(self.work)
            result=self.shell(['one_click_install_docker_auto'],setup,'one_click_install_docker_auto')
            self.assertEqual(result.returncode,int(broken),result.stdout+result.stderr)
            self.assertNotIn('REINSTALL',result.stdout)
            self.assertNotIn('RECONFIGURE',result.stdout)

    def test_new_docker_uses_region_and_keeps_foreign_mirrors_untouched(self):
        for region,mirror in (('CN','1'),('HK','2'),('ES','2')):
            setup='root_use() { :; }; install() { :; }; command() { if [ "$*" = "-v docker" ]; then return 1; fi; builtin command "$@"; }; daimon_country() { echo '+region+'; }; bash() { echo "INSTALL_MIRROR:$2"; }; docker() { :; }; install_add_docker_cn() { echo FOLLOWUP; }; DAIMON_SCRIPT_DIR='+str(self.work)
            result=self.shell(['one_click_install_docker_auto'],setup,'one_click_install_docker_auto')
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('INSTALL_MIRROR:'+mirror,result.stdout)
            if region!='CN': self.assertNotIn('FOLLOWUP',result.stdout)

    def test_dns_write_failure_is_not_masked_by_chattr(self):
        script=function('set_dns').replace('/etc/resolv.conf',str(self.work))
        setup='ip_address() { ipv4_address=192.0.2.1; ipv6_address=""; }; chattr() { return 0; }; dns1_ipv4=1.1.1.1; dns2_ipv4=8.8.8.8; '
        result=subprocess.run(['/bin/bash','-c',script+'\n'+setup+'set_dns'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)

    def test_locale_failures_do_not_overwrite_active_setting(self):
        os_release=self.work/'os-release';os_release.write_text('ID=ubuntu\n')
        default=self.work/'locale';default.write_text('LANG=original\n')
        generated=self.work/'locale.gen';generated.write_text('# en_US.UTF-8 UTF-8\n')
        script=function('update_locale').replace('/etc/os-release',str(os_release)).replace('/etc/default/locale',str(default)).replace('/etc/locale.gen',str(generated))
        for install_rc,generate_rc in ((42,0),(0,42)):
            setup='install() { return '+str(install_rc)+'; }; locale-gen() { return '+str(generate_rc)+'; }; '
            result=subprocess.run(['/bin/bash','-c',script+'\n'+setup+'update_locale en_US.UTF-8 en_US.UTF-8 false'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,result.stdout)
            self.assertEqual(default.read_text(),'LANG=original\n')
            self.assertNotIn('系统语言已经修改',result.stdout)
        os_release.write_text('ID=unsupported\n')
        result=subprocess.run(['/bin/bash','-c',script+'\nupdate_locale en_US.UTF-8 en_US.UTF-8 false'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0,result.stdout)

    def test_rhel_locale_selects_requested_language_pack(self):
        release=self.work/'os-release';release.write_text('ID=fedora\n')
        config=self.work/'locale.conf'
        script=function('update_locale').replace('/etc/os-release',str(release)).replace('/etc/locale.conf',str(config))
        setup='install() { echo "PACKAGE:$1"; }; localectl() { return 0; }; '
        result=subprocess.run(['/bin/bash','-c',script+'\n'+setup+'update_locale en_US.UTF-8 en_US.UTF-8 false'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PACKAGE:glibc-langpack-en',result.stdout)
        self.assertEqual(config.read_text(),'LANG=en_US.UTF-8\n')

    def test_update_failure_and_unsupported_manager_are_reported(self):
        for available in ('zypper','none'):
            setup='command() { [ "$1" = -v ] && [ "$2" = '+available+' ]; }; zypper() { echo "ZYPPER:$1"; [ "$1" != refresh ]; }; '
            result=self.shell(['linux_update'],setup,'linux_update')
            self.assertNotEqual(result.returncode,0,result.stdout)
            self.assertNotIn('ZYPPER:update',result.stdout)


if __name__ == '__main__':
    unittest.main()
