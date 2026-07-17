import { describe, test, expect } from 'std:test'

describe('runtime hello', () => {
  test('supports basic string values', () => {
    const message: string = 'Hello from Hao!'
    expect(message).toBe('Hello from Hao!')
  })
})
