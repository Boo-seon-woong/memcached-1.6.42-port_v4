# 실험 raw-data 인덱스

이 문서는 정돈된 표가 아니라 실험 원문이 저장된 디렉터리를 전부 가리킨다.
raw 파일은 수정하거나 Markdown에 복제하지 않는다.

| 실험 | 측정일 | root | 문서 |
|---|---|---|---|
| CONFIG MATRIX 10s | 2026-07-24 | `rdma-results/config-matrix-10s-20260724/` | [CONFIG_MATRIX](CONFIG_MATRIX_10S_20260724.md) |
| FRONTIER 7-point | 2026-07-24 | `rdma-results/frontier-7point-20260724/` | [FRONTIER](FRONTIER_7POINT_20260724.md) |
| CPU 회계 | 2026-07-24 | `rdma-results/cpu-stage-detail-20260724/` | [CPU_COST_ACCOUNTING](CPU_COST_ACCOUNTING.md) |
| CPU 점진 최적화 | 2026-07-24 | `rdma-results/cpu-optimization-20260724/` | [CPU_OPTIMIZATION_ROLLOUT](CPU_OPTIMIZATION_ROLLOUT.md) |
| thread/pipeline 민감도 | 2026-07-27 | `rdma-results/sensitivity-thread-pipeline-20260727/` | [SENSITIVITY](SENSITIVITY_THREAD_PIPELINE_20260727.md) |
| 3실험 (window/depth1/plateau) | 2026-07-27 | `rdma-results/three-exp-20260727-082205/` | [THREE_EXP](THREE_EXP_20260727.md) |

모든 경로의 접두사는 `/home/seonung/2026/`다.

## 파일 구성

`config-matrix-10s.sh`가 만든 각 point 디렉터리에는 다음 9개 원문이 있다.

| 파일 | 내용 |
|---|---|
| `server-command.txt` | 실제 server 실행 명령과 CPU/QP/depth 설정 |
| `server-sha256.txt` | 실행 중인 `/proc/<pid>/exe` SHA-256 |
| `server.txt` | memcached stdout/stderr |
| `stats-start.txt` | server 시작 직후 stats |
| `preload.txt` | memtier 1M-key preload 전체 출력 |
| `stats-after-preload.txt` | preload 완료 뒤 stats |
| `warmup.txt` | 2초 GET warmup 전체 출력 |
| `load.txt` | 10초 memtier GET workload 전체 출력 |
| `stats-final.txt` | 측정 직후 memcached stats 전체 출력 |

각 run root에는 `README.txt`, `binaries.sha256`, `results.csv`가 있다.
CONFIG MATRIX root에는 run들을 합친 `results-canonical.csv`도 있다.

## CONFIG_MATRIX_10S_20260724

root:

```text
/home/seonung/2026/rdma-results/config-matrix-10s-20260724/
```

총 388 files이다.

### 최초 전체 matrix raw

root:

```text
/home/seonung/2026/rdma-results/config-matrix-10s-20260724/main/
```

27 points, 246 files:

```text
qp-ext1/
qp-ext2/
qp-ext4/
qp-ext8/
qp-ext16/

pipeline-1/
pipeline-2/
pipeline-4/
pipeline-8/
pipeline-16/
pipeline-32/

threads-mt4-mc4-ext4/
threads-mt4-mc4-ext8/
threads-mt4-mc4-ext16/
threads-mt4-mc8-ext4/
threads-mt4-mc8-ext8/
threads-mt4-mc16-ext4/
threads-mt8-mc4-ext4/
threads-mt8-mc4-ext8/
threads-mt8-mc8-ext4/
threads-mt8-mc8-ext8/
threads-mt16-mc4-ext4/

depth-16/
depth-32/
depth-64/
depth-128/

stock-local/
```

`main/threads-*`는 최초 실행 원문이므로 보존하지만, CPU 배치를 바로잡은
thread 결과는 아래 `threads-corrected-v2/`가 표의 근거다.

### Thread 조합 corrected raw

root:

```text
/home/seonung/2026/rdma-results/config-matrix-10s-20260724/threads-corrected-v2/
```

11 points, 102 files:

