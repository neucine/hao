export type MetricKind = 'counter' | 'gauge' | 'histogram';
export type MetricDefinition = { scope: string; name: string; kind: MetricKind; unit?: string };
export type MetricSnapshot = {
  id: number; scope: string; name: string; kind: MetricKind; unit: string;
  value: number; count: number; sum: number; min: number; max: number;
};

declare global {
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

type Span = { id: number; name: string; parent: number | null; start: number; end?: number; status?: string };
const spans = new Map<number, Span>();
const records: Span[] = [];
const scopes = new Map<number, number | null>();
let nextSpanId = 1;
let nextScopeId = 1;
let currentSpan: number | null = null;
const scheduleTimeout = globalThis.setTimeout;
globalThis.setTimeout = ((callback: (...args: any[]) => void, delay?: number, ...args: any[]) => {
  if (typeof callback !== 'function') return scheduleTimeout(callback, delay);
  const parent = currentSpan;
  return scheduleTimeout(() => {
    const previous = currentSpan;
    currentSpan = parent;
    try { callback(...args); } finally { currentSpan = previous; }
  }, delay);
}) as typeof setTimeout;
export function snapshotTracesNative(): Span[] { return records.map(record => ({ ...record })); }
function createSpan(name: string, parent: number | null): number {
  if (typeof name !== 'string' || !name) throw Error('trace name must be a non-empty string');
  const id = nextSpanId++;
  const span = { id, name, parent, start: Date.now() };
  spans.set(id, span);
  records.push(span);
  if (records.length > 512) records.shift();
  return id;
}
export function startTraceNative(name: string): number { return createSpan(name, currentSpan); }
export function startRootTraceNative(name: string): number { return createSpan(name, null); }
export function enterTraceNative(id: number): number {
  if (!spans.has(id)) throw Error('unknown trace span');
  const scope = nextScopeId++;
  scopes.set(scope, currentSpan);
  currentSpan = id;
  return scope;
}
export function exitTraceNative(scope: number): void {
  if (!scopes.has(scope)) throw Error('unknown trace scope');
  currentSpan = scopes.get(scope)!;
  scopes.delete(scope);
}
export function endTraceNative(id: number, status: 'ok' | 'err' | 'unset' = 'ok'): void {
  const span = spans.get(id);
  if (!span) throw Error('unknown trace span');
  span.end = Date.now();
  span.status = status;
  spans.delete(id);
}
