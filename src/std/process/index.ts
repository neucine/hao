import { getEnvNative } from "hao:process/native";

export function getEnv(name: string): string | null {
  if (typeof name !== "string" || name.length === 0) {
    throw new Error("process.getEnv requires a non-empty variable name");
  }
  return getEnvNative(name);
}

export default { getEnv };
