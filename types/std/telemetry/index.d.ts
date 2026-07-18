declare module "std:telemetry" {
  export type MetricKind = "counter" | "gauge" | "histogram";

  export interface MetricDefinition {
    scope: string;
    name: string;
    unit?: string;
  }

  export interface MetricSnapshot {
    id: number;
    scope: string;
    name: string;
    kind: MetricKind;
    unit: string;
    value: number;
    count: number;
    sum: number;
    min: number;
    max: number;
  }

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

  export function counter(definition: MetricDefinition): Counter;
  export function gauge(definition: MetricDefinition): Gauge;
  export function histogram(definition: MetricDefinition): Histogram;
  export function metrics(): MetricSnapshot[];

  const telemetry: {
    counter: typeof counter;
    gauge: typeof gauge;
    histogram: typeof histogram;
    metrics: typeof metrics;
  };
  export default telemetry;
}
