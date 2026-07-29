/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/* v2 (P0): local value memory is gone (remote-only stubs), so the segmented
 * LRU, its maintainer thread, the crawler hooks and the bump machinery are
 * removed. Items live only in the hash table; TTL/flush are lazy on access.
 * See md/V2_CODE_SPEC.md P0. */
#include "memcached.h"
#include "storage.h"
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <assert.h>
#include <unistd.h>
#include <poll.h>

#define LARGEST_ID POWER_LARGEST
typedef struct {
    uint64_t reclaimed;
    uint64_t outofmemory;
    uint64_t expired_unfetched; /* items reclaimed but never touched */
    uint64_t mem_requested;
} itemstats_t;

/* Indexed by plain slab class id; lru_locks kept as the per-class stat lock. */
static itemstats_t itemstats[LARGEST_ID];
static unsigned int sizes[LARGEST_ID];
static uint64_t sizes_bytes[LARGEST_ID];
static unsigned int *stats_sizes_hist = NULL;
static int stats_sizes_buckets = 0;
static uint64_t cas_id = 1;

static pthread_mutex_t cas_id_lock = PTHREAD_MUTEX_INITIALIZER;

void item_stats_reset(void) {
    int i;
    for (i = 0; i < LARGEST_ID; i++) {
        pthread_mutex_lock(&lru_locks[i]);
        memset(&itemstats[i], 0, sizeof(itemstats_t));
        pthread_mutex_unlock(&lru_locks[i]);
    }
}

/* Get the next CAS id for a new item. */
uint64_t get_cas_id(void) {
    pthread_mutex_lock(&cas_id_lock);
    uint64_t next_id = ++cas_id;
    pthread_mutex_unlock(&cas_id_lock);
    return next_id;
}

void set_cas_id(uint64_t new_cas) {
    pthread_mutex_lock(&cas_id_lock);
    cas_id = new_cas;
    pthread_mutex_unlock(&cas_id_lock);
}

int item_is_flushed(item *it) {
    rel_time_t oldest_live = settings.oldest_live;
    if (it->time <= oldest_live && oldest_live <= current_time)
        return 1;

    return 0;
}

/* Enable this for reference-count debugging. */
#if 0
# define DEBUG_REFCNT(it,op) \
                fprintf(stderr, "item %x refcnt(%c) %d %c%c%c\n", \
                        it, op, it->refcount, \
                        (it->it_flags & ITEM_LINKED) ? 'L' : ' ', \
                        (it->it_flags & ITEM_SLABBED) ? 'S' : ' ')
#else
# define DEBUG_REFCNT(it,op) while(0)
#endif

static size_t item_make_header(const uint8_t nkey, const client_flags_t flags, const int nbytes,
                     char *suffix, uint8_t *nsuffix) {
    if (flags == 0) {
        *nsuffix = 0;
    } else {
        *nsuffix = sizeof(flags);
    }
    return sizeof(item) + nkey + *nsuffix + nbytes;
}

/* 워커 전용 item magazine.
 *
 * 전역 slabs_lock은 alloc/free 각각 1건마다 잡히므로 SET 경로에서 CPU의
 * 절반 가까이를 소모한다(측정: slabs_alloc 33.3% + slabs_free 13.4%).
 * GET은 복호 목적지를 _Thread_local cache_t에서 꺼내 이 비용을 피하는데,
 * stub item은 해시테이블에 등재되므로 같은 방식을 쓸 수 없다. 대신 슬랩
 * 계층 앞에 워커 전용 자유 목록을 두고 배치로 채우고 비운다.
 *
 * magazine에 든 항목의 상태는 slab 자유 목록에 있을 때와 동일하게
 * (ITEM_SLABBED, slabs_clsid) 유지하고, 꺼낼 때 do_slabs_alloc과 같은
 * 전이(플래그 해제 + refcount=1)를 적용한다. chunked item은 별도 해제
 * 경로가 필요하므로 제외한다. */
static _Thread_local struct {
    void *v[ITEM_MAG_MAX];
    unsigned int n;
} g_item_mag[MAX_NUMBER_OF_SLAB_CLASSES];

