import { describe, test, expect, beforeEach, afterEach } from 'std:test'

let counter = 0

describe('basic', () => {
  beforeEach(() => {
    counter += 1
  })

  afterEach(() => {
    counter -= 1
  })

  test('toBe works', () => {
    expect(1 + 1).toBe(2)
  })

  test('toEqual works', () => {
    expect({ a: [1, 2] }).toEqual({ a: [1, 2] })
    expect(counter).toBe(1)
  })
})
