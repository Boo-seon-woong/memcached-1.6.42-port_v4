/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
#include "memcached.h"
#ifdef EXTSTORE

#include "storage.h"
#include "extstore.h"
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>
#include <ctype.h>
/* ponytail: #include the .c so the crypto TU rides along without a Makefile
 * object-list edit (autotools 1.17 regen is unavailable here). */
#include "ext_crypto.c"

// Single remote size-class for the fixed-size RDMA workload (P-1a).
#define PAGE_BUCKET_DEFAULT 0
#define PAGE_BUCKET_COUNT   1
/* v3 pac: SYNC_FOR_DEVICE 배치 큐의 하드 상한 (ext_setq_max의 최대값) */
#define SETQ_HARD_MAX 64

static bool g_crypto_on = false;
static unsigned int g_read_retries = 3;   // integrity-read retry cap (EXT_READ_RETRIES)
/* v2 (P2a): completions parked during a drain, flushed by the drain caller. */
static _Thread_local iop_head_t g_ret_head;
/* 큐 상한 경로가 item_lock(hv) 아래에서 flush를 부르므로, 그때 재개하면
 * storage_set_return_cb가 같은 버킷의 item_lock을 다시 잡아 데드락이다.
 * 충돌하는 것만 여기로 빼고 나머지는 그 자리에서 재개한다 — 버킷이 겹칠
 * 확률은 1/2^item_lock_power 이라 사실상 전부 즉시 재개된다. */
static _Thread_local iop_head_t g_ret_defer;
static _Thread_local bool g_ret_defer_init;
static _Thread_local unsigned int g_reap_tick;
/* 체인 없이 요청마다 ibv_post_send 를 부르면 mlx5 의 QP 당 스핀락을 매번
 * 잡는다(프로파일: pthread_spin_lock +0.093, _mlx5_post_send +0.051 µs/op).
 * K 건을 모아 한 번에 넘기면 둘 다 1/K 이 되고, 대신 앞쪽 요청의 admit 이
 * 최대 K-1 건의 파싱만큼 늘어난다 — 건당 0.1 µs 수준이라 span 예산 안이다. */
#define POST_CHAIN_MAX 32
static _Thread_local obj_io *g_chain_head, *g_chain_tail;
static _Thread_local unsigned int g_chain_n;

static void pending_chain_flush(LIBEVENT_THREAD *t) {
    if (g_chain_head == NULL) return;
    obj_io *h = g_chain_head;
    g_chain_head = g_chain_tail = NULL; g_chain_n = 0;
    extstore_worker_submit(t->ext_worker, h);
}
static _Thread_local conn *g_skip_conn;  /* 지금 파싱 중이라 재개하면 안 되는 연결 */

static _Thread_local bool g_ret_init = false;
static unsigned int g_qp_per_worker = 1;  // v2 P2a (ext_qp_per_worker)
static unsigned int g_loc_mag_depth = 64; // v3 (ext_loc_mag_depth); extstore.c의 기본값과 일치
static _Atomic uint64_t g_read_retry_ct = 0;
static _Atomic uint64_t g_worker_write_spins = 0;
/* v3 pac 카운터 */
static _Atomic uint64_t g_pac_posted = 0;     /* pending으로 수락된 SET */
static _Atomic uint64_t g_pac_fail = 0;       /* WRITE 실패로 게시 롤백 */
static _Atomic uint64_t g_pac_fallback = 0;   /* 자원 부족 → 동기 폴백 */
/* v3: SYNC_FOR_DEVICE 배치 큐. flushes 대비 writes가 상각 계수다. */
static _Atomic uint64_t g_setq_flushes = 0;
static _Atomic uint64_t g_setq_writes = 0;
/* 기본 1 = 배치 없음. 실측(축소 규모 스윕): batch 64는 Sspan 254.7 µs, 1은
 * 13.7 µs이고 처리량 차이는 2.68M → 2.24M(−16%)뿐이다. 관리자 우선순위가
 * "span < 30 µs가 10M보다 중요"이므로 span 쪽을 기본으로 둔다. 처리량을
 * 되찾으려면 ext_setq_max를 올리되 span을 함께 확인할 것. */
static unsigned int g_setq_max = 1;              /* ext_setq_max */
static _Atomic uint64_t g_badcrc_log_ct = 0;      // rate-limit for the badcrc diagnostic
static _Atomic uint64_t g_flush_log_ct = 0;       // rate-limit for the flush diagnostic

/* Problem B probes (genie). The pre-read reject path had no counter at all: a GET
 * of a stub can be answered as a miss before any RDMA read happens, and nothing
 * recorded it — which is why "permanently unreadable" looked like the same fault
 * as a torn read. These name which path it is. */
static _Atomic uint64_t g_abort_chunked = 0;   /* P-6: item too large */
static _Atomic uint64_t g_abort_alloc = 0;     /* no read destination available */
static _Atomic uint64_t g_plaintext_slab_fallback = 0;
static unsigned int g_plaintext_slot_size;
static _Thread_local cache_t *g_plaintext_cache;

/* 4096 offered requests / 8 workers = 512 nominal; leave burst headroom. */
#define PLAINTEXT_POOL_LIMIT 1024

/* EXT_TRACE_SEAL=1: table indexed by nonce counter (dense, monotonic) recording
 * who sealed each object and at what length, so a badcrc can compare the length
 * it read against the length actually written. No write-path I/O: logging every
 * seal would change the timing of the race being observed. */
#define SEAL_TRACE_MAX (1u << 21)
struct seal_rec { uint32_t page, off, len; char key[24]; };
static struct seal_rec *g_seal_tab;

static uint64_t nonce_counter(const void *obj) {   /* [salt 4][counter 8] */
    uint64_t c; memcpy(&c, (const char *)obj + 4, 8); return c;
}

typedef struct {
    int done;
    int ret;
} store_wait;

/* v2 (P2b): inline path never initialises mutex/cond — the writer spins on
 * `done` and reaps the completion from its own drain on the same thread. */
static void storage_store_done_cb(void *e, obj_io *io, int ret) {
    (void)e;
    store_wait *w = io->data;
    w->ret = ret;
    w->done = 1;
}

/*
 * API functions
 */
static void storage_finalize_cb(io_pending_t *pending);
static void storage_return_cb(io_pending_t *pending);

// re-cast an io_pending_t into this more descriptive structure.
// the first few items _must_ match the original struct.
typedef struct _io_pending_storage_t {
    uint8_t io_queue_type;
    uint8_t io_sub_type;
    uint8_t payload; // payload offset
    LIBEVENT_THREAD *thread;
    conn *c;
    mc_resp *resp;
    io_queue_cb return_cb;    // called on worker thread.
    io_queue_cb finalize_cb;  // called back on the worker thread.
    STAILQ_ENTRY(io_pending_t) iop_next; // queue chain.
                              /* original struct ends here */
    item *hdr_it;             /* original header item. */
    item *read_it;            /* decrypt destination (RDMA: != io.buf bounce slot) */
    unsigned int read_clsid;  /* slab class of read_it, for freeing */
    cache_t *read_cache;      /* worker-private cache, NULL for slab fallback */
    obj_io io_ctx;            /* embedded extstore IO header */
    unsigned int iovec_data;  /* specific index of data iovec */
    bool noreply;             /* whether the response had noreply set */
    bool miss;                /* signal a miss to unlink hdr_it */
    bool badcrc;              /* signal a crc failure */
    bool active;              /* tells if IO was dispatched or not */
} io_pending_storage_t;

// Only call this if item has ITEM_HDR
bool storage_validate_item(void *e, item *it) {
    item_hdr *hdr = (item_hdr *)ITEM_data(it);
    if (extstore_check(e, hdr->page_id, hdr->page_version) != 0) {
        return false;
    } else {
        return true;
    }
}

/* item_free 훅. unlink 가 아니라 실제 소멸에서 회수해야 in-flight READ 가
 * 보호된다 — GET 은 hdr_it 에 refcount 를 쥐므로 그동안 여기 오지 않는다.
 * 상류는 unlink 에서 회수해도 됐다. 페이지 버전이 낡은 읽기를 잡아줬기
 * 때문인데, 이 포트는 슬롯 단위로 재활용하고 버전을 올리지 않아 그 안전망이
 * 없다(extstore.c:534). */
void storage_free_hdr(item *it) {
    if (ext_storage) storage_delete(ext_storage, it);
}

void storage_delete(void *e, item *it) {
    if (it->it_flags & ITEM_HDR) {
        /* v3 pac: WRITE가 아직 wire에 있는 stub. 지금 loc을 회수하면 그 슬롯을
         * 재할당받은 다른 SET의 WRITE와 겹친다 — 회수는 완료 콜백
         * (storage_set_return_cb)이 unlink 여부를 보고 한다. 이 검사와 플래그
         * 해제는 모두 item_lock(hv) 아래에서 일어난다 (유일한 락-밖 호출자인
         * GET-miss 경로는 badcrc면 stub을 남기므로 WFLIGHT stub을 지우지 않는다). */
        if (it->it_flags & ITEM_WFLIGHT) return;
        item_hdr *hdr = (item_hdr *)ITEM_data(it);
        if (hdr->len == 0) return;          /* 이미 회수됐거나 게시 전이다 */
        struct ext_loc loc = { hdr->page_version, hdr->offset, hdr->len, hdr->page_id };
        extstore_free_loc(e, &loc);
        hdr->len = 0;                       /* 두 번 회수하지 않는다 */
    }
}

// Function for the extra stats called from a protocol.
// NOTE: This either needs a name change or a wrapper, perhaps?
// it's defined here to reduce exposure of extstore.h to the rest of memcached
// but feels a little off being defined here.
// At very least maybe "process_storage_stats" in line with making this more
// of a generic wrapper module.
void storage_prof_reset(void) {
    if (ext_storage) extstore_prof_reset(ext_storage);
}

void process_extstore_stats(ADD_STAT add_stats, void *c) {
    int i;
    char key_str[STAT_KEY_LEN];
    char val_str[STAT_VAL_LEN];
    int klen = 0, vlen = 0;
    struct extstore_stats st;

    assert(add_stats);

    void *storage = ext_storage;
    if (storage == NULL) {
        return;
    }
    extstore_get_stats(storage, &st);
    st.page_data = calloc(st.page_count, sizeof(struct extstore_page_data));
    extstore_get_page_data(storage, &st);

    for (i = 0; i < st.page_count; i++) {
        APPEND_NUM_STAT(i, "version", "%llu",
                (unsigned long long) st.page_data[i].version);
        APPEND_NUM_STAT(i, "bytes", "%llu",
                (unsigned long long) st.page_data[i].bytes_used);
        APPEND_NUM_STAT(i, "bucket", "%u",
                st.page_data[i].bucket);
    }

    free(st.page_data);
}

