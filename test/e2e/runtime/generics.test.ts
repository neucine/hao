import { describe, test, expect } from 'hao:test'

interface Container<T> {
  value: T
  label: string
}

function wrap<T>(value: T, label: string): Container<T> {
  return { value, label }
}

function unwrap<T>(container: Container<T>): T {
  return container.value
}

enum Color {
  Red = 'red',
  Green = 'green',
  Blue = 'blue',
}

describe('runtime generics', () => {
  test('preserves generic container values', () => {
    const boxed = wrap<number[]>([1, 2, 3], 'numbers')
    expect(boxed.label).toBe('numbers')
    expect(unwrap(boxed)).toEqual([1, 2, 3])
  })

  test('preserves enum values through generic wrappers', () => {
    const colorBox = wrap<Color>(Color.Green, 'favorite color')
    expect(colorBox.label).toBe('favorite color')
    expect(unwrap(colorBox)).toBe(Color.Green)
  })
})
