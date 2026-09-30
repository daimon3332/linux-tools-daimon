#!/usr/bin/env python3
"""Install and verify a complete immutable toolbox release."""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

if os.name == 'posix':
    import fcntl

REPO = 'daimon3332/linux-tools-daimon'
MAX_ARCHIVE = 16 * 1024 * 1024
NETWORK_FILES = {'tcp-tuning-lab.sh', 'tcp-tuning-client.ps1', 'tcp-tuning-control.py', 'tcp-tuning-score.py'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def private_directory(path):
    require(path.is_absolute() and path.resolve() == path, 'Untrusted installation directory')
    for parent in (path, *path.parents):
        info = parent.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                'Installation directory is not root-owned or is writable by others')


def regular(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0 and
            not info.st_mode & 0o022, 'Untrusted installation file: ' + str(path))


def atomic(path, data, mode=0o600):
    private_directory(path.parent)
    if path.exists() or path.is_symlink():
        regular(path)
    fd, name = tempfile.mkstemp(prefix='.daimon-write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        descriptor = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def manifest(directory):
    path = directory / 'runtime.json'
    require(path.is_file() and not path.is_symlink(), 'Runtime manifest is missing')
    data = json.loads(path.read_text())
    require(data.get('format') == 1 and isinstance(data.get('modules'), list) and
            isinstance(data.get('files'), dict), 'Invalid runtime manifest')
    files = data['files']
    require('linux-toolbox.sh' in files and 'scripts/lib/package.py' in files and 'scripts/lib/entry.sh' in files and
            'scripts/main.sh' in data['modules'] and 'scripts/lib/globals.sh' == data['modules'][0],
            'Required entry points are missing')
    for number in range(1, 22):
        require(sum(p.startswith('scripts/%02d-' % number) and p.endswith('.sh') for p in files) == 1,
                'Menu module is missing or ambiguous: ' + str(number))
    require(all('scripts/network/' + name in files for name in NETWORK_FILES), 'TCP components are incomplete')
    require(len(data['modules']) == len(set(data['modules'])) and set(data['modules']) <= files.keys(),
            'Module order contains duplicates or missing files')
    for name, checksum in files.items():
        p = PurePosixPath(name)
        require(not p.is_absolute() and '..' not in p.parts and str(p) == name and
                (name == 'linux-toolbox.sh' or name.startswith('scripts/')) and
                p.suffix in ('.sh', '.py', '.ps1') and re.fullmatch(r'[a-f0-9]{64}', checksum),
                'Unsafe manifest entry')
    require(set(data['modules']) == {name for name in files if name.endswith('.sh') and
                                    name.startswith('scripts/') and not name.startswith('scripts/network/') and
                                    name != 'scripts/lib/entry.sh'},
            'A shell module would not be loaded')
    return data


def verify(directory, syntax=False, trusted=False):
    data = manifest(directory)
    for name, expected in data['files'].items():
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.resolve() == path.absolute(),
                'Runtime component missing or linked: ' + name)
        if trusted:
            regular(path)
        require(digest(path.read_bytes()) == expected, 'Runtime component checksum mismatch: ' + name)
        if syntax and name.endswith('.sh'):
            p = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
            require(p.returncode == 0, 'Invalid shell component: ' + name + ': ' + p.stderr)
        if syntax and name.endswith('.py'):
            compile(path.read_bytes(), name, 'exec')
    return data


def country():
    try:
        with urllib.request.urlopen('https://ipinfo.io/json', timeout=5) as stream:
            value = json.load(stream).get('country', '')
        return value if re.fullmatch(r'[A-Z]{2}', value) else ''
    except Exception:
        return ''


def archive_urls(revision, region):
    url = 'https://github.com/' + REPO + '/archive/' + revision + '.tar.gz'
    direct = ['https://codeload.github.com/' + REPO + '/tar.gz/' + revision, url]
    proxies = [prefix + url for prefix in ('https://gh-proxy.com/', 'https://ghproxy.net/', 'https://ghfast.top/')]
    return proxies + direct if region == 'CN' else direct + proxies


def resolve(revision, region):
    if revision != 'master':
        return revision
    url = 'https://api.github.com/repos/' + REPO + '/git/ref/heads/master'
    proxies = ['https://gh-proxy.com/' + url, 'https://ghproxy.net/' + url]
    for endpoint in (proxies + [url] if region == 'CN' else [url] + proxies):
        try:
            with urllib.request.urlopen(urllib.request.Request(endpoint, headers={'User-Agent': 'linux-tools-daimon'}), timeout=20) as stream:
                target = json.loads(stream.read(65536))['object']
            if target['type'] == 'commit' and re.fullmatch(r'[a-f0-9]{40}', target['sha']):
                print('Latest revision: ' + target['sha'], file=sys.stderr, flush=True)
                return target['sha']
        except Exception as error:
            print('Revision lookup failed: ' + endpoint + ': ' + str(error), file=sys.stderr, flush=True)
    return revision


