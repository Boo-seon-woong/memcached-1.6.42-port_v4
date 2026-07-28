# 용어와 변수 정의

이 port의 모든 문서는 여기서 정의한 이름만 쓴다. 값이 아니라 **의미**를 고정하는
문서이므로 측정값은 넣지 않는다. 코드 근거는 `file:line`으로 표시한다.

## 0. 배치

```text
memtier_benchmark (client)              memcached port (server)              genie_memd (remote)
                                                                             1 process, 1 big MR
 mtT threads                            mcT worker threads                   READ/WRITE 대상만 제공
   x clients TCP connections   --TCP-->    | GET: io_pending을 자기 QP에 push  (passive: CPU 안 씀)
   x pipeline outstanding req             | SET: WRITE CQE까지 여기서 block
                                          v
                                   ext_threads 개의 IO thread
                                   = ext_threads 개의 RC QP     --RDMA-->  MR
                                   QP당 depth 개까지 outstanding WR
```

한 문장으로: **client의 `pipeline`은 부하를 만들고, server의 `mcT`는 그 부하를
파싱하며, `ext_threads`(=QP)와 `depth`는 그 부하가 fabric에 얼마나 병렬로 나가는지를
정한다.**

---

## 1. Client 축 — memtier_benchmark

| 이름 | flag | 정의 |
|---|---|---|
| `mtT` (memtier thread) | `--threads` | 부하 생성기 thread 수. runner가 CPU `24-mtT` ~ `23`에 taskset으로 고정한다. |
| `clients` (clients/thread) | `--clients` | memtier thread 하나가 여는 TCP connection 수. runner 고정값 **16**. |
| connections | 유도값 | `mtT × clients`. 표준 shape에서 `8 × 16 = 128`. |
| **`pipeline`** | `--pipeline` | **TCP connection 하나가 응답을 기다리지 않고 동시에 띄워 두는 request 수.** server 설정이 아니라 client가 만드는 offered concurrency다. |
| offered concurrency | 유도값 | `mtT × clients × pipeline`. `8 × 16 × 8 = 1024`개의 in-flight GET. |
| value size | `-d 64` | value 64 B. key는 `m-<n>`. |
| key space | `--key-minimum/--key-maximum` | `1 .. 1,000,000`. |
| ratio | `--ratio` | `SET:GET`. preload은 `1:0`, 측정은 `0:1`(GET-only). |
| key pattern | `--key-pattern` | preload `P:P`(순차), 측정 `R:R`(무작위). |

`pipeline`은 throughput과 latency를 동시에 움직이는 유일한 client 변수다. 올리면
completed GET/s는 오르지만 server QP queue에 대기가 쌓여 remote span도 같이 는다.
`clients`를 올리는 것과 다르다. `clients`는 connection과 worker 부하를 늘리고,
`pipeline`은 connection당 미해결 요청 깊이를 늘린다.

SET에는 `pipeline`이 효과가 없다. SET은 worker thread에서 RDMA WRITE CQE까지
block하므로(§2) 동시 SET 수는 `mcT`와 staging slot 수로 제한된다.

---

## 2. Server 축 — memcached

| 이름 | flag | 정의 |
|---|---|---|
| **`mcT`** (worker thread) | `-t N` | memcached worker thread 수. thread마다 `event_base` 하나를 갖고 배정된 connection의 socket I/O·파싱·hash/LRU 조회를 전담한다. |
| `-R 1024` | `--max-reqs-per-event` | event loop 한 번에 한 connection에서 처리할 최대 request 수. pipeline이 깊을 때 한 connection이 worker를 독점하지 않게 한다. |
| `-m 2048` | | slab item memory, MB. **remote 용량과 무관하다.** storage가 켜지면 hash에는 `ITEM_HDR` stub만 남으므로 이 메모리는 stub과 key만 담는다. |
| `-c 8192` | | 최대 connection 수. |
| `-U 0` | | UDP off. extstore와 함께 쓸 수 없다 (`storage_check_config`, `storage.c:775`). |

worker thread 하나가 GET에서 하는 일:

