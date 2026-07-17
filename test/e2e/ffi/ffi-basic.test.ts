import { describe, test, expect } from 'hao:test'
import { dlopen } from 'hao:ffi'

describe('ffi basic', () => {
  test('calls libm functions through dlopen bindings', () => {
    const libm = dlopen('m', {
      ceil: { args: ['f64'], returns: 'f64' },
      floor: { args: ['f64'], returns: 'f64' },
      sqrt: { args: ['f64'], returns: 'f64' },
      pow: { args: ['f64', 'f64'], returns: 'f64' },
      abs: { args: ['i32'], returns: 'i32' },
    })

    expect(libm.ceil(2.3)).toBe(3)
    expect(libm.floor(2.7)).toBe(2)
    expect(libm.sqrt(16)).toBe(4)
    expect(libm.pow(2, 10)).toBe(1024)
    expect(libm.abs(-42)).toBe(42)

    libm.close()
  })
})
