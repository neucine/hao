type Parameter = { name: string; type: string };
type FunctionSpec = { name: string; params: Parameter[]; returns: string };
type Prepared = { symbols: string[]; functions: FunctionSpec[]; policies: any };
const libraries = new Map<number, Prepared>();

function ffiType(type: string, returning = false): string {
  const normalized = type.replace(/\b(const|volatile|restrict|signed)\b/g, '').replace(/\s+/g, ' ').trim();
  if (/\*/.test(normalized)) {
    if (/\bchar\s*\*/.test(normalized)) return returning ? 'cstring' : 'cstring';
    return 'ptr';
  }
  const mapping: Record<string, string> = {
    void: 'void', bool: 'bool', _Bool: 'bool', char: 'i8',
    'unsigned char': 'u8', short: 'i16', 'short int': 'i16',
    'unsigned short': 'u16', 'unsigned short int': 'u16',
    int: 'i32', 'unsigned int': 'u32', unsigned: 'u32',
    long: 'i64', 'long int': 'i64', 'unsigned long': 'u64',
    'long long': 'i64', 'unsigned long long': 'u64',
    size_t: 'u64', ssize_t: 'i64', float: 'f32', double: 'f64',
    int8_t: 'i8', int16_t: 'i16', int32_t: 'i32', int64_t: 'i64',
    uint8_t: 'u8', uint16_t: 'u16', uint32_t: 'u32', uint64_t: 'u64',
  };
  const result = mapping[normalized];
  if (!result) throw Error(`unsupported C type: ${type}`);
  return result;
}
function parse(declarations: string, opts: any): Prepared {
  if (typeof declarations !== 'string' || !declarations.trim()) throw Error('cdecl: declarations must be a non-empty string');
  if (/#|\.\.\./.test(declarations)) throw Error('unsupported C declarations');
  if (opts?.search) throw Error('C library search policies are not ported yet');
  const functions: FunctionSpec[] = [];
  for (const raw of declarations.split(';')) {
    const statement = raw.trim();
    if (!statement) continue;
    if (statement.startsWith('typedef ')) throw Error('typedef declarations are not ported yet');
    const match = /^(.+?)\s+([A-Za-z_]\w*)\s*\(([^()]*)\)$/.exec(statement);
    if (!match) throw Error(`invalid C declaration: ${statement}`);
    const params: Parameter[] = [];
    if (match[3].trim() && match[3].trim() !== 'void') {
      for (const rawParam of match[3].split(',')) {
        const param = /^(.+?[\s*])([A-Za-z_]\w*)$/.exec(rawParam.trim());
        if (!param) throw Error(`invalid C parameter: ${rawParam}`);
        params.push({ name: param[2], type: ffiType(param[1]) });
      }
    }
    functions.push({ name: match[2], params, returns: ffiType(match[1], true) });
  }
  if (!functions.length) throw Error('cdecl requires at least one function');
  for (const name of Object.keys(opts?.functions ?? {})) {
    if (!functions.some(item => item.name === name)) throw Error(`unknown C function policy: ${name}`);
    const policy = opts.functions[name];
    if (policy?.returns?.out) throw Error('C out parameters are not ported yet');
    if (policy?.errors?.message && typeof policy.errors.message !== 'string') {
      throw Error('C error message helpers are not ported yet');
    }
  }
  return { symbols: functions.map(item => item.name), functions, policies: opts ?? {} };
}
function bytesPerElement(name: string): number {
  return ['u8', 'i8'].includes(name) ? 1 : ['u16', 'i16'].includes(name) ? 2 :
    ['u32', 'i32', 'f32'].includes(name) ? 4 : 8;
}
function backingLength(value: any): number {
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return value.byteLength;
  throw Error('buffer argument must be an ArrayBuffer or typed array');
}
export function prepareNative(name: string, declarations: string, opts?: any): Prepared {
  if (typeof name !== 'string' || !name) throw Error('cdecl: invalid library name');
  return parse(declarations, opts);
}
export function openNative(name: string, declarations: string, opts?: any): { handle: number; symbols: string[]; policies: any } {
  const prepared = prepareNative(name, declarations, opts);
  let handle: number;
  try { handle = globalThis.__hao_ffi_open(name); }
  catch (_) { throw new RuntimeError('io_error', 'openNative: failed to open library'); }
  try {
    for (const fn of prepared.functions) {
      const buffers = prepared.policies?.functions?.[fn.name]?.buffers ?? {};
      globalThis.__hao_ffi_bind(handle, fn.name,
        fn.params.map(param => buffers[param.name] ? 'ptr' : param.type), fn.returns);
    }
  } catch (error) {
    globalThis.__hao_ffi_close(handle);
    throw error;
  }
  libraries.set(handle, prepared);
  return { handle, symbols: prepared.symbols, policies: prepared.policies };
}
export function callNative(handle: number, symbol: string, args: any[]): unknown {
  const prepared = libraries.get(handle);
  if (!prepared) throw Error('FFI: invalid library handle');
  const fn = prepared.functions.find(item => item.name === symbol);
  if (!fn) throw Error('FFI: unknown symbol');
  const policy = prepared.policies?.functions?.[symbol];
  const buffers = policy?.buffers ?? {};
  const lengths = new Map<string, number>();
  const visible = fn.params.filter(param => !Object.values(buffers).some((buffer: any) => buffer.length === param.name));
  if (args.length !== visible.length) throw Error('FFI: wrong number of arguments');
  let input = 0;
  const values = new Map<string, any>();
  for (const param of visible) {
    const value = args[input++];
    values.set(param.name, value);
    const buffer = buffers[param.name];
    if (buffer) {
      const length = backingLength(value) / bytesPerElement(buffer.element);
      if (!Number.isInteger(length)) throw Error('buffer length is not aligned to its element type');
      const existing = lengths.get(buffer.length);
      if (existing !== undefined && existing !== length) throw Error('buffer lengths disagree');
      lengths.set(buffer.length, length);
    }
  }
  for (const [name, length] of lengths) values.set(name, length);
  const raw = globalThis.__hao_ffi_call(handle, symbol, fn.params.map(param => values.get(param.name)));
  const errors = policy?.errors;
  if (errors?.kind === 'status' && raw !== (errors.ok ?? 0) ||
      errors?.kind === 'null' && (raw === null || raw === 0) ||
      errors?.kind === 'sentinel' && raw === errors.value) {
    const error: any = new Error(typeof errors.message === 'string' ? errors.message : `${symbol} failed`);
    if (errors.code) error.code = errors.code;
    throw error;
  }
  return raw;
}
export function closeNative(handle: number): void {
  libraries.delete(handle);
  globalThis.__hao_ffi_close(handle);
}
