"""Compare HTTP URL and method decisions with the legacy runtime."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


legacy, port = sys.argv[1:3]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
urls = [
    "0", "1", "/path", "./path", "127.0.0.1:1", "//127.0.0.1:1/",
    "http://127.0.0.1:1/", "HTTP://127.0.0.1:1/",
    "https://127.0.0.1:1/", "ftp://127.0.0.1:1/", "foo://bar",
    "http:/bad", "http://", "http://?x", "://bad", "", " ",
    "http://host:abc/", "http://host:65536/", "http://host:/",
    "http://[::1]:1/", "http://[::1/", "http://]:1/",
    "http://user@/", "http:///path", "http:////path",
    "http://host space/", "http://host:12x/", "http://host:-1/",
    "http://host:999999999999/", "https://[bad]/",
    f"http://127.0.0.1:+{server.server_port}/",
]
source = '''
import { requestNative } from "std:http/native";
for (const url of URLS) {
  try {
    const response = await requestNative({ url, method: "GET", headers: [] });
    console.log(JSON.stringify(url), response.status, response.url);
  } catch (error) {
    console.log(JSON.stringify(url), error.name, error.message);
  }
}
const base = {url: "http://127.0.0.1:1/", method: "GET", headers: []};
for (const [key, value] of [["url", null], ["url", undefined],
    ["method", null], ["method", undefined], ["maxBytes", null]]) {
  try { await requestNative({...base, [key]: value}); console.log(key, String(value), "ok"); }
  catch (error) { console.log(key, String(value), error.name, error.message); }
}
for (const method of ["GET", "QUERY", "PROPFIND", "get", ""]) {
  try { await requestNative({...base, method}); console.log(method, "ok"); }
  catch (error) { console.log(method, error.name, error.message); }
}
'''.replace("URLS", json.dumps(urls))

try:
    with tempfile.TemporaryDirectory(prefix="hao-http-url-parity-") as directory:
        script = Path(directory) / "urls.ts"
        script.write_text(source)
        outcomes = []
        for binary in (legacy, port):
            result = subprocess.run((binary, str(script)), capture_output=True, timeout=30)
            outcomes.append((result.returncode, result.stdout, result.stderr))
finally:
    server.shutdown()
    server.server_close()

if outcomes[0] != outcomes[1]:
    print("legacy:", outcomes[0], file=sys.stderr)
    print("port:", outcomes[1], file=sys.stderr)
    raise SystemExit("HTTP URL behavior differs from legacy")
print(f"HTTP URL and method differential: {len(urls) + 10} cases matched")
