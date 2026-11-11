declare module "std:ffi/native" {
  export function openNative(name: string, descriptor: Record<string, { args: string[]; returns: string }>): number
  export function callNative(handle: number, symbol: string, args: unknown[]): unknown
  export function closeNative(handle: number): void
}
