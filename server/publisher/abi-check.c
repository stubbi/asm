/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Build-only extension; no C application backend is linked. */
#define main reader_abi_main
#include "../abi-check.c"
#undef main
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <sys/random.h>
#include <unistd.h>
#if !defined(__x86_64__)
#error "The first publisher checkpoint requires native Linux x86-64"
#endif
#if defined(ASM_OPENSSL_PROFILE_3_5_9) && !defined(ASM_OPENSSL_PROFILE_3_0_22_FIXTURE)
#define REVIEWED_OPENSSL_MINOR 5
#define REVIEWED_OPENSSL_PATCH 9
#define REVIEWED_OPENSSL_LABEL "3.5.9"
#elif defined(ASM_OPENSSL_PROFILE_3_0_22_FIXTURE) && !defined(ASM_OPENSSL_PROFILE_3_5_9)
#define REVIEWED_OPENSSL_MINOR 0
#define REVIEWED_OPENSSL_PATCH 22
#define REVIEWED_OPENSSL_LABEL "3.0.22 (retained fixture only)"
#else
#error "Select exactly one reviewed publisher OpenSSL profile"
#endif
_Static_assert(OPENSSL_VERSION_MAJOR == 3 && OPENSSL_VERSION_MINOR == REVIEWED_OPENSSL_MINOR &&
               OPENSSL_VERSION_PATCH == REVIEWED_OPENSSL_PATCH,
               "Review another OpenSSL header before qualification");
_Static_assert(__builtin_types_compatible_p(__typeof__(&EVP_MD_CTX_new), EVP_MD_CTX *(*)(void)) &&
               __builtin_types_compatible_p(__typeof__(&EVP_MD_CTX_free), void (*)(EVP_MD_CTX *)) &&
               __builtin_types_compatible_p(__typeof__(&EVP_DigestInit_ex), int (*)(EVP_MD_CTX *, const EVP_MD *, ENGINE *)) &&
               __builtin_types_compatible_p(__typeof__(&EVP_DigestUpdate), int (*)(EVP_MD_CTX *, const void *, size_t)) &&
               __builtin_types_compatible_p(__typeof__(&EVP_DigestFinal_ex), int (*)(EVP_MD_CTX *, unsigned char *, unsigned int *)) &&
               __builtin_types_compatible_p(__typeof__(&CRYPTO_memcmp), int (*)(const void *, const void *, size_t)) &&
               __builtin_types_compatible_p(__typeof__(&OPENSSL_cleanse), void (*)(void *, size_t)),
               "Publisher EVP or memory-cleanup signatures changed");
_Static_assert(MHD_OPTION_NOTIFY_COMPLETED == 4 && MHD_REQUEST_TERMINATED_COMPLETED_OK == 0,
               "MHD completion ABI changed");
_Static_assert(O_DIRECTORY == 0x10000 && O_NOFOLLOW == 0x20000 && O_CLOEXEC == 0x80000 &&
               (O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC) == 0xa00c2 && RENAME_NOREPLACE == 1,
               "Publisher descriptor flags changed");
_Static_assert(offsetof(struct stat, st_size) == 48 && offsetof(struct stat, st_nlink) == 16,
               "Publisher file metadata layout changed");
_Static_assert(__builtin_types_compatible_p(MHD_RequestCompletedCallback,
               void (*)(void *, struct MHD_Connection *, void **, enum MHD_RequestTerminationCode)),
               "MHD request completion signature changed");

int main(void)
{
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int bytes = 0;
    if (reader_abi_main() || OpenSSL_version_num() != OPENSSL_VERSION_NUMBER ||
        EVP_Digest("abc", 3, digest, &bytes, EVP_sha256(), NULL) != 1 || bytes != 32) {
        fputs("Use the reviewed OpenSSL " REVIEWED_OPENSSL_LABEL " headers and runtime.\n", stderr);
        return 1;
    }
    return 0;
}
