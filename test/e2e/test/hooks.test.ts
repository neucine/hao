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

describe('nested hook order', () => {
  const order: string[] = []
  beforeEach(() => { order.push('outer setup') })
  afterEach(() => { order.push('outer first cleanup') })
  afterEach(() => { order.push('outer second cleanup') })
  describe('inner', () => {
    beforeEach(() => { order.push('inner setup') })
    afterEach(() => { order.push('inner first cleanup') })
    afterEach(() => { order.push('inner second cleanup') })
    test('runs setup outward and cleanup inward', () => {
      order.push('body')
    })
  })
  afterAll(() => {
    expect(order).toEqual([
      'outer setup', 'inner setup', 'body',
      'inner second cleanup', 'inner first cleanup',
      'outer second cleanup', 'outer first cleanup',
    ])
  })
})
