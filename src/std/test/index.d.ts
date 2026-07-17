// Runtime API exposed by the public test module (hao:test).
// This is the internal source of truth for what test/index.ts returns to JS.
// User-facing types can be published by language bindings.

interface TestCaptureOptions {
  target?: "stdout" | "stderr" | "both"
}

interface TestCapturedOutput {
  stdout: string
  stderr: string
  combined: string
  exitCode: number | null
  signal: number | null
}

interface TestAllCloseOptions {
  rtol?: number
  atol?: number
  equalNaN?: boolean
}

interface TestMatcher<T> {
  toBe(expected: T): void
  toEqual(expected: unknown): void
  toBeTruthy(): void
  toBeFalsy(): void
  toBeDefined(): void
  toBeUndefined(): void
  toBeNull(): void
  toBeInstanceOf(expected: new (...args: any[]) => unknown): void
  toHaveLength(expected: number): void
  toContain(expected: unknown): void
  toMatch(expected: string | RegExp): void
  toMatchInlineSnapshot(expected: string): void
  toMatchSnapshotFile(path: string): void
  toHaveShape(expected: readonly number[]): void
  toHaveDtype(expected: string): void
  toBeAllClose(expected: unknown, opts?: TestAllCloseOptions): void
  toBeAllFinite(): void
  toContainNaN(): void
  toHaveRowSumsCloseTo(expected: number, tol?: number): void
  toThrow(expected?: string): void
  toHaveBeenCalled(): void
  toHaveBeenCalledTimes(expected: number): void
  toHaveBeenCalledWith(...expectedArgs: unknown[]): void
  toHaveLastReturnedWith(expected: unknown): void
  readonly not: TestMatcher<T>
}

interface TestMockFunction<TArgs extends unknown[] = unknown[], TResult = unknown> {
  (...args: TArgs): TResult
  readonly calls: TArgs[]
  readonly callCount: number
  readonly lastCall: TArgs | undefined
  readonly results: TResult[]
  mockImplementation(fn: (...args: TArgs) => TResult): this
  mockReturnValue(value: TResult): this
  mockReturnValueOnce(value: TResult): this
  mockResolvedValue(value: unknown): this
  mockResolvedValueOnce(value: unknown): this
  mockRejectedValue(reason: unknown): this
  mockRejectedValueOnce(reason: unknown): this
  reset(): this
  cleanup(): this
}

interface TestSpyFunction<TArgs extends unknown[] = unknown[], TResult = unknown> extends TestMockFunction<TArgs, TResult> {
  restore(): this
}

interface TestMockFactory {
  <TArgs extends unknown[] = unknown[], TResult = unknown>(impl?: (...args: TArgs) => TResult): TestMockFunction<TArgs, TResult>
}

interface TestMockModule extends TestMockFactory {
  fn<TArgs extends unknown[] = unknown[], TResult = unknown>(impl?: (...args: TArgs) => TResult): TestMockFunction<TArgs, TResult>
  resetAll(): void
  restoreAll(): void
  cleanupAll(): void
}

interface TestPropertyReplacement {
  restore(): void
}

interface TestDescribeRegistrar {
  (name: string, fn: () => void): void
  skip: TestDescribeModifier
  only: TestDescribeModifier
  each<Row>(rows: Row[]): TestDescribeEachRegistrar<Row>
}

// Name templates support `$0`, `$1`, ... for array rows and `$field` for
// top-level object properties. Nested paths like `$0.field` are not supported.
interface TestEachRegistrar<Row> {
  (name: string, fn: (row: Row) => void | Promise<void>): void
}

// Name templates support `$0`, `$1`, ... for array rows and `$field` for
// top-level object properties. Nested paths like `$0.field` are not supported.
interface TestDescribeEachRegistrar<Row> {
  (name: string, fn: (row: Row) => void): void
}

interface TestDescribeModifier {
  (name: string, fn: () => void): void
  (predicate: () => boolean): (name: string, fn: () => void) => void
  each<Row>(rows: Row[]): TestDescribeEachRegistrar<Row>
}

interface TestModifier {
  (name: string, fn: () => void | Promise<void>): void
  (predicate: () => boolean): (name: string, fn: () => void | Promise<void>) => void
  each<Row>(rows: Row[]): TestEachRegistrar<Row>
}

interface TestRegistrar extends TestModifier {
  (name: string, fn: () => void | Promise<void>): void
  skip: TestModifier
  only: TestModifier
  each<Row>(rows: Row[]): TestEachRegistrar<Row>
}

interface TestModule {
  describe: TestDescribeRegistrar
  test: TestRegistrar
  it: TestRegistrar
  expect<T>(actual: T): TestMatcher<T>
  values(actual: unknown): unknown
  mock: TestMockModule
  spy<T extends object, K extends keyof T>(target: T, key: K): TestSpyFunction
  spyOn<T extends object, K extends keyof T>(target: T, key: K): TestSpyFunction
  replaceProperty<T extends object, K extends keyof T>(target: T, key: K, value: T[K]): TestPropertyReplacement
  beforeAll(fn: () => void | Promise<void>): void
  afterAll(fn: () => void | Promise<void>): void
  beforeEach(fn: () => void | Promise<void>): void
  afterEach(fn: () => void | Promise<void>): void
  captureOutput(fn: () => void | Promise<void>, opts?: TestCaptureOptions): Promise<TestCapturedOutput>
  captureOutput(path: string): Promise<TestCapturedOutput>
}

declare module "hao:test" {
  export const describe: TestDescribeRegistrar
  export const test: TestRegistrar
  export const it: TestRegistrar
  export function expect<T>(actual: T): TestMatcher<T>
  export const mock: TestMockModule
  export function spy<T extends object, K extends keyof T>(target: T, key: K): TestSpyFunction
  export function spyOn<T extends object, K extends keyof T>(target: T, key: K): TestSpyFunction
  export function replaceProperty<T extends object, K extends keyof T>(target: T, key: K, value: T[K]): TestPropertyReplacement
  export function beforeAll(fn: () => void | Promise<void>): void
  export function afterAll(fn: () => void | Promise<void>): void
  export function beforeEach(fn: () => void | Promise<void>): void
  export function afterEach(fn: () => void | Promise<void>): void
  export function captureOutput(fn: () => void | Promise<void>, opts?: TestCaptureOptions): Promise<TestCapturedOutput>
  export function captureOutput(path: string): Promise<TestCapturedOutput>
  export function values(actual: unknown): unknown

  const testModule: TestModule
  export default testModule
}
