# SEV-SNP remote-memory 실험 실행 가이드

모든 구성 sweep은 `tools/config-matrix-10s.sh` 하나로 실행한다. 변수 이름의
정의는 [`../GLOSSARY.md`](../GLOSSARY.md)에 있다.

## 측정 계약

| 항목 | 조건 |
|---|---|
| guest | SEV-SNP, 24 vCPU, 48 GB configured RAM |
| CPU 배치 | client가 상위 `mtT`개 CPU, server가 나머지. 표준 shape은 server 0–15, memtier 16–23 |
| workload | GET-only, 64 B, 1,000,000 preloaded keys |
| memcached | `-t mcT -m 2048 -c 8192 -R 1024 -U 0` |
| memtier | `mtT` threads × 16 clients/thread |
| Port security | AES-256-GCM ON (`EXT_CRYPTO_KEY` 필수) |
| Port throughput | `extstore_prof_read_count / 측정초`; 같은 구간 `cmd_get`과 일치해야 한다 |
| Port GET latency | READ post 직전 → CQE → sync/private copy → decrypt 완료 |
| Port SET latency | encrypt 시작 → WRITE CQE (enqueue 대기 포함) |
| stock throughput | `cmd_get / 측정초` |
| stock latency | memtier end-to-end; Port remote span과 직접 비교하지 않음 |

Port 측정 대상은 memtier end-to-end가 아니라 원격 메모리 access다. memtier는
load generator로만 쓴다. 모든 채택 point는 miss, badcrc, RDMA failure,
engine dead, plaintext slab fallback이 전부 0이어야 한다.

## 실행 환경 전제

runner가 server를 띄울 때 아래를 고정으로 넣는다. 손으로 실행할 때도 같아야 한다.

| 항목 | 값 | 이유 |
|---|---|---|
| `LD_LIBRARY_PATH` | `$HOME/covlib:$REPO` | patched libibverbs/libmlx5. `SYNC_FOR_CPU`/`SYNC_FOR_DEVICE` advise가 여기 있다 |
| `MLX5_COHERENT_QP` / `MLX5_COHERENT_CQ` | `1` / `1` | 없으면 `rdma_cm`이 hang한다 |
| `EXT_SLOT_SIZE` | `256` | remote object·bounce·staging·plaintext slot 크기 |
| `EXT_READ_SLOTS` | `64` | IO thread당 bounce slot(상한값) |
| `EXT_RDMA_PROF` | `1` | span-v2 수집. 없으면 Port headline이 0이다 |
| `EXT_CRYPTO_KEY` | `$REPO/ext.key` | 32 byte AES-256 key |
| remote | `genie_memd 11212 4g --prefill` | `10.99.0.2:11212`, passive |

`ext_path`의 `:4g`는 크기 검사용일 뿐이고 실제 remote 용량은 genie가 보고한
MR 크기다.

## 실행

guest에 현재 Port binary, stock binary, memtier, `ext.key`를 배치하고 아래
경로만 실제 배치 위치에 맞춘다.

```bash
cd "$HOME/kvs-port"

REPO="$HOME/kvs-port" \
PORT_BIN="$HOME/kvs-port/spanv2-pool-crypto-qpaff-iolock/memcached" \
STOCK_BIN="$HOME/kvs-port/memcached.stock" \
MT="$HOME/memtier/memtier_benchmark" \
OUT="$HOME/rdma-results/frontier-7point-$(date +%Y%m%d-%H%M%S)" \
PHASES=frontier \
TEST_SECONDS=10 \
tools/config-matrix-10s.sh
```

### PHASES