// Additional storage stats for the main stats output.
void storage_stats(ADD_STAT add_stats, void *c) {
    struct extstore_stats st;
    if (ext_storage) {
        extstore_get_stats(ext_storage, &st);
        APPEND_STAT("extstore_page_allocs", "%llu", (unsigned long long)st.page_allocs);
        APPEND_STAT("extstore_pages_free", "%llu", (unsigned long long)st.pages_free);
        APPEND_STAT("extstore_pages_used", "%llu", (unsigned long long)st.pages_used);
        APPEND_STAT("extstore_objects_read", "%llu", (unsigned long long)st.objects_read);
        APPEND_STAT("extstore_objects_written", "%llu", (unsigned long long)st.objects_written);
        APPEND_STAT("extstore_objects_used", "%llu", (unsigned long long)st.objects_used);
        APPEND_STAT("extstore_bytes_written", "%llu", (unsigned long long)st.bytes_written);
        APPEND_STAT("extstore_bytes_read", "%llu", (unsigned long long)st.bytes_read);
        APPEND_STAT("extstore_bytes_used", "%llu", (unsigned long long)st.bytes_used);
        APPEND_STAT("extstore_limit_maxbytes", "%llu", (unsigned long long)(st.page_count * st.page_size));
        APPEND_STAT("extstore_io_queue", "%llu", (unsigned long long)(st.io_queue));
        // RDMA bring-up debug counters (SPEC §8). Nonzero = look here first.
        APPEND_STAT("extstore_engine_dead", "%llu", (unsigned long long)st.engine_dead);
        APPEND_STAT("extstore_write_failures", "%llu", (unsigned long long)st.write_failures);
        APPEND_STAT("extstore_read_failures", "%llu", (unsigned long long)st.read_failures);
        APPEND_STAT("extstore_read_retries", "%llu",
                (unsigned long long)atomic_load(&g_read_retry_ct));
        APPEND_STAT("extstore_get_aborted_chunked", "%llu",
                (unsigned long long)atomic_load(&g_abort_chunked));
        APPEND_STAT("extstore_get_aborted_alloc", "%llu",
                (unsigned long long)atomic_load(&g_abort_alloc));
        APPEND_STAT("extstore_plaintext_slab_fallback", "%llu",
                (unsigned long long)atomic_load(&g_plaintext_slab_fallback));
        APPEND_STAT("ext_worker_window", "%llu",
                (unsigned long long)st.worker_window);
        APPEND_STAT("ext_qp_per_worker", "%llu",
                (unsigned long long)st.qp_per_worker);
        APPEND_STAT("ext_ord_limit", "%llu",
                (unsigned long long)st.ord_limit);
        APPEND_STAT("ext_read_slots", "%llu",
                (unsigned long long)st.read_slots);
        APPEND_STAT("ext_loc_mag_depth", "%llu",
                (unsigned long long)g_loc_mag_depth);
        APPEND_STAT("ext_worker_drain_calls", "%llu",
                (unsigned long long)st.worker_drain_calls);
        APPEND_STAT("ext_worker_drain_empty", "%llu",
                (unsigned long long)st.worker_drain_empty);
        APPEND_STAT("ext_worker_wait_enq", "%llu",
                (unsigned long long)st.worker_wait_enq);
        APPEND_STAT("ext_worker_write_spins", "%llu",
                (unsigned long long)atomic_load(&g_worker_write_spins));
        APPEND_STAT("ext_pac_posted", "%llu",
                (unsigned long long)atomic_load(&g_pac_posted));



        APPEND_STAT("ext_pac_fail", "%llu",
                (unsigned long long)atomic_load(&g_pac_fail));
        APPEND_STAT("ext_pac_fallback", "%llu",
                (unsigned long long)atomic_load(&g_pac_fallback));
        APPEND_STAT("ext_setq_max", "%u", g_setq_max);
        APPEND_STAT("ext_seal_at_flush", "%s",
                settings.ext_seal_at_flush ? "yes" : "no");
        APPEND_STAT("ext_setq_flushes", "%llu",
                (unsigned long long)atomic_load(&g_setq_flushes));
        APPEND_STAT("ext_setq_writes", "%llu",
                (unsigned long long)atomic_load(&g_setq_writes));
        APPEND_STAT("ext_slot_acct_leak", "%llu",
                (unsigned long long)st.slot_acct_leak);
        APPEND_STAT("extstore_alloc_failures", "%llu",
                (unsigned long long)st.alloc_failures);
        /* 계약이 판정에 쓰는 정의다. 2026-08-01 에 v2 → v3 로 넓혔는데
         * 이 값이 2 로 박혀 있었다 — 서버가 자기 정의를 틀리게 알리고 있었고
         * 그 사이 아무도 읽지 않았다(2026-08-05 발견).
         * v2 성분(_avg_ns 계열)은 분해용으로 계속 노출한다. 아래 참조. */
        APPEND_STAT("extstore_prof_span_ver", "%u", 3);
        // Span v2 distribution (ns); populated only under EXT_RDMA_PROF=1.
        // v3 = admit + (이 v2 구간) + ret.  v3 는 _e2e_ 접두를 쓴다.
        APPEND_STAT("extstore_prof_read_count", "%llu", (unsigned long long)st.prof_read_count);
        APPEND_STAT("extstore_prof_read_avg_ns", "%llu", (unsigned long long)st.prof_read_avg_ns);
        APPEND_STAT("extstore_prof_read_p50_ns", "%llu", (unsigned long long)st.prof_read_p50_ns);
        APPEND_STAT("extstore_prof_read_p99_ns", "%llu", (unsigned long long)st.prof_read_p99_ns);
        APPEND_STAT("extstore_prof_write_count", "%llu", (unsigned long long)st.prof_write_count);
        APPEND_STAT("extstore_prof_write_avg_ns", "%llu", (unsigned long long)st.prof_write_avg_ns);
        APPEND_STAT("extstore_prof_write_p50_ns", "%llu", (unsigned long long)st.prof_write_p50_ns);
        APPEND_STAT("extstore_prof_write_p99_ns", "%llu", (unsigned long long)st.prof_write_p99_ns);
        APPEND_STAT("extstore_prof_read_crypto_avg_ns", "%llu",
                (unsigned long long)st.prof_read_crypto_avg_ns);
        APPEND_STAT("extstore_prof_write_crypto_avg_ns", "%llu",
                (unsigned long long)st.prof_write_crypto_avg_ns);
        // breakout: crypto, sync (SWIOTLB advise), transfer, avg ns.
        APPEND_STAT("extstore_prof_read_sync_avg_ns", "%llu", (unsigned long long)st.prof_read_sync_avg_ns);
        APPEND_STAT("extstore_prof_read_xfer_avg_ns", "%llu", (unsigned long long)st.prof_read_xfer_avg_ns);
        APPEND_STAT("extstore_prof_write_sync_avg_ns", "%llu", (unsigned long long)st.prof_write_sync_avg_ns);
        APPEND_STAT("extstore_prof_write_xfer_avg_ns", "%llu", (unsigned long long)st.prof_write_xfer_avg_ns);
        /* span v3 — backend 진입부터. READ: storage_get_item 진입 → 복호·태그
         * 검증 완료. WRITE: storage_store_item_pac 진입 → WFLIGHT 해제.
         * v2 가 빼는 admission/queue 대기와 완료 관측 지연이 여기 들어온다. */
        APPEND_STAT("extstore_prof_read_e2e_count", "%llu", (unsigned long long)st.prof_read_e2e_count);
        APPEND_STAT("extstore_prof_read_e2e_avg_ns", "%llu", (unsigned long long)st.prof_read_e2e_avg_ns);
        APPEND_STAT("extstore_prof_bk_count",  "%llu", (unsigned long long)st.prof_bk_count);
        APPEND_STAT("extstore_prof_bk_avg_ns", "%llu", (unsigned long long)st.prof_bk_avg_ns);
        APPEND_STAT("extstore_prof_bk_p50_ns", "%llu", (unsigned long long)st.prof_bk_p50_ns);
        APPEND_STAT("extstore_prof_bk_p99_ns", "%llu", (unsigned long long)st.prof_bk_p99_ns);
        APPEND_STAT("extstore_prof_srv_count",  "%llu", (unsigned long long)st.prof_srv_count);
        APPEND_STAT("extstore_prof_srv_avg_ns", "%llu", (unsigned long long)st.prof_srv_avg_ns);
        APPEND_STAT("extstore_prof_srv_p50_ns", "%llu", (unsigned long long)st.prof_srv_p50_ns);
        APPEND_STAT("extstore_prof_srv_p99_ns", "%llu", (unsigned long long)st.prof_srv_p99_ns);
        APPEND_STAT("extstore_prof_que_count",  "%llu", (unsigned long long)st.prof_que_count);
        APPEND_STAT("extstore_prof_que_avg_ns", "%llu", (unsigned long long)st.prof_que_avg_ns);
        APPEND_STAT("extstore_prof_que_p50_ns", "%llu", (unsigned long long)st.prof_que_p50_ns);
        APPEND_STAT("extstore_prof_que_p99_ns", "%llu", (unsigned long long)st.prof_que_p99_ns);
        APPEND_STAT("extstore_prof_read_e2e_p50_ns", "%llu", (unsigned long long)st.prof_read_e2e_p50_ns);
        APPEND_STAT("extstore_prof_read_e2e_p99_ns", "%llu", (unsigned long long)st.prof_read_e2e_p99_ns);
        APPEND_STAT("extstore_prof_write_e2e_count", "%llu", (unsigned long long)st.prof_write_e2e_count);
        APPEND_STAT("extstore_prof_write_e2e_avg_ns", "%llu", (unsigned long long)st.prof_write_e2e_avg_ns);
        APPEND_STAT("extstore_prof_write_e2e_p50_ns", "%llu", (unsigned long long)st.prof_write_e2e_p50_ns);
        APPEND_STAT("extstore_prof_write_e2e_p99_ns", "%llu", (unsigned long long)st.prof_write_e2e_p99_ns);
        /* v3 성분 분해: v3 = admit + (v2 구간) + ret */
        APPEND_STAT("extstore_prof_read_admit_avg_ns", "%llu", (unsigned long long)st.prof_read_admit_avg_ns);
        APPEND_STAT("extstore_prof_write_admit_avg_ns", "%llu", (unsigned long long)st.prof_write_admit_avg_ns);
        APPEND_STAT("extstore_prof_write_ret_avg_ns", "%llu", (unsigned long long)st.prof_write_ret_avg_ns);
    }

}

