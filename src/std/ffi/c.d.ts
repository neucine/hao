declare module "hao:ffi/c" {
  import type { CBoundLibrary, CDeclOptions } from "hao:ffi"

  export function cdecl<
    const Decls extends string,
  >(name: string, declarations: Decls): CBoundLibrary<Decls, undefined>

  export function cdecl<
    const Decls extends string,
    const Opts,
  >(name: string, declarations: Decls, opts: Opts extends CDeclOptions ? Opts : CDeclOptions): CBoundLibrary<Decls, Opts extends CDeclOptions ? Opts : undefined>

  export const decl: typeof cdecl

  const cModule: {
    decl: typeof cdecl
  }

  export default cModule
}
