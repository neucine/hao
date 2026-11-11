import type { Parameter, FunctionSpec, PodSpec } from "std:ffi/c_abi/ast";
import type { Prepared } from "std:ffi/c_abi/metadata";
import { podSpec, ffiType } from "std:ffi/c_abi/lower";
import { invalidArg } from "std:ffi/c_abi/errors";
function functionType(type: string, returning = false): string {
  const bare = /^(?:const\s+)?([A-Za-z_]\w*)$/.exec(type.trim());
  if (bare && !['void', 'bool', 'char', 'size_t', 'float', 'double',
    'int8_t', 'int16_t', 'int32_t', 'int64_t', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t',
    'short', 'int', 'long', 'unsigned', 'signed', 'volatile', 'restrict', 'static', 'extern'].includes(bare[1])) {
    return 'named';
  }
  return ffiType(type, returning);
}
function stripComments(source: string): string {
  let result = '';
  for (let index = 0; index < source.length;) {
    if (source.startsWith('//', index)) {
      index += 2;
      while (index < source.length && source[index] !== '\n') index++;
      result += ' ';
    } else if (source.startsWith('/*', index)) {
      const end = source.indexOf('*/', index + 2);
      if (end < 0) throw invalidArg('unterminated C block comment');
      index = end + 2;
      result += ' ';
    } else {
      result += source[index++];
    }
  }
  return result;
}
export function parse(declarations: string, opts: any): Prepared {
  if (typeof declarations !== 'string') throw invalidArg('cdecl: declarations must be a string');
  const source = stripComments(declarations);
  if (/\bstruct\s+[A-Za-z_]\w*\s*\*/.test(source)) {
    throw invalidArg('unsupported C declarations', 'UnsupportedFeature');
  }
  if (/#|\.\.\.|\(\s*\*\s*[A-Za-z_]\w*\s*\)/.test(source)) {
    throw invalidArg('unsupported C declarations', 'UnsupportedFeature');
  }
  if (source.trim() && !source.trim().endsWith(';')) throw invalidArg('C declaration requires a terminating semicolon', 'SyntaxError');
  if (opts?.search != null) {
    const search = opts.search;
    if (typeof search !== 'object' || Array.isArray(search)) throw invalidArg('invalid C library search policy');
    if (search.strategy != null && !['runtime-default', 'relative-first', 'system-first'].includes(String(search.strategy))) {
      throw invalidArg('invalid C library search strategy');
    }
    if (search.paths != null && !Array.isArray(search.paths)) {
      throw invalidArg('invalid C library search paths');
    }
  }
  const functions: FunctionSpec[] = [];
  const typeReferences: string[] = [];
  const declarationTypes = new Map<string, { params: { name: string; type: string }[] }>();
  const opaqueTypes = new Set<string>();
  const pods: Record<string, PodSpec> = {};
  const podBodies: Record<string, string> = {};
  const withoutPods = source.replace(/typedef\s+struct\s*\{([^{}]*)\}\s*([A-Za-z_]\w*)\s*;/g,
    (_whole, body: string, name: string) => {
      if (name in podBodies) throw invalidArg(`duplicate C type: ${name}`);
      podBodies[name] = body;
      return '';
    });
  const resolving = new Set<string>();
  const resolvePod = (name: string): PodSpec | null => {
    if (pods[name]) return pods[name];
    if (!(name in podBodies)) return null;
    if (resolving.has(name)) return { fields: [], size: 0, alignment: 1, invalidLayout: true };
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
      if (!declaration) throw invalidArg(`unsupported C typedef: ${statement}`);
      if (declaration[1] !== declaration[2]) throw invalidArg('unsupported C declarations', 'UnsupportedFeature');
      if (opaqueTypes.has(declaration[1]) || declaration[1] in podBodies) throw invalidArg(`duplicate C type: ${declaration[1]}`);
      opaqueTypes.add(declaration[1]);
      continue;
    }
    const match = /^([\s\S]+?[\s*])([A-Za-z_]\w*)\s*\(([^()]*)\)$/.exec(statement);
    if (!match) throw invalidArg(`invalid C declaration: ${statement}`);
    if (functions.some(item => item.name === match[2])) {
      throw invalidArg('duplicate C function', 'DuplicateFunctionName');
    }
    const returnType = functionType(match[1], true);
    const params: Parameter[] = [];
    const rawParams: { name: string; type: string }[] = [];
    if (match[3].trim() && match[3].trim() !== 'void' && match[3].trim() !== 'const void') {
      const declarations = match[3].split(',');
      // Zig validates named parameter types before reporting a missing name.
      for (const rawParam of declarations) {
        const candidate = /^([\s\S]+?[\s*])([A-Za-z_]\w*)$/.exec(rawParam.trim());
        if (candidate) {
          if (/^(?:const\s+)?void$/.test(candidate[1].trim())) {
            throw invalidArg(`invalid C parameter: ${rawParam}`);
          }
          functionType(candidate[1]);
        }
      }
      for (const rawParam of declarations) {
        const param = /^([\s\S]+?[\s*])([A-Za-z_]\w*)$/.exec(rawParam.trim());
        if (rawParam.trim() === 'void') throw invalidArg('missing C parameter name');
        if (!param) throw invalidArg(`invalid C parameter: ${rawParam}`);
        if (/^(?:const\s+)?void$/.test(param[1].trim())) throw invalidArg(`invalid C parameter: ${rawParam}`);
        if (params.some(item => item.name === param[2])) throw invalidArg(`duplicate C parameter: ${param[2]}`);
        const namedPointer = /^\s*([A-Za-z_]\w*)\s*\*\s*$/.exec(param[1]);
        const pod = namedPointer && pods[namedPointer[1]] ? namedPointer[1] : undefined;
        params.push({ name: param[2], type: functionType(param[1]), pod, rawType: param[1].trim() });
        rawParams.push({ name: param[2], type: param[1].trim() });
        typeReferences.push(param[1]);
      }
    }
    functions.push({ name: match[2], params, returns: returnType });
    declarationTypes.set(match[2], { params: rawParams });
    typeReferences.push(match[1]);
  }
  const primitives = new Set(['void', 'bool', 'char', 'size_t', 'float', 'double',
    'int8_t', 'int16_t', 'int32_t', 'int64_t', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t']);
  for (const reference of typeReferences) {
    const base = reference.replace(/^\s*const\s+/, '').replace(/\*\s*const\b/g, '*')
      .replace(/\*/g, '').trim();
    if (!primitives.has(base) && !opaqueTypes.has(base) && !(base in pods)) {
      throw invalidArg(`unknown C type: ${base}`);
    }
  }
  for (const name of Object.keys(opts?.functions ?? {})) {
    if (!functions.some(item => item.name === name)) throw invalidArg(`unknown C function policy: ${name}`);
    const policy = opts.functions[name];
    const fn = functions.find(item => item.name === name)!;
    if (policy?.returns?.out) {
      const out = functions.find(item => item.name === name)!.params.find(param => param.name === policy.returns.out);
      if (!out) throw invalidArg('unknown C output parameter');
      if (out.type !== 'ptr') throw invalidArg('C output parameter is not a pointer');
    }
    if (policy?.returns?.kind === 'handle' &&
        (!opaqueTypes.has(policy.returns.type) || fn.returns !== 'ptr')) {
      throw invalidArg(`invalid C handle return policy: ${name}`);
    }
    for (const [pointerName, buffer] of Object.entries(policy?.buffers ?? {}) as [string, any][]) {
      const pointer = fn.params.find(param => param.name === pointerName);
      const length = fn.params.find(param => param.name === buffer?.length);
      const rawLength = declarationTypes.get(name)!.params.find(param => param.name === buffer?.length)?.type;
      if (!pointer) throw invalidArg('unknown C buffer pointer parameter');
      if (!length) throw invalidArg('unknown C buffer length parameter');
      if (pointer.type !== 'ptr' && pointer.type !== 'cstring') throw invalidArg('C buffer pointer parameter is not pointer-like');
      if (rawLength?.replace(/^const\s+/, '') !== 'size_t') throw invalidArg('C buffer length parameter is not size-like');
      if (!['u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'f32', 'f64'].includes(buffer.element) ||
          buffer.direction != null && !['in', 'out', 'inout'].includes(buffer.direction)) {
        throw invalidArg(`invalid C buffer policy: ${name}.${pointerName}`);
      }
    }
    const message = policy?.errors?.message;
    if (message != null && typeof message !== 'string') {
      if (!message || typeof message !== 'object' || typeof message.from !== 'string' ||
          !functions.some(item => item.name === message.from) ||
          message.arg != null && (typeof message.arg !== 'string' ||
            !functions.find(item => item.name === name)!.params.some(param => param.name === message.arg))) {
        throw invalidArg(`invalid C error message source: ${name}`);
      }
    }
  }
  for (const [type, policy] of Object.entries(opts?.handles ?? {}) as [string, any][]) {
    if (!opaqueTypes.has(type)) throw invalidArg(`invalid C handle policy: ${type}`);
    if (policy?.close != null) {
      const close = declarationTypes.get(policy.close);
      if (!close || !/^\s*(?:const\s+)?[A-Za-z_]\w*\s*\*\s*(?:const\s*)?$/.test(close.params[0]?.type ?? '') ||
          close.params[0].type.replace(/\bconst\b|\*/g, '').trim() !== type) {
        throw invalidArg(`invalid C close function: ${type}`);
      }
    }
  }
  return { symbols: functions.map(item => item.name), functions, policies: opts ?? {}, pods, opaqueTypes: [...opaqueTypes] };
}
