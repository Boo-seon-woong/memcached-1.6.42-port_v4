# port_v2 재수정 명세: remote-only 전제의 구조 정리 (closed form)

기준일: 2026-07-28
base tree: `memcached-1.6.42-port` @ `3bb5553` 복사본
상태: **결정 완료 — 이 문서 기준으로 porting을 연속 진행한다.**
2026-07-28 대화로 확정된 결정: ① GET·SET 모두 worker-inline, IO thread 완전
삭제 ② 개발 게이트는 co-located, 최종 판정은 off-box ③ off-box stock 보정
측정을 최종 캠페인 앞에 배치 ④ eviction 제거(SET 실패 + lazy expiry).
각 단계 완료 시 해당 절을 실측 동작 기록으로 갱신한다. 변수 정의는
[`../GLOSSARY.md`](../GLOSSARY.md), 실측 근거는 v1 tree의
`md/THREE_EXP_20260727.md`·`md/CPU_COST_ACCOUNTING.md`·
`md/FRONTIER_7POINT_20260724.md`.

## 0. 전제, 목표, 비목표

### 전제

v1은 이미 값을 remote에만 둔다(hash에는 `ITEM_HDR` stub만, 1 GET = 1 RDMA
READ, STORED는 WRITE CQE 후). 그러나 "local에 value가 없다"는 사실이 구조에
반영되지 않았다:

1. **local value memory 관리 기구** — segmented LRU(hot/warm/cold), LRU
   maintainer, LRU crawler, slab rebalancer/automove, 63개 slab class.
   관리 대상인 local value가 존재하지 않는다.
2. **SSD 전제의 worker/IO thread 분리** — stock extstore는 `pread()`가
   블로킹이라 IO thread가 필수였다. RDMA post/poll은 논블로킹이므로 분리의
   존재 이유가 소멸했는데, 요청마다 mutex+cond 제출과 eventfd notify라는
   thread 경계 횡단 2회를 지불한다.

실측 근거(2026-07-27, THREE_EXP):

| 증거 | 수치 | 함의 |
|---|---|---|
| depth=1 천장이 QP(≤256)·pipeline(≤48)에 불변 | ~1.05M/s | 병목은 fabric·window가 아니라 per-request 직렬 경로 |
| 천장이 mcT에 비례 (4/8/10 → 0.65/1.05/0.93M/s) | worker당 0.13–0.16M/s | 직렬 경로는 worker당 지불, 8 초과는 경합 역효과 |
| depth amortization (worker당 0.131→0.53M/s, d1→d16) | 4× | 비용 대부분이 wakeup/notify류 — batch로 상각됨 |
| worker futex 1.99회/op vs stock 0.10회 (v1 최적화 전) | 19.4× | thread 경계 횡단이 syscall로 드러남 |
| server 코어 배치 | worker 8 + busy-poll IO 8 | 코어 절반이 handoff 상대편 유지에 소모 |

### 목표 (정량) — 10M ops/s

최종 목표는 **avg `<30µs`(span-v2)에서 10M GET/s**다. stock local-memory
memcached가 10M+를 달성한 전적이 있으므로 port가 그 이하를 목표할 이유가
없다. 10M이 강제하는 예산:

| 제약 | 유도 | 귀결 |
|---|---|---|
| CPU | 10M × per-op CPU = 필요 코어. stock 포화 0.90µs/op → 9코어. v1 port 3.45µs/op → 34.5코어(불가) | **v2 per-op server CPU ≤ 2.0µs** (syscall 제거 + IO 이중처리 제거 + 포화 batching). 20~24 server 코어에서 10~12M |
| 부하 공급 | client 자체가 10M 생성에 ~8-10코어 소요 | co-located로는 검증 불가 → **최종 판정은 off-box**(genie-side memtier, IPoIB). guest 24코어 전부 server |
| latency | avg<30µs ⇒ L = T×W ≤ 10M×30µs = 300 in-flight | window 예산 넉넉 (worker 20×W16=320 상한, §2.3) |
| fabric | 10M × 264B ≈ 2.6GB/s, CQE 10M/s | 100Gb HCA 여유 — 비병목 |

트랙별 목표:

