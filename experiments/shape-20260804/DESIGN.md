# 동시성 형태 실험 — v4 재실험 설계

원 설계: `port_v3/md/CONCURRENCY_SHAPE_EXPERIMENT.md` (2026-07-31 시행)
원 결과: `port_v3/experiments/shape-20260731/`

**v3 실험을 그대로 재현하지 않는다.** v3 실험은 v3 운영점을 기준점으로 삼고
거기서 변인을 통제한 것이므로, v4 에서는 **v4 운영점을 기준점으로** 잡아야
같은 성격의 실험이 된다.

---

## 0. 무엇이 달라지는가

### 0-1. 기준점

| | v3 실험 | v4 재실험 |
|---|---|---|
| mcT | 28 | **30** (`taskset 0-29`) |
| W | 24 | **24** |
| nqp | 2 | **4** |
| pipeline | 160 | **256** |
| reap / chain | 없음 | **8 / 8** |
| submit_inline | 없음 | **on** |
| admit_max | 없음 | **64** |

### 0-2. 측정 항목 — 여기가 이번 재실험의 핵심이다

v3 는 서버 span 의 `avg` 와 `p99` 만 기록했다. v4 는 여덟 가지를 전부 낸다.

```text
① span p99          ② span p50          ③ span avg
④ client latency avg ⑤ client p50        ⑥ client p99
⑦ span latency breakdown
⑧ client-side latency breakdown
```

⑦⑧ 은 2026-08-04 에 추가한 계측으로 처음 가능해졌다
(`extstore_prof_{srv,que,bk}_*`, `md/LATENCY_BREAKDOWN.md`).

**⑦ span breakdown** — 계약이 재는 구간의 내부:

```text
span v3 = admit + xfer + crypto + sync + 나머지        (GET)
        = admit + xfer + crypto + sync + ret           (SET)
```

**⑧ client breakdown** — 클라이언트가 체감하는 전체:

```text
client latency
├ 네트워크 + 클라이언트 큐잉      = client_avg − srv
└ srv  (소켓 read → sendmsg)
   ├ que   read → 명령 시작        파이프라인 앞선 명령 대기
   ├ pre   명령 → backend 진입     파싱·해시
   ├ span v3                       ← 계약이 재는 전부
   └ post  v3 완료 → sendmsg       비동기 재개 대기
```

### 0-3. 실험 A 확장

v3 는 곱(`nqp × ORD`)을 **16 하나**로만 고정했다. v4 는 **16 / 32 / 64 / 128
네 개**로 늘린다. 곱 하나로는 "형태가 문제인가"만 답하고 "총량이 어디서
포화하는가"에는 답하지 못한다.

---

## 1. 실험 A — 총 동시성 고정, 분배 형태만 변경

**질문 1**: 워커당 실효 동시성이 같을 때, 그것이 몇 개의 QP 에 나뉘어 실리는지가
throughput·span·client latency 에 영향을 주는가.
**질문 2**(v4 추가): 그 답이 총량(곱)에 따라 달라지는가.

`W = P` 로 두어 W 가 묶지 않게 하고, `EXT_READ_SLOTS=256` 으로 바운스 슬롯도
묶지 않게 한다(`extstore.c:774` — `bounce_slots = read_slots` 가 동시성 상한이다).

| 곱 P | 셀 | nqp | ORD | 총 QP (mcT=30) |
|---:|---|---:|---:|---:|
| **16** | A16-1 … A16-5 | 1 / 2 / 4 / 8 / 16 | 16 / 8 / 4 / 2 / 1 | 30 / 60 / 120 / 240 / 480 |
| **32** | A32-1 … A32-5 | 2 / 4 / 8 / 16 / 32 | 16 / 8 / 4 / 2 / 1 | 60 / 120 / 240 / 480 / 960 |
| **64** | A64-1 … A64-5 | 4 / 8 / 16 / 32 / 64 | 16 / 8 / 4 / 2 / 1 | 120 / 240 / 480 / 960 / 1920 |
| **128** | A128-1 … A128-5 | 8 / 16 / 32 / 64 / 128 | 16 / 8 / 4 / 2 / 1 | 240 / 480 / 960 / 1920 / **3840** |

**20 셀 × 워크로드 3 = 60 측정.**

`ORD` 상한을 16 으로 둔 이유: HCA 협상값이 16 이다. **핀하면 그 이상도
받는다** — `extstore.c:650` 이 "초과분은 SQ 에 쌓이며 그것도 측정 가능한
결과"라고 적고 있다. 다만 그건 다른 실험이므로 여기서는 16 을 넘기지 않고,
곱을 키울 때 nqp 쪽으로만 간다.

### 1-1. 선행 확인이 필요하다 — A128-5 는 3,840 QP 다