| 값 | 내용 | 고정 조건 |
|---|---|---|
| `all` | `qp`+`pipeline`+`threads`+`depth`+`stock` 전체 | pipeline=4, depth=64 계열 |
| `qp` | `ext_threads/QP = 1,2,4,8,16` | mtT=8, mcT=8, pipeline=4, depth=64 |
| `pipeline` | `pipeline = 1,2,4,8,16,32` | mtT=8, mcT=8, QP=8, depth=64 |
| `threads` | `mtT × mcT × QP` 조합, `mtT+mcT+QP <= 24` | pipeline=4, depth=64 |
| `depth` | `$DEPTHS` (기본 `16 32 64 128`) | mtT=8, mcT=8, QP=8, pipeline=`$DEPTH_PIPELINE` |
| `stock` | stock local-memory control 1점 | mtT=8, mcT=8, pipeline=4 |
| `frontier` | Port 후보 4점 + stock pipeline 4/6/8 | 현재 운영점을 고른 실행 |
| `sensitivity` | `$SENS_AXES`의 단일축 sweep | 기준점 mcT=8, pipeline=8, QP=8, depth=16 |
| `qpxdepth` | `QP×depth=$QPXD_WINDOW`(기본 128) 고정 window 5점 | mtT=8, mcT=8, pipeline=8 |
| `qpd1` | depth=1, QP=1..16 | mtT=8, mcT=8, pipeline=8 |
| `plateau` | pipeline 8..64 ladder 후 argmax pipeline에서 mtT=mcT=8..12 | QP=8, depth=16 |

`qpxdepth`·`qpd1`·`plateau`는 공백으로 묶어 한 번에 실행할 수 있다
(`PHASES="qpxdepth qpd1 plateau"`). 결과는 [`THREE_EXP_20260727.md`](THREE_EXP_20260727.md)에 있다.

예:

```bash
PHASES=depth DEPTHS="1 2 4 8" DEPTH_PIPELINE=4 tools/config-matrix-10s.sh

PHASES=sensitivity \
SENS_AXES="mc_threads pipeline" \
SENS_MC_THREADS="$(seq 1 16)" \
SENS_PIPELINES="$(seq 1 8)" \
tools/config-matrix-10s.sh
```

`SENS_AXES`는 `mc_threads`, `pipeline`, `qp`, `depth` 중 원하는 것만 고른다.

### point마다 runner가 하는 일

1. server 재시작과 `/proc/<pid>/exe` SHA-256 기록
2. 1M key preload 후 `curr_items` 검증 (다르면 그 point는 실패로 기록하고 중단)
3. 2초 warmup, `stats reset`
4. `TEST_SECONDS`초 GET load
5. `cmd_get`, remote completion, span-v2, correctness counter를 CSV에 기록
6. `extstore_prof_read_count == cmd_get`이고 miss/badcrc/read failure/engine dead가
   모두 0이어야 `status=ok`

## 그래프

```bash
python3 tools/plot-config-matrix.py <results.csv> <img-dir>
for f in <img-dir>/*.svg; do rsvg-convert -w 1600 -o "${f%.svg}.png" "$f"; done
```

plotter는 CSV의 `phase` 열을 보고 sensitivity / frontier / 전체 matrix 중
어느 그림을 그릴지 스스로 고른다. 축이 불완전하면 assert로 멈춘다.

## 현재 결과

운영점은 `mtT=8×c16, mcT=8, pipeline=8, QP/ext=8, depth=16`이다. 같은 binary로
두 번 측정했다.

| 측정일 | remote GET/s | avg | p50 | p99 | 문서 |
|---|---:|---:|---:|---:|---|
| 2026-07-24 | 2.445M | 22.252µs | 20.300µs | 59.600µs | [FRONTIER](FRONTIER_7POINT_20260724.md) |
| 2026-07-27 | 2.967M | 20.888µs | 20.400µs | 43.700µs | [SENSITIVITY](SENSITIVITY_THREAD_PIPELINE_20260727.md) |

2026-07-24 실행에서 같은 shape의 stock local-memory throughput은 3.371M GET/s였고
Port는 그 72.54%였다. 최초 전체 matrix의 당시 조건별 실측은
[`CONFIG_MATRIX_10S_20260724.md`](CONFIG_MATRIX_10S_20260724.md)에 있다.

## 결과 보존

`OUT` 아래의 `results.csv`, `binaries.sha256`, `README.txt`, 각 point의
`server-command.txt`, `server-sha256.txt`, `server.txt`, `stats-start.txt`,
`preload.txt`, `stats-after-preload.txt`, `warmup.txt`, `load.txt`,
`stats-final.txt`를 함께 보존한다. summary 수치만 남기지 않는다. 위치는
[`RAW_DATA_INDEX.md`](RAW_DATA_INDEX.md)에 기록한다.
