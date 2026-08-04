# 동시성 형태 캠페인 v4 — raw 보관

설계: [`DESIGN.md`](DESIGN.md) · 결과: [`RESULTS.md`](RESULTS.md) ·
해석: [`FINDINGS.md`](FINDINGS.md)

원 실험은 `port_v3/experiments/shape-20260731/` 이다. **그것의 재현이 아니라
v4 운영점을 기준점으로 다시 설계한 것**이므로 셀 이름과 파라미터가 다르다.
비교할 때는 절대값이 아니라 개형을 본다.

```text
DESIGN.md      설계·규약·반증 조건
RESULTS.md     실험별 결과 표
FINDINGS.md    해석. 예측이 맞았는지 틀렸는지 포함
manifest.tsv   셀 → 시작 UTC epoch. 절단은 이 시각으로만 한다
rows.tsv       파싱된 측정 행 (서버 측이 authoritative)
ariel/         서버 raw — obwatch 전문 + 서버 명령줄
genie/         클라이언트 raw — memtier 표준출력 전문
```

## `rows.tsv` 열

```text
cell  workload  window_s
get/s  set/s  total_Mops
Gspan_avg  Gspan_p50  Gspan_p99
Sspan_avg  Sspan_p50  Sspan_p99
client_avg  client_p50  client_p99
srv  que  pre  post
admit  xfer  crypto  sync  ret
busyCPU  err5  badcrc  hit%  coverage
```

**v3 대비 늘어난 열**: span 의 `p50`, 클라이언트 지연 3 종,
`srv/que/pre/post`(클라이언트 지연 분해), `admit/xfer/crypto/sync/ret`
(span 내부 분해), `coverage`.

`err5` = `get_misses + read_failures + write_failures + engine_dead +
slot_acct_leak`. **0 이 아니면 그 행의 성능 수치는 무효다.**
`badcrc` 는 혼합에서 0 이 아닐 수 있고 재시도로 회수되므로 그 자체로는
무효 사유가 아니다(`get_misses=0` 이면 정상).

## 이 캠페인에서 특별히 주의할 것 둘

**① 창을 부하 시작 전에 연다.** 전속 중에 열면 `stats reset` 경계에서 창
총계가 부풀어 오른다 — 실측 8.45% 오차를 봤다. `coverage` 열이 밴드
(−1.0 ~ +0.2%) 밖이면 **총계를 버리고 안정구간(10s~) 초당 행을 쓴다.**

**② 계측이 처리량을 4.2% 깎는다.** 전 셀을 `EXT_RDMA_PROF=1` 로 돌리므로
셀 간 비교는 유효하다. 계약 기록 옆에 절대값을 놓을 때만 이 4.2% 를 명시한다.