// This callback runs inline while the owning worker drains its CQ.
static void _storage_get_item_cb(void *e, obj_io *io, int ret) {
    io_pending_storage_t *p = (io_pending_storage_t *)io->data;
    mc_resp *resp = p->resp;
    assert(p->active == true);
    item *read_it = p->read_it;   // decrypt destination (io->buf is the bounce slot)
    bool miss = false;

    if (ret < 1) {
        miss = true;
    } else if (g_crypto_on) {
        // bounce slot holds [nonce|ciphertext|tag]; open into read_it image.
        uint32_t hv = hash(ITEM_key(p->hdr_it), p->hdr_it->nkey);
        struct ext_aad aad = { .hv = hv, .page_id = io->page_id, .pad = 0,
            .offset = io->offset, .page_version = io->page_version };
        uint64_t crypto_start = extstore_prof_stamp();
        int opened = ext_crypto_open(read_it, (uint8_t *)io->buf, io->len, &aad);
        extstore_prof_read_done(e, io, crypto_start, extstore_prof_stamp());
        if (opened < 0) {
            // Retry a transient DMA visibility failure; never serve unverified data.
            if (io->retries++ < g_read_retries) {
                atomic_fetch_add(&g_read_retry_ct, 1);
                io->next = NULL;
                /* v2 (P2a): re-post on the worker whose drain is running. */
                void *w = extstore_worker_current();
                assert(w != NULL);
                extstore_worker_submit(w, io);
                return;
            }
            miss = true;
            p->badcrc = true;
                // Diagnostic (genie's request): a permanently-unreadable key means
                // the stub's AAD no longer matches the object in its slot. Log the
                // expected loc, whether the page version still matches, and the
                // slot's stored nonce (first 12B = boot_salt||counter, identifies
                // which object actually lives there). First N only.
                if (atomic_fetch_add(&g_badcrc_log_ct, 1) < 32) {
                    const unsigned char *n = (const unsigned char *)io->buf;
                    int pv_ok = (extstore_check(e, io->page_id, io->page_version) == 0);
                    fprintf(stderr, "extstore badcrc: key=%.*s stub{page=%u off=%u ver=%u len=%u} "
                        "page_ver_match=%d slot_nonce=%02x%02x%02x%02x.%02x%02x%02x%02x%02x%02x%02x%02x\n",
                        p->hdr_it->nkey, ITEM_key(p->hdr_it),
                        io->page_id, io->offset, io->page_version, io->len, pv_ok,
                        n[0],n[1],n[2],n[3],n[4],n[5],n[6],n[7],n[8],n[9],n[10],n[11]);
                    if (g_seal_tab) {
                        uint64_t ctr = nonce_counter(io->buf);
                        struct seal_rec *r = ctr < SEAL_TRACE_MAX ? &g_seal_tab[ctr] : NULL;
                        if (r && r->key[0])
                            fprintf(stderr, "extstore badcrc: ^ slot holds key=%s sealed at "
                                "page=%u off=%u len=%u; we read len=%u -> %s\n",
                                r->key, r->page, r->off, r->len, io->len,
                                r->len == io->len ? "LENGTH MATCHES" : "LENGTH MISMATCH");
                        else
                            fprintf(stderr, "extstore badcrc: ^ no seal record (counter %llu)\n",
                                (unsigned long long)ctr);
                    }
                }
                // GCM writes the (unverified) plaintext into read_it BEFORE the
                // tag check, so a failed open left read_it's header garbage;
                // reset it_flags so slabs_free doesn't take the chunked path on a
                // bogus header (ASAN SEGV, slabs.c:468).
                read_it->it_flags = 0;
                read_it->slabs_clsid = p->read_clsid;
        }
    } else {
        uint64_t crypto_start = extstore_prof_stamp();
        memcpy(read_it, io->buf, io->len);   // crypto off: io->len == ntotal
        extstore_prof_read_done(e, io, crypto_start, extstore_prof_stamp());
    }

    if (miss) {
        if (p->noreply) {
            // In all GET cases, noreply means we send nothing back.
            resp->skip = true;
        } else {
            // TODO: This should be movable to the worker thread.
            // Convert the binprot response into a miss response.
            // The header requires knowing a bunch of stateful crap, so rather
            // than simply writing out a "new" miss response we mangle what's
            // already there.
            if (resp->binary_prot) {
                protocol_binary_response_header *header =
                    (protocol_binary_response_header *)resp->wbuf;

                // cut the extra nbytes off of the body_len
                uint32_t body_len = ntohl(header->response.bodylen);
                uint8_t hdr_len = header->response.extlen;
                body_len -= resp->iov[p->iovec_data].iov_len + hdr_len;
                resp->tosend -= resp->iov[p->iovec_data].iov_len + hdr_len;
                header->response.extlen = 0;
                header->response.status = (uint16_t)htons(PROTOCOL_BINARY_RESPONSE_KEY_ENOENT);
                header->response.bodylen = htonl(body_len);

                // truncate the data response.
                resp->iov[p->iovec_data].iov_len = 0;
                // wipe the extlen iov... wish it was just a flat buffer.
                resp->iov[p->iovec_data-1].iov_len = 0;
                resp->chunked_data_iov = 0;
            } else {
                int i;
                // Meta commands have EN status lines for miss, rather than
                // END as a trailer as per normal ascii.
                if (resp->iov[0].iov_len >= 3
                        && memcmp(resp->iov[0].iov_base, "VA ", 3) == 0) {
                    // TODO: These miss translators should use specific callback
                    // functions attached to the io wrap. This is weird :(
                    resp->iovcnt = 1;
                    resp->iov[0].iov_len = 4;
                    resp->iov[0].iov_base = "EN\r\n";
                    resp->tosend = 4;
                } else {
                    // Wipe the iovecs up through our data injection.
                    // Allows trailers to be returned (END)
                    for (i = 0; i <= p->iovec_data; i++) {
                        resp->tosend -= resp->iov[i].iov_len;
                        resp->iov[i].iov_len = 0;
                        resp->iov[i].iov_base = NULL;
                    }
                }
                resp->chunked_total = 0;
                resp->chunked_data_iov = 0;
            }
        }
        p->miss = true;
    } else {
        assert(read_it->slabs_clsid != 0);
        // TODO: should always use it instead of ITEM_data to kill more
        // chunked special casing.
        if ((read_it->it_flags & ITEM_CHUNKED) == 0) {
            resp->iov[p->iovec_data].iov_base = ITEM_data(read_it);
        }
        p->miss = false;
    }

    p->active = false;
    //assert(c->io_wrapleft >= 0);

    /* v2 (P2a): this cb runs on the owning worker thread inside the drain
     * loop. Returning the conn here would re-enter the event loop (and this
     * very worker's submit path) while the drain is still reconciling bounce
     * slots and window accounting. Park it; the drain caller flushes after
     * the loop, so re-entrancy depth stays 1 (spec §6 R6). */
    if (!g_ret_init) { STAILQ_INIT(&g_ret_head); g_ret_init = true; }
    STAILQ_INSERT_TAIL(&g_ret_head, (io_pending_t *)p, iop_next);
}

