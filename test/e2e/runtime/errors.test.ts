import { describe, test, expect } from 'hao:test'
import { c } from 'hao:ffi'

function captureError(fn: () => void): any {
  try {
    fn()
  } catch (err) {
    return err
  }
  throw new Error('expected function to throw')
}

describe('runtime errors', () => {
  test('HaoError constructor matches the public surface', () => {
    const err = new HaoError('invalid_arg', 'test: bad argument')
    expect(err instanceof Error).toBe(true)
    expect(err instanceof HaoError).toBe(true)
    expect(err.name).toBe('HaoError')
    expect(err.message).toBe('test: bad argument')
    expect(err.code).toBe('invalid_arg')
    expect(typeof err.stack === 'string' && err.stack.length > 0).toBe(true)
  })

  test('ffi missing library throws io_error', () => {
    const err = captureError(() => c.decl('nonexistent_library_xyz', 'double sqrt(double x);'))
    expect(err instanceof HaoError).toBe(true)
    expect(err.code).toBe('io_error')
    expect(err.message).toContain('openNative: failed to open library')
  })
})
