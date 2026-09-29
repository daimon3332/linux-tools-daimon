import os,re,subprocess,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(os.environ.get('DAIMON_TEST_SOURCE',ROOT/'linux-toolbox.sh')).read_text(encoding='utf-8')
class Entry(unittest.TestCase):
    def test_no_recursive_delete_in_certificate_entrypoints(self):
        for name in ('remove_cert','remove_nginx_and_cert','cleanup_nginx_and_cert','cleanup_failed_cert_request'):
            m=re.search(r'(?m)^'+name+r'\(\) \{\n',SOURCE)
            body=SOURCE[m.start():SOURCE.index('\n}\n',m.end())+2]
            self.assertNotIn('rm -rf',body,name)
@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Native root/OpenSSL required')
class Certificates(unittest.TestCase):
    def setUp(self):
        (ROOT/'.tmp').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=ROOT/'.tmp');self.work=Path(self.tmp.name)
        self.target=self.work/'domain/example.test';self.target.mkdir(parents=True)
        self.nginx=self.work/'nginx';self.nginx.mkdir()
        (self.work/'acme').mkdir();self.acme=self.work/'acme/acme.sh'
        self.acme.write_text('#!/bin/sh\ntouch "'+str(self.work/'deregistered')+'"\n');self.acme.chmod(0o700)
        self.make_cert('DNS:example.test')
        body=SOURCE.split("<<'PYCERT_REMOVE'\n",1)[1].split('\nPYCERT_REMOVE',1)[0]
        for old,new in [('/root/domain',self.work/'domain'),('/etc/nginx',self.nginx),('/home/web/conf.d',self.work/'conf.d')]:body=body.replace(old,str(new))
        self.scope={'__name__':'fixture'};exec(compile(body,'certificate-worker','exec'),self.scope)
    def tearDown(self):self.tmp.cleanup()
    def make_cert(self,san):
        subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','1',
                        '-subj','/CN=example.test','-addext','subjectAltName='+san,'-keyout',str(self.target/'privkey.pem'),
                        '-out',str(self.target/'fullchain.pem')],check=True,capture_output=True)
    def invoke(self):
        with patch('shutil.which',return_value=None):
            self.scope['remove']('example.test',str(self.target),str(self.acme),str(self.work/'renew.lock'))
    def rejected(self):
        before={p.name:p.read_bytes() for p in self.target.iterdir() if p.is_file()}
        with self.assertRaises((ValueError,OSError)):self.invoke()
        self.assertEqual(before,{p.name:p.read_bytes() for p in self.target.iterdir() if p.is_file()})
        self.assertFalse((self.work/'deregistered').exists())
    def test_exclusive_cert_removed(self):
        self.invoke();self.assertFalse(self.target.exists());self.assertTrue((self.work/'deregistered').exists())
    def test_nginx_reference_retained(self):
        (self.nginx/'site.conf').write_text('ssl_certificate '+str(self.target/'fullchain.pem')+';')
        self.rejected()
    def test_variable_certificate_reference_retained(self):
        (self.nginx/'site.conf').write_text('ssl_certificate /certs/$host.pem;');self.rejected()
    def test_multidomain_certificate_retained(self):
        self.make_cert('DNS:example.test,DNS:other.test');self.rejected()
    def test_other_renewal_record_retained(self):
        other=self.work/'acme/other.test';other.mkdir();(other/'other.test.conf').write_text(str(self.target))
        self.rejected()
    def test_unexpected_file_retained(self):
        (self.target/'business.txt').write_text('keep');self.rejected()
    def test_hardlink_retained(self):
        os.link(self.target/'privkey.pem',self.work/'sentinel');self.rejected()
    def test_symlink_retained(self):
        (self.target/'privkey.pem').rename(self.work/'sentinel');(self.target/'privkey.pem').symlink_to(self.work/'sentinel');self.rejected()
    def test_open_certificate_retained(self):
        with (self.target/'fullchain.pem').open('rb'):self.rejected()
    def test_ecc_registration_is_removed_explicitly(self):
        (self.work/'acme/example.test_ecc').mkdir()
        self.acme.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "'+str(self.work/'args')+'"\n')
        self.invoke()
        self.assertIn('--ecc',(self.work/'args').read_text().splitlines())
    def test_linked_configuration_directory_is_not_silently_ignored(self):
        outside=self.work/'outside';outside.mkdir();(outside/'site.conf').write_text(str(self.target))
        (self.nginx/'linked').symlink_to(outside,target_is_directory=True)
        self.rejected()
    def test_acme_failure_preserves_files(self):
        self.acme.write_text('#!/bin/sh\nexit 1\n');self.rejected()
    def test_lock_conflict(self):
        import fcntl
        with (self.work/'renew.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);self.rejected()
if __name__=='__main__':unittest.main()
