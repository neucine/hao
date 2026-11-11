#ifndef HAO_STD_HTTP_NATIVE_H
#define HAO_STD_HTTP_NATIVE_H
#include <quickjs.h>
int hao_http_valid_method(const unsigned char *method);
int hao_http_url_error(const unsigned char *url);
unsigned char *hao_http_transport_url(const unsigned char *url);
void hao_install_http_globals(JSContext *ctx, JSValue global);
#endif
