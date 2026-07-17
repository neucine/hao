interface ProcessRunOptions {
  cmd: string
  args?: string[]
  cwd?: string
  maxOutputBytes?: number
  check?: boolean
}

interface ProcessRunResult {
  stdout: string
  stderr: string
  exitCode: number | null
  signal: number | null
}

interface ProcessResult extends ProcessRunResult {
  json<T = unknown>(): T
}

interface ProcessRunPromise extends Promise<ProcessResult> {
  json<T = unknown>(): Promise<T>
  text(): Promise<string>
}

declare module "std:process" {
  export function run(options: ProcessRunOptions | string): ProcessRunPromise
  export function getEnv(name: string): string | null

  const processModule: {
    run: typeof run
    getEnv: typeof getEnv
  }

  export default processModule
}
