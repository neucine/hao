import { dlopen, Pointer } from 'hao:ffi'

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

// Basic math library
const lib = dlopen('m', {
  ceil: { args: ['f64'], returns: 'f64' },
  floor: { args: ['f64'], returns: 'f64' },
})

// ceil takes number, returns number
const r = lib.ceil(2.3)
assertType<IsExact<typeof r, number>>()

// close() exists
lib.close()

// Pointer type is opaque
const lib2 = dlopen('test', {
  create: { args: [], returns: 'ptr' },
  destroy: { args: ['ptr'], returns: 'void' },
})

const p = lib2.create()
assertType<IsExact<typeof p, Pointer>>()

lib2.destroy(p)

// cstring maps to string
const lib3 = dlopen('c', {
  strlen: { args: ['cstring'], returns: 'u64' },
})
const n = lib3.strlen('hello')
assertType<IsExact<typeof n, number>>()

// bool type
const lib4 = dlopen('test', {
  check: { args: ['bool'], returns: 'bool' },
})
const b = lib4.check(true)
assertType<IsExact<typeof b, boolean>>()

// void return
const lib5 = dlopen('test', {
  doSomething: { args: ['i32', 'f64'], returns: 'void' },
})
const v = lib5.doSomething(1, 2.0)
assertType<IsExact<typeof v, void>>()

// Negative tests
// @ts-expect-error - can't pass string where number expected
lib.ceil('hello')

// @ts-expect-error - can't pass number where Pointer expected
lib2.destroy(42)
