export type MetricKind = 'counter' | 'gauge' | 'histogram';
declare const InternalError: new (message: string) => Error;
export type MetricDefinition = { scope: string; name: string; kind: MetricKind; unit?: string };
export type MetricSnapshot = {
  id: number; scope: string; name: string; kind: MetricKind; unit: string;
  value: number; count: number; sum: number; min: number; max: number;
};

type TraceAttributeValue = boolean | number | string;
export type TraceAttributes = Record<string, TraceAttributeValue>;
type TraceAttributeEntry = [string, TraceAttributeValue];
export type TraceRecord = {
  sequence: number;
  kind: 'span_start' | 'event' | 'span_end';
  timestamp_ns: number;
  trace_id: string;
  span_id: string;
  parent_span_id: string;
  name: string;
  status: string;
  source_kind: string;
  source: string;
  attributes: TraceAttributes;
};
export type TraceFilter = {
  source_kind?: string;
  source?: string;
  trace_id?: string;
  span_id?: string;
  name?: string;
  status?: string;
  since_ns?: number;
};
export type TracePage = {
  next_cursor: number;
  missed: boolean;
  records: TraceRecord[];
};

declare global {
  var __hao_telemetry_monotonicNs: () => number;
  var __hao_telemetry_memorySnapshot: () => Record<string, number>;
  var __hao_telemetry_register: (definition: MetricDefinition) => number;
  var __hao_telemetry_add: (id: number, delta: number) => void;
  var __hao_telemetry_set: (id: number, value: number) => void;
  var __hao_telemetry_observe: (id: number, value: number) => void;
  var __hao_telemetry_value: (id: number) => number;
  var __hao_telemetry_snapshot: () => MetricSnapshot[];
  var __hao_telemetry_clear: () => void;
  var __hao_telemetry_drainMetrics: () => void;
  var __hao_telemetry_startSpan:
    (name: string, root: boolean, attributes: TraceAttributeEntry[], source: string) => number;
  var __hao_telemetry_enterSpan: (id: number) => number;
  var __hao_telemetry_exitSpan: (scope: number) => void;
  var __hao_telemetry_addEvent:
    (id: number, name: string, attributes: TraceAttributeEntry[]) => void;
  var __hao_telemetry_endSpan: (id: number, status: 'ok' | 'err' | 'unset') => void;
  var __hao_telemetry_snapshotTraces:
    (since: number, limit: number, filter: TraceFilter) => TracePage;
}

export function registerMetricNative(definition: MetricDefinition): number {
  return globalThis.__hao_telemetry_register(definition);
}
export function addMetricNative(id: number, delta: number): void {
  globalThis.__hao_telemetry_add(id, delta);
}
export function setMetricNative(id: number, value: number): void {
  globalThis.__hao_telemetry_set(id, value);
}
export function observeMetricNative(id: number, value: number): void {
  globalThis.__hao_telemetry_observe(id, value);
}
export function metricValueNative(id: number): number {
  globalThis.__hao_telemetry_drainMetrics();
  refreshRuntimeMemory();
  return globalThis.__hao_telemetry_value(id);
}

function refreshRuntimeMemory(): void {
  const gauges = globalThis.__hao_telemetry_memorySnapshot();
  for (const [name, value] of Object.entries(gauges)) {
    const id = registerMetricNative({ scope: 'runtime.memory', name, kind: 'gauge',
      unit: name.endsWith('_count') ? 'count' : 'bytes' });
    setMetricNative(id, value);
  }
}

export function snapshotMetricsNative(): MetricSnapshot[] {
  globalThis.__hao_telemetry_drainMetrics();
  refreshRuntimeMemory();
  return globalThis.__hao_telemetry_snapshot();
}

export function clearMetricsNative(): void {
  globalThis.__hao_telemetry_clear();
}

function utf8Length(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const point = character.codePointAt(0)!;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes;
}

function copyAttributes(attributes: TraceAttributes): TraceAttributeEntry[] {
  if (attributes === null || typeof attributes !== 'object' || Array.isArray(attributes)) {
    throw Error('invalid trace attributes');
  }
  const entries = Object.entries(attributes);
  if (entries.length > 16) throw Error('too many trace attributes');
  const copy: TraceAttributeEntry[] = [];
  for (const [key, value] of entries) {
    if (utf8Length(key) > 64) throw Error('trace attribute key too long');
    if (typeof value === 'string') {
      if (utf8Length(value) > 256) throw Error('trace attribute value too long');
    } else if (typeof value !== 'boolean' &&
               (typeof value !== 'number' || !Number.isFinite(value))) {
      throw Error('invalid trace attribute value');
    }
    copy.push([key, value]);
  }
  return copy;
}

function startSpanNative(name: unknown, root: boolean,
                         attributes: TraceAttributes, source: string): number {
  if (typeof name === 'symbol') throw new TypeError('trace name must be a string');
  const text = String(name);
  if (utf8Length(text) > 96)
    throw new InternalError(`failed to start ${root ? 'root ' : ''}trace span`);
  const id = globalThis.__hao_telemetry_startSpan(
    text, root, copyAttributes(attributes), source);
  if (!id) throw new InternalError(`failed to start ${root ? 'root ' : ''}trace span`);
  return id;
}

export function startTraceNative(name: string, attributes: TraceAttributes = {}): number {
  if (arguments.length < 1) throw new TypeError('startTrace requires a name');
  return startSpanNative(name, false, attributes, 'javascript');
}

export function startRootTraceNative(name: string, attributes: TraceAttributes = {}): number {
  if (arguments.length < 1) throw new TypeError('startRootTrace requires a name');
  return startSpanNative(name, true, attributes, 'javascript');
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
  const scope = globalThis.__hao_telemetry_enterSpan(traceId(id, 'span'));
  if (!scope) throw new InternalError('failed to enter trace span');
  return scope;
}

export function exitTraceNative(scope: number): void {
  if (arguments.length < 1) throw new TypeError('exitTrace requires a scope id');
  globalThis.__hao_telemetry_exitSpan(traceId(scope, 'scope'));
}

export function addTraceEventNative(id: number, name: string,
                                    attributes: TraceAttributes = {}): void {
  if (typeof name !== 'string' || !name || utf8Length(name) > 96)
    throw Error('invalid trace name');
  globalThis.__hao_telemetry_addEvent(traceId(id, 'span'), name, copyAttributes(attributes));
}

export function endTraceNative(id: number, status: 'ok' | 'err' | 'unset' = 'ok'): void {
  if (arguments.length < 1) throw new TypeError('endTrace requires a span id');
  const span = traceId(id, 'span');
  let normalized: 'ok' | 'err' | 'unset' = 'ok';
  if (arguments.length >= 2) {
    if (typeof status === 'symbol') throw new TypeError('trace status must be a string');
    const text = String(status);
    normalized = text === 'err' ? 'err' : text === 'unset' ? 'unset' : 'ok';
  }
  globalThis.__hao_telemetry_endSpan(span, normalized);
}

export function snapshotTraceRecordsNative(
  since = 0,
  limit = 100,
  filter: TraceFilter = {},
): TracePage {
  if (!Number.isSafeInteger(since) || since < 0 ||
      !Number.isSafeInteger(limit) || limit < 1) {
    throw Error('invalid trace cursor or limit');
  }
  if (filter === null || typeof filter !== 'object' || Array.isArray(filter))
    throw Error('invalid trace filter');
  if (filter.since_ns !== undefined &&
      (!Number.isFinite(filter.since_ns) || filter.since_ns < 0))
    throw Error('invalid trace filter');
  return globalThis.__hao_telemetry_snapshotTraces(since, limit, filter);
}
