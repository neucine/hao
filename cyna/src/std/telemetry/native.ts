export type MetricKind = 'counter' | 'gauge' | 'histogram';
declare const InternalError: new (message: string) => Error;
export type MetricDefinition = { scope: string; name: string; kind: MetricKind; unit?: string };
export type MetricSnapshot = {
  id: number; scope: string; name: string; kind: MetricKind; unit: string;
  value: number; count: number; sum: number; min: number; max: number;
};

declare global {
  var __hao_trace_capacity: number;
  var __hao_telemetry_monotonicNs: () => number;
  var __hao_telemetry_randomHexId: (bytes: 8 | 16) => string;
  var __hao_telemetry_register: (definition: MetricDefinition) => number;
  var __hao_telemetry_add: (id: number, delta: number) => void;
  var __hao_telemetry_set: (id: number, value: number) => void;
  var __hao_telemetry_observe: (id: number, value: number) => void;
  var __hao_telemetry_value: (id: number) => number;
  var __hao_telemetry_snapshot: () => MetricSnapshot[];
  var __hao_telemetry_clear: () => void;
  var __hao_telemetry_drainNative: () => Omit<TraceRecord, 'sequence'>[];
}
export function registerMetricNative(definition: MetricDefinition): number { return globalThis.__hao_telemetry_register(definition); }
export function addMetricNative(id: number, delta: number): void { globalThis.__hao_telemetry_add(id, delta); }
export function setMetricNative(id: number, value: number): void { globalThis.__hao_telemetry_set(id, value); }
export function observeMetricNative(id: number, value: number): void { globalThis.__hao_telemetry_observe(id, value); }
export function metricValueNative(id: number): number { drainNative(); refreshRuntimeMemory(); return globalThis.__hao_telemetry_value(id); }
function refreshRuntimeMemory(): void {
  const gauges = globalThis.__hao_telemetry_memorySnapshot();
  for (const [name, value] of Object.entries(gauges)) {
    const id = registerMetricNative({ scope: 'runtime.memory', name, kind: 'gauge',
      unit: name.endsWith('_count') ? 'count' : 'bytes' });
    setMetricNative(id, value as number);
  }
}
export function snapshotMetricsNative(): MetricSnapshot[] {
  drainNative();
  refreshRuntimeMemory();
  return globalThis.__hao_telemetry_snapshot();
}
export function clearMetricsNative(): void {
  globalThis.__hao_telemetry_clear();
}

type Span = { id: number; traceId: string; spanId: string; parentSpanId: string; name: string };
type TraceAttributeValue = boolean | number | string;
type TraceAttributes = Record<string, TraceAttributeValue>;
type TraceRecord = { sequence: number; kind: 'span_start' | 'event' | 'span_end'; timestamp_ns: number;
  trace_id: string; span_id: string; parent_span_id: string; name: string;
  status: string; attributes: TraceAttributes };
const spans = new Map<number, Span>();
const spanTraceIds = new Map<number, string>();
const spanIds = new Map<number, string>();
const records: TraceRecord[] = [];
const traceCapacity = globalThis.__hao_trace_capacity;
function drainNative(): void {
  for (const record of globalThis.__hao_telemetry_drainNative()) {
    if (traceCapacity === 0) continue;
    records.push({ ...record, sequence: nextSequence++ });
    if (records.length > traceCapacity) records.shift();
  }
}
type Context = { span: number | null; trace: string | null; spanId: string | null };
const scopes = new Map<number, Context>();
let nextSpanId = 1;
let nextSequence = 1;
let nextScopeId = 1;
let currentSpan: number | null = null;
let currentTraceId: string | null = null;
let currentSpanId: string | null = null;
globalThis.__hao_telemetry_captureContext = () =>
  ({ span: currentSpan, trace: currentTraceId, spanId: currentSpanId });
