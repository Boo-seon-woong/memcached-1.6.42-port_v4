# Port v2 구조 안내

> **[v2 시점 기록]** 이 문서는 그 시점의 기록으로 보존한다. 현재 운영값은
> [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md), 최신 결과는
> [`V4_RESULT.md`](V4_RESULT.md) 다. 구조는 v2 시점 기준이고, v3·v4 변화는
> [`V3_ARCHITECTURE.md`](V3_ARCHITECTURE.md) 와
> [`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md) 에 있다.

기준일: 2026-07-28. 기준 commit: `f6cdffd`.

이 문서는 **v2 port가 지금 어떻게 생겼는지**를 설명한다. stock memcached
구조는 [`../ARCHITECTURE.md`](../ARCHITECTURE.md), 용어와 설정값 사전은
[`../GLOSSARY.md`](../GLOSSARY.md), 검증 결과와 판정은
[`V2_CODE_SPEC.md`](V2_CODE_SPEC.md)에 있다. 여기서는 그 사이의 빈칸 —
**자원 소유 관계와 요청이 흐르는 경로** — 만 다룬다.

---

## 1. 한 장 요약

```text
                    Ariel guest (SEV-SNP, 24 vCPU)
  ┌──────────────────────────────────────────────────────────────┐
  │  memtier ──localhost TCP──▶ memcached worker #0 ─┐           │
  │                             memcached worker #1 ─┤           │
  │                                    ...           │           │
  │                             memcached worker #N ─┤           │
  └──────────────────────────────────────────────────┼───────────┘
                                                     │ one-sided
                                        RDMA READ/WRITE (RC QP)
                                                     ▼
                              Genie: genie_memd 가 MR 하나만 제공
```

v1과의 가장 큰 차이 한 줄: **요청을 받은 worker가 그 요청의 RDMA까지 끝까지
책임진다.** 중간에 다른 thread로 넘기지 않는다.

### 지금 존재하는 thread

| thread | 개수 | 하는 일 |
|---|---|---|
| worker | `-t N` (측정 기본 12) | TCP 이벤트 처리 + RDMA post + 자기 CQ drain + decrypt |
| dispatcher | 1 | accept 후 worker에 conn 배정 (stock 그대로) |
| assoc maintenance | 1 | hash 확장 (stock 그대로) |
| logger | 1 | 로그 (stock 그대로) |

**extstore IO thread는 존재하지 않는다.** v1에서 `ext_threads` 개수만큼
떠서 busy-poll하던 그 thread들이 v2에는 아예 없다 — 코드째 삭제됐다.
LRU maintainer / crawler / slab rebalancer도 없다 (P0에서 삭제).

---

## 2. v1 → v2 변수 대응

사라진 축과 새로 생긴 축을 한 표로 본다. **가장 중요한 변화는 depth가
window로 바뀐 것**이다.

| v1 | v2 | 성격 |
|---|---|---|
| `ext_io_depth` (= QP depth) | **`ext_worker_window` (W)** + `EXT_ORD_LIMIT`(16) | **둘로 분리**. §2.2 |
| `ext_threads` (= IO thread 수 = QP 수, 1:1) | **삭제** | QP 수는 `-t × ext_qp_per_worker`로 파생. §2.1 |
| — | **`ext_qp_per_worker`** | 신규. worker당 QP 개수 (1..4, 기본 1) |
| — | **`ext_drain_spin`** | 신규. batch 처리 후 CQ를 몇 번까지 더 훑을지 (기본 1024) |
| (하드코딩 16) | **`ext_ord_limit`** | 신규. 기본 0 = CM 협상값 채택 |
| (하드코딩 32) | **`ext_batch`** | 신규. post/drain 한 번의 WR·CQE 묶음 크기 |
| `-t N` (worker 수) | `-t N` — **의미가 늘었다** | 기존 knob이지만 이제 QP 수·RDMA 병렬도·bounce/staging 파티션 수까지 결정한다 |
| IO thread별 bounce pool | worker별 bounce/staging 파티션 | 소유자만 바뀜 |
| global staging + mutex/cond | worker별 staging 파티션, lock 없음 | 삭제 |

`ext_threads`와 `ext_io_depth`는 파싱조차 하지 않는다. 실행 명령이나 결과
CSV에 이 축을 되살리지 않는다.

### 2.1 QP 수는 어디로 갔나

v1의 `ext_threads`는 **한 숫자가 세 가지를 동시에** 뜻했다 — QP 수, IO
thread 수, busy-poll이 태우는 CPU. `genie_connect()`가 `io_threadcount`번
루프를 돌며 IO thread마다 QP를 정확히 하나씩 열었기 때문이다
(v1 `extstore.c:249`).

v2는 이 결합을 끊었다. IO thread라는 항목이 아예 없어졌고, **QP 수를 직접
지정하는 knob도 없다.** 파생될 뿐이다:

```text
v1:  QP 수 = ext_threads              (= IO thread 수, 1:1)
v2:  QP 수 = -t × ext_qp_per_worker   (worker 수에서 파생)
```

### 2.2 depth는 둘로 쪼개졌다

`ext_io_depth`는 하나의 knob이 아니라 **두 개의 서로 다른 상한**으로
분리됐다. 둘 다 `worker_post()`의 같은 조건식에 나란히 있다
(`extstore.c:596-598`).

| v1 `ext_io_depth`의 역할 | v2 대응 | 걸리는 단위 | 코드 |
|---|---|---|---|
| 미완료 개수 소프트 상한 | `ext_worker_window` (W) | **worker** | `w->outstanding < w->window` |
| (암묵적) wire 동시성 한계 | `ext_ord_limit` (기본 = 협상값) | **QP** | `w->read_out[qi] < w->ord_limit` |

왜 쪼개졌나: v1은 IO thread ↔ QP가 1:1이라 "thread당 depth"와 "QP당 depth"가
같은 말이었다. v2는 worker 하나가 QP를 여러 개 가질 수 있어(CQ는 공유) 그 두
층이 분리됐고, 각자 다른 상한을 받는다.

**ORD는 v1에도 있었다** — 코드가 추적하지 않아 보이지 않았을 뿐이다. v2 초기에는
16으로 하드코딩돼 있었으나 지금은 CM 협상값을 채택한다(이 HCA에서 실측 16).
v1에서 `depth=64`를 줘도 wire에 나가는 READ는 16개가 한계였고 나머지는 SQ에서
대기했다. depth를 16 너머로 올려도 throughput이 늘지 않던 v1 실측이 정확히
이것이다. v2는 `read_out[]`으로 이를 명시 추적해 초과 post를 하지 않는다.

실제 숫자:

```text
v1 최적점:  ext_threads=8, ext_io_depth=16
            → QP 8, IO thread 8, 총 in-flight 8 × 16 = 128

v2 운영점:  -t 12, ext_qp_per_worker=1, ext_worker_window=16
            → QP 12, IO thread 0, 총 in-flight 12 × 16 = 192
```

`ext_qp_per_worker=1`인 지금은 worker당 QP가 1개라 W와 ORD가 같은 대상에
걸려 **v1 depth와 사실상 같은 의미**다. 2 이상으로 올리는 순간 갈라진다 —
W는 worker 전체 예산이 되고, QP별로는 여전히 16이 각각 걸린다.

### 2.3 상한 전체

CPU 결합이 끊긴 것도 함께 보면, v1은 "큐를 깊게 하려면 busy-poll thread를
늘려야" 했고 v2는 CPU를 더 쓰지 않고 W만 조절할 수 있다. 동시에 유효한
상한은 다음과 같다:

```text
worker 총 outstanding      <= W
worker READ outstanding    <= bounce slot 수 (EXT_READ_SLOTS, 상한 없음)
QP 하나의 wire READ        <= 16
worker 전체 wire READ      <= 16 × ext_qp_per_worker
```

즉 **QP가 1개면 W를 ORD 너머로 키워도 wire 병렬도는 안 늘어난다** — 초과분은
SQ에서 기다릴 뿐이다. `W>ORD` 실험은 `ext_qp_per_worker`를 함께 올릴 때만
의미가 있다. 기본값 W=16은 이 HCA의 ORD 경계에 맞춘 값이다.

**W를 키우려면 `EXT_READ_SLOTS`도 같이 키워야 한다.** bounce slot이 없으면
post가 멈추므로, slot이 64인 채 W만 128로 올리면 실제 READ 동시성은 64에
묶인다. 실측으로도 W=128에서 slot 64 → avg 43.8µs, slot 128 → avg 86.4µs로
그때서야 in-flight가 실제로 두 배가 된다.

**이 축들에는 상한이 없다.** 성능이 나쁜 설정도 유효한 측정 결과이므로 엔진이
대신 거부하지 않는다. 검사하는 것은 동작에 필요한 하한(>=1)뿐이고, 자원 배열과
slot bitmap은 설정값에 맞춰 동적으로 잡힌다.

---

## 3. worker가 소유하는 것

`store_worker` (`extstore.c:120`). 이 구조체의 모든 필드는 **소유 worker만**
건드린다 — hot path에 lock이 없는 이유다.

| 필드 | 내용 |
|---|---|
| `qp[EXT_QP_MAX]`, `nqp`, `rr` | 자기 QP들과 round-robin 커서 |
| `cq` | **QP 여러 개가 공유하는 CQ 1개**. 완료는 `wr_id`의 `obj_io` 포인터로 식별하므로 어느 QP에서 왔는지 몰라도 된다 |
| `read_out[]` | QP별 미완료 READ (ORD 16 준수용) |
| `outstanding`, `window` | worker 총 미완료와 그 상한(W) |
| `bounce_base` / `bounce_free` | READ가 착지하는 DMA 버퍼와 64비트 free bitmap |
| `staging_base` / `staging_free` | seal된 WRITE 원본 버퍼와 bitmap |
| `wait_head/tail` | window·ORD·slot이 부족해 대기 중인 op FIFO |
| `prof_r_*`, `prof_w_*` | span-v2 히스토그램 (읽을 때만 합산) |

engine(`store_engine`)에 남은 공유 자원은 **remote slot allocator, page
테이블, stats** 뿐이고 각각 자기 mutex로 보호된다. GET hot path는 여기를
지나가지 않는다.

QP 연결은 main thread가 conn을 받기 전에 순차적으로 끝낸다
(`extstore_workers_prepare` → `extstore_worker_create` → `cm_connect_worker_qp`,
`extstore.c:491/570/413`, 호출은 `thread.c:873`).

---

## 4. GET이 흐르는 길

```text
worker: TCP 요청 파싱
  → hash에서 stub(ITEM_HDR) 찾음                     items.c
  → storage_get_item(): iop 만들고 io_queue에 넣음    storage.c:369
  → storage_submit_cb(): iop 체인 → obj_io 체인       storage.c:476
  → extstore_worker_submit() → worker_post()          extstore.c:711 / 578
       · bounce slot 확보, QP 선택(ORD 여유 있는 것)
       · ibv_post_send (RDMA READ)
       · 자리가 없으면 wait list에 park
  → 이벤트 루프로 즉시 복귀 (conn은 io-pending 상태)

  ... RDMA 왕복 ...

  → extstore_worker_drain(): ibv_poll_cq (최대 32)    extstore.c:730
       · SYNC_FOR_CPU (batch)
       · _storage_get_item_cb(): decrypt + 검증       storage.c:224
       · 완료된 iop는 큐에 park만 해둠
  → storage_flush_returns(): conn 재개                storage.c:904
  → 응답 전송
```

v1과 비교하면 두 번의 thread 경계 횡단이 사라졌다:

```text
v1:  worker ──[mutex+cond 제출]──▶ IO thread ──[eventfd+epoll 복귀]──▶ worker
v2:  worker ────────────── 전부 자기가 ──────────────▶ worker
```

**decrypt는 이제 worker에서 일어난다** (v1은 IO thread). 완료 처리를
drain 루프 안에서 곧바로 conn 재개까지 하면 이벤트 루프에 재진입하게 되므로,
완료된 iop는 일단 park하고 **drain 루프가 끝난 뒤** `storage_flush_returns()`
가 재개한다. 재진입 깊이를 1로 고정하는 장치다.

### drain은 두 군데서 돈다

| 지점 | 위치 | 역할 |
|---|---|---|
| (a) batch 직후 | `thread.c:515-522` | 소켓 이벤트 한 묶음 처리 후 최대 `ext_drain_spin`회 CQ를 훑는다. RTT가 ~3µs라 대부분 여기서 수거된다 |
| (b) 0-timeout self event | `thread.c:853` (`ext_drain_handler`) | (a)에서 못 비운 잔여분. outstanding이 남아 있는 동안만 자신을 재무장하고, 0이 되면 잠든다 |

`ext_drain_spin`이 tail latency를 지배한다 — 8이면 완료가 이벤트 루프 회전을
기다려 p99가 무너지고(325µs), 1024면 in-line으로 수거되어 33µs로 떨어진다.
1024에서 포화하며 4096은 이득이 없어 기본값이 1024다.

---

## 5. SET이 흐르는 길

`storage_store_item()` (`storage.c:554`). GET과 달리 **동기**다 —
`STORED`는 WRITE CQE를 확인한 뒤에만 나간다(v1 계약 그대로).

```text
worker: remote slot 할당 (engine allocator, SET 전용 lock)
  → 자기 staging slot 확보                      extstore_worker_staging_get (656)
  → ext_crypto_seal (worker TLS ctx)
  → window 여유 없으면 자기 CQ를 drain하며 대기   storage.c:636
  → SYNC_FOR_DEVICE 후 ibv_post_send (WRITE)     extstore_worker_post_write (672)
  → 자기 CQ를 spin-drain 하며 이 WRITE의 CQE 대기
  → stub publish → STORED
```

바뀐 건 대기 방식뿐이다: v1은 `pthread_cond_wait`으로 IO thread를 기다렸고,
v2는 자기 CQ를 직접 돈다. spin 도중 함께 수거되는 GET 완료는 §4처럼 park만
되므로 재진입이 없다. WRITE는 ORD 제한을 받지 않지만 window에는 계상된다.

---

## 6. 삭제된 것과 그 귀결

| 삭제 | 귀결 |
|---|---|
| extstore IO thread 전부 | thread 경계 횡단 2회(요청당 syscall 2회)가 사라짐 |
| segmented LRU + maintainer | local에 evict할 value가 없음. TTL은 접근 시 lazy 판정 |
| LRU crawler | 순회할 큐가 없음 |
| slab rebalancer / automove | class가 2개뿐이라 재배분이 정의되지 않음 |
| eviction 자체 | stub/remote slot 고갈 = **SET 실패**(`SERVER_ERROR`), evict 아님 |
| slab class 63개 | remote-only 모드는 2개(stub / 인바운드 transient)만 사용 |

주의할 semantics 변화 하나: **`flush_all`의 경계가 초 단위**가 됐다. stock은
LRU를 훑어 "flush와 같은 초에 저장된 item"까지 즉시 지웠는데, 훑을 큐가
없어졌기 때문이다. 지연 flush와 초 경계를 넘은 flush는 stock과 동일하게
동작한다.

---

## 7. 파일별 책임

| 파일 | v2에서의 역할 |
|---|---|
| `extstore.c/.h` | RDMA 전부: worker 자원, QP 연결, post/drain, remote slot allocator, span-v2 |
| `storage.c` | memcached item ↔ remote object 변환, crypto 호출, GET/SET 경로, 설정 파싱 |
| `ext_crypto.c` | AES-256-GCM seal/open (AAD가 hash와 remote location을 묶음) |
| `thread.c` | worker 기동, drain 두 지점, `current_worker_thread()` |
| `items.c` | stub 수명 관리 (LRU 코드는 전부 빠짐) |
| `slabs.c` | remote-only일 때 2-class 고정 |
| `memcached.c` | worker 준비 호출, 삭제된 옵션 정리 |

---

## 8. 측정 기준점

```text
mcT=12, memtier 8 threads × 16 clients, pipeline=64
ext_worker_window=16, ext_qp_per_worker=1, ext_drain_spin=1024
EXT_SLOT_SIZE=256, EXT_READ_SLOTS=64, crypto ON
```

이 지점의 실측(3회 중앙값)은 5,797,294.4 GET/s, span avg 13.951µs,
p99 31.6µs, server CPU 1.943µs/op이며 correctness counter는 전부 0이다.
수치의 근거와 raw artifact 위치는 [`V2_CODE_SPEC.md`](V2_CODE_SPEC.md)와
[`V2_REMODIFICATION_SPEC.md`](V2_REMODIFICATION_SPEC.md)에 있다.
