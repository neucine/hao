"""Compare complete HTTP/1.x request framing through the public server."""
import itertools
from pathlib import Path
import socket
import subprocess
import sys

fixture = Path(__file__).with_name('http_server_fixture.ts').resolve()
methods=[b'GET',b'get',b'POST',b'OPTIONS',b'HEAD',b'PATCH',b'G@T']
targets=[b'/',b'/%2f',b'//',b'/a?b',b'*',b'/\xff',b'/\x7f']
versions=[b'HTTP/1.0',b'HTTP/1.1',b'HTTP/2.0']
headers=[b'Host: x\r\n',b'Host: x\r\nContent-Length: 0\r\n',b'Host: x\r\nConnection: keep-alive\r\n',b'Host: x\r\nX-A: b\r\n']
cases=[]
for m,t,v,h in itertools.product(methods,targets,versions,headers):
    cases.append(m+b' '+t+b' '+v+b'\r\n'+h+b'\r\n')

def run(binary):
    server=subprocess.Popen([binary,fixture],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        port=int(server.stdout.readline())
        out=[]
        for payload in cases:
            with socket.create_connection(('127.0.0.1',port),timeout=3) as s:
                s.settimeout(3)
                s.sendall(payload)
                chunks=[]
                while True:
                    data=s.recv(65536)
                    if not data: break
                    chunks.append(data)
                out.append(b''.join(chunks))
        return out
    finally:
        server.terminate()
        server.wait(timeout=5)
def main():
    if len(sys.argv) != 3:
        print('usage: http_server_framing_differential.py LEGACY_HAO CYNA_HAO', file=sys.stderr)
        return 2
    legacy, cyna = (run(str(Path(path).resolve())) for path in sys.argv[1:])
    differences = [(i, cases[i], legacy[i][:200], cyna[i][:200])
                   for i in range(len(cases)) if legacy[i] != cyna[i]]
    for difference in differences[:15]:
        print(repr(difference), file=sys.stderr)
    if differences:
        print(f'{len(differences)} of {len(cases)} HTTP responses differ', file=sys.stderr)
        return 1
    print(f'HTTP server framing matched legacy: {len(cases)} responses')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
