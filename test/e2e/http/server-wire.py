# Raw wire checks for the native server; Python is only a test client.
import socket
import sys
import time

import subprocess
import atexit
server = subprocess.Popen([sys.argv[1], 'test/e2e/http/server-fixture.ts'], stdout=subprocess.PIPE, text=True)
def cleanup():
    server.terminate()
    server.wait(timeout=5)
atexit.register(cleanup)
port = int(server.stdout.readline())
def exchange(parts):
    with socket.create_connection(('127.0.0.1', port), timeout=2) as s:
        for part in parts:
            s.sendall(part)
            if len(parts) > 1:
                time.sleep(.01)
        out = b''
        while True:
            data = s.recv(65536)
            if not data:
                return out
            out += data

def status(raw, expected):
    out = exchange([raw])
    assert out.startswith(f'HTTP/1.1 {expected} '.encode()), (expected, out)

status(b'GET / HTTP/1.1\r\n\r\n', 400)
status(b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx', 400)
status(b'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n', 501)
status(b'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n', 400)
status(b'GET / HTTP/1.1\r\nHost: x\r\nX: a\r\r\n\r\n', 400)
status(b'GET / HTTP/1.1\r\nHost: x\r\nX: ' + b'x' * 17000 + b'\r\n\r\n', 431)
status(b'POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n', 417)
out = exchange([b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r', b'\n\r\na', b'\x00bc'])
assert out.endswith(b'a\x00bc'), out
assert exchange([b'GET / HTTP/1.1\r\nHost:']) == b''  # incomplete request deadline
assert exchange([b'GET /slow HTTP/1.1\r\nHost: x\r\n\r\n']) == b'' # handler deadline
# Allow the timed-out async handler to settle safely.
time.sleep(.2)
status(b'GET / HTTP/1.1\r\nHost: x\r\n\r\n', 200)
print('wire framing and deadline checks passed')
