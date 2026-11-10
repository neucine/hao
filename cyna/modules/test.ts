import fs from 'std:fs'
import processModule from 'std:process'
import {
  pushSuite,
  popSuite,
  registerTest,
  registerHook,
  getCurrentTestFilePath,
  getCurrentExecutablePath,
  beginCapture,
  endCapture,
} from 'std:test/native'
const core = {
  pushSuite,
  popSuite,
  registerTest,
  registerHook,
  getCurrentTestFilePath,
  getCurrentExecutablePath,
  beginCapture,
  endCapture,
}

  const restorers: Array<() => void> = []
  const allMocks: any[] = []
  const modeStack: Array<'normal' | 'skip' | 'only'> = ['normal']

  function fail(message: string): never {
    throw new Error(message)
  }

  function isPromiseLike(value: any): boolean {
    return value != null && typeof value.then === 'function'
  }

  function ensureCallback(name: string, fn: any): void {
    if (typeof fn !== 'function') fail(`${name} requires a function`)
    if (fn.length !== 0) fail(`${name} callback-style completion is unsupported; return a Promise instead`)
  }

  function deepEqual(a: any, b: any): boolean {
    if (Object.is(a, b)) return true
    if (typeof a !== typeof b) return false
    if (a == null || b == null) return false
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false
      for (let i = 0; i < a.length; i++) {
        if (!deepEqual(a[i], b[i])) return false
      }
      return true
    }
    if (typeof a === 'object') {
      const aKeys = Object.keys(a)
      const bKeys = Object.keys(b)
      if (aKeys.length !== bKeys.length) return false
      for (const key of aKeys) {
        if (!Object.prototype.hasOwnProperty.call(b, key)) return false
        if (!deepEqual(a[key], b[key])) return false
      }
      return true
    }
    return false
  }

  function formatValue(value: any): string {
    if (typeof value === 'string') return JSON.stringify(value)
    try {
      return JSON.stringify(value)
    } catch {
      return String(value)
    }
  }

  function flattenNested(value: any, out: number[]): number[] {
    if (Array.isArray(value)) {
      for (const item of value) flattenNested(item, out)
      return out
    }
    out.push(value)
    return out
  }

  function nestedShape(value: any): number[] {
    if (!Array.isArray(value)) return []
    if (value.length === 0) return [0]
    return [value.length, ...nestedShape(value[0])]
  }

  function isComputeValueLike(value: unknown): boolean {
    return !!value
      && typeof value === 'object'
      && Array.isArray((value as any).shape)
      && typeof (value as any).dtype === 'string'
  }

  function values(value: any): any {
    if ((isComputeValueLike(value) || !!value) && typeof value?.to_array === 'function') return value.to_array()
    return value
  }

  function numericView(value: any): { flat: number[]; shape: number[] | null } {
    const nestedValue = values(value)
    if (nestedValue !== value) {
      const shape = Array.isArray(value.shape) ? [...value.shape] : nestedShape(nestedValue)
      return { flat: flattenNested(nestedValue, []), shape }
    }
    if (Array.isArray(value)) {
      return { flat: flattenNested(value, []), shape: nestedShape(value) }
    }
    if (value && typeof value.length === 'number') {
      const flat: number[] = []
      for (let i = 0; i < value.length; i++) flat.push(value[i])
      return { flat, shape: [value.length] }
    }
    fail('toBeAllClose requires a compute tensor, array, or array-like value')
  }

  function numericRows(value: any): number[][] {
    const nested = values(value)
    if (!Array.isArray(nested)) fail('toHaveRowSumsCloseTo requires a rank-2 compute tensor or nested array')
    const rows: number[][] = []
    for (let i = 0; i < nested.length; i++) {
      const row = nested[i]
      if (!Array.isArray(row)) fail('toHaveRowSumsCloseTo requires a rank-2 compute tensor or nested array')
      const out: number[] = []
      for (let j = 0; j < row.length; j++) out.push(Number(row[j]))
      rows.push(out)
    }
    return rows
  }

  function comparable(value: any): any {
    const extracted = values(value)
    if (extracted !== value) return extracted
    if (Array.isArray(value)) return value.map((item) => comparable(item))
    if (value && typeof value === 'object') {
      const out: Record<string, any> = {}
      const keys = Object.keys(value)
      for (let i = 0; i < keys.length; i++) out[keys[i]] = comparable(value[keys[i]])
      return out
    }
    return value
  }

  function formatShape(shape: number[] | null): string {
    return shape == null ? 'unknown' : formatValue(shape)
  }

  function formatMockCalls(calls: any[][]): string {
    if (!Array.isArray(calls) || calls.length === 0) return '[]'
    return `[${calls.map((call) => formatValue(call)).join(', ')}]`
  }

  function normalizeInlineSnapshot(value: string): string {
    let normalized = value.replace(/\r\n/g, '\n')
    if (normalized.startsWith('\n')) normalized = normalized.slice(1)
    if (normalized.endsWith('\n')) normalized = normalized.slice(0, -1)

    // TODO: Add an opt-out for dedenting when leading indentation is semantically significant.
    const lines = normalized.split('\n')
    let indent: number | null = null
    for (const line of lines) {
      if (line.trim().length === 0) continue
      const match = line.match(/^\s*/)
      const current = match ? match[0].length : 0
      indent = indent == null ? current : Math.min(indent, current)
    }
    const dedented =
      indent == null || indent === 0
        ? lines
        : lines.map((line) => line.startsWith(' '.repeat(indent)) ? line.slice(indent) : line)

    while (dedented.length > 0 && dedented[0].trim().length === 0) dedented.shift()
    while (dedented.length > 0 && dedented[dedented.length - 1].trim().length === 0) dedented.pop()
    return dedented.join('\n')
  }

  function normalizeSnapshotText(value: string): string {
    return value.replace(/\r\n/g, '\n')
  }

  function dirname(path: string): string {
    const normalized = path.replace(/\\/g, '/')
    const idx = normalized.lastIndexOf('/')
    if (idx <= 0) return idx === 0 ? '/' : '.'
    return normalized.slice(0, idx)
  }

  function resolvePath(baseFile: string, target: string): string {
    if (typeof target !== 'string' || target.length === 0) fail('snapshot path must be a non-empty string')
    const normalizedTarget = target.replace(/\\/g, '/')
    const absolute = normalizedTarget.startsWith('/')
    const seed = absolute ? normalizedTarget : `${dirname(baseFile)}/${normalizedTarget}`
    const parts = seed.split('/')
    const out: string[] = []
    for (const part of parts) {
      if (part === '' || part === '.') continue
      if (part === '..') {
        if (out.length > 0) out.pop()
        continue
      }
      out.push(part)
    }
    return `${seed.startsWith('/') ? '/' : ''}${out.join('/')}`
  }

  function allClose(
    actual: any,
    expected: any,
    opts: { rtol?: number; atol?: number; equalNaN?: boolean } = {},
  ): { pass: boolean; index?: number; got?: number; expected?: number; shapeMismatch?: boolean } {
    const rtol = opts.rtol ?? 1e-5
    const atol = opts.atol ?? 1e-8
    const equalNaN = opts.equalNaN ?? false
    const a = numericView(actual)
    const b = numericView(expected)
    if (a.shape && b.shape && !deepEqual(a.shape, b.shape)) {
      return { pass: false, shapeMismatch: true }
    }
    if (a.flat.length !== b.flat.length) {
      return { pass: false, shapeMismatch: true }
    }
    for (let i = 0; i < a.flat.length; i++) {
      const got = a.flat[i]
      const exp = b.flat[i]
      if (Number.isNaN(got) || Number.isNaN(exp)) {
        if (equalNaN && Number.isNaN(got) && Number.isNaN(exp)) continue
        return { pass: false, index: i, got, expected: exp }
      }
      if (!Number.isFinite(got) || !Number.isFinite(exp)) {
        if (Object.is(got, exp)) continue
        return { pass: false, index: i, got, expected: exp }
      }
      if (Math.abs(got - exp) <= atol + rtol * Math.abs(exp)) continue
      return { pass: false, index: i, got, expected: exp }
    }
    return { pass: true }
  }

  function createMockFunction(impl?: Function, onRestore?: () => void): any {
    const originalImpl = impl ?? (() => undefined)
    let currentImpl = originalImpl
    const onceQueue: Function[] = []
    const calls: any[][] = []
    const results: any[] = []

    const mockFn = function(this: any, ...args: any[]) {
      calls.push(args)
      const nextImpl = onceQueue.length > 0 ? onceQueue.shift()! : currentImpl
      const result = nextImpl.apply(this, args)
      results.push(result)
      return result
    } as any

    mockFn.__haoMock = true
    mockFn.calls = calls
    Object.defineProperty(mockFn, 'callCount', {
      get() {
        return calls.length
      },
    })
    Object.defineProperty(mockFn, 'lastCall', {
      get() {
        return calls.length > 0 ? calls[calls.length - 1] : undefined
      },
    })
    Object.defineProperty(mockFn, 'results', {
      get() {
        return results
      },
    })

    function resetState(): void {
      calls.length = 0
      results.length = 0
      onceQueue.length = 0
      currentImpl = originalImpl
    }

    mockFn.mockImplementation = function(newImpl: Function) {
      currentImpl = newImpl
      return mockFn
    }
    mockFn.mockReturnValue = function(value: any) {
      currentImpl = () => value
      return mockFn
    }
    mockFn.mockReturnValueOnce = function(value: any) {
      onceQueue.push(() => value)
      return mockFn
    }
    mockFn.mockResolvedValue = function(value: any) {
      currentImpl = () => Promise.resolve(value)
      return mockFn
    }
    mockFn.mockResolvedValueOnce = function(value: any) {
      onceQueue.push(() => Promise.resolve(value))
      return mockFn
    }
    mockFn.mockRejectedValue = function(reason: any) {
      currentImpl = () => Promise.reject(reason)
      return mockFn
    }
    mockFn.mockRejectedValueOnce = function(reason: any) {
      onceQueue.push(() => Promise.reject(reason))
      return mockFn
    }
    mockFn.reset = function() {
      resetState()
      return mockFn
    }
    mockFn.cleanup = function() {
      resetState()
      if (onRestore) onRestore()
      return mockFn
    }
    if (onRestore) {
      mockFn.restore = function() {
        onRestore()
        return mockFn
      }
    }
    mockFn.__reset = resetState

    allMocks.push(mockFn)
    return mockFn
  }

  function findDescriptor(target: any, key: PropertyKey): { owner: any; descriptor: PropertyDescriptor } | null {
    let current = target
    while (current != null) {
      const descriptor = Object.getOwnPropertyDescriptor(current, key)
      if (descriptor) return { owner: current, descriptor }
      current = Object.getPrototypeOf(current)
    }
    return null
  }

  function replaceProperty(target: any, key: PropertyKey, value: any) {
    const found = findDescriptor(target, key)
    const hadOriginal = found !== null
    const originalDescriptor = found?.descriptor
    const restore = () => {
      if (hadOriginal && originalDescriptor) {
        Object.defineProperty(target, key, originalDescriptor)
      } else {
        delete target[key]
      }
    }
    Object.defineProperty(target, key, {
      configurable: true,
      enumerable: originalDescriptor?.enumerable ?? true,
      writable: true,
      value,
    })
    restorers.push(restore)
    return { restore }
  }

  function spy(target: any, key: PropertyKey) {
    const found = findDescriptor(target, key)
    if (!found) fail(`spy could not find property ${String(key)}`)
    if (found.descriptor.get || found.descriptor.set) {
      fail(`spy does not support getter/setter properties for ${String(key)} in this phase`)
    }
    if (typeof found.descriptor.value !== 'function') fail(`spy requires a method property for ${String(key)}`)
    const original = found.descriptor.value
    const restore = () => {
      Object.defineProperty(target, key, found.descriptor)
    }
    const mockFn = createMockFunction(function(this: any, ...args: any[]) {
      return original.apply(this, args)
    }, restore)
    Object.defineProperty(target, key, {
      configurable: true,
      enumerable: found.descriptor.enumerable ?? true,
      writable: true,
      value: mockFn,
    })
    restorers.push(restore)
    return mockFn
  }

  function spyOn(target: any, key: PropertyKey) {
    return spy(target, key)
  }

  function resetAll(): void {
    for (const mockFn of allMocks) {
      if (typeof mockFn.__reset === 'function') mockFn.__reset()
    }
  }

  function restoreAll(): void {
    while (restorers.length > 0) {
      const restore = restorers.pop()!
      restore()
    }
  }

  function cleanupAll(): void {
    restoreAll()
    resetAll()
  }

  core.registerHook('after_each', cleanupAll)

  function makeExpect(actual: any, negated = false): any {
    const assert = (pass: boolean, message: string) => {
      if (negated ? pass : !pass) fail(message)
    }
    return {
      toBe(expected: any) {
        assert(Object.is(actual, expected), `expected ${formatValue(actual)} to be ${formatValue(expected)}`)
      },
      toEqual(expected: any) {
        const normalizedActual = comparable(actual)
        const normalizedExpected = comparable(expected)
        assert(deepEqual(normalizedActual, normalizedExpected), `expected ${formatValue(normalizedActual)} to equal ${formatValue(normalizedExpected)}`)
      },
      toBeTruthy() {
        assert(!!actual, `expected ${formatValue(actual)} to be truthy`)
      },
      toBeFalsy() {
        assert(!actual, `expected ${formatValue(actual)} to be falsy`)
      },
      toBeDefined() {
        assert(actual !== undefined, 'expected value to be defined')
      },
      toBeUndefined() {
        assert(actual === undefined, `expected ${formatValue(actual)} to be undefined`)
      },
      toBeNull() {
        assert(actual === null, `expected ${formatValue(actual)} to be null`)
      },
      toBeInstanceOf(expected: any) {
        if (typeof expected !== 'function') fail('toBeInstanceOf requires a constructor function')
        const ctorName = expected?.name || '<anonymous>'
        assert(actual instanceof expected, `expected ${formatValue(actual)} to be instance of ${ctorName}`)
      },
      toHaveLength(expected: number) {
        const length = actual?.length
        if (typeof length !== 'number') fail('toHaveLength requires a .length property')
        assert(length === expected, `expected length ${length} to be ${expected}`)
      },
      toContain(expected: any) {
        if (typeof actual === 'string') {
          assert(actual.includes(String(expected)), `expected ${formatValue(actual)} to contain ${formatValue(expected)}`)
          return
        }
        if (Array.isArray(actual)) {
          let found = false
          for (const item of actual) {
            if (deepEqual(comparable(item), comparable(expected)) || Object.is(item, expected)) {
              found = true
              break
            }
          }
          assert(found, `expected ${formatValue(actual)} to contain ${formatValue(expected)}`)
          return
        }
        fail('toContain requires a string or array')
      },
      toMatch(expected: any) {
        if (typeof actual !== 'string') fail('toMatch requires a string actual value')
        if (typeof expected === 'string') {
          assert(actual.includes(expected), `expected ${formatValue(actual)} to match ${formatValue(expected)}`)
          return
        }
        if (expected instanceof RegExp) {
          assert(expected.test(actual), `expected ${formatValue(actual)} to match ${String(expected)}`)
          return
        }
        fail('toMatch requires a string or RegExp pattern')
      },
      toMatchInlineSnapshot(expected: any) {
        if (typeof actual !== 'string') fail('toMatchInlineSnapshot requires a string actual value')
        if (typeof expected !== 'string') fail('toMatchInlineSnapshot requires a string snapshot')
        const normalizedActual = normalizeInlineSnapshot(actual)
        const normalized = normalizeInlineSnapshot(expected)
        assert(
          normalizedActual === normalized,
          `expected string to match inline snapshot:\n--- actual ---\n${normalizedActual}\n--- expected ---\n${normalized}`,
        )
      },
      toMatchSnapshotFile(path: any) {
        if (typeof actual !== 'string') fail('toMatchSnapshotFile requires a string actual value')
        if (typeof path !== 'string') fail('toMatchSnapshotFile requires a string snapshot path')
        const currentFile = core.getCurrentTestFilePath()
        if (typeof currentFile !== 'string' || currentFile.length === 0) fail('current test file path is unavailable')
        const resolved = resolvePath(currentFile, path)
        const snapshot = fs.readFileSync(resolved)
        const normalizedActual = normalizeSnapshotText(actual)
        const normalizedExpected = normalizeSnapshotText(snapshot)
        assert(
          normalizedActual === normalizedExpected,
          `expected string to match snapshot file ${resolved}:\n--- actual ---\n${normalizedActual}\n--- expected ---\n${normalizedExpected}`,
        )
      },
      toHaveShape(expected: readonly number[]) {
        if (!actual || !Array.isArray(actual.shape)) fail('toHaveShape requires a compute tensor-like object with .shape')
        assert(deepEqual(actual.shape, [...expected]), `expected shape ${formatValue(actual.shape)} to equal ${formatValue(expected)}`)
      },
      toHaveDtype(expected: string) {
        if (!actual || typeof actual.dtype !== 'string') fail('toHaveDtype requires a compute tensor-like object with .dtype')
        assert(actual.dtype === expected, `expected dtype ${formatValue(actual.dtype)} to be ${formatValue(expected)}`)
      },
      toBeAllClose(expected: any, opts?: { rtol?: number; atol?: number; equalNaN?: boolean }) {
        const actualView = numericView(actual)
        const expectedView = numericView(expected)
        const result = allClose(actual, expected, opts)
        if (result.pass) {
          assert(true, '')
          return
        }
        const rtol = opts?.rtol ?? 1e-5
        const atol = opts?.atol ?? 1e-8
        if (result.shapeMismatch) {
          assert(
            false,
            `expected values to be all-close with matching shapes: got shape ${formatShape(actualView.shape)} expected shape ${formatShape(expectedView.shape)}`,
          )
          return
        }
        assert(
          false,
          `expected values to be all-close at index ${result.index} (shape ${formatShape(actualView.shape)}, rtol=${rtol}, atol=${atol}): got ${formatValue(result.got)} expected ${formatValue(result.expected)}`,
        )
      },
      toBeAllFinite() {
        const actualView = numericView(actual)
        for (let i = 0; i < actualView.flat.length; i++) {
          const value = actualView.flat[i]
          if (Number.isFinite(value)) continue
          assert(false, `expected values to be all finite, but index ${i} (shape ${formatShape(actualView.shape)}) was ${formatValue(value)}`)
          return
        }
        assert(true, '')
      },
      toContainNaN() {
        const actualView = numericView(actual)
        for (let i = 0; i < actualView.flat.length; i++) {
          if (Number.isNaN(actualView.flat[i])) {
            assert(true, '')
            return
          }
        }
        assert(false, `expected values to contain NaN, but none were found in shape ${formatShape(actualView.shape)}`)
      },
      toHaveRowSumsCloseTo(expected: number, tol = 1e-6) {
        const rows = numericRows(actual)
        for (let i = 0; i < rows.length; i++) {
          const sum = rows[i].reduce((acc, value) => acc + value, 0)
          if (Math.abs(sum - expected) < tol) continue
          assert(false, `expected row ${i} sum to be within ${tol} of ${expected}, got ${sum}`)
          return
        }
        assert(true, '')
      },
      toThrow(expected?: string) {
        if (typeof actual !== 'function') fail('toThrow requires a function')
        let threw = false
        let error: any = undefined
        try {
          const result = actual()
          if (isPromiseLike(result)) {
            fail('toThrow does not support Promise-returning functions in phase 1')
          }
        } catch (err) {
          threw = true
          error = err
        }
        assert(threw, 'expected function to throw')
        if (expected !== undefined) {
          const message = error && typeof error.message === 'string' ? error.message : String(error)
          assert(message.includes(expected), `expected error message ${formatValue(message)} to contain ${formatValue(expected)}`)
        }
      },
      toHaveBeenCalled() {
        if (!actual?.__haoMock) fail('toHaveBeenCalled requires a mock or spy')
        assert(actual.callCount > 0, 'expected mock to have been called')
      },
      toHaveBeenCalledTimes(expected: number) {
        if (!actual?.__haoMock) fail('toHaveBeenCalledTimes requires a mock or spy')
        assert(actual.callCount === expected, `expected mock to have been called ${expected} times, got ${actual.callCount}`)
      },
      toHaveBeenCalledWith(...expectedArgs: any[]) {
        if (!actual?.__haoMock) fail('toHaveBeenCalledWith requires a mock or spy')
        let found = false
        for (const call of actual.calls) {
          if (deepEqual(call, expectedArgs)) {
            found = true
            break
          }
        }
        assert(
          found,
          `expected mock to have been called with ${formatValue(expectedArgs)}, but calls were ${formatMockCalls(actual.calls)}`,
        )
      },
      toHaveLastReturnedWith(expected: any) {
        if (!actual?.__haoMock) fail('toHaveLastReturnedWith requires a mock or spy')
        if (!actual.results || actual.results.length === 0) fail('expected mock to have returned at least once')
        const last = actual.results[actual.results.length - 1]
        assert(
          deepEqual(comparable(last), comparable(expected)) || Object.is(last, expected),
          `expected last return value to equal ${formatValue(comparable(expected))}, got ${formatValue(comparable(last))} (all returns: ${formatValue(actual.results)})`,
        )
      },
      get not() {
        return makeExpect(actual, !negated)
      },
    }
  }

  function currentMode(): 'normal' | 'skip' | 'only' {
    return modeStack[modeStack.length - 1] ?? 'normal'
  }

  function combineMode(localMode: 'normal' | 'skip' | 'only'): 'normal' | 'skip' | 'only' {
    const parent = currentMode()
    if (parent === 'skip' || localMode === 'skip') return 'skip'
    if (parent === 'only' || localMode === 'only') return 'only'
    return 'normal'
  }

  function formatEachName(name: string, row: any): string {
    if (Array.isArray(row)) {
      return name.replace(/\$(\d+)/g, (_, index) => formatValue(row[Number(index)]))
    }
    if (row && typeof row === 'object') {
      return name.replace(/\$([a-zA-Z_][a-zA-Z0-9_]*)/g, (_, key) => formatValue(row[key]))
    }
    return name
  }

  function registerEach(mode: 'normal' | 'skip' | 'only', rows: any[]) {
    return function(name: string, fn: (row: any) => void | Promise<void>): void {
      if (!Array.isArray(rows)) fail('test.each requires an array of rows')
      if (typeof fn !== 'function') fail('test.each requires a callback')
      for (const row of rows) {
        registerTestWithMode(mode, formatEachName(String(name), row), () => fn(row))
      }
    }
  }

  function registerDescribeEach(mode: 'normal' | 'skip' | 'only', rows: any[]) {
    return function(name: string, fn: (row: any) => void): void {
      if (!Array.isArray(rows)) fail('describe.each requires an array of rows')
      if (typeof fn !== 'function') fail('describe.each requires a callback')
      for (const row of rows) {
        describeWithMode(mode, formatEachName(String(name), row), () => fn(row))
      }
    }
  }

  function describeWithMode(mode: 'normal' | 'skip' | 'only', name: string, fn: () => void): void {
    ensureCallback('describe', fn)
    core.pushSuite(String(name))
    modeStack.push(combineMode(mode))
    try {
      fn()
    } finally {
      modeStack.pop()
      core.popSuite()
    }
  }

  function describe(name: string, fn: () => void): void {
    describeWithMode('normal', name, fn)
  }

  function resolveConditionalMode(
    mode: 'normal' | 'skip' | 'only',
    arg0: any,
    arg1?: any,
  ): 'normal' | 'skip' | 'only' {
    if (typeof arg0 === 'function') {
      if (arg0.length !== 0) fail('conditional skip predicate must not accept arguments')
      return arg0() ? mode : 'normal'
    }
    return mode
  }

  describe.skip = function(arg0: any, arg1?: any): any {
    if (typeof arg0 === 'function' && arg1 === undefined) {
      return function(name: string, fn: () => void): void {
        describeWithMode(resolveConditionalMode('skip', arg0), name, fn)
      }
    }
    describeWithMode('skip', String(arg0), arg1)
  }

  describe.only = function(name: string, fn: () => void): void {
    describeWithMode('only', name, fn)
  }

  describe.each = function(rows: any[]) {
    return registerDescribeEach('normal', rows)
  }

  ;(describe.skip as any).each = function(rows: any[]) {
    return registerDescribeEach('skip', rows)
  }

  ;(describe.only as any).each = function(rows: any[]) {
    return registerDescribeEach('only', rows)
  }

  function registerTestWithMode(mode: 'normal' | 'skip' | 'only', name: string, fn: () => void | Promise<void>): void {
    ensureCallback('test', fn)
    core.registerTest(String(name), fn, combineMode(mode))
  }

  function test(name: string, fn: () => void | Promise<void>): void {
    registerTestWithMode('normal', name, fn)
  }

  test.skip = function(arg0: any, arg1?: any): any {
    if (typeof arg0 === 'function' && arg1 === undefined) {
      return function(name: string, fn: () => void | Promise<void>): void {
        registerTestWithMode(resolveConditionalMode('skip', arg0), name, fn)
      }
    }
    registerTestWithMode('skip', String(arg0), arg1)
  }

  test.only = function(name: string, fn: () => void | Promise<void>): void {
    registerTestWithMode('only', name, fn)
  }

  test.each = function(rows: any[]) {
    return registerEach('normal', rows)
  }

  ;(test.skip as any).each = function(rows: any[]) {
    return registerEach('skip', rows)
  }

  ;(test.only as any).each = function(rows: any[]) {
    return registerEach('only', rows)
  }

  const it = test

  function beforeAll(fn: () => void | Promise<void>): void {
    ensureCallback('beforeAll', fn)
    core.registerHook('before_all', fn)
  }

  function afterAll(fn: () => void | Promise<void>): void {
    ensureCallback('afterAll', fn)
    core.registerHook('after_all', fn)
  }

  function beforeEach(fn: () => void | Promise<void>): void {
    ensureCallback('beforeEach', fn)
    core.registerHook('before_each', fn)
  }

  function afterEach(fn: () => void | Promise<void>): void {
    ensureCallback('afterEach', fn)
    core.registerHook('after_each', fn)
  }

  const mock = Object.assign(
    function(impl?: Function) {
      return createMockFunction(impl)
    },
    {
      fn(impl?: Function) {
        return createMockFunction(impl)
      },
      resetAll,
      restoreAll,
      cleanupAll,
    },
  )

  async function captureOutput(
    input: string | (() => void | Promise<void>),
    opts: { target?: 'stdout' | 'stderr' | 'both' } = {},
  ): Promise<{ stdout: string; stderr: string; combined: string; exitCode: number | null; signal: number | null }> {
    if (typeof input === 'string') {
      const currentFile = core.getCurrentTestFilePath()
      if (typeof currentFile !== 'string' || currentFile.length === 0) fail('current test file path is unavailable')
      const exePath = core.getCurrentExecutablePath()
      if (typeof exePath !== 'string' || exePath.length === 0) fail('current hao executable path is unavailable')
      const resolved = resolvePath(currentFile, input)
      const result = await processModule.run({
        cmd: exePath,
        args: [resolved],
        check: false,
      })
      return {
        stdout: result.stdout,
        stderr: result.stderr,
        combined: result.stdout + result.stderr,
        exitCode: result.exitCode,
        signal: result.signal,
      }
    }

    ensureCallback('captureOutput', input)
    core.beginCapture(opts.target ?? 'stdout')
    try {
      const result = input()
      if (isPromiseLike(result)) await result
      const captured = core.endCapture()
      return { ...captured, exitCode: 0, signal: null }
    } catch (err) {
      try {
        core.endCapture()
      } catch {}
      throw err
    }
  }

function expect(actual: any) {
  return makeExpect(actual, false)
}

export {
  describe,
  test,
  it,
  expect,
  mock,
  spy,
  spyOn,
  replaceProperty,
  beforeAll,
  afterAll,
  beforeEach,
  afterEach,
  captureOutput,
  values,
}

export default {
  describe,
  test,
  it,
  expect,
  mock,
  spy,
  spyOn,
  replaceProperty,
  beforeAll,
  afterAll,
  beforeEach,
  afterEach,
  captureOutput,
  values,
}
