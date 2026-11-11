#include "c_bytes.h"
#include <string.h>

unsigned char hao_byte_at(const unsigned char *pointer, size_t index) {
    return pointer[index];
}

void hao_copy_bytes(unsigned char *output, const unsigned char *input, size_t length) {
    memcpy(output, input, length);
}
