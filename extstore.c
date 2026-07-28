/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/* extstore RDMA backend: one-sided READ/WRITE to a remote (genie) MR.
 * Replaces the flash/wbuf engine. See EXTSTORE_RDMA_SPEC.md.
 * Storage model: remote memory sliced into pages; each page bump-allocates
 * fixed-max slots. In-place overwrite (P-1a) means alloc is cold after preload.
 */
#include "config.h"
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>
#include "extstore.h"
#include <time.h>

/* EXT_RDMA_PROF (D6): runtime-gated in-server span profiling. */
#define PROF_BUCKETS 32768     /* x100ns => 0..3.27ms, captures the contention tail */
#define PROF_BUCKET_NS 100
static int g_prof_on = 0;
static double g_ns_per_cycle = 0.0;          /* rdtsc cycle -> ns */

static inline uint64_t prof_rdtsc(void) { return __builtin_ia32_rdtsc(); }

/* Calibrate rdtsc against CLOCK_MONOTONIC over ~50ms (invariant TSC assumed). */
static void prof_calibrate(void) {
    struct timespec t0, t1;
    uint64_t c0 = prof_rdtsc();
    clock_gettime(CLOCK_MONOTONIC, &t0);
    struct timespec s = { .tv_sec = 0, .tv_nsec = 50 * 1000 * 1000 };
    nanosleep(&s, NULL);
    uint64_t c1 = prof_rdtsc();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    uint64_t cyc = c1 - c0;
    g_ns_per_cycle = cyc ? ns / (double)cyc : 0.0;
    fprintf(stderr, "extstore prof: TSC %.4f ns/cycle (%.0f MHz)\n",
            g_ns_per_cycle, g_ns_per_cycle > 0 ? 1000.0 / g_ns_per_cycle : 0.0);
}

static inline void prof_record(uint32_t *hist, uint64_t *count, uint64_t *sum,
                               uint64_t cycles) {
    uint64_t ns = (uint64_t)(cycles * g_ns_per_cycle);
    unsigned int b = ns / PROF_BUCKET_NS;
    if (b >= PROF_BUCKETS) b = PROF_BUCKETS - 1;
    hist[b]++; (*count)++; *sum += ns;
}

/* DMA-registerable buffer. On SEV-SNP the passthrough NIC can only DMA SHARED
 * (unencrypted) memory, so the read-bounce and write-staging pools must come
 * from /dev/snp_shared. On non-TEE hosts that device is absent, so fall back to
 * anonymous mmap (keeps the genie loopback path working). §9 / P-3(a). */
/* SEV bounce/staging come from /dev/snp_shared (decrypted, cache=wb), so the
 * NIC DMAs into them directly rather than through SWIOTLB. On x86 that path is
 * cache-coherent and the SYNC advise is a no-op cost. Left ON by default; set
 * EXT_SKIP_DMA_SYNC=1 to measure/skip it. Correctness is self-checking: if the
 * sync is in fact required, GCM tag verification fails and badcrc fires. */
static int g_skip_dma_sync = 0;

