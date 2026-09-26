import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parent.parent
IPERF = os.environ.get('DAIMON_IPERF3', shutil.which('iperf3'))


def port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


@unittest.skipUnless(IPERF, 'iperf3 executable required')
class ClientTest(unittest.TestCase):
    def test_default_powershell_returns_to_prompt(self):
        shells = [shutil.which(name) for name in ('powershell', 'pwsh')]
        if not any(shells):
            self.skipTest('PowerShell required')
        (ROOT / '.tmp').mkdir(exist_ok=True)
        for shell in filter(None, shells):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
                state = Path(directory)
                control_port, data_port = port(), port()
                stage = {'state': 'ready', 'id': 1, 'family': 4, 'host': '127.0.0.1',
                         'port': data_port, 'duration': 1, 'omit': 0, 'budget_bytes': 20000000000,
                         'message': 'A'}
                (state / 'stage.json').write_text(json.dumps(stage), encoding='utf-8')
                server = subprocess.Popen([IPERF, '-s', '-1', '-4', '-p', str(data_port)],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                control = subprocess.Popen([sys.executable, str(ROOT / 'tcp-tuning-control.py'),
                    '--bind', '127.0.0.1', '--port', str(control_port), '--token', 'test',
                    '--state-dir', str(state), '--client', str(ROOT / 'tcp-tuning-client.ps1')],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                client = None
                try:
                    endpoint = f'http://127.0.0.1:{control_port}'
                    for _ in range(50):
                        try:
                            with urlopen(endpoint + '/stage?token=test', timeout=1):
                                break
                        except OSError:
                            time.sleep(0.1)
                    command = (f"$env:DAIMON_IPERF3='{IPERF}'; & '{ROOT / 'tcp-tuning-client.ps1'}' "
                               f"-Control '{endpoint}' -Token test; Write-Output 'PARENT_CONTINUED'")
                    client = subprocess.Popen([shell, '-NoProfile', '-NonInteractive', '-Command', command],
                                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    deadline = time.monotonic() + 30
                    while not (state / 'result-1.json').exists() and time.monotonic() < deadline:
                        if client.poll() is not None:
                            break
                        time.sleep(0.1)
                    if (state / 'result-1.json').exists():
                        result = json.loads((state / 'result-1.json').read_text())
                        self.assertGreater(result['receiver_mbps'], 0)
                        self.assertGreaterEqual(result['seconds'], 0.9)
                        (state / 'stage.json').write_text(json.dumps({'state': 'done', 'id': 1, 'message': 'Test complete'}))
                    output, _ = client.communicate(timeout=10)
                    self.assertEqual(client.returncode, 0, output)
                    self.assertIn('Test complete', output)
                    self.assertIn('PARENT_CONTINUED', output)
                    self.assertEqual(json.loads((state / 'completed.json').read_text()),
                                     {'id': 1, 'state': 'done'})
                finally:
                    for process in (client, server, control):
                        if process and process.poll() is None:
                            process.terminate()
                        if process:
                            process.wait(timeout=5)
                            if process.stdout:
                                process.stdout.close()


if __name__ == '__main__':
    unittest.main()