/* No eviction in v2: allocation failure is an OOM error, never an evict. */
item *do_item_alloc_pull(const size_t ntotal, const unsigned int id) {
    unsigned int depth = settings.item_mag_depth;
    if (depth > ITEM_MAG_MAX) depth = ITEM_MAG_MAX;
    if (depth > 0 && id < MAX_NUMBER_OF_SLAB_CLASSES) {
        if (g_item_mag[id].n == 0)
            g_item_mag[id].n = slabs_alloc_batch(id, g_item_mag[id].v, depth);
        if (g_item_mag[id].n > 0) {
            item *it = (item *)g_item_mag[id].v[--g_item_mag[id].n];
            /* do_slabs_alloc과 동일한 전이 */
            it->it_flags &= ~ITEM_SLABBED;
            it->refcount = 1;
            return it;
        }
    }
    item *it = slabs_alloc(id, 0);
    if (it == NULL) {
        pthread_mutex_lock(&lru_locks[id]);
        itemstats[id].outofmemory++;
        pthread_mutex_unlock(&lru_locks[id]);
    }
    return it;
}

/* Chain another chunk onto this chunk. */
item_chunk *do_item_alloc_chunk(item_chunk *ch, const size_t bytes_remain) {
    // TODO: Should be a cleaner way of finding real size with slabber calls
    size_t size = bytes_remain + sizeof(item_chunk);
    if (size > settings.slab_chunk_size_max)
        size = settings.slab_chunk_size_max;
    unsigned int id = slabs_clsid(size);

    item_chunk *nch = (item_chunk *) do_item_alloc_pull(size, id);
    if (nch == NULL) {
        if (size == settings.slab_chunk_size_max) {
            return NULL;
        } else {
            size = settings.slab_chunk_size_max;
            id = slabs_clsid(size);
            nch = (item_chunk *) do_item_alloc_pull(size, id);

            if (nch == NULL)
                return NULL;
        }
    }

    // link in.
    // ITEM_CHUNK[ED] bits need to be protected by the slabs lock.
    slabs_mlock();
    nch->head = ch->head;
    ch->next = nch;
    nch->prev = ch;
    nch->next = 0;
    nch->used = 0;
    nch->slabs_clsid = id;
    nch->size = size - sizeof(item_chunk);
    nch->it_flags |= ITEM_CHUNK;
    slabs_munlock();
    return nch;
}

item *do_item_alloc(const char *key, const size_t nkey, const client_flags_t flags,
                    const rel_time_t exptime, const int nbytes) {
    uint8_t nsuffix;
    item *it = NULL;
    char suffix[40];
    // Avoid potential underflows.
    if (nbytes < 2)
        return 0;

    size_t ntotal = item_make_header(nkey + 1, flags, nbytes, suffix, &nsuffix);
    if (settings.use_cas) {
        ntotal += sizeof(uint64_t);
    }

    unsigned int id = slabs_clsid(ntotal);
    unsigned int hdr_id = 0;
    if (id == 0)
        return 0;

    /* This is a large item. Allocate a header object now, lazily allocate
     *  chunks while reading the upload.
     */
    if (ntotal > settings.slab_chunk_size_max) {
        int htotal = nkey + 1 + nsuffix + sizeof(item) + sizeof(item_chunk);
        if (settings.use_cas) {
            htotal += sizeof(uint64_t);
        }
#ifdef NEED_ALIGN
        // header chunk needs to be padded on some systems
        int remain = htotal % 8;
        if (remain != 0) {
            htotal += 8 - remain;
        }
#endif
        hdr_id = slabs_clsid(htotal);
        it = do_item_alloc_pull(htotal, hdr_id);
        /* setting ITEM_CHUNKED is fine here because we aren't LINKED yet. */
        if (it != NULL)
            it->it_flags |= ITEM_CHUNKED;
    } else {
        it = do_item_alloc_pull(ntotal, id);
    }

    if (it == NULL)
        return NULL;

    assert(it->it_flags == 0 || it->it_flags == ITEM_CHUNKED);

    /* Refcount is seeded to 1 by slabs_alloc() */
    it->next = it->prev = 0;
    it->slabs_clsid = id;

    DEBUG_REFCNT(it, '*');
    it->it_flags |= settings.use_cas ? ITEM_CAS : 0;
    it->it_flags |= nsuffix != 0 ? ITEM_CFLAGS : 0;
    it->nkey = nkey;
    it->nbytes = nbytes;
    memcpy(ITEM_key(it), key, nkey);
    it->exptime = exptime;
    if (nsuffix > 0) {
        memcpy(ITEM_suffix(it), &flags, sizeof(flags));
    }

    /* Initialize internal chunk. */
    if (it->it_flags & ITEM_CHUNKED) {
        item_chunk *chunk = (item_chunk *) ITEM_schunk(it);

        chunk->next = 0;
        chunk->prev = 0;
        chunk->used = 0;
        chunk->size = 0;
        chunk->head = it;
        chunk->orig_clsid = hdr_id;
    }
    it->h_next = 0;

    return it;
}

