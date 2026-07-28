# port_v2 재수정 명세: remote-only 전제의 구조 정리

기준일: 2026-07-28
base tree: `memcached-1.6.42-port` @ `3bb5553` 복사본
성격: **구현 전 계획 명세.** v1의 `SOURCE_CHANGE_SPEC.md`가 "현재 동작"만
기록하는 것과 달리, 이 문서는 바꿀 것·바꾸는 이유·검증 게이트를 먼저 적는다.
각 단계가 끝나면 해당 절을 실측 동작 기록으로 갱신한다. 변수 정의는
[`../GLOSSARY.md`](../GLOSSARY.md), 실측 근거는 v1 tree의
`md/THREE_EXP_20260727.md`와 `md/CPU_COST_ACCOUNTING.md`를 가리킨다.

## 0. 전제, 목표, 비목표

### 전제

v1은 이미 값을 remote에만 둔다(불변식: hash에는 `ITEM_HDR` stub만, 1 GET =
1 RDMA READ, STORED는 WRITE CQE 후). 그러나 **"local에 value가 없다"는 사실이
구조에는 반영되지 않았다.** value가 존재하지 않는데 value를 위해 존재하는
stock 기구가 그대로 돌고 있다:

1. **local value memory 관리 기구** — segmented LRU(hot/warm/cold), LRU
   maintainer, LRU crawler, slab rebalancer/automove, 다단계 slab class.
   관리 대상인 local value가 없으므로 전부 무의미한 상주 비용이다.
2. **SSD 전제의 worker/IO thread 분리** — stock extstore는 `pread()`가
   블로킹이라 IO thread가 필수였다. RDMA post/poll은 논블로킹이므로 분리
   이유가 소멸했는데, 요청마다 mutex+cond 제출과 eventfd notify라는 thread
   경계 횡단 2회를 지불한다.

실측 근거(2026-07-27, THREE_EXP):

| 증거 | 수치 | 함의 |
|---|---|---|
| depth=1 천장이 QP(≤256)·pipeline(≤48)에 불변 | ~1.05M/s | 병목은 fabric·window가 아니라 per-request 직렬 경로 |
| 천장이 mcT에 비례 (4/8/10 → 0.65/1.05/0.93M/s) | worker당 0.13–0.16M/s | 직렬 경로는 worker당 지불, 8 초과는 경합 역효과 |
| depth amortization (worker당 0.131→0.53M/s, d1→d16) | 4× | 비용의 대부분이 wakeup/notify류 — batch로 상각됨 |
| worker futex 1.99회/op vs stock 0.10회 (v1 최적화 전) | 19.4× | thread 경계 횡단이 syscall로 드러남 |
| server 코어 배치 | worker 8 + busy-poll IO 8 | 코어의 절반이 handoff 상대편 유지에 소모 |

### 목표 (정량)

| 트랙 | v1 실측 (2026-07-27) | v2 목표 | 근거 |
|---|---:|---:|---|
| p99 `<30µs` (depth=1 영역) | 1.05M/s, p99 12.7µs | **≥2M/s, p99 ≤15µs** | 직렬 7.6µs/worker → CPU-bound ~3.5µs로 단축, 8 worker 기준 |
| avg `<30µs` (throughput) | 4.25M/s @ p48 | **≥5.5M/s** | IO 코어 8개를 worker로 전환(mcT 12–14), stock 동일 박스 7.8M/s의 70% 수준 |

### 비목표

- client↔memcached TCP protocol의 RDMA화 (×)
- crypto 계약 변경 (×) — AES-256-GCM, AAD binding, fail-closed 전부 유지
- genie protocol / `genie_memd` 변경 (×)
- SET/WRITE 경로 재설계 (× — P4 이후 별도 판단, §2.5)
- remote compaction/GC 신설 (× — v1과 동일하게 slot free 재사용만)

## 1. M1 — 제거 명세: local value memory 기구

원칙: **stub은 value가 아니다.** stub(=`item` header + key + `item_hdr`)은
고정 상한 크기의 인덱스 엔트리이고, 그 수명은 remote slot과 1:1이다. 따라서
"메모리 압력"이라는 개념이 local에서 사라지고 remote 용량이 유일한 한계가
된다.

### 1.1 segmented LRU + LRU maintainer thread

