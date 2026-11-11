#!/usr/bin/env python3
"""Compare server behavior for incomplete and delayed HTTP requests."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

SOURCE = """import { serve } from 'std:http';
const server = serve({ port: 0, requestTimeoutMs: 60,
  async handler(request) {
    await new Promise(resolve => setTimeout(resolve, 10));
    return { body: request.url };
  } });
console.log(server.port);
setTimeout(() => server.close(), 2000);
"""
CASES = [
    [(0, b'GET / HTTP/1.1\r\nHost: x\r\n')],
    [(0, b'GET / HTTP/1.1\r\nHost: x\r\n\r')],
    [(0, b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nab')],
    [(0, b'GET / HTTP/1.1\r\nHost: x\r\n\r\n')],
    [(0, b'GET / HTTP/1.1\r\nHost: x\r\n'),
     (0.02, b'\r\n')],
    [(0, b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nab'),
     (0.02, b'cd')],
]


def run(binary: Path, source: Path) -> list[bytes]:
    process = subprocess.Popen([str(binary), str(source)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    try:
        port = int(process.stdout.readline())
        results = []
        for steps in CASES:
            with socket.create_connection(('127.0.0.1', port), timeout=2) as conn:
                conn.settimeout(2)
                for delay, data in steps:
                    if delay:
                        time.sleep(delay)
                    conn.sendall(data)
                chunks = []
                while part := conn.recv(65536):
                    chunks.append(part)
                results.append(b''.join(chunks))
        return results
    finally:
        process.terminate()
        process.wait(timeout=3)


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: http_server_incomplete_differential.py LEGACY_HAO CYNA_HAO',
              file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='hao-http-incomplete-') as directory:
        source = Path(directory) / 'server.ts'
        source.write_text(SOURCE)
        legacy, cyna = (run(Path(arg).resolve(), source) for arg in sys.argv[1:])
    assert legacy[:3] == [b'', b'', b''], legacy[:3]
    assert all(response.startswith(b'HTTP/1.1 200 ') for response in legacy[3:]), legacy[3:]
    if legacy != cyna:
        for index, (old, new) in enumerate(zip(legacy, cyna)):
            if old != new:
                print(f'case {index}: Zig {old!r}; Cyna {new!r}', file=sys.stderr)
        return 1
    assert len(legacy) == len(CASES)
    print(f'HTTP incomplete requests matched legacy: {len(CASES)} outcomes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
