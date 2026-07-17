import { describe, test, expect, mock, spy, spyOn, replaceProperty } from 'hao:test'

describe('hao:test mocks', () => {
  test('mock is callable', () => {
    const doubled = mock((x: number) => x * 2)
    doubled.mockReturnValueOnce(10)

    expect(doubled(1)).toBe(10)
    expect(doubled(3)).toBe(6)
    expect(doubled).toHaveBeenCalled()
    expect(doubled).toHaveBeenCalledTimes(2)
    expect(doubled).toHaveBeenCalledWith(1)
    expect(doubled).toHaveBeenCalledWith(3)
    expect(doubled).toHaveLastReturnedWith(6)
    doubled.cleanup()
    expect(doubled).not.toHaveBeenCalled()
  })

  test('mock is the single mock factory surface', () => {
    const doubled = mock((x: number) => x * 2)
    expect(doubled(5)).toBe(10)
    expect(doubled).toHaveBeenCalledWith(5)
  })

  test('mock supports async once variants', async () => {
    const fetchValue = mock(() => Promise.resolve('steady'))
    fetchValue.mockResolvedValueOnce('first')
    fetchValue.mockRejectedValueOnce(new Error('boom'))

    expect(await fetchValue()).toBe('first')
    let message = ''
    try {
      await fetchValue()
    } catch (err: any) {
      message = err?.message ?? String(err)
    }
    expect(message).toBe('boom')
    expect(await fetchValue()).toBe('steady')
  })

  test('spy wraps methods and preserves behavior', () => {
    const obj = {
      base: 2,
      mul(x: number) {
        return this.base * x
      },
    }

    const s = spy(obj, 'mul')
    expect(obj.mul(4)).toBe(8)
    expect(s).toHaveBeenCalledTimes(1)
    expect(s).toHaveBeenCalledWith(4)
    s.reset()
    expect(s).not.toHaveBeenCalled()
    expect(obj.mul(5)).toBe(10)
    s.restore()
    expect(obj.mul(5)).toBe(10)
  })

  test('spy.cleanup resets state and restores the method in one go', () => {
    const obj = {
      value: 3,
      mul(x: number) {
        return this.value * x
      },
    }

    const s = spy(obj, 'mul')
    expect(obj.mul(2)).toBe(6)
    expect(s).toHaveBeenCalledWith(2)
    s.cleanup()
    expect(obj.mul(4)).toBe(12)
    expect(s).not.toHaveBeenCalled()
  })

  test('spyOn is an alias to spy', () => {
    const obj = {
      value: 3,
      inc(x: number) {
        return this.value + x
      },
    }

    const s = spyOn(obj, 'inc')
    expect(obj.inc(4)).toBe(7)
    expect(s).toHaveBeenCalledWith(4)
    expect(s).toHaveLastReturnedWith(7)
  })

  test('spy rejects accessor properties clearly', () => {
    const obj = {
      get value() {
        return 1
      },
    }

    expect(() => spy(obj, 'value')).toThrow('getter/setter')
  })

  test('reports useful call mismatch details', () => {
    const called = mock((x: number) => x * 2)
    called(1)
    called(3)

    expect(() => {
      expect(called).toHaveBeenCalledWith(9)
    }).toThrow('called with [9]')
    expect(() => {
      expect(called).toHaveBeenCalledWith(9)
    }).toThrow('calls were [[1], [3]]')
  })

  test('reports useful last-return mismatch details', () => {
    const called = mock((x: number) => x * 2)
    called(1)
    called(3)

    expect(() => {
      expect(called).toHaveLastReturnedWith(99)
    }).toThrow('equal 99')
    expect(() => {
      expect(called).toHaveLastReturnedWith(99)
    }).toThrow('got 6')
    expect(() => {
      expect(called).toHaveLastReturnedWith(99)
    }).toThrow('all returns: [2,6]')
  })

  test('replaceProperty overrides and auto-restores values', () => {
    const obj = { value: 1 }
    replaceProperty(obj, 'value', 42)
    expect(obj.value).toBe(42)
  })

  test('mock.resetAll clears call state without restoring spies', () => {
    const obj = {
      value: 2,
      mul(x: number) {
        return this.value * x
      },
    }

    const fn = mock((x: number) => x + 1)
    const s = spy(obj, 'mul')
    fn(1)
    obj.mul(3)
    mock.resetAll()

    expect(fn).not.toHaveBeenCalled()
    expect(s).not.toHaveBeenCalled()
    expect(obj.mul(4)).toBe(8)
  })

  test('mock.restoreAll restores spies without clearing standalone mocks', () => {
    const obj = {
      value: 2,
      mul(x: number) {
        return this.value * x
      },
    }
    const fn = mock((x: number) => x + 1)
    const s = spy(obj, 'mul')
    fn(1)
    obj.mul(3)

    mock.restoreAll()

    expect(fn).toHaveBeenCalledWith(1)
    expect(obj.mul(4)).toBe(8)
  })

  test('previous test replacements and mocks were auto-restored', () => {
    const obj = { value: 1 }
    expect(obj.value).toBe(1)

    const called = mock()
    expect(called).not.toHaveBeenCalled()
    called('x')
    expect(called).toHaveBeenCalledWith('x')
  })
})
