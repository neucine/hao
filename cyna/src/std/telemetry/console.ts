import { serve } from 'std:http/server';
import { getEnv } from 'std:process';
import { snapshotMetricsNative, snapshotTraceRecordsNative } from 'std:telemetry/native';
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
      return { json: snapshotTraceRecordsNative(since, limit) };
    }
    return { status: 404, json: { error: 'not_found' } };
  } });
  console.error(`Telemetry console listening on http://127.0.0.1:${server.port}/`);
}
