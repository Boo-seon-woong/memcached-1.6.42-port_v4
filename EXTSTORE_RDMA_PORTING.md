# extstore → RDMA 원격 메모리 포팅 결정

상태: 구현 완료. 이 문서는 구현 전 Tier/가설 문서를 대체하고, **무엇을 채택하고
무엇을 버렸는지와 그 근거**만 기록한다.

- 변수 정의: [`GLOSSARY.md`](GLOSSARY.md)
- 함수·자료구조 수준 명세: [`SOURCE_CHANGE_SPEC.md`](SOURCE_CHANGE_SPEC.md)
- 운영점 결정 근거: [`md/FRONTIER_7POINT_20260724.md`](md/FRONTIER_7POINT_20260724.md)

## 현재 구조

- 포팅 범위는 client↔memcached TCP가 아니라 memcached extstore backend다.
- 성공한 SET value는 AES-256-GCM으로 seal한 뒤 one-sided RDMA WRITE를
  완료하고, local hash에는 `ITEM_HDR` metadata만 publish한다.
- GET은 `ITEM_HDR`의 remote location으로 RDMA READ하고,
  `SYNC_FOR_CPU`로 private-visible 상태를 만든 뒤 AES-GCM open을 완료한다.
- local value cache, flash wbuf/compaction/recache, local memcpy backend는 없다.
- `ext_threads = RC QP 수 = busy-poll IO thread 수`이며 1:1이다.
- 코드 기본값은 `ext_threads=1`, `ext_io_depth=64`지만 현재 `<30µs`
  throughput-optimal 실행값은 `ext_threads/QP=8`, `depth=16`이다.

## 채택된 성능 변경

| 변경 | 현재 상태 | 근거 |
|---|---|---|
| GET plaintext 임시 버퍼를 per-worker cache에서 재사용 | 채택 | slab/futex hot path 제거 |
| thread-local `EVP_CIPHER_CTX` 재사용 | 채택 | crypto CPU와 provider lock 경합 감소 |
| worker별 QP affinity | 채택 | 모든 worker가 모든 QP queue lock을 치는 round-robin 제거 |
| IO-owner 전용 `outstanding`/`bounce_free` lock 제거 | 채택 | self-lock 제거 |
| process-level CPU 분리 | 채택 | server CPU 0–15, memtier CPU 16–23 |
| worker/IO thread 개별 pinning | 폐기 | 동일 조건 throughput 9.1% 감소 |
| post/CQ batch cap 32→64 | 폐기 | throughput 이득 없음 |
| per-IO profile counter | 폐기 | 기준선 개선 없음 |

## 폐기되거나 보류된 초기 아이디어

- **worker-direct/IO thread 삭제**: worker→QP affinity와 IO-owner self-lock
  제거로 대체했다. 현재 계획에서 제거한다.
- **coherent-MR로 bounce 제거**: 현재 CPU 회계에서 sync/ioctl 상한이 약
  `0.16 CPU-µs/op`라 throughput 우선순위가 낮다. DMA copy 또는 latency가
  별도 병목으로 확인될 때 kernel track으로 진행한다.
- **slab 전체 MR/ODP/hugepage MR**: 현재 구현은 `/dev/snp_shared` 기반
  read-bounce/write-staging pool만 등록한다. 따라서 기존 “slab 전체를
  zero-copy MR로 등록” 설계는 사용하지 않는다.
- **flash compaction 유지/개조**: compaction 자체를 제거했고 remote slot
  allocator와 free-location stack으로 대체했다.

## 현재 실험점

| 항목 | 값 |
|---|---|
| guest | SEV-SNP, 24 vCPU, 48 GB configured RAM |
| CPU | server 0–15, memtier 16–23 |
| memcached | `-t 8 -R 1024` |
| memtier | 8 threads × 16 clients, pipeline 8 |
| RDMA engine | QP/ext 8, depth 16 |
| workload | GET-only, 64 B, 1M preloaded keys, 10초 |

같은 binary로 이 운영점을 두 번 측정했다.

| 측정일 | remote GET/s | avg | p50 | p99 |
|---|---:|---:|---:|---:|
| 2026-07-24 | 2.445M | 22.252µs | 20.300µs | 59.600µs |
| 2026-07-27 | 2.967M | 20.888µs | 20.400µs | 43.700µs |

두 값을 섞어 쓰지 않는다. 운영점 선택은 각 실행 안의 상대 비교로만 한다.

GET latency는 `RDMA READ post 직전 → CQE → SYNC_FOR_CPU/private copy →
AES-GCM open 완료`, SET latency는 `AES-GCM seal 시작 → RDMA WRITE CQE`다.
memtier는 Port에서 부하 생성기이며, Port headline은 remote completion count와
위 내부 span이다.

## 남은 작업의 판정 기준

추가 구조 변경은 같은 workload에서 다음을 모두 기록한 뒤 결정한다.

1. `remote GET/s`, span-v2 avg/p50/p99
2. worker/io CPU-µs/op
3. `cmd_get == extstore_prof_read_count`
4. miss, badcrc, RDMA failure, engine dead가 모두 0

현재 재현 절차는 [`md/experiment.md`](md/experiment.md), CPU 근거는
[`md/CPU_COST_ACCOUNTING.md`](md/CPU_COST_ACCOUNTING.md)에 있다.

## 아직 열려 있는 것

- **p99 `<30µs`는 어느 실험 point에서도 달성하지 못했다.** avg만 충족했다.
- **server 확장 상한을 판정하지 못했다.** 같은 box의 memtier가 약 1M ops/s에서
  먼저 포화하므로, worker/QP를 늘렸을 때의 진짜 상한을 보려면 off-box client가
  필요하다.
- **10M GET/s 목표의 적용 범위.** 같은 shape의 stock local control도 3.371M/s라
  현 운영점에서 10M은 port 품질을 판정하는 기준이 되지 못한다. 전체 하드웨어의
  절대 상한을 주장하려면 별도 stock saturation sweep이 필요하다.
- **mixed-size workload.** 현재 allocator는 top-only LIFO 재사용이라
  fragmentation이 실제로 나타나면 size-class free-list가 필요하다.
