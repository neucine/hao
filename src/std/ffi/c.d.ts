declare module "hao:ffi/c" {
  export function cdecl(name: string, declarations: string, opts?: unknown): Record<string, any>
  export const decl: typeof cdecl
  export default { decl }
}