int storage_get_item(LIBEVENT_THREAD *t, item *it, mc_resp *resp) {
    /* span v3 시작 — backend 진입. v2 는 실제 post 시점(worker_post)에서
     * 시작해 admission·bounce slot 대기를 통째로 빠뜨린다. */
    uint64_t t_enter_v3 = extstore_prof_stamp();
    if (resp) resp->t_enter = t_enter_v3;   /* pre/post 분해용 */
#ifdef NEED_ALIGN
    item_hdr hdr;
    memcpy(&hdr, ITEM_data(it), sizeof(hdr));
#else
    item_hdr *hdr = (item_hdr *)ITEM_data(it);
#endif
    io_queue_t *q = thread_io_queue_get(t, IO_QUEUE_EXTSTORE);
    size_t ntotal = ITEM_ntotal(it);
    unsigned int clsid = slabs_clsid(ntotal);
    item *new_it;
    cache_t *read_cache = NULL;
    if (ntotal > settings.slab_chunk_size_max) {
        // P-6: chunked items unsupported on the RDMA backend.
        atomic_fetch_add(&g_abort_chunked, 1);
        return -1;
    }
    if (ntotal <= g_plaintext_slot_size) {
        if (g_plaintext_cache == NULL) {
            g_plaintext_cache = cache_create("extstore-plaintext",
                    g_plaintext_slot_size, sizeof(char *));
            if (g_plaintext_cache != NULL)
                cache_set_limit(g_plaintext_cache, PLAINTEXT_POOL_LIMIT);
        }
        if (g_plaintext_cache != NULL) {
            new_it = do_cache_alloc(g_plaintext_cache);
            if (new_it != NULL)
                read_cache = g_plaintext_cache;
        } else {
            new_it = NULL;
        }
    } else {
        new_it = NULL;
    }
    if (new_it == NULL) {
        atomic_fetch_add(&g_plaintext_slab_fallback, 1);
        new_it = do_item_alloc_pull(ntotal, clsid);
    }
    if (new_it == NULL) {
        atomic_fetch_add(&g_abort_alloc, 1);
        return -1;
    }
    // so we can free the chunk on a miss
    new_it->slabs_clsid = clsid;

    io_pending_storage_t *p = do_cache_alloc(t->io_cache);
    // this is a re-cast structure, so assert that we never outsize it.
    assert(sizeof(io_pending_t) >= sizeof(io_pending_storage_t));
    memset(p, 0, sizeof(io_pending_storage_t));
    p->active = true;
    p->miss = false;
    p->badcrc = false;
    p->noreply = resp->noreply;
    /* 호출자는 storage_get_item 이 돌아온 뒤에야 c 를 채우고 suspend 한다
     * (proto_text.c: resp->io_pending->c = c; conn_resp_suspend). 인라인 post
     * 뒤 그 자리에서 drain 하면 **방금 post 한 자기 자신의 완료**가 잡힐 수
     * 있는데(co-located RDMA 5 µs), 그때 c 가 NULL 이면 재개가
     * conn_resp_unsuspend(NULL, ...) 로 죽는다(실측 segfault at 0xfc).
     * 여기서 미리 채워두면 아래 g_skip_conn 검사가 자기 자신도 걸러낸다. */
    p->c = t->cur_conn;
    p->thread = t;
    p->return_cb = storage_return_cb;
    p->finalize_cb = storage_finalize_cb;
    // io_pending owns the reference for this object now.
    p->hdr_it = it;
    p->read_it = new_it;
    p->read_clsid = clsid;
    p->read_cache = read_cache;
    p->resp = resp;
    p->io_queue_type = IO_QUEUE_EXTSTORE;
    p->payload = offsetof(io_pending_storage_t, io_ctx);
    obj_io *eio = &p->io_ctx;

    // Reserve a response iov (data base filled in by the callback after decrypt).
    p->iovec_data = resp->iovcnt;
    int iovtotal = (resp->binary_prot) ? it->nbytes - 2 : it->nbytes;
    resp_add_iov(resp, "", iovtotal);

    // We can't bail out anymore, so mc_resp owns the IO from here.
    resp->io_pending = (io_pending_t *)p;
    t->ext_resident++;          /* 여기부터 span v3 안이다 */

    eio->buf = NULL;   // engine assigns a bounce slot at post time

    /* 인라인 제출이면 큐를 거치지 않는다 — 아래에서 eio 가 다 채워진 뒤
     * 그 자리에서 post 한다. 큐에 넣어두면 이 연결의 나머지 요청이 전부
     * 파싱될 때까지 기다리고, 그 대기가 span v3 의 admit 이다. */
    if (!settings.ext_submit_inline)
        STAILQ_INSERT_TAIL(&q->stack, (io_pending_t *)p, iop_next);

    // reference ourselves for the callback.
    eio->data = (void *)p;

    // Fill in the remote location from our header.
#ifdef NEED_ALIGN
    eio->page_version = hdr.page_version;
    eio->page_id = hdr.page_id;
    eio->offset = hdr.offset;
    eio->len = hdr.len;
#else
    eio->page_version = hdr->page_version;
    eio->page_id = hdr->page_id;
    eio->offset = hdr->offset;
    eio->len = hdr->len;   // remote object length (ntotal + crypto overhead)
#endif
    eio->retries = 0;
    eio->mode = OBJ_IO_READ;
    eio->t_enter = t_enter_v3;
    eio->cb = _storage_get_item_cb;

    /* span v3 로 드러난 구조 문제: 6a~6e·7 은 전부 워커 전용 로컬 작업이라
     * 200 ns 면 끝나는데, 8(제출)이 연결 파싱이 끝날 때까지 미뤄져 있어
     * 먼저 파싱된 요청이 같은 배치의 나머지를 기다린다. 실측 admit 6.96 µs
     * (batch=0, 배치 12건 → 건당 0.58 µs).
     *
     * 여기서 바로 post 하면 그 대기가 사라진다. 대가는 체인이 1건이라
     * 도어벨이 배치당 1회에서 건당 1회로 는다 — _mlx5_post_send 가
     * 0.026 µs/op 이므로 6.96 µs 와 바꿀 만하다. */
    if (settings.ext_submit_inline) {
        eio->next = NULL;
        if (g_chain_tail) g_chain_tail->next = eio; else g_chain_head = eio;
        g_chain_tail = eio;
        if (++g_chain_n >= settings.ext_post_chain || g_chain_n >= POST_CHAIN_MAX)
            pending_chain_flush(t);
        /* post 한 자리에서 완료도 거둔다. 인라인 이전에는 제출이 pass 시작에
         * 몰려 바로 뒤에 drain 이 왔는데, 이제 제출이 파싱 도중에 흩어지므로
         * pass 끝의 drain 까지 CQE 가 기다린다 — GET 에서 걷어낸 대기가
         * SET 의 ret 로 옮겨간다(실측 0.29 → 26.98 µs).
         * 지금 파싱 중인 연결만 빼고 재개한다. */
        /* cur_conn 을 모르면 재개하지 않는다. 지금 파싱 중인 연결을 재개하면
         * drive_machine 이 아직 그 연결을 돌고 있는 채로 conn_worker_readd 가
         * 걸린다(실측: 서버 즉사). 디스패치 경로를 하나라도 빠뜨리면 그렇게
         * 되므로, 완전성에 기대지 않고 모를 때는 안 한다 — pass 끝의 flush 가
         * 어차피 처리한다. */
        /* drain 이 실제로 뭔가 거뒀을 때만 재개한다. 0 이어도 매번 부르게
         * 했더니 서버가 멈췄다 — meta-get 경로(limited_get_locked)는
         * item_lock 을 쥔 채 여기 들어오고, storage_set_return_cb 가 같은
         * 락을 다시 잡는다. 호출 빈도를 올리자 그 창이 열렸다. 보류분은
         * pass 끝 flush 가 처리한다. */
        /* 수거를 K 건마다로 상각한다. post 마다 하면 span 은 최소가 되지만
         * poll + flush 가 op 당 비용으로 온전히 붙는다(무제한 기준선 대비
         * CPU/op 2.51 → 3.80). span 예산이 30 인데 6 밖에 안 쓰고 있으므로
         * 그 여유를 처리량으로 바꾼다 — 늦게 수거하면 v2 가 최대 K/2 건만큼
         * 늘어난다. */
        if (t->cur_conn != NULL && ++g_reap_tick >= settings.ext_reap_every) {
            pending_chain_flush(t);
            g_reap_tick = 0;
            extstore_worker_drain(t->ext_worker, 32);
            g_skip_conn = t->cur_conn;
            storage_flush_returns();
            g_skip_conn = NULL;
        }
        worker_storage_arm_drain(t);
    }

    // FIXME: This stat needs to move to reflect # of flash hits vs misses
    // for now it's a good gauge on how often we request out to flash at
    // least.
    THR_STATS_LOCK(t);
    t->stats.get_extstore++;
    THR_STATS_UNLOCK(t);

    return 0;
}

void storage_submit_cb(io_queue_t *q) {
    // IOP's are converted into an obj_io chain just before submission.
    void *eio_head = NULL;
    LIBEVENT_THREAD *t = NULL;
    while(!STAILQ_EMPTY(&q->stack)) {
        io_pending_t *p = STAILQ_FIRST(&q->stack);
        STAILQ_REMOVE_HEAD(&q->stack, iop_next);
        if (t == NULL) t = p->thread;
        obj_io *io_ctx = (obj_io *) ((char *)p + p->payload);
        io_ctx->next = eio_head;
        eio_head = io_ctx;
    }
    if (eio_head == NULL) return;
    assert(t != NULL && t->ext_worker != NULL);
    extstore_worker_submit(t->ext_worker, eio_head);
    worker_storage_arm_drain(t);
}

// Runs locally in worker thread.
static void storage_release_pending(io_pending_t *pending) {
    // re-cast to our specific struct.
    io_pending_storage_t *p = (io_pending_storage_t *)pending;

    conn *c = p->c;
    item *it = p->read_it;   // the decrypt destination we allocated
    assert(c != NULL);
    if (p->read_cache != NULL)
        do_cache_free(p->read_cache, it);
    else
        slabs_free(it, p->read_clsid);
    if (p->active) {
        // If request never dispatched, free the read buffer, leave header alone.
        p->resp->suspended = false;
        c->resps_suspended--;
        io_queue_t *q = thread_io_queue_get(p->thread, p->io_queue_type);
        STAILQ_REMOVE(&q->stack, pending, _io_pending_t, iop_next);
        pthread_mutex_lock(&c->thread->stats.mutex);
        c->thread->stats.get_aborted_extstore++;
        pthread_mutex_unlock(&c->thread->stats.mutex);
    } else if (p->miss) {
        // Keep the stub on an integrity failure so a transient DMA visibility
        // failure can recover on a later GET. No local value is available.
        if (!p->badcrc) {
            storage_delete(p->thread->storage, p->hdr_it);
            item_unlink(p->hdr_it);
        }
        pthread_mutex_lock(&c->thread->stats.mutex);
        c->thread->stats.miss_from_extstore++;
        if (p->badcrc)
            c->thread->stats.badcrc_from_extstore++;
        pthread_mutex_unlock(&c->thread->stats.mutex);
    }

    p->io_ctx.buf = NULL;
    p->io_ctx.next = NULL;
    p->active = false;

    item_remove(p->hdr_it);
}

// Called after an IO has been returned to the worker thread.
static void storage_return_cb(io_pending_t *pending) {
    if (g_skip_conn != NULL && pending->c == g_skip_conn &&
        pending->c->resps_suspended <= 1) {
        /* 이 연결은 지금 drive_machine 안에 있다. 재개하면 conn_worker_readd 가
         * 파싱 도중에 걸린다 — memcached.c 의 FIXME 가 경고하는 경우다. */
        STAILQ_INSERT_TAIL(&g_ret_defer, pending, iop_next);
        return;
    }
    pending->thread->ext_resident--;
    conn_resp_unsuspend(pending->c, pending->resp);
}

// Called after responses have been transmitted. Need to free up related data.
static void storage_finalize_cb(io_pending_t *pending) {
    storage_release_pending(pending);
    // don't need to free the main context, since it's embedded.
}

/* ==== v3 pac: publish-at-command 비동기 SET ==============================
 *
 * (c) 이식: GET이 검증한 완료 수거 구조(post 후 워커 해방, 공유 drain에서
 * CQE 수거, g_ret_head → loop 레벨 재개)를 SET에 태운다. 게시(item_replace/
 * do_item_link)는 명령 시점에 끝나므로 연결 내 순서는 동기 경로와 동일하고,
 * 연결 파킹이 필요 없다. 이 구조가 미루는 것은 STORED 응답뿐이다
 * (STORED-after-CQE 계약 유지).
 *
 * (a)는 도입하지 않는다: post는 SET마다 즉시(SYNC_FOR_DEVICE도 SET당 1회,
 * 상각 없음). 따라서 write span = seal + sync + wire + (c)가 되어 (c)가
 * 실측으로 드러난다. SYNC 배치화는 이 단계의 A/B가 끝난 뒤의 일이다.
 *
 * 게시가 CQE보다 앞서므로 그 사이 GET은 아직 쓰이지 않은 원격을 읽을 수
 * 있다 — GCM open이 실패하고 기존 badcrc 재시도 경로가 흡수한다(수 µs 창).
 * 미검증 데이터는 전달되지 않는다. */
