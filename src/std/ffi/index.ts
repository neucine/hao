import { openNative, callNative, closeNative } from "std:ffi/native";
import cModule from "std:ffi/c";

type FFIDescriptor = Record<string, { args: string[]; returns: string }>;

function dlopen(name: string, descriptor: FFIDescriptor) {
  if (typeof name !== "string" || name.length === 0) {
    throw new Error("dlopen: invalid library name");
  }
  if (!descriptor || typeof descriptor !== "object") {
    throw new Error("dlopen: descriptor must be an object");
  }
  const handle = openNative(name, descriptor);
  let closed = false;
  const lib: Record<string, any> = {};
  for (const symbol of Object.keys(descriptor)) {
    lib[symbol] = (...args: any[]) => {
      if (closed) throw new Error("FFI: library has been closed");
      return callNative(handle, symbol, args);
    };
  }
  lib.close = () => {
    if (closed) return;
    closed = true;
    closeNative(handle);
  };
  return lib;
}

export { dlopen };
export { cModule as c };
export default { dlopen, c: cModule };