1. TCP read → parse → `assoc_find`로 `ITEM_HDR` stub 획득
2. `storage_get_item()` (`storage.c:349`) — plaintext 목적지 slot 확보,
   `io_pending_storage_t` 구성, worker의 `IO_QUEUE_EXTSTORE` stack에 push
3. `storage_submit_cb()` (`storage.c:456`) — stack을 `obj_io` chain으로 바꿔
   `extstore_submit()` 한 번 호출
4. IO thread가 완료시키면 worker로 돌아와 response 전송, 그 뒤
   `storage_finalize_cb()`에서 slot 반환

SET은 다르다. `storage_store_item()` (`storage.c:530`)이 seal → submit →
**condvar에서 WRITE CQE를 기다리며 worker thread를 block한다.** 성공한 뒤에야
`do_item_link()`/`item_replace()`로 stub을 publish하고 `STORED`를 반환한다.

### 서버 프로세스의 thread 전체

| 종류 | 개수 | 비고 |
|---|---|---|
| main / dispatcher | 1 | listen + accept + clock |
| worker | `mcT` | 위 참조 |
| extstore IO | `ext_threads` | §3 |
| background | 약 5 | LRU maintainer, LRU crawler, slab rebalancer, assoc maintenance, logger |

민감도 문서의 `mt+mc+ext` 합계는 **CPU를 실제로 태우는 세 종류만** 센 값이다.
background thread와 dispatcher는 idle에 가까워 제외한다. stock에 있던
storage write thread와 compaction thread는 이 port에서 삭제됐다
(`memcached.c` diff, `thread.c` diff).

---

## 3. RDMA engine 축 — extstore

| 이름 | 설정 | 정의 |
|---|---|---|
| **`ext_threads`** | `-o ext_threads=N` | extstore IO thread 수. |
| **QP** | 유도값 | **`ext_threads`와 같은 값이다.** IO thread 하나가 `rdma_cm` connection 하나, RC QP 하나, CQ 하나, read-bounce slice 하나를 소유한다 (`cm_connect_one`, `extstore.c:202`). QP만 따로 늘리거나 줄일 수 없다. |
| **`depth`** = `ext_io_depth` | `-o ext_io_depth=N` | **QP 하나가 post한 채로 유지할 수 있는 WR 수 상한.** posting loop 조건이 `t->outstanding + n < depth`다 (`extstore.c:271`). 같은 값이 CQ 크기(`depth × 2`)와 `max_send_wr`(`depth + 1`)도 정한다. process 전체 상한이 아니라 **QP당** 상한이다. |
| posting round | `EXT_WRITE_BATCH` | 한 loop iteration에서 linked WR chain으로 한 번에 post하는 WR 수 상한. 1..32, 기본 32. `wrs[32]` 배열 크기가 하드 상한이다. |
| CQ poll batch | 코드 상수 32 | `ibv_poll_cq(t->cq, 32, wc)` (`extstore.c:364`). |
| **bounce slot** | `EXT_READ_SLOTS` | IO thread 하나가 가진 RDMA READ 목적지 슬롯 수. free 상태를 `uint64_t bounce_free` bitmask로 관리하므로 **64로 clamp**된다 (`extstore.c:528`). 따라서 QP당 READ in-flight 상한은 실제로는 `min(depth, read_slots)`다. |
| **staging slot** | `EXT_WRITE_SLOTS` | process 전체가 공유하는 RDMA WRITE source 슬롯 수(기본 256). 고갈되면 SET이 `staging_cond`에서 대기한다. local fallback은 없다 (`extstore_staging_get`, `extstore.c:704`). |
| **`slot_size`** | `EXT_SLOT_SIZE` | 슬롯 1개의 byte 크기. 세 가지를 동시에 정한다: ① bounce/staging 슬롯 크기, ② **remote object 최대 크기**(`extstore_alloc`이 `len > slot_size`면 -1, `extstore.c:628`), ③ worker plaintext cache slot 크기(`g_plaintext_slot_size`). |
| page | `-o ext_page_size=MiB` | remote MR을 자르는 단위(기본 64 MiB). `page_count = genie가 보고한 MR 크기 / page_size`. |
| bucket | 코드 상수 1 | remote size-class 수(`PAGE_BUCKET_COUNT`). 고정 workload용으로 1이다. |
| publication | 코드 성질 | **1 GET = RDMA READ 1회, 1 SET = RDMA WRITE 1회.** 여러 request를 한 transfer로 합치지 않는다. 따라서 `extstore_prof_read_count == cmd_get`이 성립해야 한다. |

