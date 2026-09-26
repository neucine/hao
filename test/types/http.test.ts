import http, { get, post, request } from 'std:http'

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

const response = await request('https://example.test', {
  headers: {
    accept: 'application/json',
    vary: ['accept', 'content-type'],
  },
  query: {
    page: 1,
    debug: false,
    empty: null,
    missing: undefined,
  },
  json: { ok: true },
})

assertType<IsExact<typeof response.status, number>>()
assertType<IsExact<typeof response.ok, boolean>>()
assertType<IsExact<ReturnType<typeof response.text>, string>>()
assertType<IsExact<ReturnType<typeof response.bytes>, Uint8Array>>()

const body = response.json<{ ok: boolean }>()
assertType<IsExact<typeof body, { ok: boolean }>>()

const getResponse = await get('https://example.test', { query: { q: 'hao' } })
assertType<IsExact<typeof getResponse.url, string>>()

await post('https://example.test', { body: new Uint8Array([1, 2, 3]) })
await post('https://example.test', { body: new ArrayBuffer(4) })
await http.request('https://example.test')

// @ts-expect-error - get options cannot override method
await get('https://example.test', { method: 'POST' })
// @ts-expect-error - headers values must be strings or string arrays
await request('https://example.test', { headers: { bad: 123 } })
// @ts-expect-error - query values are limited to scalar URL values
await request('https://example.test', { query: { bad: { nested: true } } })
// @ts-expect-error - request URL is required
await request()

const downloaded = await http.download('https://example.test/model', '/tmp/model', { maxBytes: 1024 })
assertType<IsExact<typeof downloaded.bytesWritten, number>>()
assertType<IsExact<typeof downloaded.sha256, string>>()
// @ts-expect-error Streaming results do not expose buffered body accessors.
downloaded.bytes()
// @ts-expect-error Streaming downloads support bodiless GET only.
await http.download('https://example.test', '/tmp/model', { body: 'no' })

const server = http.serve({ port: 0, async handler(req) {
  assertType<IsExact<ReturnType<typeof req.bytes>, Uint8Array>>()
  assertType<IsExact<typeof req.headers, Record<string, string>>>()
  return { status: 200, json: req.json() }
} })
assertType<IsExact<typeof server.port, number>>()
server.close()
// @ts-expect-error A server requires a handler.
http.serve({ port: 8000 })
// @ts-expect-error A response body must be text or bytes.
http.serve({ handler: () => ({ body: 123 }) })
