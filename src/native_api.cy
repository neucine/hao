// Direct Cyna integration surface for hosts that do not use the Hao C ABI.
import { Runtime } from .runtime;
// Keep the exported implementation module in link units. HaoRuntime's C
// bridge calls these Cyna implementations even when the embedding host only
// uses this Cyna API.
import { abi_async_uv_new as retain_implementation_link } from .abi;
import {
    NativeModuleLoader as BridgeNativeModuleLoader,
    runtime_register_native
} from .bridge.qjs;

pub type NativeModuleLoader = BridgeNativeModuleLoader;

pub fn api_version(): u32 {
    return 1;
}

// Registers a QuickJS module supplied by the Cyna host. The loader receives
// Hao's context pointer and the requested module specifier.
pub fn register_native_module(runtime: &const Runtime, specifier: string,
    loader: NativeModuleLoader
): i32 {
    const bytes = specifier.bytes();
    return runtime_register_native(
        runtime.handle,
        bytes.ptr as! *const c_uchar,
        bytes.len() as c_size_t,
        loader
    ) as i32;
}
