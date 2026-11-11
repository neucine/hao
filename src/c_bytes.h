#ifndef HAO_C_BYTES_H
#define HAO_C_BYTES_H

#include <stddef.h>

unsigned char hao_byte_at(const unsigned char *pointer, size_t index);
void hao_copy_bytes(unsigned char *output, const unsigned char *input, size_t length);

#endif
