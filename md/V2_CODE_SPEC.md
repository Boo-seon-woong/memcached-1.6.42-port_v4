# V2 코드 및 검증 명세

기준일: 2026-07-28

이 문서는 현재 `memcached-1.6.42-port_v2` 구현의 authority다. 이전 단계별
초안의 라인 번호와 “P2b에서 삭제 예정” 표현은 더 이상 유효하지 않다.

## 1. 현재 판정

| 단계 | 상태 | 현재 근거 |
|---|---|---|
| P0: LRU/crawler/mover 제거 | 구현 완료 | 관련 소스·옵션 제거, GET hit 통계는 slab stats에 직접 합산 |
| P1: remote-only slab 2-class | 구현 완료 | extstore 사용 시에만 stub/transient 2-class, 일반 모드는 stock class 유지 |
| P2a: GET worker-inline | 구현 완료 | worker 소유 QP/CQ/bounce, 같은 worker에서 post/drain/decrypt |
| P2b: SET worker-inline + IO thread 삭제 | 구현 완료 | 구형 queue/thread/QP/global staging 경로가 소스에서 삭제됨 |
| P2c: co-located 게이트 | 기존 실측 통과 | 5.646M GET/s, 1.991 CPU µs/op; 아래 측정 계약 참조 |
| P3: off-box 최종 판정 | 미실행 | 이번 소스 정리 후 새 hardware run 필요 |

“구현 완료”는 source/build/local unit 기준이다. 실제 Ariel↔Genie RDMA 무결성과
성능은 P3 실행 전까지 완료로 주장하지 않는다.

## 2. 실제 자원 소유 모델

```text
memcached worker
  ├─ TCP connection/event loop
  ├─ 1..4 RC QP
  ├─ QP들이 공유하는 CQ 1개
  ├─ private bounce slots (RDMA READ destination)
  └─ private staging slots (RDMA WRITE source)
```

`extstore_init()`은 설정과 Genie 주소만 보관한다.
`extstore_workers_prepare()`이 첫 worker QP를 연결해 PD와 remote
`raddr/rkey/size`를 얻고, 모든 worker QP와 MR/page table을 준비한다.
따라서 초기화용 dummy QP, `store_iothr`, `extstore_io_thread`,
`extstore_submit`, 전역 staging mutex/cond는 존재하지 않는다.

GET 경로:

```text
storage_get_item
  -> storage_submit_cb
  -> extstore_worker_submit
  -> worker QP RDMA READ
  -> extstore_worker_drain
  -> SYNC_FOR_CPU
  -> AES-256-GCM open/AAD 검증
  -> worker-local response resume
```

SET 경로:

```text
storage_store_item
  -> extstore_alloc
  -> worker-private staging에 AES-256-GCM seal
  -> extstore_worker_post_write
  -> 같은 worker가 CQ drain
  -> WRITE CQE 성공
  -> ITEM_HDR publish
  -> STORED
```

`STORED`는 WRITE CQE 이후에만 반환된다. tag 검증 실패 데이터는 절대 응답하지
않으며, transient visibility 실패는 설정된 횟수만 재시도한다.

## 3. 설정과 기본값

| 설정 | 기본값 | 의미 |
|---|---:|---|
| `-t` | 4 (upstream) | memcached worker 수; 기본 QP 수도 동일 |
| `ext_worker_window` | 16 | worker당 READ+WRITE outstanding 상한 |
| `ext_qp_per_worker` | 1 | worker당 QP 수, 1..4 |
| `ext_drain_spin` | 1024 | socket event 뒤 CQ poll 반복 상한 |
| `EXT_SLOT_SIZE` | 256 B | sealed remote object와 local transient class의 공통 한도 |
| `EXT_READ_SLOTS` | 32 | worker당 bounce slot, 최대 64 |
| `EXT_WRITE_SLOTS` | 256 | 전체 staging 예산; worker별로 균등 분할 |

삭제된 설정: `ext_threads`, `ext_io_depth`. v2 실행 도구나 명령에 이 값을
넣으면 구성 오류로 종료하는 것이 정상이다.

## 4. slot 크기와 회계

`EXT_SLOT_SIZE_DEFAULT=256`을 slabs와 storage가 함께 사용한다. 이전의
slabs 256 / storage 2048 불일치는 기본값을 생략했을 때 slab admission과
remote allocation이 서로 다른 최대 객체 크기를 적용하게 만들었다. 명시적으로
`EXT_SLOT_SIZE=256`을 준 기존 측정에는 영향이 없지만, 기본 실행에서는
remote engine이 받을 수 있다고 본 객체를 slabs가 먼저 거절할 수 있었다.

slot 해제는 `extstore_free_loc()` 하나로 통합한다. 이 함수가 page와 engine의
object/byte count를 동시에 감소시키고 free-list에 location을 반환한다.
일반 READ miss와 proxy miss도 stub unlink 전에 반드시 `storage_delete()`를
호출한다. 불일치·stale location·free-list 확장 실패는
`ext_slot_acct_leak`를 증가시키며 정상 실행에서는 0이어야 한다.

## 5. 관측 가능성 계약

다음 stats는 v2 실행의 필수 증거다.

- `ext_worker_window`
- `ext_worker_drain_calls`, `ext_worker_drain_empty`
- `ext_worker_wait_enq`, `ext_worker_write_spins`
- `ext_slot_acct_leak`
- `extstore_engine_dead`, `extstore_read_failures`,
  `extstore_write_failures`
- `badcrc_from_extstore`, `extstore_prof_read_count`

GET-only 완료 run은 최소한 아래를 만족해야 한다.

```text
get_misses = 0
badcrc_from_extstore = 0
extstore_read_failures = 0
extstore_write_failures = 0
extstore_engine_dead = 0
ext_slot_acct_leak = 0
extstore_prof_read_count = cmd_get
```

span-v2 READ 경계는 post 직전부터 CQE, `SYNC_FOR_CPU`, decrypt 완료까지다.
memtier latency는 client end-to-end이므로 span-v2와 같은 열로 직접 비교하지 않는다.

## 6. 검증 상태와 다음 게이트

이번 정리에서 확인한 것:

- clean source build: 통과
- `./testapp`: 56/56 통과
- 일반(non-extstore) slab class 선택: stock 경로 유지
- legacy symbol scan: `store_iothr|extstore_io_thread|extstore_submit|
  extstore_staging_get|extstore_delete|io_threadcount|io_depth` 0건
- 실제 RDMA smoke/mixed/torn/off-box: 미실행

삭제된 eviction, chunked remote object, flash extstore 옵션에 의존하는 upstream
테스트는 v2 호환 테스트가 아니다. 목록과 사유는 `t/SKIPPED_V2.list`에 둔다.

기존 P2b 동작 실측은 `mcT=12, W=16, pipeline=64, spin=1024`에서
5.646M GET/s, 1.991 CPU µs/op, correctness 0이었다. 당시 IO thread는 이미
요청을 처리하지 않았지만 초기화용 legacy QP와 dead code가 남아 있었다.
이번 완전 삭제 후에는 아래 순서로 다시 판정한다.

1. Genie virgin MR + `EXT_SELFTEST=1`.
2. 1M SET preload 후 `curr_items=1000000`, slot/correctness counters 0.
3. GET/mixed/torn smoke.
4. 같은 boot에서 v1 보정점과 v2 co-located 점.
5. off-box stock ≥10M/s 보정 후 v2 최종 캠페인.
