import { describe, test, expect } from 'std:test'
import { inspect } from 'std:util'
import native from 'std:util/native'

describe('util inspect', () => {
  test('native module shares inspect options and handles circular values', () => {
    const cycle: any = { value: 3 }
    cycle.self = cycle
    expect(native.inspect(cycle)).toBe('{ value: 3, self: [Circular] }')
    native.setInspectOptions({ maxDepth: 1 })
    expect(inspect({ child: { value: 3 } })).toBe('{ child: [Object] }')
    native.setInspectOptions({ maxDepth: 4 })
    expect((inspect as any)()).toBeUndefined()
  })

  test('prefers generic repr data over toString', () => {
    const value = {
      repr() {
        return { mime: 'image/svg+xml', data: '<svg><circle /></svg>' }
      },
      toString() {
        return 'raw fallback'
      },
    }

    expect(inspect(value)).toBe('<svg><circle /></svg>')
  })
})
