const request = globalThis.__hao_http_requestNative;
export async function requestNative(options: any) {
  const body = options.bodyText ?? options.bodyBytes;
  const raw = await request({ ...options, body });
  return { ...raw, ok: raw.status >= 200 && raw.status < 300 };
}
export const serveNative = globalThis.__hao_http_serveNative;
export const stopServerNative = globalThis.__hao_http_stopServerNative;
export const pauseClientNative = globalThis.__hao_http_pauseClientNative;
export const respondNative = globalThis.__hao_http_respondNative;
export const encodeTextNative = globalThis.__hao_http_encodeTextNative;
export const decodeTextNative = globalThis.__hao_http_decodeTextNative;
