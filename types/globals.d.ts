/** Minimal global type declarations for the Hao runtime. */

interface Console {
  log(...args: unknown[]): void
  error(...args: unknown[]): void
  warn(...args: unknown[]): void
}

declare var console: Console

/** Schedule a callback to run after `delay` milliseconds. Returns a timer handle id. */
declare function setTimeout(callback: () => void, delay?: number): number

/** Cancel a timer previously created with `setTimeout`. */
declare function clearTimeout(id: number): void
