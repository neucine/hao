import { describe, test, expect } from 'std:test'
import { c } from 'std:ffi'
import { prepareNative } from 'std:ffi/c/native'

const { decl: cdecl } = c

describe('c basic', () => {
  test('classifies invalid declarations as invalid_arg', () => {
    let error: any = null
    try { cdecl('m', 'double sqrt(...);') } catch (caught) { error = caught }
    expect(error).toBeInstanceOf(RuntimeError)
    expect(error.code).toBe('invalid_arg')
  })

  test('rejects platform width integer names as legacy does', () => {
    for (const type of ['int', 'short', 'long', 'unsigned int']) {
      let error: any = null
      try { prepareNative('m', `${type} sum(${type} a, ${type} b);`) }
      catch (caught) { error = caught }
      expect(error).toBeInstanceOf(RuntimeError)
      expect(error.code).toBe('invalid_arg')
    }
  })

  test('binds direct libm calls through std:ffi.c', () => {
    const libm = cdecl('m', `
      double sqrt(double x);
      double pow(double x, double y);
    `)

    expect(libm.sqrt(25)).toBe(5)
    expect(libm.pow(2, 8)).toBe(256)

    libm.close()
  })

  test('maps const char* and size_t through std:ffi.c', () => {
    const libc = cdecl('c', `
      size_t strlen(const char* s);
    `)

    expect(libc.strlen('hello')).toBe(5)
    expect(libc.strlen('')).toBe(0)

    libc.close()
  })

  test('accepts C types split across declaration lines', () => {
    const libc = cdecl('c', `
      const
      char *strerror(int32_t
        code);
    `)

    expect(typeof libc.strerror(2)).toBe('string')
    libc.close()

    prepareNative('c', `
      typedef struct { double
        x; double y; } HaoPoint;
      void hao_move_point(HaoPoint *point);
    `)
  })

  test('maps pointer-plus-length buffer policies onto typed-array arguments', () => {
    const libc = cdecl('c', `
      void* memcpy(void* dest, const void* src, size_t n);
    `, {
      functions: {
        memcpy: {
          buffers: {
            dest: { length: 'n', element: 'u8', direction: 'out' },
            src: { length: 'n', element: 'u8' },
          },
        },
      },
    })

    const dest = new Uint8Array(4)
    const src = new Uint8Array([10, 20, 30, 40])
    libc.memcpy(dest, src)

    expect(Array.from(dest)).toEqual([10, 20, 30, 40])

    libc.close()
  })
})
