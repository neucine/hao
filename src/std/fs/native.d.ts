declare module "hao:fs/native" {
  export function existsSync(path: string): boolean;
  export function readFileSync(path: string): string;
  export function writeFileSync(path: string, data: string): void;
  export function statSync(path: string): { size: number };
}
