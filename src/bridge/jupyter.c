#include "support.h"
#include <openssl/evp.h>
#include <openssl/params.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zmq.h>

/* ZeroMQ transport and multipart framing. */
enum { HAO_SHELL = 3, HAO_CONTROL = 2, HAO_IOPUB = 4, HAO_HEARTBEAT = 1 };
enum { HAO_HEADER = 1, HAO_CONTENT = 2 };
enum { HAO_MAX_FRAME = 1024 * 1024, HAO_MAX_IDENTITIES = 32 };

typedef struct {
    char *data;
    size_t length;
} HaoFrame;

typedef struct {
    void *context;
    void *shell, *control, *iopub, *stdin_socket, *heartbeat;
    char *key;
    size_t key_length;
    char session[33];
    HaoFrame identities[HAO_MAX_IDENTITIES];
    size_t identity_count;
    HaoFrame header, content;
    int incoming_channel;
} HaoWire;

static int hmac_sha256(const void *key, size_t key_length,
                       const void *parts[4], const size_t lengths[4],
                       unsigned char digest[32]) {
    EVP_MAC *mac = EVP_MAC_fetch(NULL, "HMAC", NULL);
    if (!mac) return -1;
    EVP_MAC_CTX *context = EVP_MAC_CTX_new(mac);
    EVP_MAC_free(mac);
    if (!context) return -1;
    char algorithm[] = "SHA256";
    OSSL_PARAM params[] = { OSSL_PARAM_utf8_string("digest", algorithm, 0), OSSL_PARAM_END };
    int status = EVP_MAC_init(context, key, key_length, params);
    for (size_t i = 0; status == 1 && i < 4; i++)
        status = EVP_MAC_update(context, parts[i], lengths[i]);
    size_t digest_length = 0;
    if (status == 1) status = EVP_MAC_final(context, digest, &digest_length, 32);
    EVP_MAC_CTX_free(context);
    return status == 1 && digest_length == 32 ? 0 : -1;
}

static char *copy_text(const unsigned char *data, size_t length) {
    if ((!data && length) || length > HAO_MAX_FRAME) return NULL;
    char *out = hao_alloc(length + 1);
    if (!out) return NULL;
    if (length) memcpy(out, data, length);
    out[length] = 0;
    return out;
}

static void clear_message(HaoWire *wire) {
    for (size_t i = 0; i < wire->identity_count; i++) hao_free(wire->identities[i].data);
    wire->identity_count = 0;
    hao_free(wire->header.data); hao_free(wire->content.data);
    wire->header = (HaoFrame){0}; wire->content = (HaoFrame){0};
    wire->incoming_channel = 0;
}

static void random_id(char out[33]) {
    static const char hex[] = "0123456789abcdef";
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    for (size_t i = 0; i < sizeof(bytes); i++) {
        out[i * 2] = hex[bytes[i] >> 4];
        out[i * 2 + 1] = hex[bytes[i] & 15];
    }
    out[32] = 0;
}

static int bind_socket(void **out, void *context, int kind, const char *transport,
                       const char *ip, uint16_t port) {
    char endpoint[512];
    int length = snprintf(endpoint, sizeof(endpoint), "%s://%s:%u", transport, ip, port);
    if (length <= 0 || (size_t)length >= sizeof(endpoint)) return -1;
    *out = zmq_socket(context, kind);
    if (!*out) return -1;
    int linger = 1000;
    if (zmq_setsockopt(*out, ZMQ_LINGER, &linger, sizeof(linger)) < 0) return -1;
    return zmq_bind(*out, endpoint);
}

void hao_jupyter_wire_close(uintptr_t handle) {
    HaoWire *wire = (HaoWire *)handle;
    if (!wire) return;
    clear_message(wire);
    if (wire->shell) zmq_close(wire->shell);
    if (wire->control) zmq_close(wire->control);
    if (wire->iopub) zmq_close(wire->iopub);
    if (wire->stdin_socket) zmq_close(wire->stdin_socket);
    if (wire->heartbeat) zmq_close(wire->heartbeat);
    if (wire->context) zmq_ctx_term(wire->context);
    hao_free(wire->key); hao_free(wire);
}