| 항목 | 내용 |
|---|---|
| 대상 | `items.c`의 HOT/WARM/COLD/TEMP LRU 큐, `lru_maintainer_thread`, `lru_pull_tail`, ITEM_ACTIVE/FETCHED aging, `memcached.c:4718` `start_lru_maintainer` |
| 현재 역할 | local value 메모리가 찰 때 세대별 eviction |
| 제거 이유 | evict할 value가 없다. stub 상한은 remote slot 수로 정적으로 결정되므로(§1.4) 메모리 압력 자체가 정의되지 않는다 |
| 제거 방식 | LRU 큐를 단일 리스트로 축퇴시키지 않고 **큐 연결 자체를 제거**한다. stub은 hash와 (expiry를 위한) 없음 — TTL은 조회 시 lazy 판정만 유지 |
| 파급 | `do_item_link/unlink`의 LRU 연결 코드, `item_stats*`의 LRU 통계, `lru` proto 명령(`proto_text.c`), `-o (no_)lru_maintainer` 설정 |
| 게이트 | G-base(§4) 통과 + `stats items`에서 LRU 카운터 제거 확인 |

TTL 정책: lazy expiry만 유지한다. 조회가 만료 stub을 만나면 그 자리에서
unlink + remote slot free. 능동 회수는 없다(비목표 아님 — crawler 제거의
귀결이며, 만료 키가 조회되지 않으면 remote slot이 늦게 회수되는 것을
감수한다. 우리 workload는 TTL 미사용이라 실측 영향 0).

### 1.2 LRU crawler

| 항목 | 내용 |
|---|---|
| 대상 | `crawler.c/.h` 전체, `start_lru_crawler`(`memcached.c:4719`), `lru_crawler` proto 명령 |
| 현재 역할 | LRU를 순회하며 만료 item 선회수, metadump |
| 제거 이유 | LRU가 사라지면 순회 대상도 사라진다. metadump는 우리 실험 경로에서 미사용 |
| 제거 방식 | 파일 제거 + `Makefile.am`에서 삭제. proto 명령은 `CLIENT_ERROR unsupported` 반환 |
| 게이트 | G-base + `lru_crawler metadump` 명령이 명시적 에러를 반환 |

### 1.3 slab rebalancer / automove

| 항목 | 내용 |
|---|---|
| 대상 | `slabs_mover.c` 전체(v1에서 이미 `slab_automove_extstore` 정책은 삭제됨), `slabs automove` proto 명령, `-o slab_reassign/slab_automove` |
| 현재 역할 | slab class 간 페이지 재배분 |
| 제거 이유 | §1.4에 의해 class가 1개가 되므로 재배분이라는 연산이 정의되지 않는다 |
| 제거 방식 | 파일 제거, thread 미기동, 명령 에러화 |
| 게이트 | G-base |

### 1.4 slab class 축퇴 → 단일 고정 크기 stub class

| 항목 | 내용 |
|---|---|
| 대상 | `slabs.c`의 class 배열(기본 63개), growth factor, `do_item_alloc`의 class 선택 |
| 유지 | `slabs.c`의 페이지 할당/freelist 뼈대 자체는 유지한다 (diff 최소화 — P1에서 전용 arena로 교체할지는 §4 P1에서 재평가) |
| 변경 | class를 1개로 강제한다. slot 크기 = `sizeof(item) + KEY_MAX_LENGTH+1 + sizeof(item_hdr)` 상한 고정 |
| 크기 산정 | item header ≈48B + key ≤251B + item_hdr ≈24B → **320B/stub**. remote 4GiB / `EXT_SLOT_SIZE` 256B = 16.7M slot → stub 전량 상주 시 최대 ~5.4GB. 현 실험(9B key, 1M keys)은 stub ≈96B, 96MB. `-m`은 "stub arena 상한"으로 의미가 바뀐다(§5) |
| eviction 부재의 정합성 | stub alloc 실패 ⇔ `-m` 부족. 이때 SET은 **evict가 아니라 `SERVER_ERROR out of memory` 실패**다. remote slot 고갈도 동일하게 SET 실패(v1 계승). 운영자는 `-m ≥ stub_max × remote_slots`로 설정해 두 한계를 일치시킨다 |
| 게이트 | G-base + 1M preload 후 `stats slabs`가 class 1개만 보고 |

### 1.5 부수 정리

- `memcached.c` 옵션 파싱: 삭제된 knob들(`lru_maintainer`, `lru_crawler`,
  `slab_reassign`, `slab_automove`, `hot/warm_lru_pct`, `temp_lru`,
  `lru_segmented` 등)을 파싱 단계에서 제거하고 도움말 갱신.
