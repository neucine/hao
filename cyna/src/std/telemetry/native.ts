export type MetricKind = 'counter' | 'gauge' | 'histogram';
export type MetricDefinition = { scope: string; name: string; kind: MetricKind; unit?: string };
export type MetricSnapshot = {
  id: number; scope: string; name: string; kind: MetricKind; unit: string;
  value: number; count: number; sum: number; min: number; max: number;
};

declare global {
  var __hao_trace_capacity: number;
  var __hao_telemetry_monotonicNs: () => number;
  var __hao_telemetry_register: (definition: MetricDefinition) => number;
  var __hao_telemetry_add: (id: number, delta: number) => void;
  var __hao_telemetry_set: (id: number, value: number) => void;
  var __hao_telemetry_observe: (id: number, value: number) => void;
  var __hao_telemetry_value: (id: number) => number;
  var __hao_telemetry_snapshot: () => MetricSnapshot[];
  var __hao_telemetry_clear: () => void;
}
export function registerMetricNative(definition: MetricDefinition): number { return globalThis.__hao_telemetry_register(definition); }
export function addMetricNative(id: number, delta: number): void { globalThis.__hao_telemetry_add(id, delta); }
export function setMetricNative(id: number, value: number): void { globalThis.__hao_telemetry_set(id, value); }
export function observeMetricNative(id: number, value: number): void { globalThis.__hao_telemetry_observe(id, value); }
export function metricValueNative(id: number): number { refreshRuntimeMemory(); return globalThis.__hao_telemetry_value(id); }
function refreshRuntimeMemory(): void {
  const gauges = globalThis.__hao_telemetry_memorySnapshot();
  for (const [name, value] of Object.entries(gauges)) {
    const id = registerMetricNative({ scope: 'runtime.memory', name, kind: 'gauge',
      unit: name.endsWith('_count') ? 'count' : 'bytes' });
    setMetricNative(id, value as number);
  }
}
export function snapshotMetricsNative(): MetricSnapshot[] {
  refreshRuntimeMemory();
  return globalThis.__hao_telemetry_snapshot();
}
export function clearMetricsNative(): void {
  globalThis.__hao_telemetry_clear();
}

type Span = { id: number; traceId: number; name: string; parent: number | null; start: number };
type TraceRecord = { sequence: number; kind: 'span_start' | 'span_end'; timestamp_ns: number;
  trace_id: string; span_id: string; parent_span_id: string; name: string;
  status: string; attributes: Record<string, unknown> };
const spans = new Map<number, Span>();
const spanTraceIds = new Map<number, number>();
const records: TraceRecord[] = [];
const traceCapacity = globalThis.__hao_trace_capacity;
type Context = { span: number | null; trace: number | null };
const scopes = new Map<number, Context>();
let nextSpanId = 1;
let nextSequence = 1;
let nextScopeId = 1;
let currentSpan: number | null = null;
let currentTraceId: number | null = null;
const scheduleTimeout = globalThis.setTimeout;
globalThis.setTimeout = ((callback: (...args: any[]) => void, delay?: number, ...args: any[]) => {
  if (typeof callback !== 'function') return scheduleTimeout(callback, delay);
  const parent = currentSpan;
  const traceId = currentTraceId;
  return scheduleTimeout(() => {
    const previous = { span: currentSpan, trace: currentTraceId };
    currentSpan = parent;
    currentTraceId = traceId;
    try { callback(...args); } finally { currentSpan = previous.span; currentTraceId = previous.trace; }
  }, delay);
}) as typeof setTimeout;
function hex(id: number | null, width: number): string { return (id ?? 0).toString(16).padStart(width, '0'); }
function recordSpan(span: Span, kind: 'span_start' | 'span_end', status = 'unset'): void {
  records.push({ sequence: nextSequence++, kind, timestamp_ns: globalThis.__hao_telemetry_monotonicNs(),
    trace_id: hex(span.traceId, 32), span_id: hex(span.id, 16), parent_span_id: hex(span.parent, 16),
    name: span.name, status, attributes: {} });
  if (records.length > traceCapacity) records.shift();
}
export function snapshotTraceRecordsNative(since = 0, limit = 100) {
  if (!Number.isSafeInteger(since) || since < 0 || !Number.isSafeInteger(limit) || limit < 1) {
    throw Error('invalid trace cursor or limit');
  }
  const latest = nextSequence - 1;
  if (!records.length || since >= latest) return { next_cursor: latest, missed: false, records: [] };
  const missed = since + 1 < records[0].sequence;
  const selected = records.filter(record => record.sequence > since).slice(0, Math.min(limit, traceCapacity));
  return { next_cursor: selected.length ? selected[selected.length - 1].sequence : since,
    missed, records: selected.map(record => ({ ...record })) };
}
function createSpan(name: string, parent: number | null): number {
  if (typeof name !== 'string' || !name) throw Error('trace name must be a non-empty string');
  const id = nextSpanId++;
  const traceId = parent === null ? id :
    parent === currentSpan && currentTraceId !== null ? currentTraceId : spanTraceIds.get(parent) ?? parent;
  const span = { id, traceId, name, parent, start: Date.now() };
  spans.set(id, span);
  spanTraceIds.set(id, traceId);
  trimTraceIds();
  recordSpan(span, 'span_start');
  return id;
}
function trimTraceIds(): void {
  if (spanTraceIds.size <= 512) return;
  for (const id of spanTraceIds.keys()) {
    if (!spans.has(id)) spanTraceIds.delete(id);
    if (spanTraceIds.size <= 512) break;
  }
}
export function startTraceNative(name: string): number { return createSpan(name, currentSpan); }
export function startRootTraceNative(name: string): number { return createSpan(name, null); }
export function enterTraceNative(id: number): number {
  if (!spans.has(id)) throw Error('unknown trace span');
  const scope = nextScopeId++;
  scopes.set(scope, { span: currentSpan, trace: currentTraceId });
  currentSpan = id;
  currentTraceId = spans.get(id)!.traceId;
  return scope;
}
export function exitTraceNative(scope: number): void {
  if (!scopes.has(scope)) throw Error('unknown trace scope');
  const previous = scopes.get(scope)!;
  currentSpan = previous.span;
  currentTraceId = previous.trace;
  scopes.delete(scope);
}
export function endTraceNative(id: number, status: 'ok' | 'err' | 'unset' = 'ok'): void {
  const span = spans.get(id);
  if (!span) throw Error('unknown trace span');
  recordSpan(span, 'span_end', status);
  spans.delete(id);
  trimTraceIds();
}
