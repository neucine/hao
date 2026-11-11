type Descriptor = Record<string, { args: string[]; returns: string }>;
const types = new Set(['void', 'bool', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32', 'f64', 'ptr', 'cstring', 'buffer']);

export function openNative(name: string, descriptor: Descriptor): number {
  if (arguments.length < 2) throw new TypeError('dlopen requires 2 arguments: library name and descriptor');
  if (typeof name === 'symbol') throw new TypeError('dlopen: invalid library name');
  try { name = String(name); }
  catch (_) { throw new TypeError('dlopen: invalid library name'); }
  if (!descriptor || typeof descriptor !== 'object') {
    throw new TypeError('dlopen: descriptor must be an object');
  }
  const handle = globalThis.__hao_ffi_open(name);
  try {
    for (const [symbol, spec] of Object.entries(descriptor)) {
      if (!spec || typeof spec !== 'object') throw new TypeError('dlopen: invalid descriptor');
      let args: string[];
      try { args = spec.args; }
      catch (_) { throw new TypeError('dlopen: descriptor args must be an array'); }
      if (!globalThis.__hao_ffi_isArray(args)) throw new TypeError('dlopen: descriptor args must be an array');
      let returns: string;
      try { returns = spec.returns; }
      catch (_) { throw new TypeError('dlopen: invalid return type'); }
      if (!types.has(returns)) throw new TypeError('dlopen: invalid return type');
      for (let index = 0; index < args.length; index++) {
        let type: string;
        try { type = args[index]; }
        catch (_) { throw new TypeError('dlopen: invalid argument type'); }
        if (!types.has(type)) throw new TypeError('dlopen: invalid argument type');
      }
      globalThis.__hao_ffi_bind(handle, symbol, args, returns);
    }
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