uintptr_t hao_jupyter_wire_open(const unsigned char *transport_bytes, size_t transport_len,
    const unsigned char *ip_bytes, size_t ip_len, uint16_t shell_port,
    uint16_t control_port, uint16_t iopub_port, uint16_t stdin_port, uint16_t hb_port,
    const unsigned char *key_bytes, size_t key_len) {
    if (!transport_len || transport_len > 64 || !ip_len || ip_len > 255 || key_len > 4096) return 0;
    char *transport = copy_text(transport_bytes, transport_len);
    char *ip = copy_text(ip_bytes, ip_len);
    if (!transport || !ip || strchr(transport, '\0') != transport + transport_len ||
        strchr(ip, '\0') != ip + ip_len) { hao_free(transport); hao_free(ip); return 0; }
    HaoWire *wire = hao_calloc(1, sizeof(*wire));
    if (!wire) { hao_free(transport); hao_free(ip); return 0; }
    wire->key = copy_text(key_bytes, key_len);
    wire->key_length = key_len;
    wire->context = zmq_ctx_new();
    random_id(wire->session);
    int status = wire->context && wire->key &&
        bind_socket(&wire->shell, wire->context, ZMQ_ROUTER, transport, ip, shell_port) == 0 &&
        bind_socket(&wire->control, wire->context, ZMQ_ROUTER, transport, ip, control_port) == 0 &&
        bind_socket(&wire->iopub, wire->context, ZMQ_PUB, transport, ip, iopub_port) == 0 &&
        bind_socket(&wire->stdin_socket, wire->context, ZMQ_ROUTER, transport, ip, stdin_port) == 0 &&
        bind_socket(&wire->heartbeat, wire->context, ZMQ_REP, transport, ip, hb_port) == 0;
    hao_free(transport); hao_free(ip);
    if (!status) { hao_jupyter_wire_close((uintptr_t)wire); return 0; }
    return (uintptr_t)wire;
}

static int read_frame(void *socket, HaoFrame *out, int *more) {
    zmq_msg_t message;
    if (zmq_msg_init(&message) < 0) return -1;
    int size = zmq_msg_recv(&message, socket, 0);
    *more = size < 0 ? 0 : zmq_msg_more(&message);
    if (size < 0 || size > HAO_MAX_FRAME) { zmq_msg_close(&message); return -1; }
    out->data = copy_text(zmq_msg_data(&message), (size_t)size);
    out->length = (size_t)size;
    zmq_msg_close(&message);
    return out->data ? 0 : -1;
}

static void discard_remaining(void *socket, int more) {
    while (more) {
        zmq_msg_t message;
        if (zmq_msg_init(&message) < 0) return;
        if (zmq_msg_recv(&message, socket, 0) < 0) { zmq_msg_close(&message); return; }
        more = zmq_msg_more(&message);
        zmq_msg_close(&message);
    }
}

static size_t signature(const HaoWire *wire, const HaoFrame frames[4], char out[65]) {
    if (!wire->key_length) { out[0] = 0; return 0; }
    const void *parts[4]; size_t lengths[4];
    for (size_t i = 0; i < 4; i++) { parts[i] = frames[i].data; lengths[i] = frames[i].length; }
    uint8_t digest[32];
    if (hmac_sha256(wire->key, wire->key_length, parts, lengths, digest) != 0) return SIZE_MAX;
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; i++) { out[i * 2] = hex[digest[i] >> 4]; out[i * 2 + 1] = hex[digest[i] & 15]; }
    out[64] = 0;
    return 64;
}

static int receive_message(HaoWire *wire, void *socket, int channel) {
    clear_message(wire);
    HaoFrame frame = {0};
    int more = 0;
    while (1) {
        if (read_frame(socket, &frame, &more) < 0) { discard_remaining(socket, more); clear_message(wire); return -1; }
        if (frame.length == 9 && memcmp(frame.data, "<IDS|MSG>", 9) == 0) { hao_free(frame.data); break; }
        if (wire->identity_count == HAO_MAX_IDENTITIES || !more) {
            hao_free(frame.data); discard_remaining(socket, more); clear_message(wire); return -1;
        }
        wire->identities[wire->identity_count++] = frame;
    }
    HaoFrame fields[5] = {{0}};
    for (size_t i = 0; i < 5; i++) {
        if (!more || read_frame(socket, &fields[i], &more) < 0) goto bad;
    }
    if (more) goto bad;
    char expected[65];
    size_t expected_len = signature(wire, &fields[1], expected);
    if (fields[0].length != expected_len || memcmp(fields[0].data, expected, expected_len) != 0) goto bad;
    wire->header = fields[1]; wire->content = fields[4]; wire->incoming_channel = channel;
    hao_free(fields[0].data); hao_free(fields[2].data); hao_free(fields[3].data);
    return channel;
bad:
    for (size_t i = 0; i < 5; i++) hao_free(fields[i].data);
    discard_remaining(socket, more);
    clear_message(wire);
    return -1;
}