typedef struct _io_pending_storage_write_t {
    uint8_t io_queue_type;
    uint8_t io_sub_type;
    uint8_t payload;
    LIBEVENT_THREAD *thread;
    conn *c;
    mc_resp *resp;
    io_queue_cb return_cb;
    io_queue_cb finalize_cb;
    STAILQ_ENTRY(io_pending_t) iop_next;
                              /* original struct ends here */
    item *hdr_it;             /* 게시된 stub — pending이 참조 1개를 쥔다 */
    item *src_it;             /* seal 지연 시 평문 원본. seal 직후 놓는다 */
    uint32_t hv;
    struct ext_loc loc;       /* WRITE 실패/unlink 시 회수용 사본 */
    bool write_ok;
    obj_io io_ctx;            /* embedded — payload가 가리킨다 */
} io_pending_storage_write_t;

/* post 대기 큐 — 이 pass에 수락된 쓰기들을 advise 1회로 함께 동기화한다. */
static _Thread_local struct {
    unsigned int n;
    io_pending_storage_write_t *v[SETQ_HARD_MAX];
} g_setq;

/* 재개 시 out_string()을 쓰면 안 된다 — conn_set_state()로 연결 상태를
 * 되돌려 파이프라인 중간을 깨뜨린다. suspend해 둔 resp에만 쓴다. */
static void setp_out_string(mc_resp *resp, const char *str) {
    size_t len = strlen(str);
    assert(len + 2 <= WRITE_BUFFER_SIZE);
    memcpy(resp->wbuf, str, len);
    memcpy(resp->wbuf + len, "\r\n", 2);
    resp_add_iov(resp, resp->wbuf, len + 2);
}

/* staging 슬롯을 잡고 원본을 봉인한다. 명령 시점(즉시)과 flush 시점(지연)
 * 양쪽에서 같은 코드가 돈다 — 차이는 "언제 부르는가"뿐이다.
 *
 * span 스탬프가 이 함수 안에 있으므로, 호출을 flush로 미루면 큐 누적 대기가
 * 스탬프 앞으로 빠진다. 그것이 ext_seal_at_flush의 목적이고, 동시에 이
 * 조치가 클라이언트 지연을 줄이지 않는 이유이기도 하다 — 같은 일을 나중에
 * 할 뿐이다.
 *
 * 반환 0 = 봉인 완료(io_ctx.buf 유효), -1 = 실패(슬롯/원본 정리 끝난 상태). */
static int pac_seal(io_pending_storage_write_t *p) {
    void *w = p->thread->ext_worker;
    item *src = p->src_it;
    size_t ntotal = ITEM_ntotal(src);
    unsigned int rlen = p->io_ctx.len;

    char *slot;
    uint64_t stg_spins = 0;
    while ((slot = extstore_worker_staging_get(w)) == NULL) {
        stg_spins++;
        /* 큐에 쌓인 쓰기도 슬롯을 쥔다. 아직 post 전이면 drain해도 완료가
         * 올 리 없으므로 먼저 내보내야 한다. flush 안에서 불릴 때는 g_setq.n이
         * 이미 0이라 no-op이고, 그때의 진전은 post된 쓰기의 CQE가 만든다.
         * staging >= window + SETQ_HARD_MAX 이므로 한 배치가 슬롯을 다 쥐는
         * 경우는 없다. */
        storage_flush_pending_writes();
        if (extstore_worker_drain(w, 32) < 0) break;   /* 엔진 사망 */
    }
    if (stg_spins) atomic_fetch_add(&g_worker_write_spins, stg_spins);
    if (slot == NULL) {
        do_item_remove(src); p->src_it = NULL;
        return -1;
    }

    uint64_t prof_start = extstore_prof_stamp();
    int sealed;
    if (g_crypto_on) {
        struct ext_aad aad = { .hv = p->hv, .page_id = p->loc.page_id, .pad = 0,
            .offset = p->loc.offset, .page_version = p->loc.page_version };
        sealed = ext_crypto_seal((uint8_t *)slot, src, ntotal, &aad);
    } else {
        memcpy(slot, src, ntotal);
        sealed = (int)ntotal;
    }
    uint64_t prof_crypto_done = extstore_prof_stamp();

    /* 원본은 봉인 직후 놓는다. 이 item은 해시테이블에 링크된 적이 없으므로
     * (pac은 stub을 게시한다) 락 없이 놓아도 다른 스레드가 볼 수 없다 —
     * item_remove()를 쓰면 큐 상한 flush가 item_lock 아래에서 실행될 때 같은
     * 버킷을 재귀로 잡아 데드락이다. */
    do_item_remove(src);
    p->src_it = NULL;

    if (sealed != (int)rlen) {
        extstore_worker_staging_put(w, slot);
        return -1;
    }
    p->io_ctx.buf = slot;
    p->io_ctx.t_start = prof_start;
    p->io_ctx.t_end = prof_crypto_done;
    return 0;
}

/* drain 문맥(소유 워커 스레드). staging만 반납하고 결과를 적어 GET과 같은
 * 반환 목록에 올린다 — 락/게시/응답은 전부 loop 레벨에서. */
static void _storage_set_item_cb(void *e, obj_io *io, int ret) {
    io_pending_storage_write_t *p = (io_pending_storage_write_t *)io->data;
    extstore_worker_staging_put(p->thread->ext_worker, io->buf);
    io->buf = NULL;
    p->write_ok = (ret == (int)io->len);
    if (!g_ret_init) { STAILQ_INIT(&g_ret_head); g_ret_init = true; }
    STAILQ_INSERT_TAIL(&g_ret_head, (io_pending_t *)p, iop_next);
    (void)e;
}

/* loop 레벨 (storage_flush_returns → conn_io_queue_return). item_lock을 잡을
 * 수 있다 — WFLIGHT 해소와 loc 소유권 판정을 여기서 끝낸 뒤 응답을 쓴다. */
static void storage_set_return_cb(io_pending_t *pending) {
    io_pending_storage_write_t *p = (io_pending_storage_write_t *)pending;
    item *it = p->hdr_it;
    /* 지금 파싱 중인 연결이라도, 위험한 것은 재개 자체가 아니라 그것이
     * **마지막** 재개일 때다 — conn_resp_unsuspend 가 resps_suspended 를 0 으로
     * 만들면 conn_worker_readd 가 drive_machine 이 도는 중에 걸린다.
     * 아직 보류된 응답이 더 있으면 0 이 되지 않으므로 안전하다.
     *
     * 이 구분이 없을 때는 SET 재개의 100% 가 여기서 막혔다(실측:
     * setret_now 0, skipconn SET 당 7.4 회). 파이프라인 혼합에서는 한 연결의
     * SET 과 뒤따르는 GET 이 인접해, SET 이 완료될 때 늘 그 연결을 파싱 중이다. */
    if (g_skip_conn != NULL && pending->c == g_skip_conn &&
        pending->c->resps_suspended <= 1) {
        STAILQ_INSERT_TAIL(&g_ret_defer, pending, iop_next);
        return;
    }
    /* 락을 잡을 수 있는지 추측하지 않고 물어본다. 호출자가 이 버킷을 쥐고
     * 있으면(큐 상한 경로의 do_store_item, meta-get 의 limited_get_locked)
     * trylock 이 실패하고 우리는 미룬다. 버킷을 비교하던 방식은 호출 경로를
     * 다 알아야 했고, 실제로 meta-get 경로를 빠뜨려 서버가 멈췄다. */
    void *ilock = item_trylock(p->hv);
    if (ilock == NULL) {
        STAILQ_INSERT_TAIL(&g_ret_defer, pending, iop_next);
        return;
    }
    it->it_flags &= ~ITEM_WFLIGHT;
    /* span v3 종료 — 응용에서 완료로 보이는 시점. CQE 관측(v2)보다 뒤이고
     * completion 관측 지연과 loop 재개 지연을 포함한다. */
    extstore_prof_write_e2e(p->thread->ext_worker, &p->io_ctx, extstore_prof_stamp());
    bool linked = (it->it_flags & ITEM_LINKED) != 0;
    if (!p->write_ok) {
        /* 쓰이지 않은 원격을 가리키는 stub을 남길 수 없다 — 게시를 되물린다 */
        if (linked) do_item_unlink(it, p->hv);
        extstore_free_loc(ext_storage, &p->loc);
        ((item_hdr *)ITEM_data(it))->len = 0;   /* item_free 훅과 겹치지 않게 */
        atomic_fetch_add(&g_pac_fail, 1);
    } else if (!linked) {
        /* in-flight 동안 delete/replace됨. storage_delete가 WFLIGHT를 보고
         * 건너뛰었으므로 회수는 우리 몫이다 */
        extstore_free_loc(ext_storage, &p->loc);
        ((item_hdr *)ITEM_data(it))->len = 0;
    }
    item_trylock_unlock(ilock);
    p->thread->ext_resident--;
    setp_out_string(p->resp,
        p->write_ok ? "STORED" : "SERVER_ERROR remote write failed");
    conn_resp_unsuspend(p->c, p->resp);
}

/* 전송 후 (resp_finish → finalize_cb). io_pending 본체는 호출자가
 * do_cache_free로 돌려놓는다. */
static void storage_set_finalize_cb(io_pending_t *pending) {
    io_pending_storage_write_t *p = (io_pending_storage_write_t *)pending;
    if (p->src_it) { do_item_remove(p->src_it); p->src_it = NULL; }  /* 방어 */
    item_remove(p->hdr_it);   /* pending의 참조 반납 (내부에서 잠근다) */
    p->io_ctx.next = NULL;
}

/* 반환: 1 = pending 수락(*hdr_out 게시할 것, 응답은 CQE 이후),
 *       0 = 이 SET은 못 받음(호출자가 동기 경로로),  -1 = 하드 실패. */
