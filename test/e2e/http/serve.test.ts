import { test, expect } from 'std:test'
import { serve, get, post, request } from 'std:http'

test('native server handles async JSON, UTF-8, bytes, HEAD and errors', async () => {
  const server = serve({ port: 0, async handler(req) {
    await new Promise(resolve => setTimeout(resolve, 2))
    if (req.url === '/json') return { json: { method: req.method, ...req.json<any>() } }
    if (req.url === '/bytes') return { body: req.bytes() }
    if (req.url === '/error') throw Error('private details')
    if (req.url === '/invalid-header') return { headers: { test: 'x\r\ny: z' } }
    return { body: 'Hello 世界 🐈', headers: { 'X-Test': 'yes' } }
  } })
  const url = `http://${server.hostname}:${server.port}`
  try {
    expect(server.port > 0).toBe(true)
    const response = await get(url)
    expect(response.text()).toBe('Hello 世界 🐈')
    expect(response.headers['X-Test']).toBe('yes')
    expect((await post(url + '/json', { json: { answer: 42 } })).json()).toEqual({ method: 'POST', answer: 42 })
    expect(Array.from((await post(url + '/bytes', { body: new Uint8Array([0, 255, 42]) })).bytes())).toEqual([0, 255, 42])
    expect((await request(url, { method: 'HEAD' })).text()).toBe('')
    expect((await get(url + '/error')).status).toBe(500)
    expect((await get(url + '/invalid-header')).status).toBe(500)
    const responses = await Promise.all([get(url), get(url), get(url)])
    expect(responses.every(r => r.status === 200)).toBe(true)
    expect(() => serve({ port: server.port, handler: () => ({}) })).toThrow()
  } finally { server.close(); server.close() }
})

test('native server enforces request and response limits', async () => {
  const server = serve({ port: 0, maxBodyBytes: 3, maxResponseBytes: 32, handler: () => ({ body: 'x'.repeat(40) }) })
  try {
    const url = `http://127.0.0.1:${server.port}`
    expect((await post(url, { body: '1234' })).status).toBe(413)
    expect((await get(url)).status).toBe(500)
  } finally { server.close() }
  expect(() => serve({ port: -1, handler: () => ({}) })).toThrow()
  expect(() => serve({ port: 0, hostname: 'invalid', handler: () => ({}) })).toThrow()
})

test('native server validates wire framing and expires incomplete or slow requests', async () => {
  const { run } = await import('std:process')
  const result = await run({ cmd: 'python3', args: ['test/e2e/http/server-wire.py', 'zig-out/bin/hao'], check: false })
  if (result.exitCode !== 0) throw Error(result.stderr)
  expect(result.stdout).toContain('checks passed')
})

test('buffered client limits bytes and supports manual redirects', async () => {
  const server = serve({ port: 0, handler(req) {
    if (req.url === '/redirect') return { status: 302, headers: { location: '/bytes' } }
    return { body: new Uint8Array(200000) }
  } })
  try {
    const url = `http://127.0.0.1:${server.port}`
    expect((await get(url + '/redirect', { redirect: 'manual' })).status).toBe(302)
    expect((await get(url + '/redirect', { maxBytes: 200000 })).bytes().length).toBe(200000)
    let rejected = false
    try { await get(url, { maxBytes: 199999 }) } catch { rejected = true }
    expect(rejected).toBe(true)
    expect(() => get(url, { maxBytes: 0 })).toThrow()
  } finally { server.close() }
})
