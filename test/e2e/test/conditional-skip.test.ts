import { describe, test, expect } from 'hao:test'

describe('conditional skip', () => {
  test.skip(() => true)('skips when predicate is true', () => {
    throw new Error('should not run')
  })

  test.skip(() => false)('runs when predicate is false', () => {
    expect(2 + 3).toBe(5)
  })

  describe.skip(() => true)('skipped suite', () => {
    test('nested skipped test', () => {
      throw new Error('should not run')
    })
  })

  describe.skip(() => false)('active suite', () => {
    test('nested active test', () => {
      expect('ok').toBe('ok')
    })
  })

  test('rejects predicate callbacks with parameters', () => {
    expect(() => {
      ;(test.skip as any)((flag: boolean) => flag)('bad predicate', () => {})
    }).toThrow('predicate must not accept arguments')
  })
})
