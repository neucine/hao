interface FSStat {
  size: number
}

declare module "hao:fs" {
  export function existsSync(path: string): boolean
  export function readFileSync(path: string): string
  export function writeFileSync(path: string, data: string): void
  export function statSync(path: string): FSStat

  const fsModule: {
    existsSync: typeof existsSync
    readFileSync: typeof readFileSync
    writeFileSync: typeof writeFileSync
    statSync: typeof statSync
  }

  export default fsModule
}
