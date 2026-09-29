import os,re,subprocess,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
class Retirement(unittest.TestCase):
    def test_never_uses_force_or_compose_down(self):
        m=re.search(r'(?m)^server_retire_compose_stop\(\) \{\n',SOURCE)
        body=SOURCE[m.start():SOURCE.index('\n}\n',m.end())+2]
        self.assertNotIn('docker rm -f',body)
        self.assertNotIn(' down ',body)
    def execute(self, conflicting=False, fail_stop=False, fail_query=False, change_members=False):
        import json
        body=SOURCE.split("<<'PYRETIRE_COMPOSE'\n",1)[1].split('\nPYRETIRE_COMPOSE',1)[0]
        scope={'__name__':'fixture'};exec(compile(body,'retire','exec'),scope)
        ids=['a'*64,'b'*64];actions=[];queries=0
        running={x:True for x in ids}
        def command(*args):
            nonlocal queries
            if args[0]=='ps':
                queries+=1
                if fail_query:raise ValueError('query failed')
                return '\n'.join(ids if not(change_members and queries>1) else ids[:1])
            if args[0]=='inspect':
                x=args[-1]
                labels={'com.docker.compose.project':'fixture','com.docker.compose.project.working_dir':'/missing',
                        'com.docker.compose.project.config_files':'/missing/compose.yaml'}
                if conflicting and x==ids[1]:labels['com.docker.compose.project.working_dir']='/business'
                return json.dumps([{'Id':x,'Config':{'Labels':labels},'State':{'Running':running[x]}}])
            actions.append(args)
            if args[0]=='stop':
                if fail_stop:raise ValueError('stop failed')
                running[args[-1]]=False
            return ''
        scope['command']=command
        error=None
        try:scope['main']('fixture','/missing','/missing/compose.yaml')
        except ValueError as e:error=e
        return actions,error
    def test_exact_ids_stop_before_nonforce_removal(self):
        actions,error=self.execute();self.assertIsNone(error)
        self.assertEqual(actions,[('stop','--time','30','a'*64),('rm','a'*64),('stop','--time','30','b'*64),('rm','b'*64)])
    def test_conflicting_context_rejected_before_any_stop(self):
        actions,error=self.execute(conflicting=True);self.assertIsNotNone(error);self.assertEqual(actions,[])
    def test_query_failure_has_no_actions(self):
        actions,error=self.execute(fail_query=True);self.assertIsNotNone(error);self.assertEqual(actions,[])
    def test_changed_membership_has_no_actions(self):
        actions,error=self.execute(change_members=True);self.assertIsNotNone(error);self.assertEqual(actions,[])
    def test_stop_failure_does_not_remove(self):
        actions,error=self.execute(fail_stop=True);self.assertIsNotNone(error);self.assertEqual(len(actions),1)

if __name__=='__main__':unittest.main()
