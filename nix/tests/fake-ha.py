"""A stand-in for Home Assistant's notify API.

Every POST to /api/services/notify/<service> appends one JSON line to
/run/fake-ha/calls with the service, whether the bearer token was the expected
one, and the title and message. Answers 503 while /run/fake-ha/refuse exists,
so a test can have Home Assistant reachable but unwilling, and waits a minute
before answering while /run/fake-ha/hang exists.
"""

import http.server
import json
import pathlib
import time

DIR = pathlib.Path("/run/fake-ha")
TOKEN = "test-ha-token"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        prefix = "/api/services/notify/"
        if (DIR / "hang").exists():
            time.sleep(60)
        if not self.path.startswith(prefix) or (DIR / "refuse").exists():
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.loads(raw or b"{}")
        record = {
            "service": self.path[len(prefix):],
            "auth_ok": self.headers.get("Authorization") == f"Bearer {TOKEN}",
            "title": body.get("title"),
            "message": body.get("message"),
        }
        with (DIR / "calls").open("a") as f:
            f.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"[]")

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 8123), Handler).serve_forever()
