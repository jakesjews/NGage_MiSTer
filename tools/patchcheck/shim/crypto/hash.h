/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PATCHCHECK_CRYPTO_HASH_H
#define PATCHCHECK_CRYPTO_HASH_H
#include "qapi/error.h"
#define QCRYPTO_HASH_ALGO_MD5 0
int qcrypto_hash_bytes(int alg, const void *buf, size_t len, uint8_t **result, size_t *resultlen, Error **errp);
#endif
