declare module "hao:ffi" {
  type FFIDescriptor = Record<string, { args: string[]; returns: string }>

  export function dlopen(name: string, descriptor: FFIDescriptor): Record<string, any>

  export const c: {
    cdecl(name: string, declarations: string, opts?: unknown): never
    decl(name: string, declarations: string, opts?: unknown): never
  }

  export default {
    dlopen,
    c,
  }
}
