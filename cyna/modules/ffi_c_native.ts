type PodField = { name: string; type: string; offset: number; pod?: string };
type PodSpec = { fields: PodField[]; size: number; alignment: number };
type Parameter = { name: string; type: string; pod?: string };
type FunctionSpec = { name: string; params: Parameter[]; returns: string };
type Prepared = { symbols: string[]; functions: FunctionSpec[]; policies: any; pods: Record<string, PodSpec> };
const libraries = new Map<number, Prepared>();

function scalarLayout(type: string): { size: number; alignment: number } {
  if (['bool', 'i8', 'u8'].includes(type)) return { size: 1, alignment: 1 };
  if (['i16', 'u16'].includes(type)) return { size: 2, alignment: 2 };
  if (['i32', 'u32', 'f32'].includes(type)) return { size: 4, alignment: 4 };
  if (['i64', 'u64', 'f64'].includes(type)) return { size: 8, alignment: 8 };
  throw Error(`unsupported POD field type: ${type}`);
}
function podSpec(body: string, resolve: (name: string) => PodSpec | null): PodSpec {
  const fields: PodField[] = [];
  let size = 0, alignment = 1;
  for (const source of body.split(';')) {
    const declaration = source.trim();
    if (!declaration) continue;
    const match = /^(.+?\s+)([A-Za-z_]\w*)$/.exec(declaration);
    if (!match) throw Error(`invalid POD field: ${declaration}`);
    const name = match[1].trim();
    const nested = resolve(name);
    const type = nested ? 'pod' : ffiType(name);
    const layout = nested ?? scalarLayout(type);
    size = Math.ceil(size / layout.alignment) * layout.alignment;
    fields.push({ name: match[2], type, offset: size, pod: nested ? name : undefined });
    size += layout.size;
    alignment = Math.max(alignment, layout.alignment);
  }
  if (!fields.length) throw Error('empty POD struct');
  return { fields, size: Math.ceil(size / alignment) * alignment, alignment };
}

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
  if (opts?.search != null) {
    const search = opts.search;
    if (typeof search !== 'object' || Array.isArray(search)) throw Error('invalid C library search policy');
    if (search.strategy != null && !['runtime-default', 'relative-first', 'system-first'].includes(search.strategy)) {
      throw Error('invalid C library search strategy');
    }
    if (search.paths != null && (!Array.isArray(search.paths) ||
        search.paths.some((path: unknown) => typeof path !== 'string' || !path))) {
      throw Error('invalid C library search paths');
    }
  }
  const functions: FunctionSpec[] = [];
  const opaqueTypes = new Set<string>();
  const pods: Record<string, PodSpec> = {};
  const podBodies: Record<string, string> = {};
  const withoutPods = declarations.replace(/typedef\s+struct\s*\{([^{}]*)\}\s*([A-Za-z_]\w*)\s*;/g,
    (_whole, body: string, name: string) => { podBodies[name] = body; return ''; });
  const resolving = new Set<string>();
  const resolvePod = (name: string): PodSpec | null => {
    if (pods[name]) return pods[name];
    if (!(name in podBodies)) return null;
    if (resolving.has(name)) throw Error(`recursive POD struct: ${name}`);
    resolving.add(name);
    const spec = podSpec(podBodies[name], resolvePod);
    resolving.delete(name);
    pods[name] = spec;
    return spec;
  };
  for (const name of Object.keys(podBodies)) resolvePod(name);
  for (const raw of withoutPods.split(';')) {
    const statement = raw.trim();
    if (!statement) continue;
    if (statement.startsWith('typedef ')) {
      const declaration = /^typedef\s+struct\s+([A-Za-z_]\w*)\s+([A-Za-z_]\w*)$/.exec(statement);
      if (!declaration || declaration[1] !== declaration[2]) throw Error(`unsupported C typedef: ${statement}`);
      opaqueTypes.add(declaration[1]);
      continue;
    }
    const match = /^(.+?[\s*])([A-Za-z_]\w*)\s*\(([^()]*)\)$/.exec(statement);
    if (!match) throw Error(`invalid C declaration: ${statement}`);
    const params: Parameter[] = [];
    if (match[3].trim() && match[3].trim() !== 'void') {
      for (const rawParam of match[3].split(',')) {
        const param = /^(.+?[\s*])([A-Za-z_]\w*)$/.exec(rawParam.trim());
        if (!param) throw Error(`invalid C parameter: ${rawParam}`);
        const namedPointer = /^\s*([A-Za-z_]\w*)\s*\*\s*$/.exec(param[1]);
        const pod = namedPointer && pods[namedPointer[1]] ? namedPointer[1] : undefined;
        params.push({ name: param[2], type: ffiType(param[1]), pod });
      }
    }
    functions.push({ name: match[2], params, returns: ffiType(match[1], true) });
  }
  if (!functions.length) throw Error('cdecl requires at least one function');
  for (const name of Object.keys(opts?.functions ?? {})) {
    if (!functions.some(item => item.name === name)) throw Error(`unknown C function policy: ${name}`);
    const policy = opts.functions[name];
    if (policy?.returns?.out) {
      const out = functions.find(item => item.name === name)!.params.find(param => param.name === policy.returns.out);
      if (!out || out.type !== 'ptr') throw Error(`invalid C output parameter: ${policy.returns.out}`);
    }
    if (policy?.returns?.kind === 'handle' &&
        (!opaqueTypes.has(policy.returns.type) || functions.find(item => item.name === name)!.returns !== 'ptr')) {
      throw Error(`invalid C handle return policy: ${name}`);
    }
    const message = policy?.errors?.message;
    if (message != null && typeof message !== 'string') {
      if (!message || typeof message !== 'object' || typeof message.from !== 'string' ||
          !functions.some(item => item.name === message.from) ||
          message.arg != null && (typeof message.arg !== 'string' ||
            !functions.find(item => item.name === name)!.params.some(param => param.name === message.arg))) {
        throw Error(`invalid C error message source: ${name}`);
      }
    }
  }
  for (const [type, policy] of Object.entries(opts?.handles ?? {}) as [string, any][]) {
    if (!opaqueTypes.has(type) || (policy?.close != null &&
        !functions.some(item => item.name === policy.close))) throw Error(`invalid C handle policy: ${type}`);
  }
  return { symbols: functions.map(item => item.name), functions, policies: opts ?? {}, pods };
}
function bytesPerElement(name: string): number {
  return ['u8', 'i8'].includes(name) ? 1 : ['u16', 'i16'].includes(name) ? 2 :
    ['u32', 'i32', 'f32'].includes(name) ? 4 : 8;
}
function backingLength(value: any): number {
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return value.byteLength;
  throw Error('buffer argument must be an ArrayBuffer or typed array');
}
function podField(view: DataView, field: PodField, value?: any, base = 0): any {
  const at = base + field.offset;
  if (value !== undefined) {
    if (typeof value !== 'number' && typeof value !== 'boolean' && typeof value !== 'bigint') throw Error(`invalid POD field: ${field.name}`);
    switch (field.type) {
      case 'bool': case 'u8': view.setUint8(at, Number(value)); break;
      case 'i8': view.setInt8(at, Number(value)); break;
      case 'u16': view.setUint16(at, Number(value), true); break;
      case 'i16': view.setInt16(at, Number(value), true); break;
      case 'u32': view.setUint32(at, Number(value), true); break;
      case 'i32': view.setInt32(at, Number(value), true); break;
      case 'f32': view.setFloat32(at, Number(value), true); break;
      case 'f64': view.setFloat64(at, Number(value), true); break;
      case 'u64': view.setBigUint64(at, BigInt(value), true); break;
      case 'i64': view.setBigInt64(at, BigInt(value), true); break;
    }
    return;
  }
  switch (field.type) {
    case 'bool': return view.getUint8(at) !== 0;
    case 'u8': return view.getUint8(at);
    case 'i8': return view.getInt8(at);
    case 'u16': return view.getUint16(at, true);
    case 'i16': return view.getInt16(at, true);
    case 'u32': return view.getUint32(at, true);
    case 'i32': return view.getInt32(at, true);
    case 'f32': return view.getFloat32(at, true);
    case 'f64': return view.getFloat64(at, true);
    case 'u64': return view.getBigUint64(at, true);
    case 'i64': return view.getBigInt64(at, true);
  }
}
function writePod(view: DataView, spec: PodSpec, object: any, pods: Record<string, PodSpec>, base = 0): void {
  if (!object || typeof object !== 'object') throw Error('POD argument must be an object');
  for (const field of spec.fields) {
    const value = object[field.name];
    if (value === undefined) throw Error(`missing POD field: ${field.name}`);
    if (field.pod) writePod(view, pods[field.pod], value, pods, base + field.offset);
    else podField(view, field, value, base);
  }
}
function readPod(view: DataView, spec: PodSpec, object: any, pods: Record<string, PodSpec>, base = 0): void {
  for (const field of spec.fields) {
    if (field.pod) readPod(view, pods[field.pod], object[field.name], pods, base + field.offset);
    else object[field.name] = podField(view, field, undefined, base);
  }
}
export function prepareNative(name: string, declarations: string, opts?: any): Prepared {
  if (typeof name !== 'string' || !name) throw Error('cdecl: invalid library name');
  return parse(declarations, opts);
}
function openWithSearch(name: string, search: any): number {
  const open = (candidate: string): number | null => {
    try { return globalThis.__hao_ffi_open(candidate); } catch (_) { return null; }
  };
  if (!search || name.includes('/') || name.includes('.')) {
    const handle = open(name);
    if (handle !== null) return handle;
    throw Error('library unavailable');
  }
  const strategy = search.strategy ?? 'runtime-default';
  const paths: string[] = search.paths ?? [];
  const basenames = [`lib${name}.dylib`, `lib${name}.so`];
  const fromPaths = (): number | null => {
    for (const path of paths) {
      for (const basename of basenames) {
        const handle = open(`${path.replace(/\/$/, '')}/${basename}`);
        if (handle !== null) return handle;
      }
    }
    return null;
  };
  const handle = strategy === 'relative-first' ? fromPaths() ?? open(name) :
    strategy === 'system-first' ? open(name) ?? fromPaths() : open(name);
  if (handle !== null) return handle;
  throw Error('library unavailable');
}
export function openNative(name: string, declarations: string, opts?: any): { handle: number; symbols: string[]; policies: any } {
  const prepared = prepareNative(name, declarations, opts);
  let handle: number;
  try { handle = openWithSearch(name, prepared.policies?.search); }
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
  const outIndex = policy?.returns?.out == null ? -1 : fn.params.findIndex(param => param.name === policy.returns.out);
  const buffers = policy?.buffers ?? {};
  const lengths = new Map<string, number>();
  const visible = fn.params.filter(param => param.name !== policy?.returns?.out &&
    !Object.values(buffers).some((buffer: any) => buffer.length === param.name));
  if (args.length !== visible.length) throw Error('FFI: wrong number of arguments');
  let input = 0;
  const values = new Map<string, any>();
  const staged: { object: any; view: DataView; spec: PodSpec }[] = [];
  for (const param of visible) {
    const value = args[input++];
    if (param.pod && value && typeof value === 'object' && !ArrayBuffer.isView(value)) {
      const spec = prepared.pods[param.pod];
      const bytes = new Uint8Array(spec.size);
      const view = new DataView(bytes.buffer);
      writePod(view, spec, value, prepared.pods);
      values.set(param.name, bytes);
      staged.push({ object: value, view, spec });
    } else values.set(param.name, value);
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
  const native = globalThis.__hao_ffi_call(handle, symbol, fn.params.map(param => values.get(param.name)),
    outIndex < 0 ? undefined : outIndex);
  const raw = outIndex < 0 ? native : native.raw;
  const errors = policy?.errors;
  if (errors?.kind === 'status' && raw !== (errors.ok ?? 0) ||
      errors?.kind === 'null' && (raw === null || raw === 0) ||
      errors?.kind === 'sentinel' && raw === errors.value) {
    let message = typeof errors.message === 'string' ? errors.message : `${symbol} failed`;
    if (errors.message && typeof errors.message === 'object') {
      const source = errors.message;
      const helper = prepared.functions.find(item => item.name === source.from);
      if (helper && helper.params.length <= 1 && (helper.params.length === 0 || source.arg)) {
        const argument = source.arg === policy?.returns?.out ? native.out : values.get(source.arg);
        try {
          const supplied = globalThis.__hao_ffi_call(handle, source.from,
            helper.params.length === 0 ? [] : [argument]);
          if (typeof supplied === 'string') message = supplied;
        } catch { /* retain the original call failure */ }
      }
    }
    const error: any = new Error(message);
    if (errors.code) error.code = errors.code;
    throw error;
  }
  for (const item of staged) readPod(item.view, item.spec, item.object, prepared.pods);
  return outIndex < 0 ? raw : native.out;
}
export function closeNative(handle: number): void {
  libraries.delete(handle);
  globalThis.__hao_ffi_close(handle);
}
