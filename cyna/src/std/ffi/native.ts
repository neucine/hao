type Descriptor = Record<string, { args: string[]; returns: string }>;
const types = new Set(['void', 'bool', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32', 'f64', 'ptr', 'cstring', 'buffer']);

export function openNative(name: string, descriptor: Descriptor): number {
  if (arguments.length < 2) throw new TypeError('dlopen requires 2 arguments: library name and descriptor');
  if (typeof name !== 'string' || !name) throw Error('dlopen: invalid library name');
  if (!descriptor || typeof descriptor !== 'object' || Array.isArray(descriptor)) {
    throw Error('dlopen: descriptor must be an object');
  }
  const entries = Object.entries(descriptor);
  for (const [symbol, spec] of entries) {
    if (!symbol || !spec || !Array.isArray(spec.args) || spec.args.length > 8 ||
        spec.args.some(type => !types.has(type) || type === 'void') || !types.has(spec.returns)) {
      throw Error(`dlopen: invalid descriptor for ${symbol}`);
    }
  }
  const handle = globalThis.__hao_ffi_open(name);
  try {
    for (const [symbol, spec] of entries) globalThis.__hao_ffi_bind(handle, symbol, spec.args, spec.returns);
    return handle;
  } catch (error) {
    globalThis.__hao_ffi_close(handle);
    throw error;
  }
}
export function callNative(handle: number, symbol: string, args: unknown[]): unknown {
  if (arguments.length < 3) throw new TypeError('ffi.callNative requires handle, symbol, and args');
  return globalThis.__hao_ffi_call(handle, symbol, args);
}
export function closeNative(handle: number): void {
  if (arguments.length < 1) throw new TypeError('ffi.closeNative requires a handle');
  globalThis.__hao_ffi_close(handle);
}
