import { requestNative } from "std:http/native";

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

  const fullUrl = appendQuery(url, options.query);
  const headers = normalizeHeaders(options.headers);
  const normalized: any = {
    url: fullUrl,
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

export { request, get, post };
export default { request, get, post };
