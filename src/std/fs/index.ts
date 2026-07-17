import * as native from "std:fs/native";

export const existsSync = native.existsSync;
export const readFileSync = native.readFileSync;
export const writeFileSync = native.writeFileSync;
export const statSync = native.statSync;

export default { existsSync, readFileSync, writeFileSync, statSync };
