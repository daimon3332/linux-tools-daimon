import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
BASH = os.environ.get('BASH_BIN') or shutil.which('bash')
SHELLS = [path for name in ('powershell', 'pwsh') if (path := shutil.which(name))]
FINISH = '''
source ./tcp-tuning-lab.sh
DAIMON_TCP_LAB_DIR="$1"
command -v cygpath >/dev/null 2>&1 && DAIMON_TCP_LAB_DIR=$(cygpath -u "$1")
DAIMON_TCP_LAB_ROUND=1
DAIMON_TCP_LAB_IP4=127.0.0.1
DAIMON_TCP_LAB_PORT=50280
DAIMON_TCP_LAB_DURATION=1
DAIMON_TCP_LAB_OMIT=0
DAIMON_TCP_LAB_FINISH_WAIT="$2"
daimon_tcp_lab_finish done 'Final result received'
'''


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


@unittest.skipUnless(BASH, 'Bash required')
class CompletionTest(unittest.TestCase):
    def test_no_ack_has_bounded_wait(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
            result = subprocess.run([BASH, '-c', FINISH, 'finish', directory, '1'], cwd=ROOT,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                encoding='utf-8', errors='replace', timeout=4)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('客户端未确认', result.stdout)

    @unittest.skipUnless(SHELLS, 'PowerShell required')
    def test_lost_ack_response_does_not_fail_a_received_success(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                paths = []

                class Handler(http.server.BaseHTTPRequestHandler):
                    def log_message(self, *_args):
                        pass

                    def do_GET(self):
                        data = b'{"state":"done","id":1,"message":"Final result received"}'
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)

                    def do_POST(self):
                        self.rfile.read(int(self.headers['Content-Length']))
                        paths.append(self.path.split('?')[0])
                        self.send_error(503)

                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    env = os.environ.copy()
                    env['DAIMON_IPERF3'] = sys.executable
                    command = (f"& '{ROOT / 'tcp-tuning-client.ps1'}' -Control "
                               f"'http://127.0.0.1:{server.server_port}' -Token test; 'PARENT_CONTINUED'")
                    result = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-Command', command],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, encoding='utf-8', errors='replace', timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertIn('Final result received', result.stdout)
                    self.assertIn('PARENT_CONTINUED', result.stdout)
                    self.assertEqual(paths, ['/ack', '/ack', '/ack'])
                finally:
                    server.shutdown()
                    server.server_close()

    @unittest.skipUnless(SHELLS, 'PowerShell required')
    def test_delayed_reply_still_acknowledges_final_result(self):
        (ROOT / '.tmp').mkdir(exist_ok=True)
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir=ROOT / '.tmp') as directory:
                state = Path(directory)
                (state / 'stage.json').write_text(json.dumps({'state': 'processing', 'id': 1}))
                port = free_port()
                endpoint = f'http://127.0.0.1:{port}'
                captured = threading.Event()

                class Proxy(http.server.BaseHTTPRequestHandler):
                    def log_message(self, *_args):
                        pass

                    def forward(self, data=None):
                        try:
                            with urlopen(Request(endpoint + self.path, data=data), timeout=5) as reply:
                                body = reply.read()
                            if data is None:
                                captured.set()
                                time.sleep(3)
                            self.send_response(200)
                            self.send_header('Content-Length', str(len(body)))
                            self.end_headers()
                            self.wfile.write(body)
                        except OSError:
                            self.send_error(502)

                    def do_GET(self):
                        self.forward()

                    def do_POST(self):
                        self.forward(self.rfile.read(int(self.headers['Content-Length'])))

                proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
                proxy.daemon_threads = True
                threading.Thread(target=proxy.serve_forever, daemon=True).start()
                control = subprocess.Popen([sys.executable, str(ROOT / 'tcp-tuning-control.py'),
                    '--bind', '127.0.0.1', '--port', str(port), '--token', 'test', '--state-dir', directory,
                    '--client', str(ROOT / 'tcp-tuning-client.ps1')],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                client = finisher = None
                try:
                    for _ in range(50):
                        try:
                            with urlopen(endpoint + '/stage?token=test', timeout=1):
                                break
                        except OSError:
                            time.sleep(0.1)
                    env = os.environ.copy()
                    env['DAIMON_IPERF3'] = sys.executable
                    command = (f"& '{ROOT / 'tcp-tuning-client.ps1'}' -Control "
                               f"'http://127.0.0.1:{proxy.server_port}' -Token test; 'PARENT_CONTINUED'")
                    client = subprocess.Popen([shell, '-NoProfile', '-NonInteractive', '-Command', command],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                        encoding='utf-8', errors='replace')
                    self.assertTrue(captured.wait(10), 'client did not poll the stage')
                    finisher = subprocess.Popen([BASH, '-c', FINISH, 'finish', directory, '12'], cwd=ROOT,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    deadline = time.monotonic() + 25
                    while client.poll() is None and time.monotonic() < deadline:
                        if finisher.poll() is not None and control.poll() is None:
                            control.terminate()
                            control.wait(timeout=5)
                        time.sleep(0.05)
                    output, _ = client.communicate(timeout=2)
                    self.assertEqual(client.returncode, 0, output)
                    self.assertIn('Final result received', output)
                    self.assertIn('PARENT_CONTINUED', output)
                    self.assertEqual(json.loads((state / 'completed.json').read_text()),
                                     {'id': 1, 'state': 'done'})
                    self.assertEqual(finisher.wait(timeout=3), 0)
                finally:
                    for process in (client, finisher, control):
                        if process and process.poll() is None:
                            process.terminate()
                        if process:
                            process.wait(timeout=5)
                            if process.stdout:
                                process.stdout.close()
                    proxy.shutdown()
                    proxy.server_close()


if __name__ == '__main__':
    unittest.main()
