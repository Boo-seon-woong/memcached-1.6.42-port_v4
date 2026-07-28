# V2 코드 명세 (function/structure level)

기준일: 2026-07-28. 상위 계획: [`V2_REMODIFICATION_SPEC.md`](V2_REMODIFICATION_SPEC.md).
라인 번호는 base `3bb5553` 기준이며 심볼 이름이 우선한다.

**규칙: 개발 중 새 결정을 만들지 않는다.** 이 문서에 없는 결정이 필요해지면
구현을 멈추고 이 문서를 먼저 갱신·커밋한 뒤 진행한다. 각 절 끝의 체크리스트가
해당 단계의 완료 정의다.

공통 사실 (측정·코드로 확정된 전제):

| 사실 | 근거 |
|---|---|
| SET은 동기식: worker가 stack의 `store_wait` cond로 WRITE CQE를 기다림 | `storage.c:595-611` |
| GET 완료 반환은 `return_io_pending()` → ion_lock/STAILQ → eventfd notify | `storage.c:346`, `thread.c:814` |
| worker→engine 제출은 `storage_submit_cb()`가 iop stack을 obj_io 체인으로 변환 후 `extstore_submit` | `storage.c:456-471` |
| ORD/IRD=16 하드코딩 → QP당 wire 동시 READ ≤16. WRITE는 ORD 무관 | `extstore.c:227` |
| IO thread별 자원: QP/CQ/bounce(bitmap 64)/queue+mutex+cond/prof | `store_iothr`, `extstore.c:123-142` |
| staging pool은 engine 전역 + mutex/cond | `store_engine` 말미 |
| `LIBEVENT_THREAD`에 `void *storage` 필드 존재 (engine 포인터) | `memcached.h:713` |
| 인바운드 SET은 값 전체를 담는 **임시 full item을 slabs에서 할당** 후 seal | `storage_store_item(e, it, …)`의 `it` |

---

## P0 — LRU/crawler/mover 제거

### P0.1 `items.c`

**삭제하는 심볼** (본문과 프로토타입 모두):

```
static item_link_q / do_item_link_q / item_link_q_warm     (items.c:407-446)
static item_unlink_q / do_item_unlink_q                    (items.c:447-486)
lru_pull_tail                                              (items.c:1082)
lru_maintainer 계열 전부: do_run_lru_maintainer_thread,
  lru_maintainer_lock, lru_maintainer_thread, lru_maintainer_crawler_check,
  start_lru_maintainer_thread, stop_lru_maintainer_thread,
  lru_maintainer_pause/resume
bump 계열 전부: lru_bump_buf, bump_buf_head/tail/lock,
  lru_bump_async, lru_total_bumps_dropped, item_lru_bump_buf_create,
  lru_bump_buf_link_q                                      (items.c:93-100, 1260-…)
lru_type_map                                               (items.c:23)
do_get_lru_size                                            (items.c:126)
item_stats의 per-LRU 구간, stats_sizes의 LRU 참조
```

**수정하는 심볼**:

- `do_item_link(item *it, uint32_t hv)`: `item_link_q(it)` 호출 삭제.
  나머지(refcount, hash 연결, stats, cas) 유지.
- `do_item_unlink(...)` / `do_item_unlink_nolock(...)`: `item_unlink_q(it)`
  호출 삭제.
- `do_item_bump(LIBEVENT_THREAD *t, item *it, uint32_t hv)`: 본문을
  `it->time = current_time;` 한 줄로 축소 (lazy TTL·`stats items`의 age
  근사에 필요). ITEM_FETCHED 플래그 설정은 유지.
- `do_item_alloc_pull(...)`: `lru_pull_tail` 호출 분기 삭제 —
  `slabs_alloc` 실패는 즉시 NULL 반환 (eviction 없음 결정).
- `item` struct의 `next/prev` 필드: **P0-P1에서는 유지**(dead field,
  stub당 16B 낭비 감수). 제거는 P4 후보. 이유: ITEM_ntotal/매크로 파급을
  P0 게이트 안에서 늘리지 않기 위함.
- `item_is_flushed()` (flush_all 판정): **유지** — epoch 비교라 LRU 불요.

### P0.2 파일 삭제

- `crawler.c`, `crawler.h` 삭제. `Makefile.am`의
  `memcached_SOURCES`/`memcached_debug_SOURCES`에서 제거.
