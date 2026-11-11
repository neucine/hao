#ifndef HAO_STD_FFI_NATIVE_H
#define HAO_STD_FFI_NATIVE_H
#include <quickjs.h>
#include <stdint.h>
int hao_ffi_type_code(const unsigned char *name);
int hao_ffi_parse_unsigned(const unsigned char *text, size_t length, uint64_t *output);
void hao_install_ffi_globals(JSContext *ctx, JSValue global);
void hao_ffi_cleanup(JSContext *ctx);
#endif
