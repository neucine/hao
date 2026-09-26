import { requestNative, serveNative, stopServerNative, pauseClientNative, respondNative, encodeTextNative, decodeTextNative } from "std:http/native";

type HeaderValue = string | string[];
type HeadersRecord = Record<string, HeaderValue>;

function fail(message: string): never {
  throw new Error(message);
}

function assertUrl(url: string) {
  if (typeof url !== "string" || url.length === 0) {
    fail("http.request requires a non-empty URL string");
  }
}

function normalizeMethod(method: unknown, hasBody: boolean): string {
  if (method == null) return hasBody ? "POST" : "GET";
  if (typeof method !== "string") {
    fail("http.request method must be a string");
  }
  const normalized = method.trim().toUpperCase();
  if (!normalized) {
    fail("http.request method must be a non-empty string");
  }
  return normalized;
}

function appendQuery(url: string, query: Record<string, unknown> | undefined): string {
  if (!query) return url;
  const parts: string[] = [];
  for (const [key, raw] of Object.entries(query)) {
    if (raw == null) continue;
    if (typeof raw !== "string" && typeof raw !== "number" && typeof raw !== "boolean") {
      fail(`http.request query value for ${key} must be string, number, boolean, null, or undefined`);
    }
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(raw))}`);
  }
  if (parts.length === 0) return url;
  return `${url}${url.includes("?") ? "&" : "?"}${parts.join("&")}`;
}

function normalizeHeaders(headers: HeadersRecord | undefined): [string, string][] {
  if (!headers) return [];
  const out: [string, string][] = [];
  for (const [key, raw] of Object.entries(headers)) {
    if (typeof key !== "string" || key.length === 0) {
      fail("http.request header names must be non-empty strings");
    }
    if (typeof raw === "string") {
      out.push([key, raw]);
      continue;
    }
    if (Array.isArray(raw)) {
      for (const value of raw) {
        if (typeof value !== "string") {
          fail(`http.request header ${key} must contain only string values`);
        }
        out.push([key, value]);
      }
      continue;
    }
    fail(`http.request header ${key} must be a string or string[]`);
  }
  return out;
}

function ensureUint8Array(body: Uint8Array | ArrayBuffer): Uint8Array {
  if (body instanceof Uint8Array) return body;
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  fail("http.request body must be a string, Uint8Array, or ArrayBuffer");
}

function normalize(url: string, opts?: any) {
  assertUrl(url);
  const options = opts ?? {};
  if (options == null || typeof options !== "object") {
    fail("http.request options must be an object when provided");
  }
  if (options.timeoutMs != null) {
    fail("http.request timeoutMs is not implemented yet");
  }
  if (options.body != null && options.json != null) {
    fail("http.request accepts either body or json, not both");
  }

  const maxBytes = options.maxBytes ?? 1024 * 1024 * 1024;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) fail('http.request maxBytes must be a positive safe integer');
  const redirect = options.redirect ?? 'follow';
  if (redirect !== 'follow' && redirect !== 'manual') fail('Invalid http.request redirect mode');
  const fullUrl = appendQuery(url, options.query);
  const headers = normalizeHeaders(options.headers);
  const normalized: any = {
    url: fullUrl,
    maxBytes, redirect,
    method: normalizeMethod(options.method, options.body != null || options.json != null),
    headers,
  };

  if (options.json != null) {
    normalized.bodyText = JSON.stringify(options.json);
    const hasContentType = headers.some(([key]) => key.toLowerCase() === "content-type");
    if (!hasContentType) {
      normalized.headers = headers.concat([["content-type", "application/json"]]);
    }
  } else if (typeof options.body === "string") {
    normalized.bodyText = options.body;
  } else if (options.body != null) {
    normalized.bodyBytes = ensureUint8Array(options.body);
  }

  return normalized;
}

function decorateResponse(raw: any) {
  return {
    status: raw.status,
    ok: raw.ok,
    statusText: raw.statusText,
    headers: raw.headers,
    url: raw.url,
    text(): string {
      return raw.bodyText;
    },
    json<T = unknown>(): T {
      return JSON.parse(raw.bodyText) as T;
    },
    bytes(): Uint8Array {
      return raw.bodyBytes.slice(0);
    },
  };
}

let dispatch = (request: any) => Promise.resolve().then(() => requestNative(request));

function request(url: string, opts?: any) {
  const normalized = normalize(url, opts);
  return dispatch(normalized).then((raw: any) => decorateResponse(raw));
}

function get(url: string, opts?: any) {
  return request(url, { ...(opts ?? {}), method: "GET" });
}

function post(url: string, opts?: any) {
  return request(url, { ...(opts ?? {}), method: "POST" });
}

/** Stream a GET response to disk with bounded buffers and atomic replacement. */
function download(url: string, path: string, opts?: any) {
  if (typeof path !== "string" || !path || path.includes("\0")) fail("http.download requires a destination path");
  const maxBytes = opts?.maxBytes ?? 1024 * 1024 * 1024;
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) fail("http.download maxBytes must be a positive safe integer");
  if (opts?.body != null || opts?.json != null || opts?.method != null) fail("http.download supports bodiless GET only");
  const normalized = normalize(url, { ...opts, method: "GET" });
  normalized.downloadPath = path;
  normalized.maxBytes = maxBytes;
  return dispatch(normalized).then((raw: any) => ({
    status: raw.status, statusText: raw.statusText, ok: raw.ok,
    headers: raw.headers, url: raw.url, path, bytesWritten: raw.bytesWritten, sha256: raw.sha256,
  }));
}

export { request, get, post, download, serve };
export default { request, get, post, download, serve };

// Small HTTP/1.x server: one buffered request/response per connection.
// Keeping framing here makes its validation testable independently of TCP I/O.
function serve(options: any) {
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
  return { hostname, port: native.port, close() { if (!stopped) { stopped = true; pending.clear(); stopServerNative(native.id); } } };
}