int storage_store_item_pac(void *e, item *it, item **hdr_out, uint32_t hv,
                           LIBEVENT_THREAD *t) {
    /* span v3 시작 — backend 진입 (v2 는 seal 직전에서 시작한다) */
    uint64_t t_enter_v3 = extstore_prof_stamp();
    if (t->cur_resp) t->cur_resp->t_enter = t_enter_v3;   /* pre/post 분해용 */
    size_t ntotal = ITEM_ntotal(it);
    unsigned int rlen = ntotal + (g_crypto_on ? EXT_CRYPTO_OVERHEAD : 0);
    if (it->it_flags & (ITEM_CHUNKED|ITEM_HDR)) return 0;
    void *w = t->ext_worker;
    mc_resp *resp = t->cur_resp;
    conn *c = t->cur_conn;
    if (w == NULL || resp == NULL || c == NULL || resp->io_pending != NULL)
        return 0;

    client_flags_t flags;
    FLAGS_CONV(it, flags);
    item *hdr_it = do_item_alloc(ITEM_key(it), it->nkey, flags, it->exptime,
                                 sizeof(item_hdr));
    if (hdr_it == NULL) { atomic_fetch_add(&g_pac_fallback, 1); return 0; }
    /* len==0 이 "이 헤더는 loc 을 안 쥐고 있다"의 표시다. 게시 전에 버려지는
     * 경로가 여럿이라(alloc 실패, seal 실패, post 실패) 초기화가 없으면
     * item_free 훅이 쓰레기 loc 을 회수한다. */
    memset(ITEM_data(hdr_it), 0, sizeof(item_hdr));
    struct ext_loc loc;
    if (extstore_alloc(e, rlen, PAGE_BUCKET_DEFAULT, &loc) != 0) {
        do_item_remove(hdr_it);
        atomic_fetch_add(&g_pac_fallback, 1);
        return 0;
    }
    io_pending_storage_write_t *p = do_cache_alloc(t->io_cache);
    if (p == NULL) {
        extstore_free_loc(e, &loc);
        do_item_remove(hdr_it);
        atomic_fetch_add(&g_pac_fallback, 1);
        return 0;
    }
    assert(sizeof(io_pending_t) >= sizeof(io_pending_storage_write_t));
    memset(p, 0, sizeof(*p));
    p->thread = t;
    p->c = c;
    p->resp = resp;
    p->return_cb = storage_set_return_cb;
    p->finalize_cb = storage_set_finalize_cb;
    p->io_queue_type = IO_QUEUE_EXTSTORE;
    p->payload = offsetof(io_pending_storage_write_t, io_ctx);
    p->hdr_it = hdr_it;
    p->hv = hv;
    p->loc = loc;
    p->io_ctx = (obj_io){ .data = p, .next = NULL, .buf = NULL,
        .page_version = loc.page_version, .len = rlen, .offset = loc.offset,
        .page_id = loc.page_id, .mode = OBJ_IO_WRITE,
        .cb = _storage_set_item_cb };

    /* 봉인 전까지 평문 원본을 살려둔다. 호출자(complete_nread_ascii)는
     * store_item이 돌아오면 c->item을 놓아버리므로 여기서 참조를 하나 든다.
     * 즉시 봉인 모드에서는 pac_seal이 그 자리에서 다시 놓는다. */
    refcount_incr(it);
    p->src_it = it;

    if (!settings.ext_seal_at_flush) {
        if (pac_seal(p) != 0) {
            do_cache_free(t->io_cache, p);
            extstore_free_loc(e, &loc);
            do_item_remove(hdr_it);
            return -1;   /* 아직 게시 전이라 되돌릴 수 있다 */
        }
    }

    item_hdr *hdr = (item_hdr *)ITEM_data(hdr_it);
    hdr->page_version = loc.page_version;
    hdr->offset = loc.offset;
    hdr->len = loc.len;
    hdr->page_id = loc.page_id;
    hdr_it->nbytes = it->nbytes;
    hdr_it->it_flags |= ITEM_HDR | ITEM_WFLIGHT |
        (it->it_flags & (ITEM_TOKEN_SENT|ITEM_STALE|ITEM_KEY_BINARY));
    refcount_incr(hdr_it);              /* pending 참조 — finalize에서 반납 */
    resp->io_pending = (io_pending_t *)p;

    /* post는 이벤트 루프 pass 끝(storage_flush_pending_writes)까지 미룬다 —
     * 그 pass에 수락된 쓰기들을 SYNC_FOR_DEVICE 1회로 함께 동기화하기 위해서다.
     * 여기서 실패할 수 있는 것은 이미 다 지났으므로 enqueue는 실패하지 않는다.
     * 이 지점 이후로 SET은 "수락됨"이고, post 실패조차 -1로 되돌릴 수 없다 —
     * done_cb(-1) 경로로 합류해 게시가 롤백된다. */
    p->io_ctx.t_enter = t_enter_v3;      /* span v3 시작 (t_start 는 seal 시각) */
    t->ext_resident++;
    g_setq.v[g_setq.n++] = p;
    /* A-1 재시도: 여기서 flush 하면 do_store_item 의 item_lock(hv) 아래에서
     * advise·post·drain·재개가 전부 돌아 같은 버킷의 GET 을 막는다. 전에
     * 락 밖으로 뺐을 때는 처리량이 졌지만(9.05 대 9.18) 그때는 refcount 와
     * stats 락이 그대로였다. 둘을 걷어낸 지금은 부호가 바뀔 수 있다. */
    if (g_setq.n >= SETQ_HARD_MAX)
        storage_flush_pending_writes();
    /* GET이 없는 워크로드에서도 CQE를 걷을 주체를 보장한다 */
    worker_storage_arm_drain(t);
    atomic_fetch_add(&g_pac_posted, 1);
    *hdr_out = hdr_it;
    return 1;
}

/* 이벤트 루프 pass 끝(worker_libevent)과 큐 상한에서 호출된다. advise 1회 +
 * post N회.
 *
 * 여기서 storage_flush_returns()를 부르면 안 된다 — 큐 상한 경로는
 * do_store_item의 item_lock(hv) 아래에서 실행되는데, 재개(return_cb)는
 * item_lock(p->hv)을 다시 잡으므로 같은 버킷이면 데드락이다. enqueue마다
 * worker_storage_arm_drain이 걸려 있으므로 ready 목록은 다음 drain 이벤트가
 * 소화한다(엔진이 죽어 있어도 handler가 returns를 먼저 비운다). */
void storage_flush_pending_writes(void) {
    unsigned int n = g_setq.n;
    if (n == 0) return;
    g_setq.n = 0;
    LIBEVENT_THREAD *t = g_setq.v[0]->thread;
    void *w = t->ext_worker;

    /* 1단계 — 봉인. ext_seal_at_flush면 여기서 처음 암호화가 일어난다.
     * 배치 앞쪽 항목은 뒤쪽 항목들의 seal을 자기 span 안에서 기다리게 되므로
     * (sync는 모든 seal 뒤 1회여야 하니까) 배치가 클수록 앞쪽 span이 나빠진다.
     * 즉시 봉인 모드에서는 이미 buf가 채워져 있어 이 단계가 통째로 건너뛴다. */
    obj_io *ios[SETQ_HARD_MAX];
    unsigned int m = 0;
    for (unsigned int i = 0; i < n; i++) {
        io_pending_storage_write_t *p = g_setq.v[i];
        if (p->io_ctx.buf == NULL && pac_seal(p) != 0) {
            /* 이미 게시된 SET이라 되돌릴 수 없다 — WRITE 실패와 같은 경로로 */
            _storage_set_item_cb(NULL, &p->io_ctx, -1);
            continue;
        }
        ios[m++] = &p->io_ctx;
    }
    if (m == 0) { atomic_fetch_add(&g_setq_flushes, 1); return; }

    /* 2단계 — 각 쓰기에 대해 seal → sync → post 순서는 유지된다.
     * 배치는 sync 호출만 공유한다. */
    extstore_worker_sync_for_device(w, ios, m);

    /* 3단계 — post */
    uint64_t spins = 0;
    for (unsigned int i = 0; i < m; i++) {
        int rc;
        while ((rc = extstore_worker_post_write_presynced(w, ios[i])) == EAGAIN) {
            spins++;
            if (extstore_worker_drain(w, 32) < 0) { rc = -1; break; }
        }
        if (rc != 0) {
            /* 이미 수락된 SET이므로 여기서 끝낼 수 없다. WRITE 실패와 같은
             * 경로로 보내 loop 레벨에서 게시가 롤백되게 한다. */
            _storage_set_item_cb(NULL, ios[i], -1);
        }
    }
    if (spins) atomic_fetch_add(&g_worker_write_spins, spins);

    /* 4단계 — 완료 수거. 이 배치를 post한 김에 앞선 배치의 CQE를 거둔다.
     *
     * 이전 버전에서는 enqueue 시점의 staging 대기가 이 일을 우연히 대신하고
     * 있었다 — 측정상 drain 호출의 93%가 그 spin에서 나왔다. seal(과 staging
     * 확보)을 flush로 옮기자 워커당 104슬롯을 배치 하나가 다 쓰지 못해 압력이
     * 사라졌고, 그와 함께 수거도 멎어 post→CQE가 11 → 383 µs로 뛰고 처리량이
     * window(24)에 묶였다. 수거를 부작용이 아니라 의도로 만든다.
     *
     * 여기서 storage_flush_returns()를 부르면 안 되는 것은 위와 같다 —
     * 큐 상한 경로가 item_lock 아래라 재개가 같은 버킷을 다시 잡는다.
     * cb는 staging 반납과 ready 목록 적재까지만 하므로 안전하다. */
    for (int k = 0; k < 8 && extstore_worker_drain(w, 32) > 0; k++)
        ;

    /* 방금 거둔 완료를 여기서 재개한다. 재개는 item_trylock 을 쓰므로
     * 켜져 있어 충돌 버킷만 보류된다. 이 호출이 없으면 재개가 이벤트 루프
     * pass 하나만큼 밀리는데, ext_setq_max=1 이라 모든 SET이 이 경로로 오므로
     * 완료 하나가 그 pass의 남은 SET 수백 개를 통째로 기다린다 — 실측
     * SET-only pipe=256 에서 span v3 2398 µs 중 2390 µs 가 이 대기였다. */
    storage_flush_returns();

    /* 우리가 거둔 완료는 ready 목록에만 올라가 있다. 재개(storage_flush_returns)
     * 는 item_lock을 잡으므로 여기서 부를 수 없고 — 큐 상한 경로가 이미 그
     * 락 아래다 — drain 이벤트에 맡겨야 한다. 그런데 우리가 CQ를 비워버리면
     * worker_libevent의 drain 지점은 outstanding==0을 보고 블록 전체를
     * 건너뛴다. 그러면 arm도 안 걸리고, 클라이언트가 그 응답을 기다리느라
     * 다음 명령을 안 보내면 영원히 재개되지 않는다(실측: preload가 249k에서
     * 정지, 서버 CPU 0). 수거했으면 반드시 재개도 예약한다. */
    worker_storage_arm_drain(t);

    atomic_fetch_add(&g_setq_flushes, 1);
    atomic_fetch_add(&g_setq_writes, m);
}
/* ==== v3 pac 끝 ========================================================== */

/*
 * Remote-only SET commit. The input item is a transient request buffer and is
 * never linked into the hash table. A successful RDMA WRITE returns an
 * unlinked ITEM_HDR; the caller publishes that stub and only then replies
 * STORED. Resource exhaustion blocks at the staging pool instead of falling
 * back to a locally serviceable value.
 */
