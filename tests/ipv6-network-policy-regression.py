from source import read_source
import json,os,re,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=read_source(ROOT)
BASH=os.environ.get('BASH_BIN','/bin/bash')
@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native POSIX/root required')
class Policy(unittest.TestCase):
 def setUp(self):
  (ROOT/'.tmp').mkdir(exist_ok=True);self.temp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp',prefix='network-policy.');self.work=Path(self.temp.name)
  for d in ['usr/lib/systemd/network','usr/local/lib/systemd/network','run/systemd/network','etc/systemd/network','sys/class/net/eth0','bin','plan']:(self.work/d).mkdir(parents=True)
  self.main=self.work/'run/systemd/network/10-netplan-eth0.network'
  self.main.write_text('[Match]\nName=eth0\n[Network]\nDHCP=yes\nLinkLocalAddressing=yes\n')
  self.target=self.work/'etc/systemd/network/10-netplan-eth0.network.d/99-daimon-ipv6.conf'
  for name,body in {'systemctl':'[ "${MANAGER:-networkd}" = networkd ] && [ "${3:-}" != NetworkManager ]',
   'networkctl':'if [ "$1" = status ]; then echo "Network File: $WORK/run/systemd/network/10-netplan-eth0.network"; else echo "$*" >> "$WORK/calls"; [ "${APPLY_FAIL:-0}" = 0 ]; fi'}.items():
   f=self.work/'bin'/name;f.write_text('#!/bin/sh\n'+body+'\n');f.chmod(0o755)
  m=re.search(r'(?m)^daimon_ipv6_network_policy\(\) \{\n',SOURCE)
  body=SOURCE[m.start():SOURCE.index('\n}\n\n',m.end())+2]
  for path in ['/usr/lib/systemd/network','/usr/local/lib/systemd/network','/run/systemd/network','/etc/systemd/network','/sys/class/net']:body=body.replace(path,str(self.work)+path)
  self.entry=self.work/'entry.sh';self.entry.write_text(body+'\ndaimon_ipv6_network_policy "$@"\n')
 def tearDown(self):self.temp.cleanup()
 def invoke(self,action,value='1',**env):return subprocess.run([BASH,str(self.entry),action,str(self.work/'plan'),value],capture_output=True,timeout=15,env=dict(os.environ,WORK=str(self.work),PATH=str(self.work/'bin')+':'+os.environ['PATH'],**env))
 def test_preserves_ipv4_and_restores_owned_policy(self):
  original=self.main.read_bytes();self.assertEqual(self.invoke('plan').returncode,0)
  self.assertEqual(self.invoke('apply').returncode,0);text=self.target.read_text();self.assertIn('DHCP=ipv4',text);self.assertIn('LinkLocalAddressing=ipv4',text);self.assertIn('IPv6AcceptRA=no',text)
  self.assertEqual(self.main.read_bytes(),original);self.assertEqual(self.invoke('restore').returncode,0);self.assertFalse(self.target.exists())
 def test_enable_removes_only_owned_override(self):
  self.assertEqual(self.invoke('plan').returncode,0);self.assertEqual(self.invoke('apply').returncode,0)
  self.assertEqual(self.invoke('plan','0').returncode,0);self.assertEqual(self.invoke('apply','0').returncode,0);self.assertFalse(self.target.exists())
 def test_static_ipv6_refused(self):
  with self.main.open('a') as f:f.write('Address=2001:db8::1/64\n')
  self.assertNotEqual(self.invoke('plan').returncode,0);self.assertFalse(self.target.exists())
 def test_unknown_manager_refused(self):
  self.assertNotEqual(self.invoke('plan',MANAGER='unknown').returncode,0);self.assertFalse(self.target.exists())
 def test_foreign_override_refused(self):
  self.target.parent.mkdir();self.target.write_text('[Network]\nDHCP=no\n')
  self.assertNotEqual(self.invoke('plan').returncode,0);self.assertEqual(self.target.read_text(),'[Network]\nDHCP=no\n')
 def test_competing_dropin_refused(self):
  self.target.parent.mkdir();(self.target.parent/'other.conf').write_text('[Network]\nDHCP=no\n')
  self.assertNotEqual(self.invoke('plan').returncode,0);self.assertFalse(self.target.exists())
 def test_changed_source_refused_before_writes(self):
  self.assertEqual(self.invoke('plan').returncode,0);self.main.write_text('[Network]\nDHCP=ipv4\n')
  self.assertNotEqual(self.invoke('apply').returncode,0);self.assertFalse(self.target.exists())
 def test_failed_apply_can_restore_policy(self):
  self.assertEqual(self.invoke('plan').returncode,0);self.assertNotEqual(self.invoke('apply',APPLY_FAIL='1').returncode,0)
  self.assertEqual(self.invoke('restore').returncode,0);self.assertFalse(self.target.exists())
 def test_symlink_override_is_refused(self):
  self.target.parent.mkdir();self.target.symlink_to(self.main)
  self.assertNotEqual(self.invoke('plan').returncode,0);self.assertTrue(self.target.is_symlink())
if __name__=='__main__':unittest.main()