int hao_jupyter_wire_poll(uintptr_t handle, int timeout_ms) {
    HaoWire *wire = (HaoWire *)handle;
    if (!wire) return -1;
    zmq_pollitem_t items[3] = {
        {.socket = wire->heartbeat, .events = ZMQ_POLLIN},
        {.socket = wire->control, .events = ZMQ_POLLIN},
        {.socket = wire->shell, .events = ZMQ_POLLIN},
    };
    int status = zmq_poll(items, 3, timeout_ms);
    if (status <= 0) return status;
    if (items[0].revents & ZMQ_POLLIN) {
        zmq_msg_t message;
        if (zmq_msg_init(&message) < 0) return -2;
        if (zmq_msg_recv(&message, wire->heartbeat, 0) < 0) {
            zmq_msg_close(&message);
            return -2;
        }
        int sent = zmq_msg_send(&message, wire->heartbeat, 0);
        zmq_msg_close(&message);
        return sent < 0 ? -2 : HAO_HEARTBEAT;
    }
    if (items[1].revents & ZMQ_POLLIN) {
        int channel = receive_message(wire, wire->control, HAO_CONTROL);
        return channel < 0 ? -2 : channel;
    }
    if (items[2].revents & ZMQ_POLLIN) {
        int channel = receive_message(wire, wire->shell, HAO_SHELL);
        return channel < 0 ? -2 : channel;
    }
    return 0;
}

size_t hao_jupyter_wire_field_length(uintptr_t handle, int field) {
    HaoWire *wire = (HaoWire *)handle;
    if (!wire) return 0;
    const HaoFrame *value = field == HAO_HEADER ? &wire->header : field == HAO_CONTENT ? &wire->content : NULL;
    return value && value->data ? value->length : 0;
}

const unsigned char *hao_jupyter_wire_field_view(uintptr_t handle, int field) {
    HaoWire *wire = (HaoWire *)handle;
    if (!wire) return NULL;
    const HaoFrame *value = field == HAO_HEADER ? &wire->header : field == HAO_CONTENT ? &wire->content : NULL;
    if (!value || !value->data) return NULL;
    return (const unsigned char *)value->data;
}

static int send_frame(void *socket, const void *data, size_t length, int more) {
    return zmq_send(socket, data, length, more ? ZMQ_SNDMORE : 0) < 0 ? -1 : 0;
}

int hao_jupyter_wire_send(uintptr_t handle, int channel, const unsigned char *type_bytes,
    size_t type_len, const unsigned char *content_bytes, size_t content_len) {
    HaoWire *wire = (HaoWire *)handle;
    if (!wire || !wire->header.data || type_len == 0 || type_len > 80 || content_len > HAO_MAX_FRAME) return -1;
    void *socket = channel == HAO_SHELL ? wire->shell : channel == HAO_CONTROL ? wire->control : channel == HAO_IOPUB ? wire->iopub : NULL;
    if (!socket) return -1;
    char *type = copy_text(type_bytes, type_len);
    if (!type) return -1;
    char id[33]; random_id(id);
    char header[512];
    int size = snprintf(header, sizeof(header), "{\"msg_id\":\"%s\",\"session\":\"%s\",\"username\":\"hao\",\"date\":\"\",\"msg_type\":\"%s\",\"version\":\"5.3\"}", id, wire->session, type);
    hao_free(type);
    if (size <= 0 || (size_t)size >= sizeof(header)) return -1;
    HaoFrame frames[4] = {
        {header, (size_t)size}, wire->header, {"{}", 2}, {(char *)content_bytes, content_len},
    };
    char digest[65]; size_t digest_len = signature(wire, frames, digest);
    if (digest_len == SIZE_MAX) return -1;
    if (channel != HAO_IOPUB)
        for (size_t i = 0; i < wire->identity_count; i++)
            if (send_frame(socket, wire->identities[i].data, wire->identities[i].length, 1) < 0) return -1;
    return send_frame(socket, "<IDS|MSG>", 9, 1) == 0 &&
        send_frame(socket, digest, digest_len, 1) == 0 &&
        send_frame(socket, header, (size_t)size, 1) == 0 &&
        send_frame(socket, wire->header.data, wire->header.length, 1) == 0 &&
        send_frame(socket, "{}", 2, 1) == 0 &&
        send_frame(socket, content_bytes, content_len, 0) == 0 ? 0 : -1;
}
