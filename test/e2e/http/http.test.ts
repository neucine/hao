import { describe, test, expect, beforeEach, afterEach } from 'std:test'
import { run } from 'std:process'
import { getEnv } from 'std:process'
import fs from 'std:fs'
import { get, post, download } from 'std:http'

const serverScript = 'test/e2e/http/server.py'

describe('http module', () => {
  let pid: string | null = null
  let serverPid: string | null = null
  let portFile = ''
  let serverUrl = ''

  beforeEach(async () => {
    portFile = `.hao-http-port-${Date.now()}-${Math.random().toString(16).slice(2)}`
    const python = getEnv('pythonLocation')
      ? `${getEnv('pythonLocation')}/bin/python3`
      : 'python3'
    const out = await run({
      cmd: python,
      args: ['-u', serverScript],
    })
    const [port, childPid] = out.stdout.trim().split(/\s+/)
    if (out.exitCode === 0 && port && childPid) {
      serverPid = childPid
      pid = childPid
      serverUrl = `http://127.0.0.1:${port}`
      return
    }

    throw new Error(`failed to start local HTTP server (exit=${out.exitCode} stdout=${JSON.stringify(out.stdout)} stderr=${JSON.stringify(out.stderr)})`)
  })

  afterEach(async () => {
    if (pid) {
      await run({
        cmd: 'sh',
        args: ['-c', `kill ${serverPid || pid} >/dev/null 2>&1 || true; rm -f ${portFile}`],
        check: false,
      })
    }
    pid = null
    serverPid = null
    serverUrl = ''
  })

  test('performs a GET request with query params and JSON decoding', async () => {
    const response = await get(`${serverUrl}/json`, {
      query: { q: 'hello world', page: 2, exact: true },
    })

    expect(response.status).toBe(200)
    expect(response.ok).toBe(true)
    expect(response.headers['Content-Type']).toBe('application/json')
    expect(response.headers['X-Hao-Test']).toBe('yes')
    expect(response.json<{ ok: boolean; path: string }>().path).toContain('q=hello%20world')
    expect(response.text()).toContain('"ok": true')
  })

  test('performs a POST request with JSON body helpers', async () => {
    const response = await post(`${serverUrl}/echo`, {
      json: { answer: 42 },
    })

    const body = response.json<{ method: string; contentType: string; body: string }>()
    expect(response.status).toBe(200)
    expect(body.method).toBe('POST')
    expect(body.contentType).toBe('application/json')
    expect(body.body).toBe('{"answer":42}')
  })

  test('exposes raw bytes through bytes()', async () => {
    const response = await get(`${serverUrl}/bytes`)
    const bytes = response.bytes()

    expect(bytes).toBeInstanceOf(Uint8Array)
    expect(Array.from(bytes)).toEqual([0, 1, 2, 255])
  })
  test('streams binary data through redirects and computes its checksum', async () => {
    const root = (await run({ cmd: 'mktemp', args: ['-d', '/tmp/hao-download.XXXXXX'] })).stdout.trim()
    try {
      const path = `${root}/model.bin`
      const result = await download(`${serverUrl}/download-redirect`, path, { maxBytes: 4 * 1024 * 1024 })
      expect(result.status).toBe(200)
      expect(result.url).toBe(`${serverUrl}/large`)
      expect(result.bytesWritten).toBe(4 * 1024 * 1024)
      expect(fs.statSync(path).size).toBe(result.bytesWritten)
      const expected = (await run({ cmd: 'shasum', args: ['-a', '256', path] })).stdout.split(/\s/)[0]
      expect(result.sha256).toBe(expected)
      expect(result.sha256).toBe('2b07811057df887086f06a67edc6ebf911de8b6741156e7a2eb1416a4b8b1b2e')
      expect('bodyBytes' in result).toBe(false)
      expect('bodyText' in result).toBe(false)
      const empty = await download(`${serverUrl}/empty`, path)
      expect(empty.bytesWritten).toBe(0)
      expect(empty.sha256).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
      expect(fs.statSync(path).size).toBe(0)
    } finally { await run({ cmd: 'rm', args: ['-rf', root] }) }
  })

  test('enforces decoded byte limits and preserves destinations on all transfer failures', async () => {
    const root = (await run({ cmd: 'mktemp', args: ['-d', '/tmp/hao-download.XXXXXX'] })).stdout.trim()
    try {
      const path = `${root}/model.bin`
      fs.writeFileSync(path, 'original')
      for (const route of ['/large', '/compressed', '/truncated', '/chunked-truncated', '/missing']) {
        let failed = false
        try { await download(`${serverUrl}${route}`, path, { maxBytes: 100000 }) }
        catch { failed = true }
        if (!failed) throw new Error(`Expected download failure for ${route}`)
        expect(fs.readFileSync(path)).toBe('original')
        const listing = (await run({ cmd: 'ls', args: ['-A', root] })).stdout.trim()
        expect(listing).toBe('model.bin')
      }
      for (const route of ['/compressed', '/compressed-length', '/chunked-compressed']) {
        const compressed = await download(`${serverUrl}${route}`, path, { maxBytes: 200000 })
        expect(compressed.bytesWritten).toBe(200000)
        expect(fs.readFileSync(path)).toBe('A'.repeat(200000))
      }
      await download(`${serverUrl}/chunked`, path)
      expect(fs.readFileSync(path)).toBe('chunked payload')
      let failed = false
      try { await download(`${serverUrl}/bytes`, `${root}/missing/file`) } catch { failed = true }
      expect(failed).toBe(true)
    } finally { await run({ cmd: 'rm', args: ['-rf', root] }) }
  })

  test('rejects invalid streaming arguments before requesting', () => {
    for (const maxBytes of [0, -1, 0.5, Infinity, NaN]) {
      expect(() => download(serverUrl, '/tmp/unused', { maxBytes })).toThrow()
    }
    expect(() => download(serverUrl, '')).toThrow()
  })

})
