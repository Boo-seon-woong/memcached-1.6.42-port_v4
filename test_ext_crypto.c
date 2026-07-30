/* Self-check for ext_crypto. Build: cc -o t test_ext_crypto.c ext_crypto.c -lcrypto */
#include "ext_crypto.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    uint8_t key[32];
    for (int i = 0; i < 32; i++) key[i] = i;
    ext_crypto_init(key);

    const char *pt = "the quick brown fox jumps over 64 bytes of value payload........";
    size_t ptlen = strlen(pt);
    struct ext_aad aad = { .hv = 0xdeadbeef, .page_id = 7, .offset = 4096, .page_version = 3 };
    uint8_t obj[256], back[256];

    /* round trip */
    int n = ext_crypto_seal(obj, pt, ptlen, &aad);
    assert(n == (int)ptlen + EXT_CRYPTO_OVERHEAD);
    assert(ext_crypto_open(back, obj, n, &aad) == (int)ptlen);
    assert(memcmp(back, pt, ptlen) == 0);

    /* AAD mismatch (slot reused by another key) → reject */
    struct ext_aad bad = aad; bad.hv ^= 1;
    assert(ext_crypto_open(back, obj, n, &bad) == -1);
    assert(ext_crypto_open(back, obj, n, &aad) == (int)ptlen);
    assert(memcmp(back, pt, ptlen) == 0);

    /* torn read: a byte of ciphertext overwritten mid-flight → reject */
    uint8_t torn[256]; memcpy(torn, obj, n);
    torn[20] ^= 0xff;
    assert(ext_crypto_open(back, torn, n, &aad) == -1);

    /* two seals never reuse a nonce */
    uint8_t o2[256];
    ext_crypto_seal(o2, pt, ptlen, &aad);
    assert(memcmp(obj, o2, 12) != 0);

    /* ctx 재사용: 키는 스레드별 ctx에 한 번만 넣고 이후 IV만 간다. 앞 메시지의
     * GCM 상태(카운터·GHASH 누산기)가 남으면 여기서 태그나 평문이 어긋난다.
     * 길이를 바꿔 가며 도는 것은 AAD/평문 길이가 상태에 얽히는 경우까지 잡기
     * 위해서다. 거부 경로(위의 AAD 불일치·torn)를 지난 뒤라야 의미가 있다 —
     * 실패한 open이 상태를 남기지 않는지도 같이 보는 셈이다. */
    for (int i = 0; i < 1000; i++) {
        size_t l = 1 + (size_t)i % ptlen;
        struct ext_aad a = { .hv = (uint32_t)i, .page_id = i % 13,
                             .offset = (uint32_t)(i * 64), .page_version = i % 5 };
        int m = ext_crypto_seal(obj, pt, l, &a);
        assert(m == (int)l + EXT_CRYPTO_OVERHEAD);
        assert(ext_crypto_open(back, obj, m, &a) == (int)l);
        assert(memcmp(back, pt, l) == 0);
    }

    puts("ext_crypto: ok");
    return 0;
}
