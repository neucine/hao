#include <quickjs.h>
#include <uv.h>
#include <arpa/inet.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern uv_loop_t *hao_runtime_loop(JSContext *ctx);

typedef struct HaoServer HaoServer;
typedef struct HaoClient HaoClient;
typedef struct HaoWrite HaoWrite;

struct HaoServer {
    uv_tcp_t listener;
    JSContext *ctx;
    JSValue callback;
    int64_t id;
    unsigned max_connections;
    unsigned connections;
    uint64_t timeout_ms;
    int references;
    bool closing;
    HaoClient *clients;
    HaoServer *next;
};
struct HaoClient {
    uv_tcp_t tcp;
    uv_timer_t timer;
    HaoServer *server;
    int64_t id;
    int handles;
    bool closing;
    bool responding;
    HaoClient *next;
};
struct HaoWrite {
    uv_write_t request;
    HaoClient *client;
    char *bytes;
};

static HaoServer *servers;
static int64_t next_id = 1;

static HaoServer *find_server(int64_t id) {
    for (HaoServer *server = servers; server; server = server->next)
        if (server->id == id) return server;
    return NULL;
}
static HaoClient *find_client(int64_t id) {
    for (HaoServer *server = servers; server; server = server->next)
        for (HaoClient *client = server->clients; client; client = client->next)
            if (client->id == id) return client;
    return NULL;
}
static void unlink_server(HaoServer *server) {
    HaoServer **link = &servers;
    while (*link && *link != server) link = &(*link)->next;
    if (*link) *link = server->next;
}
static void release_server(HaoServer *server) {
    if (--server->references != 0) return;
    JS_FreeValue(server->ctx, server->callback);
    free(server);
}
static bool notify_client(HaoClient *client, JSValue value) {
    HaoServer *server = client->server;
    JSValue id = JS_NewInt64(server->ctx, client->id);
    JSValue args[] = { id, value };
    JSValue result = JS_Call(server->ctx, server->callback, JS_UNDEFINED, 2, args);
    JS_FreeValue(server->ctx, id);
    JS_FreeValue(server->ctx, value);
    if (JS_IsException(result)) {
        JSValue error = JS_GetException(server->ctx);
        JS_FreeValue(server->ctx, error);
        return false;
    }
    JS_FreeValue(server->ctx, result);
    return true;
}
static void client_closed(uv_handle_t *handle) {
    HaoClient *client = handle->data;
    if (--client->handles != 0) return;
    HaoServer *server = client->server;
    free(client);
    release_server(server);
}
static void close_client(HaoClient *client) {
    if (client->closing) return;
    client->closing = true;
    HaoServer *server = client->server;
    HaoClient **link = &server->clients;
    while (*link && *link != client) link = &(*link)->next;
    if (*link) *link = client->next;
    server->connections--;
    uv_read_stop((uv_stream_t *)&client->tcp);
    if (client->handles == 2) {
        uv_timer_stop(&client->timer);
        uv_close((uv_handle_t *)&client->timer, client_closed);
    }
    uv_close((uv_handle_t *)&client->tcp, client_closed);
    if (!server->closing) (void)notify_client(client, JS_NULL);
}
static void listener_closed(uv_handle_t *handle) {
    HaoServer *server = handle->data;
    release_server(server);
}
static void stop_server(HaoServer *server) {
    if (server->closing) return;
    server->closing = true;
    unlink_server(server);
    while (server->clients) close_client(server->clients);
    uv_close((uv_handle_t *)&server->listener, listener_closed);
}
void hao_http_server_cleanup(JSContext *ctx) {
    HaoServer *server = servers;
    while (server) {
        HaoServer *next = server->next;
        if (server->ctx == ctx) stop_server(server);
        server = next;
    }
}
static void client_timeout(uv_timer_t *timer) { close_client(timer->data); }
static void allocate_buffer(uv_handle_t *handle, size_t suggested, uv_buf_t *buf) {
    (void)handle; (void)suggested;
    buf->base = malloc(65536);
    buf->len = buf->base ? 65536 : 0;
}
static JSValue bytes_value(JSContext *ctx, const char *bytes, size_t length) {
    JSValue array_buffer = JS_NewArrayBufferCopy(ctx, (const uint8_t *)bytes, length);
    if (JS_IsException(array_buffer)) return array_buffer;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue constructor = JS_GetPropertyStr(ctx, global, "Uint8Array");
    JSValue value = JS_CallConstructor(ctx, constructor, 1, &array_buffer);
    JS_FreeValue(ctx, constructor);
    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, array_buffer);
    return value;
}
static void read_client(uv_stream_t *stream, ssize_t count, const uv_buf_t *buf) {
    HaoClient *client = stream->data;
    if (count < 0) {
        free(buf->base);
        close_client(client);
        return;
    }
    if (count == 0) { free(buf->base); return; }
    JSValue value = bytes_value(client->server->ctx, buf->base, (size_t)count);
    free(buf->base);
    if (JS_IsException(value)) {
        JSValue error = JS_GetException(client->server->ctx);
        JS_FreeValue(client->server->ctx, error);
        close_client(client);
        return;
    }
    if (!notify_client(client, value)) close_client(client);
}
static void accept_client(uv_stream_t *stream, int status) {
    if (status < 0) return;
    HaoServer *server = stream->data;
    HaoClient *client = calloc(1, sizeof(*client));
    if (!client) return;
    client->server = server;
    client->id = next_id++;
    if (uv_tcp_init(uv_handle_get_loop((uv_handle_t *)stream), &client->tcp) != 0) { free(client); return; }
    client->tcp.data = client;
    client->handles = 1;
    server->references++;
    server->connections++;
    client->next = server->clients;
    server->clients = client;
    if (uv_accept(stream, (uv_stream_t *)&client->tcp) != 0 || server->closing || server->connections > server->max_connections) {
        close_client(client);
        return;
    }
    if (uv_timer_init(uv_handle_get_loop((uv_handle_t *)stream), &client->timer) != 0) { close_client(client); return; }
    client->timer.data = client;
    client->handles = 2;
    if (uv_timer_start(&client->timer, client_timeout, server->timeout_ms, 0) != 0 ||
        uv_read_start((uv_stream_t *)&client->tcp, allocate_buffer, read_client) != 0) close_client(client);
}
static int64_t integer_property(JSContext *ctx, JSValueConst object, const char *key, int64_t fallback) {
    JSValue value = JS_GetPropertyStr(ctx, object, key);
    int64_t result = fallback;
    if (JS_IsNumber(value)) JS_ToInt64(ctx, &result, value);
    JS_FreeValue(ctx, value);
    return result;
}
static JSValue serve_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !JS_IsObject(argv[0]) || !JS_IsFunction(ctx, argv[1]))
        return JS_ThrowTypeError(ctx, "http.serve requires options and a callback");
    JSValue host_value = JS_GetPropertyStr(ctx, argv[0], "hostname");
    const char *hostname = JS_ToCString(ctx, host_value);
    int64_t port = integer_property(ctx, argv[0], "port", -1);
    int64_t max_connections = integer_property(ctx, argv[0], "maxConnections", -1);
    int64_t timeout_ms = integer_property(ctx, argv[0], "requestTimeoutMs", -1);
    struct sockaddr_in address;
    if (!hostname || port < 0 || port > 65535 || max_connections < 1 || max_connections > 1024 || timeout_ms < 1 || timeout_ms > 3600000 ||
        uv_ip4_addr(hostname, (int)port, &address) != 0) {
        if (hostname) JS_FreeCString(ctx, hostname);
        JS_FreeValue(ctx, host_value);
        return JS_ThrowTypeError(ctx, "invalid http.serve address or limits");
    }
    JS_FreeCString(ctx, hostname);
    JS_FreeValue(ctx, host_value);
    HaoServer *server = calloc(1, sizeof(*server));
    if (!server) return JS_ThrowOutOfMemory(ctx);
    server->ctx = ctx;
    server->callback = JS_DupValue(ctx, argv[1]);
    server->id = next_id++;
    server->max_connections = (unsigned)max_connections;
    server->timeout_ms = (uint64_t)timeout_ms;
    server->references = 1;
    uv_loop_t *loop = hao_runtime_loop(ctx);
    if (!loop || uv_tcp_init(loop, &server->listener) != 0) {
        JS_FreeValue(ctx, server->callback); free(server);
        return JS_ThrowInternalError(ctx, "unable to initialize HTTP server");
    }
    server->listener.data = server;
    if (uv_tcp_bind(&server->listener, (const struct sockaddr *)&address, 0) != 0 ||
        uv_listen((uv_stream_t *)&server->listener, 128, accept_client) != 0) {
        server->closing = true;
        uv_close((uv_handle_t *)&server->listener, listener_closed);
        return JS_ThrowInternalError(ctx, "unable to bind HTTP server");
    }
    struct sockaddr_storage bound;
    int bound_size = sizeof(bound);
    if (uv_tcp_getsockname(&server->listener, (struct sockaddr *)&bound, &bound_size) != 0) {
        server->closing = true;
        uv_close((uv_handle_t *)&server->listener, listener_closed);
        return JS_ThrowInternalError(ctx, "unable to inspect HTTP server port");
    }
    server->next = servers;
    servers = server;
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "id", JS_NewInt64(ctx, server->id));
    JS_SetPropertyStr(ctx, result, "port", JS_NewInt32(ctx, ntohs(((struct sockaddr_in *)&bound)->sin_port)));
    return result;
}
static JSValue stop_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc && JS_ToInt64(ctx, &id, argv[0]) == 0) {
        HaoServer *server = find_server(id);
        if (server && server->ctx == ctx) stop_server(server);
    }
    return JS_UNDEFINED;
}
static JSValue unref_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (!argc || JS_ToInt64(ctx, &id, argv[0]) < 0) return JS_ThrowTypeError(ctx, "HTTP server id required");
    HaoServer *server = find_server(id);
    if (!server || server->ctx != ctx || server->closing) return JS_ThrowTypeError(ctx, "invalid HTTP server id");
    uv_unref((uv_handle_t *)&server->listener);
    return JS_UNDEFINED;
}
static JSValue pause_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc && JS_ToInt64(ctx, &id, argv[0]) == 0) {
        HaoClient *client = find_client(id);
        if (client && client->server->ctx == ctx) uv_read_stop((uv_stream_t *)&client->tcp);
    }
    return JS_UNDEFINED;
}
static void wrote_client(uv_write_t *request, int status) {
    (void)status;
    HaoWrite *write = request->data;
    close_client(write->client);
    free(write->bytes);
    free(write);
}
static JSValue respond_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 2 || JS_ToInt64(ctx, &id, argv[0]) != 0) return JS_ThrowTypeError(ctx, "invalid HTTP client id");
    HaoClient *client = find_client(id);
    if (!client || client->server->ctx != ctx || client->responding) return JS_UNDEFINED;
    size_t offset = 0, length = 0, total = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, argv[1], &offset, &length, NULL);
    if (JS_IsException(buffer)) return buffer;
    uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
    if (!bytes || offset > total || length > total - offset) {
        JS_FreeValue(ctx, buffer);
        return JS_ThrowTypeError(ctx, "response must be Uint8Array");
    }
    HaoWrite *write = malloc(sizeof(*write));
    if (!write) { JS_FreeValue(ctx, buffer); return JS_ThrowOutOfMemory(ctx); }
    write->bytes = malloc(length ? length : 1);
    if (!write->bytes) { free(write); JS_FreeValue(ctx, buffer); return JS_ThrowOutOfMemory(ctx); }
    memcpy(write->bytes, bytes + offset, length);
    JS_FreeValue(ctx, buffer);
    write->client = client;
    write->request.data = write;
    uv_buf_t output = uv_buf_init(write->bytes, (unsigned int)length);
    client->responding = true;
    uv_read_stop((uv_stream_t *)&client->tcp);
    if (uv_write(&write->request, (uv_stream_t *)&client->tcp, &output, 1, wrote_client) != 0) {
        client->responding = false;
        free(write->bytes); free(write);
        close_client(client);
        return JS_ThrowInternalError(ctx, "HTTP response write failed");
    }
    return JS_UNDEFINED;
}
static JSValue encode_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (!argc) return JS_ThrowTypeError(ctx, "text required");
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, argv[0]);
    if (!text) return JS_EXCEPTION;
    JSValue result = bytes_value(ctx, text, length);
    JS_FreeCString(ctx, text);
    return result;
}
static JSValue decode_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (!argc) return JS_ThrowTypeError(ctx, "bytes required");
    size_t offset = 0, length = 0, total = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, argv[0], &offset, &length, NULL);
    if (JS_IsException(buffer)) return buffer;
    uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
    JSValue result = bytes && offset <= total && length <= total - offset
        ? JS_NewStringLen(ctx, (const char *)bytes + offset, length)
        : JS_ThrowTypeError(ctx, "bytes must be Uint8Array");
    JS_FreeValue(ctx, buffer);
    return result;
}
void hao_install_http_server_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_http_serveNative", JS_NewCFunction(ctx, serve_native, "serveNative", 2));
    JS_SetPropertyStr(ctx, global, "__hao_http_unrefServerNative", JS_NewCFunction(ctx, unref_native, "unrefServerNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_stopServerNative", JS_NewCFunction(ctx, stop_native, "stopServerNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_pauseClientNative", JS_NewCFunction(ctx, pause_native, "pauseClientNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_respondNative", JS_NewCFunction(ctx, respond_native, "respondNative", 2));
    JS_SetPropertyStr(ctx, global, "__hao_http_encodeTextNative", JS_NewCFunction(ctx, encode_native, "encodeTextNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_decodeTextNative", JS_NewCFunction(ctx, decode_native, "decodeTextNative", 1));
}
