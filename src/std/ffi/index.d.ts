declare module "hao:ffi" {
  type FFIDescriptor = Record<string, { args: string[]; returns: string }>

  export function dlopen(name: string, descriptor: FFIDescriptor): Record<string, any>

  export { default as c } from "hao:ffi/c"

  export default {
    dlopen,
    c,
  }
}
