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

  export type TraceAttributeValue = boolean | number | string;
  export type TraceAttributes = Record<string, TraceAttributeValue>;
  export interface TraceRecord {
    sequence: number;
    kind: "span_start" | "event" | "span_end";
    timestamp_ns: number;
    trace_id: string;
    span_id: string;
    parent_span_id: string;
    name: string;
    status: string;
    source_kind: string;
    source: string;
    attributes: TraceAttributes;
  }
  export interface TraceFilter {
    source_kind?: string;
    source?: string;
    trace_id?: string;
    span_id?: string;
    name?: string;
    status?: string;
    since_ns?: number;
  }
  export interface TracePage {
    next_cursor: number;
    missed: boolean;
    records: TraceRecord[];
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
  export function snapshotTraceRecordsNative(
    since?: number,
    limit?: number,
    filter?: TraceFilter,
  ): TracePage;
}
