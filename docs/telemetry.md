# Telemetry

`std:telemetry` exposes counters, gauges, histograms, metric snapshots, root
and child spans, and the `trace(name, callback)` helper. The Cyna runtime
stores metrics per runtime in its native adapter. Trace spans and a bounded
record buffer currently live in `cyna/src/std/telemetry/native.ts`.

```ts
import { counter, metrics, trace } from "std:telemetry"

const calls = counter({ scope: "app", name: "calls", unit: "count" })
calls.add(1)
trace("app.request", () => handleRequest())
console.log(metrics())
```

`trace` closes its span when a synchronous callback finishes or a returned
Promise settles. The timer wrapper captures the active span at scheduling time
and restores it while the callback runs. General context propagation across
`await`, HTTP worker completions, and native addon callbacks is not yet
implemented. Span events and attributes are also absent from the Cyna trace
records. Do not use the current trace output as a complete distributed trace.

Set `RUNTIME_TELEMETRY_CONSOLE=1` to start the in-process console on loopback.
`RUNTIME_TELEMETRY_CONSOLE_PORT` chooses its port; zero selects an available
port. The console serves the dashboard, health, metric, and trace endpoints.
The trace endpoint returns up to 512 retained start and end records with
sequence cursors and a `missed` flag when history has been overwritten.

Metrics include QuickJS memory gauges and process resident and physical
footprint gauges, including their observed peaks. On macOS, allocator gauges
use malloc zone totals. The addon metric callbacks share the same metric
registry as `std:telemetry`.

The Zig telemetry implementation, including its native trace core and exporter
policy, remains on the `legacy` branch while the Cyna parity work continues.
