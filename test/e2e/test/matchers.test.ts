import { describe, test, expect } from 'std:test'

describe('std:test matchers', () => {
  test('supports richer core matchers', () => {
    expect('abc').toHaveLength(3)
    expect([1, 2, 3]).toHaveLength(3)
    expect('abcdef').toContain('cde')
    expect('abcdef').toMatch('bcd')
    expect('abc123').toMatch(/[a-z]+\d+/)
    expect([1, 2, 3]).toContain(2)
    expect(undefined).not.toBeDefined()
    expect(undefined).toBeUndefined()
    expect('value').toBeDefined()
    expect(null).toBeNull()
    expect(new Error('boom')).toBeInstanceOf(Error)
    expect('alpha\nbeta').toMatchInlineSnapshot(`
      alpha
      beta
    `)
  })

  test('supports generic numeric edge matchers', () => {
    expect([1, 2, 3]).toBeAllFinite()
    expect([1, Number.NaN, 3]).toContainNaN()
    expect([[0.25, 0.75], [0.1, 0.9]]).toHaveRowSumsCloseTo(1)
  })

  test('reports useful all-close mismatch details', () => {
    expect(() => {
      expect([1, 2, 3]).toBeAllClose([1, 9, 3], { rtol: 1e-3, atol: 1e-4 })
    }).toThrow('index 1')
    expect(() => {
      expect([1, 2, 3]).toBeAllClose([1, 9, 3], { rtol: 1e-3, atol: 1e-4 })
    }).toThrow('shape [3]')
    expect(() => {
      expect([1, 2, 3]).toBeAllClose([1, 9, 3], { rtol: 1e-3, atol: 1e-4 })
    }).toThrow('rtol=0.001')
    expect(() => {
      expect([1, 2, 3]).toBeAllClose([1, 9, 3], { rtol: 1e-3, atol: 1e-4 })
    }).toThrow('atol=0.0001')
  })

  test('reports shape mismatch details for all-close', () => {
    expect(() => {
      expect([[1, 2], [3, 4]]).toBeAllClose([1, 2, 3, 4])
    }).toThrow('matching shapes')
    expect(() => {
      expect([[1, 2], [3, 4]]).toBeAllClose([1, 2, 3, 4])
    }).toThrow('got shape [2,2]')
    expect(() => {
      expect([[1, 2], [3, 4]]).toBeAllClose([1, 2, 3, 4])
    }).toThrow('expected shape [4]')
  })

  test('reports useful string and instance matcher failures', () => {
    expect(() => {
      expect('abcdef').toMatch(/xyz/)
    }).toThrow('to match /xyz/')
    expect(() => {
      expect(123 as any).toMatch('23')
    }).toThrow('string actual value')
    expect(() => {
      expect({}).toBeInstanceOf(Array)
    }).toThrow('instance of Array')
    expect(() => {
      expect('alpha\nbeta').toMatchInlineSnapshot(`
        alpha
        gamma
      `)
    }).toThrow('--- actual ---')
    expect(() => {
      expect('alpha\nbeta').toMatchInlineSnapshot(`
        alpha
        gamma
      `)
    }).toThrow('--- expected ---')
  })
})
