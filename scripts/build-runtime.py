#!/usr/bin/env python3
"""Regenerate the tracked runtime file manifest after source changes."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
modules = ['scripts/lib/globals.sh']
modules += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'scripts').glob('**/*.sh'))
            if p.relative_to(ROOT).as_posix() != modules[0] and p.parent.name != 'network' and p.name != 'entry.sh']
files = [ROOT/'linux-toolbox.sh'] + sorted((ROOT/'scripts').glob('**/*'))
checksums = {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes().replace(b'\r\n', b'\n')).hexdigest()
             for p in files if p.is_file() and p.suffix in ('.sh','.py','.ps1') and p.name!='build-runtime.py'}
(ROOT/'runtime.json').write_text(json.dumps({'format':1,'modules':modules,'files':checksums},indent=2)+'\n',encoding='utf-8',newline='\n')