### "depth"라는 이름이 세 개다

| 이름 | 출처 | 현재 값 | 무엇을 제한하나 |
|---|---|---|---|
| send queue depth (`cap.max_send_wr`) | verbs 표준 | `ext_io_depth + 1` | QP가 담을 수 있는 WQE 수 (자원 크기) |
| ORD / IRD (`initiator_depth` / `responder_resources`) | IB 표준 | **16 하드코딩** (`extstore.c:227`) | RC connection이 동시에 띄울 수 있는 **RDMA READ** 수 |
| `ext_io_depth` | 이 port의 소프트웨어 gate | 설정값 | IO thread가 post해 두는 미완료 WR 수 |

셋은 독립이다. 특히 **ORD가 16으로 고정돼 있으므로 `ext_io_depth > 16`은 wire
상의 동시 READ를 늘리지 못한다.** 초과분은 HCA 안에서 read credit을 기다리고,
GET span 시계는 post에서 시작하므로 그 대기가 latency로 계상된다.
2026-07-24 depth 스윕에서 32/64/128의 post→CQE가 모두 15.7µs로 평평하고
throughput 이득이 0인 것이 이와 일치한다. HCA의 `max_qp_rd_atom`이 16임은
채널 로그(`conversation.md`, "rd_atom was 16=16")에서 확인됐다. 확인 명령은
guest에서 `ibv_devinfo -v | grep -i rd_atom`이다.

`ext_io_depth`라는 **옵션 이름은 stock 1.6.42에서 물려받았지만 의미가 다르다.**
stock에서는 IO thread가 큐에서 한 번에 떼어오는 **배치 크기**였고(기본 1,
`extstore.c` 큐 분리 루프), 그 배치를 순차 `pread`/`pwrite`했다. 이 port에서는
배치 크기가 아니라 **동시 미완료 상한**이다. 배치 크기는 별도로
`EXT_WRITE_BATCH`가 상한만 정하고 실제 크기는 부하에 따라 정해진다.

### worker → QP affinity

`extstore_submit()` (`extstore.c:682`)은 `_Thread_local g_submit_io_idx`를 쓴다.
thread가 **처음** submit할 때 전역 round-robin으로 QP 하나를 고르고, 그 뒤로는
계속 같은 QP만 쓴다. 결과:

- worker 수 > QP 수: 여러 worker가 한 QP queue mutex를 공유한다.
- worker 수 < QP 수: 남는 QP는 IO thread가 condvar에서 자며 놀게 된다.
- IO thread가 GCM 실패로 재제출할 때도 같은 규칙을 쓰므로, 재시도는 그 IO thread가
  처음 고른 QP로 간다.

### IO thread 한 바퀴

`extstore_io_thread()` (`extstore.c:257`):

1. queue와 outstanding이 모두 비면 condvar에서 대기 (idle일 때만 잠든다)
2. `depth`와 `EXT_WRITE_BATCH`와 bounce slot 여유까지 지켜 최대 32개 WR을 chain으로 구성
3. WRITE가 있으면 `SYNC_FOR_DEVICE` advise 1회 → `ibv_post_send` 1회
4. `ibv_poll_cq` 최대 32개 → READ 성공분에 `SYNC_FOR_CPU` advise 1회
5. CQE마다 `io->cb` 호출(READ면 여기서 AES-GCM open), bounce slot 반환
6. CQE가 없고 outstanding이 있으면 `sched_yield()` — 즉 **부하 중에는 busy-poll**

post 실패나 error CQE는 engine을 `dead`로 만들고 이후 모든 요청을 fail-fast한다.
자동 reconnect는 없다.

### `ext_path`의 size 필드

