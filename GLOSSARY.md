# Port v2 용어와 실행 변수

기준일: 2026-07-28

## 구조 용어

| 용어 | v2 의미 |
|---|---|
| worker / `mcT` | memcached TCP event loop와 RDMA post/drain을 함께 수행하는 thread. `-t N`. |
| QP | RC Queue Pair. 기본은 worker당 1개이며 총 QP=`mcT × ext_qp_per_worker`. |
| CQ | worker 하나의 모든 QP가 공유하는 completion queue. 소유 worker만 poll한다. |
| window / `W` | worker당 미완료 READ+WRITE 상한. `ext_worker_window`, 기본 16. |
| ORD | QP당 wire상의 RDMA READ 상한. 기본은 CM 협상값(이 HCA에서 16). `ext_ord_limit`으로 고정 가능하며, 협상값보다 크게 잡으면 초과분은 SQ에 쌓인다. WRITE에는 적용되지 않는다. |
| pipeline | memtier connection당 outstanding request 수. RDMA batching이나 server `-R`이 아니다. |
| `-R` | memcached가 한 socket event에서 처리하는 request 수 상한. |
| bounce slot | RDMA READ가 도착하는 worker-private DMA buffer. `EXT_READ_SLOTS`, 최대 64. |
| staging slot | seal된 RDMA WRITE source를 담는 worker-private DMA buffer. |
| remote slot | Genie MR 안의 한 sealed object location. `page_id/version/offset/len`으로 식별한다. |
| stub | local hash에 남는 `ITEM_HDR`. value는 포함하지 않는다. |
| transient item | SET 입력 또는 GET decrypt 목적지로 잠시 쓰는 local item. hash에 publish하지 않는다. |

삭제된 v1 용어: `ext_threads`, `ext_io_depth`, extstore IO thread,
global staging condvar. v2 명령이나 결과 CSV에 이 축을 다시 넣지 않는다.
`ext_io_depth`가 왜 `ext_worker_window`로 대체됐는지와 요청이 흐르는 경로는
[`md/V2_ARCHITECTURE.md`](md/V2_ARCHITECTURE.md)에 있다.

## 배치 topology

```text
Ariel guest: memtier -> localhost TCP -> memcached worker
                                         |
                                         +-> RDMA -> Genie genie_memd MR
```

load generator와 memcached worker는 Ariel에 있고 Genie는 remote MR만
제공한다. Genie의 `genie_memd` process를 memtier 실행 대상으로 해석하거나
Genie에서 memtier를 실행한 결과를 canonical v2 run으로 취급하지 않는다.

## 설정

| 이름 | 기본값 | 범위/설명 |
|---|---:|---|
| `-t` | upstream 기본 4 | worker 수 |
| `ext_worker_window` | 16 | >= 1, 상한 없음 |
| `ext_qp_per_worker` | 1 | >= 1, 상한 없음 |
| `ext_drain_spin` | 1024 | >= 0, 상한 없음 |
| `ext_ord_limit` | 0 | 0 = CM 협상값 채택. 값을 주면 그대로 사용 |
| `ext_batch` | 32 | >= 1. post/drain 한 번의 WR·CQE 묶음 크기 |
| `EXT_SLOT_SIZE` | 256 B | slabs와 RDMA engine이 공유하는 sealed-object 한도 |
| `EXT_READ_SLOTS` | 32 | worker당 bounce slot 수. 상한 없음 — W>64를 실질적으로 쓰려면 이 값도 함께 올려야 한다 |
| `EXT_WRITE_SLOTS` | 256 | process 예산을 worker 수로 나눔 |
| `EXT_READ_RETRIES` | 3 | GCM tag 실패 시 visibility retry |
| `EXT_CRYPTO_KEY` | 필수 | 정확히 32 B key file |
| `EXT_SELFTEST` | off | 1이면 serving 전 WRITE/READ payload self-test |
| `EXT_RDMA_PROF` | off | 1이면 span-v2 histogram/stage stats |
| `MLX5_COHERENT_QP/CQ` | 환경 의존 | patched SEV-SNP verbs 경로 선택 |

`EXT_SLOT_SIZE`는 remote ciphertext 전체의 상한이다. crypto ON이면 nonce/tag 등
`EXT_CRYPTO_OVERHEAD`도 이 안에 포함된다. slabs와 storage 기본값이 다르면
SET admission과 remote allocation이 서로 다른 객체를 허용하므로 반드시 같은
상수를 사용한다.

## 동시성 관계

```text
worker 총 outstanding <= W
worker READ outstanding <= bounce slots (EXT_READ_SLOTS)
QP별 wire READ <= ORD(16)
worker 총 wire READ <= 16 × QP/worker
offered client requests ≈ memtier_threads × clients × pipeline
```

`W>ORD`는 QP가 1개면 wire READ 병렬도를 그 이상 늘리지 못한다.
`ext_qp_per_worker>1`은 W도 함께 키운 실험에서만 의미가 있다.

v2는 이 축들에 상한을 두지 않는다. 성능이 나쁜 설정도 유효한 측정 결과이므로
엔진이 대신 판단하지 않으며, 동작에 필요한 하한(>=1)만 검사한다.

## 데이터와 보안 계약

SET은 `ext_crypto_seal` 후 RDMA WRITE를 post한다. AAD는 hash와 remote
location을 묶는다. WRITE CQE 전에는 stub을 publish하거나 `STORED`를 보내지
않는다.

GET은 remote slot을 bounce로 READ한 뒤 `SYNC_FOR_CPU`와
`ext_crypto_open`을 수행한다. tag 검증 실패 payload는 반환하지 않는다.
remote value의 plaintext local fallback은 없다.

## 시간과 처리량

- memtier latency: client end-to-end, 출력 단위 ms. 보고 시 µs로 ×1000.
- span-v2 READ: RDMA post 직전 → CQE → sync → decrypt 완료, stats 단위 ns.
- span-v2 WRITE: seal 시작 → sync → RDMA WRITE CQE, stats 단위 ns.
- canonical throughput: 측정 구간 `cmd_get / seconds` 또는
  `extstore_prof_read_count / seconds`; 두 count가 같아야 한다.

날짜가 다른 run의 절대값은 직접 비교하지 않는다. 동일 binary, topology,
workload, run 안의 상대값만 순위화한다.

## 필수 correctness counters

정상 GET-only run:

```text
get_misses=0
badcrc_from_extstore=0
extstore_read_failures=0
extstore_write_failures=0
extstore_engine_dead=0
ext_slot_acct_leak=0
extstore_prof_read_count=cmd_get
```

backpressure/CPU 해석에는 `ext_worker_drain_calls`,
`ext_worker_drain_empty`, `ext_worker_wait_enq`,
`ext_worker_write_spins`도 함께 기록한다.

## Readiness와 raw artifact

Genie의 TCP port open만으로 RDMA 준비를 판정하지 않는다. memcached server
log에 `genie_connect OK`가 worker/QP 설정과 함께 나타난 뒤 preload를 시작한다.
`EXT_SELFTEST=1`이면 `extstore selftest: OK`도 요구한다.

최소 보존 파일:

```text
server-command.txt
server-sha256.txt
server.txt
preload.txt
load.txt
stats-after-preload.txt
stats-final.txt
results.csv
```

2026-07-28 clean full-delete run은
`/home/seonung/rdma-results/memcached-port-v2-4d3b2d1/`에 보존돼 있다.
