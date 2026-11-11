import type { PodSpec } from "std:ffi/c_abi/ast";
import type { Prepared } from "std:ffi/c_abi/metadata";
import { parse } from "std:ffi/c_abi/parser";
import { backingLength, bytesPerElement, writePod, readPod } from "std:ffi/c_abi/struct_runtime";
import { invalidArg } from "std:ffi/c_abi/errors";

const libraries = new Map<number, Prepared>();
const runtimeErrorCodes = new Set([
  'invalid_arg', 'missing_arg', 'shape_mismatch', 'invalid_shape',
  'invalid_dtype', 'out_of_memory', 'device_mismatch', 'device_error',
  'grad_error', 'io_error', 'cancelled', 'invalid_state',
  'unsupported_lowering', 'internal', 'thread_pool_unavailable',
]);

function prepareSpec(name: string, declarations: string, opts: any, operation: string): Prepared {
  if (typeof name !== 'string' || !name) throw invalidArg('cdecl: invalid library name');
  try { return parse(declarations, opts); }
  catch (error) {
    if (error instanceof RuntimeError && error.message === 'duplicate C function') {
      throw invalidArg(`${operation}: declaration lowering failed: DuplicateFunctionName`, 'DuplicateFunctionName');
    }
    throw error;
  }
}
export function prepareNative(name: string, declarations: string, opts?: any): {
  descriptor: Record<string, { args: string[]; returns: string }>;
  policies: { handles: Record<string, { close?: string }>; functions: Record<string, any> };
} {
  const prepared = prepareSpec(name, declarations, opts, 'prepareNative');
  const descriptor: Record<string, { args: string[]; returns: string }> = {};
  for (const fn of prepared.functions) {
    const policy = prepared.policies?.functions?.[fn.name];
    if (policy?.errors || Object.keys(policy?.buffers ?? {}).length) {
      throw new RuntimeError('internal', 'prepareNative: failed to build descriptor');
    }
    descriptor[fn.name] = { args: fn.params.map(param => param.type), returns: fn.returns };
  }
  return { descriptor, policies: publicPolicies(prepared) };
}
function publicPolicies(prepared: Prepared): {
  handles: Record<string, { close?: string }>;
  functions: Record<string, any>;
} {
  const functions: Record<string, any> = {};
  for (const fn of prepared.functions) {
    const policy = prepared.policies?.functions?.[fn.name];
    let type = policy?.returns?.kind === 'handle' ? policy.returns.type : undefined;
    if (!type && policy?.returns?.out) {
      const output = fn.params.find(param => param.name === policy.returns.out);
      const match = /^([A-Za-z_]\w*)\s*\*\s*\*$/.exec(output?.rawType ?? '');
      if (match && prepared.opaqueTypes.includes(match[1])) type = match[1];
    }
    if (type) functions[fn.name] = { returns: { kind: 'handle', type } };
  }
  return { handles: prepared.policies?.handles ?? {}, functions };
}
function openWithSearch(name: string, search: any): number {
  const open = (candidate: string): number | null => {
    try { return globalThis.__hao_ffi_open(candidate); } catch (_) { return null; }
  };
  if (!search || name.includes('/') || name.includes('.')) {
    const handle = open(name);
    if (handle !== null) return handle;
    throw invalidArg('library unavailable');
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
  throw invalidArg('library unavailable');
}
export function openNative(name: string, declarations: string, opts?: any): { handle: number; symbols: string[]; policies: any } {
  const prepared = prepareSpec(name, declarations, opts, 'openNative');
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
    if (error instanceof Error && error.message === 'dlopen: symbol not found') {
      const missing: any = new RuntimeError('io_error', 'openNative: symbol not found: SymbolNotFound');
      const capture = (globalThis as any).__hao_capture_native_stack;
      if (typeof capture === 'function') {
        const stack = capture('SymbolNotFound');
        if (typeof stack === 'string') missing.nativeStack = stack;
      }
      throw missing;
    }
    throw error;
  }
  libraries.set(handle, prepared);
  return { handle, symbols: prepared.symbols, policies: publicPolicies(prepared) };
}
export function callNative(handle: number, symbol: string, args: any[]): unknown {
  const prepared = libraries.get(handle);
  if (!prepared) throw invalidArg('C: invalid library handle');
  const fn = prepared.functions.find(item => item.name === symbol);
  if (!fn) throw invalidArg('C: unknown symbol');
  const policy = prepared.policies?.functions?.[symbol];
  const outIndex = policy?.returns?.out == null ? -1 : fn.params.findIndex(param => param.name === policy.returns.out);
  const buffers = policy?.buffers ?? {};
  const lengths = new Map<string, number>();
  const visible = fn.params.filter(param => param.name !== policy?.returns?.out &&
    !Object.values(buffers).some((buffer: any) => buffer.length === param.name));
  if (args.length !== visible.length) throw invalidArg('C: wrong number of arguments');
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
      if (!Number.isInteger(length)) throw invalidArg('buffer length is not aligned to its element type');
      const existing = lengths.get(buffer.length);
      if (existing !== undefined && existing !== length) throw invalidArg('buffer lengths disagree');
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
    const code = runtimeErrorCodes.has(errors.code) ? errors.code : 'internal';
    throw new RuntimeError(code, message);
  }
  for (const item of staged) readPod(item.view, item.spec, item.object, prepared.pods);
  return outIndex < 0 ? raw : native.out;
}
export function closeNative(handle: number): void {
  libraries.delete(handle);
  try { globalThis.__hao_ffi_close(handle); }
  catch (error) {
    if (error instanceof TypeError && error.message === 'FFI: invalid library handle') {
      throw invalidArg('C: invalid library handle');
    }
    throw error;
  }
}
