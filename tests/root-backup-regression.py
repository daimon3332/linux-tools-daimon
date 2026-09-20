#!/usr/bin/env python3
"""Exercise the generated root task without stopping production containers."""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import json
import time

SOURCE = pathlib.Path(os.environ.get('DAIMON_TEST_SOURCE', pathlib.Path(__file__).resolve().parents[1] / 'linux-toolbox.sh')).read_text(encoding='utf-8')


def function(name):
    match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
    if not match:
        raise AssertionError('Missing function: ' + name)
    return match.group()


class Recovery(unittest.TestCase):
    def test_application_first_does_not_block_database_start(self):
        script = r'''
set -o pipefail
TASK_KIND=root
OWNS_STATE=1
STATE_FILE=/dev/fd/3
SECONDS=0
app_running=false db_running=false
container_state() {
 case "$1" in
 app) if [ "$app_running" = false ]; then echo 'false none'; elif [ "$db_running" = false ]; then echo 'true starting'; else echo 'true healthy'; fi ;;
 db) echo "$db_running none" ;;
 esac
}
timeout() {
 case "$*" in
 '60s docker start app') app_running=true; echo START_APP ;;
 '60s docker start db') db_running=true; echo START_DB ;;
 *) return 1 ;;
 esac
}
sleep() { SECONDS=$((SECONDS+60)); }
rm() { :; }
'''
        script += function('container_recovery_timeout') + '\n' + function('recover_writers') + '\nrecover_writers 3<<<$\'app\\ndb\'\nrc=$?\ncat "$LOG_FILE"\nexit "$rc"\n'
        binary = os.environ.get('BASH_BIN', 'bash')
        root = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root, prefix='root-recovery.') as work:
            env = dict(os.environ, LOG_FILE=pathlib.Path(work, 'test.log').as_posix())
            result = subprocess.run([binary, '-s'], input=script, text=True, encoding='utf-8', capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'POSIX Python helper')
    def test_health_budget_includes_start_period_and_retries(self):
        script='timeout() { echo "180000000000 15000000000 5000000000 8"; }\n'+function('container_recovery_timeout')+'\ncontainer_recovery_timeout fixture\n'
        result=subprocess.run(['bash','-s'],input=script,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'370')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'POSIX Python helper')
    def test_health_budget_is_bounded_and_override_is_respected(self):
        script='timeout() { echo "7200000000000 15000000000 5000000000 8"; }\n'+function('container_recovery_timeout')+'\ncontainer_recovery_timeout fixture\nDAIMON_RECOVERY_TIMEOUT=900 container_recovery_timeout fixture\n'
        result=subprocess.run(['bash','-s'],input=script,capture_output=True,text=True)
        self.assertEqual(result.stdout.split(),['3600','900'])


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux filesystem/log integration tests')
class LogPolicy(unittest.TestCase):
    def setUp(self):
        root = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        root.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=root, prefix='root-policy.')
        self.work = pathlib.Path(self.directory.name)
        self.runs = self.work / 'runs'
        self.runs.mkdir()
        self.cache = self.work / 'status.tsv'
        self.active = self.runs / '20260920-010101-123-root.log'
        self.env = dict(os.environ, DAIMON_LOG_FILE_BYTES='8192', DAIMON_LOG_TOTAL_BYTES='32768',
                        DAIMON_LOG_MIN_FREE_BYTES='1', DAIMON_LOG_MIN_FREE_INODES='1')

    def tearDown(self):
        self.directory.cleanup()

    def policy(self, mode='prepare', env=None):
        script = function('log_policy') + '\nlog_policy "$@"\n'
        return subprocess.run(['bash', '-c', script, 'policy', mode, str(self.runs), str(self.cache), str(self.active)],
                              env=env or self.env, capture_output=True, text=True)

    def test_space_failure_prevents_log_creation(self):
        result = self.policy(env=dict(self.env, DAIMON_LOG_MIN_FREE_BYTES=str(2**62)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.active.exists())

    def test_inode_failure_prevents_log_creation(self):
        result = self.policy(env=dict(self.env, DAIMON_LOG_MIN_FREE_INODES=str(2**62)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.active.exists())

    def test_retention_removes_only_owned_inactive_logs(self):
        stale = self.runs / '20200101-010101-456-root.log'
        stale.write_bytes(b'x' * 40000)
        unrelated = self.runs / 'business.log'
        unrelated.write_text('keep')
        result = self.policy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        self.assertEqual(unrelated.read_text(), 'keep')

    def test_active_log_is_never_removed_for_budget(self):
        import fcntl
        protected = self.runs / '20260920-010101-789-root.log'
        protected.write_bytes(b'x' * 40000)
        with protected.open('rb') as fd:
            fcntl.flock(fd, fcntl.LOCK_EX)
            result = self.policy()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(protected.exists())

    def test_symlink_is_rejected(self):
        protected = self.work / 'protected'
        protected.write_text('keep')
        self.active.symlink_to(protected)
        self.assertNotEqual(self.policy().returncode, 0)
        self.assertEqual(protected.read_text(), 'keep')

    def test_monitor_bounds_current_log_without_orphans(self):
        self.assertEqual(self.policy().returncode, 0)
        script = function('log_policy') + '\nlog_policy "$@"\n'
        proc = subprocess.Popen(['bash', '-c', script, 'policy', 'monitor', str(self.runs), str(self.cache),
                                 str(self.active), str(os.getpid())], env=self.env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        try:
            with self.active.open('ab') as out:
                out.write(b'content\n' * 3000)
            deadline = time.monotonic() + 5
            while self.active.stat().st_size > 8192 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertLessEqual(self.active.stat().st_size, 8192)
            self.assertIn('LOG_ROTATED', self.active.read_text())
        finally:
            proc.terminate()
            proc.wait(timeout=5)
            proc.stderr.close()

    def test_readonly_log_mount_rejects_start(self):
        if os.geteuid() != 0:
            self.skipTest('private mount namespace requires root')
        script = 'set -e\nmount -t tmpfs -o size=1m tmpfs "$1"\nmount -o remount,ro "$1"\n'
        script += function('log_policy') + '\nif log_policy prepare "$1" "$2" "$3"; then exit 90; fi\n'
        result = subprocess.run(['unshare','--mount','--propagation','private','bash','-c',script,'test',
                                 str(self.runs),str(self.cache),str(self.active)],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_full_log_mount_rejects_start(self):
        if os.geteuid() != 0:
            self.skipTest('private mount namespace requires root')
        script = 'set -e\nmount -t tmpfs -o size=16k tmpfs "$1"\ndd if=/dev/zero of="$1/business.bin" bs=4096 count=4 status=none\n'
        script += function('log_policy') + '\nif log_policy prepare "$1" "$2" "$3"; then exit 90; fi\ntest -f "$1/business.bin"\n'
        result = subprocess.run(['unshare','--mount','--propagation','private','bash','-c',script,'test',
                                 str(self.runs),str(self.cache),str(self.active)],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_runtime_full_log_cancels_task_and_runs_recovery(self):
        if os.geteuid() != 0:
            self.skipTest('private mount namespace requires root')
        start=SOURCE.index('#!/bin/bash\nset -u\nTASK="${1:-custom}"')
        runner=self.work/'runner.sh'
        runner.write_text(SOURCE[start:SOURCE.index('\nEOF\n',start)])
        worker=self.work/'worker.sh'
        worker.write_text('#!/bin/bash\ntrap \'touch "$TEST_WORK/recovered"; exit 143\' TERM\ntouch "$TEST_WORK/ready"\nwhile :; do sleep 0.1; done\n')
        worker.chmod(0o700)
        env=dict(self.env,TEST_WORK=str(self.work),DAIMON_RCLONE_RUN_LOG_DIR=str(self.runs),
                 DAIMON_RCLONE_STATUS_CACHE=str(self.cache),DAIMON_RCLONE_STATUS_LOCK=str(self.work/'status.lock'))
        script=r'''set -u
mount -t tmpfs -o size=1m tmpfs "$1" || exit 1
bash "$2" fixture "$3" > "$TEST_WORK/runner-output" 2>&1 & task=$!
for ((i=0;i<100;i++)); do test ! -e "$TEST_WORK/ready" || break; sleep 0.05; done
test -e "$TEST_WORK/ready" || { kill "$task"; exit 1; }
dd if=/dev/zero of="$1/business.bin" bs=4096 count=256 status=none 2>/dev/null || true
wait "$task"; result=$?
test "$result" = 74 && test -e "$TEST_WORK/recovered"
'''
        result=subprocess.run(['unshare','--mount','--propagation','private','bash','-c',script,'test',
                               str(self.runs),str(runner),str(worker)],env=env,capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr+(self.work/'runner-output').read_text())


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux disk checks')
class Space(unittest.TestCase):
    def test_root_work_space_failure(self):
        env = dict(os.environ, DAIMON_BACKUP_MIN_FREE_BYTES=str(2**62))
        result = subprocess.run(['bash', '-c', 'WORK_BASE=/tmp STATE_DIR=/tmp LOG_DIR=/tmp\n' +
                                 function('root_space_ok') + '\nroot_space_ok'], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux generated root-task integration')
class RootLifecycle(unittest.TestCase):
    def setUp(self):
        root = pathlib.Path(__file__).resolve().parents[1] / '.tmp'
        root.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=root, prefix='root-lifecycle.')
        self.work = pathlib.Path(self.directory.name)
        for name in ('bin','src','logs','locks','state','work'):
            (self.work/name).mkdir()
        body = SOURCE.split('PRIMARY="qq3303338052@outlook:$BACKUP_NAME"',1)[1].split('\nEOF\n',1)[0]
        body = 'PRIMARY="qq3303338052@outlook:$BACKUP_NAME"' + body
        body = body.replace('LOG_DIR="/var/log/rclone"', f'LOG_DIR="{self.work}/logs"')
        self.task = self.work/'task.sh'
        self.task.write_text('#!/bin/bash\nset -Eeuo pipefail\nTASK_KIND=root\nBACKUP_NAME=Fixture\nSRC1="'+str(self.work/'src')+'"\n'+body)
        self.env = dict(os.environ, FIXTURE=str(self.work), PATH=str(self.work/'bin')+':'+os.environ['PATH'],
                        DAIMON_LOCK_DIR=str(self.work/'locks'), DAIMON_ROOT_STATE_DIR=str(self.work/'state'),
                        DAIMON_BACKUP_WORK_DIR=str(self.work/'work'), DAIMON_RUN_LOG=str(self.work/'logs/run.log'),
                        DAIMON_BACKUP_MIN_FREE_BYTES='1', DAIMON_BACKUP_MIN_FREE_INODES='1', DAIMON_RECOVERY_TIMEOUT='2')
        (self.work/'state.json').write_text(json.dumps({'a'*64:True,'b'*64:True,'c'*64:False}))
        docker = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['FIXTURE']); args=sys.argv[1:]; mode=os.environ.get('MODE','success')
state=json.loads((p/'state.json').read_text()); op=args[0]
with (p/'calls').open('a') as f: f.write('docker '+' '.join(args)+'\n')
if op=='info': sys.exit(0)
if op=='ps':
 print('\n'.join(k for k,v in state.items() if v or '-aq' in args)); sys.exit(0)
if op=='inspect':
 if '-f' in args:
  fmt=args[2]
  for cid in args[3:]:
   if cid not in state: sys.exit(1)
   if '.Mounts' in fmt: print(cid+' '+json.dumps([{'Type':'bind','Source':str(p/'src'),'RW':True}]))
   else:
    health='healthy' if cid!='a'*64 or state['b'*64] else 'starting'
    if mode=='unhealthy' and cid=='a'*64: health='unhealthy'
    print(('true '+health) if state[cid] else 'false none')
 else:
  print(json.dumps([{'Id':cid,'Name':cid,'Mounts':[{'Type':'bind','Source':str(p/'src'),'RW':True}],
   'Config':{'Labels':{'com.docker.compose.project':'fixture','com.docker.compose.service':'app' if cid=='a'*64 else 'db',
   'com.docker.compose.depends_on':'db:service_healthy:false' if cid=='a'*64 else ''}}} for cid in args[1:]]))
elif op in ('stop','start'):
 cid=args[-1]
 if mode=='start-failure' and op=='start' and cid=='b'*64: sys.exit(2)
 state[cid]=(op=='start'); (p/'state.json').write_text(json.dumps(state))
else: sys.exit(99)
'''
        rclone = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['FIXTURE']); args=sys.argv[1:]; mode=os.environ.get('MODE','success')
with (p/'calls').open('a') as f: f.write('rclone '+' '.join(args)+'\n')
if args[0]=='lsd': sys.exit(21 if mode=='remote-failure' else 0)
if args[0]=='lsjson':
 if mode=='large' and args[1]==str(p/'src'):
  print(json.dumps([{'Path':'files/'+str(n)+'x'*120,'Size':1,'IsDir':False} for n in range(35000)]))
 else: print(json.dumps([{'Path':'data.sqlite','Size':1,'IsDir':False,'ModTime':'2026-01-01T00:00:00Z','Hashes':{'sha1':'x'}}]))
elif args[0] in ('sync','check'):
 state=json.loads((p/'state.json').read_text())
 if args[1]==str(p/'src'): assert not state['a'*64] and not state['b'*64]
 else: assert state['a'*64] and state['b'*64]
 if mode=='sync-failure' and args[0]=='sync': sys.exit(23)
 if mode=='secondary-failure' and args[1].startswith('qq'): sys.exit(24)
 if mode=='writer-restart' and args[0]=='sync' and args[1]==str(p/'src'):
  state['a'*64]=True; (p/'state.json').write_text(json.dumps(state))
else: sys.exit(99)
'''
        for name, text in [('docker',docker),('rclone',rclone)]:
            path=self.work/'bin'/name
            path.write_text(text)
            path.chmod(0o700)

    def tearDown(self):
        self.directory.cleanup()

    def execute(self, mode='success', **env):
        return subprocess.run(['bash',str(self.task)], env=dict(self.env,MODE=mode,**env),capture_output=True,text=True,timeout=50)

    def test_success_starts_database_first_and_cleans_work(self):
        result=self.execute()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr+(self.work/'logs/run.log').read_text())
        calls=(self.work/'calls').read_text()
        self.assertLess(calls.index('docker start '+'b'*64),calls.index('docker start '+'a'*64))
        self.assertNotIn('docker start '+'c'*64,calls)
        self.assertFalse((self.work/'state/containers.pending').exists())
        self.assertFalse(list((self.work/'work').glob('run.*')))

    def test_inventory_larger_than_lock_partition(self):
        result=self.execute('large')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(list((self.work/'locks').rglob('inventory.*')))

    def test_sync_failure_still_restores_all_writers(self):
        result=self.execute('sync-failure')
        self.assertEqual(result.returncode,23,result.stdout+result.stderr)
        state=json.loads((self.work/'state.json').read_text())
        self.assertTrue(state['a'*64] and state['b'*64])
        self.assertFalse((self.work/'logs/Fixture.last-success').exists())

    def test_space_failure_does_not_stop_writers(self):
        result=self.execute(DAIMON_BACKUP_MIN_FREE_BYTES=str(2**62))
        self.assertNotEqual(result.returncode,0)
        calls=(self.work/'calls').read_text() if (self.work/'calls').exists() else ''
        self.assertNotIn('docker stop',calls)

    def test_removed_legacy_ids_and_healthy_survivors_are_reconciled(self):
        legacy=self.work/'locks/daimon-root'
        legacy.mkdir()
        (legacy/'containers.pending').write_text('d'*64+'\n'+'b'*64+'\n')
        result=self.execute()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('RECOVERY_RECONCILED ready=1 removed=1',result.stdout)

    def test_unresolved_legacy_stopped_container_blocks_without_starting(self):
        legacy=self.work/'locks/daimon-root'
        legacy.mkdir()
        (legacy/'containers.pending').write_text('c'*64+'\n')
        result=self.execute()
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((legacy/'containers.pending').exists())
        self.assertNotIn('docker start',(self.work/'calls').read_text())

    def test_persistent_journal_recovers_only_recorded_original_writer(self):
        (self.work/'state.json').write_text(json.dumps({'a'*64:False,'b'*64:True,'c'*64:False}))
        (self.work/'state/containers.pending').write_text('a'*64+'\n')
        (self.work/'state/writers.json').write_text(json.dumps({'names':{'a'*64:'app'}}))
        result=self.execute()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('docker start '+'c'*64,(self.work/'calls').read_text())

    def test_secondary_failure_preserves_primary_verified_result(self):
        result=self.execute('secondary-failure')
        self.assertEqual(result.returncode,24,result.stdout+result.stderr)
        self.assertTrue((self.work/'logs/Fixture.qq-success').exists())
        self.assertFalse((self.work/'logs/Fixture.last-success').exists())
        self.assertIn('qq_verified=yes',(self.work/'logs/run.log').read_text())

    def test_external_writer_restart_aborts_before_success(self):
        result=self.execute('writer-restart')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.work/'logs/Fixture.last-success').exists())
        state=json.loads((self.work/'state.json').read_text())
        self.assertTrue(state['a'*64] and state['b'*64])

    def test_excluded_backup_lock_is_not_a_host_writer(self):
        lock=self.work/'src/linux-daimon/backup/nginx-domain/.bundle.lock'
        lock.parent.mkdir(parents=True)
        with lock.open('w'):
            result=self.execute()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_unmanaged_host_database_writer_is_rejected(self):
        database=self.work/'src/live.sqlite'
        with database.open('w'):
            result=self.execute()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Unmanaged host writer',result.stderr)

    def test_unavailable_remote_prevents_stopping_services(self):
        result=self.execute('remote-failure')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('docker stop',(self.work/'calls').read_text())

    def test_orphan_cleanup_keeps_active_and_unowned_directories(self):
        boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        for name,pid in [('run.orphan',999999999),('run.active',os.getpid())]:
            path=self.work/'work'/name; path.mkdir()
            (path/'.daimon-work').write_text(str(pid)+' '+boot)
        unowned=self.work/'work/run.business'; unowned.mkdir()
        result=self.execute()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse((self.work/'work/run.orphan').exists())
        self.assertTrue((self.work/'work/run.active').exists())
        self.assertTrue(unowned.exists())

    def test_root_inode_failure(self):
        env = dict(os.environ, DAIMON_BACKUP_MIN_FREE_INODES=str(2**62))
        result = subprocess.run(['bash', '-c', 'WORK_BASE=/tmp STATE_DIR=/tmp LOG_DIR=/tmp\n' +
                                 function('root_space_ok') + '\nroot_space_ok'], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