int storage_store_item(void *e, item *it, item **hdr_out, uint32_t hv) {
    size_t ntotal = ITEM_ntotal(it);
    unsigned int rlen = ntotal + (g_crypto_on ? EXT_CRYPTO_OVERHEAD : 0);
    *hdr_out = NULL;
    if (it->it_flags & (ITEM_CHUNKED|ITEM_HDR))
        return -1;

    client_flags_t flags;
    FLAGS_CONV(it, flags);
    item *hdr_it = do_item_alloc(ITEM_key(it), it->nkey, flags, it->exptime,
                                 sizeof(item_hdr));
    if (hdr_it == NULL)
        return -1;
    /* len==0 이 "이 헤더는 loc 을 안 쥐고 있다"의 표시다. 게시 전에 버려지는
     * 경로가 여럿이라(alloc 실패, seal 실패, post 실패) 초기화가 없으면
     * item_free 훅이 쓰레기 loc 을 회수한다. */
    memset(ITEM_data(hdr_it), 0, sizeof(item_hdr));

    struct ext_loc loc;
    if (extstore_alloc(e, rlen, PAGE_BUCKET_DEFAULT, &loc) != 0) {
        do_item_remove(hdr_it);
        return -1;
    }

    /* v2 (P2b): SET runs inline on the calling worker — its own staging
     * partition, its own QP, and a bounded spin on its own CQ. The synchronous
     * STORED contract is unchanged; only the wait mechanism differs (cond ->
     * drain). See md/V2_CODE_SPEC.md P2b. */
    LIBEVENT_THREAD *wt = current_worker_thread();
    void *w = wt != NULL ? wt->ext_worker : NULL;
    if (w == NULL) {
        extstore_free_loc(e, &loc);
        do_item_remove(hdr_it);
        return -1;
    }
    char *slot = extstore_worker_staging_get(w);
    if (slot == NULL) {
        extstore_free_loc(e, &loc);
        do_item_remove(hdr_it);
        return -1;
    }

    uint64_t prof_start = extstore_prof_stamp();
    int sealed;
    if (g_crypto_on) {
        struct ext_aad aad = { .hv = hv, .page_id = loc.page_id, .pad = 0,
            .offset = loc.offset, .page_version = loc.page_version };
        sealed = ext_crypto_seal((uint8_t *)slot, it, ntotal, &aad);
        if (g_seal_tab) {
            uint64_t ctr = nonce_counter(slot);
            if (ctr < SEAL_TRACE_MAX) {
                struct seal_rec *r = &g_seal_tab[ctr];
                r->page = loc.page_id; r->off = loc.offset; r->len = rlen;
                int kn = it->nkey < (int)sizeof(r->key) - 1 ? it->nkey : (int)sizeof(r->key) - 1;
                memcpy(r->key, ITEM_key(it), kn); r->key[kn] = 0;
            }
        }
    } else {
        memcpy(slot, it, ntotal);
        sealed = (int)ntotal;
    }
    uint64_t prof_crypto_done = extstore_prof_stamp();
    if (sealed != (int)rlen) {
        extstore_worker_staging_put(w, slot);
        extstore_free_loc(e, &loc);
        do_item_remove(hdr_it);
        return -1;
    }

    if (g_crypto_on && atomic_fetch_add(&g_flush_log_ct, 1) < 200) {
        const unsigned char *n = (const unsigned char *)slot;
        fprintf(stderr, "extstore flush: key=%.*s -> {page=%u off=%u ver=%u} "
            "nonce=%02x%02x%02x%02x.%02x%02x%02x%02x%02x%02x%02x%02x\n",
            it->nkey, ITEM_key(it), loc.page_id, loc.offset, loc.page_version,
            n[0],n[1],n[2],n[3],n[4],n[5],n[6],n[7],n[8],n[9],n[10],n[11]);
    }

    /* wait/io를 스택에 두면 안 된다: 엔진이 죽어 완료를 못 본 채 이 함수를
     * 빠져나가는 경로(아래 wait.done 검사)에서, 우리가 post한 WRITE는 여전히
     * wr_id로 이 객체를 가리키고 있다. 스택에 두면 프레임이 죽은 뒤 다음
     * drain이 그 CQE를 폴링해 dangling 포인터로 io->cb를 호출한다. 동기
     * 경로는 자기 완료를 기다리므로 워커당 동시 진행이 1건이고, 따라서
     * _Thread_local 한 벌로 충분하다 — 그리고 이건 프레임과 함께 죽지 않는다. */
    static _Thread_local store_wait wait;
    static _Thread_local obj_io io;
    wait = (store_wait){0};
    io = (obj_io){
        .data = &wait, .next = NULL, .buf = slot,
        .page_version = loc.page_version, .len = rlen, .offset = loc.offset,
        .page_id = loc.page_id, .mode = OBJ_IO_WRITE,
        .cb = storage_store_done_cb,
        .t_start = prof_start, .t_end = prof_crypto_done,
    };

    /* spin 카운터는 루프 밖에서 한 번만 반영한다. 전역 _Atomic을 회전마다
     * 두드리면 워커 28개가 캐시라인 하나를 놓고 경합한다(SET당 15.6회
     * → 초당 2600만 RMW). 통계값이라 배치 반영으로 충분하다. */
    uint64_t spins = 0;
    unsigned int win = extstore_worker_window(w);
    while (extstore_worker_outstanding(w) >= win) {
        spins++;
        if (extstore_worker_drain(w, 32) < 0) break;
    }
    if (extstore_worker_post_write(w, &io) != 0) {
        wait.done = true;
        wait.ret = -1;
    }
    while (!wait.done) {
        spins++;
        if (extstore_worker_drain(w, 32) < 0) break;
    }
    if (spins) atomic_fetch_add(&g_worker_write_spins, spins);
    if (wait.done) {
        extstore_worker_staging_put(w, slot);
    }
    /* !wait.done이면 엔진이 죽어 완료를 보지 못한 것이다. 슬롯을 반납하면
     * NIC이 아직 DMA-read 중일 수 있는 메모리를 다음 SET이 덮어쓰므로
     * 의도적으로 누수시킨다 — 엔진이 죽은 뒤이므로 회수할 이유가 없다. */

    if (wait.ret != (int)rlen) {
        extstore_free_loc(e, &loc);
        do_item_remove(hdr_it);
        return -1;
    }

    item_hdr *hdr = (item_hdr *)ITEM_data(hdr_it);
    hdr->page_version = loc.page_version;
    hdr->offset = loc.offset;
    hdr->len = loc.len;
    hdr->page_id = loc.page_id;
    hdr_it->nbytes = it->nbytes;
    hdr_it->it_flags |= ITEM_HDR |
        (it->it_flags & (ITEM_TOKEN_SENT|ITEM_STALE|ITEM_KEY_BINARY));
    *hdr_out = hdr_it;
    return 0;
}

/*** UTILITY ***/
// ext_path=<genie_host>:<port>:<size>   size unit m|g|t|p (RDMA port)
// FIXME: Modifies argument. copy instead?
struct extstore_conf_file *storage_conf_parse(char *arg) {
    struct extstore_conf_file *cf = NULL;
    char *b = NULL;
    char unit = 0;
    uint64_t multiplier = 0;
    char *host = strtok_r(arg, ":", &b);
    char *port = strtok_r(NULL, ":", &b);
    char *size = strtok_r(NULL, ":", &b);
    if (!host || !port || !size) {
        fprintf(stderr, "ext_path must be host:port:size, ie: ext_path=10.99.0.2:11212:64g\n");
        goto error;
    }
    cf = calloc(1, sizeof(struct extstore_conf_file));
    cf->file = strdup(host);
    cf->cport = atoi(port);

    unit = tolower(size[strlen(size)-1]);
    size[strlen(size)-1] = '\0';
    switch (unit) {
        case 'm': multiplier = 1024ULL * 1024; break;
        case 'g': multiplier = 1024ULL * 1024 * 1024; break;
        case 't': multiplier = 1024ULL * 1024 * 1024 * 1024; break;
        case 'p': multiplier = 1024ULL * 1024 * 1024 * 1024 * 1024; break;
        default:
            fprintf(stderr, "ext_path size needs a unit (m|g|t|p)\n");
            goto error;
    }
    cf->total_size = multiplier * (uint64_t)atoi(size);
    return cf;
error:
    if (cf) { free(cf->file); free(cf); }
    return NULL;
}

struct storage_settings {
    struct extstore_conf_file *storage_file;
    struct extstore_conf ext_cf;
};

void *storage_init_config(struct settings *s) {
    (void)s;
    struct storage_settings *cf = calloc(1, sizeof(struct storage_settings));

    cf->ext_cf.page_size = 64 * 1024 * 1024;
    cf->ext_cf.page_buckets = PAGE_BUCKET_COUNT;
    char *v;
    cf->ext_cf.slot_size = EXT_SLOT_SIZE_DEFAULT;
    if ((v = getenv("EXT_SLOT_SIZE")) &&
            !safe_strtoul(v, &cf->ext_cf.slot_size))
        cf->ext_cf.slot_size = 0;
    g_plaintext_slot_size = cf->ext_cf.slot_size;
    cf->ext_cf.read_slots = 32;
    if ((v = getenv("EXT_READ_SLOTS")) &&
            !safe_strtoul(v, &cf->ext_cf.read_slots))
        cf->ext_cf.read_slots = 0;
    cf->ext_cf.write_slots = 256;
    if ((v = getenv("EXT_WRITE_SLOTS")) &&
            !safe_strtoul(v, &cf->ext_cf.write_slots))
        cf->ext_cf.write_slots = 0;
    cf->ext_cf.qp_per_worker = 1;
    cf->ext_cf.ord_limit = 0;      /* 0 = adopt the CM-negotiated per-QP depth */
    cf->ext_cf.batch = EXT_BATCH_DEFAULT;
    if ((v = getenv("EXT_READ_RETRIES"))) g_read_retries = atoi(v);
    if (getenv("EXT_TRACE_SEAL")) {
        g_seal_tab = calloc(SEAL_TRACE_MAX, sizeof(*g_seal_tab));
        fprintf(stderr, "extstore: seal trace %s\n", g_seal_tab ? "on" : "alloc failed");
    }

    return cf;
}

