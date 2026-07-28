# Port v2 remodification 계획과 현재 상태

기준일: 2026-07-28

## 결론

계획했던 구조 변경 P0~P2b는 source 수준에서 완료됐고, clean binary의
Ariel↔Genie correctness와 co-located 성능 재측정도 완료됐다.

v2의 목적은 값이 remote에만 존재한다는 전제를 코드 구조에 반영하는 것이다.
client↔memcached TCP와 AES-256-GCM 계약은 유지하며, flash extstore에서 물려받은
LRU/eviction/IO-thread handoff를 제거한다.

## 확정된 구조

- hash에는 `ITEM_HDR` stub만 존재한다.
- 성공한 SET value는 worker가 seal하고 RDMA WRITE CQE를 확인한 뒤 publish한다.
- GET은 worker가 자기 QP에 READ를 post하고 자기 CQ에서 완료를 drain한다.
- QP/CQ/bounce/staging은 worker 소유이며 hot path에서 공유 lock이 없다.
- eviction과 능동 TTL 회수는 없다. 메모리/remote slot 고갈 시 SET 실패,
  TTL은 접근 시 lazy 처리한다.
- remote-only 모드만 slab 2-class(stub/transient)를 사용한다. 일반 memcached
  실행은 stock slab class를 사용한다.
- `ext_threads`와 `ext_io_depth`는 삭제됐다.

## 단계별 상태

| 단계 | 결과 | 남은 게이트 |
|---|---|---|
| P0 | LRU maintainer/crawler/slab mover와 관련 옵션 제거 | 삭제 기능 의존 test는 skip 사유 유지 |
| P1 | remote-only 2-class, slot 기본값 256으로 통일 | mixed-size와 slot 회계 통과; exact ±1 B 경계는 별도 |
| P2a | GET worker-inline, worker당 QP fan-out 1..4 | 80,000 torn-stress READ 포함 correctness 통과 |
| P2b | SET worker-inline, legacy IO thread/QP/queue/global staging 완전 삭제 | smoke/mixed/torn correctness 통과 |
| P2c | 완전 삭제 binary 3회 co-located 측정 완료 | 5.797M/s, 1.943 CPU µs/op 중앙값 |
| P3 | 현재 topology 최종 확인 완료 | 별도 loadgen topology 확장은 현재 범위 밖 |

## 이번 정리에서 해결한 문제

### Legacy IO 자원

이전 부분 구현은 `ext_threads=0`일 때 pthread를 만들지 않았지만 PD와 remote
MR 정보를 얻기 위해 사용되지 않는 구형 QP 하나를 연결했고, old queue와 global
staging 코드도 남겼다. 이제 첫 worker QP가 그 bootstrap 역할을 하므로 runtime
QP 수는 정확히 `workers × ext_qp_per_worker`다.

이 삭제가 보장하는 것은 dead resource와 초기화 비용 제거, ownership 단순화다.
기존 inline 경로가 이미 요청당 queue/cond/eventfd를 우회했으므로, 완전 삭제만의
추가 CPU/op 이득은 작을 가능성이 높다. 다만 1.991 CPU µs/op 수준의 기존 결과는
worker 수나 client 배치를 바꿀 때 throughput 개선 여지가 있음을 보여준다.
완전 삭제 binary의 실측 중앙값은 1.943 CPU µs/op다.

### Slot 기본값

slabs와 storage가 서로 다른 기본값을 쓰면 명시적 env가 없는 실행에서 admission
한도와 remote allocation 한도가 달라진다. 둘 모두 256 B 상수를 사용하도록
통일했고, remote-only 여부를 `slabs_init`에 전달해 일반 memcached 테스트가
2-class 제한을 받지 않게 했다.

### Slot 회계

`extstore_delete`와 `extstore_free_loc`로 분리돼 있던 회계를
`extstore_free_loc` 하나로 합쳤다. allocation 실패, 정상 delete, READ miss,
proxy miss가 모두 같은 해제 경로를 사용한다. `ext_slot_acct_leak`가 불변식
위반을 노출한다.

### 관측성

worker window, drain call/empty, wait enqueue, SET spin, slot accounting leak를
stats에 추가했다. 결과 표는 throughput과 latency뿐 아니라 이 값들과
miss/badcrc/RDMA failure/engine dead를 함께 보존해야 한다.

## 실행 기준

기본 측정 shape:

```text
mcT=12
memtier threads=8, clients=16
pipeline=64
ext_worker_window=16
ext_qp_per_worker=1
ext_drain_spin=1024
EXT_SLOT_SIZE=256
EXT_READ_SLOTS=64
crypto=ON
```

canonical 도구:

- `tools/config-matrix-10s.sh`: thread/pipeline/window/QP와 stock control
- `tools/cpu-stage-detail.sh`: worker/client CPU µs/op
- `tools/remote-only-smoke.sh`, `tools/mixed-size-stress.sh`,
  `tools/torn-repro.sh`: correctness
- `tools/test-v2.sh`: local 호환 테스트

canonical topology:

```text
Ariel guest memtier --localhost TCP--> Ariel guest memcached
                                     --one-sided RDMA--> Genie genie_memd MR
```

Genie는 remote memory server만 실행한다. Genie에서 memtier를 실행하는
off-box 계획은 이 시스템의 역할 분리와 맞지 않으므로 v2 게이트에서 제외한다.

각 run은 binary SHA-256, server command, server/memtier raw text, 시작/종료 stats,
CSV를 남긴다. CSV의 `server_get_s`는 port와 stock 모두 `cmd_get/seconds`,
`remote_get_s`는 port의 검증된 remote completion 기준이다. RDMA readiness는
TCP port open이 아니라 server log의 `genie_connect OK`와
`extstore selftest: OK`로 판정한다.

## 최종 실측

binary SHA-256:
`2f1e283f2f527f9a5e3bd2973114cfb130342964d3df05dc35075d1335abd43c`

3회 10초 GET-only 결과:

| run | `cmd_get/10s` | span avg | p50 | p99 | server CPU |
|---:|---:|---:|---:|---:|---:|
| 1 | 5,700,288.8/s | 14.114 µs | 13.4 µs | 32.3 µs | 1.972882 µs/op |
| 2 | 5,797,294.4/s | 13.951 µs | 13.3 µs | 31.6 µs | 1.942113 µs/op |
| 3 | 5,812,638.8/s | 13.791 µs | 13.3 µs | 31.2 µs | 1.943179 µs/op |
| median | 5,797,294.4/s | 13.951 µs | 13.3 µs | 31.6 µs | 1.943179 µs/op |

모든 run에서 miss, badcrc, RDMA read/write failure, engine dead,
slot accounting leak가 0이고 `extstore_prof_read_count == cmd_get`였다.
일부 memtier final summary가 progress count와 불일치해 throughput은 계약대로
server count를 10초로 나눈 값만 사용한다.

raw artifact:
`/home/seonung/rdma-results/memcached-port-v2-4d3b2d1/`

날짜가 다른 절대 throughput은 직접 순위화하지 않는다. 같은 run/boot 안의 상대
비교와 retained raw artifact만 근거로 사용한다.
