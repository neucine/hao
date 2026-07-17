import { describe, test, expect } from 'hao:test'

describe('runtime timer', () => {
  test('runs timers in expected order and cancels cleared ones', async () => {
    const events: string[] = []

    events.push('sync start')

    setTimeout(() => {
      events.push('timer 1')
    }, 0)

    const cancelled = setTimeout(() => {
      events.push('cancelled')
    }, 0)
    clearTimeout(cancelled)

    setTimeout(() => {
      events.push('timer 2')
    }, 1)

    events.push('sync end')

    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), 5)
    })

    expect(events).toEqual(['sync start', 'sync end', 'timer 1', 'timer 2'])
    expect(events).not.toContain('cancelled')
  })
})
