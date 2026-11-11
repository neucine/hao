#ifndef HAO_STD_HTTP_SERVER_UV_H
#define HAO_STD_HTTP_SERVER_UV_H
#include <quickjs.h>
void hao_install_http_server_globals(JSContext *ctx, JSValue global);
void hao_http_server_cleanup(JSContext *ctx);
#endif
