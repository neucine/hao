#!/usr/bin/env python3
"""Compare HTTP method and body behavior across local redirects."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def do_PUT(self):
        self.respond()

    def do_HEAD(self):
        self.respond()

    def respond(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        path = self.path.split('?', 1)[0]
        if path.startswith('/root/location/') and path.rsplit('/', 1)[1].isdigit() and '?' not in self.path:
            locations = ['final', '../final', '/final', '?q=1',
                         f'//127.0.0.1:{self.server.server_port}/final',
                         f'http://127.0.0.1:{self.server.server_port}/final']
            self.send_response(303)
            self.send_header('Location', locations[int(path.rsplit('/', 1)[1])])
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/chain/'):
            count = int(self.path.rsplit('/', 1)[1])
            self.send_response(302)
            self.send_header('Location', f'/chain/{count - 1}' if count > 1 else '/redirect/303')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/redirect/'):
            code = int(self.path.rsplit('/', 1)[1])
            self.send_response(code)
            self.send_header('Location', '/final')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        data = json.dumps({'method': self.command, 'body': body.decode(),
                           'header': self.headers.get('X-Probe')},
                          separators=(',', ':')).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def log_message(self, *_args):
        pass


def run(binary: Path, source: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run([str(binary), str(source)], cwd=source.parent,
                            capture_output=True, timeout=15)
    return result.returncode, result.stdout, result.stderr


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: http_redirect_method_differential.py LEGACY_HAO CYNA_HAO', file=sys.stderr)
        return 2
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='hao-http-redirect-') as directory:
            source = Path(directory) / 'redirect.ts'
            source.write_text("import { request } from 'std:http';\n"
                "for (const [method, body, code, redirect] of "
                "[['POST', 'payload', 301], ['POST', 'payload', 302], "
                "['POST', 'payload', 303], ['POST', 'payload', 307], "
                "['POST', 'payload', 308], ['POST', undefined, 301], "
                "['POST', undefined, 307], ['GET', undefined, 307], "
                "['GET', undefined, 308], ['GET', 'payload', 301], "
                "['GET', 'payload', 303], ['GET', 'payload', 307], ['PUT', 'payload', 301], "
                "['PUT', 'payload', 303], ['PUT', 'payload', 307], "
                "['HEAD', undefined, 301], ['HEAD', undefined, 303], "
                "['HEAD', undefined, 307], ['HEAD', 'payload', 303], "
                "['POST', 'payload', 307, 'manual']]) {\n"
                f"  try {{ const response = await request('http://127.0.0.1:{server.server_port}/redirect/' + code, "
                "{ method, body, redirect, headers: { 'X-Probe': 'value' } });\n"
                "    console.log(method, body === undefined ? 'empty' : 'body', code, "
                "redirect ?? 'follow', response.status, response.text()); }\n"
                "  catch (error) { console.log(method, body === undefined ? 'empty' : 'body', "
                "code, redirect ?? 'follow', error.name, error.message); }\n"
                "}\n"
                f"for (const method of ['GET', 'PUT']) {{ const response = await request('http://127.0.0.1:{server.server_port}/final', "
                "{ method, body: 'payload' }); console.log('direct', method, response.text()); }\n"
                f"for (const count of [2, 3]) {{ try {{ const response = await request('http://127.0.0.1:{server.server_port}/chain/' + count, "
                "{ method: 'PUT' }); console.log('chain', count, response.status, response.text()); }\n"
                "catch (error) { console.log('chain', count, error.name, error.message); } }\n"
                f"for (let index = 0; index < 6; index++) {{ const response = await request('http://127.0.0.1:{server.server_port}/root/location/' + index, "
                "{ method: 'PUT', body: 'payload' });\n"
                "console.log('location', index, response.status, response.url, response.text()); }\n")
            legacy, cyna = (run(Path(arg).resolve(), source) for arg in sys.argv[1:])
        if legacy != cyna:
            print('HTTP redirect method behavior differs from Zig', file=sys.stderr)
            print('legacy:', repr(legacy), file=sys.stderr)
            print('cyna:', repr(cyna), file=sys.stderr)
            return 1
        assert legacy[0] == 0 and len(legacy[1].splitlines()) == 30, legacy
        print('HTTP redirect methods matched legacy: 30 outcomes')
        return 0
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
