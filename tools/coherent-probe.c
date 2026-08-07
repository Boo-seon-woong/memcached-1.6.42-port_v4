/* coherent MR 풀 탐침. memcached 를 건드리지 않고 독립으로 돈다.
 *
 *   gcc -O2 -o coherent-probe coherent-probe.c -libverbs -ldl
 *   LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib ./coherent-probe
 *
 * 두 가지를 잰다.
 *   ① 단발 최대 — extstore 는 bounce 를 MR 하나로 잡으므로 이게 구속값이다
 *   ② 누적 총량 — bounce + staging 이 함께 들어가야 하므로 이것도 봐야 한다
 * 실행 중인 memcached 가 이미 쥔 몫은 빠진 값이 나온다(하한).
 */
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>
#include <infiniband/verbs.h>

typedef struct ibv_mr *(*alloc_fn)(struct ibv_pd *, size_t, int);
static alloc_fn coherent_alloc;
static struct ibv_pd *pd;
#define ACC IBV_ACCESS_LOCAL_WRITE

static struct ibv_mr *try_alloc(size_t sz) { return coherent_alloc(pd, sz, ACC); }

int main(void) {
    int n = 0;
    struct ibv_device **list = ibv_get_device_list(&n);
    if (!list || n == 0) { fprintf(stderr, "no RDMA device\n"); return 1; }
    struct ibv_context *ctx = ibv_open_device(list[0]);
    if (!ctx) { fprintf(stderr, "open_device failed\n"); return 1; }
    printf("device %s\n", ibv_get_device_name(list[0]));
    pd = ibv_alloc_pd(ctx);
    if (!pd) { fprintf(stderr, "alloc_pd failed\n"); return 1; }

    void *lib = dlopen("libmlx5.so.1", RTLD_NOW | RTLD_LOCAL);
    void *sym = lib ? dlsym(lib, "mlx5dv_alloc_coherent_mr") : NULL;
    memcpy(&coherent_alloc, &sym, sizeof(coherent_alloc));
    if (!coherent_alloc) { fprintf(stderr, "mlx5dv_alloc_coherent_mr absent\n"); return 1; }

    /* ① 단발 최대 (1 MB 단위 이분) */
    size_t lo = 0, hi = 512u << 20;
    while (hi - lo > (1u << 20)) {
        size_t mid = lo + (hi - lo) / 2;
        struct ibv_mr *mr = try_alloc(mid);
        if (mr) { lo = mid; ibv_dereg_mr(mr); } else hi = mid;
    }
    printf("단발 최대   %.2f MB\n", lo / 1048576.0);

    /* ② 누적 총량 (4 MB 조각을 실패할 때까지) */
    enum { MAXN = 256 };
    struct ibv_mr *held[MAXN];
    int h = 0; size_t total = 0, chunk = 4u << 20;
    while (h < MAXN) {
        struct ibv_mr *mr = try_alloc(chunk);
        if (!mr) { if (chunk <= (1u << 20)) break; chunk /= 2; continue; }
        held[h++] = mr; total += chunk;
    }
    printf("누적 총량   %.2f MB  (조각 %d개)\n", total / 1048576.0, h);
    for (int i = 0; i < h; i++) ibv_dereg_mr(held[i]);

    /* 이 침대의 실험 규칙으로 환산 */
    printf("\nslot=256B · mcT=30 기준 (bounce 2×wire + staging wire+9 슬롯)\n");
    printf("  단발 최대로 본 bounce 상한 wire = %.0f  → 총 in-flight %.0f\n",
           lo / (30.0 * 2 * 256), 30 * lo / (30.0 * 2 * 256));
    printf("  누적 총량으로 본 wire         = %.0f  → 총 in-flight %.0f\n",
           total / (30.0 * 3 * 256), 30 * total / (30.0 * 3 * 256));
    return 0;
}
