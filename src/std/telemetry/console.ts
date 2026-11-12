import { serve } from 'std:http/server';
import { snapshotMetricsNative, snapshotTraceRecordsNative } from 'std:telemetry/native';
import { dashboard } from 'std:telemetry/dashboard';

declare global {
  var __hao_telemetry_console_enabled: boolean;
  var __hao_telemetry_console_port: number;
}

if (globalThis.__hao_telemetry_console_enabled) {
  const port = globalThis.__hao_telemetry_console_port;
  const server = serve({ hostname: '127.0.0.1', port, unref: true, handler(request: any) {
    const path = request.url.split('?')[0];
    if (request.method !== 'GET') return { status: 405, json: { error: 'method_not_allowed' } };
    if (path === '/' || path === '/index.html') return { body: dashboard,
      headers: { 'content-type': 'text/html; charset=utf-8' } };
    if (path === '/health' || path === '/api/health') return { json: { ok: true } };
    if (path === '/metrics' || path === '/api/metrics') return { json: snapshotMetricsNative() };
    if (path.startsWith('/traces') || path.startsWith('/api/traces')) {
      const query = (name: string) => {
        const value = new RegExp(`(?:\\?|&)${name}=([^&]*)`).exec(request.url)?.[1];
        return value === undefined ? undefined : decodeURIComponent(value);
      };
      const since = Number(query('since') ?? '0');
      const limit = Math.min(512, Math.max(1, Number(query('limit') ?? '100')));
      const filter: Record<string, string | number> = {};
      for (const name of ['source_kind', 'source', 'trace_id', 'span_id', 'name', 'status']) {
        const value = query(name);
        if (value !== undefined) filter[name] = value;
      }
      const sinceNs = query('since_ns');
      if (sinceNs !== undefined) filter.since_ns = Number(sinceNs);
      return { json: snapshotTraceRecordsNative(since, limit, filter) };
    }
    return { status: 404, json: { error: 'not_found' } };
  } });
  console.error(`Telemetry console listening on http://127.0.0.1:${server.port}/`);
}
