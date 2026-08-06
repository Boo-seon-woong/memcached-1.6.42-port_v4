# semi_final 실험 계획

실험 7개 — 변인 6개(pipeline · thread · value_size · ext_post_chain · nqp ·
ORD)를 운영점에서 **하나씩만** 흔들고, 7번은 곱(nqp×ORD)을 256 으로 고정한
채 형태만 바꾼다. baseline 없음 — stock 대조군도, 별도 기준 셀도 없다.
운영점(OP)은 전 축이 공유하는 교차점일 뿐이며 캠페인에서 **한 번만** 돈다
(맨 끝 재시행 1회 제외).

## 0. 고정 조건 (전 셀 공통 — 각 축이 자기 변인만 바꾼다)

```text
빌드    c11ede3ebd2a45d8f32e9943  (게스트 ~/coherent-mr-v2/bin/memcached)
서버    -p 11411 -U 0 -t 30 -m 2048 -c 16384 -R 1024, taskset 0-29
        W=1280 nqp=4 ORD=0(협상16) chain=8 reap=8 admit_max=0 setq_max=1
        submit_inline, drain_spin=1024, DEM=0, hashpower=22
환경    MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1
        EXT_SLOT_SIZE=256 EXT_READ_SLOTS=1280

        ★ 동시성 상한은 nqp×ORD 하나다 (관리자 결정 2026-08-06).
        나머지 상한 셋은 전부 비구속으로 연다: W=1280·slots=1280 은 캠페인
        내 곱 최대(64×16=1024)보다 크고, admit_max=0 은 무제한이다
        (admit_max 도 워커당 상주 상한이다 — memcached.c:3181).
        이 때문에 OP 실효 깊이가 64 가 되어 08-03 게이트(W=24·admit=64,
        실효 24)와 절대값이 다르게 나온다 — 정상이다
부하    genie off-box. memtier -s 10.99.0.3 -p 11411 -P memcache_text
        -t 30 -c 4 --pipeline=256 -d 64 --key-prefix=m-
        --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R
        --distinct-client-seed --hide-histogram --test-time=60
키공간  1,000,000 × d.  프리로드: 재기동·크기 변경 직후 매번
        (memtier 로컬 P:P 1:0, threads=8 clients=16 pipe=8 -n 7813)
시간    부하 60초, 사이 20초.  구성마다 워크로드 3종: -GET(0:1) -MIX(1:9) -SET(1:0)
채널    conversation.md 에 GO/DONE. GO 맨 위에 SERVER: 줄(판별자 포함) 필수
기록    guest 추적기 42열 1초(/tmp/semifinal/trace.csv, RESET_ON_LOAD=1)
        + manifest.tsv(라벨, GO 직전 epoch) + genie DONE 줄(avg/p50/p99/p99.9)
        절단 tools/night-slice.py → rows.tsv, 클라 tools/parse-client.py → client.tsv
저장    experiments/semi_final/{rows.tsv, client.tsv, manifest.tsv, ariel/, genie/}
게이트  무장마다: coherent MR 2줄 · stats 지문 일치 · curr_items 1,000,000
        · ext_pac_fallback 0.  셀 유효 조건: err5 0, uniform hit 100%
```

## 1. 실험과 값

| # | 실험 | 값 (굵게 = OP) | 신규 구성 | 바꾸는 방법 | nqp × ORD |
|---|---|---|---:|---|---|
| 1 | pipeline | 1, 8, 32, 64, 128, **256**, 384, 512 | 7 | 클라 `--pipeline` 만 | 4 × 16 = 64 |
| 2 | thread (mcT=mtT) | 1, 2, 4, 8, 12, 16, 24, 28, **30** | 8 | 재기동: `-t m`, `taskset 0-(m−1)`, genie `-t m` | 4 × 16 = 64 |
| 3 | value_size | 16, 32, **64**, 128, CAP(156↘152) | 4 | flush + `-d` 재프리로드, 부하도 같은 `-d` | 4 × 16 = 64 |
| 4 | ext_post_chain | 1~16 전 정수 (**8** 제외 15개 신규) | 15 | 재기동: `-o ext_post_chain=c` (reap=8 유지) | 4 × 16 = 64 |
| 5 | nqp | 1, 2, **4**, 8, 16, 64 | 5 | 재기동: `ext_qp_per_worker=q` (ORD=협상16) | ×16 = 16, 32, **64**, 128, 256, 1024 |
| 6 | ORD | 1, 2, 4, 8, **협상16**, 32, 64 | 6 | 재기동: `ext_ord_limit=o` 핀 (nqp=4) | 4× = 4, 8, 16, 32, **64**, 128, 256 |
| 7 | 형태 (곱 256 고정) | 1×256, 2×128, 4×64†, 8×32, 16×16†, 32×8, 64×4 | 5 | 재기동: q·o 를 함께 변경 (곱 = 256 유지) | 256 고정 |

