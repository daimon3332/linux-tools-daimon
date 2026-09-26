#!/usr/bin/env python3
"""Short-lived, token-protected result channel for the TCP benchmark."""

import argparse
import hmac
import json
import math
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--client", type=Path, required=True)
    args = parser.parse_args()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def authorized(self):
            supplied = parse_qs(urlsplit(self.path).query).get("token", [""])[0]
            if not hmac.compare_digest(supplied, args.token):
                self.send_error(403)
                return False
            return True

        def respond(self, data, content_type="application/json"):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.authorized():
                return
            path = urlsplit(self.path).path
            if path == "/client":
                self.respond(args.client.read_bytes(), "text/plain; charset=utf-8")
            elif path == "/stage":
                stage = args.state_dir / "stage.json"
                self.respond(stage.read_bytes() if stage.exists() else b'{"state":"waiting"}')
            else:
                self.send_error(404)

        def do_POST(self):
            if not self.authorized():
                return
            path = urlsplit(self.path).path
            if path not in ("/result", "/abort"):
                self.send_error(404)
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 16384:
                    raise ValueError("invalid payload size")
                result = json.loads(self.rfile.read(size))
                if path == "/abort":
                    reason = str(result.get("reason", "client aborted"))[:200]
                    target = args.state_dir / "abort.json"
                    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                        json.dump({"reason": reason}, output)
                        output.write("\n")
                    self.respond(b'{"accepted":true}')
                    return
                stage = json.loads((args.state_dir / "stage.json").read_text())
                if stage.get("state") != "ready" or result.get("id") != stage.get("id"):
                    raise ValueError("stale stage")
                if result.get("family") != stage.get("family"):
                    raise ValueError("wrong IP family")
                rate = float(result["receiver_mbps"])
                transferred = int(result["bytes"])
                retrans = int(result.get("retrans", 0))
                if not math.isfinite(rate) or rate <= 0 or transferred <= 0 or retrans < 0:
                    raise ValueError("invalid measurement")
                target = args.state_dir / f'result-{stage["id"]}.json'
                descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                    json.dump(result, output)
                    output.write("\n")
                self.respond(b'{"accepted":true}')
            except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
                self.send_error(400)

    if ":" in args.bind:
        class IPv6Server(ThreadingHTTPServer):
            address_family = socket.AF_INET6

        server = IPv6Server((args.bind, args.port), Handler)
    else:
        server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
