import {
  addMetricNative,
  metricValueNative,
  observeMetricNative,
  registerMetricNative,
  setMetricNative,
  snapshotMetricsNative,
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

export default { counter, gauge, histogram, metrics };
