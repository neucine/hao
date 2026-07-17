declare module "hao:ffi/c/native" {
  export function openNative(name: string, declarations: string, opts?: unknown): {
    handle: number
    symbols: string[]
    policies: {
      handles?: Record<string, { close?: string }>
      functions?: Record<string, { returns?: { kind?: string; type?: string; out?: string } }>
    }
  }
  export function callNative(handle: number, symbol: string, args: unknown[]): unknown
  export function closeNative(handle: number): void
  export function prepareNative(name: string, declarations: string, opts?: unknown): {
    descriptor: Record<string, { args: string[]; returns: string }>
    policies: {
      handles?: Record<string, { close?: string }>
      functions?: Record<string, { returns?: { kind?: string; type?: string; out?: string } }>
    }
  }
}
