/* v2 (P0): LRU queues/maintainer/crawler/bump machinery removed — items live
 * only in the hash table. The LRU id bit macros are kept because ITEM_clsid()
 * and historical stats code mask with them. See md/V2_CODE_SPEC.md P0. */
#define HOT_LRU 0
#define WARM_LRU 64
#define COLD_LRU 128
#define TEMP_LRU 192

#define CLEAR_LRU(id) (id & ~(3<<6))
#define GET_LRU(id) (id & (3<<6))

/* See items.c */
uint64_t get_cas_id(void);
void set_cas_id(uint64_t new_cas);

/*@null@*/
item *do_item_alloc(const char *key, const size_t nkey, const client_flags_t flags, const rel_time_t exptime, const int nbytes);
item_chunk *do_item_alloc_chunk(item_chunk *ch, const size_t bytes_remain);
item *do_item_alloc_pull(const size_t ntotal, const unsigned int id);
void item_free(item *it);
bool item_size_ok(const size_t nkey, const client_flags_t flags, const int nbytes);

int  do_item_link(item *it, const uint32_t hv, const uint64_t cas);     /** may fail if transgresses limits */
void do_item_unlink(item *it, const uint32_t hv);
void do_item_unlink_nolock(item *it, const uint32_t hv);
void do_item_remove(item *it);
void do_item_update(item *it);   /** refresh access time */
int  do_item_replace(item *it, item *new_it, const uint32_t hv, const uint64_t cas);
void do_item_link_fixup(item *it);

int item_is_flushed(item *it);

void item_flush_expired(void);

/*@null@*/
char *item_cachedump(const unsigned int slabs_clsid, const unsigned int limit, unsigned int *bytes);
void item_stats(ADD_STAT add_stats, void *c);
void item_stats_totals(ADD_STAT add_stats, void *c);
/*@null@*/
void item_stats_sizes(ADD_STAT add_stats, void *c);
void item_stats_sizes_init(void);
void item_stats_sizes_add(item *it);
void item_stats_sizes_remove(item *it);
bool item_stats_sizes_status(void);

item *do_item_get(const char *key, const size_t nkey, const uint32_t hv, LIBEVENT_THREAD *t, const bool do_update);
item *do_item_touch(const char *key, const size_t nkey, uint32_t exptime, const uint32_t hv, LIBEVENT_THREAD *t);
void do_item_bump(LIBEVENT_THREAD *t, item *it, const uint32_t hv);
void item_stats_reset(void);
extern pthread_mutex_t lru_locks[POWER_LARGEST];
