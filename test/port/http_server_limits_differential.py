"""Compare native HTTP server option validation with legacy Hao."""

from pathlib import Path
import subprocess
import sys
import tempfile


legacy, port = sys.argv[1:3]
source = '''
import { serveNative, stopServerNative } from "std:http/native";
const defaults = {hostname: "127.0.0.1", port: 0,
                  maxConnections: 8, requestTimeoutMs: 1000};
const cases = [
  ["port", -1], ["port", 65536], ["port", 1.5], ["port", null],
  ["port", "0"], ["port", NaN], ["port", Infinity], ["port", -0],
  ["port", 0.5], ["port", 9007199254740992],
  ["maxConnections", 0], ["maxConnections", 1025],
  ["maxConnections", null], ["maxConnections", 1.5],
  ["maxConnections", NaN], ["maxConnections", Infinity],
  ["requestTimeoutMs", 0], ["requestTimeoutMs", 3600001],
  ["requestTimeoutMs", null], ["requestTimeoutMs", 1.5],
  ["requestTimeoutMs", NaN],
  ["hostname", null], ["hostname", "bad"],
  ["hostname", "0.0.0.0"], ["hostname", "127.0.0.1\\0bad"],
  ["hostname", Symbol("x")], ["hostname", 0],
  ["hostname", undefined], ["hostname", true], ["hostname", {}],
  ["hostname", ""], ["hostname", "::1"], ["hostname", "127.0.0.1 "],
  ["port", 1n], ["port", Symbol("x")],
  ["port", {valueOf() { return 0; }}],
  ["maxConnections", "8"], ["requestTimeoutMs", true],
];
for (const [index, [key, value]] of cases.entries()) {
  try {
    const server = serveNative({...defaults, [key]: value}, () => {});
    console.log(index, key, "ok");
    stopServerNative(server.id);
  } catch (error) {
    console.log(index, key, error.name, error.message);
  }
}
'''

with tempfile.TemporaryDirectory(prefix="hao-server-limits-") as directory:
    script = Path(directory) / "limits.ts"
    script.write_text(source)
    outcomes = []
    for binary in (legacy, port):
        result = subprocess.run((binary, str(script)), capture_output=True, timeout=30)
        outcomes.append((result.returncode, result.stdout, result.stderr))

if outcomes[0] != outcomes[1]:
    print("legacy:", outcomes[0], file=sys.stderr)
    print("port:", outcomes[1], file=sys.stderr)
    raise SystemExit("HTTP server option behavior differs from legacy")
print(f"HTTP server limit differential: {len(outcomes[0][1].splitlines())} cases matched")
