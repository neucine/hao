# Telemetry

Hao has one telemetry core per runtime. JavaScript, Cyna, native
extensions, QuickJS jobs, timers, and HTTP continuations all feed the same
metric registry, trace context, sequence space, and bounded trace ring in
`src/bridge/telemetry.c`. The JavaScript and console modules are views over
that core; they do not collect or reorder observations independently.

```text
JavaScript | Cyna | native addon | QuickJS jobs | libuv callbacks
                         |
                  telemetry core
                         |
          JavaScript API | console | filtered snapshots
```

## JavaScript API

`std:telemetry` exposes counters, gauges, histograms, metric snapshots, root
and child spans, and the `trace(name, callback)` helper.

```ts
import { counter, metrics, trace } from "std:telemetry"

const calls = counter({ scope: "app", name: "calls", unit: "count" })
calls.add(1)
trace("app.request", () => handleRequest())
console.log(metrics())
```

`trace` closes its span when a synchronous callback finishes or a returned
Promise settles. QuickJS job-context hooks preserve the active trace across
`await`. Timer callbacks, HTTP worker completions, Cyna code, and native
extension callbacks can continue the same trace through the native context
API.

## Trace records

Start, event, and end records use a shared sequence and monotonic clock. Each
record contains trace, span, and parent IDs; name, status, timestamp, and
attributes; plus `source_kind` and `source` metadata. `source_kind` identifies
the emitting layer (`javascript`, `cyna`, or `addon`); `source` identifies the
addon module or other producer.

`snapshotTraceRecordsNative(since, limit, filter)` returns records after a
sequence cursor. Filters can select `source_kind`, `source`, `trace_id`,
`span_id`, `name`, `status`, and `since_ns`. A page contains `next_cursor` and
`missed`; `missed` is true when older matching history has been overwritten.

The ring retains 4096 records by default. Set
`RUNTIME_TELEMETRY_TRACE_RECORDS` to a positive capacity up to 1,048,576 before
startup.

## Console

Set `RUNTIME_TELEMETRY_CONSOLE=1` to start the in-process console on loopback.
`RUNTIME_TELEMETRY_CONSOLE_PORT` chooses its port; zero selects an available
port. The console serves the dashboard, health, metrics, and trace endpoints.
Trace endpoints accept the same sequence, limit, and filter fields as the
native snapshot API.

## Metrics

Metrics include QuickJS memory gauges and process resident and physical
footprint gauges, including observed peaks. On macOS, allocator gauges use
malloc zone totals; on Linux they use `mallinfo2`. Native addon metrics and
JavaScript metrics share the runtime registry.

The Zig implementation remains on the `legacy` branch. The Cyna `main` branch
owns this unified observation plane; neither JavaScript nor the console owns a
second trace store.
