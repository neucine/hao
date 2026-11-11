#include <zmq.h>
#include "../../src/jupyter/crypto.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern uintptr_t hao_jupyter_wire_open(const unsigned char *, size_t, const unsigned char *, size_t,
    uint16_t, uint16_t, uint16_t, uint16_t, uint16_t, const unsigned char *, size_t);
extern void hao_jupyter_wire_close(uintptr_t);
extern int hao_jupyter_wire_poll(uintptr_t, int);
extern int hao_jupyter_wire_field(uintptr_t, int, unsigned char *, size_t);
extern int hao_jupyter_wire_send(uintptr_t, int, const unsigned char *, size_t, const unsigned char *, size_t);

static void sign(const char *key, const char *header, const char *parent,
                 const char *metadata, const char *content, char out[65]) {
    const char *fields[] = {header, parent, metadata, content};
    const void *parts[4]; size_t lengths[4];
    for (size_t i = 0; i < 4; i++) { parts[i] = fields[i]; lengths[i] = strlen(fields[i]); }
    unsigned char digest[32];
    if (hao_hmac_sha256(key, strlen(key), parts, lengths, digest) != 0) abort();
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; i++) { out[i * 2] = hex[digest[i] >> 4]; out[i * 2 + 1] = hex[digest[i] & 15]; }
    out[64] = 0;
}

int main(void) {
    char ip[100], endpoint[128];
    snprintf(ip, sizeof(ip), "/tmp/hao-jupyter-wire-%ld", (long)getpid());
    const char *key = "secret";
    uintptr_t wire = hao_jupyter_wire_open((const unsigned char *)"ipc", 3,
        (const unsigned char *)ip, strlen(ip), 1, 2, 3, 4, 5,
        (const unsigned char *)key, strlen(key));
    if (!wire) return 1;
    void *context = zmq_ctx_new();
    void *client = zmq_socket(context, ZMQ_DEALER);
    int linger = 0; zmq_setsockopt(client, ZMQ_LINGER, &linger, sizeof(linger));
    snprintf(endpoint, sizeof(endpoint), "ipc://%s:1", ip);
    if (zmq_connect(client, endpoint) != 0) return 2;
    const char *header = "{\"msg_type\":\"kernel_info_request\"}";
    char digest[65]; sign(key, header, "{}", "{}", "{}", digest);
    const char *frames[] = {"<IDS|MSG>", digest, header, "{}", "{}", "{}"};
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 3;
    if (hao_jupyter_wire_poll(wire, 1000) != 3) return 4;
    unsigned char buffer[256];
    if (hao_jupyter_wire_field(wire, 1, buffer, sizeof(buffer)) != (int)strlen(header) ||
        strcmp((char *)buffer, header) != 0) return 5;
    if (hao_jupyter_wire_send(wire, 3, (const unsigned char *)"kernel_info_reply", 17,
        (const unsigned char *)"{\"status\":\"ok\"}", 15) != 0) return 6;
    for (size_t i = 0; i < 6; i++) {
        int size = zmq_recv(client, buffer, sizeof(buffer) - 1, 0);
        if (size < 0) return 7;
        buffer[size] = 0;
        if (i == 5 && strcmp((char *)buffer, "{\"status\":\"ok\"}") != 0) return 8;
    }
    digest[0] = digest[0] == 'a' ? 'b' : 'a';
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 9;
    if (hao_jupyter_wire_poll(wire, 1000) != -2) return 10;
    sign(key, header, "{}", "{}", "{}", digest);
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 11;
    if (hao_jupyter_wire_poll(wire, 1000) != 3) return 12;
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), ZMQ_SNDMORE) < 0) return 13;
    if (zmq_send(client, "extra", 5, 0) < 0) return 14;
    if (hao_jupyter_wire_poll(wire, 1000) != -2) return 15;
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 16;
    if (hao_jupyter_wire_poll(wire, 1000) != 3) return 17;
    size_t oversized_length = 1024 * 1024 + 1;
    char *oversized = malloc(oversized_length);
    if (!oversized) return 18;
    memset(oversized, 'x', oversized_length);
    int oversized_sent = zmq_send(client, oversized, oversized_length, ZMQ_SNDMORE);
    free(oversized);
    if (oversized_sent < 0) return 19;
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 20;
    if (hao_jupyter_wire_poll(wire, 1000) != -2) return 21;
    for (size_t i = 0; i < 6; i++)
        if (zmq_send(client, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return 22;
    if (hao_jupyter_wire_poll(wire, 1000) != 3) return 23;
    zmq_close(client); zmq_ctx_term(context); hao_jupyter_wire_close(wire);
    for (int port = 1; port <= 5; port++) {
        snprintf(endpoint, sizeof(endpoint), "%s:%d", ip, port);
        unlink(endpoint);
    }
    puts("wire ok");
    return 0;
}
