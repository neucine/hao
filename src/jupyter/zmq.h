#ifndef HAO_JUPYTER_ZMQ_H
#define HAO_JUPYTER_ZMQ_H

#include <stddef.h>
#include <stdint.h>

uintptr_t hao_jupyter_wire_open(const unsigned char *transport_bytes, size_t transport_len, const unsigned char *ip_bytes, size_t ip_len, uint16_t shell_port, uint16_t control_port, uint16_t iopub_port, uint16_t stdin_port, uint16_t hb_port, const unsigned char *key_bytes, size_t key_len);
void hao_jupyter_wire_close(uintptr_t handle);
int hao_jupyter_wire_poll(uintptr_t handle, int timeout_ms);
size_t hao_jupyter_wire_field_length(uintptr_t handle, int field);
const unsigned char *hao_jupyter_wire_field_view(uintptr_t handle, int field);
int hao_jupyter_wire_send(uintptr_t handle, int channel, const unsigned char *type_bytes, size_t type_len, const unsigned char *content_bytes, size_t content_len);

#endif
