import os,re,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
BASH=os.environ.get('BASH_BIN','/bin/bash')
def fn(name):
 m=re.search(r'(?m)^'+name+r'\(\) ([{(])\n',SOURCE)
 return SOURCE[m.start():SOURCE.index('\n'+('}' if m[1]=='{' else ')')+'\n\n',m.end())+2]
class Selection(unittest.TestCase):
 def setUp(self):
  (ROOT/'.tmp').mkdir(exist_ok=True);self.temp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp',prefix='retire-selection.');self.work=Path(self.temp.name)
 def tearDown(self):self.temp.cleanup()
 def run_case(self,action,inputs='',extra=''):
  names=re.findall(r'(?m)^(server_retire_[a-z_]+)\(\) [({]',SOURCE)
  body='\n'.join(fn(n) for n in names)+r"""
server_retire_script_items() { for n in a b c; do [ -e "$WORK/$n" ] && printf '%s\ttrue\n' "$WORK/$n"; done; return 0; }
server_retire_update_items() { :; }
docker_compose_update_discover_projects() { :; }
server_retire_nginx_items() { :; }
server_retire_nginx_reload() { echo reload >> "$WORK/calls"; }
server_retire_remove_script() { echo "$1" >> "$WORK/calls"; [ "${FAIL:-}" != "$1" ] || return 41; rm -f -- "$1"; }
DAIMON_SCRIPT_DIR="$WORK/missing"
DAIMON_ROOT_DIR="$WORK/missing"
crontab() { return 1; }
"""+'\n'+extra+'\n'+action+'\n'
  for n in 'abc':(self.work/n).touch()
  entry=self.work/'test.sh';entry.write_bytes(body.encode())
  p=subprocess.run([BASH,entry.as_posix()],input=inputs.encode(),capture_output=True,timeout=15,env=dict(os.environ,WORK=self.work.as_posix()))
  calls=(self.work/'calls').read_text() if (self.work/'calls').exists() else ''
  return p,calls
 def test_duplicate_numbers_cannot_delete_reindexed_item(self):
  p,calls=self.run_case('server_retire_script_menu sync','1 1\ny\n')
  self.assertEqual(p.returncode,0,p.stderr);self.assertFalse((self.work/'a').exists());self.assertTrue((self.work/'b').exists());self.assertEqual(len(calls.splitlines()),1)
 def test_invalid_number_rejects_entire_selection(self):
  p,calls=self.run_case('server_retire_script_menu sync','1 1;d\ny\n')
  self.assertNotEqual(p.returncode,0);self.assertEqual(calls,'');self.assertTrue((self.work/'a').exists())
 def test_failure_cannot_be_hidden_by_later_success(self):
  p,calls=self.run_case('server_retire_apply_tokens_for_prefix A "A1 A2"',extra='FAIL="$WORK/b"')
  self.assertNotEqual(p.returncode,0)
 def test_cancel_is_noop(self):
  p,calls=self.run_case('server_retire_script_menu sync','1\nn\n');self.assertEqual(p.returncode,0);self.assertEqual(calls,'')
 def test_eof_is_noop(self):
  p,calls=self.run_case('server_retire_script_menu sync');self.assertNotEqual(p.returncode,0);self.assertEqual(calls,'')
 def test_bulk_failure_is_returned(self):
  p,calls=self.run_case('server_retire_bulk','A1 A2\nRETIRE\n',extra='FAIL="$WORK/a"');self.assertNotEqual(p.returncode,0)
if __name__=='__main__':unittest.main()
