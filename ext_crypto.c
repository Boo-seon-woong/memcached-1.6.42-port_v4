#include "ext_crypto.h"
#include <string.h>
#include <stdatomic.h>
#include <sys/random.h>
#include <openssl/evp.h>

static uint8_t g_key[32];
static uint32_t g_salt;
static _Atomic uint64_t g_ctr;
static _Thread_local EVP_CIPHER_CTX *g_seal_ctx;
static _Thread_local EVP_CIPHER_CTX *g_open_ctx;

void ext_crypto_init(const uint8_t key[32]) {
    memcpy(g_key, key, 32);
    if (getrandom(&g_salt, sizeof(g_salt), 0) != sizeof(g_salt)) {
        /* getrandom shouldn't fail for 4 bytes; if it does, refuse to run
         * rather than seal with a predictable salt. */
        abort();
    }
    atomic_store(&g_ctr, 0);
}

static void make_nonce(uint8_t n[12]) {
    uint64_t c = atomic_fetch_add(&g_ctr, 1);
    memcpy(n, &g_salt, 4);
    memcpy(n + 4, &c, 8);
}

/* 키는 스레드별 ctx에 한 번만 넣는다. 매 연산마다 키를 넘기면 OpenSSL 3.x가
 * AES 키 스케줄과 GHASH 테이블(CRYPTO_gcm128_init)을 다시 만들고, 그 재초기화
 * 경로가 provider를 문자열 파라미터로 조회한다 — perf에서 GET CPU의 약 6%가
 * EVP_CIPHER_CTX_get_iv_length / get_key_length / ctrl 로 나갔다. 키는
 * ext_crypto_init에서 한 번 정해지고 바뀌지 않으므로 전부 불필요한 일이다.
 * 이후 seal/open은 IV만 갈아끼운다(키 인자 NULL = 기존 키 유지).
 *
 * 따라서 ext_crypto_init은 워커가 뜨기 전에 끝나야 한다. 나중에 키를 바꾸면
 * 이미 만들어진 ctx는 옛 키를 계속 쓴다. 이 포트에는 키 교체 경로가 없다. */
static EVP_CIPHER_CTX *get_ctx(EVP_CIPHER_CTX **slot, int encrypt) {
    if (*slot) return *slot;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return NULL;
    if (EVP_CipherInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL, encrypt) != 1 ||
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1 ||
            EVP_CipherInit_ex(ctx, NULL, NULL, g_key, NULL, encrypt) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    return *slot = ctx;
}

int ext_crypto_seal(uint8_t *out, const void *pt, size_t ptlen,
                    const struct ext_aad *aad) {
    uint8_t nonce[12];
    make_nonce(nonce);
    EVP_CIPHER_CTX *ctx = get_ctx(&g_seal_ctx, 1);
    if (!ctx) return -1;
    int len, rv = -1;
    if (EVP_EncryptInit_ex(ctx, NULL, NULL, NULL, nonce) != 1) goto out;  /* IV만 */
    if (EVP_EncryptUpdate(ctx, NULL, &len, (const uint8_t *)aad, sizeof(*aad)) != 1) goto out;
    if (EVP_EncryptUpdate(ctx, out + 12, &len, pt, ptlen) != 1) goto out;
    if (EVP_EncryptFinal_ex(ctx, out + 12 + len, &len) != 1) goto out;  /* len=0 for GCM */
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, out + 12 + ptlen) != 1) goto out;
    memcpy(out, nonce, 12);
    rv = (int)ptlen + EXT_CRYPTO_OVERHEAD;
out:
    if (rv < 0) {
        EVP_CIPHER_CTX_free(ctx);
        g_seal_ctx = NULL;
    }
    return rv;
}

int ext_crypto_open(void *pt_out, const uint8_t *in, size_t inlen,
                    const struct ext_aad *aad) {
    if (inlen < EXT_CRYPTO_OVERHEAD) return -1;
    size_t ctlen = inlen - EXT_CRYPTO_OVERHEAD;
    const uint8_t *nonce = in;
    const uint8_t *ct = in + 12;
    uint8_t tag[16];
    memcpy(tag, in + inlen - 16, 16);        /* copy: DecryptFinal wants non-const */
    EVP_CIPHER_CTX *ctx = get_ctx(&g_open_ctx, 0);
    if (!ctx) return -1;
    int len, rv = -1;
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, NULL, nonce) != 1) goto out;  /* IV만 */
    if (EVP_DecryptUpdate(ctx, NULL, &len, (const uint8_t *)aad, sizeof(*aad)) != 1) goto out;
    if (EVP_DecryptUpdate(ctx, pt_out, &len, ct, ctlen) != 1) goto out;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag) != 1) goto out;
    if (EVP_DecryptFinal_ex(ctx, (uint8_t *)pt_out + len, &len) != 1) goto out;  /* tag check */
    rv = (int)ctlen;
out:
    if (rv < 0) {
        EVP_CIPHER_CTX_free(ctx);
        g_open_ctx = NULL;
    }
    return rv;
}