`ext_path=host:port:size`의 `size`는 0 여부만 검사한다
(`storage_check_config`). 실제 remote 용량은 genie가 첫 connection의
`private_data`로 넘겨주는 MR 크기이며, `page_count`는 그 값으로 계산된다
(`extstore.c:584`). `ext_path`의 숫자를 바꿔도 remote 용량은 바뀌지 않는다.

---

## 4. 환경변수

| 변수 | 코드 기본값 | 측정 실행값 | 의미 |
|---|---:|---:|---|
| `EXT_CRYPTO_KEY` | 없음(필수) | `$REPO/ext.key` | 32 byte AES-256 key 파일. 없거나 32 byte를 못 읽으면 storage init 실패. |
| `EXT_SLOT_SIZE` | 2048 | **256** | §3의 slot_size. |
| `EXT_READ_SLOTS` | 32 (max 64) | **64** | IO thread당 bounce slot. |
| `EXT_WRITE_SLOTS` | 256 | 기본값 | process 전체 staging slot. |
| `EXT_READ_RETRIES` | 3 | 기본값 | GCM open 실패 시 같은 remote location을 다시 읽는 횟수. |
| `EXT_WRITE_BATCH` | 32 | 기본값 | posting round 상한, 1..32. **이름과 달리 READ posting에도 적용된다.** |
| `EXT_RDMA_PROF` | off | **1** | span v2 profile 수집. off면 모든 `prof_*` stat이 0이다. |
| `EXT_SELFTEST` | off | off | 기동 시 remote에 WRITE→READ 왕복 검증. 실패하면 init 실패. |
| `EXT_TRACE_SEAL` | off | off | nonce counter로 색인한 seal 기록 표. badcrc 진단용. |

---

## 5. 보안 / crypto

- remote object 배치: `[nonce 12B][ciphertext][GCM tag 16B]`. overhead 28 B
  (`EXT_CRYPTO_OVERHEAD`).
- nonce = `boot_salt(4B) || 전역 단조 counter(8B)`. object와 함께 저장하므로
  reader가 재계산하지 않는다.
- AAD = `{ hash(key), page_id, pad, offset, page_version }` (`struct ext_aad`).
  논리적 정체(key)와 물리적 슬롯(page/offset/version)을 함께 묶으므로, 다른 key가
  재사용한 슬롯을 잘못 읽으면 tag가 실패한다.
- `EVP_CIPHER_CTX`는 seal용/open용 각각 thread-local로 재사용한다. 실패하면 그
  context를 즉시 폐기해 실패 상태가 다음 operation으로 새지 않는다.
- **fail-closed**: tag가 맞지 않으면 검증되지 않은 plaintext를 절대 반환하지 않는다.
  `EXT_READ_RETRIES`를 소진하면 miss로 처리하되 stub은 unlink하지 않아 다음 GET에서
  회복할 수 있게 둔다.

---

## 6. 측정 지표

### span v2 — server 내부 wall-clock

`EXT_RDMA_PROF=1`일 때만 채워진다. `stats`에 `extstore_prof_span_ver=2`로 표시된다.

| 방향 | total span 경계 | 포함 | 미포함 |
|---|---|---|---|
| **GET** | RDMA READ post 직전 → CQE reap → `SYNC_FOR_CPU` → AES-GCM open 완료 | 앞선 WQE 뒤에서 기다린 시간, CQE batch 안에서 자기 decrypt 순서를 기다린 시간 | worker→IO enqueue 대기, decrypt 후 worker notify와 TCP 응답 |
| **SET** | AES-GCM seal 시작 → `SYNC_FOR_DEVICE` → WRITE CQE reap | **worker→IO enqueue 대기**, seal 시간 | `STORED` 응답 전송 |

**두 방향의 시작점이 비대칭이다.** GET은 IO thread가 post 직전에 찍고, SET은 worker가
seal 직전에 찍는다. 따라서 SET span은 enqueue 대기를 포함하고 GET span은 포함하지
않는다. 두 값을 같은 축으로 비교하지 않는다.

### breakout과 잔차

