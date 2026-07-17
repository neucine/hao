import { describe, test, expect } from 'hao:test'
import { c } from 'hao:ffi'

const { decl: cdecl } = c

describe('c basic', () => {
  test('binds direct libm calls through hao:ffi.c', () => {
    const libm = cdecl('m', `
      double sqrt(double x);
      double pow(double x, double y);
    `)

    expect(libm.sqrt(25)).toBe(5)
    expect(libm.pow(2, 8)).toBe(256)

    libm.close()
  })

  test('maps const char* and size_t through hao:ffi.c', () => {
    const libc = cdecl('c', `
      size_t strlen(const char* s);
    `)

    expect(libc.strlen('hello')).toBe(5)
    expect(libc.strlen('')).toBe(0)

    libc.close()
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
