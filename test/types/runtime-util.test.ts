import runtime, { name, namespace } from 'std:runtime'
import util, { getInspectOptions, inspect, setInspectOptions } from 'std:util'

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

assertType<IsExact<typeof name, 'hao'>>()
assertType<IsExact<typeof namespace, 'std:'>>()
assertType<IsExact<typeof runtime.name, 'hao'>>()
assertType<IsExact<typeof runtime.namespace, 'std:'>>()

const text = inspect({ value: 42 }, { maxDepth: 2, maxArrayLength: 10, maxStringLength: 100 })
assertType<IsExact<typeof text, string>>()

setInspectOptions({ maxDepth: 3 })
setInspectOptions({})

const opts = getInspectOptions()
assertType<IsExact<typeof opts.maxDepth, number | undefined>>()

util.setInspectOptions({ maxArrayLength: 4 })
assertType<IsExact<ReturnType<typeof util.inspect>, string>>()

// @ts-expect-error - runtime name is literal
const badName: 'other' = name
// @ts-expect-error - inspect options only accept known keys
inspect('hao', { color: true })
// @ts-expect-error - maxDepth must be a number
setInspectOptions({ maxDepth: 'deep' })
