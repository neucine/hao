# Telemetry

Hao telemetry has three related signals:

- Metrics are aggregate numeric state.
- Spans represent a duration.
- Events represent a timestamped occurrence inside a span.

A trace is the stream of span and event records connected by `trace_id` and
`span_id`.

## Current Status

The runtime-independent trace core is available from `hao.telemetry.trace`.
It owns bounded record storage, span identity, parent relationships, attribute
copying, and sampling decisions.

The TypeScript and addon bindings are not connected yet. The examples below
describe the intended contract for those layers.

## TypeScript

The planned TypeScript API will use the current context when starting a span:

```ts
import { startSpan } from "std:telemetry"

const span = startSpan("http.request", {
  kind: "server",
  attributes: {
    "http.method": "GET",
    "http.route": "/users",
  },
})

try {
  span.addEvent("request.headers.received", {
    "http.content_length": 128,
  })
  await handleRequest()
  span.setStatus("ok")
} catch (error) {
  span.setStatus("error")
  span.addEvent("exception", { message: String(error) })
  throw error
} finally {
  span.end()
}
```

Attributes describe the span's operation. Event attributes describe one
occurrence at one timestamp. Names should remain stable; dynamic values belong
in attributes.

Async context must be captured when a Promise continuation, timer, or native
callback is registered, then restored while that callback runs. This is still
runtime integration work and is not implemented by the core buffer.

## Native Addons And Threads

Native code should receive a small copyable trace context, not a QuickJS value:

```text
TraceContext {
  trace_id
  span_id
  sampled
}
```

The intended addon flow is:

```text
Hao callback thread:
  capture current TraceContext
  pass TraceContext to worker thread

Worker thread:
  do native work
  keep away from QuickJS values and APIs

Hao event-loop thread:
  restore TraceContext
  create or finish the native child span
  emit completion events
```

The context is safe to copy across threads. `JsValue` handles and JavaScript
objects are not. Native worker threads must marshal JavaScript interaction and
span ownership back to Hao's runtime/event-loop thread.

The addon ABI will eventually expose context capture, context restore, span
lifecycle, span attributes, and span events. The ABI shape is intentionally
deferred until async propagation and record ownership are stable.

## Buffer And Sampling

Trace records are kept in bounded storage. Recording must never block script
execution or a native worker. Sampling is decided at the trace root and
inherited by child spans and events, so one trace is not accidentally split by
independent event sampling.

Each retained record has a monotonic sequence number. A future telemetry
consumer can request records after a cursor and receive a `missed` indication
when the ring has already overwritten part of the requested history. This
allows the browser console to poll incrementally, deduplicate records, and mark
large or incomplete traces honestly.

The host will eventually choose the sampling and export policy. The core does
not write logs, export spans, or impose an OpenTelemetry transport.

## Telemetry Console

The first telemetry console will run in-process with the Hao host. It can read
the metrics registry and trace buffer directly, avoiding an IPC protocol while
the runtime APIs are still evolving. The host owns its lifecycle and should
bind to loopback by default.

The browser-facing HTTP and cursor contracts should remain independent of this
implementation choice. A later version may move the console into a dedicated
thread or process without changing the dashboard protocol.

Enable it for a local CLI run with:

```sh
HAO_TELEMETRY_CONSOLE=1 HAO_TELEMETRY_CONSOLE_PORT=0 hao path/to/main.ts
```

Hao prints the loopback URL when the console starts. The current endpoints are:

- `GET /` for the dashboard
- `GET /api/health`
- `GET /api/metrics`
- `GET /api/traces?since=<cursor>&limit=<n>`
