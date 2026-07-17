import testModule, {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  captureOutput,
  describe,
  expect,
  it,
  mock,
  replaceProperty,
  spy,
  spyOn,
  test,
} from 'std:test'

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

describe('types', () => {
  beforeAll(() => {})
  beforeEach(async () => {})
  afterEach(() => {})
  afterAll(async () => {})

  test('matcher surface', () => {
    expect(1).toBe(1)
    expect([1, 2]).toHaveLength(2)
    expect(() => {
      throw new Error('ok')
    }).toThrow('ok')
    expect(1).not.toBe(2)
    testModule.expect('hao').toMatch(/hao/)
  })

  it.each([
    [1, 2],
    [3, 4],
  ])('row $0', (row) => {
    assertType<IsExact<typeof row, number[]>>()
  })
})

describe.skip(() => true)('skipped', () => {})
describe.only.each([{ name: 'hao' }])('$name', (row) => {
  assertType<IsExact<typeof row, { name: string }>>()
})

const fn = mock<[number], string>((value) => String(value))
const out = fn(42)
assertType<IsExact<typeof out, string>>()
assertType<IsExact<typeof fn.calls, [number][]>>()
fn.mockReturnValue('ok').mockImplementation((value) => `${value}`)
mock.resetAll()

const target = {
  value: 1,
  inc(delta: number) {
    return this.value + delta
  },
}
const watched = spy(target, 'inc')
const watchedAlias = spyOn(target, 'inc')
watched.restore()
watchedAlias.cleanup()
replaceProperty(target, 'value', 2).restore()

const captured = await captureOutput(() => {
  console.log('hello')
}, { target: 'both' })
assertType<IsExact<typeof captured.stdout, string>>()
await captureOutput('printf hello')

// @ts-expect-error - test callback does not receive arguments
test('bad callback', (value: string) => {})
// @ts-expect-error - toBe expects the same type as actual
expect(1).toBe('1')
// @ts-expect-error - mock implementation argument type is preserved
fn('bad')
// @ts-expect-error - replaceProperty value must match property type
replaceProperty(target, 'value', 'bad')
// @ts-expect-error - capture target is a fixed string union
captureOutput(() => {}, { target: 'stdin' })
