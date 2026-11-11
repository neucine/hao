import type { PodField, PodSpec } from "std:ffi/c_abi/ast";
import { invalidArg } from "std:ffi/c_abi/errors";
export function bytesPerElement(name: string): number {
  return ['u8', 'i8'].includes(name) ? 1 : ['u16', 'i16'].includes(name) ? 2 :
    ['u32', 'i32', 'f32'].includes(name) ? 4 : 8;
}
export function backingLength(value: any): number {
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return value.byteLength;
  throw invalidArg('buffer argument must be an ArrayBuffer or typed array');
}
function podField(view: DataView, field: PodField, value?: any, base = 0): any {
  const at = base + field.offset;
  if (value !== undefined) {
    if (typeof value !== 'number' && typeof value !== 'boolean' && typeof value !== 'bigint') throw invalidArg(`invalid POD field: ${field.name}`);
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
export function writePod(view: DataView, spec: PodSpec, object: any, pods: Record<string, PodSpec>, base = 0): void {
  if (spec.invalidLayout) throw invalidArg('C: invalid POD struct layout', 'UnsupportedFeature');
  if (!object || typeof object !== 'object') throw invalidArg('POD argument must be an object');
  for (const field of spec.fields) {
    const value = object[field.name];
    if (value === undefined) throw invalidArg(`missing POD field: ${field.name}`);
    if (field.pod) writePod(view, pods[field.pod], value, pods, base + field.offset);
    else podField(view, field, value, base);
  }
}
export function readPod(view: DataView, spec: PodSpec, object: any, pods: Record<string, PodSpec>, base = 0): void {
  if (spec.invalidLayout) throw invalidArg('C: invalid POD struct layout', 'UnsupportedFeature');
  for (const field of spec.fields) {
    if (field.pod) readPod(view, pods[field.pod], object[field.name], pods, base + field.offset);
    else object[field.name] = podField(view, field, undefined, base);
  }
}
