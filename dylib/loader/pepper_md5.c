// Thin CC_MD5 wrapper — lets Swift compute the same port hash as the Makefile
// without adding CryptoKit as a framework dependency.

#include <CommonCrypto/CommonDigest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

void pepper_md5(const void *data, unsigned int len, unsigned char *out) {
    CC_MD5(data, len, out);
}

#pragma clang diagnostic pop
