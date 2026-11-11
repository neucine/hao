#ifndef HAO_TEST_JUPYTER_HMAC_H
#define HAO_TEST_JUPYTER_HMAC_H

#include <stddef.h>

int jupyter_hmac_sha256(const void *key, size_t key_length,
                        const void *parts[4], const size_t lengths[4],
                        unsigned char digest[32]);

#endif
