import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(os.environ.get('DAIMON_TEST_PACKAGE', Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('package_native',ROOT/'scripts/lib/package.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native root-owned files required')
class Native(unittest.TestCase):
    def setUp(self):
        (Path(__file__).resolve().parents[1]/'.tmp').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]/'.tmp',prefix='native-package-')
        self.work=Path(self.tmp.name)
        self.root=self.work/'installation';self.root.mkdir(mode=0o700)
        self.bin=self.work/'d'
        self.env=patch.dict(os.environ,{'DAIMON_RUNTIME_ROOT':str(self.root),'DAIMON_INSTALL_BIN':str(self.bin)})
        self.env.start();self.addCleanup(self.env.stop);self.addCleanup(self.tmp.cleanup)
        self.rev='a'*40
        self.archive=self.make_archive(self.rev)

    def make_archive(self,rev,omit=None,corrupt=None):
        archive=self.work/(rev+'.tar.gz')
        data=json.loads((ROOT/'runtime.json').read_text())
        with tarfile.open(archive,'w:gz',pax_headers={'comment':rev}) as tar:
            for name in ['runtime.json',*data['files']]:
                if name==omit:continue
                content=(ROOT/name).read_bytes()
                if name==corrupt:content+=b'corruption'
                member=tarfile.TarInfo('toolbox-'+rev+'/'+name);member.size=len(content);member.mode=0o600
                tar.addfile(member,io.BytesIO(content))
        return archive

    def install(self,rev=None,archive=None):
        return p.install(self.root,rev or self.rev,True,archive or self.archive)

    def test_first_install_and_offline_verified_run(self):
        destination=self.install()
        self.assertEqual(p.current(self.root),destination)
        self.assertEqual(self.bin.read_bytes(),(ROOT/'linux-toolbox.sh').read_bytes())
        with patch.object(p,'download',side_effect=AssertionError('Offline run downloaded')):
            self.assertEqual(p.current(self.root),destination)

    def test_all_modules_source_without_business_actions(self):
        release=self.install()
        result=subprocess.run(['bash',str(release/'scripts/lib/entry.sh'),'--definitions'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'backup-sh').exists())

    def test_every_menu_entry_and_shortcut_dispatch_is_defined(self):
        release=self.install()
        entries=['linux_info','linux_update','linux_clean','one_click_config_manager','linux_Settings',
                 'linux_thirdparty_tools','linux_programming_tools','linux_docker','ssh_config_manager',
                 'ufw_manager','ssl_nginx_manager','fail2ban_manager','linux_bbr','warp_manager',
                 'rclone_manager','bitwarden_manager','crontab_sync_manager','common_one_click_scripts',
                 'server_retire_menu','debian_basics_menu','daimon_tcp_tune_menu','daimon_dispatch']
        script='set -e\n'+''.join('source '+str(release/name)+'\n' for name in p.manifest(release)['modules'])
        script+='\n'.join('declare -F '+name+' >/dev/null' for name in entries)
        result=subprocess.run(['bash','--noprofile','--norc'],input=script,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_concurrent_launches_all_succeed(self):
        release=self.install()
        cmd=['python3',str(release/'scripts/lib/package.py'),'boot']
        procs=[subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(12)]
        for proc in procs:
            out,err=proc.communicate(timeout=60)
            self.assertEqual(proc.returncode,0,err)
            lines=out.splitlines()
            self.assertEqual(lines[0],str(release))
            self.assertIn('module=scripts/main.sh',lines)
            self.assertIn('setting=canshu=default',lines)

    def test_old_releases_are_pruned(self):
        for rev in ('b'*40,'c'*40,'d'*40,'e'*40):
            self.install(rev,self.make_archive(rev))
        names=sorted(x.name for x in (self.root/'releases').iterdir() if not x.name.startswith('.'))
        self.assertEqual(len(names),p.KEEP_RELEASES)
        self.assertEqual(p.current(self.root).name,'e'*40)

    def test_settings_migrate_and_survive_update(self):
        self.bin.write_text('#!/bin/bash\nDAIMON_NAME="linux-tools-daimon"\ncanshu="V6"\npermission_granted="true"\nENABLE_STATS="false"\n')
        self.install()
        self.assertEqual(p.preferences(self.root),{'canshu':'V6','permission_granted':'true','ENABLE_STATS':'false'})
        rev='b'*40;self.install(rev,self.make_archive(rev))
        self.assertEqual(p.preferences(self.root)['canshu'],'V6')

    def test_missing_corrupt_package_never_replaces_current(self):
        release=self.install();original=self.bin.read_bytes()
        for kind in ('omit','corrupt'):
            rev=('b' if kind=='omit' else 'c')*40
            archive=self.make_archive(rev,**{kind:'scripts/08-docker.sh'})
            with self.assertRaises(ValueError):self.install(rev,archive)
            self.assertEqual(p.current(self.root),release);self.assertEqual(self.bin.read_bytes(),original)

    def test_failed_launcher_publish_restores_both_files(self):
        release=self.install();original=self.bin.read_bytes()
        rev='b'*40;archive=self.make_archive(rev)
        real=p.atomic;failed=[]
        def broken(path,data,mode=0o600):
            if path==self.bin and not failed:
                failed.append(True);raise OSError('Injected launcher failure')
            return real(path,data,mode)
        with patch.object(p,'atomic',side_effect=broken),self.assertRaises(OSError):self.install(rev,archive)
        self.assertEqual(p.current(self.root),release)
        self.assertEqual(self.bin.read_bytes(),original)
        self.assertEqual((self.root/'linux-toolbox.sh').read_bytes(),original)

    def test_download_interruption_does_not_replace_release(self):
        release=self.install()
        with patch.object(p,'download',side_effect=OSError('Interrupted transfer')),self.assertRaises(OSError):
            p.install(self.root,'b'*40,True)
        self.assertEqual(p.current(self.root),release)
        self.assertFalse(list((self.root/'releases').glob('.stage-*')))

    def test_wrong_revision_rejected(self):
        with self.assertRaisesRegex(ValueError,'revision'):
            self.install('b'*40,self.archive)
        self.assertFalse((self.root/'current').exists())

    def test_unrelated_launcher_not_overwritten(self):
        self.bin.write_text('unrelated')
        with self.assertRaisesRegex(ValueError,'unrelated'):
            self.install()
        self.assertEqual(self.bin.read_text(),'unrelated')
        self.assertFalse((self.root/'current').exists())

    def test_valid_fallback_after_bad_proxy_content(self):
        content=self.archive.read_bytes()
        responses=[io.BytesIO(b'<html>proxy error</html>'),io.BytesIO(content)]
        with patch.object(p,'country',return_value='CN'),patch.object(p.urllib.request,'urlopen',side_effect=responses):
            dest=p.install(self.root,self.rev,True)
        self.assertEqual(dest.name,self.rev)

    def test_master_resolves_to_commit_before_download(self):
        ref=json.dumps({'object':{'type':'commit','sha':self.rev}}).encode()
        responses=[io.BytesIO(ref),io.BytesIO(self.archive.read_bytes())]
        with patch.object(p,'country',return_value='CN'),patch.object(p.urllib.request,'urlopen',side_effect=responses) as opened:
            dest=p.install(self.root,'master',True)
        self.assertEqual(dest.name,self.rev)
        self.assertIn(self.rev,opened.call_args_list[1][0][0].full_url)

    def test_installed_component_corruption_refuses_run(self):
        release=self.install()
        (release/'scripts/08-docker.sh').write_text('broken')
        with self.assertRaisesRegex(ValueError,'checksum'):
            p.current(self.root)


if __name__=='__main__':
    unittest.main()
