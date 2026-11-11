type HttpHeaderValue = string | string[]
type HttpHeaders = Record<string, HttpHeaderValue>
type HttpQueryValue = string | number | boolean | null | undefined

interface HttpRequestOptions {
  /** Maximum decoded response bytes; defaults to 1 GiB. */
  maxBytes?: number
  /** Follow up to three redirects (default), or return the redirect response. */
  redirect?: 'follow' | 'manual'

  method?: string
  headers?: HttpHeaders
  query?: Record<string, HttpQueryValue>
  body?: string | Uint8Array | ArrayBuffer
  json?: unknown
}

interface HttpResponse {
  status: number
  statusText: string
  ok: boolean
  headers: HttpHeaders
  url: string
  text(): string
  json<T = unknown>(): T
  bytes(): Uint8Array
}

interface HttpDownloadOptions {
  headers?: HttpHeaders
  query?: Record<string, HttpQueryValue>
  /** Maximum decoded body bytes written; defaults to 1 GiB. */
  maxBytes?: number
}

interface HttpDownloadResult {
  status: number
  statusText: string
  ok: boolean
  headers: HttpHeaders
  url: string
  path: string
  bytesWritten: number
  /** Lowercase SHA-256 of the decoded bytes written to disk. */
  sha256: string
}

interface HttpServerRequest {
  method: string
  /** Request target, including path and query (not an absolute URL). */
  url: string
  /** Lowercase header names. */
  headers: Record<string, string>
  text(): string
  json<T = unknown>(): T
  bytes(): Uint8Array
}

interface HttpServerResponse {
  status?: number
  headers?: HttpHeaders
  body?: string | Uint8Array | ArrayBuffer
  json?: unknown
}

interface HttpServerOptions {
  /** IPv4 address; defaults to 127.0.0.1. */
  hostname?: string
  /** Defaults to 8000; use 0 for an available port. */
  port?: number
  handler(request: HttpServerRequest): HttpServerResponse | Promise<HttpServerResponse>
  /** Default 1 MiB; maximum 16 MiB. */
  maxBodyBytes?: number
  /** Default 16 MiB; maximum 64 MiB. */
  maxResponseBytes?: number
  /** Default 64; maximum 1024. */
  maxConnections?: number
  /** Connection lifetime, including the handler; default 30000 ms. */
  requestTimeoutMs?: number
}

interface HttpServer {
  hostname: string
  port: number
  /** Stop accepting and close active connections. Safe to call repeatedly. */
  close(): void
}

declare module "std:http" {
  /** Native HTTP/1.x server. Buffered bodies, one request per connection.
   * Header limit: 16 KiB. No TLS, keep-alive, chunked uploads or streaming responses.
   * Handler failures produce HTTP 500; deadlines close the connection.
   */
  export function serve(options: HttpServerOptions): HttpServer

  /**
   * Stream a GET response to a file using bounded native buffers on an I/O worker.
   * @param url HTTP(S) source URL; follows up to three redirects.
   * @param path Destination file; its parent directory must exist.
   * @param opts Request headers/query and maximum decoded body size (default 1 GiB).
   * @returns Response metadata, bytes written, and SHA-256; no in-memory response body.
   * @remarks Atomically replaces the destination after a complete successful 2xx response.
   * Errors reject and remove the temporary file, preserving an existing destination.
   * Supports decompression, but not progress callbacks, cancellation, resume, or timeouts yet.
   */
  export function download(url: string, path: string, opts?: HttpDownloadOptions): Promise<HttpDownloadResult>
  export function request(url: string, opts?: HttpRequestOptions): Promise<HttpResponse>
  export function get(url: string, opts?: Omit<HttpRequestOptions, "method">): Promise<HttpResponse>
  export function post(url: string, opts?: Omit<HttpRequestOptions, "method">): Promise<HttpResponse>

  const httpModule: {
    serve: typeof serve
    download: typeof download
    request: typeof request
    get: typeof get
    post: typeof post
  }

  export default httpModule
}
