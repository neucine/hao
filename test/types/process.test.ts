import processModule, { getEnv, run } from 'hao:process'

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

const value = getEnv('PATH')
assertType<IsExact<typeof value, string | null>>()

const result = await run({
  cmd: 'printf',
  args: ['hello'],
  cwd: '.',
  maxOutputBytes: 1024,
  check: false,
})
assertType<IsExact<typeof result.stdout, string>>()
assertType<IsExact<typeof result.stderr, string>>()
assertType<IsExact<typeof result.exitCode, number | null>>()
assertType<IsExact<ReturnType<typeof result.json>, unknown>>()

const parsed = await run('printf {"ok":true}').json<{ ok: boolean }>()
assertType<IsExact<typeof parsed, { ok: boolean }>>()

const text = await processModule.run('printf hello').text()
assertType<IsExact<typeof text, string>>()

// @ts-expect-error - env name must be a string
getEnv(123)
// @ts-expect-error - cmd is required in option object
run({ args: ['missing-cmd'] })
// @ts-expect-error - args must be strings
run({ cmd: 'printf', args: [1] })
// @ts-expect-error - run expects a command string or option object
run(42)
