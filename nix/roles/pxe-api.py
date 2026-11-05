#!/usr/bin/env python3
# Pixiecore's API server: a boot answer for one MAC, 404 for every other.
#
#   pxe-api.py <mac> <image-dir> <port>
#
# Pixiecore asks GET /v1/boot/<mac> for every PXE client it sees and boots
# only those that get a 200. <image-dir> holds bzImage, initrd and cmdline
# (the flake's htpc-netboot package). Pixiecore fetches the kernel and initrd
# from here and serves them to the client itself, so this listens on loopback
# only. The shape is the one proven on herdr's ~/pxe-spike/api.py.
import json
import os
import shutil
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ALLOW = sys.argv[1].lower()
IMAGE = sys.argv[2]
PORT = int(sys.argv[3])
BASE = f"http://127.0.0.1:{PORT}"
FILES = {"/bzImage": "bzImage", "/initrd": "initrd"}

with open(os.path.join(IMAGE, "cmdline")) as f:
    CMDLINE = f.read().strip()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v1/boot/"):
            mac = unquote(self.path[len("/v1/boot/"):]).lower()
            allowed = mac == ALLOW
            print(
                time.strftime("%T"),
                "boot request from",
                mac or "(none)",
                "allowed" if allowed else "IGNORED",
                flush=True,
            )
            if not allowed:
                self.send_error(404)
                return
            body = json.dumps(
                {
                    "kernel": f"{BASE}/bzImage",
                    "initrd": [f"{BASE}/initrd"],
                    "cmdline": CMDLINE,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in FILES:
            path = os.path.join(IMAGE, FILES[self.path])
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.stat(path).st_size))
            self.end_headers()
            with open(path, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            return
        self.send_error(404)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
