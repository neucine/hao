#include <quickjs.h>
#include <curl/curl.h>
#include <CommonCrypto/CommonDigest.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    unsigned char *body;
    size_t length, capacity, limit;
    JSContext *ctx;
    JSValue headers;
    char status_text[128];
    int failed;
    FILE *download_file;
    CC_SHA256_CTX digest;
    int skip_body;
} HaoHttpResponse;

static size_t hao_http_body(char *data, size_t size, size_t count, void *opaque) {
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

static size_t hao_http_header(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length >= 5 && memcmp(data, "HTTP/", 5) == 0) {
        response->skip_body = 0;
        char *status_start = memchr(data, ' ', length);
        if (status_start && data + length - status_start >= 4) {
            long status = strtol(status_start + 1, NULL, 10);
            response->skip_body = status >= 100 && status < 200 || status >= 300 && status < 400;
        }
        JS_FreeValue(response->ctx, response->headers);
        response->headers = JS_NewObject(response->ctx);
        char *space = memchr(data, ' ', length);
        if (space) {
            char *reason = memchr(space + 1, ' ', (size_t)(data + length - space - 1));
            if (reason) {
                size_t n = (size_t)(data + length - reason - 1);
                while (n && (reason[1 + n - 1] == '\r' || reason[1 + n - 1] == '\n')) n--;
                if (n >= sizeof(response->status_text)) n = sizeof(response->status_text) - 1;
                memcpy(response->status_text, reason + 1, n);
                response->status_text[n] = 0;
            }
        }
        return length;
    }
    char *colon = memchr(data, ':', length);
    if (!colon || colon == data) return length;
    size_t name_len = (size_t)(colon - data);
    char *name = malloc(name_len + 1);
    if (!name) return 0;
    memcpy(name, data, name_len); name[name_len] = 0;
    const char *value = colon + 1;
    size_t value_len = (size_t)(data + length - value);
    while (value_len && isspace((unsigned char)*value)) { value++; value_len--; }
    while (value_len && isspace((unsigned char)value[value_len - 1])) value_len--;
    JS_SetPropertyStr(response->ctx, response->headers, name, JS_NewStringLen(response->ctx, value, value_len));
    free(name);
    return length;
}

