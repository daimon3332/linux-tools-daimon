import os,re,signal,subprocess,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH=os.environ.get('BASH_BIN','/bin/bash')
def fn(name):
 m=re.search(r'(?m)^'+name+r'\(\) ([{(])\n',SOURCE)
 if not m:return ''
 return SOURCE[m.start():SOURCE.index('\n'+('}' if m[1]=='{' else ')')+'\n\n',m.end())+2]
@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native root/POSIX required')
class Safety(unittest.TestCase):
 def setUp(self):
  (ROOT/'.tmp').mkdir(exist_ok=True);self.temp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp',prefix='retire-safe.');self.work=Path(self.temp.name)
  for n in ['scripts','nginx/sites-available','nginx/sites-enabled','domain/example.test']:(self.work/n).mkdir(parents=True,exist_ok=True)
  self.script=self.work/'scripts/task.sh';self.script.write_text('sleep 30\n')
  self.config=self.work/'nginx/sites-available/site';self.config.write_text('server_name example.test;\n')
  self.link=self.work/'nginx/sites-enabled/site';self.link.symlink_to(self.config)
  self.cert=self.work/'domain/example.test/key';self.cert.write_text('private-fixture')
 def tearDown(self):self.temp.cleanup()
 def invoke(self,action,extra=''):
  names=['server_retire_remove_script','server_retire_script_guard','server_retire_nginx_remove']
  body='\n'.join(fn(n) for n in names)
  for old,new in [('/etc/nginx',str(self.work/'nginx')),('/home/web/conf.d',str(self.work/'conf.d')),('/root/domain',str(self.work/'domain'))]:body=body.replace(old,new)
  body+=r"""
server_retire_sync_dirs() { echo "$WORK/scripts"; }
server_retire_update_dirs() { :; }
server_retire_remove_cron_path() { echo cron >> "$WORK/calls"; return "${CRON_RC:-0}"; }
server_retire_nginx_reload() { echo reload >> "$WORK/calls"; return "${RELOAD_RC:-0}"; }
validate_domain_name() { :; }
DAIMON_SCRIPT_DIR="$WORK/daimon"
DAIMON_ROOT_DIR="$WORK"
"""+'\n'+extra+'\n'+action+'\n'
  entry=self.work/'entry.sh';entry.write_text(body)
  p=subprocess.run([BASH,str(entry)],capture_output=True,timeout=15,env=dict(os.environ,WORK=str(self.work)))
  return p
 def test_script_delete_is_bounded_and_cron_failure_retains_file(self):
  p=self.invoke('server_retire_remove_script "$WORK/scripts/task.sh"','CRON_RC=1');self.assertNotEqual(p.returncode,0);self.assertTrue(self.script.exists())
  p=self.invoke('server_retire_remove_script "$WORK/scripts/task.sh"');self.assertEqual(p.returncode,0,p.stderr);self.assertFalse(self.script.exists())
 def test_hardlink_and_symlink_scripts_are_retained(self):
  other=self.work/'sentinel';os.link(self.script,other)
  p=self.invoke('server_retire_remove_script "$WORK/scripts/task.sh"');self.assertNotEqual(p.returncode,0);self.assertTrue(self.script.exists());other.unlink()
  self.script.unlink();other.write_text('keep');self.script.symlink_to(other)
  p=self.invoke('server_retire_remove_script "$WORK/scripts/task.sh"');self.assertNotEqual(p.returncode,0);self.assertTrue(self.script.is_symlink());self.assertEqual(other.read_text(),'keep')
 def test_running_script_retains_cron_and_file(self):
  process=subprocess.Popen([BASH,str(self.script)],start_new_session=True)
  try:
   time.sleep(0.2);p=self.invoke('server_retire_remove_script "$WORK/scripts/task.sh"');self.assertNotEqual(p.returncode,0);self.assertTrue(self.script.exists());self.assertFalse((self.work/'calls').exists())
  finally:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=5)
 def test_nginx_removal_preserves_certificate(self):
  p=self.invoke('server_retire_nginx_remove "$WORK/nginx/sites-available/site" example.test');self.assertEqual(p.returncode,0,p.stderr);self.assertFalse(self.config.exists());self.assertFalse(self.link.is_symlink());self.assertTrue(self.cert.exists())
 def test_nginx_reload_failure_restores_config_and_link(self):
  p=self.invoke('server_retire_nginx_remove "$WORK/nginx/sites-available/site" example.test','RELOAD_RC=1');self.assertNotEqual(p.returncode,0);self.assertTrue(self.config.exists());self.assertTrue(self.link.is_symlink());self.assertTrue(self.cert.exists())
 def test_nginx_path_escape_is_rejected(self):
  p=self.invoke('server_retire_nginx_remove "$WORK/nginx/sites-available/../../domain/example.test/key" example.test');self.assertNotEqual(p.returncode,0);self.assertTrue(self.cert.exists())
if __name__=='__main__':unittest.main()