| 트랙 | v1 실측 (2026-07-27) | v2 중간 게이트 (co-located) | v2 최종 (off-box) |
|---|---:|---:|---:|
| avg `<30µs` throughput | 4.25M/s @ p48 | ≥5.5M/s **그리고 server CPU ≤2.2µs/op** | **≥10M/s** |
| p99 `<30µs` (W=1 영역) | 1.05M/s, p99 12.7µs | ≥2M/s, p99 ≤15µs | off-box에서 재산정 (worker 수 확장) |

co-located 중간 게이트가 throughput이 아니라 **per-op CPU를 병행 판정**하는
이유: co-located에서는 client 공급이 ~7.8M에서 먼저 포화하므로(v1 stock
실측) 10M 달성 여부를 co-located 수치로 판정할 수 없다. CPU-µs/op가
off-box 상한의 선행 지표다.

### 비목표

- client↔memcached TCP protocol의 RDMA화 (×)
- crypto 계약 변경 (×) — AES-256-GCM, AAD binding, fail-closed 전부 유지
- genie protocol / `genie_memd` 변경 (×)
- remote compaction/GC 신설 (×) — slot free 재사용만 (v1 계승)
- eviction (×) — 확정 결정: stub/slot 고갈 시 SET 실패, TTL은 lazy 판정만

## 1. M1 — 제거 명세: local value memory 기구

원칙: **stub은 value가 아니다.** stub(=`item` header + key + `item_hdr`)은
고정 상한 크기의 인덱스 엔트리이고, 수명은 remote slot과 1:1이다. "메모리
압력" 개념이 local에서 사라지고 remote 용량이 유일한 한계다.

### 1.1 segmented LRU + LRU maintainer thread

| 항목 | 내용 |
|---|---|
| 대상 | `items.c`의 HOT/WARM/COLD/TEMP LRU 큐, `lru_maintainer_thread`, `lru_pull_tail`, ITEM_ACTIVE/FETCHED aging, `memcached.c:4718` `start_lru_maintainer` |
| 제거 이유 | evict할 value가 없다. stub 상한은 remote slot 수로 정적으로 결정(§1.4) — 메모리 압력이 정의되지 않는다 |
| 제거 방식 | LRU 큐 연결 자체를 제거. stub은 hash에만 존재. TTL은 조회 시 lazy 판정: 만료 stub을 만나면 그 자리에서 unlink + remote slot free |
| 파급 | `do_item_link/unlink`의 LRU 연결, `item_stats*` LRU 통계, `lru` proto 명령, `-o (no_)lru_maintainer` |
| 게이트 | G-base(§4) + `stats items`에서 LRU 카운터 제거 확인 |

능동 TTL 회수는 없다. 만료 키가 조회되지 않으면 remote slot 회수가 지연되는
것을 감수한다(확정 결정 ④; 현 workload는 TTL 미사용).

### 1.2 LRU crawler

| 항목 | 내용 |
|---|---|
| 대상 | `crawler.c/.h` 전체, `start_lru_crawler`, `lru_crawler` proto 명령 |
| 제거 방식 | 파일 제거 + `Makefile.am` 정리. proto 명령은 `CLIENT_ERROR unsupported` |
| 게이트 | G-base + `lru_crawler metadump`가 명시적 에러 반환 |

### 1.3 slab rebalancer / automove

| 항목 | 내용 |
|---|---|
| 대상 | `slabs_mover.c` 전체, `slabs automove`·`slabs reassign` proto 명령, `-o slab_reassign/slab_automove` |
| 제거 이유 | class가 1개가 되므로(§1.4) 재배분 연산이 정의되지 않는다 |
| 게이트 | G-base |

### 1.4 slab class 축퇴 → 단일 고정 크기 stub class

| 항목 | 내용 |
|---|---|
| 대상 | `slabs.c` class 배열(63개), growth factor, `do_item_alloc` class 선택 |
| 유지 | `slabs.c` 페이지/freelist 뼈대는 유지 (diff 최소). 전용 arena 교체는 P4 후보로만 남긴다 — stub alloc은 SET 경로 전용이라 GET hot path와 무관 |
| 변경 | class 1개 강제. slot 크기 = `sizeof(item) + KEY_MAX_LENGTH+1 + sizeof(item_hdr)` 상한 고정 ≈ 320B |
| 크기 산정 | remote 4GiB / `EXT_SLOT_SIZE` 256B = 16.7M slot → stub 전량 상주 최대 ~5.4GB. 현 실험 keyset(9B key, 1M)은 stub ≈96B → 96MB. `-m`은 "stub arena 상한"으로 의미 변경(§5) |
| eviction 부재 | stub alloc 실패 ⇔ `-m` 부족 → SET은 `SERVER_ERROR out of memory`. remote slot 고갈도 SET 실패(v1 계승). 기동 시 `-m`이 stub_max×slot 수 미만이면 경고 로그(§6 R4) |
| 게이트 | G-base + 1M preload 후 `stats slabs` class 1개 |

