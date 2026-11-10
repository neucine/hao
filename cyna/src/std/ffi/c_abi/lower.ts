import type { PodField, PodSpec } from "std:ffi/c_abi/ast";
import { invalidArg } from "std:ffi/c_abi/errors";
function scalarLayout(type: string): { size: number; alignment: number } {
  if (['bool', 'i8', 'u8'].includes(type)) return { size: 1, alignment: 1 };
  if (['i16', 'u16'].includes(type)) return { size: 2, alignment: 2 };
  if (['i32', 'u32', 'f32'].includes(type)) return { size: 4, alignment: 4 };
  if (['i64', 'u64', 'f64'].includes(type)) return { size: 8, alignment: 8 };
  throw invalidArg(`unsupported POD field type: ${type}`);
}
export function podSpec(body: string, resolve: (name: string) => PodSpec | null): PodSpec {
  const fields: PodField[] = [];
  let size = 0, alignment = 1;
  for (const source of body.split(';')) {
    const declaration = source.trim();
    if (!declaration) continue;
    const match = /^([\s\S]+?\s+)([A-Za-z_]\w*)$/.exec(declaration);
    if (!match) throw invalidArg(`invalid POD field: ${declaration}`);
    const name = match[1].trim();
    const nested = resolve(name);
    const type = nested ? 'pod' : ffiType(name);
    const layout = nested ?? scalarLayout(type);
    size = Math.ceil(size / layout.alignment) * layout.alignment;
    fields.push({ name: match[2], type, offset: size, pod: nested ? name : undefined });
    size += layout.size;
    alignment = Math.max(alignment, layout.alignment);
  }
  if (!fields.length) throw invalidArg('empty POD struct');
  return { fields, size: Math.ceil(size / alignment) * alignment, alignment };
}

export function ffiType(type: string, returning = false): string {
  const normalized = type.replace(/\b(const|volatile|restrict|signed)\b/g, '').replace(/\s+/g, ' ').trim();
  if (/\*/.test(normalized)) {
    if (/\bchar\s*\*/.test(normalized)) return returning ? 'cstring' : 'cstring';
    return 'ptr';
  }
  const mapping: Record<string, string> = {
    void: 'void', bool: 'bool', char: 'i8',
    size_t: 'u64', float: 'f32', double: 'f64',
    int8_t: 'i8', int16_t: 'i16', int32_t: 'i32', int64_t: 'i64',
    uint8_t: 'u8', uint16_t: 'u16', uint32_t: 'u32', uint64_t: 'u64',
  };
  const result = mapping[normalized];
  if (!result) throw invalidArg(`unsupported C type: ${type}`);
  return result;
}
