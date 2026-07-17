type HttpHeaderValue = string | string[]
type HttpHeaders = Record<string, HttpHeaderValue>
type HttpQueryValue = string | number | boolean | null | undefined

interface HttpRequestOptions {
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

declare module "hao:http" {
  export function request(url: string, opts?: HttpRequestOptions): Promise<HttpResponse>
  export function get(url: string, opts?: Omit<HttpRequestOptions, "method">): Promise<HttpResponse>
  export function post(url: string, opts?: Omit<HttpRequestOptions, "method">): Promise<HttpResponse>

  const httpModule: {
    request: typeof request
    get: typeof get
    post: typeof post
  }

  export default httpModule
}
