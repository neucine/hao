import { describe, test, expect, afterAll } from 'std:test'

describe('describe modifiers and each helpers', () => {
  const seen: string[] = []
  const skippedRows: string[] = []
  const described: string[] = []

  describe.skip('skipped suite', () => {
    test('does not run', () => {
      seen.push('skipped')
    })
  })

  describe.each([
    { label: 'cpu', value: 2 },
    { label: 'metal', value: 3 },
  ])('$label backend', ({ label, value }) => {
    described.push(label)

    test('multiplies by itself', () => {
      expect(value * value).toBe(label === 'cpu' ? 4 : 9)
    })
  })

  describe('only suite', () => {
    test.each([
      { a: 1, b: 2, expected: 3 },
      { a: 4, b: 5, expected: 9 },
    ])('adds $a + $b -> $expected', ({ a, b, expected }) => {
      seen.push(`${a}+${b}`)
      expect(a + b).toBe(expected)
    })
  })

  test.skip.each([
    ['x'],
    ['y'],
  ])('skipped row $0', ([value]) => {
    skippedRows.push(value)
  })

  test.each([
    ['z'],
  ])('row $0', ([value]) => {
    seen.push(value)
  })

  describe.skip.each([
    ['left'],
    ['right'],
  ])('skipped each suite $0', ([value]) => {
    test('does not run nested test', () => {
      seen.push(`nested:${value}`)
    })
  })

  test('normal sibling runs when no describe.only exists', () => {
    seen.push('normal')
  })

  afterAll(() => {
    expect(seen).toEqual(['1+2', '4+5', 'z', 'normal'])
    expect(skippedRows).toHaveLength(0)
    expect(described).toEqual(['cpu', 'metal'])
  })
})
