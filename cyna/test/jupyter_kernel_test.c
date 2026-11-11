#include <zmq.h>
#include "../crypto.h"
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void sign_request(const char *header, const char *content, char out[65]) {
    const char *frames[] = {header, "{}", "{}", content};
    const void *parts[4]; size_t lengths[4];
    for (int i = 0; i < 4; i++) { parts[i] = frames[i]; lengths[i] = strlen(frames[i]); }
    unsigned char digest[32];
    if (hao_hmac_sha256("secret", 6, parts, lengths, digest) != 0) abort();
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[i * 2] = hex[digest[i] >> 4]; out[i * 2 + 1] = hex[digest[i] & 15]; }
    out[64] = 0;
}

static int send_request_signed(void *socket, const char *kind, const char *content, int corrupt) {
    char header[256], digest[65];
    snprintf(header, sizeof(header), "{\"msg_type\":\"%s\",\"msg_id\":\"test\"}", kind);
    sign_request(header, content, digest);
    if (corrupt) digest[0] = digest[0] == 'a' ? 'b' : 'a';
    const char *frames[] = {"<IDS|MSG>", digest, header, "{}", "{}", content};
    for (int i = 0; i < 6; i++)
        if (zmq_send(socket, frames[i], strlen(frames[i]), i == 5 ? 0 : ZMQ_SNDMORE) < 0) return -1;
    return 0;
}

