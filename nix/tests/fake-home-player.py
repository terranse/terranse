"""A stand-in for home-player's backend, driven by two files.

/health and /system/activity are the whole contract the update policy depends
on, and both answers come from /run/fake-backend, so the test flips "busy" or
"unhealthy" with one echo. POST /home-assistant/tv/on appends a line to
/run/fake-backend/tv-on, so a test can count how often the TV was asked to wake.
"""

import http.server
import json
import pathlib

STATE = pathlib.Path("/run/fake-backend")


def flag(name, default):
    try:
        return (STATE / name).read_text().strip() == "true"
    except OSError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            ok = flag("healthy", True)
            code = 200 if ok else 503
            body = json.dumps({"status": "ok" if ok else "unhealthy"})
        elif self.path == "/system/activity":
            code = 200
            body = json.dumps({"busy": flag("busy", False)})
        else:
            code = 404
            body = "{}"

        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path == "/home-assistant/tv/on":
            with (STATE / "tv-on").open("a") as calls:
                calls.write("on\n")
            code = 200
        else:
            code = 404
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 9600), Handler).serve_forever()