† 재사용: 4×64 = SF-O64(6번 축), 16×16 = SF-Q16(5번 축 — 협상16 과 핀16 은
같은 상한값, 기동 배너만 negotiated/pinned 로 다르다).

- CAP 확정 규칙: `-d 156` 프리로드 후 `ext_pac_fallback` 이 0 이면 156,
  아니면 152. 추가 탐침 없음.
- nqp 축과 ORD 축은 둘 다 곱을 바꾸지만 **형태가 다르다** — 곱이 같아도
  성능이 다를 수 있다. 곱 16: SF-Q1(1×16) vs SF-O4(4×4). 곱 128:
  SF-Q8(8×16) vs SF-O32(4×32). 곱 256 전 형태는 7번 축이 덮는다.
- ORD 핀 > 협상16 은 초과분이 SQ 에 쌓인다(`extstore.c:650` — wire 는 QP당
  16 만 나간다). 실행에는 문제 없고, 그 대기도 측정 대상이다.
- nqp=64 는 총 QP 30×64 = 1,920 이다. 실기동 확인 최대는 v3 의 896 —
  무장 게이트가 실패하면 그 구성만 건너뛰고 기록한다(조용히 축소 금지).

## 2. 실행 순서 (재기동 최소화 순. 이대로 위에서 아래로)

```text
0  무장 OP + 프리로드(d=64) + 게이트    tools/night-arm.sh: INLINE=1 AD=0 RE=8 PC=8 DEM=0 → 20 1280 4 1280
1  SF-OP                    3부하       전 축의 공용점 (pipe=256). 재기동 없음
2  SF-P{1,8,32,64,128,384,512}   7×3   클라만 변경. 재기동 없음
3  value 축   탐침: flush → d=156 프리로드 → fallback 확인 → CAP 확정
   SF-D{16,32,128,CAP}      4×3        크기마다 flush+프리로드. 부하 -d 동일
4  SF-C{1..7,9..16}         15×3       재기동 15회: PC=c RE=8 → 20 1280 4 1280, 매회 d=64 프리로드+게이트
5  SF-Q{1,2,8,16,64}        5×3        재기동 5회: → 20 1280 q 1280 (ORD=0 협상)
6  SF-O{1,2,4,8,32,64}      6×3        재기동 6회: ORD=o 핀 → 20 1280 4 1280
7  SF-S{1x256,2x128,8x32,32x8,64x4}  5×3   재기동 5회: ORD=o 핀 → 20 1280 q 1280
8  SF-T{1,2,4,8,12,16,24,28}     8×3   재기동 8회: MCT=m CPUSET=0-(m−1) → 20 1280 4 1280, genie -t m
9  SF-OP-r2                 3부하       OP 재무장(재기동 1회) 후 1과 동일 조건
```

OP 재시행 판정: |OP − OP-r2| ≤ 3%(재기동 편차) 면 정상. 초과하면 전 축의
절대값 비교에 주의 표기를 달고 어긋난 쪽을 1회 재측정한다 — exp4 에서 운영점
셀 하나가 −2.8% 낮게 나와 결론이 두 번 뒤집힌 전례가 있다.

각 GO 는 한 구성의 3부하(-GET → -MIX → -SET 순서 고정)를 묶고, genie 의
해당 구성 마지막 셀(-SET) 보고를 확인한 뒤 다음 무장으로 넘어간다.
재기동 구성은 무장 게이트(§0) 통과 후에만 GO 를 올린다.

## 3. 규모

```text
부하    (1+7+4+15+5+6+5+8+1) = 52 구성 × 3 = 156 부하 × 80초   ≈ 208분
재기동  40회 (+프리로드)                                       ≈ 100분
value flush/프리로드 5회(탐침 포함)                             ≈ 6분
합계                                                           ≈ 5.2 h
```

주: 재기동 간 처리량 편차 ±3% 실측 — 축 안에서는 형태·방향을 읽고, 절대값
주장은 본측정(60초×3런 교대)으로 넘긴다.
