import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH = os.environ.get('BASH_BIN', '/bin/bash')


def function(name):
    match = re.search(r'(?m)^' + name + r'\(\) ([{(])\n', SOURCE)
    closing = '}' if match[1] == '{' else ')'
    return SOURCE[match.start():SOURCE.index('\n' + closing, match.end())+2]


class Users(unittest.TestCase):
    def setUp(self):
        (ROOT/'.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT/'.tmp', prefix='users.')
        self.work = Path(self.temp.name)
        for name in ['etc/sudoers.d', 'home', 'srv/alice', 'managed']:
            (self.work/name).mkdir(parents=True, exist_ok=True)
        (self.work/'etc/sudoers').write_bytes(b'root ALL=(ALL:ALL) ALL\n')
        (self.work/'etc/passwd').write_bytes(b'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:100::/srv/alice:/bin/bash\n')
        (self.work/'groups').write_bytes(b'users\n')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, action, inputs='', failure=''):
        names=['create_user_with_sshkey', 'linux_Settings', 'daimon_regular_user_valid']
        for name in ['daimon_user_sudo', 'daimon_user_home', 'daimon_user_has_sudo_rules', 'daimon_config_commit']:
            if re.search(r'(?m)^'+name+r'\(\)', SOURCE): names.append(name)
        body='\n'.join(function(n) for n in names)
        for prefix in ['/etc/', '/home/']:
            body=body.replace(prefix, self.work.as_posix()+prefix)
        body+='''
root_use() { :; }; clear() { :; }; send_stats() { :; }; break_end() { :; }
install() { [ "$FAILURE" != install ]; }
id() {
    local user="${@: -1}"
    case "$1" in
        -u) [ "$user" != root ] && echo 1000 || echo 0 ;;
        -g) echo 100 ;;
        -gn) echo users ;;
        -nG) cat "$WORK/groups" ;;
        *) [ "$user" = alice ] || [ "$user" = root ] ;;
    esac
}
getent() {
    case "$1:$2" in
        passwd:alice) printf 'alice:x:1000:100::%s:/bin/bash\\n' "$(cd "$WORK/srv/alice" && pwd)" ;;
        group:sudo) echo sudo:x:27: ;;
        *) return 1 ;;
    esac
}
stat() {
    if [ "$1" = -c ] && [ "$2" = %u ]; then echo 1000; else command stat "$@"; fi
}
chown() { :; }
groups() { echo "$1 : users"; }
usermod() { [ "$FAILURE" != usermod ] || return 1; echo 'users sudo' > "$WORK/groups"; }
gpasswd() { echo users > "$WORK/groups"; }
sudo() {
    if [ "$FAILURE" = not-allowed ]; then echo 'User alice is not allowed to run sudo on audit-host.'; return 0; fi
    if grep -q '^alice ' "$WORK/etc/sudoers" || [ -f "$WORK/etc/sudoers.d/alice" ]; then echo '(ALL : ALL) NOPASSWD: ALL'; else return 1; fi
}
visudo() { [ "$FAILURE" != syntax ]; }
ssh_public_key_valid() { [ "$1" = 'ecdsa-sha2-nistp256 VALID' ]; }
import_sshkey() { ssh_public_key_valid "$1" || return 1; echo "$2" > "$WORK/import-home"; }
fetch_remote_ssh_keys() { return 1; }
runuser() { shift 3; command "$@"; }
'''
        if os.name=='nt': body+='flock() { :; }\n'
        body+=action+'\n'
        script=self.work/'entry.sh';script.write_bytes(body.encode())
        return subprocess.run([BASH,'--noprofile','--norc',script.as_posix()],input=inputs.encode(),capture_output=True,timeout=15,
                              env=dict(os.environ,WORK=self.work.as_posix(),DAIMON_ROOT_DIR=(self.work/'managed').as_posix(),FAILURE=failure))

    def test_create_existing_system_account_is_rejected(self):
        result=self.shell('create_user_with_sshkey root true','\n')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.work/'etc/sudoers.d/root').exists())

    def test_invalid_key_is_not_written(self):
        result=self.shell('create_user_with_sshkey alice false','ssh-ed25519 invalid-key\n')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.work/'home/alice/.ssh/authorized_keys').exists())
        self.assertFalse((self.work/'import-home').exists())

    def test_valid_ecdsa_uses_actual_home(self):
        result=self.shell('create_user_with_sshkey alice false','ecdsa-sha2-nistp256 VALID\n')
        self.assertEqual(result.returncode,0,result.stderr.decode())
        expected=subprocess.check_output([BASH,'-c','cd "$1" && pwd','bash',(self.work/'srv/alice').as_posix()],text=True).strip()
        self.assertEqual((self.work/'import-home').read_text().strip(),expected)

    def test_sudo_install_failure_does_not_grant(self):
        result=self.shell('create_user_with_sshkey alice true','\n','install')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.work/'etc/sudoers.d/alice').exists())
        self.assertEqual((self.work/'groups').read_bytes(),b'users\n')

    def test_sudo_revoke_removes_all_all_direct_rule(self):
        path=self.work/'etc/sudoers'
        path.write_bytes(path.read_bytes()+b'alice ALL=(ALL:ALL) NOPASSWD:ALL\n')
        result=self.shell('linux_Settings','6\n4\nalice\n0\n0\n')
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertNotIn(b'alice ',path.read_bytes())
        self.assertIn(b'root ALL=(ALL:ALL) ALL',path.read_bytes())

    def test_user_list_detects_all_all_sudo_rule(self):
        path=self.work/'etc/sudoers'
        path.write_bytes(path.read_bytes()+b'alice ALL=(ALL:ALL) NOPASSWD:ALL\n')
        result=self.shell('linux_Settings','6\n0\n0\n')
        self.assertRegex(result.stdout.decode(),r'(?m)^alice[^\n]+Yes\s*$')

    def test_user_list_does_not_treat_zero_exit_denial_as_permission(self):
        result=self.shell('linux_Settings','6\n0\n0\n','not-allowed')
        self.assertRegex(result.stdout.decode(),r'(?m)^alice[^\n]+No\s*$')

    def test_revoke_does_not_report_remaining_rules_for_zero_exit_denial(self):
        result=self.shell('daimon_user_sudo revoke alice',failure='not-allowed')
        self.assertEqual(result.returncode,0,result.stdout.decode())

    def test_sudo_group_failure_restores_existing_grant(self):
        path=self.work/'etc/sudoers.d/alice'
        path.write_bytes(b'alice ALL=(ALL) /usr/bin/true\n')
        before=path.read_bytes()
        result=self.shell('daimon_user_sudo grant alice',failure='usermod')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(path.read_bytes(),before)
        self.assertEqual((self.work/'groups').read_bytes(),b'users\n')

    def test_sudo_syntax_failure_preserves_configuration(self):
        before=(self.work/'etc/sudoers').read_bytes()
        result=self.shell('daimon_user_sudo grant alice',failure='syntax')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.work/'etc/sudoers').read_bytes(),before)
        self.assertFalse((self.work/'etc/sudoers.d/alice').exists())
        self.assertEqual((self.work/'groups').read_bytes(),b'users\n')

    def test_sudo_grant_preserves_other_users_rules(self):
        path=self.work/'etc/sudoers.d/alice'
        for content in [b'bob ALL=(ALL) ALL\n',b'#includedir /other/policy\n']:
            path.write_bytes(content)
            result=self.shell('daimon_user_sudo grant alice')
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(path.read_bytes(),content)
            self.assertEqual((self.work/'groups').read_bytes(),b'users\n')

    @unittest.skipIf(os.name=='nt','POSIX symlink fixture')
    def test_sudo_grant_rejects_symlink(self):
        target=self.work/'unrelated';target.write_bytes(b'keep')
        (self.work/'etc/sudoers.d/alice').symlink_to(target)
        self.shell('linux_Settings','6\n3\nalice\n0\n0\n')
        self.assertEqual(target.read_bytes(),b'keep')
        self.assertEqual((self.work/'groups').read_bytes(),b'users\n')


if __name__=='__main__':
    unittest.main()