- `stats` 출력에서 대응 카운터 제거. `stats settings` 갱신.
- `t/` 테스트 중 삭제 기능 의존 테스트는 목록화 후 skip 처리(삭제하지 않고
  skip 사유 주석 — upstream diff 추적용).
- `assoc` maintenance thread(`start_assoc_maint`)와 logger는 **유지**한다.
  hash 확장과 로깅은 stub-only에서도 필요하다.

## 2. M2 — 재설계 명세: worker-inline READ (shared-nothing)

### 2.1 자원 소유 모델

| 자원 | v1 | v2 |
|---|---|---|
| QP/CQ | IO thread당 1개, `ext_threads=QP` | **worker당 1개, QP 수 = mcT** (+write thread QP) |
| bounce pool | IO thread당 `EXT_READ_SLOTS` | worker당 `EXT_READ_SLOTS` (§2.3 window와 연동) |
| crypto ctx | IO thread TLS (v1 최적화) | worker TLS (같은 코드 경로 재사용) |
| DMA sync ioctl batch | IO thread에서 31 op당 1회 | worker CQ drain에 동일 로직 이식 |
| span-v2 prof 카운터 | engine 전역 | worker별 누적 → stats에서 합산 (경계 정의 불변) |
| READ 실행 주체 | IO thread | **worker 자신** |
| WRITE/staging 실행 주체 | IO thread | IO thread (축소: write 전용, §2.5) |

모든 worker 소유 자원은 그 worker만 접근한다. cross-thread post/poll 금지가
새 불변식이다(§3).

### 2.2 GET 경로 명세

v1 경로에서 밑줄 친 두 횡단이 사라진다:

```
v1: worker lookup → [mutex+cond 제출]₁ → IO thread post → CQE poll →
    decrypt → [eventfd+epoll 복귀]₂ → worker 응답
v2: worker lookup → post → (이벤트 루프 계속) → worker CQ drain →
    decrypt → 응답
```

단계 명세:

1. `storage_get_item()` (worker): stub 확인, refcount++, bounce slot을
   **자기 pool에서** 확보. 없으면 conn을 worker-local 대기 리스트에 넣고
   `EWOULDBLOCK` 경로로 반환 (backpressure — v1의 "staging 부족은 wait"
   불변식과 동형).
2. READ post (worker, inline): `ibv_post_send` signaled. `wr_id` = 기존
   `obj_io` 포인터 그대로. 실패 시 즉시 miss 처리 아님 — v1과 동일하게
   engine dead 판정 규칙 적용.
3. worker는 즉시 이벤트 루프로 복귀한다. conn은 v1과 같은 io-pending 상태
   (기존 `io_queue_t` 기구 재사용 — 단 return_cb가 cross-thread notify가
   아니라 같은 thread의 직접 호출이 된다).
4. **CQ drain 지점** (worker 이벤트 루프에 2개 삽입):
   - (a) 처리 중인 소켓 이벤트 batch가 끝날 때마다 1회
   - (b) `epoll_wait` 진입 직전: outstanding > 0이면 timeout=0, 0이면 기존
     timeout (idle worker는 v1과 동일하게 잠든다 — busy-poll 코어 소모는
     outstanding이 있는 동안만)
5. drain: `ibv_poll_cq` 최대 32개. 각 CQE에 대해 DMA sync(batch 규칙 유지)
   → `ext_crypto_open` → 기존 `_storage_get_item_cb`의 검증 로직(재시도,
   badcrc, AAD) 그대로 → resp 완성 → conn 재개(직접 호출).
6. 공정성 규칙: 한 루프 회전에서 drain ≤ 32, 이후 반드시 소켓 이벤트를
   처리한다. TCP 기아 방지가 우선이고, READ 완료 지연은 span-v2에 그대로
   드러나므로 측정으로 감시한다.

### 2.3 outstanding window (신규 knob `ext_worker_window`)

`ext_io_depth`(IO thread당 미결 상한)를 **worker당 미결 READ 상한 W**로
대체한다. L=λW 예산으로 기본값을 정한다: worker당 목표 λ ≈ 0.5M/s,
목표 avg ≤ 20µs → worker당 in-flight ≈ 10 → **기본 W=16** (bounce pool과
동일 값으로 연동, `EXT_READ_SLOTS`가 사실상 W의 상한).

