import { describe, expect, test } from "std:test";
import { counter, gauge, histogram, metrics, trace } from "std:telemetry";

describe("telemetry metrics", () => {
  test("records counters gauges and histograms", () => {
    const requests = counter({ scope: "test.http", name: "requests", unit: "count" });
    requests.add();
    requests.add(2);
    expect(requests.value()).toBe(3);

    const queue = gauge({ scope: "test.worker", name: "queue_depth", unit: "count" });
    queue.set(4);
    queue.add(-1);
    expect(queue.value()).toBe(3);

    const latency = histogram({ scope: "test.http", name: "latency_ms", unit: "ms" });
    latency.observe(12);
    latency.observe(8);
    latency.observe(20);
    expect(latency.count()).toBe(3);

    const snapshot = metrics();
    const requestMetric = snapshot.find((metric) => metric.scope === "test.http" && metric.name === "requests");
    expect(requestMetric?.kind).toBe("counter");
    expect(requestMetric?.value).toBe(3);

    const latencyMetric = snapshot.find((metric) => metric.scope === "test.http" && metric.name === "latency_ms");
    expect(latencyMetric?.kind).toBe("histogram");
    expect(latencyMetric?.count).toBe(3);
    expect(latencyMetric?.sum).toBe(40);
    expect(latencyMetric?.min).toBe(8);
    expect(latencyMetric?.max).toBe(20);
  });

  test("registration is idempotent for the same metric definition", () => {
    const a = counter({ scope: "test.idempotent", name: "events" });
    const b = counter({ scope: "test.idempotent", name: "events" });
    a.add(2);
    b.add(3);

    expect(a.id).toBe(b.id);
    expect(a.value()).toBe(5);
    expect(metrics().filter((metric) => metric.scope === "test.idempotent").length).toBe(1);
  });

  test("includes runtime memory gauges", () => {
    const snapshot = metrics();
    const memoryUsed = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "qjs_heap_used_bytes");
    const objects = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "qjs_object_count");
    const allocatorActive = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "allocator_active_bytes");
    const allocatorPeak = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "allocator_peak_bytes");

    expect(memoryUsed?.kind).toBe("gauge");
    expect(memoryUsed?.unit).toBe("bytes");
    expect((memoryUsed?.value ?? 0) > 0).toBe(true);
    expect(objects?.kind).toBe("gauge");
    expect(objects?.unit).toBe("count");
    expect(allocatorActive?.kind).toBe("gauge");
    expect(allocatorActive?.unit).toBe("bytes");
    expect(allocatorPeak?.kind).toBe("gauge");
    expect(allocatorPeak?.unit).toBe("bytes");
  });

  test("propagates trace context through sync and async callbacks", async () => {
    expect(trace("test.sync", () => 42)).toBe(42);

    const value = await trace("test.async", async () => {
      await Promise.resolve();
      return "done";
    });
    expect(value).toBe("done");
  });
});
