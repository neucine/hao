import gzip
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body, content_type="application/json", extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("X-Hao-Test", "yes")
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/download-redirect":
            self._send(302, b"", extra_headers={"Location": "/large"})
            return
        if self.path == "/large":
            body = bytes(range(256)) * 16384
            self._send(200, body, content_type="application/octet-stream", extra_headers={"Content-Length": str(len(body))})
            return
        if self.path in ["/chunked", "/chunked-truncated", "/chunked-compressed"]:
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            if self.path == "/chunked-compressed":
                self.send_header("Content-Encoding", "gzip")
                body = gzip.compress(b"A" * 200000)
            else:
                body = b"chunked payload"
            self.end_headers()
            self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")
            if self.path != "/chunked-truncated":
                self.wfile.write(b"0\r\n\r\n")
            self.close_connection = True
            return
        if self.path == "/compressed-length":
            body = gzip.compress(b"A" * 200000)
            self._send(200, body, extra_headers={"Content-Encoding": "gzip", "Content-Length": str(len(body))})
            return
        if self.path == "/compressed":
            self._send(200, gzip.compress(b"A" * 200000), extra_headers={"Content-Encoding": "gzip"})
            return
        if self.path == "/truncated":
            self._send(200, b"short", extra_headers={"Content-Length": "100000"})
            self.close_connection = True
            return
        if self.path == "/empty":
            self._send(200, b"", extra_headers={"Content-Length": "0"})
            return
        if self.path.startswith("/json"):
            payload = json.dumps({"ok": True, "path": self.path}).encode("utf-8")
            self._send(200, payload)
            return
        if self.path == "/bytes":
            self._send(200, bytes([0, 1, 2, 255]), content_type="application/octet-stream")
            return
        self._send(404, b'{"ok":false}', extra_headers={"X-Missing": "true"})

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size)
        payload = json.dumps({
            "method": "POST",
            "contentType": self.headers.get("Content-Type"),
            "body": body.decode("utf-8"),
        }).encode("utf-8")
        self._send(200, payload)


server = HTTPServer(("127.0.0.1", 0), Handler)
child_pid = os.fork()
if child_pid == 0:
    os.setsid()
    os.close(1)
    os.close(2)
    server.serve_forever()
else:
    print(server.server_address[1], child_pid, flush=True)