W 초과 시 post하지 않고 §2.2-1의 대기 리스트에 둔다. drain이 slot을 풀면
대기 conn부터 재개한다.

### 2.4 이벤트 루프 통합의 결정

- libevent 콜백 구조는 유지한다. drain 지점 (a)는 conn 이벤트 콜백 말미,
  (b)는 `event_base_loop` 진입 전 훅이 아니라 **0-timeout 자기 이벤트**
  (`event_active` 재무장)로 구현한다 — libevent 내부를 패치하지 않기 위한
  선택. outstanding=0이 되면 재무장을 멈춘다.
- 대안(폐기): epoll fd에 CQ completion channel을 등록하는 방식은 completion
  channel이 `ibv_req_notify_cq` + solicited event로 다시 syscall 경로가
  되므로 v2의 목적과 모순. busy-drain이 원칙이다.

### 2.5 SET/WRITE 경로 — 이번 단계에서 변경하지 않음

- staging pool, `extstore_submit`의 WRITE 절반, IO thread는 **write 전용**으로
  남긴다. `ext_threads`의 의미가 "write 전용 IO thread 수"로 바뀌고 기본 2.
- 이유: SET은 우리 실험 축에서 rare-path이고(GET-only 측정), STORED 계약이
  WRITE CQE에 동기라 worker-inline화의 이득 구조가 GET과 다르다. P4에서
  SET-heavy workload를 정의한 뒤 별도 판단한다.
- 결과적으로 server thread 구성: worker mcT개 + write IO 2개 + dispatcher
  + assoc/logger. **busy-poll 상주 코어가 8개 → 0개**가 된다 (worker의
  0-timeout 구간은 outstanding 존재 시로 한정).

### 2.6 실패·재시도 규칙 (계승 + 이관)

- GCM open 실패 재시도(≤`EXT_READ_RETRIES`)는 worker 내 재post로 이관.
- retry 큐잉이 luop 회전을 넘길 수 있으므로 재시도 중인 obj_io도 W에
  계상한다 (starvation 방지).
- engine dead 판정, badcrc 진단 로그(v1의 AAD 불일치 덤프) 경로는 그대로.

## 3. 불변식

v1 `SOURCE_CHANGE_SPEC.md` §2의 6개 불변식을 전부 계승하고, 다음을 추가한다:

1. worker 소유 QP/CQ/bounce/crypto ctx는 소유 worker 외 접근 금지.
2. CQ drain과 소켓 이벤트 처리는 같은 thread에서 교대한다 — drain 상한 32,
   drain 연속 2회 사이에 반드시 이벤트 처리 기회가 있다.
3. stub의 수명은 remote slot과 1:1이다: stub unlink 경로는 반드시 remote
   slot free를 동반하고, 그 역도 성립한다 (누수 = slot 회계 불일치로 정의).
4. span-v2 경계(READ post 직전 → CQE → sync → decrypt 완료)는 v1과 동일하게
   유지한다 — v1/v2 성능 비교의 전제.

## 4. 단계 계획과 게이트

공통 게이트 **G-base**: v1 harness(`tools/config-matrix-10s.sh` 이식본)로
기준점 `mtT=8×c16, mcT=8, pipeline=8, (v1 표기) QP/ext=8, depth=16` 1점 실행,
같은 boot의 v1 실측 대비 remote throughput ±5% 이내, miss/badcrc/RDMA
failure/engine dead = 0, `extstore_prof_read_count == cmd_get`.

| 단계 | 내용 | 예상 diff 범위 | 게이트 |
|---|---|---|---|
| **P0** | §1.1–1.3 제거 (LRU/maintainer/crawler/mover), 큐 연결 제거, 명령 에러화 | `items.c` 대폭, `crawler.c`·`slabs_mover.c` 삭제, `memcached.c`/`proto_text.c` 옵션·명령 정리 | G-base. **성능 변화를 목표로 하지 않는다** — 상주 thread 제거가 tail에 주는 효과만 부수 관찰 |
| **P1** | §1.4 단일 stub class + §1.5 knob/stats 정리 | `slabs.c`, `items.c`, `memcached.c` | G-base + `stats slabs` class 1개 + 1M preload 무결 |
| **P2** | §2 worker-inline READ 전체. IO thread를 write 전용화 | `extstore.c` (QP/CQ per-worker화, io thread READ 경로 삭제), `storage.c` (submit/return 직결), `thread.c` (drain 훅) | smoke(`genie_connect OK`) → W=1, QP=mcT=8에서 worker당 ≥0.25M/s·p99≤15µs → mcT 8–14 스윕 단조성 확인 |
| **P3** | 측정 캠페인: THREE_EXP 동일 축 재실행, v1 대비표 작성 | 코드 변경 없음 | p99<30 트랙 ≥2M/s, avg<30 트랙 ≥5.5M/s. 미달 시 §6 리스크 항목별 회귀 분석 |
| **P4** (보류) | SET inline 여부, off-box client, compaction | — | P3 결과로 별도 결정 |

