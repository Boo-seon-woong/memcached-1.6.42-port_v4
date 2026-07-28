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
    uint64_t prof_write_count, prof_write_avg_ns, prof_write_p50_ns, prof_write_p99_ns;
    /* Span v2 breakout: crypto + sync (SWIOTLB advise) + transfer, avg ns. */
    uint64_t prof_read_crypto_avg_ns, prof_write_crypto_avg_ns;
    uint64_t prof_read_sync_avg_ns,  prof_read_xfer_avg_ns;
    uint64_t prof_write_sync_avg_ns, prof_write_xfer_avg_ns;
    struct extstore_page_data *page_data;
};

// TODO: Temporary configuration structure. A "real" library should have an
// extstore_set(enum, void *ptr) which hides the implementation.
// this is plenty for quick development.
struct extstore_conf {
    unsigned int page_size; // ideally 64-256M in size
    unsigned int page_count;
    unsigned int page_buckets; // number of size-class buckets for remote slots
    unsigned int io_threadcount; // = number of RDMA QPs
    unsigned int io_depth;     // max outstanding RDMA ops per IO thread
    // RDMA port additions:
    unsigned int slot_size;    // bounce/staging slot size (>= max remote object)
    unsigned int read_slots;   // bounce slots per IO thread (<= 64)
    unsigned int write_slots;  // total staging slots
    unsigned int worker_window;   // v2: per-worker outstanding cap (<= 64)
    unsigned int qp_per_worker;   // v2: QPs per worker (1..EXT_QP_MAX)
};

struct extstore_conf_file {
    unsigned int page_count;
    char *file;                // genie host
    int cport;                 // genie control-channel TCP port
    uint64_t total_size; // size in bytes, before page_count slicing
    struct extstore_conf_file *next;
};

/* v2 (P2a): worker-inline READ path. */
#define EXT_QP_MAX 4          /* ext_qp_per_worker upper bound */
#define EXT_ORD_LIMIT 16      /* HCA max_qp_rd_atom; matches initiator_depth */

enum obj_io_mode {
    OBJ_IO_READ = 0,
    OBJ_IO_WRITE,
};

typedef struct _obj_io obj_io;
typedef void (*obj_io_cb)(void *e, obj_io *io, int ret);

/* An object for both reads and writes to the storage engine.
 * Once an IO is submitted, ->next may be changed by the IO thread. It is not
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
    EXTSTORE_INIT_THREAD_FAIL,
    EXTSTORE_INIT_SELFTEST_FAIL
};

const char *extstore_err(enum extstore_res res);
void *extstore_init(struct extstore_conf_file *fh, struct extstore_conf *cf, enum extstore_res *res);
/* Allocate a remote slot of `len` bytes in size-class `bucket`. 0 on success. */
int extstore_alloc(void *ptr, unsigned int len, unsigned int bucket, struct ext_loc *out);
void extstore_free_loc(void *ptr, const struct ext_loc *loc);
int extstore_submit(void *ptr, obj_io *io);

/* v2 (P2a) worker-inline READ API. All *_worker functions touch only the
 * calling worker's resources (shared-nothing; see md/V2_CODE_SPEC.md P2a).
 * prepare/create run in the MAIN thread before conns are dispatched. */
int extstore_workers_prepare(void *ptr, unsigned int nworkers,
                             unsigned int nqp, unsigned int window);
void *extstore_worker_create(void *ptr, unsigned int worker_id);
int extstore_worker_submit(void *worker, obj_io *chain);
int extstore_worker_drain(void *worker, int budget);
unsigned int extstore_worker_outstanding(void *worker);
void *extstore_worker_current(void); /* set during drain; for retry re-post */
/* Staging slots for the write path (ciphertext source for RDMA WRITE). */
char *extstore_staging_get(void *ptr);
void extstore_staging_put(void *ptr, char *slot);
int extstore_check(void *ptr, unsigned int page_id, uint64_t page_version);
int extstore_delete(void *ptr, unsigned int page_id, uint64_t page_version, unsigned int count, unsigned int bytes);
void extstore_get_stats(void *ptr, struct extstore_stats *st);
uint64_t extstore_prof_stamp(void);
void extstore_prof_read_done(void *ptr, obj_io *io,
        uint64_t crypto_start, uint64_t crypto_done);
/* EXT_RDMA_PROF: clear the per-op span histograms (call at phase start). */
void extstore_prof_reset(void *ptr);
void extstore_get_page_data(void *ptr, struct extstore_stats *st);

#endif
