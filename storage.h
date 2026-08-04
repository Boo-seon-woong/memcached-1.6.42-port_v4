#ifndef STORAGE_H
#define STORAGE_H

void storage_delete(void *e, item *it);
void storage_free_hdr(item *it);   /* item_free 훅 */
unsigned int storage_setq_max(void);
void storage_post_chain_flush(void *t);  /* pass 끝에 남은 체인을 비운다 */
/* unlink 시점 회수는 하지 않는다. 호출처가 9군데(items/proto_parser/
 * proto_bin/proto_proxy/memcached)라 하나씩 지우면 하나를 빠뜨린다 — 한 곳에서
 * 막고, 실제 회수는 item_free 훅(storage_free_hdr)이 한다.
 *
 * 상류는 unlink 에서 회수해도 안전했다. 페이지 단위로 재활용하고 page_version
 * 으로 낡은 읽기를 걸러냈기 때문이다. 이 포트는 슬롯 단위로 재활용하면서
 * 버전을 올리지 않아(extstore.c:534) 그 안전망이 없다. unlink 에서 회수하면
 * 그 슬롯이 다음 SET 에 재할당돼, 읽는 중인 원격 메모리를 덮어쓴다. */
#define STORAGE_delete(e, it)   do { (void)(e); (void)(it); } while (0)

/* EXT_RDMA_PROF: 클라이언트 가시 지연 분해. memcached.c 의 소켓 read /
 * 응답 완료 지점에서 부른다. 꺼져 있으면 분기 하나로 끝난다.
 * (extstore.h 를 memcached.c 에 통째로 들이지 않으려고 여기 둔다.) */
uint64_t extstore_prof_stamp(void);
void extstore_prof_resp_done(void *worker, uint64_t t_read, uint64_t t_cmd,
                             uint64_t t_send);

// API.
void storage_stats(ADD_STAT add_stats, void *c);
void process_extstore_stats(ADD_STAT add_stats, void *c);
void storage_prof_reset(void);   // D6: clear in-server span histograms
bool storage_validate_item(void *e, item *it);
unsigned int storage_slot_size(void *conf);
#ifdef EXTSTORE
int storage_get_item(LIBEVENT_THREAD *t, item *it, mc_resp *resp);
int storage_prepare_workers(void *storage, int nthreads);
void storage_flush_returns(void);
// v3 pac: flush the deferred WRITE queue (one SYNC_FOR_DEVICE, then post N).
// Called at the end of each event-loop pass, before the sleep decision.
void storage_flush_pending_writes(void);
// Commit one value remotely and return an unlinked ITEM_HDR. Caller holds
// item_lock(hv); no local value is published on failure.
int storage_store_item(void *e, item *it, item **hdr_it, uint32_t hv);
// v3 pac: publish-at-command async SET. Returns 1 = pending accepted
// (*hdr_it is ready to publish now; response is written at WRITE CQE),
// 0 = not taken (caller falls back to the sync path), -1 = hard failure.
int storage_store_item_pac(void *e, item *it, item **hdr_it, uint32_t hv,
                           LIBEVENT_THREAD *t);
#else
#define storage_get_item NULL
#endif

// callback for the IO queue subsystem.
void storage_submit_cb(io_queue_t *q);

// Init functions.
struct extstore_conf_file *storage_conf_parse(char *arg);
void *storage_init_config(struct settings *s);
int storage_read_config(void *conf, char **subopt);
int storage_check_config(void *conf);
void *storage_init(void *conf);

// Ignore pointers and header bits from the CRC
#define STORE_OFFSET offsetof(item, nbytes)

#endif
