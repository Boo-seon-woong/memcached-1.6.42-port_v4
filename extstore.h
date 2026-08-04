#ifndef EXTSTORE_H
#define EXTSTORE_H

/* A safe-to-read remote page snapshot. The array index is the page id. */
struct extstore_page_data {
    uint64_t version;
    uint64_t bytes_used;
    unsigned int bucket;
    bool active; // page is actively being written to; ignore it except for tallying.
};

struct extstore_stats {
    uint64_t page_allocs;
    uint64_t page_count; /* total page count */
    uint64_t page_size; /* size in bytes per page (supplied by caller) */
    uint64_t pages_free; /* currently unallocated/unused pages */
    uint64_t pages_used;
    uint64_t objects_read;
    uint64_t objects_written;
    uint64_t objects_used; /* total number of objects stored */
    uint64_t bytes_written;
    uint64_t bytes_read; /* wbuf - read -> bytes read from storage */
    uint64_t bytes_used; /* total number of bytes stored */
    uint64_t io_queue;
    /* RDMA bring-up debug counters */
    uint64_t write_failures;   /* RDMA WRITE completions with error status */
    uint64_t read_failures;    /* RDMA READ completions with error status */
    uint64_t engine_dead;      /* 0/1: a QP error shut the engine down (fail-fast) */
    /* EXT_RDMA_PROF (D6): per-direction in-server span distribution, ns.
     * Populated only when EXT_RDMA_PROF=1; reset by extstore_prof_reset. */
    uint64_t prof_read_count,  prof_read_avg_ns,  prof_read_p50_ns,  prof_read_p99_ns;
    /* span v3 — backend 진입부터. v2 가 빼는 admission/queue·완료 관측 지연 포함 */
    uint64_t prof_read_e2e_count,  prof_read_e2e_avg_ns,  prof_read_e2e_p50_ns,  prof_read_e2e_p99_ns;
    uint64_t prof_write_e2e_count, prof_write_e2e_avg_ns, prof_write_e2e_p50_ns, prof_write_e2e_p99_ns;
    uint64_t prof_write_count, prof_write_avg_ns, prof_write_p50_ns, prof_write_p99_ns;
    /* Span v2 breakout: crypto + sync (SWIOTLB advise) + transfer, avg ns. */
    uint64_t prof_read_crypto_avg_ns, prof_write_crypto_avg_ns;
    uint64_t prof_read_sync_avg_ns,  prof_read_xfer_avg_ns;
    uint64_t prof_write_sync_avg_ns, prof_write_xfer_avg_ns;
    /* v3 성분: admit = 진입→v2 시작(admission/queue), ret = CQE→응용 가시 */
    uint64_t prof_read_admit_avg_ns, prof_write_admit_avg_ns, prof_write_ret_avg_ns;
    /* v4 클라이언트 가시 구간: srv = 소켓 read→sendmsg, que = read→명령 시작 */
    uint64_t prof_srv_count, prof_srv_avg_ns, prof_srv_p50_ns, prof_srv_p99_ns;
    uint64_t prof_que_count, prof_que_avg_ns, prof_que_p50_ns, prof_que_p99_ns;
    /* bk = backend 진입 → sendmsg. pre = srv-que-bk, post = bk - span_v3 */
    uint64_t prof_bk_count, prof_bk_avg_ns, prof_bk_p50_ns, prof_bk_p99_ns;
    uint64_t worker_drain_calls, worker_drain_empty, worker_wait_enq;
    uint64_t slot_acct_leak;
    uint64_t alloc_failures;   /* store full: SET answered NOT_STORED */
    uint64_t worker_window;
    /* 형태 실험(shape-20260804)이 이 셋으로만 셀을 가른다. 노출하지 않으면
     * 양측 다 어느 셀을 돌렸는지 증명할 수 없다. ord_limit 은 실효값이다
     * (0 을 넣으면 CM 협상값이 들어오므로 워커가 실제로 쓰는 값을 낸다). */
    uint64_t qp_per_worker, ord_limit, read_slots;
    struct extstore_page_data *page_data;
};

// TODO: Temporary configuration structure. A "real" library should have an
// extstore_set(enum, void *ptr) which hides the implementation.
// this is plenty for quick development.
struct extstore_conf {
    unsigned int page_size; // ideally 64-256M in size
    unsigned int page_count;
    unsigned int page_buckets; // number of size-class buckets for remote slots
    // RDMA port additions:
    unsigned int slot_size;    // bounce/staging slot size (>= max remote object)
    unsigned int read_slots;   // bounce slots per worker (<= 64)
    unsigned int write_slots;  // total worker staging slots
    unsigned int worker_window;   // v2: per-worker outstanding cap (<= 64)
    unsigned int qp_per_worker;   // v2: QPs per worker (>=1, unbounded)
    unsigned int ord_limit;       // v2: per-QP outstanding RDMA READ gate.
                                  //     0 = use the CM-negotiated value.
    unsigned int batch;           // v2: WR/CQE batch size per post/drain call
};

struct extstore_conf_file {
    unsigned int page_count;
    char *file;                // genie host
    int cport;                 // genie control-channel TCP port
    uint64_t total_size; // size in bytes, before page_count slicing
    struct extstore_conf_file *next;
};

