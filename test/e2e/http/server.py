import json
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
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

    def do_GET(self):
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
print(server.server_address[1], flush=True)
server.serve_forever()
