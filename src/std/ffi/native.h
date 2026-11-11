#ifndef HAO_STD_FFI_NATIVE_H
#define HAO_STD_FFI_NATIVE_H
#include <quickjs.h>
void hao_install_ffi_globals(JSContext *ctx, JSValue global);
void hao_ffi_cleanup(JSContext *ctx);
#endif
