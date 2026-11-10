import { Runtime } from .runtime;

pub fn install(runtime: &const Runtime): i32 {
    return runtime.register_source_module(
        "std:runtime",
        "export const name = 'hao'; export const namespace = 'std:'; export default { name, namespace };"
    );
}