/* v2 (P2a): worker-inline READ path. */
/* v2: no compile-time ceiling on QP count, window, slots or ORD. Every limit
 * is an input; a setting that performs badly is a measurement, not an error,
 * so the engine does not second-guess it. Only functional floors (>=1) remain. */
#define EXT_BATCH_DEFAULT 32  /* default WR/CQE batch; override via ext_batch */
#ifndef EXT_SLOT_SIZE_DEFAULT
#define EXT_SLOT_SIZE_DEFAULT 256
#endif

enum obj_io_mode {
    OBJ_IO_READ = 0,
    OBJ_IO_WRITE,
};

typedef struct _obj_io obj_io;
typedef void (*obj_io_cb)(void *e, obj_io *io, int ret);

/* An object for both reads and writes to the storage engine.
 * Once an IO is submitted, ->next may be changed by the owning worker. It is not
 * safe to further modify the IO stack until the entire request is completed.
 */
struct _obj_io {
    void *data; /* user supplied data pointer */
    struct _obj_io *next;
    char *buf;  /* READ: engine-assigned bounce slot. WRITE: caller staging slot */
    unsigned int page_version;
    unsigned int len;     /* remote object length (both modes) */
    unsigned int offset;  /* offset within page */
    unsigned short page_id;
    enum obj_io_mode mode;
    obj_io_cb cb;
    unsigned char retries; /* read retry count (torn-read / tag fail) */
    unsigned char wqp;     /* v2: which worker QP carries this op (drain acct) */
    /* EXT_RDMA_PROF span v2: READ pre-post through post-decrypt;
     * WRITE pre-encrypt through CQE. t_end is an intermediate boundary. */
    uint64_t t_start, t_end;
    /* span v3 (secure remote access): backend 진입 시각. v2 가 놓치는
     * admission/queue 대기를 포함한다 — READ 는 storage_get_item() 진입,
     * WRITE 는 storage_store_item_pac() 진입에서 찍는다. 0 이면 미계측. */
    uint64_t t_enter;
};

/* A remote object location. Returned by extstore_alloc, stored in item_hdr. */
struct ext_loc {
    unsigned int page_version;
    unsigned int offset;
    unsigned int len;
    unsigned short page_id;
};

enum extstore_res {
    EXTSTORE_INIT_OOM = 1,
    EXTSTORE_INIT_OPEN_FAIL,
    EXTSTORE_INIT_SELFTEST_FAIL
};

const char *extstore_err(enum extstore_res res);
void *extstore_init(struct extstore_conf_file *fh, struct extstore_conf *cf, enum extstore_res *res);
/* Allocate a remote slot of `len` bytes in size-class `bucket`. 0 on success. */
int extstore_alloc(void *ptr, unsigned int len, unsigned int bucket, struct ext_loc *out);
void extstore_free_loc(void *ptr, const struct ext_loc *loc);
void extstore_set_loc_mag_depth(unsigned int d);

/* v3: SYNC_FOR_DEVICE를 쓰기 N건에 1회로 상각. seal이 끝난 io들에 대해
 * post 전에 호출하고, post는 presynced 변형을 쓴다. */
int extstore_worker_sync_for_device(void *worker, obj_io *const *ios,
                                    unsigned int n);
int extstore_worker_post_write_presynced(void *worker, obj_io *io);
/* v3: staging 산정에 쓸 "워커당 post 전 큐 길이"를 알린다. prepare 전에 호출. */
void extstore_set_staging_need(void *ptr, unsigned int n);

/* v2 worker-inline READ/WRITE API. All *_worker functions touch only the
 * calling worker's resources (shared-nothing; see md/V2_CODE_SPEC.md P2).
 * prepare/create run in the MAIN thread before conns are dispatched. */
int extstore_workers_prepare(void *ptr, unsigned int nworkers,
                             unsigned int nqp, unsigned int window);
void *extstore_worker_create(void *ptr, unsigned int worker_id);
int extstore_worker_submit(void *worker, obj_io *chain);
char *extstore_worker_staging_get(void *worker);      /* P2b */
void extstore_worker_staging_put(void *worker, char *slot);
int extstore_worker_post_write(void *worker, obj_io *io);
int extstore_worker_drain(void *worker, int budget);
unsigned int extstore_worker_outstanding(void *worker);
void *extstore_worker_current(void); /* set during drain; for retry re-post */
int extstore_check(void *ptr, unsigned int page_id, uint64_t page_version);
void extstore_get_stats(void *ptr, struct extstore_stats *st);
uint64_t extstore_prof_stamp(void);
void extstore_prof_resp_done(void *worker, uint64_t t_read, uint64_t t_cmd,
                             uint64_t t_enter, uint64_t t_send);
void extstore_prof_read_done(void *ptr, obj_io *io,
        uint64_t crypto_start, uint64_t crypto_done);
/* span v3 WRITE 종료: WFLIGHT 해제 직후(= 응용에서 보이는 완료) 호출한다. */
void extstore_prof_write_e2e(void *worker, obj_io *io, uint64_t done);
/* EXT_RDMA_PROF: clear the per-op span histograms (call at phase start). */
void extstore_prof_reset(void *ptr);
void extstore_get_page_data(void *ptr, struct extstore_stats *st);

#endif