- `slabs_mover.c` 삭제, 동일하게 Makefile 정리.
  (`slab_automove_extstore.c`는 v1에서 이미 제거됨.)

### P0.3 `memcached.c`

- `bool start_lru_maintainer/start_lru_crawler` (4718-4719) 및 이를 읽는
  기동 블록 삭제. `start_assoc_maint`(4720)는 유지.
- settings 필드 삭제(선언은 `memcached.h`): `lru_maintainer_thread`,
  `lru_segmented`, `hot_lru_pct`, `warm_lru_pct`, `hot_max_factor`,
  `warm_max_factor`, `temp_lru`, `temporary_ttl`, `lru_crawler`,
  `lru_crawler_sleep`, `lru_crawler_tocrawl`, `crawls_persleep`,
  `slab_reassign`, `slab_automove`, `slab_automove_ratio`,
  `slab_automove_window`, `slab_automove_freeratio`.
- 옵션 파싱: 위 필드에 대응하는 subopt enum 값과 `case` 절 삭제
  (`memcached.c:5232-5560` 범위에 분포). `usage()` 텍스트 갱신.
- `stats settings` 출력에서 해당 항목 제거.

### P0.4 `proto_text.c`

- `process_lru_command` 삭제, dispatcher에서 `"lru"` 분기 →
  `out_string(c, "CLIENT_ERROR unsupported")`.
- `lru_crawler` 분기 동일 처리.
- `slabs reassign`/`slabs automove` 분기 동일 처리 (`slabs` stats는 유지).

### P0.5 `thread.c`

- worker init의 `item_lru_bump_buf_create()` 호출과
  `LIBEVENT_THREAD.lru_bump_buf` 필드(`memcached.h:716`) 삭제.

### P0.6 게이트 체크리스트

- [ ] `make && make test` — 실패 테스트는 전부 “삭제 기능 의존”으로 분류되어
      `t/` skip 목록(`t/SKIPPED_V2.list` 신규 파일)에 사유와 함께 기재
- [ ] `stats items`/`stats`에 LRU/crawler/automove 카운터 부재
- [ ] `lru`, `lru_crawler`, `slabs reassign|automove` 명령이 CLIENT_ERROR
- [ ] G-base: 같은 boot의 v1 대비 기준점 throughput ±5%, correctness 0

---

## P1 — slab class 축퇴 (2-class)

**결정 수정** (계획 spec §1.4의 "단일 class"를 정정): 인바운드 SET이 값
전체를 담는 임시 full item을 slabs에서 할당하므로 class는 **2개**다.

```c
/* slabs.c 상단에 상수화 */
#define V2_CLS_STUB      1   /* ITEM_HDR stub */
#define V2_CLS_TRANSIENT 2   /* 인바운드 SET 임시 full item */

/* 크기 산식 (컴파일 타임, static_assert로 고정) */
stub_chunk      = sizeof(item) + KEY_MAX_LENGTH + 1 + 8 /*cas*/ + sizeof(item_hdr);
                  /* ≈ 48+250+1+8+24 = 331 → 8B 정렬 336 */
transient_chunk = sizeof(item) + KEY_MAX_LENGTH + 1 + 8
                  + (EXT_SLOT_SIZE_MAX - EXT_CRYPTO_OVERHEAD);
                  /* slot 256, overhead 33 기준 ≈ 530 → 8B 정렬 536 */
static_assert(stub_chunk <= transient_chunk, "class order");
```

`EXT_SLOT_SIZE_MAX`는 기동 시 `EXT_SLOT_SIZE` env 값(기본 256)으로 채우는
전역 — `slabs_init` 호출 전에 storage 설정이 파싱되므로 순서 문제 없음
(현 기동 순서: settings 파싱 → storage_read_config → slabs_init).

### 수정 심볼

- `slabs_clsid(const size_t size)` (`slabs.c:77`): 새 본문 —
  `size <= stub_chunk → V2_CLS_STUB; size <= transient_chunk →
  V2_CLS_TRANSIENT; else → 0 (실패)`.
- `slabs_init(...)` (`slabs.c:202`): factor 루프 대신 위 두 class만 구성.
  `slab_sizes`/`factor` 인자 경로는 무시하고 경고 로그.
