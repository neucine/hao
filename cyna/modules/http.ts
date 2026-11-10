type HeaderValue = string | string[];
type HeadersRecord = Record<string, HeaderValue>;

function fail(message: string): never { throw new Error(message); }
function normalize(url: string, options: any = {}) {
  if (typeof url !== 'string' || !url) fail('http.request requires a non-empty URL string');
  if (!options || typeof options !== 'object') fail('http.request options must be an object');
  if (options.timeoutMs != null) fail('http.request timeoutMs is not implemented yet');
  if (options.body != null && options.json != null) fail('http.request accepts either body or json, not both');
  const maxBytes = options.maxBytes ?? 1024 * 1024 * 1024;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > 1024 * 1024 * 1024) fail('http.request maxBytes must be between 1 and 1073741824');
  const redirect = options.redirect ?? 'follow';
  if (redirect !== 'follow' && redirect !== 'manual') fail('Invalid http.request redirect mode');
  let fullUrl = url;
  if (options.query) {
    const parts: string[] = [];
    for (const [key, value] of Object.entries(options.query)) {
      if (value == null) continue;
      if (!['string', 'number', 'boolean'].includes(typeof value)) fail(`http.request query value for ${key} is invalid`);
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`);
    }
    if (parts.length) fullUrl += (url.includes('?') ? '&' : '?') + parts.join('&');
  }
  const headers: [string, string][] = [];
  if (options.headers) {
    for (const [key, raw] of Object.entries(options.headers as HeadersRecord)) {
      if (!key || key.includes('\r') || key.includes('\n') || key.includes(':')) fail('http.request header name is invalid');
      const values = Array.isArray(raw) ? raw : [raw];
      for (const value of values) {
        if (typeof value !== 'string' || value.includes('\r') || value.includes('\n')) fail(`http.request header ${key} must contain only valid string values`);
        headers.push([key, value]);
      }
    }
  }
  let method = options.method;
  if (method == null) method = options.body != null || options.json != null ? 'POST' : 'GET';
  if (typeof method !== 'string' || !method.trim()) fail('http.request method must be a non-empty string');
  let body: string | Uint8Array | undefined;
  if (options.json != null) {
    body = JSON.stringify(options.json);
    if (!headers.some(([key]) => key.toLowerCase() === 'content-type')) headers.push(['content-type', 'application/json']);
  } else if (typeof options.body === 'string') body = options.body;
  else if (options.body instanceof Uint8Array) body = options.body;
  else if (options.body instanceof ArrayBuffer) body = new Uint8Array(options.body);
  else if (options.body != null) fail('http.request body must be a string, Uint8Array, or ArrayBuffer');
  return { url: fullUrl, method: method.trim().toUpperCase(), headers, body, maxBytes, redirect };
}

export function request(url: string, options?: any) {
  const normalized = normalize(url, options);
  return Promise.resolve().then(() => {
    const raw = globalThis.__hao_http_requestNative(normalized);
    return {
      status: raw.status, ok: raw.status >= 200 && raw.status < 300,
      statusText: raw.statusText, headers: raw.headers, url: raw.url,
      text() { return raw.bodyText; },
      json() { return JSON.parse(raw.bodyText); },
      bytes() { return raw.bodyBytes.slice(0); },
    };
  });
}
export function get(url: string, options?: any) { return request(url, { ...options, method: 'GET' }); }
export function post(url: string, options?: any) { return request(url, { ...options, method: 'POST' }); }
export function download(url: string, path: string, options?: any) {
  if (typeof path !== 'string' || !path || path.includes('\0')) fail('http.download requires a destination path');
  if (options?.body != null || options?.json != null || options?.method != null) fail('http.download supports bodiless GET only');
  const normalized = normalize(url, { ...options, method: 'GET' });
  normalized.redirect = 'follow';
  return Promise.resolve().then(() => ({
    ...globalThis.__hao_http_requestNative({ ...normalized, downloadPath: path }),
    path,
  }));
}
export default { request, get, post, download };
