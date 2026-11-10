#include <quickjs.h>
#include <uv.h>
#include <curl/curl.h>
#include <CommonCrypto/CommonDigest.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern uv_loop_t *hao_runtime_loop(JSContext *ctx);

typedef struct HaoHeader {
    char *name;
    char *value;
    struct HaoHeader *next;
} HaoHeader;

typedef struct {
    unsigned char *body;
    size_t length, capacity, limit;
    HaoHeader *headers;
    HaoHeader *headers_tail;
    char status_text[128];
    int failed;
    int skip_body;
    FILE *download_file;
    CC_SHA256_CTX digest;
} HaoHttpResponse;

typedef struct {
    uv_work_t work;
    JSContext *ctx;
    JSValue resolve;
    JSValue reject;
    char *url;
    char *method;
    char *download_path;
    char *body;
    size_t body_length;
    bool has_body;
    bool manual_redirect;
    struct curl_slist *request_headers;
    HaoHttpResponse response;
    char *final_url;
    long status;
    char sha256[65];
    char error[256];
} HaoHttpJob;

static void free_headers(HaoHeader *header) {
    while (header) {
        HaoHeader *next = header->next;
        free(header->name);
        free(header->value);
        free(header);
        header = next;
    }
}
static void destroy_job(HaoHttpJob *job) {
    free(job->url);
    free(job->method);
    free(job->download_path);
    free(job->body);
    free(job->final_url);
    free(job->response.body);
    free_headers(job->response.headers);
    curl_slist_free_all(job->request_headers);
    JS_FreeValue(job->ctx, job->resolve);
    JS_FreeValue(job->ctx, job->reject);
    free(job);
}
static size_t receive_body(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (response->skip_body) return length;
    if (length > response->limit - response->length) { response->failed = 1; return 0; }
    if (response->download_file) {
        if (length && fwrite(data, 1, length, response->download_file) != length) { response->failed = 3; return 0; }
        CC_SHA256_Update(&response->digest, data, (CC_LONG)length);
        response->length += length;
        return length;
    }
    if (response->length + length > response->capacity) {
        size_t capacity = response->capacity ? response->capacity : 4096;
        while (capacity < response->length + length) {
            if (capacity > response->limit / 2) { capacity = response->limit; break; }
            capacity *= 2;
        }
        unsigned char *next = realloc(response->body, capacity);
        if (!next) { response->failed = 2; return 0; }
        response->body = next;
        response->capacity = capacity;
    }
    memcpy(response->body + response->length, data, length);
    response->length += length;
    return length;
}
static size_t receive_header(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length >= 5 && memcmp(data, "HTTP/", 5) == 0) {
        response->skip_body = 0;
        char *space = memchr(data, ' ', length);
        if (space) {
            long status = strtol(space + 1, NULL, 10);
            response->skip_body = (status >= 100 && status < 200) || (status >= 300 && status < 400);
        }
        free_headers(response->headers);
        response->headers = NULL;
        response->headers_tail = NULL;
        response->status_text[0] = 0;
        if (space) {
            char *reason = memchr(space + 1, ' ', (size_t)(data + length - space - 1));
            if (reason) {
                size_t n = (size_t)(data + length - reason - 1);
                while (n && (reason[n] == '\r' || reason[n] == '\n')) n--;
                if (n >= sizeof(response->status_text)) n = sizeof(response->status_text) - 1;
                memcpy(response->status_text, reason + 1, n);
                response->status_text[n] = 0;
            }
        }
        return length;
    }
    char *colon = memchr(data, ':', length);
    if (!colon || colon == data) return length;
    size_t name_length = (size_t)(colon - data);
    const char *value = colon + 1;
    size_t value_length = (size_t)(data + length - value);
    while (value_length && isspace((unsigned char)*value)) { value++; value_length--; }
    while (value_length && isspace((unsigned char)value[value_length - 1])) value_length--;
    HaoHeader *header = calloc(1, sizeof(*header));
    if (!header) { response->failed = 2; return 0; }
    header->name = malloc(name_length + 1);
    header->value = malloc(value_length + 1);
    if (!header->name || !header->value) {
        free_headers(header);
        response->failed = 2;
        return 0;
    }
    memcpy(header->name, data, name_length); header->name[name_length] = 0;
    memcpy(header->value, value, value_length); header->value[value_length] = 0;
    if (response->headers_tail) response->headers_tail->next = header;
    else response->headers = header;
    response->headers_tail = header;
    return length;
}
static void set_error(HaoHttpJob *job, const char *message) {
    snprintf(job->error, sizeof(job->error), "%s", message);
}
static void perform_http(uv_work_t *work) {
    HaoHttpJob *job = work->data;
    HaoHttpResponse *response = &job->response;
    CURL *curl = NULL;
    char *temporary_path = NULL;
    if (job->download_path) {
        size_t length = strlen(job->download_path);
        temporary_path = malloc(length + 17);
        if (!temporary_path) { set_error(job, "out of memory"); goto done; }
        snprintf(temporary_path, length + 17, "%s.hao-XXXXXX", job->download_path);
        int fd = mkstemp(temporary_path);
        if (fd < 0) { set_error(job, "unable to create download file"); goto done; }
        response->download_file = fdopen(fd, "wb");
        if (!response->download_file) { close(fd); set_error(job, "unable to open download file"); goto done; }
        CC_SHA256_Init(&response->digest);
    }
    curl = curl_easy_init();
    if (!curl) { set_error(job, "unable to initialize HTTP client"); goto done; }
    curl_easy_setopt(curl, CURLOPT_URL, job->url);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, job->method);
    if (strcmp(job->method, "HEAD") == 0) curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, job->manual_redirect ? 0L : 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive_body);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, receive_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, response);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 30000L);
    if (job->has_body) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, job->body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)job->body_length);
    }
    if (job->request_headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, job->request_headers);
    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        set_error(job, response->failed == 1 ? "http response exceeds maxBytes" : curl_easy_strerror(code));
        goto done;
    }
    char *effective_url = NULL;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &job->status);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
    job->final_url = strdup(effective_url ? effective_url : job->url);
    if (!job->final_url) { set_error(job, "out of memory"); goto done; }
    if (job->download_path) {
        if (job->status < 200 || job->status >= 300) { set_error(job, "http.download requires a successful response"); goto done; }
        if (fflush(response->download_file) != 0 || fsync(fileno(response->download_file)) != 0) {
            set_error(job, "unable to finish download file"); goto done;
        }
        if (fclose(response->download_file) != 0) {
            response->download_file = NULL;
            set_error(job, "unable to close download file"); goto done;
        }
        response->download_file = NULL;
        if (rename(temporary_path, job->download_path) != 0) {
            set_error(job, "unable to replace download destination"); goto done;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        const char digits[] = "0123456789abcdef";
        CC_SHA256_Final(digest, &response->digest);
        for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            job->sha256[i * 2] = digits[digest[i] >> 4];
            job->sha256[i * 2 + 1] = digits[digest[i] & 15];
        }
        job->sha256[64] = 0;
    }
 done:
    if (response->download_file) fclose(response->download_file);
    if (temporary_path) { unlink(temporary_path); free(temporary_path); }
    if (curl) curl_easy_cleanup(curl);
}
static JSValue make_response(HaoHttpJob *job) {
    JSContext *ctx = job->ctx;
    HaoHttpResponse *response = &job->response;
    JSValue result = JS_NewObject(ctx);
    JSValue headers = JS_NewObject(ctx);
    for (HaoHeader *header = response->headers; header; header = header->next)
        JS_SetPropertyStr(ctx, headers, header->name, JS_NewString(ctx, header->value));
    JS_SetPropertyStr(ctx, result, "status", JS_NewInt32(ctx, (int)job->status));
    JS_SetPropertyStr(ctx, result, "statusText", JS_NewString(ctx, response->status_text));
    JS_SetPropertyStr(ctx, result, "url", JS_NewString(ctx, job->final_url));
    JS_SetPropertyStr(ctx, result, "headers", headers);
    if (job->download_path) {
        JS_SetPropertyStr(ctx, result, "ok", JS_TRUE);
        JS_SetPropertyStr(ctx, result, "bytesWritten", JS_NewFloat64(ctx, (double)response->length));
        JS_SetPropertyStr(ctx, result, "sha256", JS_NewString(ctx, job->sha256));
    } else {
        JS_SetPropertyStr(ctx, result, "bodyText", JS_NewStringLen(ctx, (const char *)response->body, response->length));
        JSValue array_buffer = JS_NewArrayBufferCopy(ctx, response->body, response->length);
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue constructor = JS_GetPropertyStr(ctx, global, "Uint8Array");
        JSValue bytes = JS_CallConstructor(ctx, constructor, 1, &array_buffer);
        JS_SetPropertyStr(ctx, result, "bodyBytes", bytes);
        JS_FreeValue(ctx, constructor);
        JS_FreeValue(ctx, global);
        JS_FreeValue(ctx, array_buffer);
    }
    return result;
}
static void finish_http(uv_work_t *work, int status) {
    HaoHttpJob *job = work->data;
    JSContext *ctx = job->ctx;
    if (status < 0 && !job->error[0]) set_error(job, uv_strerror(status));
    JSValue value;
    JSValue callback;
    if (job->error[0]) {
        value = JS_NewError(ctx);
        JS_SetPropertyStr(ctx, value, "message", JS_NewString(ctx, job->error));
        callback = job->reject;
    } else {
        value = make_response(job);
        callback = job->resolve;
    }
    JSValue result = JS_Call(ctx, callback, JS_UNDEFINED, 1, &value);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, value);
    destroy_job(job);
}
static char *copy_property(JSContext *ctx, JSValueConst object, const char *name) {
    JSValue value = JS_GetPropertyStr(ctx, object, name);
    const char *text = JS_ToCString(ctx, value);
    char *copy = text ? strdup(text) : NULL;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, value);
    return copy;
}
static bool parse_options(HaoHttpJob *job, JSValueConst options) {
    JSContext *ctx = job->ctx;
    job->url = copy_property(ctx, options, "url");
    job->method = copy_property(ctx, options, "method");
    char *redirect = copy_property(ctx, options, "redirect");
    if (redirect) { job->manual_redirect = strcmp(redirect, "manual") == 0; free(redirect); }
    JSValue limit = JS_GetPropertyStr(ctx, options, "maxBytes");
    int64_t max_bytes = 0;
    JS_ToInt64(ctx, &max_bytes, limit);
    JS_FreeValue(ctx, limit);
    if (!job->url || !job->method || max_bytes < 1 || max_bytes > 1024 * 1024 * 1024) return false;
    job->response.limit = (size_t)max_bytes;
    JSValue path = JS_GetPropertyStr(ctx, options, "downloadPath");
    if (JS_IsString(path)) {
        const char *text = JS_ToCString(ctx, path);
        job->download_path = text ? strdup(text) : NULL;
        if (text) JS_FreeCString(ctx, text);
        if (!job->download_path) { JS_FreeValue(ctx, path); return false; }
    }
    JS_FreeValue(ctx, path);
    JSValue body = JS_GetPropertyStr(ctx, options, "body");
    if (JS_IsString(body)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, body);
        if (!text) { JS_FreeValue(ctx, body); return false; }
        job->body = malloc(length ? length : 1);
        if (job->body) memcpy(job->body, text, length);
        job->body_length = length;
        job->has_body = true;
        JS_FreeCString(ctx, text);
    } else if (JS_IsObject(body)) {
        size_t offset = 0, length = 0, total = 0;
        JSValue buffer = JS_GetTypedArrayBuffer(ctx, body, &offset, &length, NULL);
        if (JS_IsException(buffer)) { JS_FreeValue(ctx, body); return false; }
        uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
        if (!bytes || offset > total || length > total - offset) { JS_FreeValue(ctx, buffer); JS_FreeValue(ctx, body); return false; }
        job->body = malloc(length ? length : 1);
        if (job->body) memcpy(job->body, bytes + offset, length);
        job->body_length = length;
        job->has_body = true;
        JS_FreeValue(ctx, buffer);
    } else if (!JS_IsUndefined(body)) { JS_FreeValue(ctx, body); return false; }
    JS_FreeValue(ctx, body);
    if (job->has_body && !job->body) return false;
    JSValue headers = JS_GetPropertyStr(ctx, options, "headers");
    JSValue count_value = JS_GetPropertyStr(ctx, headers, "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    if (count > 128) { JS_FreeValue(ctx, headers); return false; }
    for (uint32_t i = 0; i < count; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, headers, i);
        JSValue name_value = JS_GetPropertyUint32(ctx, pair, 0);
        JSValue value_value = JS_GetPropertyUint32(ctx, pair, 1);
        const char *name = JS_ToCString(ctx, name_value);
        const char *value = JS_ToCString(ctx, value_value);
        if (!name || !value || strchr(name, '\r') || strchr(name, '\n') || strchr(value, '\r') || strchr(value, '\n')) {
            if (name) JS_FreeCString(ctx, name);
            if (value) JS_FreeCString(ctx, value);
            JS_FreeValue(ctx, name_value); JS_FreeValue(ctx, value_value); JS_FreeValue(ctx, pair); JS_FreeValue(ctx, headers);
            return false;
        }
        size_t length = strlen(name) + strlen(value) + 3;
        char *line = malloc(length);
        bool appended = false;
        if (line) {
            snprintf(line, length, "%s: %s", name, value);
            struct curl_slist *next = curl_slist_append(job->request_headers, line);
            if (next) { job->request_headers = next; appended = true; }
            free(line);
        }
        JS_FreeCString(ctx, name); JS_FreeCString(ctx, value);
        JS_FreeValue(ctx, name_value); JS_FreeValue(ctx, value_value); JS_FreeValue(ctx, pair);
        if (!appended) { JS_FreeValue(ctx, headers); return false; }
    }
    JS_FreeValue(ctx, headers);
    return true;
}
static JSValue request_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) return JS_ThrowTypeError(ctx, "http request options required");
    HaoHttpJob *job = calloc(1, sizeof(*job));
    if (!job) return JS_ThrowOutOfMemory(ctx);
    job->ctx = ctx;
    job->resolve = JS_UNDEFINED;
    job->reject = JS_UNDEFINED;
    if (!parse_options(job, argv[0])) {
        destroy_job(job);
        return JS_ThrowTypeError(ctx, "invalid http request options");
    }
    JSValue functions[2];
    JSValue promise = JS_NewPromiseCapability(ctx, functions);
    if (JS_IsException(promise)) { destroy_job(job); return promise; }
    job->resolve = functions[0];
    job->reject = functions[1];
    job->work.data = job;
    uv_loop_t *loop = hao_runtime_loop(ctx);
    int status = loop ? uv_queue_work(loop, &job->work, perform_http, finish_http) : UV_EINVAL;
    if (status != 0) {
        JS_FreeValue(ctx, promise);
        destroy_job(job);
        return JS_ThrowInternalError(ctx, "unable to queue HTTP request");
    }
    return promise;
}
void hao_install_http_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_http_requestNative", JS_NewCFunction(ctx, request_native, "requestNative", 1));
}
