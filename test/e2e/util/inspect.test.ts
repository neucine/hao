import { describe, test, expect } from 'hao:test'
import { inspect } from 'hao:util'

describe('util inspect', () => {
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