void item_free(item *it) {
    unsigned int clsid;
    assert((it->it_flags & ITEM_LINKED) == 0);
    assert(it->refcount == 0);

    /* so slab size changer can tell later if item is already free or not */
    clsid = ITEM_clsid(it);
    DEBUG_REFCNT(it, 'F');
    {
        unsigned int depth = settings.item_mag_depth;
        if (depth > ITEM_MAG_MAX) depth = ITEM_MAG_MAX;
        if (depth > 0 && clsid < MAX_NUMBER_OF_SLAB_CLASSES &&
            (it->it_flags & ITEM_CHUNKED) == 0 &&
            g_item_mag[clsid].n < depth) {
            /* do_slabs_free와 동일한 전이 (자유 목록 연결만 생략) */
            it->it_flags = ITEM_SLABBED;
            it->slabs_clsid = clsid;
            g_item_mag[clsid].v[g_item_mag[clsid].n++] = it;
            return;
        }
    }
    slabs_free(it, clsid);
}

/**
 * Returns true if an item will fit in the cache (its size does not exceed
 * the maximum for a cache entry.)
 */
bool item_size_ok(const size_t nkey, const client_flags_t flags, const int nbytes) {
    char prefix[40];
    uint8_t nsuffix;
    if (nbytes < 2)
        return false;

    size_t ntotal = item_make_header(nkey + 1, flags, nbytes,
                                     prefix, &nsuffix);
    if (settings.use_cas) {
        ntotal += sizeof(uint64_t);
    }

    return slabs_clsid(ntotal) != 0;
}

/* Per-class accounting shared by link/unlink. */
static void item_acct_add(item *it) {
    unsigned int id = ITEM_clsid(it);
    pthread_mutex_lock(&lru_locks[id]);
    sizes[id]++;
#ifdef EXTSTORE
    if (it->it_flags & ITEM_HDR) {
        sizes_bytes[id] += (ITEM_ntotal(it) - it->nbytes) + sizeof(item_hdr);
    } else {
        sizes_bytes[id] += ITEM_ntotal(it);
    }
#else
    sizes_bytes[id] += ITEM_ntotal(it);
#endif
    pthread_mutex_unlock(&lru_locks[id]);
}

static void item_acct_remove(item *it) {
    unsigned int id = ITEM_clsid(it);
    pthread_mutex_lock(&lru_locks[id]);
    sizes[id]--;
#ifdef EXTSTORE
    if (it->it_flags & ITEM_HDR) {
        sizes_bytes[id] -= (ITEM_ntotal(it) - it->nbytes) + sizeof(item_hdr);
    } else {
        sizes_bytes[id] -= ITEM_ntotal(it);
    }
#else
    sizes_bytes[id] -= ITEM_ntotal(it);
#endif
    pthread_mutex_unlock(&lru_locks[id]);
}

/* fixing stats/references during warm start */
void do_item_link_fixup(item *it) {
    int ntotal = ITEM_ntotal(it);
    uint32_t hv = hash(ITEM_key(it), it->nkey);
    assoc_insert(it, hv);

    item_acct_add(it);

    STATS_LOCK();
    stats_state.curr_bytes += ntotal;
    stats_state.curr_items += 1;
    stats.total_items += 1;
    STATS_UNLOCK();

    item_stats_sizes_add(it);

    return;
}

int do_item_link(item *it, const uint32_t hv, const uint64_t cas) {
    MEMCACHED_ITEM_LINK(ITEM_key(it), it->nkey, it->nbytes);
    assert((it->it_flags & (ITEM_LINKED|ITEM_SLABBED)) == 0);
    it->it_flags |= ITEM_LINKED;
    it->time = current_time;

    STATS_LOCK();
    stats_state.curr_bytes += ITEM_ntotal(it);
    stats_state.curr_items += 1;
    stats.total_items += 1;
    STATS_UNLOCK();

    /* Allocate a new CAS ID on link. */
    ITEM_set_cas(it, cas);
    assoc_insert(it, hv);
    item_acct_add(it);
    refcount_incr(it);
    item_stats_sizes_add(it);

    return 1;
}

void do_item_unlink(item *it, const uint32_t hv) {
    MEMCACHED_ITEM_UNLINK(ITEM_key(it), it->nkey, it->nbytes);
    if ((it->it_flags & ITEM_LINKED) != 0) {
        it->it_flags &= ~ITEM_LINKED;
        STATS_LOCK();
        stats_state.curr_bytes -= ITEM_ntotal(it);
        stats_state.curr_items -= 1;
        STATS_UNLOCK();
        item_stats_sizes_remove(it);
        assoc_delete(ITEM_key(it), it->nkey, hv);
        item_acct_remove(it);
        do_item_remove(it);
    }
}

