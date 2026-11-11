#ifndef HAO_STD_HTTP_SERVER_UV_H
#define HAO_STD_HTTP_SERVER_UV_H
#include <quickjs.h>
int hao_http_server_valid_number(double value);
int hao_http_server_limits_error(double port, double max_connections, double timeout_ms);
void hao_install_http_server_globals(JSContext *ctx, JSValue global);
void hao_http_server_cleanup(JSContext *ctx);
#endif
