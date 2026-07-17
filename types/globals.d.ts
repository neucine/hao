/** Minimal global type declarations for the Hao runtime. */

interface Console {
  log(...args: unknown[]): void
  error(...args: unknown[]): void
  warn(...args: unknown[]): void
}

declare var console: Console

type RuntimeErrorCode =
  | "invalid_arg"
  | "missing_arg"
  | "shape_mismatch"
  | "invalid_shape"
  | "invalid_dtype"
  | "out_of_memory"
  | "device_mismatch"
  | "device_error"
  | "grad_error"
  | "io_error"
  | "cancelled"
  | "invalid_state"
  | "unsupported_lowering"
  | "internal"
  | "thread_pool_unavailable"

declare class RuntimeError extends Error {
  readonly name: "RuntimeError"
  readonly code: RuntimeErrorCode
  readonly nativeStack?: string

  constructor(code: RuntimeErrorCode, message: string)
}

/** Schedule a callback to run after `delay` milliseconds. Returns a timer handle id. */
declare function setTimeout(callback: () => void, delay?: number): number

/** Cancel a timer previously created with `setTimeout`. */
declare function clearTimeout(id: number): void
