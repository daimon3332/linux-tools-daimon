import copy,io,json,os,re,tarfile,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
class RestoreSafety(unittest.TestCase):
    def test_restore_never_force_deletes_existing_container(self):
        start=SOURCE.index('\tdocker_migration_restore() {')
        end=SOURCE.index('\n\t# ----------------------------',start)
        body=SOURCE[start:end]
        self.assertNotIn('docker rm -f',body)
        self.assertNotIn('--directory / ',body)

WORKER=SOURCE.split("<<'PYDOCKER_BACKUP'\n",1)[1].split('\nPYDOCKER_BACKUP',1)[0]
if os.name != 'posix': WORKER=WORKER.replace('fcntl, ', '')
SCOPE={'__name__':'fixture'}
exec(compile(WORKER,'docker-engine','exec'),SCOPE)
def item():
    return {'Id':'a'*64,'Name':'/fixture','Image':'sha256:'+'b'*64,'State':{'Running':True},
            'Config':{'Image':'example:tag','Entrypoint':['/bin/sh','-c'],'Cmd':['printf "a b"',''],
                      'Env':['TOKEN=private value','MULTILINE=a\nb'],'User':'1000:1000','WorkingDir':'/app',
                      'Healthcheck':{'Test':['CMD','true']},'Labels':{}},
            'HostConfig':{'PortBindings':{'80/udp':[{'HostIp':'127.0.0.1','HostPort':'18080'},{'HostIp':'127.0.0.2','HostPort':'18081'}]},
                          'RestartPolicy':{'Name':'on-failure','MaximumRetryCount':3},'NetworkMode':'none','Memory':67108864},
            'Mounts':[{'Type':'bind','Source':'/original','Destination':'/data','RW':False,'Propagation':'rprivate'},
                      {'Type':'volume','Source':'/voldata','Name':'volume-fixture','Destination':'/db','RW':True}],
            'NetworkSettings':{'Networks':{'none':{}}}}
class Metadata(unittest.TestCase):
    def test_payload_retains_arrays_udp_multi_bind_mount_type_and_policy(self):
        original=item();data=copy.deepcopy(original)
        result=SCOPE['payload'](data,{'/original':'/restore/data/payload'}, {})
        for key in ('Entrypoint','Cmd','Env','User','WorkingDir','Healthcheck'):self.assertEqual(result[key],original['Config'][key])
        for key in ('PortBindings','RestartPolicy','Memory'):self.assertEqual(result['HostConfig'][key],original['HostConfig'][key])
        self.assertEqual(result['HostConfig']['Mounts'][0],{'Type':'bind','Source':'/restore/data/payload','Target':'/data','ReadOnly':True,'BindOptions':{'Propagation':'rprivate'}})
        self.assertEqual(result['HostConfig']['Mounts'][1]['Type'],'volume')
        self.assertEqual(result['HostConfig']['Mounts'][1]['Source'],'volume-fixture')
        self.assertEqual(data,original)
    def test_network_id_remapped_to_name(self):
        data=item();data['HostConfig']['NetworkMode']='old-id'
        data['NetworkSettings']['Networks']={'project_default':{'NetworkID':'old-id','Aliases':['app',data['Id'][:12]],'IPAMConfig':{'IPv4Address':'172.31.0.4'}}}
        result=SCOPE['payload'](data,{'/original':'/restore'}, {})
        self.assertEqual(result['HostConfig']['NetworkMode'],'project_default')
        self.assertEqual(result['NetworkingConfig']['EndpointsConfig']['project_default']['Aliases'],['app'])
    def test_unsupported_settings_rejected(self):
        for key,value in [('Privileged',True),('AutoRemove',True),('Devices',[{}]),('VolumesFrom',['other']),('PidMode','host')]:
            with self.subTest(key=key):
                data=item();data['HostConfig'][key]=value
                with self.assertRaises(ValueError):SCOPE['supported'](data)
    def test_compose_context_preserves_file_order_and_rejects_escape(self):
        data=item();data['Config']['Labels']={'com.docker.compose.project':'demo','com.docker.compose.project.working_dir':'/project','com.docker.compose.project.config_files':'/project/base.yaml,/project/override.yaml'}
        if os.name=='posix':
            self.assertEqual(SCOPE['project_context'](data),('demo','/project',['/project/base.yaml','/project/override.yaml']))
        data['Config']['Labels']['com.docker.compose.project.config_files']='/other.yaml'
        with self.assertRaises(ValueError):SCOPE['project_context'](data)