| stat | 의미 |
|---|---|
| `..._xfer_avg_ns` | GET: post → CQE reap. SET: post-sync → CQE reap. |
| `..._sync_avg_ns` | 그 batch의 `ibv_advise_mr` 1회에 든 시간(batch 전체 값을 batch 안 각 op에 동일 계상). |
| `..._crypto_avg_ns` | GET: `ext_crypto_open`. SET: `ext_crypto_seal`. |

`xfer + sync + crypto < total`이 정상이다. 차액은 **CQE batch 안에서 자기 callback
차례를 기다린 시간**이다. 한 번의 poll이 최대 32개 CQE를 가져오고 callback을 순차
실행하므로, batch가 클수록 이 잔차가 커진다. 잔차를 fabric 지연으로 읽지 않는다.

histogram은 100 ns bucket × 32,768개이며 3.2767 ms 이상은 마지막 bucket으로 clamp한다.
`stats reset`이 histogram과 sum도 함께 초기화한다(`stats_reset` → `storage_prof_reset`).

### throughput

| 대상 | 정의 |
|---|---|
| Port headline | `extstore_prof_read_count / 측정초`. 같은 구간 `cmd_get`과 **반드시 일치**해야 한다(publication=1). |
| stock headline | `cmd_get / 측정초`. |
| memtier `Ops/sec` | 보조값. offered load와 client 포화를 보는 용도이며 Port headline이 아니다. |

### correctness gate

채택하는 모든 point에서 다음이 전부 0이어야 한다.

```text
get_misses
badcrc_from_extstore          (CRC32C가 아니라 AES-GCM tag 실패다)
extstore_read_failures
extstore_write_failures
extstore_engine_dead
extstore_plaintext_slab_fallback
```

---

## 7. 실행 환경 필수 조건

| 항목 | 조건 |
|---|---|
| guest | SEV-SNP, 24 vCPU, 48 GB configured RAM |
| CPU 배치 | server `0 .. 23-mtT`, memtier `24-mtT .. 23`. 표준 shape은 server 0–15, client 16–23. |
| DMA 버퍼 | bounce/staging pool은 `/dev/snp_shared` mmap. NIC이 SEV guest의 private memory에 DMA할 수 없기 때문이다. 없으면 anonymous mmap으로 fallback(비TEE 전용). |
| libibverbs | **patched covlib 필수** — `LD_LIBRARY_PATH=$HOME/covlib`. `SYNC_FOR_CPU`/`SYNC_FOR_DEVICE` advise가 여기에 있다. |
| verbs 모드 | **`MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1` 필수.** 없으면 `rdma_cm`이 hang한다. |
| remote | `genie_memd <port> <size> [--prefill]`. passive이며 client의 one-sided READ/WRITE만 받는다. `--prefill`은 MR을 `0xAA`로 채워 "WRITE가 도착하지 않음"과 "WRITE가 0을 싣고 도착함"을 구분하게 한다. |

---

## 8. 이름 때문에 틀리기 쉬운 것

| 오해 | 실제 |
|---|---|
| QP 수와 IO thread 수는 따로 조절한다 | 같은 knob이다. `ext_threads` 하나뿐이다. |
| `depth`는 process 전체 상한이다 | QP당 상한이다. 전체 상한은 `ext_threads × depth`. |
| `EXT_WRITE_BATCH`는 WRITE 전용이다 | 같은 posting loop를 쓰므로 READ도 제한한다. |
| `EXT_READ_SLOTS`를 128로 올릴 수 있다 | bitmask가 `uint64_t`라 64로 clamp된다. |
| `badcrc_from_extstore`는 CRC32C 실패다 | AES-GCM tag 실패다. CRC32C 경로는 제거됐다. |
| `-m 2048`이 remote 저장 용량이다 | stub과 key만 담는 local slab 크기다. |
| `ext_path`의 size가 remote 용량이다 | genie가 보고한 MR 크기가 용량이다. |
| memtier의 `Ops/sec`가 Port 성능이다 | Port headline은 `extstore_prof_read_count`다. |
| stock latency와 Port latency를 비교할 수 있다 | stock은 client end-to-end, Port는 server 내부 span이다. throughput만 비교 가능하다. |