static JSValue hao_http_request(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) return JS_ThrowTypeError(ctx, "http request options required");
    JSValue url_value = JS_GetPropertyStr(ctx, argv[0], "url");
    JSValue method_value = JS_GetPropertyStr(ctx, argv[0], "method");
    JSValue redirect_value = JS_GetPropertyStr(ctx, argv[0], "redirect");
    JSValue max_value = JS_GetPropertyStr(ctx, argv[0], "maxBytes");
    JSValue body_value = JS_GetPropertyStr(ctx, argv[0], "body");
    JSValue headers_value = JS_GetPropertyStr(ctx, argv[0], "headers");
    JSValue download_value = JS_GetPropertyStr(ctx, argv[0], "downloadPath");
    const char *url = JS_ToCString(ctx, url_value);
    const char *method = JS_ToCString(ctx, method_value);
    const char *redirect = JS_ToCString(ctx, redirect_value);
    int64_t max_bytes = 0;
    JS_ToInt64(ctx, &max_bytes, max_value);
    CURL *curl = NULL;
    struct curl_slist *headers = NULL;
    const char *body_text = NULL;
    size_t body_length = 0;
    JSValue body_buffer = JS_UNDEFINED;
    const char *download_path = JS_IsString(download_value) ? JS_ToCString(ctx, download_value) : NULL;
    char *temporary_path = NULL;
    HaoHttpResponse response = { .limit = max_bytes > 0 ? (size_t)max_bytes : 0, .ctx = ctx, .headers = JS_NewObject(ctx) };
    JSValue result = JS_EXCEPTION;
    if (!url || !method || !redirect || !response.limit) goto done;
    if (download_path) {
        size_t path_length = strlen(download_path);
        temporary_path = malloc(path_length + 17);
        if (!temporary_path) { result = JS_ThrowOutOfMemory(ctx); goto done; }
        snprintf(temporary_path, path_length + 17, "%s.hao-XXXXXX", download_path);
        int fd = mkstemp(temporary_path);
        if (fd < 0) { result = JS_ThrowInternalError(ctx, "unable to create download file"); goto done; }
        response.download_file = fdopen(fd, "wb");
        if (!response.download_file) { close(fd); result = JS_ThrowInternalError(ctx, "unable to open download file"); goto done; }
        CC_SHA256_Init(&response.digest);
    }
    curl = curl_easy_init();
    if (!curl) goto done;
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, strcmp(redirect, "manual") == 0 ? 0L : 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, hao_http_body);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, hao_http_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &response);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 30000L);
    if (JS_IsString(body_value)) {
        body_text = JS_ToCStringLen(ctx, &body_length, body_value);
    } else if (JS_IsObject(body_value)) {
        size_t offset = 0, byte_length = 0, total = 0;
        body_buffer = JS_GetTypedArrayBuffer(ctx, body_value, &offset, &byte_length, NULL);
        if (!JS_IsException(body_buffer)) {
            uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, body_buffer);
            if (bytes && offset <= total && byte_length <= total - offset) {
                body_text = (const char *)(bytes + offset); body_length = byte_length;
            }
        }
    }
    if (!JS_IsUndefined(body_value) && !body_text) goto done;
    if (body_text) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body_text);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
    }
    uint32_t header_count = 0;
    JSValue header_length = JS_GetPropertyStr(ctx, headers_value, "length");
    JS_ToUint32(ctx, &header_count, header_length);
    JS_FreeValue(ctx, header_length);
    if (header_count > 128) {
        result = JS_ThrowTypeError(ctx, "http.request accepts at most 128 headers");
        goto done;
    }
    for (uint32_t i = 0; i < header_count; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, headers_value, i);
        JSValue key_value = JS_GetPropertyUint32(ctx, pair, 0);
        JSValue value_value = JS_GetPropertyUint32(ctx, pair, 1);
        const char *key = JS_ToCString(ctx, key_value);
        const char *value = JS_ToCString(ctx, value_value);
        if (key && value && !strchr(key, '\r') && !strchr(key, '\n') && !strchr(value, '\r') && !strchr(value, '\n')) {
            size_t n = strlen(key) + strlen(value) + 3;
            char *line = malloc(n);
            if (line) {
                snprintf(line, n, "%s: %s", key, value);
                headers = curl_slist_append(headers, line);
                free(line);
            }
        }
        if (key) JS_FreeCString(ctx, key);
        if (value) JS_FreeCString(ctx, value);
        JS_FreeValue(ctx, key_value); JS_FreeValue(ctx, value_value); JS_FreeValue(ctx, pair);
    }
    if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        result = JS_ThrowInternalError(ctx, "%s", response.failed == 1 ? "http response exceeds maxBytes" : curl_easy_strerror(code));
        goto done;
    }
    long status = 0;
    char *effective_url = NULL;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
    if (download_path) {
        if (status < 200 || status >= 300) {
            result = JS_ThrowInternalError(ctx, "http.download requires a successful response");
            goto done;
        }
        if (fflush(response.download_file) != 0 || fsync(fileno(response.download_file)) != 0) {
            result = JS_ThrowInternalError(ctx, "unable to finish download file");
            goto done;
        }
        if (fclose(response.download_file) != 0) {
            response.download_file = NULL;
            result = JS_ThrowInternalError(ctx, "unable to close download file");
            goto done;
        }
        response.download_file = NULL;
        if (rename(temporary_path, download_path) != 0) {
            result = JS_ThrowInternalError(ctx, "unable to replace download destination");
            goto done;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        const char digits[] = "0123456789abcdef";
        CC_SHA256_Final(digest, &response.digest);
        for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            hex[i * 2] = digits[digest[i] >> 4];
            hex[i * 2 + 1] = digits[digest[i] & 15];
        }
        hex[sizeof(hex) - 1] = 0;
        result = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, result, "status", JS_NewInt32(ctx, (int)status));
        JS_SetPropertyStr(ctx, result, "statusText", JS_NewString(ctx, response.status_text));
        JS_SetPropertyStr(ctx, result, "ok", JS_TRUE);
        JS_SetPropertyStr(ctx, result, "headers", JS_DupValue(ctx, response.headers));
        JS_SetPropertyStr(ctx, result, "url", JS_NewString(ctx, effective_url ? effective_url : url));
        JS_SetPropertyStr(ctx, result, "bytesWritten", JS_NewFloat64(ctx, (double)response.length));
        JS_SetPropertyStr(ctx, result, "sha256", JS_NewString(ctx, hex));
        goto done;
    }
    result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "status", JS_NewInt32(ctx, (int)status));
    JS_SetPropertyStr(ctx, result, "statusText", JS_NewString(ctx, response.status_text));
    JS_SetPropertyStr(ctx, result, "url", JS_NewString(ctx, effective_url ? effective_url : url));
    JS_SetPropertyStr(ctx, result, "headers", JS_DupValue(ctx, response.headers));
    JS_SetPropertyStr(ctx, result, "bodyText", JS_NewStringLen(ctx, (const char *)response.body, response.length));
    JSValue array_buffer = JS_NewArrayBufferCopy(ctx, response.body, response.length);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue uint8_array = JS_GetPropertyStr(ctx, global, "Uint8Array");
    JSValue args[] = { array_buffer };
    JSValue bytes = JS_CallConstructor(ctx, uint8_array, 1, args);
    JS_SetPropertyStr(ctx, result, "bodyBytes", bytes);
    JS_FreeValue(ctx, array_buffer); JS_FreeValue(ctx, uint8_array); JS_FreeValue(ctx, global);
 done:
    if (response.download_file) fclose(response.download_file);
    if (temporary_path) { unlink(temporary_path); free(temporary_path); }
    if (download_path) JS_FreeCString(ctx, download_path);
    if (body_text && JS_IsString(body_value)) JS_FreeCString(ctx, body_text);
    if (url) JS_FreeCString(ctx, url);
    if (method) JS_FreeCString(ctx, method);
    if (redirect) JS_FreeCString(ctx, redirect);
    if (curl) curl_easy_cleanup(curl);
    if (headers) curl_slist_free_all(headers);
    free(response.body);
    JS_FreeValue(ctx, response.headers);
    JS_FreeValue(ctx, url_value); JS_FreeValue(ctx, method_value); JS_FreeValue(ctx, redirect_value);
    JS_FreeValue(ctx, max_value); JS_FreeValue(ctx, body_value); JS_FreeValue(ctx, body_buffer); JS_FreeValue(ctx, headers_value); JS_FreeValue(ctx, download_value);
    return result;
}

void hao_install_http_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_http_requestNative", JS_NewCFunction(ctx, hao_http_request, "requestNative", 1));
}