```text
threads-mt4-mc4-ext4/
threads-mt4-mc4-ext8/
threads-mt4-mc4-ext16/
threads-mt4-mc8-ext4/
threads-mt4-mc8-ext8/
threads-mt4-mc16-ext4/
threads-mt8-mc4-ext4/
threads-mt8-mc4-ext8/
threads-mt8-mc8-ext4/
threads-mt8-mc8-ext8/
threads-mt16-mc4-ext4/
```

### Depth 1/2/4/8 추가 raw

root:

```text
/home/seonung/2026/rdma-results/config-matrix-10s-20260724/depth-low-p4/
```

4 points, 39 files:

```text
depth-1/
depth-2/
depth-4/
depth-8/
```

고정 조건은 `mtT=8×c16, mcT=8, QP/ext=8, pipeline=4`다.

### Canonical CSV

```text
/home/seonung/2026/rdma-results/config-matrix-10s-20260724/results-canonical.csv
```

`main`, corrected thread, 추가 depth 결과를 한 파일에 합친 표 입력이다. raw
원문을 대체하지 않는다.

## FRONTIER_7POINT_20260724

root:

```text
/home/seonung/2026/rdma-results/frontier-7point-20260724/
```

7 points, 66 files:

```text
candidate-q4-d32-p4/
candidate-q6-d16-p4/
candidate-q8-d16-p6/
candidate-q8-d16-p8/
stock-p4/
stock-p6/
stock-p8/
```

Port 4개와 동일-shape stock 3개의 실행 원문이 모두 들어 있다.

## SENSITIVITY_THREAD_PIPELINE_20260727

root:

```text
/home/seonung/2026/rdma-results/sensitivity-thread-pipeline-20260727/
```

총 231 files, 두 번의 실행으로 나뉜다.

### 최초 실행 raw (mcT=1–7)

```text
/home/seonung/2026/rdma-results/sensitivity-thread-pipeline-20260727/part1-initial/
```

7 points, 65 files. `mc-thread-7/`은 사용자 요청으로 중단된 partial point라
완결된 `stats-final.txt`와 CSV row가 없다. canonical 결과에서는 제외한다.

### continuation raw (mcT=7–16, pipeline=1–8)

```text
/home/seonung/2026/rdma-results/sensitivity-thread-pipeline-20260727/continuation/
```

18 points, 165 files. 중단됐던 `mc-thread-7`의 완결본이 여기 있다.

### Canonical CSV

```text
/home/seonung/2026/rdma-results/sensitivity-thread-pipeline-20260727/results-canonical.csv
```

24 points(mcT 1–16, pipeline 1–8) 전부 `status=ok`다.

## THREE_EXP_20260727

root:

```text
/home/seonung/2026/rdma-results/three-exp-20260727-082205/
```

33 points, 300 files, 단일 실행이다. 전 point `status=ok`.

```text
qpxd-q{1,2,4,8,16}-d{128,64,32,16,8}/   # QP×depth=128 고정 window, 5 points
qpd1-q{1..16}/                          # depth=1 QP scaling, 16 points
plat-p{8,12,16,24,32,48,64}/            # pipeline ladder, 7 points
platt-t{8..12}-p48/                     # mtT=mcT scaling @ argmax pipeline, 5 points
```

## CPU 실험 raw

`md/CPU_COST_ACCOUNTING.md`와 `md/CPU_OPTIMIZATION_ROLLOUT.md`가 참조하는
디렉터리는 각 문서 안에 point별로 나열돼 있다. root는 다음 둘이다.

```text
/home/seonung/2026/rdma-results/cpu-stage-detail-20260724/
/home/seonung/2026/rdma-results/cpu-optimization-20260724/
```

## 모든 raw 원문 출력

아래 명령은 세 실험의 파일을 경로 header와 함께 수정 없이 출력한다.

```bash
roots=(
  /home/seonung/2026/rdma-results/config-matrix-10s-20260724
  /home/seonung/2026/rdma-results/frontier-7point-20260724
  /home/seonung/2026/rdma-results/sensitivity-thread-pipeline-20260727
)

for root in "${roots[@]}"; do
  find "$root" -type f -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      printf '\n===== %s =====\n' "$file"
      cat "$file"
    done
done
```

특정 point만 확인할 때:

```bash
point=/home/seonung/2026/rdma-results/frontier-7point-20260724/candidate-q8-d16-p8

for file in "$point"/*.txt; do
  printf '\n===== %s =====\n' "$file"
  cat "$file"
done
```