### 1.5 부수 정리

- 옵션 파싱: 삭제 knob(`lru_maintainer`, `lru_crawler`, `slab_reassign`,
  `slab_automove`, `hot/warm_lru_pct`, `temp_lru`, `lru_segmented` 등) 제거,
  도움말·`stats settings` 갱신.
- `stats` 대응 카운터 제거.
- `t/` 테스트 중 삭제 기능 의존분은 목록화 후 skip 처리(사유 주석).
- `assoc` maintenance thread와 logger는 **유지** — hash 확장·로깅은
  stub-only에서도 필요.

## 2. M2 — 재설계 명세: worker-inline READ/WRITE (shared-nothing, IO thread 삭제)

확정 결정 ①: GET과 SET 모두 worker-inline이며 `extstore_io_thread`는 코드째
삭제된다. thread 경계 횡단(제출 mutex+cond, 완료 eventfd)이 코드베이스에서
소멸한다.

### 2.1 자원 소유 모델

| 자원 | v1 | v2 |
|---|---|---|
| QP/CQ | IO thread당 1개 (`ext_threads`=QP) | **worker당 1개, QP 수 = mcT** |
| bounce pool (READ 착지) | IO thread당 `EXT_READ_SLOTS` | worker당 `EXT_READ_SLOTS` |
| staging pool (WRITE 원본) | engine 전역 + staging mutex/cond | **worker당 파티션, lock 없음** |
| crypto ctx | IO thread TLS | worker TLS (동일 코드 이식) |
| DMA sync ioctl batch | IO thread 31 op당 1회 | worker CQ drain에 동일 로직 이식 |
| span-v2 prof | engine 전역 | worker별 누적, stats 합산 (경계 정의 불변) |
| READ/WRITE 실행 주체 | IO thread | **worker 자신** |
| remote slot allocator | engine 전역 (`e->mutex`) | 전역 유지 — SET 전용 경로라 hot path 아님. 경합 실측 후 P4에서 재평가 |

worker 소유 자원은 소유 worker만 접근한다(§3 불변식).

### 2.2 GET 경로 명세

```
v1: worker lookup → [mutex+cond 제출]₁ → IO thread post → poll →
    decrypt → [eventfd+epoll 복귀]₂ → worker 응답
v2: worker lookup → post → (이벤트 루프 계속) → worker CQ drain →
    decrypt → 응답
```

1. `storage_get_item()` (worker): stub 확인, refcount++, bounce slot을 자기
   pool에서 확보. 없으면 conn을 worker-local 대기 리스트로 —
   backpressure (v1 "staging 부족은 wait" 불변식과 동형).
2. READ post (worker, inline): `ibv_post_send` signaled, `wr_id`=`obj_io`.
   post 실패는 v1과 동일한 engine dead 판정 규칙.
3. worker는 즉시 이벤트 루프로 복귀. conn은 기존 `io_queue_t` io-pending
   상태를 재사용하되, return이 cross-thread notify가 아니라 같은 thread의
   직접 호출이 된다.
4. **CQ drain 지점 2개**: (a) 소켓 이벤트 batch 처리 말미 1회,
   (b) `epoll_wait` 진입 직전 — outstanding>0이면 0-timeout 자기 이벤트
   (`event_active` 재무장)로 즉시 회전, 0이면 기존 timeout으로 잠든다.
   libevent 내부는 패치하지 않는다. completion channel 방식은
   `ibv_req_notify_cq` syscall 경로라 채택하지 않는다(폐기 결정).
5. drain: `ibv_poll_cq` ≤32. CQE별로 DMA sync(batch 규칙 유지) →
   `ext_crypto_open` → 기존 `_storage_get_item_cb` 검증 로직(재시도·badcrc·
   AAD) 그대로 → resp 완성 → conn 재개(직접 호출).
6. 공정성: 한 회전 drain ≤32, drain 연속 2회 사이에 반드시 소켓 이벤트 처리
   기회. TCP 기아 방지가 우선이고 READ 완료 지연은 span-v2로 감시.

### 2.3 outstanding window (`ext_worker_window`)

