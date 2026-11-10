import { Runtime } from .runtime;
import { fs_exists } from .fs_host;

pub fn install(runtime: &const Runtime): i32 {
    const runtime_status = runtime.register_source_module(
        "std:runtime",
        "export const name = 'hao'; export const namespace = 'std:'; export default { name, namespace };"
    );
    if runtime_status != 0 {
        return runtime_status;
    }
    return runtime.register_source_module(
        "std:fs",
        "export const existsSync = globalThis.__hao_fs_existsSync; export const readFileSync = globalThis.__hao_fs_readFileSync; export const writeFileSync = globalThis.__hao_fs_writeFileSync; export const statSync = globalThis.__hao_fs_statSync; export default { existsSync, readFileSync, writeFileSync, statSync };"
    );
}