/* v2: identical to do_item_unlink — the nolock variant only differed in LRU
 * queue locking, which no longer exists. Kept as a symbol to minimize caller
 * churn. */
void do_item_unlink_nolock(item *it, const uint32_t hv) {
    do_item_unlink(it, hv);
}

void do_item_remove(item *it) {
    MEMCACHED_ITEM_REMOVE(ITEM_key(it), it->nkey, it->nbytes);
    assert((it->it_flags & ITEM_SLABBED) == 0);
    assert(it->refcount > 0);

    if (refcount_decr(it) == 0) {
        item_free(it);
    }
}

/* v2: no LRU to reposition in; just refresh the access time. */
void do_item_update(item *it) {
    MEMCACHED_ITEM_UPDATE(ITEM_key(it), it->nkey, it->nbytes);
    if ((it->it_flags & ITEM_LINKED) != 0) {
        it->time = current_time;
    }
}

int do_item_replace(item *it, item *new_it, const uint32_t hv, const uint64_t cas) {
    MEMCACHED_ITEM_REPLACE(ITEM_key(it), it->nkey, it->nbytes,
                           ITEM_key(new_it), new_it->nkey, new_it->nbytes);
    assert((it->it_flags & ITEM_SLABBED) == 0);

    do_item_unlink(it, hv);
    return do_item_link(new_it, hv, cas);
}

/* v2: no LRU to walk. flush_all relies on the lazy item_is_flushed() check
 * on every access; nothing to do eagerly. */
void item_flush_expired(void) {
    return;
}

/* v2: "stats cachedump" needed the LRU order; without one there is nothing
 * meaningful to dump. Return an empty, well-formed response. */
char *item_cachedump(const unsigned int slabs_clsid, const unsigned int limit, unsigned int *bytes) {
    char *buffer = malloc(64);
    if (buffer == 0)
        return NULL;
    memcpy(buffer, "END\r\n", 6);
    *bytes = 5;
    return buffer;
}

void item_stats_totals(ADD_STAT add_stats, void *c) {
    itemstats_t totals;
    memset(&totals, 0, sizeof(itemstats_t));
    int n;
    for (n = 0; n < LARGEST_ID; n++) {
        pthread_mutex_lock(&lru_locks[n]);
        totals.reclaimed += itemstats[n].reclaimed;
        totals.expired_unfetched += itemstats[n].expired_unfetched;
        totals.outofmemory += itemstats[n].outofmemory;
        pthread_mutex_unlock(&lru_locks[n]);
    }
    APPEND_STAT("expired_unfetched", "%llu",
                (unsigned long long)totals.expired_unfetched);
    APPEND_STAT("reclaimed", "%llu",
                (unsigned long long)totals.reclaimed);
    APPEND_STAT("outofmemory", "%llu",
                (unsigned long long)totals.outofmemory);
}

void item_stats(ADD_STAT add_stats, void *c) {
    int n;
    for (n = 0; n < LARGEST_ID; n++) {
        const char *fmt = "items:%d:%s";
        char key_str[STAT_KEY_LEN];
        char val_str[STAT_VAL_LEN];
        int klen = 0, vlen = 0;
        unsigned int size;
        uint64_t bytes;
        itemstats_t istats;

        pthread_mutex_lock(&lru_locks[n]);
        size = sizes[n];
        bytes = sizes_bytes[n];
        istats = itemstats[n];
        pthread_mutex_unlock(&lru_locks[n]);

        if (size == 0)
            continue;
        APPEND_NUM_FMT_STAT(fmt, n, "number", "%u", size);
        APPEND_NUM_FMT_STAT(fmt, n, "mem_requested", "%llu", (unsigned long long)bytes);
        APPEND_NUM_FMT_STAT(fmt, n, "outofmemory",
                            "%llu", (unsigned long long)istats.outofmemory);
        APPEND_NUM_FMT_STAT(fmt, n, "reclaimed",
                            "%llu", (unsigned long long)istats.reclaimed);
        APPEND_NUM_FMT_STAT(fmt, n, "expired_unfetched",
                            "%llu", (unsigned long long)istats.expired_unfetched);
    }

    /* getting here means both ascii and binary terminators fit */
    add_stats(NULL, 0, NULL, 0, c);
}

bool item_stats_sizes_status(void) {
    bool ret = false;
    if (stats_sizes_hist != NULL)
        ret = true;
    return ret;
}