`ext_io_depth` → **worker당 미결 op 상한 W** (READ+WRITE 합산). 기본 W=16
(worker당 목표 λ≈0.5M/s × avg 예산 20µs ≈ 10 → 여유 포함 16; `EXT_READ_SLOTS`
와 연동, bounce slot 수가 READ분 상한). W 초과분은 대기 리스트 →
drain에서 slot 반환 시 대기 conn부터 재개.

**ORD 결합 규칙**: RC READ의 wire 동시성은 QP당 ORD/IRD로 제한되고 현재
16 하드코딩이다(`extstore.c:227` `initiator_depth=16`, HCA
`max_qp_rd_atom=16`). 기본 W=16은 QP 1개의 ORD 경계에 정확히 맞춘 값이며,
**W > 16×N(QP 수)으로 설정해도 초과분은 SQ에서 대기할 뿐 wire에 나가지
않는다.** W를 16 너머로 올리는 실험은 §2.7 QP fan-out을 전제로 한다.

### 2.4 SET 경로 명세 (inline)

1. worker: remote slot 할당(전역 allocator, SET 전용 lock), 자기 staging
   파티션의 slot에 `ext_crypto_seal` (worker TLS ctx — SET latency 계약
   "seal 시작→WRITE CQE"의 시작점).
2. WRITE post (worker, inline, signaled). conn은 io-pending — **STORED는
   WRITE CQE를 drain에서 수거한 뒤 반환**한다. v1의 "성공한 SET 전에 remote
   WRITE 완료" 불변식 유지, 대기 방식만 cond→drain으로 바뀐다.
3. WRITE CQE drain 시: stub publish(`ITEM_HDR` hash 연결) → STORED 응답.
   실패 CQE는 `NOT_STORED` + slot 반납(v1 계승).
4. staging mutex/cond(`extstore.c:162-163`), `storage_store_done_cb`의
   cross-thread 경로, `extstore_submit`의 큐 절반이 모두 삭제된다.
   `extstore_submit`은 "worker-local 즉시 post 함수"로 대체.

### 2.5 삭제되는 엔진 코드

| 대상 | 근거 |
|---|---|
| `extstore_io_thread` 전체 (`extstore.c:257-…`), `store_iothr` 구조체, per-thread queue/mutex/cond | READ·WRITE 모두 worker 소유가 됨 |
| `thread.c`의 storage notify 경로 (`notify_worker` 호출부 중 storage 몫) | same-thread 직접 호출로 대체 |
| staging mutex/cond, engine 전역 bounce 소유권 | per-worker 파티션 |
| `ext_threads` knob | 개념 소멸. QP 수 = mcT |

### 2.6 QP fan-out — worker당 QP N개 (기본 1)

ORD 상한(§2.3) 때문에 worker당 wire READ 병렬도는 QP 1개당 16이 한계다.
worker에 QP를 N개 주면 **thread(=코어 소비)를 늘리지 않고 wire 병렬도를
16N으로** 올릴 수 있다. v1의 QP 축 실험은 "QP 수 = thread 수"라 큐 효과와
CPU 효과가 결합돼 있었는데(THREE_EXP 측정 조건 명시), 이 변경이 두 축을
분리하는 실험 수단이기도 하다.

| 항목 | 명세 |
|---|---|
| 구조 | worker의 `qp`를 `qp[N]` 배열로. **CQ는 worker당 1개 공유** — verbs는 다중 QP:단일 CQ를 허용하고, 완료 식별은 `wr_id`의 `obj_io` 포인터라 출신 QP와 무관 |
| posting | round-robin 선택 + per-QP outstanding 계정(각 QP ≤16 준수). W(§2.3)는 worker 총량 상한으로 그대로 |
| genie 측 | 수정 불요 — connection당 QP를 만들 뿐 |
| knob | `ext_qp_per_worker` 기본 1. N>1은 W>16 실험에서만 의미 |
| 기대 한계 | **현 병목은 wire가 아니라 per-op CPU이므로 throughput 이득 보장 없음.** 이득이 나타나는 조건 = per-op CPU를 2.0µs 근처로 내린 뒤(P2c 통과 후) worker당 λ×span이 16을 넘는 지점 |

구현 시점: P2a에서 QP 생성부를 처음부터 배열 형태(N=1)로 작성한다 —
나중에 N>1을 켜는 비용을 RR 선택과 per-QP 계정 추가로 한정하기 위함.
활성 실험은 P4다.

