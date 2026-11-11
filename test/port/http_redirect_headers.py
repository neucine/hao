#!/usr/bin/env python3
"""Check sensitive headers on same-origin and cross-origin redirects."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread


class Handler(BaseHTTPRequestHandler):
    target_port = 0

    def do_GET(self):
        self.respond()

    def do_PUT(self):
        self.respond()

    def respond(self):
        if self.path in ('/same', '/cross'):
            location = '/final' if self.path == '/same' else f'http://127.0.0.1:{self.target_port}/final'
            self.send_response(303)
            self.send_header('Location', location)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        data = json.dumps({
            'method': self.command,
            'authorization': self.headers.get('Authorization'),
            'cookie': self.headers.get('Cookie'),
            'probe': self.headers.get('X-Probe'),
        }, separators=(',', ':')).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: http_redirect_headers.py CYNA_HAO', file=sys.stderr)
        return 2
    source_server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    target_server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    Handler.target_port = target_server.server_port
    threads = [Thread(target=server.serve_forever, daemon=True)
               for server in (source_server, target_server)]
    for thread in threads:
        thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='hao-http-redirect-headers-') as directory:
            script = Path(directory) / 'probe.ts'
            script.write_text("import { request } from 'std:http';\n"
                "for (const method of ['GET', 'PUT']) for (const path of ['same', 'cross']) {\n"
                f"  const response = await request('http://127.0.0.1:{source_server.server_port}/' + path, "
                "{ method, headers: { Authorization: 'secret', Cookie: 'a=b', 'X-Probe': 'value' } });\n"
                "  console.log(method, path, response.text());\n"
                "}\n")
            result = subprocess.run([str(Path(sys.argv[1]).resolve()), str(script)],
                                    cwd=directory, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0 and result.stderr == '', result
        lines = result.stdout.splitlines()
        assert len(lines) == 4, lines
        for line in lines:
            method, path, payload = line.split(' ', 2)
            received = json.loads(payload)
            assert received['method'] == ('GET' if method == 'PUT' else method), line
            assert received['probe'] == 'value', line
            assert received['authorization'] == ('secret' if path == 'same' else None), line
            assert received['cookie'] == ('a=b' if path == 'same' else None), line
        print('HTTP redirect headers: same origin retained, cross origin stripped')
        return 0
    finally:
        for server in (source_server, target_server):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
