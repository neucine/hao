declare module "std:http/native" {
  export function serveNative(options: unknown, callback: (id: number, chunk?: Uint8Array) => void): { id: number; port: number }
  export function stopServerNative(id: number): void
  export function pauseClientNative(id: number): void
  export function respondNative(id: number, bytes: Uint8Array): boolean
  export function encodeTextNative(text: string): Uint8Array
  export function decodeTextNative(bytes: Uint8Array): string
  export function requestNative(request: unknown): unknown
}