- 값 크기 검증: `proto_text.c`/`proto_bin.c`의 item_alloc 실패 시 기존
  `SERVER_ERROR object too large for cache` 경로가 그대로 동작 —
  transient_chunk 초과 SET은 여기서 거부된다 (remote slot 초과와 동일
  조건이므로 의미 일치).

### 게이트 체크리스트

- [ ] `stats slabs`에 class 1, 2만 존재
- [ ] 1M preload 무결 (`curr_items == 1000000`)
- [ ] 값 크기 경계 테스트: ntotal이 slot 한도 ±1B에서 STORED/오류 정확
- [ ] G-base

---

## P2a — GET worker-inline

### P2a.1 `extstore.h` — 신규 구조체와 API

```c
#define EXT_QP_MAX 4          /* ext_qp_per_worker 상한 */
#define EXT_ORD_LIMIT 16      /* HCA max_qp_rd_atom, extstore.c:227과 일치 */

typedef struct store_worker {
    store_engine *e;                    /* init 후 read-only */
    struct rdma_cm_id *cm_id[EXT_QP_MAX];
    struct ibv_qp *qp[EXT_QP_MAX];
    struct ibv_cq *cq;                  /* worker당 1개, 모든 qp[i]가 공유 */
    unsigned int nqp;                   /* = settings ext_qp_per_worker */
    unsigned int rr;                    /* posting round-robin 커서 */
    unsigned int read_out[EXT_QP_MAX];  /* QP별 미결 READ, ≤ EXT_ORD_LIMIT */
    unsigned int outstanding;           /* READ+WRITE 총합, ≤ window */
    unsigned int window;                /* = settings ext_worker_window */
    char *bounce_base;  uint64_t bounce_free;   /* READ 착지, bitmap */
    char *staging_base; uint64_t staging_free;  /* WRITE 원본, bitmap (P2b) */
    obj_io *wait_head, *wait_tail;      /* window/slot 부족 대기 (FIFO) */
    struct event drain_ev;              /* 0-timeout self event */
    bool drain_armed;
    unsigned int sync_batch;            /* DMA sync 31-op 배치 카운터 */
    LIBEVENT_THREAD *t;
    /* prof 블록: store_iothr의 prof_* 필드 전체를 그대로 이동 */
    ...
} store_worker;

/* main thread에서 worker thread 기동 전에 순차 호출. cm 연결 포함. */
store_worker *extstore_worker_create(void *engine, int worker_id, int nqp);
/* obj_io 체인(READ만)을 제출. window/ORD/slot 여유만큼 즉시 post,
 * 나머지는 wait list. 반환: post된 개수(<0 = engine dead). */
int extstore_worker_submit(store_worker *w, obj_io *chain);
/* CQ를 budget개까지 poll. sync-batch → cb dispatch → wait list refill →
 * drain_ev 재무장 판단. 반환: 완료 처리 개수. */
int extstore_worker_drain(store_worker *w, int budget);
```

`extstore_submit`(구 API)·`store_iothr`는 P2a 동안 WRITE 전용으로 잔존,
P2b에서 삭제.

### P2a.2 `extstore.c` — 초기화·연결 순서 (결정)

1. `extstore_init`: PD/MR/remote 연결 정보까지만 (io thread READ 경로는
   컴파일 유지하되 `io_threadcount`는 write 전용 수로 축소, §P2b에서 제거).
2. `memcached.c` main: `memcached_thread_init(...)` 직후, listen 시작 전에
   `for (i<nthreads) t[i].ext_worker = extstore_worker_create(e, i, nqp);`
   — **모든 cm 연결은 main thread에서 순차 수행** (lock 불요, 결정적).
   genie는 connection당 QP를 수락하므로 무수정.
3. QP attr: `max_send_wr = window+1`, `max_recv_wr = 1`, sge 1.
   CQ 크기: `2 * window * nqp`.
4. bounce/staging MR: 기존 `bounce_mr` 영역을 worker 수로 파티션.
   worker i의 `bounce_base = e->bounce_all + i * EXT_READ_SLOTS * slot_size`.
   MR 등록은 전체 1회(현행과 동일), lkey 공유.

### P2a.3 `extstore_worker_submit` 알고리즘