v3 가 실기동을 확인한 최대는 **896 QP**(nqp=32, mcT=28)였다. A128-5 는 그
**4.3 배**다. 캠페인을 시작하기 전에 극단 셀 넷을 먼저 띄워 본다:

```text
A16-1    nqp=1   ORD=16   30 QP
A128-1   nqp=8   ORD=16  240 QP
A128-4   nqp=64  ORD=2  1920 QP
A128-5   nqp=128 ORD=1  3840 QP     ← 여기서 막히면 곱 128 은 nqp≤64 로 자른다
```

genie 측 CM 연결 수용량도 같이 본다(v3 는 896 을 받았다).
**막히면 설계를 줄이고 그 사실을 결과에 적는다 — 조용히 빼지 않는다.**

---

## 2. 실험 B — QP당 depth 1 고정, QP 개수 증가

**질문**: QP 당 큐잉을 없앤 상태에서 QP 를 늘리면 어디까지 선형인가.

`ext_ord_limit=1` 고정, `W=64`, `EXT_READ_SLOTS=256`.

| 셀 | nqp | 총 QP (mcT=30) |
|---|---:|---:|
| B1 | 1 | 30 |
| B2 | 2 | 60 |
| B3 | 4 | 120 |
| B4 | 8 | 240 |
| B5 | 16 | 480 |
| B6 | 32 | 960 |
| B7 | 64 | 1920 |

v3 대비 **B7 을 추가**했다 — A 의 곱 128 과 맞물리는 지점을 보기 위해서다.
**7 셀 × 3 = 21 측정.**

v2 는 depth=1 천장이 QP 와 pipeline 에 무관하고 **완료 1 건당 비용**이
결정한다고 기록했다. v4 에서 그 비용이 또 줄었으므로(`post` 계측이 새로
생겼다) 천장이 올라가야 한다. **안 올라가면 그 해석이 틀린 것이다.**

---

## 3. 실험 C — pipeline 포화점, 그 다음 thread 확장

### C-1. pipeline sweep (서버 재기동 불필요)

운영점 고정 `mcT=30 W=24 nqp=4 reap=8 chain=8`, memtier `-t 30 -c 4`.

| 셀 | pipeline | 명목 in-flight (120 conn) |
|---|---:|---:|
| C1-1 | 1 | 120 |
| C1-2 | 8 | 960 |
| C1-3 | 32 | 3,840 |
| C1-4 | 64 | 7,680 |
| C1-5 | 128 | 15,360 |
| C1-6 | 256 | 30,720 ← 운영점 |
| C1-7 | 384 | 46,080 |

**2026-08-04 에 1/8/32/128/256 을 이미 쟀다**(`md/LATENCY_BREAKDOWN.md`).
64 와 384 만 채우면 7 점이 된다 — 그 두 셀만 새로 요청한다.

### C-2. thread 확장 (포화점에서)

C-1 의 포화 pipeline 을 고정하고 `mtT = mcT` 를 함께 올린다.

| 셀 | mcT (`-t`, `taskset 0-(mcT−1)`) | mtT (genie `-t`) |
|---|---:|---:|
| C2-8 | 8 | 8 |
| C2-12 | 12 | 12 |
| C2-16 | 16 | 16 |
| C2-20 | 20 | 20 |
| C2-24 | 24 | 24 |
| C2-30 | 30 | 30 ← 운영점 |

**6 셀 × 3 = 18 측정.**

---

## 4. 워크로드와 측정 규약

셀마다 아래 순서로 3 회. **GET-only 를 먼저** — SET 이 섞인 뒤의 GET 을 재는
순서 효과를 만들지 않기 위해서다.

| # | 워크로드 | `--ratio` | 읽을 것 |
|---|---|---|---|
| W1 | GET only | `0:1` | ops/s, GET span avg/p50/p99, breakdown |
| W2 | 1:9 혼합 | `1:9` | ops/s(합), GET·SET span, breakdown |
| W3 | SET only | `1:0` | ops/s, SET span avg/p50/p99, breakdown |

> `--ratio` 는 **SET:GET** 순서다. 계약 문구는 `1:10` 이고 이 실험은 `1:9` 다
> — **게이트 수치와 직접 비교하지 말 것**(비율 차이만으로 약 1.4%).
> **v3 실험에서 W3(SET-only)이 빠진 적이 있다.** v4 는 세 워크로드를 다 돈다.

### 공통 부하

```sh
memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \
  --distinct-client-seed --hide-histogram \
  -t <mtT> -c 4 --pipeline=<P> --ratio=<R> --test-time=120
```

### 창 규약

