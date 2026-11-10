export type MetricKind = 'counter' | 'gauge' | 'histogram';
export type MetricDefinition = { scope: string; name: string; kind: MetricKind; unit?: string };
export type MetricSnapshot = {
  id: number; scope: string; name: string; kind: MetricKind; unit: string;
  value: number; count: number; sum: number; min: number; max: number;
};

type Metric = MetricSnapshot;
const registry: Metric[] = [];
const byName = new Map<string, Metric>();

function readMetric(id: number): Metric {
  if (!Number.isInteger(id) || id < 0 || !registry[id]) throw Error('invalid metric id');
  return registry[id];
}
function finite(value: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw Error('metric value must be finite');
  return value;
}
export function registerMetricNative(definition: MetricDefinition): number {
  if (!definition || typeof definition !== 'object') throw Error('registerMetric requires a definition object');
  const { scope, name, kind } = definition;
  const unit = definition.unit ?? '';
  if (typeof scope !== 'string' || !scope || typeof name !== 'string' || !name ||
      !['counter', 'gauge', 'histogram'].includes(kind) || typeof unit !== 'string') {
    throw Error('invalid metric definition');
  }
  const key = `${scope}\0${name}`;
  const existing = byName.get(key);
  if (existing) {
    if (existing.kind !== kind || existing.unit !== unit) throw Error('conflicting metric definition');
    return existing.id;
  }
  if (registry.length >= 256) throw Error('metric registry is full');
  const metric: Metric = { id: registry.length, scope, name, kind, unit, value: 0,
    count: 0, sum: 0, min: 0, max: 0 };
  registry.push(metric);
  byName.set(key, metric);
  return metric.id;
}
export function addMetricNative(id: number, delta: number): void {
  const metric = readMetric(id);
  if (metric.kind === 'histogram') throw Error('histograms require observe');
  metric.value += finite(delta);
}
export function setMetricNative(id: number, value: number): void {
  const metric = readMetric(id);
  if (metric.kind !== 'gauge') throw Error('only gauges support set');
  metric.value = finite(value);
}
export function observeMetricNative(id: number, value: number): void {
  const metric = readMetric(id);
  if (metric.kind !== 'histogram') throw Error('only histograms support observe');
  const measured = finite(value);
  metric.min = metric.count === 0 ? measured : Math.min(metric.min, measured);
  metric.max = metric.count === 0 ? measured : Math.max(metric.max, measured);
  metric.count++;
  metric.sum += measured;
  metric.value = metric.count;
}
export function metricValueNative(id: number): number {
  refreshRuntimeMemory();
  return readMetric(id).value;
}
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
  return registry.map(metric => ({ ...metric }));
}
export function clearMetricsNative(): void {
  registry.length = 0;
  byName.clear();
}

type Span = { id: number; name: string; parent: number | null; start: number; end?: number; status?: string };
const spans = new Map<number, Span>();
const records: Span[] = [];
const scopes = new Map<number, number | null>();
let nextSpanId = 1;
let nextScopeId = 1;
let currentSpan: number | null = null;
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
