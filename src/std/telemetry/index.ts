import {
  addMetricNative,
  metricValueNative,
  observeMetricNative,
  registerMetricNative,
  setMetricNative,
  snapshotMetricsNative,
  startTraceNative,
  enterTraceNative,
  exitTraceNative,
  endTraceNative,
  type MetricDefinition,
  type MetricSnapshot,
} from "std:telemetry/native";

export type MetricKind = MetricDefinition["kind"];
export type { MetricDefinition, MetricSnapshot };

export interface Counter {
  readonly id: number;
  add(delta?: number): void;
  value(): number;
}

export interface Gauge {
  readonly id: number;
  set(value: number): void;
  add(delta: number): void;
  value(): number;
}

export interface Histogram {
  readonly id: number;
  observe(value: number): void;
  count(): number;
}

function define(definition: MetricDefinition): number {
  return registerMetricNative(definition);
}

export function counter(definition: Omit<MetricDefinition, "kind">): Counter {
  const id = define({ ...definition, kind: "counter" });
  return {
    id,
    add(delta = 1) {
      addMetricNative(id, delta);
    },
    value() {
      return metricValueNative(id);
    },
  };
}

export function gauge(definition: Omit<MetricDefinition, "kind">): Gauge {
  const id = define({ ...definition, kind: "gauge" });
  return {
    id,
    set(value: number) {
      setMetricNative(id, value);
    },
    add(delta: number) {
      addMetricNative(id, delta);
    },
    value() {
      return metricValueNative(id);
    },
  };
}

export function histogram(definition: Omit<MetricDefinition, "kind">): Histogram {
  const id = define({ ...definition, kind: "histogram" });
  return {
    id,
    observe(value: number) {
      observeMetricNative(id, value);
    },
    count() {
      return metricValueNative(id);
    },
  };
}

export function metrics(): MetricSnapshot[] {
  return snapshotMetricsNative();
}

export function trace<T>(name: string, callback: () => T): T | Promise<T> {
  const spanId = startTraceNative(name);
  const invoke = () => {
    const scopeId = enterTraceNative(spanId);
    try {
      return callback();
    } finally {
      exitTraceNative(scopeId);
    }
  };

  try {
    const result = invoke();
    if (result && typeof (result as any).then === "function") {
      return Promise.resolve(result).then(
        (value) => {
          const scopeId = enterTraceNative(spanId);
          try {
            endTraceNative(spanId, "ok");
            return value;
          } finally {
            exitTraceNative(scopeId);
          }
        },
        (error) => {
          const scopeId = enterTraceNative(spanId);
          try {
            endTraceNative(spanId, "err");
          } finally {
            exitTraceNative(scopeId);
          }
          throw error;
        },
      );
    }
    endTraceNative(spanId, "ok");
    return result;
  } catch (error) {
    endTraceNative(spanId, "err");
    throw error;
  }
}

export default { counter, gauge, histogram, metrics, trace };
