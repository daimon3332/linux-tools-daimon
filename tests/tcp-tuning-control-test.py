import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent


class ControlServerTest(unittest.TestCase):
    def test_authenticated_stage_and_result(self):
        (ROOT / ".tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as directory:
            state = Path(directory)
            (state / "stage.json").write_text(
                json.dumps({"state": "ready", "id": 1, "family": 4}), encoding="utf-8"
            )
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            server = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "tcp-tuning-control.py"),
                    "--bind", "127.0.0.1",
                    "--port", str(port),
                    "--token", "secret",
                    "--state-dir", str(state),
                    "--client", str(ROOT / "tcp-tuning-client.ps1"),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                url = f"http://127.0.0.1:{port}"
                for _ in range(30):
                    try:
                        with urlopen(f"{url}/stage?token=secret", timeout=1) as reply:
                            self.assertEqual(json.load(reply)["id"], 1)
                        break
                    except OSError:
                        time.sleep(0.1)
                else:
                    self.fail("control server did not start")

                with self.assertRaises(HTTPError) as denied:
                    urlopen(f"{url}/stage?token=wrong")
                self.assertEqual(denied.exception.code, 403)
                with urlopen(f"{url}/client?token=secret") as reply:
                    self.assertIn(b"receiver_mbps", reply.read())

                result = {"id": 1, "family": 4, "receiver_mbps": 123.5,
                          "bytes": 1000000, "retrans": 2}
                request = Request(f"{url}/result?token=secret",
                                  data=json.dumps(result).encode(), method="POST")
                with urlopen(request) as reply:
                    self.assertTrue(json.load(reply)["accepted"])
                self.assertEqual(json.loads((state / "result-1.json").read_text()), result)
                with self.assertRaises(HTTPError) as duplicate:
                    urlopen(request)
                self.assertEqual(duplicate.exception.code, 400)
                result["id"] = 2
                with self.assertRaises(HTTPError) as stale:
                    urlopen(Request(f"{url}/result?token=secret",
                                    data=json.dumps(result).encode(), method="POST"))
                self.assertEqual(stale.exception.code, 400)
            finally:
                server.terminate()
                server.wait(timeout=5)
                server.stderr.close()


if __name__ == "__main__":
    unittest.main()
