#ifndef HAO_JS_ADDON_NATIVE_H
#define HAO_JS_ADDON_NATIVE_H
#include <quickjs.h>
JSModuleDef *hao_load_addon(JSContext *ctx, const char *name);
void hao_addon_cleanup(JSContext *ctx);
#endif
