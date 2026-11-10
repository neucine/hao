#include <zmq.h>
#include <CommonCrypto/CommonHMAC.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void sign_request(const char *header, const char *content, char out[65]) {
    CCHmacContext context;
    CCHmacInit(&context, kCCHmacAlgSHA256, "secret", 6);
    const char *frames[] = {header, "{}", "{}", content};
    for (int i = 0; i < 4; i++) CCHmacUpdate(&context, frames[i], strlen(frames[i]));
    unsigned char digest[32]; CCHmacFinal(&context, digest);
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[i * 2] = hex[digest[i] >> 4]; out[i * 2 + 1] = hex[digest[i] & 15]; }
    out[64] = 0;
}

static int send_request(void *socket, const char *kind, const char *content) {
    char header[256], digest[65];
    snprintf(header, sizeof(header), "{\"msg_type\":\"%s\",\"msg_id\":\"test\"}", kind);
    sign_request(header, content, digest);
    const char *frames[] = {"<IDS|MSG>", digest, header, "{}", "{}", content};
    for (int i = 0; i < 6; i++)
        if (zmq_send(socket, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return -1;
    return 0;
}

static int receive_content(void *socket, char *out, size_t capacity) {
    zmq_msg_t message;
    int more = 0, count = 0;
    do {
        if (zmq_msg_init(&message) < 0) return -1;
        int size = zmq_msg_recv(&message, socket, 0);
        if (size < 0 || (size_t)size >= capacity) { zmq_msg_close(&message); return -1; }
        memcpy(out, zmq_msg_data(&message), (size_t)size);
        out[size] = 0;
        more = zmq_msg_more(&message);
        zmq_msg_close(&message);
        count++;
    } while (more);
    return count >= 6 ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *runtime = realpath(argv[1], NULL);
    if (!runtime) return 2;
    alarm(15);
    char base[100], path[130], endpoint[150], json[1024];
    snprintf(base, sizeof(base), "/tmp/hao-kernel-test-%ld", (long)getpid());
    snprintf(path, sizeof(path), "%s.json", base);
    snprintf(json, sizeof(json), "{\"transport\":\"ipc\",\"ip\":\"%s\",\"shell_port\":1,\"control_port\":2,\"iopub_port\":3,\"stdin_port\":4,\"hb_port\":5,\"key\":\"secret\",\"signature_scheme\":\"hmac-sha256\"}", base);
    FILE *file = fopen(path, "wb"); if (!file) return 3;
    fwrite(json, 1, strlen(json), file); fclose(file);
    char module_path[160];
    snprintf(module_path, sizeof(module_path), "%s-value.ts", base);
    file = fopen(module_path, "wb"); if (!file) return 3;
    fputs("export const answer = 17;\n", file); fclose(file);
    pid_t child = fork();
    if (child == 0) { if (chdir("/tmp") < 0) _exit(127); execl(runtime, runtime, "jupyter", "--connection-file", path, (char *)NULL); _exit(127); }
    if (child < 0) return 4;
    void *context = zmq_ctx_new();
    void *shell = zmq_socket(context, ZMQ_DEALER);
    void *control = zmq_socket(context, ZMQ_DEALER);
    void *iopub = zmq_socket(context, ZMQ_SUB);
    int timeout = 5000, linger = 0;
    zmq_setsockopt(shell, ZMQ_RCVTIMEO, &timeout, sizeof(timeout));
    zmq_setsockopt(control, ZMQ_RCVTIMEO, &timeout, sizeof(timeout));
    zmq_setsockopt(iopub, ZMQ_RCVTIMEO, &timeout, sizeof(timeout));
    zmq_setsockopt(iopub, ZMQ_SUBSCRIBE, "", 0);
    zmq_setsockopt(shell, ZMQ_LINGER, &linger, sizeof(linger));
    zmq_setsockopt(control, ZMQ_LINGER, &linger, sizeof(linger));
    zmq_setsockopt(iopub, ZMQ_LINGER, &linger, sizeof(linger));
    snprintf(endpoint, sizeof(endpoint), "ipc://%s:1", base); zmq_connect(shell, endpoint);
    snprintf(endpoint, sizeof(endpoint), "ipc://%s:2", base); zmq_connect(control, endpoint);
    snprintf(endpoint, sizeof(endpoint), "ipc://%s:3", base); zmq_connect(iopub, endpoint);
    usleep(300000);
    char content[2048]; int status = 0;
    if (send_request(shell, "kernel_info_request", "{}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"implementation\":\"hao\"")) status = 5;
    if (!status && receive_content(iopub, content, sizeof(content)) < 0) status = 20;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"let x: number = 21; x * 2\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 6;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"x + 1\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 7;
    int saw_42 = 0, saw_22 = 0;
    for (int i = 0; !status && i < 12 && (!saw_42 || !saw_22); i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 10; break; }
        if (strstr(content, "\"text/plain\":\"42\"")) saw_42 = 1;
        if (strstr(content, "\"text/plain\":\"22\"")) saw_22 = 1;
    }
    if (!status && (!saw_42 || !saw_22)) status = 11;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"import { name } from 'std:runtime'; name\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 13;
    char import_request[400];
    snprintf(import_request, sizeof(import_request), "{\"code\":\"import { answer } from './hao-kernel-test-%ld-value.ts'; answer + 1\"}", (long)getpid());
    if (!status && (send_request(shell, "execute_request", import_request) < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) { fprintf(stderr, "import reply: %s\n", content); status = 14; }
    int saw_name = 0, saw_18 = 0;
    for (int i = 0; !status && i < 12 && (!saw_name || !saw_18); i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 15; break; }
        if (strstr(content, "\"text/plain\":\"hao\"")) saw_name = 1;
        if (strstr(content, "\"text/plain\":\"18\"")) saw_18 = 1;
    }
    if (!status && (!saw_name || !saw_18)) status = 16;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"class Box { value() { return 5; } }; new Box().value()\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 28;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"class Box { value() { return 7; } }; new Box().value()\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 29;
    int saw_5 = 0, saw_7 = 0;
    for (int i = 0; !status && i < 12 && (!saw_5 || !saw_7); i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 30; break; }
        if (strstr(content, "\"text/plain\":\"5\"")) saw_5 = 1;
        if (strstr(content, "\"text/plain\":\"7\"")) saw_7 = 1;
    }
    if (!status && (!saw_5 || !saw_7)) status = 31;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"import { name } from 'std:runtime'; name\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 32;
    int saw_reimport = 0;
    for (int i = 0; !status && i < 6 && !saw_reimport; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 33; break; }
        if (strstr(content, "\"text/plain\":\"hao\"")) saw_reimport = 1;
    }
    if (!status && !saw_reimport) status = 34;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"({ repr() { return { mime: 'image/svg+xml', data: '<svg/>' }; } })\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 17;
    int saw_svg = 0;
    for (int i = 0; !status && i < 6 && !saw_svg; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 18; break; }
        if (strstr(content, "\"image/svg+xml\":\"<svg/>\"")) saw_svg = 1;
    }
    if (!status && !saw_svg) status = 19;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"Promise.resolve(41).then(value => value + 1)\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 21;
    int saw_async_42 = 0;
    for (int i = 0; !status && i < 6 && !saw_async_42; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 22; break; }
        if (strstr(content, "\"text/plain\":\"42\"")) saw_async_42 = 1;
    }
    if (!status && !saw_async_42) status = 23;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"new Promise(resolve => setTimeout(() => resolve(23), 10))\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 24;
    int saw_delayed_23 = 0;
    for (int i = 0; !status && i < 6 && !saw_delayed_23; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 25; break; }
        if (strstr(content, "\"text/plain\":\"23\"")) saw_delayed_23 = 1;
    }
    if (!status && !saw_delayed_23) status = 26;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"Promise.reject(new Error('async broken'))\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\""))) status = 27;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"throw new Error('broken')\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\""))) status = 12;
    if (!status && (send_request(control, "shutdown_request", "{}") < 0 ||
        receive_content(control, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 8;
    if (status) kill(child, SIGTERM);
    int child_status = 0; waitpid(child, &child_status, 0);
    if (!status && (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0)) status = 9;
    zmq_close(shell); zmq_close(control); zmq_close(iopub); zmq_ctx_term(context);
    unlink(path);
    unlink(module_path);
    free(runtime);
    for (int port = 1; port <= 5; port++) { snprintf(endpoint, sizeof(endpoint), "%s:%d", base, port); unlink(endpoint); }
    if (!status) puts("kernel ok");
    return status;
}