- **부하 120 초, 측정 창 60 초.** 창은 부하 안쪽에 잡는다.
- **창은 부하가 오르기 전에 연다.** 전속 중에 `stats reset` 이 돌면
  `get_cmds`(`thread.c:1055`)와 `get_hits`(`thread.c:1064` memset)가 서로 다른
  시점에 0 이 되고 증가 쪽은 락이 없어(`THR_STATS_LOCK` no-op,
  `memcached.h:989`) 창 총계가 부풀어 오른다. **실측으로 8.45% 오차를 봤다.**
- **커버리지가 밴드(−1.0 ~ +0.2%) 밖이면 창 총계를 버리고 안정구간(10s~)
  초당 행을 쓴다.** 이 규칙은 `BD-PROF-ON-MIX-r1` 에서 검증됐다
  (총계 11.865 M / 행 10.961 M / 클라이언트 10.926 M).
- **서버 측이 authoritative**, 클라이언트 수치는 교차검증 — 다만 **client
  latency 는 클라이언트만 낼 수 있으므로 memtier 값이 정본**이다.
- correctness 5 종이 0 이어야 유효:
  `get_misses / read_failures / write_failures / engine_dead / slot_acct_leak`.
  혼합의 `badcrc` 는 0 이 아닐 수 있다(재시도로 회수, `get_misses=0` 이면 정상).

### 계측 비용

`EXT_RDMA_PROF=1` 은 처리량을 **약 4.2%** 깎는다(2026-08-04 A/B: GET 4.30%,
혼합 4.10%). **전 셀을 켠 채로 돈다** — 셀 간 비교가 목적이므로 일정하면 된다.
절대값을 계약 기록 옆에 놓을 때만 이 4.2% 를 명시한다.

---

## 5. 셀당 기록 형식

```text
cell | mtT mcT nqp ORD W pipe | workload | ops/s
     | Gspan avg/p50/p99 | Sspan avg/p50/p99
     | client avg/p50/p99
     | srv que pre post | admit xfer crypto sync (ret)
     | busyCPU | err5 badcrc | 커버리지
```

thread 열은 **mtT/mcT/nqp 를 각각** 적고 합계 열을 만들지 않는다.

---

## 6. 디렉터리

```text
DESIGN.md      이 문서
README.md      배치와 읽는 법
RESULTS.md     실험별 결과 표
FINDINGS.md    해석과 반증 결과
manifest.tsv   셀 → 시작 UTC epoch (절단 기준)
rows.tsv       파싱된 측정 행
ariel/         서버 raw (obwatch 전문 + 서버 명령줄)
genie/         클라이언트 raw (memtier 표준출력 전문)
```

**중간 점검 시 절단 주의** — 셀 경계는 `manifest.tsv` 시각으로만 나눈다.
캠페인 진행 중에 자르면 직전 셀의 잔여 부하가 다음 구간에 떨어진다
(v3 에서 `OPT-base` 중복 실행이 `OPT-pipe` 구간에 섞인 전례).

---

## 7. 규모와 순서

```text
A   20 셀 × 3 = 60 측정
B    7 셀 × 3 = 21
C1   2 셀 × 3 =  6   (5 점은 2026-08-04 에 이미 측정)
C2   6 셀 × 3 = 18
                ───
                105 측정 × 약 2.5 분 ≈ 4.5 시간
```

**순서**: 선행 확인(§1-1) → A → C1 잔여 → C2 → B.

A 를 먼저 두는 이유는 사용자가 확장을 지정한 실험이기 때문이고, B 를 뒤로
두는 이유는 A 의 곱 128 결과가 B7 의 필요 여부를 알려주기 때문이다.

---

## 8. 이 실험이 반증하려는 것

| 실험 | 가설 | 반증 조건 |
|---|---|---|
| A | 실효 동시성은 곱으로만 결정되고 분배 형태는 무관하다 | 같은 곱 안에서 셀 간 차이가 2σ(2%)를 넘는다 |
| A | 그 성질이 곱에 무관하다 | 곱 16 에서는 평탄한데 128 에서는 갈린다(또는 반대) |
| B | depth=1 천장은 완료 1 건당 비용이 정하고 QP 수와 무관하다 | nqp 를 늘려 천장이 올라간다 |
| C1 | 처리량 포화가 span 계약보다 먼저 온다 | span 이 30 µs 를 먼저 넘는다 |
| C2 | mcT=30 이 최적이고 그 위는 안 쟀다 | 30 미만에서 더 높은 점이 나온다 |

**예측은 셀 요청 시 `±2σ` 로 채널에 적어 보낸다.** 틀렸을 때가 더 값지다 —
v4 캠페인에서 `r14c12` 가 `v2 ← reap` 모형을, `A4` 가 `min(chain,reap,ORD)` 를
반증했고, 키 분포 실험에서는 내 예측이 두 번 연속 부호까지 틀렸다.