// TODO: pass settings struct?
int storage_read_config(void *conf, char **subopt) {
    struct storage_settings *cf = conf;
    struct extstore_conf *ext_cf = &cf->ext_cf;
    char *subopts_value;

    enum {
        EXT_PAGE_SIZE,
        EXT_PATH,
        EXT_QP_PER_WORKER,
        EXT_ORD_LIMIT,
        EXT_BATCH,
        EXT_DRAIN_SPIN,
        EXT_DRAIN_EMPTY_MAX,
        EXT_LOC_MAG_DEPTH,
        EXT_SETQ_MAX,
        EXT_SUBMIT_BATCH,
        EXT_ADMIT_MAX,
        EXT_SUBMIT_INLINE,
        EXT_REAP_EVERY,
        EXT_POST_CHAIN,
    };

    char *const subopts_tokens[] = {
        [EXT_PAGE_SIZE] = "ext_page_size",
        [EXT_PATH] = "ext_path",
        [EXT_QP_PER_WORKER] = "ext_qp_per_worker",
        [EXT_ORD_LIMIT] = "ext_ord_limit",
        [EXT_BATCH] = "ext_batch",
        [EXT_DRAIN_SPIN] = "ext_drain_spin",
        [EXT_DRAIN_EMPTY_MAX] = "ext_drain_empty_max",
        [EXT_LOC_MAG_DEPTH] = "ext_loc_mag_depth",
        [EXT_SETQ_MAX] = "ext_setq_max",
        [EXT_SUBMIT_BATCH] = "ext_submit_batch",
        [EXT_ADMIT_MAX] = "ext_admit_max",
        [EXT_SUBMIT_INLINE] = "ext_submit_inline",
        [EXT_REAP_EVERY] = "ext_reap_every",
        [EXT_POST_CHAIN] = "ext_post_chain",
        NULL
    };

    switch (getsubopt(subopt, subopts_tokens, &subopts_value)) {
        case EXT_PAGE_SIZE:
            if (subopts_value == NULL) {
                fprintf(stderr, "Missing ext_page_size argument\n");
                return 1;
            }
            if (!safe_strtoul(subopts_value, &ext_cf->page_size)) {
                fprintf(stderr, "could not parse argument to ext_page_size\n");
                return 1;
            }
            ext_cf->page_size *= 1024 * 1024; /* megabytes */
            break;
        case EXT_POST_CHAIN:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_post_chain) ||
                settings.ext_post_chain < 1 ||
                settings.ext_post_chain > POST_CHAIN_MAX) {
                fprintf(stderr, "ext_post_chain must be 1..%d\n", POST_CHAIN_MAX);
                return 1;
            }
            break;
        case EXT_REAP_EVERY:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_reap_every) ||
                settings.ext_reap_every < 1) {
                fprintf(stderr, "ext_reap_every must be >= 1\n");
                return 1;
            }
            break;
        case EXT_SUBMIT_INLINE:
            settings.ext_submit_inline = true;
            break;
        case EXT_ADMIT_MAX:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_admit_max)) {
                fprintf(stderr, "ext_admit_max must be a number\n");
                return 1;
            }
            break;
        case EXT_SUBMIT_BATCH:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_submit_batch)) {
                fprintf(stderr, "ext_submit_batch must be a number\n");
                return 1;
            }
            break;
        case EXT_DRAIN_SPIN:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_drain_spin) ||
                false) {
                fprintf(stderr, "ext_drain_spin must be a number\n");
                return 1;
            }
            break;
        case EXT_DRAIN_EMPTY_MAX:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &settings.ext_drain_empty_max)) {
                fprintf(stderr, "ext_drain_empty_max must be a number\n");
                return 1;
            }
            break;
        case EXT_SETQ_MAX:
            /* SYNC_FOR_DEVICE 배치 상한. 1 = 쓰기당 advise 1회(배치 없음) —
             * 같은 바이너리로 배치화를 A/B하는 대조군이다. */
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &g_setq_max) ||
                g_setq_max < 1 || g_setq_max > SETQ_HARD_MAX) {
                fprintf(stderr, "ext_setq_max must be 1..%d (1 = no batching)\n",
                        SETQ_HARD_MAX);
                return 1;
            }
            break;
        case EXT_LOC_MAG_DEPTH:
            /* 0 = 끈다. 파킹된 loc은 소유 워커만 재사용하므로 스토어가 거의
             * 찼을 때 다른 워커의 할당을 실패시킬 수 있다 — 그때 낮추거나 끄는
             * 노브이고, A/B 검증에도 필요하다. */
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &g_loc_mag_depth)) {
                fprintf(stderr, "ext_loc_mag_depth must be a number (0 = off)\n");
                return 1;
            }
            extstore_set_loc_mag_depth(g_loc_mag_depth);
            break;
        case EXT_QP_PER_WORKER:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &ext_cf->qp_per_worker) ||
                ext_cf->qp_per_worker < 1) {
                fprintf(stderr, "ext_qp_per_worker must be >= 1\n");
                return 1;
            }
            break;
        case EXT_ORD_LIMIT:
            /* 0 = adopt the CM-negotiated depth. A pinned value is honoured as
             * given; exceeding the HCA's depth just queues in the SQ. */
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &ext_cf->ord_limit)) {
                fprintf(stderr, "ext_ord_limit must be a number (0 = negotiated)\n");
                return 1;
            }
            break;
        case EXT_BATCH:
            if (subopts_value == NULL ||
                !safe_strtoul(subopts_value, &ext_cf->batch) ||
                ext_cf->batch < 1) {
                fprintf(stderr, "ext_batch must be >= 1\n");
                return 1;
            }
            break;
        case EXT_PATH:
            if (subopts_value) {
                struct extstore_conf_file *tmp = storage_conf_parse(subopts_value);
                if (tmp == NULL) {
                    fprintf(stderr, "failed to parse ext_path argument\n");
                    return 1;
                }
                if (cf->storage_file != NULL) {
                    tmp->next = cf->storage_file;
                }
                cf->storage_file = tmp;
            } else {
                fprintf(stderr, "missing argument to ext_path, ie: ext_path=10.99.0.2:11212:4g\n");
                return 1;
            }
            break;
        default:
            fprintf(stderr, "Illegal suboption \"%s\"\n", subopts_value);
            return 1;
    }

    return 0;
}

int storage_check_config(void *conf) {
    struct storage_settings *cf = conf;

    if (cf->storage_file) {
        if (cf->ext_cf.slot_size <= EXT_CRYPTO_OVERHEAD ||
                cf->ext_cf.slot_size > settings.item_size_max ||
                cf->ext_cf.read_slots < 1 ||
                cf->ext_cf.write_slots < 1) {
            fprintf(stderr, "invalid EXT_SLOT_SIZE/EXT_READ_SLOTS/EXT_WRITE_SLOTS\n");
            return 1;
        }
        if (settings.udpport) {
            fprintf(stderr, "Cannot use UDP with extstore enabled (-U 0 to disable)\n");
            return 1;
        }

        struct extstore_conf_file *fh = cf->storage_file;
        while (fh != NULL) {
            // page_count is nearest-but-not-larger-than pages * psize
            fh->page_count = fh->total_size / cf->ext_cf.page_size;
            assert(cf->ext_cf.page_size * fh->page_count <= fh->total_size);
            if (fh->page_count == 0) {
                fprintf(stderr, "supplied ext_path has zero size, cannot use\n");
                return 1;
            }
            fh = fh->next;
        }

        return 0;
    }

    return 2;
}

unsigned int storage_slot_size(void *conf) {
    struct storage_settings *cf = conf;
    return cf->ext_cf.slot_size;
}

void *storage_init(void *conf) {
    struct storage_settings *cf = conf;
    struct extstore_conf *ext_cf = &cf->ext_cf;

    enum extstore_res eres;
    void *storage = NULL;
    crc32c_init();

    // Remote values are always AES-256-GCM protected.
    const char *keypath = getenv("EXT_CRYPTO_KEY");
    if (!keypath) {
        fprintf(stderr, "ext crypto: EXT_CRYPTO_KEY is required for remote storage\n");
        return NULL;
    }
    FILE *kf = fopen(keypath, "rb");
    uint8_t key[32];
    if (!kf || fread(key, 1, 32, kf) != 32) {
        fprintf(stderr, "ext crypto: cannot read 32-byte key from %s\n", keypath);
        if (kf) fclose(kf);
        return NULL;
    }
    fclose(kf);
    ext_crypto_init(key);
    g_crypto_on = true;

    g_qp_per_worker = ext_cf->qp_per_worker;
    storage = extstore_init(cf->storage_file, ext_cf, &eres);
    if (storage == NULL) {
        fprintf(stderr, "Failed to initialize external storage: %s\n",
                extstore_err(eres));
        if (eres == EXTSTORE_INIT_OPEN_FAIL) {
            perror("extstore open");
        }
        return NULL;
    }

    return storage;
}

/* v2 (P2a): resume conns whose READs completed in the drain that just ended. */
unsigned int storage_setq_max(void) { return g_setq_max; }

void storage_post_chain_flush(void *t) {
    if (g_chain_head != NULL) pending_chain_flush((LIBEVENT_THREAD *)t);
}

void storage_flush_returns(void) {
    if (!g_ret_defer_init) { STAILQ_INIT(&g_ret_defer); g_ret_defer_init = true; }
    if (!g_ret_init) { STAILQ_INIT(&g_ret_head); g_ret_init = true; return; }
    while (!STAILQ_EMPTY(&g_ret_head)) {
        io_pending_t *io = STAILQ_FIRST(&g_ret_head);
        STAILQ_REMOVE_HEAD(&g_ret_head, iop_next);
        conn_io_queue_return(io);
    }
    /* 락 충돌로 미룬 것들. 다음 호출(늦어도 루프 레벨)이 다시 시도한다 —
     * 그때는 락이 비어 있으므로 처리된다. */
    STAILQ_CONCAT(&g_ret_head, &g_ret_defer);
}

/* v2 (P2a): called from main after thread init, before conns are dispatched. */
int storage_prepare_workers(void *storage, int nthreads) {
    /* staging은 "post돼 미완료(window)" + "큐에 있고 아직 post 전(setq_max)"
     * 만큼 필요하다. 상한(64)으로 고정하면 batch=1일 때도 워커당 104슬롯을
     * 잡아 DMA 등록이 745 KB가 되고, SEV의 SWIOTLB가 파편화됐을 때
     * ibv_reg_mr이 EIO로 죽는다(실측). 실제 설정값으로 잡는다. */
    extstore_set_staging_need(storage, g_setq_max);
    return extstore_workers_prepare(storage, nthreads, g_qp_per_worker);
}

#endif
