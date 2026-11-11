"""Compare metric validation and nonfinite accumulation with legacy Hao."""

from pathlib import Path
import subprocess
import sys
import tempfile


legacy, port = sys.argv[1:3]
source = '''
import { counter, gauge, histogram, metrics } from "std:telemetry";
const cases = [
  () => counter({scope: "", name: "empty"}),
  () => counter({scope: "bad\\nscope", name: "x"}),
  () => counter({scope: "x", name: "bad\\rname"}),
  () => counter({scope: "x", name: "bad-unit", unit: "bad\\nunit"}),
  () => { const c = counter({scope: "x", name: "counter"}); c.add(-1); },
  () => { const c = counter({scope: "x", name: "counter"}); c.add(NaN); },
  () => { const g = gauge({scope: "x", name: "gauge"}); g.set(NaN); },
  () => { const h = histogram({scope: "x", name: "histogram"}); h.observe(NaN); h.observe(2); },
  () => { const h = histogram({scope: "x", name: "histogram"}); h.observe(-Infinity); },
];
for (const run of cases) {
  try { run(); console.log("ok"); }
  catch (error) { console.log(error.name, error.message); }
}
for (const metric of metrics().filter(item => item.scope === "x")) {
  console.log(metric.name, String(metric.value), metric.count,
              String(metric.sum), String(metric.min), String(metric.max));
}
'''

with tempfile.TemporaryDirectory(prefix="hao-metric-parity-") as directory:
    script = Path(directory) / "metrics.ts"
    script.write_text(source)
    outcomes = []
    for binary in (legacy, port):
        result = subprocess.run((binary, str(script)), capture_output=True)
        outcomes.append((result.returncode, result.stdout, result.stderr))

if outcomes[0] != outcomes[1]:
    print("legacy:", outcomes[0], file=sys.stderr)
    print("port:", outcomes[1], file=sys.stderr)
    raise SystemExit("telemetry metrics differ from legacy")
print("telemetry metric validation and nonfinite values matched legacy")
