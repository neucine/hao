#ifndef HAO_CYNA_CRYPTO_H
#define HAO_CYNA_CRYPTO_H

#include <openssl/evp.h>
#include <openssl/params.h>
#include <stddef.h>

static int hao_hmac_sha256(const void *key, size_t key_length,
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

#endif
