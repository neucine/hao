declare module "hao:util" {
  interface InspectOptions {
    maxDepth?: number
    maxArrayLength?: number
    maxStringLength?: number
  }

  export function inspect(value: unknown, opts?: InspectOptions): string
  export function setInspectOptions(opts: InspectOptions): void
  export function getInspectOptions(): InspectOptions

  const utilModule: {
    inspect: typeof inspect
    setInspectOptions: typeof setInspectOptions
    getInspectOptions: typeof getInspectOptions
  }

  export default utilModule
}
