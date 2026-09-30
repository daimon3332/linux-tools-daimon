import json
import os
import re
from pathlib import Path


def read_source(root):
    if os.name == 'nt' and re.match(r'^/[A-Za-z]/', str(root)):
        root = str(root)[1] + ':' + str(root)[2:]
    path = Path(os.environ.get('DAIMON_TEST_SOURCE', Path(root)/'linux-toolbox.sh'))
    text = path.read_text(encoding='utf-8')
    if '# DAIMON_MODULAR_BOOTSTRAP=1' not in text:
        return text
    directory = path.parent
    manifest = json.loads((directory/'runtime.json').read_text(encoding='utf-8'))
    return text.replace('# DAIMON_MODULAR_BOOTSTRAP=1', '# DAIMON_COMBINED_TEST_SOURCE=1') + '\n' + '\n'.join((directory/name).read_text(encoding='utf-8') for name in manifest['modules'])


if __name__ == '__main__':
    import sys
    print(read_source(sys.argv[1] if len(sys.argv)>1 else Path(__file__).resolve().parents[1]))