static char *dma_alloc(size_t sz) {
    int fd = open("/dev/snp_shared", O_RDWR);
    if (fd >= 0) {
        void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        /* keep fd open: the shared region is tied to it. one-time init leak. */
        if (p != MAP_FAILED) {
            fprintf(stderr, "extstore: dma_alloc %zuB from /dev/snp_shared\n", sz);
            return p;
        }
        fprintf(stderr, "extstore: snp_shared mmap(%zuB) failed: %s; using anon\n",
                sz, strerror(errno));
        close(fd);
    }
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

/* Custom advice added by the SEV SWIOTLB-sync kernel patch (rdma-porting-refs/).
 * Builds against stock headers; unpatched libibverbs returns an error we tolerate. */
#ifndef IBV_ADVISE_MR_ADVICE_SYNC_FOR_CPU
#define IBV_ADVISE_MR_ADVICE_SYNC_FOR_CPU 3
#endif
/* Write-direction counterpart: staging must be pushed to the device before the
 * NIC reads it, or the WRITE transmits pre-DMA contents (proved on 2026-07-23:
 * genie received a 496-byte run of 0x00 for a sealed object). The kernel patch
 * must use this same numeric value — if it picks a different one, change this
 * define, do not assume 4. A patched header wins over this fallback. */
#ifndef IBV_ADVISE_MR_ADVICE_SYNC_FOR_DEVICE
#define IBV_ADVISE_MR_ADVICE_SYNC_FOR_DEVICE 4
#endif

#define CM_TIMEOUT_MS 2000

/* Remote MR info handed to each client connection in the accept private_data. */
struct xrd_mr_info { uint64_t raddr; uint32_t rkey; uint64_t size; } __attribute__((packed));

#define STAT_L(e)   pthread_mutex_lock(&e->stats_mutex)
#define STAT_UL(e)  pthread_mutex_unlock(&e->stats_mutex)

typedef struct _store_page {
    pthread_mutex_t mutex;
    uint64_t obj_count, bytes_used;
    uint64_t remote_off;      /* byte offset of this page within the remote MR */
    uint32_t version;
    uint32_t allocated;       /* bump cursor within page */
    uint16_t id, bucket;
    bool active, free;
    struct _store_page *next; /* free-page stack link */
} store_page;

/* per-bucket freed-slot stack (holes from delete/resize; cold path) */
struct loc_stack { struct ext_loc *arr; int top, cap; };

typedef struct store_engine store_engine;

typedef struct store_worker {
    store_engine *e;
    struct rdma_cm_id **cm_id;           /* [nqp] */
    struct ibv_qp **qp;                  /* [nqp] */
    struct ibv_cq *cq;
    unsigned int nqp, rr;
    unsigned int *read_out;              /* [nqp] per-QP outstanding READ */
    unsigned int ord_limit;              /* per-QP READ gate (input/negotiated) */
    unsigned int outstanding, window;
    char *bounce_base;
    uint64_t *bounce_free;               /* bitmap, [bounce_words] */
    unsigned int bounce_words, bounce_slots;
    char *staging_base;
    uint64_t *staging_free;              /* bitmap, [staging_words] */
    unsigned int staging_words, staging_slots;
    /* per-post/drain scratch, sized by ext_batch (no stack arrays -> no cap) */
    unsigned int batch;
    struct ibv_send_wr *wrs;
    struct ibv_sge *sg;
    struct obj_io **ios;
    struct ibv_wc *wc;
    struct ibv_sge *sync_sg;
    obj_io *wait_head, *wait_tail;
    atomic_uint_fast64_t drain_calls, drain_empty, wait_enq;
    /* 완료 경로 회계는 worker가 소유한다. 전역 stats_mutex를 핫패스에서
     * 잡으면 worker 수에 따라 경합이 커진다. 읽기는 get_stats에서 합산. */
    atomic_uint_fast64_t objects_read, bytes_read, objects_written, bytes_written;
    uint64_t prof_r_count, prof_r_sum_ns;
    uint64_t prof_r_crypto_ns, prof_r_sync_ns, prof_r_xfer_ns;
    uint32_t prof_r_hist[PROF_BUCKETS];
    uint64_t prof_w_count, prof_w_sum_ns;
    uint64_t prof_w_crypto_ns, prof_w_sync_ns, prof_w_xfer_ns;
    uint32_t prof_w_hist[PROF_BUCKETS];
} store_worker;

struct store_engine {
    struct ibv_pd *pd;
    uint64_t raddr; uint32_t rkey;       /* genie MR */
    store_page *pages;
    store_page **page_buckets;           /* active page per bucket */
    store_page *free_pages;              /* stack of unused pages */
    struct loc_stack *freeloc;           /* [page_bucketcount] */
    size_t page_size;
    unsigned int page_count, page_bucketcount;
    unsigned int slot_size, read_slots;
    store_worker **workers;
    unsigned int worker_count, w_nqp, w_window;
    char *wbounce_base;
    struct ibv_mr *wbounce_mr;
    char *wstaging_base;                 /* P2b */
    struct ibv_mr *wstaging_mr;
    unsigned int w_staging_slots, write_slots;
    unsigned int ord_limit, batch;
    struct sockaddr_in peer;
    atomic_uint_fast64_t dead;           /* QP error -> fail-fast */
    pthread_mutex_t mutex;               /* pages / buckets / freeloc */
    struct extstore_stats stats;
    pthread_mutex_t stats_mutex;
};

const char *extstore_err(enum extstore_res res) {
    const char *rv = "unknown error";
    switch (res) {
        case EXTSTORE_INIT_OOM: rv = "failed to allocate engine"; break;
        case EXTSTORE_INIT_OPEN_FAIL: rv = "failed to open RDMA device / connect genie"; break;
        case EXTSTORE_INIT_SELFTEST_FAIL:
            rv = "remote memory self-test failed (see extstore selftest lines above)"; break;
        default: break;
    }
    return rv;
}

/* RDMA CM is synchronous during worker setup. Genie returns the remote MR
 * (addr, rkey, size) in the first connection's accept private_data. */
static int cm_wait(struct rdma_event_channel *ch, enum rdma_cm_event_type want,
                   struct rdma_cm_event **out) {
    struct rdma_cm_event *ev;
    if (rdma_get_cm_event(ch, &ev)) return -1;
    if (ev->event != want) {
        fprintf(stderr, "extstore rdma_cm: expected %s but got %s (status %d)\n",
                rdma_event_str(want), rdma_event_str(ev->event), ev->status);
        rdma_ack_cm_event(ev); return -1;
    }
    if (out) *out = ev; else rdma_ack_cm_event(ev);
    return 0;
}

/* ---- init ---- */

/* EXT_SELFTEST=1: write a known pattern to remote memory and RDMA READ it back
 * before serving traffic. Exists because a write can succeed at every layer that
 * reports status — clean CQE, objects_written++, no engine_dead — and still
 * deposit zeros in the remote MR when the local buffer is not synced to the
 * device (SEV SWIOTLB). Nothing else in this engine can see that; the data is
 * only discovered to be garbage on read-back, long after the benchmark ran.
 * Opt-in, so the client can still be brought up for connect/latency work while
 * the kernel-side sync is missing. */
static int selftest(store_engine *e, store_worker *w) {
    unsigned int len = e->slot_size < 256 ? e->slot_size : 256;
    unsigned char *src = (unsigned char *)w->staging_base;
    unsigned char *dst = (unsigned char *)w->bounce_base;
    for (unsigned int i = 0; i < len; i++) src[i] = (unsigned char)(0x5A ^ (i * 31));
    memset(dst, 0, len);

    /* page 0 offset 0: no object lives there yet (pages are handed out top-down) */
    for (int pass = 0; pass < 2; pass++) {          /* 0 = WRITE out, 1 = READ back */
        struct ibv_sge sg = { .addr = (uintptr_t)(pass ? dst : src), .length = len,
            .lkey = pass ? e->wbounce_mr->lkey : e->wstaging_mr->lkey };
        struct ibv_send_wr *bad, wr = { .wr_id = (uint64_t)pass, .sg_list = &sg,
            .num_sge = 1, .send_flags = IBV_SEND_SIGNALED,
            .opcode = pass ? IBV_WR_RDMA_READ : IBV_WR_RDMA_WRITE };
        wr.wr.rdma.remote_addr = e->raddr;
        wr.wr.rdma.rkey = e->rkey;
        if (!pass) {
            /* push staging to the device before the NIC reads it (same sync the
             * real WRITE path uses) — else the NIC transmits pre-DMA zeros */
            int adv = ibv_advise_mr(e->pd, IBV_ADVISE_MR_ADVICE_SYNC_FOR_DEVICE,
                                    IBV_ADVISE_MR_FLAG_FLUSH, &sg, 1);
            if (adv)
                fprintf(stderr, "extstore selftest: SYNC_FOR_DEVICE advise failed: %s\n",
                        strerror(adv));
        }
        if (ibv_post_send(w->qp[0], &wr, &bad)) {
            fprintf(stderr, "extstore selftest: post_send(%s) failed: %s\n",
                    pass ? "READ" : "WRITE", strerror(errno));
            return -1;
        }
        struct ibv_wc wc;
        int c = 0;
        for (long spin = 0; spin < 500000000L && c == 0; spin++)
            c = ibv_poll_cq(w->cq, 1, &wc);
        if (c <= 0) {
            fprintf(stderr, "extstore selftest: no completion for %s\n",
                    pass ? "READ" : "WRITE");
            return -1;
        }
        if (wc.status != IBV_WC_SUCCESS) {
            fprintf(stderr, "extstore selftest: %s completed with status %s (%d)\n",
                    pass ? "READ" : "WRITE", ibv_wc_status_str(wc.status), wc.status);
            return -1;
        }
        if (pass) {
            /* sync the bounce SWIOTLB->private before the CPU reads it back */
            int adv = ibv_advise_mr(e->pd, IBV_ADVISE_MR_ADVICE_SYNC_FOR_CPU,
                                    IBV_ADVISE_MR_FLAG_FLUSH, &sg, 1);
            if (adv)
                fprintf(stderr, "extstore selftest: SYNC_FOR_CPU advise failed: %s\n",
                        strerror(adv));
        }
    }

    if (memcmp(src, dst, len) == 0) {
        fprintf(stderr, "extstore selftest: OK (%u bytes written and read back)\n", len);
        return 0;
    }
    unsigned int i = 0;
    while (i < len && src[i] == dst[i]) i++;
    fprintf(stderr, "extstore selftest: FAILED — remote memory does not hold what "
            "we wrote. First mismatch at byte %u: sent 0x%02x, read back 0x%02x.\n",
            i, src[i], dst[i]);
    fprintf(stderr, "extstore selftest: read-back is %s. Both transfers reported "
            "success, so the transport works and the payload does not — on SEV this "
            "is the SWIOTLB sync (SYNC_FOR_DEVICE on staging, SYNC_FOR_CPU on "
            "bounce) missing from mlx5_ib.\n",
            dst[i] == 0 ? "all zero (pre-DMA contents)" : "different data");
    return -1;
}

void *extstore_init(struct extstore_conf_file *fh, struct extstore_conf *cf,
        enum extstore_res *res) {
    store_engine *e = calloc(1, sizeof(*e));
    if (!e) { *res = EXTSTORE_INIT_OOM; return NULL; }

    e->page_size = cf->page_size;
    e->page_bucketcount = cf->page_buckets ? cf->page_buckets : 1;
    e->slot_size = cf->slot_size;
    e->read_slots = cf->read_slots < 1 ? 1 : cf->read_slots;
    e->write_slots = cf->write_slots ? cf->write_slots : 256;
    e->ord_limit = cf->ord_limit;                 /* 0 = use negotiated */
    e->batch = cf->batch ? cf->batch : EXT_BATCH_DEFAULT;
    e->peer = (struct sockaddr_in){ .sin_family = AF_INET,
        .sin_port = htons(fh->cport) };
    if (inet_pton(AF_INET, fh->file, &e->peer.sin_addr) != 1) {
        *res = EXTSTORE_INIT_OPEN_FAIL;
        free(e);
        return NULL;
    }
    pthread_mutex_init(&e->mutex, NULL);
    pthread_mutex_init(&e->stats_mutex, NULL);
    atomic_store(&e->dead, 0);
    if (getenv("EXT_RDMA_PROF")) { g_prof_on = 1; prof_calibrate(); }
    { const char *v = getenv("EXT_SKIP_DMA_SYNC");
      if (v && atoi(v)) {
        g_skip_dma_sync = 1;
        fprintf(stderr, "extstore: DMA sync advise DISABLED (snp_shared direct)\n");
      } }
    return e;
}

/* ---- allocation (SPEC §2.4 / P-1) ---- */

/* caller holds e->mutex */
static store_page *grab_active(store_engine *e, unsigned int bucket, unsigned int len) {
    store_page *p = e->page_buckets[bucket];
    if (p && p->allocated + len <= e->page_size) return p;
    if (!e->free_pages) return NULL;
    p = e->free_pages; e->free_pages = p->next;
    p->free = false; p->active = true; p->bucket = bucket; p->allocated = 0;
    e->page_buckets[bucket] = p;
    STAT_L(e);
    e->stats.pages_free--; e->stats.pages_used++; e->stats.page_allocs++;
    STAT_UL(e);
    return p;
}

int extstore_alloc(void *ptr, unsigned int len, unsigned int bucket, struct ext_loc *out) {
    store_engine *e = ptr;
    if (bucket >= e->page_bucketcount) bucket = 0;
    if (len > e->slot_size) return -1;
    pthread_mutex_lock(&e->mutex);
    struct loc_stack *fs = &e->freeloc[bucket];
    /* A freed loc carries the *previous* object's len. Reuse its physical slot
     * only if that slot is at least as large as this request (else a bigger
     * object would overrun the neighbour), and stamp the caller's real len so
     * the stub and the sealed object agree — otherwise a 500-byte slot reused
     * for a 499-byte object leaves the stub claiming 500 while the seal wrote
     * 499, and every GET RDMA-READs one byte too many and fails GCM forever.
     * ponytail: LIFO top-only check + conservative shrink (recorded len can
     * only decrease); for the fixed-size workload every len matches so this is
     * exact recycling. A size-class free-list would reclaim more under mixed
     * sizes — add if fragmentation shows up. */
    if (fs->top > 0 && fs->arr[fs->top-1].len >= len) {
        *out = fs->arr[--fs->top];
        out->len = len;
        store_page *p = &e->pages[out->page_id];
        pthread_mutex_lock(&p->mutex);
        p->obj_count++;
        p->bytes_used += len;
        pthread_mutex_unlock(&p->mutex);
        STAT_L(e);
        e->stats.bytes_used += len;
        e->stats.objects_used++;
        STAT_UL(e);
        pthread_mutex_unlock(&e->mutex);
        return 0;
    }
    store_page *p = grab_active(e, bucket, len);
    if (!p) { pthread_mutex_unlock(&e->mutex); return -1; }
    out->page_id = p->id; out->page_version = p->version;
    out->offset = p->allocated; out->len = len;
    p->allocated += len; p->obj_count++; p->bytes_used += len;
    STAT_L(e);
    e->stats.bytes_used += len; e->stats.objects_used++;
    STAT_UL(e);
    pthread_mutex_unlock(&e->mutex);
    return 0;
}

void extstore_free_loc(void *ptr, const struct ext_loc *loc) {
    store_engine *e = ptr;
    pthread_mutex_lock(&e->mutex);
    if (loc->page_id >= e->page_count || loc->len == 0 ||
            loc->offset + loc->len > e->page_size) {
        STAT_L(e); e->stats.slot_acct_leak++; STAT_UL(e);
        pthread_mutex_unlock(&e->mutex);
        return;
    }
    store_page *p = &e->pages[loc->page_id];
    STAT_L(e);
    bool bad = p->version != loc->page_version ||
        p->bucket >= e->page_bucketcount || p->obj_count == 0 ||
        p->bytes_used < loc->len || e->stats.objects_used == 0 ||
        e->stats.bytes_used < loc->len;
    if (bad) {
        e->stats.slot_acct_leak++;
        STAT_UL(e);
        pthread_mutex_unlock(&e->mutex);
        return;
    }
    STAT_UL(e);
    unsigned int bucket = p->bucket;
    struct loc_stack *fs = &e->freeloc[bucket];
    if (fs->top == fs->cap) {
        int cap = fs->cap ? fs->cap * 2 : 64;
        struct ext_loc *arr = realloc(fs->arr, cap * sizeof(*arr));
        if (!arr) {
            STAT_L(e); e->stats.slot_acct_leak++; STAT_UL(e);
            pthread_mutex_unlock(&e->mutex);
            return;
        }
        fs->arr = arr;
        fs->cap = cap;
    }
    fs->arr[fs->top++] = *loc;
    p->obj_count--;
    p->bytes_used -= loc->len;
    STAT_L(e);
    e->stats.bytes_used -= loc->len;
    e->stats.objects_used--;
    STAT_UL(e);
    pthread_mutex_unlock(&e->mutex);
}

/* ---- v2 worker-inline READ/WRITE path ---- */

/* Slot bitmaps. One word covers 64 slots, so the <=64 case costs exactly the
 * same single ffsll as the old scalar bitmap; wider pools just loop. */
static inline int bm_alloc(uint64_t *bm, unsigned int words) {
    for (unsigned int i = 0; i < words; i++) {
        if (bm[i]) {
            int b = __builtin_ffsll((long long)bm[i]) - 1;
            bm[i] &= ~(1ULL << b);
            return (int)(i * 64) + b;
        }
    }
    return -1;
}

static inline void bm_free(uint64_t *bm, int slot) {
    bm[slot / 64] |= 1ULL << (slot % 64);
}

static inline uint64_t *bm_new(unsigned int slots, unsigned int *words_out) {
    unsigned int words = (slots + 63) / 64;
    uint64_t *bm = calloc(words, sizeof(uint64_t));
    if (!bm) return NULL;
    for (unsigned int i = 0; i < slots; i++) bm[i / 64] |= 1ULL << (i % 64);
    *words_out = words;
    return bm;
}

static _Thread_local store_worker *g_drain_worker = NULL;

void *extstore_worker_current(void) { return g_drain_worker; }

unsigned int extstore_worker_outstanding(void *worker) {
    return worker ? ((store_worker *)worker)->outstanding : 0;
}

static int cm_connect_worker_qp(store_engine *e, store_worker *w,
        unsigned int worker_id, unsigned int qi, bool first,
        uint64_t *size_out) {
#define WCM_FAIL(step) do { fprintf(stderr,         "extstore rdma_cm: %s failed (worker %u qp %u): %s\n",         step, worker_id, qi, strerror(errno)); return -1; } while (0)
    struct rdma_event_channel *ch = rdma_create_event_channel();
    if (!ch) WCM_FAIL("create_event_channel");
    if (rdma_create_id(ch, &w->cm_id[qi], NULL, RDMA_PS_TCP))
        WCM_FAIL("create_id");
    if (rdma_resolve_addr(w->cm_id[qi], NULL, (struct sockaddr *)&e->peer,
                          CM_TIMEOUT_MS))
        WCM_FAIL("resolve_addr");
    if (cm_wait(ch, RDMA_CM_EVENT_ADDR_RESOLVED, NULL))
        WCM_FAIL("ADDR_RESOLVED event");
    if (rdma_resolve_route(w->cm_id[qi], CM_TIMEOUT_MS))
        WCM_FAIL("resolve_route");
    if (cm_wait(ch, RDMA_CM_EVENT_ROUTE_RESOLVED, NULL))
        WCM_FAIL("ROUTE_RESOLVED event");

    if (first) {
        e->pd = ibv_alloc_pd(w->cm_id[qi]->verbs);
        if (!e->pd) WCM_FAIL("alloc_pd");
    }
    if (!w->cq) {
        w->cq = ibv_create_cq(w->cm_id[qi]->verbs,
                2 * w->window * w->nqp, NULL, NULL, 0);
        if (!w->cq) WCM_FAIL("create_cq");
    }
    struct ibv_qp_init_attr ia = { .send_cq = w->cq, .recv_cq = w->cq,
        .qp_type = IBV_QPT_RC, .cap = { .max_send_wr = w->window + 1,
            .max_recv_wr = 1, .max_send_sge = 1, .max_recv_sge = 1 } };
    if (rdma_create_qp(w->cm_id[qi], e->pd, &ia)) WCM_FAIL("create_qp");
    w->qp[qi] = w->cm_id[qi]->qp;

    /* Ask for the configured ORD; 0 means "ask for the device maximum and take
     * whatever the CM negotiates". The negotiated value is adopted below unless
     * the operator pinned one explicitly. */
    unsigned int ask = e->ord_limit;
    if (ask == 0) {
        struct ibv_device_attr da;
        ask = (ibv_query_device(w->cm_id[qi]->verbs, &da) == 0 &&
               da.max_qp_rd_atom > 0) ? (unsigned int)da.max_qp_rd_atom : 16;
    }
    struct rdma_conn_param cp = { .responder_resources = (uint8_t)ask,
        .initiator_depth = (uint8_t)ask, .retry_count = 7, .rnr_retry_count = 7 };
    struct rdma_cm_event *ev;
    if (rdma_connect(w->cm_id[qi], &cp)) WCM_FAIL("connect");
    if (cm_wait(ch, RDMA_CM_EVENT_ESTABLISHED, &ev))
        WCM_FAIL("ESTABLISHED event");
    /* Adopt the negotiated depth when the operator did not pin one. A pinned
     * value is honoured verbatim even if it exceeds what the HCA negotiated —
     * the excess simply queues in the SQ, which is a measurable outcome. */
    if (e->ord_limit == 0) {
        unsigned int neg = ev->param.conn.initiator_depth;
        w->ord_limit = neg ? neg : ask;
    }
    if (first) {
        if (ev->param.conn.private_data_len < sizeof(struct xrd_mr_info)) {
            rdma_ack_cm_event(ev);
            return -1;
        }
        struct xrd_mr_info mi;
        memcpy(&mi, ev->param.conn.private_data, sizeof(mi));
        e->raddr = mi.raddr;
        e->rkey = mi.rkey;
        *size_out = mi.size;
    }
    rdma_ack_cm_event(ev);
    return 0;
#undef WCM_FAIL
}

static int pages_init(store_engine *e, uint64_t rsize) {
    e->page_count = rsize / e->page_size;
    if (e->page_count == 0) return -1;
    e->pages = calloc(e->page_count, sizeof(store_page));
    e->page_buckets = calloc(e->page_bucketcount, sizeof(store_page *));
    e->freeloc = calloc(e->page_bucketcount, sizeof(struct loc_stack));
    if (!e->pages || !e->page_buckets || !e->freeloc) return -1;
    for (unsigned int i = 0; i < e->page_count; i++) {
        store_page *p = &e->pages[i];
        pthread_mutex_init(&p->mutex, NULL);
        p->id = i;
        p->version = 1;
        p->remote_off = (uint64_t)i * e->page_size;
        p->free = true;
        p->next = e->free_pages;
        e->free_pages = p;
    }
    e->stats.page_count = e->page_count;
    e->stats.page_size = e->page_size;
    e->stats.pages_free = e->page_count;
    return 0;
}

int extstore_workers_prepare(void *ptr, unsigned int nworkers,
                             unsigned int nqp, unsigned int window) {
    store_engine *e = ptr;
    if (!e || nworkers == 0) return -1;
    /* Functional floors only. No upper clamp: an oversized setting is the
     * operator's experiment, and its cost is a measurement (see md/). */
    if (nqp < 1) nqp = 1;
    if (window < 1) window = 1;
    e->w_nqp = nqp;
    e->w_window = window;
    e->worker_count = nworkers;
    e->workers = calloc(nworkers, sizeof(store_worker *));
    if (!e->workers) return -1;

    for (unsigned int i = 0; i < nworkers; i++) {
        store_worker *w = calloc(1, sizeof(*w));
        if (!w) return -1;
        w->e = e;
        w->nqp = nqp;
        w->window = window;
        w->batch = e->batch;
        w->ord_limit = e->ord_limit;   /* may be replaced by negotiated value */
        w->cm_id = calloc(nqp, sizeof(*w->cm_id));
        w->qp = calloc(nqp, sizeof(*w->qp));
        w->read_out = calloc(nqp, sizeof(*w->read_out));
        w->wrs = calloc(w->batch, sizeof(*w->wrs));
        w->sg = calloc(w->batch, sizeof(*w->sg));
        w->ios = calloc(w->batch, sizeof(*w->ios));
        w->wc = calloc(w->batch, sizeof(*w->wc));
        w->sync_sg = calloc(w->batch, sizeof(*w->sync_sg));
        if (!w->cm_id || !w->qp || !w->read_out || !w->wrs || !w->sg ||
            !w->ios || !w->wc || !w->sync_sg) return -1;
        e->workers[i] = w;
    }

    uint64_t rsize = 0;
    for (unsigned int i = 0; i < nworkers; i++) {
        store_worker *w = e->workers[i];
        for (unsigned int qi = 0; qi < nqp; qi++)
            if (cm_connect_worker_qp(e, w, i, qi, i == 0 && qi == 0, &rsize))
                return -1;
    }
    fprintf(stderr, "extstore: genie_connect OK (raddr=0x%lx rkey=0x%x size=%lu, "
            "workers=%u qps/worker=%u window=%u ord=%u%s batch=%u)\n",
            (unsigned long)e->raddr, e->rkey, (unsigned long)rsize, nworkers,
            nqp, window, e->workers[0]->ord_limit,
            e->ord_limit ? " pinned" : " negotiated", e->batch);

    size_t bsz = (size_t)nworkers * e->read_slots * e->slot_size;
    e->wbounce_base = dma_alloc(bsz);
    if (!e->wbounce_base) return -1;
    e->wbounce_mr = ibv_reg_mr(e->pd, e->wbounce_base, bsz,
                               IBV_ACCESS_LOCAL_WRITE);
    if (!e->wbounce_mr) {
        fprintf(stderr, "extstore: reg_mr(worker bounce %zuB) failed: %s\n",
                bsz, strerror(errno));
        return -1;
    }

    e->w_staging_slots = e->write_slots / nworkers;
    if (e->w_staging_slots < 1) e->w_staging_slots = 1;
    size_t ssz = (size_t)nworkers * e->w_staging_slots * e->slot_size;
    e->wstaging_base = dma_alloc(ssz);
    if (!e->wstaging_base) return -1;
    e->wstaging_mr = ibv_reg_mr(e->pd, e->wstaging_base, ssz,
                                IBV_ACCESS_LOCAL_WRITE);
    if (!e->wstaging_mr) {
        fprintf(stderr, "extstore: reg_mr(worker staging %zuB) failed: %s\n",
                ssz, strerror(errno));
        return -1;
    }

    for (unsigned int i = 0; i < nworkers; i++) {
        store_worker *w = e->workers[i];
        w->bounce_base = e->wbounce_base
            + (size_t)i * e->read_slots * e->slot_size;
        w->bounce_slots = e->read_slots;
        w->bounce_free = bm_new(w->bounce_slots, &w->bounce_words);
        w->staging_slots = e->w_staging_slots;
        w->staging_base = e->wstaging_base
            + (size_t)i * e->w_staging_slots * e->slot_size;
        w->staging_free = bm_new(w->staging_slots, &w->staging_words);
        if (!w->bounce_free || !w->staging_free) return -1;
    }

    if (getenv("EXT_SELFTEST") && selftest(e, e->workers[0]) != 0)
        return -1;
    if (pages_init(e, rsize) != 0) return -1;
    fprintf(stderr, "extstore: no IO threads (worker-inline READ/WRITE)\n");
    return 0;
}

void *extstore_worker_create(void *ptr, unsigned int worker_id) {
    store_engine *e = ptr;
    if (!e || !e->workers || worker_id >= e->worker_count) return NULL;
    return e->workers[worker_id];
}

/* Post as much of the chain as window/ORD/slots allow; excess to wait list.
 * Runs only on the owning worker thread. */
static void worker_post(store_worker *w, obj_io *chain) {
    store_engine *e = w->e;
    struct ibv_send_wr *wrs = w->wrs, *bad;
    struct ibv_sge *sg = w->sg;
    obj_io **ios = (obj_io **)w->ios;

    while (chain) {
        if (atomic_load(&e->dead)) {
            obj_io *nx; for (obj_io *p = chain; p; p = nx) { nx = p->next; p->cb(e, p, -1); }
            return;
        }
        /* pick a QP with ORD headroom (rr sweep) */
        unsigned int qi = UINT_MAX;
        for (unsigned int k = 0; k < w->nqp; k++) {
            unsigned int cand = (w->rr + k) % w->nqp;
            if (w->read_out[cand] < w->ord_limit) { qi = cand; break; }
        }
        int n = 0;
        while (chain && (unsigned int)n < w->batch && w->outstanding < w->window &&
               qi != UINT_MAX && w->read_out[qi] + n < w->ord_limit) {
            int slot = bm_alloc(w->bounce_free, w->bounce_words);
            if (slot < 0) break;                    /* bounce pool exhausted */
            obj_io *io = chain;
            chain = io->next;
            io->next = NULL;
            io->buf = w->bounce_base + (size_t)slot * e->slot_size;
            io->wqp = qi;
            sg[n] = (struct ibv_sge){ .addr = (uintptr_t)io->buf, .length = io->len,
                .lkey = e->wbounce_mr->lkey };
            wrs[n] = (struct ibv_send_wr){ .wr_id = (uintptr_t)io, .sg_list = &sg[n],
                .num_sge = 1, .send_flags = IBV_SEND_SIGNALED,
                .opcode = IBV_WR_RDMA_READ };
            wrs[n].wr.rdma.remote_addr = e->raddr +
                    e->pages[io->page_id].remote_off + io->offset;
            wrs[n].wr.rdma.rkey = e->rkey;
            wrs[n].next = NULL;
            if (n) wrs[n-1].next = &wrs[n];
            ios[n] = io;
            n++;
            w->outstanding++;            /* provisional; rolled back on error */
        }
        if (n == 0) {
            /* no capacity: park the rest on the wait list */
            while (chain || n == 0) {
                obj_io *io = chain;
                if (!io) break;
                chain = io->next; io->next = NULL;
                if (w->wait_tail) w->wait_tail->next = io; else w->wait_head = io;
                w->wait_tail = io;
                atomic_fetch_add(&w->wait_enq, 1);
            }
            /* also park nothing else to do */
            break;
        }
        w->rr = (ios[n-1]->wqp + 1) % w->nqp;
        if (g_prof_on) {
            uint64_t ts = prof_rdtsc();
            for (int i = 0; i < n; i++) { ios[i]->t_start = ts; ios[i]->t_end = 0; }
        }
        if (ibv_post_send(w->qp[ios[0]->wqp], &wrs[0], &bad)) {
            atomic_store(&e->dead, 1);
            STAT_L(e); e->stats.engine_dead = 1; STAT_UL(e);
            for (int i = 0; i < n; i++) {
                obj_io *io = ios[i];
                w->outstanding--;
                bm_free(w->bounce_free,
                        (int)((io->buf - w->bounce_base) / e->slot_size));
                STAT_L(e); e->stats.read_failures++; STAT_UL(e);
                io->cb(e, io, -1);
            }
            return;
        }
        w->read_out[ios[0]->wqp] += n;
    }
}

/* P2b: worker-private staging slot (no lock; owner-only). */
char *extstore_worker_staging_get(void *worker) {
    store_worker *w = worker;
    if (!w) return NULL;
    int slot = bm_alloc(w->staging_free, w->staging_words);
    if (slot < 0) return NULL;
    return w->staging_base + (size_t)slot * w->e->slot_size;
}

void extstore_worker_staging_put(void *worker, char *slot) {
    store_worker *w = worker;
    if (!w || !slot) return;
    bm_free(w->staging_free, (int)((slot - w->staging_base) / w->e->slot_size));
}

/* P2b: post one WRITE inline. WRITE is exempt from ORD (READ-only limit) but
 * still counts against the worker window. Returns 0 on post. */
int extstore_worker_post_write(void *worker, obj_io *io) {
    store_worker *w = worker;
    store_engine *e = w->e;
    if (atomic_load(&e->dead)) return -1;
    if (w->outstanding >= w->window) return EAGAIN;
    unsigned int qi = w->rr % w->nqp;
    struct ibv_sge sg = { .addr = (uintptr_t)io->buf, .length = io->len,
        .lkey = e->wstaging_mr->lkey };
    /* push the sealed bytes to the device before the NIC reads them */
    uint64_t t_sync_start = g_prof_on ? prof_rdtsc() : 0;
    if (g_prof_on && io->t_start && io->t_end >= io->t_start)
        w->prof_w_crypto_ns += (uint64_t)((io->t_end - io->t_start) * g_ns_per_cycle);
    int adv = g_skip_dma_sync ? 0
            : ibv_advise_mr(e->pd, IBV_ADVISE_MR_ADVICE_SYNC_FOR_DEVICE,
                            IBV_ADVISE_MR_FLAG_FLUSH, &sg, 1);
    static _Atomic int w_dev_warned;
    if (adv && !atomic_exchange(&w_dev_warned, 1))
        fprintf(stderr, "extstore: worker SYNC_FOR_DEVICE advise failed: %s\n",
                strerror(adv));
    if (g_prof_on) {
        uint64_t ts = prof_rdtsc();
        w->prof_w_sync_ns += (uint64_t)((ts - t_sync_start) * g_ns_per_cycle);
        io->t_end = ts;
    }
    struct ibv_send_wr *bad, wr = { .wr_id = (uintptr_t)io, .sg_list = &sg,
        .num_sge = 1, .send_flags = IBV_SEND_SIGNALED, .opcode = IBV_WR_RDMA_WRITE };
    wr.wr.rdma.remote_addr = e->raddr + e->pages[io->page_id].remote_off + io->offset;
    wr.wr.rdma.rkey = e->rkey;
    wr.next = NULL;
    io->wqp = qi;
    if (ibv_post_send(w->qp[qi], &wr, &bad)) {
        atomic_store(&e->dead, 1);
        STAT_L(e); e->stats.engine_dead = 1; e->stats.write_failures++; STAT_UL(e);
        return -1;
    }
    w->outstanding++;
    w->rr = (qi + 1) % w->nqp;
    return 0;
}

int extstore_worker_submit(void *worker, obj_io *chain) {
    store_worker *w = worker;
    if (!w) return -1;
    if (atomic_load(&w->e->dead)) {
        obj_io *nx; for (obj_io *p = chain; p; p = nx) { nx = p->next; p->cb(w->e, p, -1); }
        return -1;
    }
    /* FIFO fairness: drain any parked ops first */
    if (w->wait_head) {
        obj_io *parked = w->wait_head;
        w->wait_head = w->wait_tail = NULL;
        obj_io *tail = parked; while (tail->next) tail = tail->next;
        tail->next = chain;
        chain = parked;
    }
    worker_post(w, chain);
    return 0;
}

int extstore_worker_drain(void *worker, int budget) {
    store_worker *w = worker;
    store_engine *e = w->e;
    struct ibv_wc *wc = w->wc;
    struct ibv_sge *sync_sg = w->sync_sg;
    if (budget < 1) budget = 1;
    if ((unsigned int)budget > w->batch) budget = (int)w->batch;

    atomic_fetch_add(&w->drain_calls, 1);
    int c = ibv_poll_cq(w->cq, budget, wc);
    if (c <= 0) {
        atomic_fetch_add(&w->drain_empty, 1);
        return atomic_load(&e->dead) ? -1 : 0;
    }

    uint64_t t_poll = g_prof_on ? prof_rdtsc() : 0;
    int nsync = 0;
    for (int i = 0; i < c; i++) {
        obj_io *io = (obj_io *)(uintptr_t)wc[i].wr_id;
        if (io->mode == OBJ_IO_READ && wc[i].status == IBV_WC_SUCCESS)
            sync_sg[nsync++] = (struct ibv_sge){ .addr = (uintptr_t)io->buf,
                .length = io->len, .lkey = e->wbounce_mr->lkey };
    }
    if (nsync && !g_skip_dma_sync) {
        int adv = ibv_advise_mr(e->pd, IBV_ADVISE_MR_ADVICE_SYNC_FOR_CPU,
                                IBV_ADVISE_MR_FLAG_FLUSH, sync_sg, nsync);
        static _Atomic int w_advise_warned;
        if (adv && !atomic_exchange(&w_advise_warned, 1))
            fprintf(stderr, "extstore: worker SYNC_FOR_CPU advise failed: %s"
                    " — bounce reads are not being synced\n", strerror(adv));
    }
    uint64_t t_sync_done = g_prof_on ? prof_rdtsc() : 0;

    uint64_t nwritten = 0, bwritten = 0;
    g_drain_worker = w;
    for (int i = 0; i < c; i++) {
        obj_io *io = (obj_io *)(uintptr_t)wc[i].wr_id;
        int ok = (wc[i].status == IBV_WC_SUCCESS);
        int is_read = (io->mode == OBJ_IO_READ);
        unsigned int len = io->len;
        char *buf = io->buf;
        unsigned int qi = io->wqp;
        if (g_prof_on && ok && io->t_start) {
            if (is_read) {
                w->prof_r_xfer_ns += (uint64_t)((t_poll - io->t_start) * g_ns_per_cycle);
                w->prof_r_sync_ns += (uint64_t)((t_sync_done - t_poll) * g_ns_per_cycle);
                io->t_end = t_sync_done;
            } else {
                prof_record(w->prof_w_hist, &w->prof_w_count, &w->prof_w_sum_ns,
                            t_poll - io->t_start);
                w->prof_w_xfer_ns += (uint64_t)((t_poll - io->t_end) * g_ns_per_cycle);
            }
        }
        if (!ok) {
            atomic_store(&e->dead, 1);
            STAT_L(e);
            e->stats.engine_dead = 1;
            if (is_read) e->stats.read_failures++; else e->stats.write_failures++;
            STAT_UL(e);
        }
        /* cb may re-submit (retry) — it grabs a fresh slot; free ours after. */
        io->cb(e, io, ok ? (int)len : -1);
        if (is_read) {
            bm_free(w->bounce_free, (int)((buf - w->bounce_base) / e->slot_size));
            w->read_out[qi]--;
        } else if (ok) {
            nwritten++; bwritten += len;
        }
        w->outstanding--;
    }
    g_drain_worker = NULL;

    if (nwritten) {
        atomic_fetch_add(&w->objects_written, nwritten);
        atomic_fetch_add(&w->bytes_written, bwritten);
    }
    if (nsync) {
        uint64_t br = 0;
        for (int i = 0; i < nsync; i++) br += sync_sg[i].length;
        atomic_fetch_add(&w->objects_read, (uint64_t)nsync);
        atomic_fetch_add(&w->bytes_read, br);
    }

    /* refill from the wait list with the freed capacity */
    if (w->wait_head && !atomic_load(&e->dead)) {
        obj_io *parked = w->wait_head;
        w->wait_head = w->wait_tail = NULL;
        worker_post(w, parked);
    }
    return atomic_load(&e->dead) ? -1 : c;
}

/* ---- misc API kept for storage.c ---- */

int extstore_check(void *ptr, unsigned int page_id, uint64_t page_version) {
    store_engine *e = ptr;
    if (page_id >= e->page_count) return -1;
    store_page *p = &e->pages[page_id];
    pthread_mutex_lock(&p->mutex);
    int rv = (p->version == page_version) ? 0 : -1;
    pthread_mutex_unlock(&p->mutex);
    return rv;
}

/* Sum per-worker histograms and pull avg / p50 / p99 (ns). */
static void prof_summarize(store_engine *e, int read,
        uint64_t *count, uint64_t *avg, uint64_t *p50, uint64_t *p99) {
    uint64_t merged[PROF_BUCKETS]; memset(merged, 0, sizeof(merged));
    uint64_t total = 0, sum = 0;
    if (e->workers) {
        for (unsigned int i = 0; i < e->worker_count; i++) {
            store_worker *w = e->workers[i];
            if (!w) continue;
            total += read ? w->prof_r_count : w->prof_w_count;
            sum   += read ? w->prof_r_sum_ns : w->prof_w_sum_ns;
            uint32_t *h = read ? w->prof_r_hist : w->prof_w_hist;
            for (int b = 0; b < PROF_BUCKETS; b++) merged[b] += h[b];
        }
    }
    *count = total; *avg = total ? sum / total : 0;
    *p50 = *p99 = 0;
    if (!total) return;
    uint64_t c = 0, need50 = (total + 1) / 2, need99 = (total * 99 + 99) / 100;
    int f50 = 0, f99 = 0;
    for (int b = 0; b < PROF_BUCKETS && !(f50 && f99); b++) {
        c += merged[b];
        if (!f50 && c >= need50) { *p50 = (uint64_t)b * PROF_BUCKET_NS; f50 = 1; }
        if (!f99 && c >= need99) { *p99 = (uint64_t)b * PROF_BUCKET_NS; f99 = 1; }
    }
}

void extstore_get_stats(void *ptr, struct extstore_stats *st) {
    store_engine *e = ptr;
    STAT_L(e);
    struct extstore_page_data *pd = st->page_data;
    *st = e->stats;
    st->page_data = pd;
    STAT_UL(e);
    st->worker_window = e->w_window;
    st->worker_drain_calls = 0;
    st->worker_drain_empty = 0;
    st->worker_wait_enq = 0;
    for (unsigned int i = 0; i < e->worker_count; i++) {
        store_worker *w = e->workers[i];
        if (!w) continue;
        st->worker_drain_calls += atomic_load(&w->drain_calls);
        st->worker_drain_empty += atomic_load(&w->drain_empty);
        st->worker_wait_enq += atomic_load(&w->wait_enq);
        st->objects_read += atomic_load(&w->objects_read);
        st->bytes_read += atomic_load(&w->bytes_read);
        st->objects_written += atomic_load(&w->objects_written);
        st->bytes_written += atomic_load(&w->bytes_written);
    }
    if (g_prof_on) {
        prof_summarize(e, 1, &st->prof_read_count, &st->prof_read_avg_ns,
                       &st->prof_read_p50_ns, &st->prof_read_p99_ns);
        prof_summarize(e, 0, &st->prof_write_count, &st->prof_write_avg_ns,
                       &st->prof_write_p50_ns, &st->prof_write_p99_ns);
        uint64_t rc = 0, wc = 0, rs = 0, rx = 0, ws = 0, wx = 0;
        if (e->workers) {
            for (unsigned int i = 0; i < e->worker_count; i++) {
                store_worker *w = e->workers[i];
                if (!w) continue;
                rc += w->prof_r_crypto_ns; wc += w->prof_w_crypto_ns;
                rs += w->prof_r_sync_ns; rx += w->prof_r_xfer_ns;
                ws += w->prof_w_sync_ns; wx += w->prof_w_xfer_ns;
            }
        }
        st->prof_read_crypto_avg_ns = st->prof_read_count ? rc / st->prof_read_count : 0;
        st->prof_write_crypto_avg_ns = st->prof_write_count ? wc / st->prof_write_count : 0;
        st->prof_read_sync_avg_ns  = st->prof_read_count  ? rs / st->prof_read_count  : 0;
        st->prof_read_xfer_avg_ns  = st->prof_read_count  ? rx / st->prof_read_count  : 0;
        st->prof_write_sync_avg_ns = st->prof_write_count ? ws / st->prof_write_count : 0;
        st->prof_write_xfer_avg_ns = st->prof_write_count ? wx / st->prof_write_count : 0;
    }
}

void extstore_prof_reset(void *ptr) {
    store_engine *e = ptr;
    if (e->workers) {
        for (unsigned int i = 0; i < e->worker_count; i++) {
            store_worker *w = e->workers[i];
            if (!w) continue;
            w->prof_r_count = w->prof_r_sum_ns = 0;
            w->prof_w_count = w->prof_w_sum_ns = 0;
            w->prof_r_crypto_ns = w->prof_r_sync_ns = w->prof_r_xfer_ns = 0;
            w->prof_w_crypto_ns = w->prof_w_sync_ns = w->prof_w_xfer_ns = 0;
            memset(w->prof_r_hist, 0, sizeof(w->prof_r_hist));
            memset(w->prof_w_hist, 0, sizeof(w->prof_w_hist));
        }
    }
}

uint64_t extstore_prof_stamp(void) {
    return g_prof_on ? prof_rdtsc() : 0;
}

void extstore_prof_read_done(void *ptr, obj_io *io,
        uint64_t crypto_start, uint64_t crypto_done) {
    if (!g_prof_on || !io->t_start || !io->t_end ||
            crypto_done < crypto_start)
        return;
    (void)ptr;
    store_worker *w = g_drain_worker;
    if (!w) return;
    prof_record(w->prof_r_hist, &w->prof_r_count, &w->prof_r_sum_ns,
                crypto_done - io->t_start);
    w->prof_r_crypto_ns += (uint64_t)
            ((crypto_done - crypto_start) * g_ns_per_cycle);
    io->t_start = io->t_end = 0;
}

void extstore_get_page_data(void *ptr, struct extstore_stats *st) {
    store_engine *e = ptr;
    if (!st->page_data) return;
    for (unsigned int i = 0; i < e->page_count; i++) {
        store_page *p = &e->pages[i];
        st->page_data[i].version = p->version;
        st->page_data[i].bytes_used = p->bytes_used;
        st->page_data[i].bucket = p->bucket;
        st->page_data[i].active = p->active;
    }
}
