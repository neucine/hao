import http, { get, post, request } from 'hao:http'

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
