import { openNative, callNative, closeNative } from 'hao:ffi/c/native'

type HandlePolicy = {
  close?: string
}

type FunctionPolicy = {
  returns?: {
    kind?: 'handle'
    type?: string
    out?: string
  }
  buffers?: Record<string, {
    length: string
    element: 'u8' | 'i8' | 'u16' | 'i16' | 'u32' | 'i32' | 'u64' | 'i64' | 'f32' | 'f64'
    direction?: 'in' | 'out' | 'inout'
  }>
  errors?: {
    kind?: 'status' | 'null' | 'sentinel'
    ok?: number
    value?: number
    code?: string
    message?: string | {
      from: string
      arg?: string
    }
  }
}

type CDeclOptions = {
  handles?: Record<string, HandlePolicy>
  functions?: Record<string, FunctionPolicy>
  search?: {
    strategy?: 'runtime-default' | 'relative-first' | 'system-first'
    paths?: readonly string[]
  }
}

function unwrapArg(value: any): any {
  if (value && typeof value === 'object' && typeof value.__ptr === 'number') {
    return value.__ptr
  }
  if (typeof ArrayBuffer !== 'undefined') {
    if (value instanceof ArrayBuffer) {
      return new Uint8Array(value)
    }
    if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(value)) {
      return value
    }
  }
  return value
}

function makeHandle(callSymbol: (symbol: string, ...args: any[]) => any, ptr: number, typeName: string, handlePolicy?: HandlePolicy) {
  let closed = false
  const closeSymbol = handlePolicy?.close
  return {
    __ptr: ptr,
    __type: typeName,
    close() {
      if (closed) return
      closed = true
      if (closeSymbol) {
        callSymbol(closeSymbol, ptr)
      }
    },
  }
}

function cdecl(name: string, declarations: string, opts?: CDeclOptions) {
  if (typeof name !== 'string' || name.length === 0) {
    throw new Error('cdecl: invalid library name')
  }
  if (typeof declarations !== 'string' || declarations.length === 0) {
    throw new Error('cdecl: declarations must be a non-empty string')
  }

  const prepared = openNative(name, declarations, opts ?? null)
  const wrapped: Record<string, any> = {}
  const callSymbol = (symbol: string, ...args: any[]) => callNative(prepared.handle, symbol, args.map(unwrapArg))

  for (const symbol of prepared.symbols) {
    const fnPolicy = prepared.policies?.functions?.[symbol]
    wrapped[symbol] = (...args: any[]) => {
      const result = callSymbol(symbol, ...args)
      if (fnPolicy?.returns?.kind === 'handle' && typeof result === 'number' && result !== 0) {
        const typeName = fnPolicy.returns.type
        const handlePolicy = typeName ? prepared.policies?.handles?.[typeName] : undefined
        return makeHandle(callSymbol, result, typeName ?? 'handle', handlePolicy)
      }
      return result
    }
  }

  wrapped.close = () => closeNative(prepared.handle)
  return wrapped
}

const decl = cdecl

export { cdecl, decl }
export default { decl }
