declare module "hao:test/native" {
  export function pushSuite(name: string): void
  export function popSuite(): void
  export function registerTest(name: string, fn: Function, mode: string): void
  export function registerHook(kind: string, fn: Function): void
  export function getCurrentTestFilePath(): string
  export function getCurrentExecutablePath(): string
  export function beginCapture(target?: string): void
  export function endCapture(): { stdout: string; stderr: string; combined: string }
  export function getRegisteredCounts(): { registeredTests: number; registeredHooks: number; suiteDepth: number }
}
