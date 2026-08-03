# V2 코드 및 검증 명세

> **[v2 시점 기록]** 이 문서는 그 시점의 기록으로 보존한다. 현재 운영값은
> [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md), 최신 결과는
> [`V4_RESULT.md`](V4_RESULT.md) 다.

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
| P2c: co-located 게이트 | clean binary 실측 통과 | 3회 중앙값 5.797M GET/s, 1.943 CPU µs/op |
| P3: hardware 최종 확인 | 완료 | smoke/mixed/torn 및 3회 GET-only correctness 0 |

source 구현뿐 아니라 아래 SHA-256 binary의 Ariel↔Genie RDMA 무결성과
성능을 실제 hardware에서 확인했다.

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

## 6. 검증 상태와 결과

이번 정리에서 확인한 것:

- clean source build: 통과
- `./testapp`: 56/56 통과
- 일반(non-extstore) slab class 선택: stock 경로 유지
- legacy symbol scan: `store_iothr|extstore_io_thread|extstore_submit|
  extstore_staging_get|extstore_delete|io_threadcount|io_depth` 0건
- actual RDMA selftest: 256 B WRITE/READ 일치
- remote-only smoke: 200 SET, 100 GET, delete 후 objects/bytes/curr_items 0
- mixed-size: 6 rounds, 5,000 keys, badcrc/leak 0
- torn stress: 80,000 remote READ, retry/badcrc/miss 0
- GET-only 3회: miss/badcrc/RDMA failure/engine dead/leak 0,
  `extstore_prof_read_count == cmd_get`

삭제된 eviction, chunked remote object, flash extstore 옵션에 의존하는 upstream
테스트는 v2 호환 테스트가 아니다. 목록과 사유는 `t/SKIPPED_V2.list`에 둔다.

완전 삭제 binary SHA-256은
`2f1e283f2f527f9a5e3bd2973114cfb130342964d3df05dc35075d1335abd43c`다.
`mcT=12, W=16, pipeline=64, spin=1024`, 1M×64 B keyspace에서 10초씩
3회 측정한 중앙값은 5.797M GET/s, span avg/p50/p99
13.951/13.3/31.6 µs, server CPU 1.943 µs/op다.

### canonical topology (v3에서 개정)

v2까지의 계약은 "Ariel guest의 memtier와 memcached가 localhost TCP로 통신하고,
memcached만 Genie의 MR에 RDMA를 수행한다. Genie에서 memtier를 실행하는 off-box
경로와 10M gate는 검증 계약이 아니다"였다.

**v3에서 이 조항을 개정한다.** off-box 부하가 canonical topology가 된다.

개정 사유는 측정이다. co-located 위상에서 client는 Ariel의 물리 16코어 중
11.2 cpu-equiv를 오직 부하 생성에만 쓴다. 측정 구간 동안 guest 30 vCPU 중
28.1~28.4가 바쁘고(94%), 10M은 memcached 24 + memtier 16 = 40 스레드를
32 논리 CPU에 요구한다. **위상을 바꾸지 않는 한 10M은 자원 계산상 성립하지
않는다** — 코드로 고칠 수 있는 문제가 아니다.

| 항목 | v2 (co-located) | v3 (off-box) |
|---|---|---|
| 부하 생성 | Ariel guest 내 memtier | Genie의 memtier |
| client→server 전송 | guest loopback TCP | IPoIB, `10.99.0.3:11411` |
| Ariel 코어 배분 | server 18 + client 12 | 전부 server |
| Genie 역할 | MR 제공만 | MR 제공 + 부하 생성 |

전제 검증은 끝났다. Genie 박스에서 `10.99.0.3:11411`로 실제 TCP가 들어와
응답을 받았고(loopback 우회가 아닌 wire 경유), IPoIB 패킷당 guest CPU는
64 B 3.08 µs / 1400 B 3.38 µs로 크기에 거의 무관한 고정 비용이다. 10M 기준
IPoIB 전체가 약 2.3 cpu-equiv로, 대체되는 memtier의 11.2보다 훨씬 싸다.

Genie의 CPU는 데이터 경로에서 소모되지 않는다. opcode가
`IBV_WR_RDMA_READ`/`IBV_WR_RDMA_WRITE`뿐이고 SEND/RECV가 없으므로 Genie의
HCA가 MR에 직접 DMA한다. hit 부하 하에서의 실측 확인은 진행 중이다.

**게이트 의미는 바뀌지 않는다.** `avg < 30 µs` 판정은 `read_avg_ns`, 즉 서버
측 span-v2(post → CQE → SYNC_FOR_CPU → decrypt)를 읽는다. client end-to-end가
아니므로 client 위치와 무관하다. Genie가 보고하는 client latency에는 네트워크
왕복이 포함되며 span-v2와 같은 열에 두지 않는다.

off-box 런 하네스는 `tools/obup.sh`(기동·프리로드·연속 샘플링)와
`tools/obslice.sh`(구간 절단)다.

repository가 과거 build object를 tracked하므로 검증 전에는
`make clean && make -j"$(nproc)"`를 사용하고 실행 binary hash를 남긴다.