def download(revision, target):
    region = country()
    revision = resolve(revision, region)
    for url in archive_urls(revision, region):
        print('Downloading complete package: ' + url, file=sys.stderr, flush=True)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'linux-tools-daimon'}), timeout=30) as stream:
                content = stream.read(MAX_ARCHIVE + 1)
            require(0 < len(content) <= MAX_ARCHIVE, 'Package size is invalid')
            with tempfile.TemporaryDirectory(prefix='.verify-', dir=target.parent) as directory:
                checked = Path(directory)
                with tarfile.open(fileobj=io.BytesIO(content), mode='r:gz') as archive:
                    resolved = unpack(archive, checked, revision)
                shutil.copytree(checked, target, dirs_exist_ok=True)
            return resolved
        except Exception as error:
            print('Download failed; trying another endpoint: ' + str(error), file=sys.stderr, flush=True)
    raise ValueError('All package endpoints failed; installed release was not replaced')


def unpack(archive, target, requested):
    members = archive.getmembers()
    require(0 < len(members) < 10000, 'Archive member count is invalid')
    roots = set()
    entries = {}
    for member in members:
        path = PurePosixPath(member.name)
        require(not path.is_absolute() and '..' not in path.parts and path.parts and
                (member.isdir() or member.isfile()), 'Unsafe package archive member')
        roots.add(path.parts[0])
        if len(path.parts) > 1 and member.isfile():
            name = str(PurePosixPath(*path.parts[1:]))
            require(name not in entries and member.size <= MAX_ARCHIVE, 'Duplicate or oversized archive member')
            entries[name] = member
    require(len(roots) == 1 and 'runtime.json' in entries, 'Complete package manifest is missing')
    revision = archive.pax_headers.get('comment', '')
    if not re.fullmatch(r'[a-f0-9]{40}', revision):
        revision = next(iter(roots)).rsplit('-', 1)[-1]
    require(re.fullmatch(r'[a-f0-9]{40}', revision), 'Package has no immutable Git revision')
    if requested != 'master':
        require(revision == requested, 'Downloaded package does not match requested revision')
    content = archive.extractfile(entries['runtime.json']).read()
    (target / 'runtime.json').write_bytes(content)
    data = manifest(target)
    for name, expected in data['files'].items():
        require(name in entries, 'Required file not found in archive: ' + name)
        content = archive.extractfile(entries[name]).read()
        require(digest(content) == expected, 'Downloaded component failed checksum: ' + name)
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(content.replace(b'\r\n', b'\n'))
        path.chmod(0o755 if name == 'linux-toolbox.sh' else 0o600)
    verify(target, syntax=True, trusted=True)
    atomic(target / 'release.json', json.dumps({'revision': revision}).encode())
    return revision


def preferences(root):
    path = root / 'preferences.json'
    values = {'canshu': 'default', 'permission_granted': 'false', 'ENABLE_STATS': 'false'}
    if path.exists():
        regular(path)
        values.update(json.loads(path.read_text()))
    else:
        for candidate in (root/'linux-toolbox.sh', Path(os.environ.get('DAIMON_INSTALL_BIN','/usr/local/bin/d'))):
            if not candidate.exists() or candidate.is_symlink():
                continue
            regular(candidate)
            text = candidate.read_text()
            for key in values:
                match = re.search(r'^' + key + r'="([^"]*)"', text, re.M)
                if match:
                    values[key] = match[1]
    require(values['canshu'] in ('default', 'CN', 'V6') and
            values['permission_granted'] in ('true', 'false') and values['ENABLE_STATS'] in ('true', 'false'),
            'Invalid stored preferences')
    return values


def current(root):
    link = root / 'current'
    require(link.is_symlink(), 'No complete modular release is installed')
    release = link.resolve()
    require(release.parent == root/'releases' and re.fullmatch(r'[a-f0-9]{40}', release.name),
            'Untrusted current release link')
    private_directory(release)
    verify(release, trusted=True)
    return release


