declare global {
  var __hao_http_serveNative: (options: any, callback: (id: number, chunk: Uint8Array | null) => void) => { id: number; port: number };
  var __hao_http_stopServerNative: (id: number) => void;
  var __hao_http_pauseClientNative: (id: number) => void;
  var __hao_http_respondNative: (id: number, bytes: Uint8Array) => void;
  var __hao_http_encodeTextNative: (text: string) => Uint8Array;
  var __hao_http_decodeTextNative: (bytes: Uint8Array) => string;
  var __hao_http_unrefServerNative: (id: number) => void;
}

const {
  serveNative, stopServerNative, pauseClientNative, respondNative, encodeTextNative, decodeTextNative,
} = {
  serveNative: globalThis.__hao_http_serveNative,
  stopServerNative: globalThis.__hao_http_stopServerNative,
  pauseClientNative: globalThis.__hao_http_pauseClientNative,
  respondNative: globalThis.__hao_http_respondNative,
  encodeTextNative: globalThis.__hao_http_encodeTextNative,
  decodeTextNative: globalThis.__hao_http_decodeTextNative,
};
function fail(message: string): never { throw new Error(message); }

// Small HTTP/1.x server: one buffered request/response per connection.
// Keeping framing here makes its validation testable independently of TCP I/O.
export function serve(options: any) {
  if (!options || typeof options.handler !== 'function') fail('http.serve requires a handler');
  const hostname = options.hostname ?? '127.0.0.1';
  const port = options.port ?? 8000;
  const maxBodyBytes = options.maxBodyBytes ?? 1024 * 1024;
  const maxResponseBytes = options.maxResponseBytes ?? 16 * 1024 * 1024;
  const maxConnections = options.maxConnections ?? 64;
  const requestTimeoutMs = options.requestTimeoutMs ?? 30000;
  for (const [value, min, max] of [[port, 0, 65535], [maxBodyBytes, 0, 16 * 1024 * 1024], [maxResponseBytes, 0, 64 * 1024 * 1024], [maxConnections, 1, 1024], [requestTimeoutMs, 1, 3600000]]) {
    if (!Number.isSafeInteger(value) || value < min || value > max) fail('Invalid http.serve limit');
  }
  type Pending = { chunks: Uint8Array[]; length: number; head: Uint8Array; bodyOffset?: number; bodyLength?: number; method?: string; url?: string; headers?: Record<string, string>; handling?: boolean };
  const pending = new Map<number, Pending>();
  let stopped = false;
  const utf8 = (value: string) => encodeTextNative(value);
  function reply(id: number, value: any, method = 'GET') {
    if (stopped || !pending.has(id)) return;
    const status = value?.status ?? 200;
    if (!Number.isInteger(status) || status < 200 || status > 599) throw Error('Invalid response status');
    if (value?.body != null && value?.json !== undefined) throw Error('Use body or json, not both');
    let body: Uint8Array;
    let contentType = '';
    if (value?.json !== undefined) { body = utf8(JSON.stringify(value.json)); contentType = 'application/json; charset=utf-8'; }
    else if (value?.body == null) body = new Uint8Array(0);
    else if (typeof value.body === 'string') { body = utf8(value.body); contentType = 'text/plain; charset=utf-8'; }
    else if (value.body instanceof Uint8Array) body = value.body;
    else if (value.body instanceof ArrayBuffer) body = new Uint8Array(value.body);
    else throw Error('Invalid response body');
    if (body.length > maxResponseBytes) throw Error('Response too large');
    let head = `HTTP/1.1 ${status} Response\r\nConnection: close\r\n`;
    let hasContentType = false;
    for (const [key, raw] of Object.entries(value?.headers ?? {})) {
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key)) throw Error('Invalid response header');
      const lower = key.toLowerCase();
      if (['content-length', 'transfer-encoding', 'connection', 'trailer'].includes(lower)) throw Error('Response framing is managed by http.serve');
      hasContentType ||= lower === 'content-type';
      for (const item of Array.isArray(raw) ? raw : [raw]) {
        if (typeof item !== 'string' || /[^\t\x20-\x7e]/.test(item)) throw Error('Invalid response header value');
        head += `${key}: ${item}\r\n`;
      }
    }
    if (contentType && !hasContentType) head += `Content-Type: ${contentType}\r\n`;
    const noBody = status === 204 || status === 304;
    if (!noBody) head += `Content-Length: ${body.length}\r\n`;
    head += '\r\n';
    const headerBytes = utf8(head);
    if (headerBytes.length > 16384) throw Error('Response headers too large');
    if (method === 'HEAD' || noBody) body = new Uint8Array(0);
    const output = new Uint8Array(headerBytes.length + body.length);
    output.set(headerBytes); output.set(body, headerBytes.length);
    pauseClientNative(id);
    respondNative(id, output);
  }
  function reject(id: number, status: number) { reply(id, { status, body: maxResponseBytes >= 8 ? `HTTP ${status}` : '' }); }
  const native = serveNative({ hostname, port, maxConnections, requestTimeoutMs }, (id, chunk) => {
    if (!chunk) { pending.delete(id); return; }
    let state = pending.get(id);
    if (!state) { state = { chunks: [], length: 0, head: new Uint8Array(0) }; pending.set(id, state); }
    if (state.handling || stopped) return;
    state.chunks.push(chunk); state.length += chunk.length;
    if (state.bodyOffset === undefined) {
      // Only the bounded header prefix is copied while finding the delimiter.
      const head = new Uint8Array(Math.min(16388, state.length));
      let offset = 0;
      for (const part of state.chunks) { const count = Math.min(part.length, head.length - offset); head.set(part.subarray(0, count), offset); offset += count; if (offset === head.length) break; }
      state.head = head;
      let end = -1;
      for (let i = 0; i + 3 < head.length; i++) if (head[i] === 13 && head[i + 1] === 10 && head[i + 2] === 13 && head[i + 3] === 10) { end = i; break; }
      if (end < 0) { if (state.length > 16384) { state.handling = true; reject(id, 431); } return; }
      if (end + 4 > 16384) { state.handling = true; reject(id, 431); return; }
      const lines = Array.from(head.subarray(0, end), x => String.fromCharCode(x)).join('').split('\r\n');
      const match = /^([!#$%&'*+.^_`|~0-9A-Za-z-]+) (\/[^\x00-\x20\x7f]*|\*) HTTP\/1\.([01])$/.exec(lines.shift()!);
      const headers: Record<string, string> = Object.create(null);
      let invalid = !match;
      for (const line of lines) {
        const colon = line.indexOf(':');
        const name = line.slice(0, colon).toLowerCase(), raw = line.slice(colon + 1), val = raw.replace(/^[ \t]+|[ \t]+$/g, '');
        if (colon <= 0 || !/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(name) || /[^\t\x20-\x7e\x80-\xff]/.test(raw)) { invalid = true; break; }
        if (headers[name] !== undefined) {
          if (['content-length', 'host', 'transfer-encoding'].includes(name)) { invalid = true; break; }
          headers[name] += ', ' + val;
        } else headers[name] = val;
      }
      if (match?.[3] === '1' && !headers.host) invalid = true;
      if (invalid) { state.handling = true; reject(id, 400); return; }
      if (headers['transfer-encoding'] !== undefined) { state.handling = true; reject(id, headers['content-length'] !== undefined ? 400 : 501); return; }
      if (headers.expect !== undefined) { state.handling = true; reject(id, 417); return; }
      const lengthText = headers['content-length'];
      if (lengthText !== undefined && !/^(0|[1-9][0-9]*)$/.test(lengthText)) { state.handling = true; reject(id, 400); return; }
      const length = Number(lengthText ?? 0);
      if (!Number.isSafeInteger(length) || length > maxBodyBytes) { state.handling = true; reject(id, 413); return; }
      state.method = match![1]; state.url = match![2]; state.headers = headers; state.bodyLength = length; state.bodyOffset = end + 4;
    }
    const expected = state.bodyOffset! + state.bodyLength!;
    if (state.length < expected) return;
    // No pipelining: surplus bytes cannot become a second request.
    state.handling = true; pauseClientNative(id);
    const body = new Uint8Array(state.bodyLength!);
    let sourceOffset = 0;
    for (const part of state.chunks) {
      const from = Math.max(0, state.bodyOffset! - sourceOffset), to = Math.min(part.length, expected - sourceOffset);
      if (to > from) body.set(part.subarray(from, to), sourceOffset + from - state.bodyOffset!);
      sourceOffset += part.length;
    }
    state.chunks = []; state.head = new Uint8Array(0);
    const request = { method: state.method!, url: state.url!, headers: state.headers!,
      text: () => decodeTextNative(body), json: <T = unknown>(): T => JSON.parse(decodeTextNative(body)), bytes: () => body.slice() };
    Promise.resolve().then(() => options.handler(request)).then(value => reply(id, value, request.method)).catch(() => {
      try { reply(id, { status: 500, body: maxResponseBytes >= 21 ? 'Internal Server Error' : '' }, request.method); } catch { /* connection deadline closes it */ }
    });
  });
  if (options.unref === true) globalThis.__hao_http_unrefServerNative(native.id);
  return { hostname, port: native.port, close() { if (!stopped) { stopped = true; pending.clear(); stopServerNative(native.id); } } };
}
