import telemetry, {
  counter,
  gauge,
  histogram,
  metrics,
  startTrace,
  startSpan,
  type MetricSnapshot,
  type TraceHandle,
} from "std:telemetry";
import {
  snapshotTraceRecordsNative,
  type TraceFilter,
  type TracePage,
  type TraceRecord,
} from "std:telemetry/native";

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
function assertType<T extends true>() {}

const requests = counter({ scope: "pkg.http", name: "requests", unit: "count" });
requests.add();
requests.add(2);
assertType<IsExact<ReturnType<typeof requests.value>, number>>();

const depth = gauge({ scope: "pkg.queue", name: "depth" });
depth.set(1);
depth.add(-1);

const latency = histogram({ scope: "pkg.http", name: "latency", unit: "ms" });
latency.observe(12);
assertType<IsExact<ReturnType<typeof latency.count>, number>>();

const snapshot = metrics();
assertType<IsExact<(typeof snapshot)[number], MetricSnapshot>>();

telemetry.counter({ scope: "pkg.default", name: "events" }).add();
const root: TraceHandle = startTrace("root");
root.end("ok");
telemetry.startSpan("child").end();
assertType<IsExact<ReturnType<typeof startSpan>, TraceHandle>>();

const traceFilter: TraceFilter = {
  source_kind: "addon",
  source: "pkg:native",
  status: "ok",
  since_ns: 1,
};
const tracePage = snapshotTraceRecordsNative(0, 100, traceFilter);
assertType<IsExact<typeof tracePage, TracePage>>();
assertType<IsExact<(typeof tracePage.records)[number], TraceRecord>>();

// @ts-expect-error - metric scope is required
counter({ name: "missing_scope" });
// @ts-expect-error - metric name is required
gauge({ scope: "pkg" });
// @ts-expect-error - histogram observations must be numeric
histogram({ scope: "pkg", name: "duration" }).observe("slow");
