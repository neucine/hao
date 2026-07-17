import { describe, test, expect, beforeAll, beforeEach, afterEach, afterAll } from 'std:test'

const events: string[] = []

describe('hooks', () => {
  beforeAll(() => {
    events.push('beforeAll')
  })

  beforeEach(() => {
    events.push('beforeEach')
  })

  afterEach(() => {
    events.push('afterEach')
  })

  afterAll(() => {
    events.push('afterAll')
    expect(events).toEqual([
      'beforeAll',
      'beforeEach',
      'body',
      'afterEach',
      'afterAll',
    ])
  })

  test('runs in order', () => {
    events.push('body')
    expect(events).toEqual(['beforeAll', 'beforeEach', 'body'])
  })
})