### 2.7 실패·재시도 규칙 (계승 + 이관)

- GCM open 실패 재시도(≤`EXT_READ_RETRIES`)는 worker 내 재post. 재시도 중
  obj_io도 W에 계상(기아 방지).
- engine dead 판정, badcrc AAD 진단 덤프 경로 유지.
- fail-closed: 검증 실패 plaintext는 절대 반환하지 않는다(계승).

## 3. 불변식

v1 `SOURCE_CHANGE_SPEC.md` §2의 6개 전부 계승 + 추가:

1. worker 소유 QP/CQ/bounce/staging/crypto ctx는 소유 worker 외 접근 금지.
2. CQ drain과 소켓 이벤트 처리는 같은 thread에서 교대 — drain ≤32, 연속
   drain 2회 사이 이벤트 처리 기회 보장.
3. stub 수명 = remote slot과 1:1: unlink는 slot free를 동반하고 역도 성립
   (위반 = slot 회계 불일치 버그로 정의, stats로 감시).
4. span-v2 경계(READ post→CQE→sync→decrypt), SET 계약(seal 시작→WRITE CQE)
   불변 — v1/v2 비교의 전제.
5. STORED는 WRITE CQE 이후에만 (계승; 대기 방식만 변경).

## 4. 단계 계획과 게이트

**G-base**(공통): co-located harness로 기준점 `mtT=8×c16, mcT=8, pipeline=8,
window 상당값` 1점, 같은 boot의 v1 실측 대비 remote throughput ±5%,
miss/badcrc/RDMA failure/engine dead = 0, `extstore_prof_read_count ==
cmd_get`.

| 단계 | 내용 | 주요 diff | 게이트 |
|---|---|---|---|
| **P0** | §1.1–1.3 제거 (LRU/maintainer/crawler/mover) | `items.c` 대폭, `crawler.c`·`slabs_mover.c` 삭제, `memcached.c`/`proto_text.c` 정리 | G-base (성능 변화 비목표, tail 부수 관찰) |
| **P1** | §1.4 단일 stub class + §1.5 정리 | `slabs.c`, `items.c`, `memcached.c` | G-base + `stats slabs` class 1개 + 1M preload 무결 |
| **P2a** | GET worker-inline (§2.2–2.3). QP 생성부는 배열 형태로 작성(N=1, §2.6). IO thread는 이 단계 동안 WRITE 전용으로 잠정 유지 | `extstore.c`, `storage.c`, `thread.c` | smoke → W=1·mcT=8에서 worker당 ≥0.25M/s·p99≤15µs → mcT 8–14 단조성 |
| **P2b** | SET inline + IO thread·staging cond 완전 삭제 (§2.4–2.5) | `extstore.c` 대폭 삭제, `storage.c` | G-base + SET workload smoke(mixed-size-stress, torn-repro 계열 통과) + `ext_threads` 잔재 0 |
| **P2c** | co-located 중간 판정 | 코드 변경 없음 | **≥5.5M/s(avg<30µs) 그리고 server CPU ≤2.2µs/op**(`/proc` 회계, v1 방법론 동일). 미달 시 §6별 회귀 분석 후 진행 여부 재결정 |
| **P3a** | off-box 환경 구축 + **stock 보정**: genie-side memtier(IPoIB)로 stock을 guest 24코어에 얹어 박스 상한 확정. 10M+ 재현이 게이트 | 환경/스크립트만 | stock ≥10M/s 재현. 미달이면 병목(loadgen/IPoIB/코어)을 먼저 해소 — port 판정을 시작하지 않는다 |
| **P3b** | port 최종 캠페인 (off-box): THREE_EXP 축 재실행 + 10M 판정 | 코드 변경 없음 | **≥10M/s @ avg<30µs**. p99 트랙 상한도 재산정 |
| **P4** (보류 목록) | QP fan-out 활성 실험(§2.6, W>16 축), 전용 stub arena, remote slot allocator 분산, 편중 workload, compaction, SET-heavy 프로파일 | — | P3b 결과로 착수 여부 결정 |

단계별 독립 커밋, P2b까지 단계 단위 revert 가능. build flag 이중 경로는
두지 않는다 — **A/B는 tree 단위**(v1 tree 보존).

## 5. Knob·설정 매핑