void item_stats_sizes_init(void) {
    if (stats_sizes_hist != NULL)
        return;
    stats_sizes_buckets = settings.item_size_max / 32 + 1;
    stats_sizes_hist = calloc(stats_sizes_buckets, sizeof(int));
}

void item_stats_sizes_add(item *it) {
    if (stats_sizes_hist == NULL)
        return;
    int ntotal = ITEM_ntotal(it);
    int bucket = ntotal / 32;
    if ((ntotal % 32) != 0) bucket++;
    if (bucket < stats_sizes_buckets) stats_sizes_hist[bucket]++;
}

void item_stats_sizes_remove(item *it) {
    if (stats_sizes_hist == NULL)
        return;
    int ntotal = ITEM_ntotal(it);
    int bucket = ntotal / 32;
    if ((ntotal % 32) != 0) bucket++;
    if (bucket < stats_sizes_buckets) stats_sizes_hist[bucket]--;
}

/** dumps out a list of objects of each size, with granularity of 32 bytes */
/*@null@*/
void item_stats_sizes(ADD_STAT add_stats, void *c) {
    if (stats_sizes_hist != NULL) {
        int i;
        for (i = 0; i < stats_sizes_buckets; i++) {
            if (stats_sizes_hist[i] != 0) {
                char key[12];
                snprintf(key, sizeof(key), "%d", i * 32);
                APPEND_STAT(key, "%u", stats_sizes_hist[i]);
            }
        }
    } else {
        APPEND_STAT("sizes_status", "disabled", "");
    }

    add_stats(NULL, 0, NULL, 0, c);
}

/** wrapper around assoc_find which does the lazy expiration logic */
item *do_item_get(const char *key, const size_t nkey, const uint32_t hv, LIBEVENT_THREAD *t, const bool do_update) {
    item *it = assoc_find(key, nkey, hv);
    if (it != NULL) {
        refcount_incr(it);
    }
#ifdef EXTSTORE
    /* Remote-only invariant: a storage-enabled hash table may contain metadata
     * stubs, never a locally serviceable value. Remove any legacy/faulted full
     * item instead of silently turning it into a local-cache hit. */
    if (it != NULL && t->storage != NULL && (it->it_flags & ITEM_HDR) == 0) {
        do_item_unlink(it, hv);
        do_item_remove(it);
        it = NULL;
    }
#endif
    int was_found = 0;

    if (it != NULL) {
        was_found = 1;
        if (item_is_flushed(it)) {
            do_item_unlink(it, hv);
            STORAGE_delete(t->storage, it);
            do_item_remove(it);
            it = NULL;
            pthread_mutex_lock(&t->stats.mutex);
            t->stats.get_flushed++;
            pthread_mutex_unlock(&t->stats.mutex);
            was_found = 2;
        } else if (it->exptime != 0 && it->exptime <= current_time) {
            do_item_unlink(it, hv);
            STORAGE_delete(t->storage, it);
            do_item_remove(it);
            it = NULL;
            pthread_mutex_lock(&t->stats.mutex);
            t->stats.get_expired++;
            pthread_mutex_unlock(&t->stats.mutex);
            was_found = 3;
        } else {
            if (do_update) {
                do_item_bump(t, it, hv);
            }
            DEBUG_REFCNT(it, '+');
        }
    }

    if (settings.verbose > 2) {
        fprintf(stderr, "> %s ", was_found ? "FOUND KEY" : "NOT FOUND");
        for (int ii = 0; ii < nkey; ++ii) {
            fprintf(stderr, "%c", key[ii]);
        }
        if (was_found == 2) {
            fprintf(stderr, " -removed by flush");
        } else if (was_found == 3) {
            fprintf(stderr, " -removed by expire");
        }

        fprintf(stderr, "\n");
    }
    /* For now this is in addition to the above verbose logging. */
    LOGGER_LOG(t->l, LOG_FETCHERS, LOGGER_ITEM_GET, NULL, was_found, key,
               nkey, (it) ? it->nbytes : 0, (it) ? ITEM_clsid(it) : 0, t->cur_sfd);

    return it;
}

// Requires lock held for item.
/* v2: no LRU segments to shuffle between; record the access and move on. */
void do_item_bump(LIBEVENT_THREAD *t, item *it, const uint32_t hv) {
    it->it_flags |= ITEM_FETCHED;
    it->time = current_time;
}

item *do_item_touch(const char *key, size_t nkey, uint32_t exptime,
                    const uint32_t hv, LIBEVENT_THREAD *t) {
    item *it = do_item_get(key, nkey, hv, t, DO_UPDATE);
    if (it != NULL) {
        it->exptime = exptime;
    }
    return it;
}
