declare module "hao:process/native" {
  export function getEnvNative(name: string): string | null;
  export function runNative(options: {
    cmd: string;
    args?: string[];
    cwd?: string;
    maxOutputBytes?: number;
  }): {
    stdout: string;
    stderr: string;
    exitCode: number | null;
    signal: number | null;
  };
}
