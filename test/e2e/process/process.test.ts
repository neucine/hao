import { describe, test, expect } from 'hao:test'
import { run } from 'hao:process'

describe('process module', () => {
  test('captures stdout stderr and exit status', async () => {
    const out = await run({
      cmd: 'sh',
      args: ['-c', 'printf "hello"; printf "warn" >&2'],
    })

    expect(out.stdout).toBe('hello')
    expect(out.stderr).toBe('warn')
    expect(out.exitCode).toBe(0)
    expect(out.signal).toBeNull()
  })

  test('supports cwd overrides', async () => {
    const out = await run({
      cmd: 'sh',
      args: ['-c', 'pwd'],
      cwd: 'test',
    })

    expect(out.stdout).toMatch('/test')
  })

  test('can parse structured stdout explicitly', async () => {
    const out = await run({
      cmd: 'sh',
      args: ['-c', 'printf \'{"value":[1,2,3]}\''],
    })

    expect(out.json<{ value: number[] }>().value).toEqual([1, 2, 3])
  })

  test('supports parsing json directly from the process promise', async () => {
    const value = await run(`printf '{"value":[1,2,3]}'`).json<{ value: number[] }>()
    expect(value.value).toEqual([1, 2, 3])
  })

  test('async process promise preserves default check and json helpers together', async () => {
    const out = await run({
      cmd: 'sh',
      args: ['-c', 'printf \'{"ok":true,"value":[4,5]}\''],
    })

    expect(out.exitCode).toBe(0)
    expect(out.signal).toBeNull()
    expect(out.json<{ ok: boolean; value: number[] }>().value).toEqual([4, 5])

    const value = await run({
      cmd: 'sh',
      args: ['-c', 'printf \'{"ok":true,"value":[6,7]}\''],
    }).json<{ ok: boolean; value: number[] }>()
    expect(value.value).toEqual([6, 7])
  })

  test('check:false returns non-zero results without throwing', async () => {
    const out = await run({
      cmd: 'sh',
      args: ['-c', 'printf "bad"; printf "err" >&2; exit 7'],
      check: false,
    })

    expect(out.stdout).toBe('bad')
    expect(out.stderr).toBe('err')
    expect(out.exitCode).toBe(7)
  })

  test('default check throws on non-zero exit', async () => {
    let err: any = null
    try {
      await run({
        cmd: 'sh',
        args: ['-c', 'printf "bad"; printf "err" >&2; exit 9'],
      })
    } catch (caught) {
      err = caught
    }

    expect(err).toBeDefined()
    expect(err).toBeInstanceOf(Error)
    expect(err.message).toContain('exit code 9')
    expect(err.exitCode).toBe(9)
    expect(err.stdout).toBe('bad')
    expect(err.stderr).toBe('err')
  })
})