| v1 | v2 | 비고 |
|---|---|---|
| `ext_threads` = QP = busy-poll IO | **삭제** | QP 수 = mcT (knob 아님) |
| `ext_io_depth` | `ext_worker_window` (기본 16) | worker당 미결 op(R+W) 상한 |
| `EXT_READ_SLOTS` (IO thread당) | 동일 이름, worker당 | READ분 window 상한 |
| (없음) | `ext_qp_per_worker` (기본 1) | §2.6 QP fan-out. N>1은 W>16 실험 전용 |
| staging 전역 pool | worker당 파티션 크기 = `EXT_STAGING_SLOTS`/mcT | 신규 산정식 |
| `-m` = slab 총량 | `-m` = stub arena 상한 | §1.4 산정식, 기동 시 경고 |
| runner `-o …,ext_threads=$ext,ext_io_depth=$depth` | `…,ext_worker_window=$W` | runner v2판은 P2a에서 함께 커밋. qp 축 → mcT 축으로 재정의 |
| CPU split: server 16 = worker 8 + IO 8 | co-located: server 16 = worker mcT / off-box: **24 전부 worker** | mtT는 off-box에서 guest와 무관 |

## 6. 리스크와 미결정

| # | 리스크 | 판단/완화 |
|---|---|---|
| R1 | worker가 TCP+RDMA 겸업 시 소켓 처리 지연이 READ 완료 지연으로 전이 | drain 상한·교대 규칙(§2.2-6). stock이 같은 박스 TCP만으로 7.8M/s(co-located)를 소화한 실측이 여유 근거 |
| R2 | 0-timeout 재무장 구간 CPU 소모 | outstanding 존재 시로 한정, idle 시 stock과 동일하게 잠듦. `stats`에 drain 회전수/빈 poll 비율 추가해 실측 |
| R3 | QP=mcT 확장(→24)의 자원 | v1 실측 QP 256까지 동작(THREE_EXP §2b). 비문제 |
| R4 | `-m`과 remote slot 수 불일치 운영 실수 | 기동 시 경고 로그 + `stats settings` 병기 |
| R5 | 편중 워크로드에서 per-worker 자원 파편화 | conn round-robin 배정으로 균등 부하에선 비문제. 편중은 P4 |
| R6 | same-thread return 재진입 | return 직접 호출은 drain 루프 안에서만, conn 재개는 이벤트 재무장으로 한 단계 지연 — 재진입 깊이 1 고정 |
| R7 | LRU 제거의 숨은 의존 (flush_all, `it->time`) | flush_all은 epoch 비교로 유지(LRU 불요). `t/` skip 목록을 P0 게이트에 포함 |
| R8 | **off-box 부하 경로(IPoIB TCP)가 10M을 못 실어 나르는 경우** | P3a의 stock 보정이 정확히 이걸 먼저 판정한다. stock 10M 재현 실패 시 loadgen/IPoIB 병목을 해소할 때까지 port 판정 유보 |
| R9 | SET inline 후 STORED 지연이 drain 주기에 종속 | WRITE CQE는 GET과 같은 CQ에서 drain — 추가 지연은 drain 회전 1회분(≤수 µs). SET latency 계약으로 실측 감시 |
| R10 | remote slot allocator 전역 lock의 SET 경합 | GET-only 캠페인엔 무관. SET-heavy는 P4에서 분산 여부 결정 |
| R11 | QP fan-out(§2.6)이 이득 없이 복잡도만 추가 | 기본 N=1로 dormant. 활성은 P2c(CPU ≤2.2µs/op) 통과 후 worker당 λ×span>16인 실측이 나올 때만 — 그 전에는 배열 구조만 유지 |

## 7. 관측 가능성 계약

- span-v2 경계 불변. v2에서 "post 이전 큐잉"이 구조적으로 소멸하므로 v1↔v2
  비교표에는 remote span과 memtier e2e를 항상 병기한다.
- `stats` 신규: `ext_worker_window`, worker별 drain 회전/빈 poll 비율(합산),
  bounce/staging 대기 발생 수, stub arena 사용량, slot 회계(§3-3 감시).
- CPU 회계: v1 방법론(`/proc` utime/stime ÷ 완료 GET) 그대로 — P2c 게이트의
  판정 도구.
- off-box 캠페인의 client 지표는 genie-side memtier 출력을 쓰고, guest
  내부 span-v2와 별축으로 기록한다(v1의 "Port span과 stock e2e를 직접 비교
  하지 않는다" 원칙 유지).