```
for io in chain:
    if outstanding >= window or bounce_free == 0: append wait list; continue
    slot = ffsll(bounce_free); bounce_free &= ~bit; io->buf = base+slot*sz
    qp_i = rr 순회로 read_out[qp_i] < EXT_ORD_LIMIT 인 첫 QP (없으면 wait list)
    WR 구성은 v1 io thread post 블록(extstore.c:283-297)과 동일, 단 체인은
      같은 qp_i로 묶일 때만 next 연결
    read_out[qp_i]++, outstanding++
ibv_post_send 실패 → engine dead 규칙 (v1과 동일: e->dead set, 이후 전부 miss)
post 후 outstanding>0 && !drain_armed → event_active(&drain_ev), drain_armed=true
```

### P2a.4 `extstore_worker_drain` 알고리즘

```
n = ibv_poll_cq(cq, min(budget,32), wc)
for each wc:
    io = (obj_io *)wc.wr_id
    read_out[해당 qp]--, outstanding--        (qp index는 obj_io에 1B 필드 추가)
    wc.status != SUCCESS → engine dead 규칙
    DMA sync: 기존 31-op 배치 로직 (SYNC_FOR_CPU advise) 그대로 이식
    io->cb(e, io, len)      /* _storage_get_item_cb — 이제 worker에서 실행 */
    bounce slot 반환
wait list에서 여유만큼 재submit (post 로직 재사용)
outstanding == 0 → drain_armed=false (재무장 안 함), else event_active 재무장
```

drain 호출 지점 2곳 (`thread.c`):
- `drain_ev` 콜백 자체 (`extstore_worker_drain(w, 32)` 후 위 재무장 규칙)
- worker 이벤트 루프에는 추가 훅 불요 — 0-timeout self event가 (b)지점
  역할을 하고, libevent가 소켓 이벤트와 자동 교대시킨다 (공정성 불변식 충족)

### P2a.5 `storage.c`

- `storage_submit_cb(io_queue_t *q)` 새 본문: 기존 iop→obj_io 체인 변환
  (456-470) 유지, 마지막 줄만
  `extstore_submit(q->ctx, eio_head)` → `extstore_worker_submit(t->ext_worker, eio_head)`.
  `t`는 `q->thread` (io_queue_t가 보유; 없으면 iop 첫 항목의 `p->thread`).
- `_storage_get_item_cb`: 변경 1곳 — `return_io_pending((io_pending_t *)p)`
  (`storage.c:346`) → **직접 반환 단계 호출**. 구현: thread.c의 ion drain
  루프가 iop당 수행하는 그 호출(= `p->return_cb(p)` 상당)을 함수로 추출
  (`iop_return_one(io_pending_t*)`, thread.c에 신설)하고 여기서 호출한다.
  재진입 규칙: `storage_return_cb`는 conn 재개를 event 재무장으로 미루므로
  깊이 1 고정 (계획 spec R6).
- retry 재제출(`storage.c:235`): `extstore_submit` → `extstore_worker_submit`.
  retry 중 obj_io는 이미 outstanding에서 빠져 있으므로 재계상 자연 성립.
- `storage_get_item`: 변경 없음 (bounce 확보가 submit으로 이동했으므로
  이 함수의 slot 로직은 건드리지 않는다 — v1도 submit 시점 확보였음).

### P2a.6 `memcached.h` / knob

- `LIBEVENT_THREAD`에 `void *ext_worker;` 1필드 추가 (`storage` 필드 옆).
- `storage_read_config`: `ext_worker_window=`(기본 16, 1..64 clamp),
  `ext_qp_per_worker=`(기본 1, 1..EXT_QP_MAX) 파싱 추가.
  `ext_io_depth`는 P2a 동안 write 경로용으로 잔존.

### P2a.7 runner

`tools/config-matrix-10s.sh` v2판: server 명령의
`-o ext_path=...,ext_threads=$ext,ext_io_depth=$depth` →
`-o ext_path=...,ext_worker_window=$W`. 축 정의: qp축 삭제, `W축(1..64)`과
`mcT축` 신설. CSV 컬럼 `qp,ext_threads,depth` → `nqp,window` 재명명.

### P2a.8 게이트 체크리스트

- [ ] smoke: `genie_connect OK` × mcT개 연결, GET 1회 왕복
- [ ] W=1, mcT=8: worker당 ≥0.25M/s, p99 ≤15µs (v1 depth=1 대비 ≥2×)
- [ ] mcT 8→14 스윕: throughput 단조 증가 (코어 여유 구간)
- [ ] correctness 0 (miss/badcrc/rf/dead), `prof_read_count == cmd_get`
- [ ] `stats`: drain 회전수, 빈 poll 비율, wait list 발생 수 노출

