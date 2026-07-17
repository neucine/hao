import { describe, test, expect, beforeEach, afterEach } from 'std:test'
import { readFileSync } from 'std:fs'
import { run } from 'std:process'
import { getEnv } from 'std:process'
import { get, post } from 'std:http'

const serverScript = 'test/e2e/http/server.py'

async function sleep(ms: number) {
  await new Promise<void>((resolve) => {
    setTimeout(resolve, ms)
  })
}

describe('http module', () => {
  let pid: string | null = null
  let portFile = ''
  let errorFile = ''
  let serverUrl = ''

  beforeEach(async () => {
    portFile = `.hao-http-port-${Date.now()}-${Math.random().toString(16).slice(2)}`
    errorFile = `${portFile}.err`
    const python = getEnv('pythonLocation')
      ? `${getEnv('pythonLocation')}/bin/python3`
      : 'python3'
    const out = await run({
      cmd: 'sh',
      args: ['-c', `nohup ${python} -u ${serverScript} > ${portFile} 2> ${errorFile} </dev/null & echo $!`],
    })
    pid = out.stdout.trim()

    for (let attempt = 0; attempt < 50; attempt += 1) {
      try {
        const port = readFileSync(portFile).trim()
        if (port) {
          serverUrl = `http://127.0.0.1:${port}`
          return
        }
      } catch {}
      await sleep(50)
    }

    let details = ''
    try {
      details = readFileSync(errorFile).trim()
    } catch {}
    throw new Error(`timed out waiting for local HTTP server to start${details ? `: ${details}` : ''}`)
  })

  afterEach(async () => {
    if (pid) {
      await run({
        cmd: 'sh',
        args: ['-c', `kill ${pid} >/dev/null 2>&1 || true; rm -f ${portFile} ${errorFile}`],
        check: false,
      })
    }
    pid = null
    serverUrl = ''
    errorFile = ''
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
})
