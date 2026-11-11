import http.client
import pathlib
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

runtime = pathlib.Path(sys.argv[1]).resolve()
fixture = pathlib.Path(__file__).with_name('http_server_fixture.ts')
server = subprocess.Popen([str(runtime), str(fixture)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    port_line = server.stdout.readline()
    assert port_line, server.stderr.read()
    port = int(port_line)

    def request(method, path, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.getheaders(), response.read()
        finally:
            connection.close()

    def raw_request(payload):
        with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
            connection.settimeout(2)
            connection.sendall(payload)
            chunks = []
            while part := connection.recv(65536):
                chunks.append(part)
            return b''.join(chunks)

    response_head = b'HTTP/1.1 200 Response\r\nConnection: close\r\nX-Test: yes\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 17\r\n\r\n'
    response_body = 'Hello 世界 🐈'.encode()
    assert raw_request(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n') == response_head + response_body
    assert raw_request(b'GET / HTTP/1.0\r\n\r\n') == response_head + response_body
    assert raw_request(b'HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n') == response_head
    assert raw_request(b'GET / HTTP/1.1\r\n\r\n') == (
        b'HTTP/1.1 400 Response\r\nConnection: close\r\n'
        b'Content-Type: text/plain; charset=utf-8\r\nContent-Length: 8\r\n\r\nHTTP 400')

    status, headers, body = request('GET', '/')
    assert status == 200 and body == 'Hello 世界 🐈'.encode()
    assert dict(headers)['X-Test'] == 'yes'
    status, _, body = request('POST', '/json', '{"answer":42}', {'Content-Type': 'application/json'})
    assert status == 200 and b'"method":"POST"' in body and b'"answer":42' in body
    status, _, body = request('POST', '/bytes', bytes([0, 255, 42]))
    assert status == 200 and body == bytes([0, 255, 42])
    status, _, body = request('HEAD', '/')
    assert status == 200 and body == b''
    for path in ('/error', '/invalid-header'):
        assert request('GET', path)[0] == 500
    for _ in range(3):
        assert request('GET', '/')[0] == 200
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda value: request('POST', '/json',
            f'{{"request":{value}}}', {'Content-Type': 'application/json'}), range(8)))
    for index, (status, _, body) in enumerate(results):
        assert status == 200 and f'"request":{index}'.encode() in body
    framing = [
        (b'GET / HTTP/1.0\r\n\r\n', 200),
        (b'GET / HTTP/1.1\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost:\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost: x\r\nX-Test: a\r\n b\r\n\r\n', 400),
        (b'GET http://localhost/ HTTP/1.1\r\nHost: x\r\n\r\n', 400),
        (b'GET  / HTTP/1.1\r\nHost: x\r\n\r\n', 400),
        (b'GET\t/ HTTP/1.1\r\nHost: x\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost : x\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost:\tx\r\n\r\n', 200),
        (b'GET / HTTP/1.1\r\nHost: x\r\nX-Dup: a\r\nX-Dup: b\r\n\r\n', 200),
        (b'G@T / HTTP/1.1\r\nHost: x\r\n\r\n', 400),
        (b'GET / HTTP/2.0\r\nHost: x\r\n\r\n', 400),
        (b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length:  0 \r\n\r\n', 200),
        (b'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n', 400),
        (b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +0\r\n\r\n', 400),
        (b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 00\r\n\r\n', 400),
        (b'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\t\r\n\r\n', 200),
        (b'GET / HTTP/1.1\r\nHost: \xff\r\n\r\n', 200),
        (b'GET / HTTP/1.1\r\nHost: x\x00y\r\n\r\n', 400),
        (b'GET /%2f HTTP/1.1\r\nHost: x\r\n\r\n', 200),
        (b'get / HTTP/1.1\r\nHost: x\r\n\r\n', 200),
        (b'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n', 200),
        (b'GET / HTTP/1.1\r\nHost: x\r\nX-V: a\rb\r\n\r\n', 400),
        (b'GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n', 400),
        (b'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n', 501),
        (b'POST /bytes HTTP/1.1\r\nHost: x\r\nContent-Length: 1 \r\n\r\na', 200),
        (b'POST /bytes HTTP/1.1\r\nHost: x\r\nContent-Length: 1\t\r\n\r\na', 200),
        (b'POST /bytes HTTP/1.1\r\nHost: x\r\nContent-Length: 01\r\n\r\na', 400),
        (b'POST / HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\n\r\n', 417),
        (b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n', 413),
        (b'GET / HTTP/1.1\r\nHost: localhost\r\nX-Large: ' + b'x' * 16384 + b'\r\n\r\n', 431),
    ]
    for payload, expected in framing:
        response = raw_request(payload)
        assert response.startswith(f'HTTP/1.1 {expected} '.encode()), response[:120]
    pipelined = raw_request(
        b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'
        b'GET /json HTTP/1.1\r\nHost: localhost\r\n\r\n')
    assert pipelined.count(b'HTTP/1.1 ') == 1 and b'Hello ' in pipelined
    with socket.create_connection(('127.0.0.1', port), timeout=2) as partial, \
            socket.create_connection(('127.0.0.1', port), timeout=2) as header_partial:
        partial.settimeout(2)
        header_partial.settimeout(2)
        partial.sendall(b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 20\r\n\r\nshort')
        header_partial.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n')
        try:
            request('GET', '/stop')
            raise AssertionError('closing the server should close its active client')
        except http.client.RemoteDisconnected:
            pass
        assert partial.recv(1) == b'', 'closing the server should close an incomplete request'
        assert header_partial.recv(1) == b'', 'closing the server should close incomplete headers'
    assert server.wait(timeout=3) == 0
    assert server.stdout.read() == 'stop entered\nstop settled\n'
    print('HTTP server behavior checks passed')
finally:
    server.terminate()
    server.wait(timeout=5)