---

## P2b — SET inline + IO thread 삭제

### P2b.1 `storage_store_item` 새 동기화 (결정: **bounded spin, 계약 불변**)

`store_wait`/cond 블록(`storage.c:595-611`)을 다음으로 교체. memcached.c의
store 경로(동기 반환 계약)는 무수정:

```c
/* storage.c */
struct inline_wait { bool done; int ret; };
static void storage_store_done_inline(void *e, obj_io *io, int ret) {
    struct inline_wait *iw = io->data; iw->ret = ret; iw->done = true;
}
...
struct inline_wait iw = {0};
io.cb = storage_store_done_inline; io.data = &iw;
if (extstore_worker_post_write(w, &io) != 0) goto fail;  /* 신규, 아래 */
while (!iw.done) {
    if (extstore_worker_drain(w, 32) < 0) break;   /* engine dead */
    /* GET CQE가 섞여 완료돼도 안전: conn 재개는 event로 미뤄짐 (R6) */
}
```

- spin 상한: drain이 dead를 보고하거나 `iw.done`. RTT ~3µs이므로 루프는
  통상 1-2회전. wall timeout은 두지 않는다 — v1도 무한 cond 대기였고
  dead 판정이 유일한 탈출이라는 계약 동일.
- `extstore_worker_post_write(w, obj_io*)`: submit의 WRITE 변형 —
  bounce 대신 staging, **read_out/ORD 계정 없음**(WRITE는 ORD 무관),
  outstanding/window에는 계상.

### P2b.2 staging의 worker 파티션화

- `extstore_staging_get/put(void *e)` → `(store_worker *w)` 시그니처 변경.
  bitmap 방식은 bounce와 동일 (`staging_free`). 슬롯 수 =
  `EXT_STAGING_SLOTS / nworkers` (기본값은 현 전역값 유지 후 분할).
- 호출부는 `storage_store_item` 1곳.

### P2b.3 삭제 목록 (전부 이 단계에서)

```
extstore.c: extstore_io_thread 전체, store_iothr typedef와 배열,
            io_threadcount/io_depth/last_io_thread, staging_mutex/cond,
            extstore_submit(구), per-iothr prof 블록(→ store_worker로 이관 완료)
storage.c:  store_wait 구조체, storage_store_done_cb(구 cond 버전)
thread.c:   ion 경로의 storage 사용이 0이 됐는지 확인 후 ion 자체는 유지
            (proxy 등 다른 큐 타입이 사용) — storage 몫 주석만 갱신
설정:       ext_threads=/ext_io_depth= 파싱 제거, GLOSSARY/README 반영
```

### P2b.4 게이트 체크리스트

- [ ] SET/GET mixed smoke + `tools/mixed-size-stress.sh`, `tools/torn-repro.sh` 통과
- [ ] `grep -rn "ext_threads\|store_iothr\|staging_cond"` 결과 0 (문서 제외)
- [ ] SET latency 계약 실측: seal→CQE span이 v1 대비 악화 없음
- [ ] G-base (GET 기준점)

---

## P2c / P3 — 측정 (코드 변경 없음)

계획 spec §4의 게이트를 그대로 사용. P2c의 CPU 회계는 v1 방법론
(`tools/cpu-stage-detail.sh`)을 v2 thread 구성에 맞게 tid 필터만 수정.

## 신규 stats 카운터 (이름 확정)

| 이름 | 의미 |
|---|---|
| `ext_worker_drain_calls` / `ext_worker_drain_empty` | drain 회전 / 빈 poll |
| `ext_worker_wait_enq` | window/slot 부족으로 대기한 op 수 |
| `ext_worker_write_spins` | SET spin 루프 총 회전 |
| `ext_slot_acct_leak` | 불변식 §3-3 위반 감지 (0이어야 함) |

## 명시적 비결정 항목 (spec 갱신 필요 시에만)

없음 — 위 내용으로 P0~P2b는 결정 완결이다. 구현 중 이 문서와 코드가
충돌하면 (예: 심볼 이동) 심볼 이름을 anchor로 삼고, 의미 차이가 나면
구현을 멈추고 본 문서를 갱신한다.
