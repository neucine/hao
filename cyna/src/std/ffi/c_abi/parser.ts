import type { Parameter, FunctionSpec, PodSpec } from "std:ffi/c_abi/ast";
import type { Prepared } from "std:ffi/c_abi/metadata";
import { podSpec, ffiType } from "std:ffi/c_abi/lower";
import { invalidArg } from "std:ffi/c_abi/errors";
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
  if (typeof declarations !== 'string' || !declarations.trim()) throw invalidArg('cdecl: declarations must be a non-empty string');
  const source = stripComments(declarations);
  if (/#|\.\.\./.test(source)) throw invalidArg('unsupported C declarations');
  if (opts?.search != null) {
    const search = opts.search;
    if (typeof search !== 'object' || Array.isArray(search)) throw invalidArg('invalid C library search policy');
    if (search.strategy != null && !['runtime-default', 'relative-first', 'system-first'].includes(search.strategy)) {
      throw invalidArg('invalid C library search strategy');
    }
    if (search.paths != null && (!Array.isArray(search.paths) ||
        search.paths.some((path: unknown) => typeof path !== 'string' || !path))) {
      throw invalidArg('invalid C library search paths');
    }
  }
  const functions: FunctionSpec[] = [];
  const opaqueTypes = new Set<string>();
  const pods: Record<string, PodSpec> = {};
  const podBodies: Record<string, string> = {};
  const withoutPods = source.replace(/typedef\s+struct\s*\{([^{}]*)\}\s*([A-Za-z_]\w*)\s*;/g,
    (_whole, body: string, name: string) => { podBodies[name] = body; return ''; });
  const resolving = new Set<string>();
  const resolvePod = (name: string): PodSpec | null => {
    if (pods[name]) return pods[name];
    if (!(name in podBodies)) return null;
    if (resolving.has(name)) throw invalidArg(`recursive POD struct: ${name}`);
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
      if (!declaration || declaration[1] !== declaration[2]) throw invalidArg(`unsupported C typedef: ${statement}`);
      opaqueTypes.add(declaration[1]);
      continue;
    }
    const match = /^([\s\S]+?[\s*])([A-Za-z_]\w*)\s*\(([^()]*)\)$/.exec(statement);
    if (!match) throw invalidArg(`invalid C declaration: ${statement}`);
    const params: Parameter[] = [];
    if (match[3].trim() && match[3].trim() !== 'void') {
      for (const rawParam of match[3].split(',')) {
        const param = /^([\s\S]+?[\s*])([A-Za-z_]\w*)$/.exec(rawParam.trim());
        if (!param) throw invalidArg(`invalid C parameter: ${rawParam}`);
        const namedPointer = /^\s*([A-Za-z_]\w*)\s*\*\s*$/.exec(param[1]);
        const pod = namedPointer && pods[namedPointer[1]] ? namedPointer[1] : undefined;
        params.push({ name: param[2], type: ffiType(param[1]), pod });
      }
    }
    functions.push({ name: match[2], params, returns: ffiType(match[1], true) });
  }
  if (!functions.length) throw invalidArg('cdecl requires at least one function');
  for (const name of Object.keys(opts?.functions ?? {})) {
    if (!functions.some(item => item.name === name)) throw invalidArg(`unknown C function policy: ${name}`);
    const policy = opts.functions[name];
    if (policy?.returns?.out) {
      const out = functions.find(item => item.name === name)!.params.find(param => param.name === policy.returns.out);
      if (!out || out.type !== 'ptr') throw invalidArg(`invalid C output parameter: ${policy.returns.out}`);
    }
    if (policy?.returns?.kind === 'handle' &&
        (!opaqueTypes.has(policy.returns.type) || functions.find(item => item.name === name)!.returns !== 'ptr')) {
      throw invalidArg(`invalid C handle return policy: ${name}`);
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
    if (!opaqueTypes.has(type) || (policy?.close != null &&
        !functions.some(item => item.name === policy.close))) throw invalidArg(`invalid C handle policy: ${type}`);
  }
  return { symbols: functions.map(item => item.name), functions, policies: opts ?? {}, pods };
}
