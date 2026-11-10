import { serve } from 'std:http/server';
import { getEnv } from 'std:process';
import { snapshotMetricsNative, snapshotTracesNative } from 'std:telemetry/native';
import { dashboard } from 'std:telemetry/dashboard';

const enabled = getEnv('RUNTIME_TELEMETRY_CONSOLE');
if (enabled === '1' || enabled === 'true') {
  const configured = getEnv('RUNTIME_TELEMETRY_CONSOLE_PORT') ?? '0';
  const port = Number(configured);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw Error('Invalid telemetry console port');
  const server = serve({ hostname: '127.0.0.1', port, unref: true, handler(request: any) {
    const path = request.url.split('?')[0];
    if (request.method !== 'GET') return { status: 405, json: { error: 'method_not_allowed' } };
    if (path === '/' || path === '/index.html') return { body: dashboard,
      headers: { 'content-type': 'text/html; charset=utf-8' } };
    if (path === '/health' || path === '/api/health') return { json: { ok: true } };
    if (path === '/metrics' || path === '/api/metrics') return { json: snapshotMetricsNative() };
    if (path === '/traces' || path === '/api/traces') {
      const since = Number(/(?:\?|&)since=(\d+)/.exec(request.url)?.[1] ?? '0');
      const limit = Math.min(512, Math.max(1, Number(/(?:\?|&)limit=(\d+)/.exec(request.url)?.[1] ?? '100')));
      const all = snapshotTracesNative();
      const selected = all.filter(record => record.id > since).slice(0, limit);
      const hex = (id: number | null) => (id ?? 0).toString(16).padStart(16, '0');
      const records = selected.map(record => ({ sequence: record.id, kind: 'span_start',
        timestamp_ns: record.start * 1000000, trace_id: hex(record.parent ?? record.id).padStart(32, '0'),
        span_id: hex(record.id), parent_span_id: hex(record.parent), name: record.name,
        status: record.status ?? 'unset', attributes: {} }));
      return { json: { next_cursor: selected.length ? selected[selected.length - 1].id : since,
        missed: all.length > 0 && since > 0 && all[0].id > since + 1, records } };
    }
    return { status: 404, json: { error: 'not_found' } };
  } });
  console.error(`Telemetry console listening on http://127.0.0.1:${server.port}/`);
}