def install(root, revision, publish, archive_path=None):
    require(revision == 'master' or re.fullmatch(r'[a-f0-9]{40}', revision), 'Invalid package revision')
    require(not Path('/var/lib/daimon/ssh-change').exists(), 'SSH recovery is pending; finish it before updating')
    releases = root/'releases'
    if not releases.exists():
        releases.mkdir(mode=0o700)
    private_directory(releases)
    with tempfile.TemporaryDirectory(prefix='.stage-', dir=releases) as temporary:
        stage = Path(temporary)
        if archive_path:
            with tarfile.open(archive_path, 'r:gz') as archive:
                resolved = unpack(archive, stage, revision)
        else:
            resolved = download(revision, stage)
        destination = releases/resolved
        if destination.exists():
            private_directory(destination)
            verify(destination, syntax=True, trusted=True)
            require((destination/'runtime.json').read_bytes() == (stage/'runtime.json').read_bytes(),
                    'Existing release differs from downloaded package')
        else:
            os.rename(stage, destination)
            stage.mkdir()
        if publish:
            stored = preferences(root)
            old = root/'current'
            require(not os.path.lexists(old) or old.is_symlink(), 'Current path is occupied by a non-release file')
            if old.is_symlink():
                current(root)
            targets = (root/'linux-toolbox.sh', Path(os.environ.get('DAIMON_INSTALL_BIN', '/usr/local/bin/d')))
            for path in targets:
                private_directory(path.parent)
                if path.exists() or path.is_symlink():
                    regular(path)
                    require('DAIMON_NAME="linux-tools-daimon"' in path.read_text(), 'Refusing to replace an unrelated entry point')
            atomic(root/'preferences.json', json.dumps(stored).encode())
            originals = {path:(path.read_bytes(),stat.S_IMODE(path.stat().st_mode)) if path.exists() else None for path in targets}
            old_link = os.readlink(old) if old.is_symlink() else None
            temporary_link = root/('.current-' + next(tempfile._get_candidate_names()))
            try:
                launcher = (destination/'linux-toolbox.sh').read_bytes()
                # The first launcher can still use the old complete release until the pointer switches.
                for path in targets:
                    atomic(path, launcher, 0o755)
                temporary_link.symlink_to(destination)
                os.replace(temporary_link, old)
            except BaseException:
                for path, original in originals.items():
                    if original is None:
                        if path.exists():
                            regular(path)
                            path.unlink()
                    else:
                        atomic(path, *original)
                if old_link is not None and os.readlink(old) != old_link:
                    if temporary_link.is_symlink():
                        temporary_link.unlink()
                    temporary_link.symlink_to(old_link)
                    os.replace(temporary_link, old)
                raise
            finally:
                if temporary_link.is_symlink():
                    temporary_link.unlink()
            print('Complete release installed: ' + resolved, file=sys.stderr)
        else:
            print('Complete release staged: ' + resolved, file=sys.stderr)
        return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('run', 'update', 'stage', 'verify', 'status', 'settings', 'setting', 'modules'))
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    root = Path(os.environ.get('DAIMON_RUNTIME_ROOT', '/root/linux-daimon'))
    if args.action == 'verify':
        require(len(args.arguments) == 1, 'Expected a package path')
        verify(Path(args.arguments[0]).absolute(), syntax=True)
        print('Complete package verified')
        return
    if args.action == 'modules':
        require(len(args.arguments) == 1, 'Expected a package path')
        directory = Path(args.arguments[0]).absolute()
        data = verify(directory)
        for name in data['modules']:
            print(name)
        return
    require(os.geteuid() == 0, 'Root is required for installation and preferences')
    if not root.exists():
        private_directory(root.parent)
        root.mkdir(mode=0o700)
    private_directory(root)
    lock = root/'.package.lock'
    fd = os.open(lock, os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW, 0o600)
    try:
        regular(lock)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action in ('update', 'stage'):
            revision = args.arguments[0] if args.arguments else 'master'
            archive = args.arguments[1] if len(args.arguments) > 1 else None
            install(root, revision, args.action == 'update', archive)
        elif args.action == 'run':
            if not (root/'current').is_symlink():
                install(root, 'master', True)
            print(current(root))
        elif args.action == 'status':
            release = current(root)
            print(json.dumps({'revision':release.name, 'files':len(manifest(release)['files']), 'path':str(release)}))
        elif args.action in ('settings', 'setting'):
            values = preferences(root)
            if args.action == 'setting':
                require(len(args.arguments) == 2 and args.arguments[0] in values, 'Invalid preference')
                key, value = args.arguments
                allowed = ('default','CN','V6') if key == 'canshu' else ('true','false')
                require(value in allowed, 'Invalid preference value')
                values[key] = value
                atomic(root/'preferences.json', json.dumps(values).encode())
            else:
                for key,value in values.items():
                    print(key+'="'+value+'"')
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        print('ERROR: '+str(error), file=sys.stderr)
        sys.exit(1)