globalThis.__hao_telemetry_enterContext = (context: Context) => {
  const previous = globalThis.__hao_telemetry_captureContext();
  currentSpan = context.span;
  currentTraceId = context.trace;
  currentSpanId = context.spanId;
  return previous;
};
const scheduleTimeout = globalThis.setTimeout;
globalThis.setTimeout = ((callback: (...args: any[]) => void, delay?: number) => {
  if (typeof callback !== 'function') return scheduleTimeout(callback, delay);
  const parent = currentSpan;
  const traceId = currentTraceId;
  const spanId = currentSpanId;
  if (parent === null && traceId === null && spanId === null)
    return scheduleTimeout(callback, delay);
  return scheduleTimeout(() => {
    const previous = { span: currentSpan, trace: currentTraceId, spanId: currentSpanId };
    currentSpan = parent;
    currentTraceId = traceId;
    currentSpanId = spanId;
    try { callback(); } finally {
      currentSpan = previous.span; currentTraceId = previous.trace; currentSpanId = previous.spanId;
    }
  }, delay);
}) as typeof setTimeout;
const rootSpanId = '0000000000000000';
function utf8Length(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const point = character.codePointAt(0)!;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes;
}
function copyAttributes(attributes: TraceAttributes): TraceAttributes {
  if (attributes === null || typeof attributes !== 'object' || Array.isArray(attributes)) throw Error('invalid trace attributes');
  const entries = Object.entries(attributes);
  if (entries.length > 16) throw Error('too many trace attributes');
  const copy: TraceAttributes = {};
  for (const [key, value] of entries) {
    if (utf8Length(key) > 64) throw Error('trace attribute key too long');
    if (typeof value === 'string') {
      if (utf8Length(value) > 256) throw Error('trace attribute value too long');
    } else if (typeof value !== 'boolean' && (typeof value !== 'number' || !Number.isFinite(value))) {
      throw Error('invalid trace attribute value');
    }
    Object.defineProperty(copy, key, { value, enumerable: true, configurable: true, writable: true });
  }
  return copy;
}
function recordSpan(span: Span, kind: 'span_start' | 'span_end' | 'event', status = 'unset',
                    name = span.name, attributes: TraceAttributes = {}): void {
  drainNative();
  if (traceCapacity === 0) return;
  if (utf8Length(name) > 96) throw Error('trace name too long');
  const copied = copyAttributes(attributes);
  records.push({ sequence: nextSequence++, kind, timestamp_ns: globalThis.__hao_telemetry_monotonicNs(),
    trace_id: span.traceId, span_id: span.spanId,
    parent_span_id: kind === 'span_start' ? span.parentSpanId : rootSpanId,
    name, status, attributes: copied });
  if (records.length > traceCapacity) records.shift();
}
export function snapshotTraceRecordsNative(since = 0, limit = 100) {
  drainNative();
  if (!Number.isSafeInteger(since) || since < 0 || !Number.isSafeInteger(limit) || limit < 1) {
    throw Error('invalid trace cursor or limit');
  }
  const latest = nextSequence - 1;
  if (!records.length || since >= latest) return { next_cursor: latest, missed: false, records: [] };
  const missed = since + 1 < records[0].sequence;
  const selected = records.filter(record => record.sequence > since).slice(0, Math.min(limit, traceCapacity));
  return { next_cursor: selected.length ? selected[selected.length - 1].sequence : since,
    missed, records: selected.map(record => ({ ...record, attributes: { ...record.attributes } })) };
}
function createSpan(name: string, parent: number | null, attributes: TraceAttributes = {}): number {
  const id = nextSpanId++;
  const traceId = parent === null ? globalThis.__hao_telemetry_randomHexId(16) :
    parent === currentSpan && currentTraceId !== null ? currentTraceId :
    spanTraceIds.get(parent) ?? globalThis.__hao_telemetry_randomHexId(16);
  const spanId = globalThis.__hao_telemetry_randomHexId(8);
  const parentSpanId = parent === null ? rootSpanId :
    parent === currentSpan && currentSpanId !== null ? currentSpanId : spanIds.get(parent) ?? rootSpanId;
  const span = { id, traceId, spanId, parentSpanId, name };
  spans.set(id, span);
  spanTraceIds.set(id, traceId);
  spanIds.set(id, spanId);
  trimTraceIds();
  try { recordSpan(span, 'span_start', 'unset', name, attributes); }
  catch (error) { spans.delete(id); spanTraceIds.delete(id); spanIds.delete(id); throw error; }
  return id;
}
function trimTraceIds(): void {
  if (spanTraceIds.size <= 512) return;
  for (const id of spanTraceIds.keys()) {
    if (!spans.has(id)) { spanTraceIds.delete(id); spanIds.delete(id); }
    if (spanTraceIds.size <= 512) break;
  }
}
export function startTraceNative(name: string, attributes: TraceAttributes = {}): number {
  if (arguments.length < 1) throw new TypeError('startTrace requires a name');
  if (typeof name === 'symbol') throw new TypeError('trace name must be a string');
  const text = String(name);
  if (utf8Length(text) > 96) throw new InternalError('failed to start trace span');
  return createSpan(text, currentSpan, attributes);
}
export function startRootTraceNative(name: string, attributes: TraceAttributes = {}): number {
  if (arguments.length < 1) throw new TypeError('startRootTrace requires a name');
  if (typeof name === 'symbol') throw new TypeError('trace name must be a string');
  const text = String(name);
  if (utf8Length(text) > 96) throw new InternalError('failed to start root trace span');
  return createSpan(text, null, attributes);
}
export function addTraceEventNative(id: number, name: string, attributes: TraceAttributes = {}): void {
  const span = spans.get(id);
  if (!span) throw Error('unknown trace span');
  if (typeof name !== 'string' || !name || utf8Length(name) > 96) throw Error('invalid trace name');
  recordSpan(span, 'event', 'unset', name, attributes);
}
function traceId(value: unknown, kind: 'span' | 'scope'): number {
  let id: number;
  try { id = Number(value) | 0; }
  catch { throw new TypeError(`trace ${kind} id must be a non-negative integer`); }
  if (id < 0) throw new TypeError(`trace ${kind} id must be a non-negative integer`);
  return id;
}
export function enterTraceNative(id: number): number {
  if (arguments.length < 1) throw new TypeError('enterTrace requires a span id');
  id = traceId(id, 'span');
  if (!spans.has(id)) throw new InternalError('failed to enter trace span');
  const scope = nextScopeId++;
  scopes.set(scope, { span: currentSpan, trace: currentTraceId, spanId: currentSpanId });
  currentSpan = id;
  currentTraceId = spans.get(id)!.traceId;
  currentSpanId = spans.get(id)!.spanId;
  return scope;
}
export function exitTraceNative(scope: number): void {
  if (arguments.length < 1) throw new TypeError('exitTrace requires a scope id');
  scope = traceId(scope, 'scope');
  if (!scopes.has(scope)) throw new InternalError('failed to exit trace span');
  const previous = scopes.get(scope)!;
  currentSpan = previous.span;
  currentTraceId = previous.trace;
  currentSpanId = previous.spanId;
  scopes.delete(scope);
}
export function endTraceNative(id: number, status: 'ok' | 'err' | 'unset' = 'ok'): void {
  if (arguments.length < 1) throw new TypeError('endTrace requires a span id');
  id = traceId(id, 'span');
  if (arguments.length >= 2) {
    if (typeof status === 'symbol') throw new TypeError('trace status must be a string');
    const text = String(status);
    status = text === 'err' ? 'err' : text === 'unset' ? 'unset' : 'ok';
  }
  const span = spans.get(id);
  if (!span) throw new InternalError('failed to end trace span');
  recordSpan(span, 'span_end', status);
  spans.delete(id);
  trimTraceIds();
}