각 단계는 독립 커밋(들)로 남기고, P2 전까지는 어느 단계에서든 단계 단위
revert가 가능해야 한다. v1 tree가 그대로 있으므로 build flag에 의한 이중
경로는 두지 않는다 — **A/B는 tree 단위**다.

## 5. Knob·설정 매핑

| v1 | v2 | 비고 |
|---|---|---|
| `ext_threads` = QP = busy-poll IO | `ext_write_threads` (기본 2) | READ와 무관해짐 |
| (없음) | QP 수 = `mcT` | worker당 1 QP, knob 아님 |
| `ext_io_depth` | `ext_worker_window` (기본 16) | worker당 미결 READ 상한 |
| `EXT_READ_SLOTS` (IO thread당) | 동일 이름, worker당 | window 상한과 연동 |
| `-m` = value+stub slab 총량 | `-m` = stub arena 상한 | §1.4 산정식 문서화 |
| runner `-o ext_path=…,ext_threads=$ext,ext_io_depth=$depth` | `…,ext_write_threads=2,ext_worker_window=$W` | `tools/config-matrix-10s.sh` v2판에서 축 이름 변경: qp축 → mcT축 |
| CPU split: server 16 = worker 8 + IO 8 | server 16 = worker mcT (+write 2) | mtT=8 고정 시 mcT 최대 14 실험 가능 |

## 6. 리스크와 미결정

| # | 리스크 | 판단/완화 |
|---|---|---|
| R1 | worker가 TCP+RDMA를 겸하면 소켓 처리 지연이 READ 완료 지연으로 전이 | drain 상한·교대 규칙(§2.2-6). stock이 같은 박스에서 TCP만으로 7.8M/s를 소화한 것이 여유의 실측 근거 |
| R2 | 0-timeout 재무장 구간의 CPU 소모 | outstanding 존재 시로 한정. idle 시 stock과 동일하게 잠듦. `stats`에 drain 회전수/빈 poll 비율 카운터 추가해 실측 |
| R3 | QP=mcT 확장(→14)의 자원 | v1 실측: QP 32까지 무해, 256까지 동작(THREE_EXP §1/2b). 문제 아님 |
| R4 | stub arena 상한을 remote slot 수와 어긋나게 설정하는 운영 실수 | 기동 시 `-m` < stub_max×slot 수면 경고 로그 + `stats settings`에 두 값 병기 |
| R5 | per-worker bounce/window로 인한 자원 파편화 (한 worker만 바쁜 편중 워크로드) | memcached의 conn→worker 배정이 round-robin이라 GET-only 균등 부하에서는 비문제. 편중 워크로드는 P4 과제로 명시 |
| R6 | `io_queue_t` 재사용 시 same-thread return의 재진입 | return_cb 직접 호출은 drain 루프 안에서만, conn 재개는 이벤트 재무장으로 한 단계 미뤄 재진입 깊이 1 고정 |
| R7 | P0에서 LRU 제거가 숨은 의존(예: `it->time` 갱신, flush_all)과 충돌 | flush_all은 epoch 비교로 동작 유지(LRU 불요). `t/` 테스트 skip 목록을 P0 게이트에 포함 |

## 7. v1과의 관측 가능성 계약

- span-v2 경계 불변(§3-4). 단 v2에서는 "post 이전 큐잉"(worker→IO 대기)이
  구조적으로 사라지므로, v1↔v2의 avg 차이 중 그 성분은 span 밖(worker 처리)
  으로 이동한다. 비교표에는 remote span과 memtier e2e를 항상 병기한다.
- `stats` 신규: `ext_worker_window` 현재값, worker별 drain 통계(합산),
  bounce 대기 발생 수, stub arena 사용량.
- 측정은 v1 harness의 axes를 그대로 재사용하되 §5의 knob 매핑을 적용한
  `config-matrix-10s.sh` v2판을 P2에서 함께 커밋한다.
