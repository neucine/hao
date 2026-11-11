#include "../../runtime_host.h"
#include "../../runtime_allocator.h"
#include <uv.h>
#include <curl/curl.h>
#include <openssl/evp.h>
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
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
    bool manual_redirect;
    FILE *download_file;
    EVP_MD_CTX *digest;
} HaoHttpResponse;

typedef struct {
    uv_work_t work;
    JSContext *ctx;
    JSValue resolve;
    JSValue reject;
    JSValue trace_context;
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
    bool legacy_error;
} HaoHttpJob;

static void free_headers(HaoHeader *header) {
    while (header) {
        HaoHeader *next = header->next;
        hao_free(header->name);
        hao_free(header->value);
        hao_free(header);
        header = next;
    }
}
static void destroy_job(HaoHttpJob *job) {
    hao_free(job->url);
    hao_free(job->method);
    hao_free(job->download_path);
    hao_free(job->body);
    hao_free(job->final_url);
    hao_free(job->response.body);
    free_headers(job->response.headers);
    curl_slist_free_all(job->request_headers);
    JS_FreeValue(job->ctx, job->resolve);
    JS_FreeValue(job->ctx, job->reject);
    JS_FreeValue(job->ctx, job->trace_context);
    hao_free(job);
}
static JSValue telemetry_enter_context(JSContext *ctx, JSValueConst context) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue enter = JS_GetPropertyStr(ctx, global, "__hao_telemetry_enterContext");
    JSValue previous = JS_UNDEFINED;
    if (JS_IsFunction(ctx, enter)) previous = JS_Call(ctx, enter, global, 1, &context);
    JS_FreeValue(ctx, enter);
    JS_FreeValue(ctx, global);
    return previous;
}
static void retain_callback_error(HaoRuntime *host, JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    if (!host->has_callback_error) {
        host->callback_error = error;
        host->has_callback_error = true;
    } else {
        JS_FreeValue(ctx, error);
    }
}
static size_t receive_body(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (response->skip_body) return length;
    if (length > response->limit - response->length) { response->failed = 1; return 0; }
    if (response->download_file) {
        if (length && fwrite(data, 1, length, response->download_file) != length) { response->failed = 3; return 0; }
        if (EVP_DigestUpdate(response->digest, data, length) != 1) { response->failed = 3; return 0; }
        response->length += length;
        return length;
    }
    if (response->length + length > response->capacity) {
        size_t capacity = response->capacity ? response->capacity : 4096;
        while (capacity < response->length + length) {
            if (capacity > response->limit / 2) { capacity = response->limit; break; }
            capacity *= 2;
        }
        unsigned char *next = hao_realloc(response->body, capacity);
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
            response->skip_body = (status >= 100 && status < 200) ||
                (!response->manual_redirect && status >= 300 && status < 400);
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
    HaoHeader *header = hao_calloc(1, sizeof(*header));
    if (!header) { response->failed = 2; return 0; }
    header->name = hao_alloc(name_length + 1);
    header->value = hao_alloc(value_length + 1);
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
static void set_legacy_error(HaoHttpJob *job, const char *name) {
    snprintf(job->error, sizeof(job->error), "http.request error: %s", name);
    job->legacy_error = true;
}
static void perform_http(uv_work_t *work) {
    HaoHttpJob *job = work->data;
    HaoHttpResponse *response = &job->response;
    response->manual_redirect = job->manual_redirect;
    CURL *curl = NULL;
    char *temporary_path = NULL;
    if (job->download_path) {
        size_t length = strlen(job->download_path);
        temporary_path = hao_alloc(length + 17);
        if (!temporary_path) { set_error(job, "out of memory"); goto done; }
        snprintf(temporary_path, length + 17, "%s.hao-XXXXXX", job->download_path);
        int fd = mkstemp(temporary_path);
        if (fd < 0) { set_error(job, "unable to create download file"); goto done; }
        response->download_file = fdopen(fd, "wb");
        if (!response->download_file) { close(fd); set_error(job, "unable to open download file"); goto done; }
        response->digest = EVP_MD_CTX_new();
        if (!response->digest || EVP_DigestInit_ex(response->digest, EVP_sha256(), NULL) != 1) {
            set_error(job, "unable to initialize download digest"); goto done;
        }
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
        bool has_content_type = false;
        for (struct curl_slist *header = job->request_headers; header; header = header->next) {
            if (strncasecmp(header->data, "Content-Type:", 13) == 0) {
                has_content_type = true;
                break;
            }
        }
        if (!has_content_type) {
            struct curl_slist *headers = curl_slist_append(job->request_headers, "Content-Type:");
            if (!headers) { set_error(job, "out of memory"); goto done; }
            job->request_headers = headers;
        }
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, job->body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)job->body_length);
    }
    if (job->request_headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, job->request_headers);
    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        if (response->failed == 1) {
            set_legacy_error(job, job->download_path ? "DownloadTooLarge" : "ResponseTooLarge");
            goto done;
        }
        if (code == CURLE_PARTIAL_FILE) {
            if (job->download_path) {
                set_legacy_error(job, "TruncatedDownload");
                goto done;
            }
        } else {
            set_error(job, curl_easy_strerror(code));
            goto done;
        }
    }
    char *effective_url = NULL;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &job->status);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
    job->final_url = hao_strdup(effective_url ? effective_url : job->url);
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
        unsigned char digest[32]; unsigned int digest_length = 0;
        const char digits[] = "0123456789abcdef";
        if (EVP_DigestFinal_ex(response->digest, digest, &digest_length) != 1 || digest_length != 32) {
            set_error(job, "unable to finish download digest"); goto done;
        }
        if (rename(temporary_path, job->download_path) != 0) {
            set_error(job, "unable to replace download destination"); goto done;
        }
        for (size_t i = 0; i < 32; i++) {
            job->sha256[i * 2] = digits[digest[i] >> 4];
            job->sha256[i * 2 + 1] = digits[digest[i] & 15];
        }
        job->sha256[64] = 0;
    }
 done:
    EVP_MD_CTX_free(response->digest);
    response->digest = NULL;
    if (response->download_file) fclose(response->download_file);
    if (temporary_path) { unlink(temporary_path); hao_free(temporary_path); }
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
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (status < 0 && !job->error[0]) set_error(job, uv_strerror(status));
    JSValue value;
    JSValue callback;
    if (job->error[0]) {
        if (job->legacy_error) {
            JS_ThrowInternalError(ctx, "%s", job->error);
            value = JS_GetException(ctx);
        } else {
            value = JS_NewError(ctx);
            JS_SetPropertyStr(ctx, value, "message", JS_NewString(ctx, job->error));
        }
        callback = job->reject;
    } else {
        value = make_response(job);
        callback = job->resolve;
    }
    JSValue previous = JS_UNDEFINED;
    if (!JS_IsUndefined(job->trace_context)) {
        previous = telemetry_enter_context(ctx, job->trace_context);
        if (JS_IsException(previous)) retain_callback_error(host, ctx);
    }
    JSValue result = JS_Call(ctx, callback, JS_UNDEFINED, 1, &value);
    if (JS_IsException(result)) retain_callback_error(host, ctx);
    if (!JS_IsUndefined(previous) && !JS_IsException(previous)) {
        JSValue restored = telemetry_enter_context(ctx, previous);
        if (JS_IsException(restored)) retain_callback_error(host, ctx);
        JS_FreeValue(ctx, restored);
    }
    JS_FreeValue(ctx, previous);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, value);
    destroy_job(job);
}
static char *copy_property(JSContext *ctx, JSValueConst object, const char *name) {
    JSValue value = JS_GetPropertyStr(ctx, object, name);
    const char *text = JS_ToCString(ctx, value);
    char *copy = text ? hao_strdup(text) : NULL;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, value);
    return copy;
}
static bool valid_method(const char *method) {
    static const char *const methods[] = {
        "GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH", "QUERY"
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        if (strcmp(method, methods[i]) == 0) return true;
    }
    return false;
}
static bool parse_options(HaoHttpJob *job, JSValueConst options) {
    JSContext *ctx = job->ctx;
    job->url = copy_property(ctx, options, "url");
    job->method = copy_property(ctx, options, "method");
    char *redirect = copy_property(ctx, options, "redirect");
    if (redirect) { job->manual_redirect = strcmp(redirect, "manual") == 0; hao_free(redirect); }
    JSValue limit = JS_GetPropertyStr(ctx, options, "maxBytes");
    double max_bytes = 1024.0 * 1024.0 * 1024.0;
    if (!JS_IsUndefined(limit) &&
        (JS_ToFloat64(ctx, &max_bytes, limit) < 0 || !isfinite(max_bytes) ||
         max_bytes < 1 || max_bytes > 9007199254740991.0 || floor(max_bytes) != max_bytes ||
         max_bytes >= (double)SIZE_MAX)) {
        JS_FreeValue(ctx, limit);
        return false;
    }
    JS_FreeValue(ctx, limit);
    if (!job->url || !job->method || !valid_method(job->method)) return false;
    job->response.limit = (size_t)max_bytes;
    JSValue path = JS_GetPropertyStr(ctx, options, "downloadPath");
    if (!JS_IsUndefined(path) && !JS_IsNull(path)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, path);
        if (text && length && !memchr(text, 0, length)) job->download_path = hao_strdup(text);
        if (text) JS_FreeCString(ctx, text);
        if (!job->download_path) { JS_FreeValue(ctx, path); return false; }
    }
    JS_FreeValue(ctx, path);
    JSValue body = JS_GetPropertyStr(ctx, options, "body");
    if (JS_IsString(body)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, body);
        if (!text) { JS_FreeValue(ctx, body); return false; }
        job->body = hao_alloc(length ? length : 1);
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
        job->body = hao_alloc(length ? length : 1);
        if (job->body) memcpy(job->body, bytes + offset, length);
        job->body_length = length;
        job->has_body = true;
        JS_FreeValue(ctx, buffer);
    } else if (!JS_IsUndefined(body) && !JS_IsNull(body)) { JS_FreeValue(ctx, body); return false; }
    JS_FreeValue(ctx, body);
    if (job->has_body && !job->body) return false;
    if (job->download_path && (strcmp(job->method, "GET") != 0 || job->has_body)) return false;
    JSValue headers = JS_GetPropertyStr(ctx, options, "headers");
    if (JS_IsUndefined(headers) || JS_IsNull(headers)) { JS_FreeValue(ctx, headers); return true; }
    if (!JS_IsObject(headers)) { JS_FreeValue(ctx, headers); return false; }
    JSValue count_value = JS_GetPropertyStr(ctx, headers, "length");
    int32_t count = 0;
    int count_status = JS_ToInt32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    if (count_status < 0 || count < 0) { JS_FreeValue(ctx, headers); return false; }
    for (int32_t i = 0; i < count; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, headers, i);
        if (!JS_IsObject(pair)) { JS_FreeValue(ctx, pair); JS_FreeValue(ctx, headers); return false; }
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
        char *line = hao_alloc(length);
        bool appended = false;
        if (line) {
            snprintf(line, length, "%s: %s", name, value);
            struct curl_slist *next = curl_slist_append(job->request_headers, line);
            if (next) { job->request_headers = next; appended = true; }
            hao_free(line);
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
    HaoHttpJob *job = hao_calloc(1, sizeof(*job));
    if (!job) return JS_ThrowOutOfMemory(ctx);
    job->ctx = ctx;
    job->resolve = JS_UNDEFINED;
    job->reject = JS_UNDEFINED;
    job->trace_context = JS_UNDEFINED;
    if (!parse_options(job, argv[0])) {
        destroy_job(job);
        return JS_ThrowTypeError(ctx, "http.request options are invalid");
    }
    JSValue functions[2];
    JSValue promise = JS_NewPromiseCapability(ctx, functions);
    if (JS_IsException(promise)) { destroy_job(job); return promise; }
    job->resolve = functions[0];
    job->reject = functions[1];
    job->trace_context = JS_GetPropertyStr(ctx, argv[0], "__haoTraceContext");
    if (JS_IsException(job->trace_context)) {
        JS_FreeValue(ctx, promise);
        destroy_job(job);
        return JS_EXCEPTION;
    }
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
