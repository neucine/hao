declare module "std:telemetry/native" {
  export type MetricKind = "counter" | "gauge" | "histogram";

  export interface MetricDefinition {
    scope: string;
    name: string;
    kind: MetricKind;
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

  export function registerMetricNative(definition: MetricDefinition): number;
  export function addMetricNative(id: number, delta: number): void;
  export function setMetricNative(id: number, value: number): void;
  export function observeMetricNative(id: number, value: number): void;
  export function metricValueNative(id: number): number;
  export function snapshotMetricsNative(): MetricSnapshot[];
  export function clearMetricsNative(): void;
  export function startTraceNative(name: string): number;
  export function startRootTraceNative(name: string): number;
  export function enterTraceNative(id: number): number;
  export function exitTraceNative(scopeId: number): void;
  export function endTraceNative(id: number, status?: "ok" | "err" | "unset"): void;
}
