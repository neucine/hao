import { getEnvNative, runNative } from "std:process/native";

function normalize(options: any) {
  if (typeof options === "string") {
    return {
      cmd: "sh",
      args: ["-c", options],
    };
  }
  return options;
}

function decorate(raw: any) {
  return Object.assign(raw, {
    json(): unknown {
      return JSON.parse(raw.stdout);
    },
  });
}

export function run(options: string | {
  cmd: string;
  args?: string[];
  cwd?: string;
  maxOutputBytes?: number;
  check?: boolean;
}) {
  const normalized = normalize(options);
  const promise: any = Promise.resolve().then(async () => {
    const raw = await runNative(normalized);
    const result = decorate(raw);
    const check = !!normalized && typeof normalized.check === "boolean" ? normalized.check : true;
    if (check && result.exitCode !== 0) {
      const err: any = new Error(`process exited with exit code ${result.exitCode}`);
      err.stdout = result.stdout;
      err.stderr = result.stderr;
      err.exitCode = result.exitCode;
      err.signal = result.signal;
      throw err;
    }
    return result;
  });

  promise.json = async function(): Promise<unknown> {
    const result = await promise;
    return result.json();
  };

  promise.text = async function(): Promise<string> {
    const result = await promise;
    return result.stdout;
  };

  return promise;
}

export function getEnv(name: string): string | null {
  if (typeof name !== "string" || name.length === 0) {
    throw new Error("process.getEnv requires a non-empty variable name");
  }
  return getEnvNative(name);
}

export default { run, getEnv };