class Archives(unittest.TestCase):
    def setUp(self):
        (ROOT/'.tmp').mkdir(exist_ok=True);self.tmp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp');self.work=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def archive(self,entries):
        p=self.work/'archive.tar'
        with tarfile.open(p,'w') as archive:
            for name,kind,target in entries:
                m=tarfile.TarInfo(name);m.type=kind;m.linkname=target
                if kind==tarfile.REGTYPE:m.size=1
                archive.addfile(m,io.BytesIO(b'x') if m.isfile() else None)
        return p
    def test_valid_regular_directory_and_internal_links(self):
        p=self.archive([('payload',tarfile.DIRTYPE,''),('payload/data',tarfile.REGTYPE,''),('payload/link',tarfile.SYMTYPE,'data'),('payload/hard',tarfile.LNKTYPE,'payload/data')])
        self.assertEqual(len(SCOPE['archive_members'](p)),4)
    def test_unsafe_members_rejected(self):
        cases=[[('../escape',tarfile.REGTYPE,'')],[('/absolute',tarfile.REGTYPE,'')],[('payload/fifo',tarfile.FIFOTYPE,'')],
               [('payload/a',tarfile.REGTYPE,''),('payload/a',tarfile.REGTYPE,'')],
               [('payload/link',tarfile.SYMTYPE,'../../escape')],
               [('payload/link',tarfile.SYMTYPE,'/root')],
               [('payload/link',tarfile.SYMTYPE,'data'),('payload/link/file',tarfile.REGTYPE,'')],
               [('payload/hard',tarfile.LNKTYPE,'missing')]]
        for entries in cases:
            with self.subTest(entries=entries):
                with self.assertRaises(ValueError):SCOPE['archive_members'](self.archive(entries))
    def test_corrupt_archive_rejected(self):
        p=self.work/'bad';p.write_bytes(b'not tar')
        with self.assertRaises(tarfile.TarError):SCOPE['archive_members'](p)
    @unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native root required')
    def test_existing_container_refused_before_restore_writes(self):
        backup=self.work/'backup';backup.mkdir();target=self.work/'target';target.mkdir()
        with tarfile.open(backup/'images.tar','w'):pass
        state={'version':2,'platform':'linux/amd64','containers':[item()],'sources':{},'volumes':{},'networks':{},'projects':{},
               'checksums':{'images.tar':SCOPE['digest'](backup/'images.tar')}}
        (backup/'manifest.json').write_text(json.dumps(state))
        class Engine:
            platform='linux/amd64'
            def container(self,name,missing=False):return {'Id':'existing'}
            def api(self,*args,**kwargs):raise AssertionError('Unexpected Docker mutation')
        with self.assertRaisesRegex(ValueError,'already exists'):SCOPE['restore'](Engine(),backup,target)
        self.assertEqual(list(target.iterdir()),[])
    @unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native root required')
    def test_extract_restores_numeric_ownership_and_internal_links(self):
        p=self.archive([('payload',tarfile.DIRTYPE,''),('payload/data',tarfile.REGTYPE,''),('payload/link',tarfile.SYMTYPE,'data'),('payload/hard',tarfile.LNKTYPE,'payload/data')])
        target=self.work/'target';target.mkdir();SCOPE['unpack'](p,target,volume=True)
        self.assertEqual((target/'data').read_bytes(),b'x')
        self.assertTrue((target/'link').is_symlink())
        self.assertEqual((target/'hard').stat().st_ino,(target/'data').stat().st_ino)
        self.assertEqual((target/'data').stat().st_uid,0)

if __name__=='__main__':unittest.main()
