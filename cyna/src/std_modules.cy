import { Runtime } from .runtime;
import { fs_exists } from .fs_host;
import { resolve_package } from .package_resolver;
import { get_env } from .process_host;

pub fn install(runtime: &const Runtime): i32 {
    const runtime_status = runtime.register_source_module(
        "std:runtime",
        "export const name = 'hao'; export const namespace = 'std:'; export default { name, namespace };"
    );
    if runtime_status != 0 {
        return runtime_status;
    }
    const fs_status = runtime.register_source_module(
        "std:fs",
        "export const existsSync = globalThis.__hao_fs_existsSync; export const readFileSync = globalThis.__hao_fs_readFileSync; export const writeFileSync = globalThis.__hao_fs_writeFileSync; export const statSync = globalThis.__hao_fs_statSync; export default { existsSync, readFileSync, writeFileSync, statSync };"
    );
    if fs_status != 0 {
        return fs_status;
    }
    return runtime.register_source_module(
        "std:process",
        "export function getEnv(name) { if (typeof name !== 'string' || !name) throw new Error('process.getEnv requires a non-empty variable name'); return globalThis.__hao_process_getEnvNative(name); } export function run(options) { const normalized = typeof options === 'string' ? { cmd: 'sh', args: ['-c', options] } : options; const promise = Promise.resolve().then(() => { const raw = globalThis.__hao_process_runNative(normalized); const result = Object.assign(raw, { json() { return JSON.parse(raw.stdout); } }); const check = normalized && typeof normalized.check === 'boolean' ? normalized.check : true; if (check && result.exitCode !== 0) { const error = new Error('process exited with exit code ' + result.exitCode); Object.assign(error, result); throw error; } return result; }); promise.json = async () => (await promise).json(); promise.text = async () => (await promise).stdout; return promise; } export default { run, getEnv };"
    );
}