static int send_request(void *socket, const char *kind, const char *content) {
    return send_request_signed(socket, kind, content, 0);
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
    if (argc != 2 && (argc != 3 || strcmp(argv[2], "--shared"))) return 2;
    int shared = argc == 3;
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
    char content[65536]; int status = 0;
    if (shared) {
        if (send_request(shell, "kernel_info_request", "{}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "implementation") || !strstr(content, "hao")) status = 69;
        int info_idle_seen = 0;
        for (int i = 0; !status && i < 4 && !info_idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 74; break; }
            if (strstr(content, "execution_state") && strstr(content, "idle")) info_idle_seen = 1;
        }
        if (!status && !info_idle_seen) status = 75;
        if (!status && (send_request(shell, "execute_request", "{\"code\":\"1 + 1\"}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "status") || !strstr(content, "ok"))) status = 70;
        int result_seen = 0, idle_seen = 0;
        for (int i = 0; !status && i < 8 && !idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 71; break; }
            if (strstr(content, "text/plain") && strstr(content, "2")) result_seen = 1;
            if (strstr(content, "execution_state") && strstr(content, "idle")) idle_seen = 1;
        }
        if (!status && (!result_seen || !idle_seen)) status = 72;
        if (!status && (send_request(shell, "execute_request", "{\"code\":\"''\"}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "\"status\"") || !strstr(content, "\"ok\""))) status = 85;
        idle_seen = 0;
        for (int i = 0; !status && i < 8 && !idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 86; break; }
            if (strstr(content, "\"text/plain\"") || strstr(content, "\"display_data\"")) { status = 87; break; }
            if (strstr(content, "execution_state") && strstr(content, "idle")) idle_seen = 1;
        }
        if (!status && !idle_seen) status = 88;
        if (!status && (send_request(shell, "execute_request",
            "{\"code\":\"console.log('hao-stream'); 3\"}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "status") || !strstr(content, "ok"))) status = 76;
        int stream_seen = 0;
        result_seen = idle_seen = 0;
        for (int i = 0; !status && i < 8 && !idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 77; break; }
            if (strstr(content, "stdout") && strstr(content, "hao-stream")) stream_seen = 1;
            if (strstr(content, "text/plain") && strstr(content, "3")) result_seen = 1;
            if (strstr(content, "execution_state") && strstr(content, "idle")) idle_seen = 1;
        }
        if (!status && (!stream_seen || !result_seen || !idle_seen)) status = 78;
        if (!status && (send_request(shell, "execute_request",
            "{\"code\":\"({ repr() { return { mime: 'image/svg+xml', data: '<svg/>' }; } })\"}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "status") || !strstr(content, "ok"))) status = 79;
        int display_seen = 0;
        idle_seen = 0;
        for (int i = 0; !status && i < 8 && !idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 80; break; }
            if (strstr(content, "image/svg+xml") && strstr(content, "<svg/>")) display_seen = 1;
            if (strstr(content, "execution_state") && strstr(content, "idle")) idle_seen = 1;
        }
        if (!status && (!display_seen || !idle_seen)) status = 81;
        if (!status && (send_request(shell, "execute_request",
            "{\"code\":\"throw new Error('shared failure')\"}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "status") || !strstr(content, "error") ||
            !strstr(content, "shared failure"))) status = 82;
        int error_seen = 0;
        idle_seen = 0;
        for (int i = 0; !status && i < 8 && !idle_seen; i++) {
            if (receive_content(iopub, content, sizeof(content)) < 0) { status = 83; break; }
            if (strstr(content, "ename") && strstr(content, "shared failure")) error_seen = 1;
            if (strstr(content, "execution_state") && strstr(content, "idle")) idle_seen = 1;
        }
        if (!status && (!error_seen || !idle_seen)) status = 84;
        if (!status && (send_request(control, "shutdown_request", "{\"restart\":false}") < 0 ||
            receive_content(control, content, sizeof(content)) < 0 ||
            !strstr(content, "status") || !strstr(content, "ok"))) status = 73;
        goto cleanup;
    }
    if (send_request_signed(shell, "kernel_info_request", "{}", 1) < 0) status = 63;
    if (send_request(shell, "kernel_info_request", "{}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"implementation\":\"hao\"")) status = 5;
    if (!status && receive_content(iopub, content, sizeof(content)) < 0) {
        if (send_request(shell, "kernel_info_request", "{}") < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            receive_content(iopub, content, sizeof(content)) < 0) status = 20;
    }
    int info_idle = 0;
    for (int i = 0; !status && i < 4 && !info_idle; i++) {
        if (strstr(content, "\"execution_state\":\"idle\"")) { info_idle = 1; break; }
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 41; break; }
    }
    if (!status && !info_idle) status = 42;
    if (!status && (send_request(shell, "execute_request", "{}") < 0 ||
        send_request(shell, "kernel_info_request", "{}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"implementation\":\"hao\""))) status = 66;
    int recovery_idle = 0;
    for (int i = 0; !status && i < 4 && !recovery_idle; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 67; break; }
        if (strstr(content, "\"execution_state\":\"idle\"")) recovery_idle = 1;
    }
    if (!status && !recovery_idle) status = 68;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"globalThis.__silentValue = 9; console.log('hidden'); 123\",\"silent\":true}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\"") || !strstr(content, "\"execution_count\":null"))) status = 43;
    int silent_idle = 0;
    for (int i = 0; !status && i < 4 && !silent_idle; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 44; break; }
        if (strstr(content, "\"code\"") || strstr(content, "\"text\"") || strstr(content, "\"data\"")) { status = 45; break; }
        if (strstr(content, "\"execution_state\":\"idle\"")) silent_idle = 1;
    }
    if (!status && !silent_idle) status = 46;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"throw Error('silent failure')\",\"silent\":true}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\"") || !strstr(content, "\"execution_count\":null"))) status = 47;
    silent_idle = 0;
    for (int i = 0; !status && i < 4 && !silent_idle; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 48; break; }
        if (strstr(content, "\"ename\"") || strstr(content, "\"traceback\"")) { status = 49; break; }
        if (strstr(content, "\"execution_state\":\"idle\"")) silent_idle = 1;
    }
    if (!status && !silent_idle) status = 50;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"globalThis.__historyValue = 11; 77\",\"store_history\":false}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\"") || !strstr(content, "\"execution_count\":0"))) status = 51;
    int history_result = 0, history_idle = 0;
    for (int i = 0; !status && i < 6 && !history_idle; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 52; break; }
        if (strstr(content, "\"text/plain\":\"77\"")) history_result = 1;
        if (strstr(content, "\"execution_state\":\"idle\"")) history_idle = 1;
    }
    if (!status && (!history_result || !history_idle)) status = 53;
    if (!status && (send_request(shell, "complete_request", "{\"code\":\"abc\",\"cursor_pos\":3}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"matches\":[]") || !strstr(content, "\"cursor_start\":3"))) status = 55;
    if (!status && (send_request(shell, "inspect_request", "{\"code\":\"abc\",\"cursor_pos\":3}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"found\":false"))) status = 56;
    if (!status && (send_request(shell, "history_request", "{\"hist_access_type\":\"tail\",\"n\":2}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"history\":[]"))) status = 57;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"let x: number = 21; x * 2\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\"") || !strstr(content, "\"execution_count\":1"))) status = 6;
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
    if (!status && (send_request(shell, "history_request", "{\"hist_access_type\":\"tail\",\"n\":1}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "[1,2,\"x + 1\"]") || strstr(content, "__historyValue"))) status = 58;
    if (!status && (send_request(shell, "history_request", "{\"hist_access_type\":\"range\",\"start\":1,\"stop\":2}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "[1,1,\"let x: number = 21; x * 2\"]") || strstr(content, "x + 1"))) status = 59;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"x\",\"user_expressions\":{\"answer\":\"x + 3\",\"missing\":\"doesNotExist\"}}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\"") ||
        !strstr(content, "\"answer\":{\"status\":\"ok\",\"data\":{\"text/plain\":\"24\"}") ||
        !strstr(content, "\"missing\":{\"status\":\"error\""))) status = 54;
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
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"({ answer: 42 })\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 35;
    int saw_inspect = 0;
    for (int i = 0; !status && i < 6 && !saw_inspect; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 36; break; }
        if (strstr(content, "\"text/plain\":\"{ answer: 42 }\"")) saw_inspect = 1;
    }
    if (!status && !saw_inspect) status = 37;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"({ repr() { return { mime: 'image/svg+xml', data: '<svg/>' }; } })\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 17;
    int saw_svg = 0;
    for (int i = 0; !status && i < 6 && !saw_svg; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 18; break; }
        if (strstr(content, "\"image/svg+xml\":\"<svg/>\"")) saw_svg = 1;
    }
    if (!status && !saw_svg) status = 19;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"import { figure, plot, show } from 'std:plot'; figure({ width: 120, height: 80 }); plot([0, 1], [0, 1]); show()\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 38;
    int saw_plot = 0;
    for (int i = 0; !status && i < 6 && !saw_plot; i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 39; break; }
        if (strstr(content, "\"image/svg+xml\":\"<svg")) saw_plot = 1;
    }
    if (!status && !saw_plot) status = 40;
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
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"Promise.reject(new Error('detached broken')); 42\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\"") ||
        !strstr(content, "detached broken"))) status = 64;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"new Promise(resolve => { setTimeout(() => { throw new Error('timer broken') }, 1); setTimeout(() => resolve(42), 3) })\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\"") ||
        !strstr(content, "timer broken"))) status = 65;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"throw new Error('broken')\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"error\"") ||
        !strstr(content, "Error: broken") || !strstr(content, "at <"))) status = 12;
    if (!status && (send_request(shell, "execute_request", "{\"code\":\"'a\\\\u0000b'\"}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\""))) status = 89;
    int nul_result = 0, nul_idle = 0;
    for (int i = 0; !status && i < 40 && (!nul_idle || !nul_result); i++) {
        if (receive_content(iopub, content, sizeof(content)) < 0) { status = 90; break; }
        if (strstr(content, "\"text/plain\":\"a\\u0000b\"")) nul_result = 1;
        if (strstr(content, "\"execution_state\":\"idle\"")) nul_idle = 1;
    }
    if (!status && (!nul_result || !nul_idle)) status = 91;
    for (int i = 0; !status && i < 130; i++) {
        char request[128];
        snprintf(request, sizeof(request), "{\"code\":\"globalThis.__histWrap = %d\"}", i);
        if (send_request(shell, "execute_request", request) < 0 ||
            receive_content(shell, content, sizeof(content)) < 0 ||
            !strstr(content, "\"status\":\"ok\"")) status = 60;
    }
    if (!status && (send_request(shell, "history_request", "{\"hist_access_type\":\"tail\",\"n\":2}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "globalThis.__histWrap = 128") ||
        !strstr(content, "globalThis.__histWrap = 129") ||
        strstr(content, "globalThis.__histWrap = 127"))) status = 61;
    if (!status && (send_request(shell, "history_request", "{\"hist_access_type\":\"range\",\"start\":1,\"stop\":2}") < 0 ||
        receive_content(shell, content, sizeof(content)) < 0 ||
        !strstr(content, "\"history\":[]"))) status = 62;
    if (!status && (send_request(control, "shutdown_request", "{\"restart\":true}") < 0 ||
        receive_content(control, content, sizeof(content)) < 0 ||
        !strstr(content, "\"status\":\"ok\"") || !strstr(content, "\"restart\":true"))) status = 8;
cleanup:
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
