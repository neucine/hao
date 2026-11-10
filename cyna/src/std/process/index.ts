const { getEnvNative, runNative } = {
  getEnvNative: globalThis.__hao_process_getEnvNative,
  runNative: globalThis.__hao_process_runNative,
};

export function getEnv(name: string): string | null {
  if (typeof name !== "string" || name.length === 0) {
    throw new Error("process.getEnv requires a non-empty variable name");
  }
  return getEnvNative(name);
}

export function run(options: string | {
  cmd: string;
  args?: string[];
  cwd?: string;
  maxOutputBytes?: number;
  check?: boolean;
}) {
  const normalized = typeof options === "string"
    ? { cmd: "sh", args: ["-c", options] }
    : options;
  const promise: any = Promise.resolve().then(() => {
    const raw = runNative(normalized);
    const result = Object.assign(raw, {
      json() { return JSON.parse(raw.stdout); },
    });
    const check = normalized && typeof normalized.check === "boolean"
      ? normalized.check
      : true;
    if (check && result.exitCode !== 0) {
      const error: any = new Error(`process exited with exit code ${result.exitCode}`);
      Object.assign(error, result);
      throw error;
    }
    return result;
  });
  promise.json = async () => (await promise).json();
  promise.text = async () => (await promise).stdout;
  return promise;
}

export default { run, getEnv };
