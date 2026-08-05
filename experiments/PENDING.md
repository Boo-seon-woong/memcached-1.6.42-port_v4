# genie 대기 실험 전체 큐

genie 복귀 시 **이 문서 순서대로** 실행한다. 실행 명세(셀 표·서버 라인·판정
규칙)는 각 블록의 PLAN 에 있고 여기 중복하지 않는다. 순서는 서버 상태 전이
(빌드 교체·PROF 토글·재기동 횟수)를 최소화하도록 짰다.

## 재개 위생 (블록 0 — 부하 전에)

```text
1. manifest.tsv 기록 재개 — 셀 시작·끝 UTC. shape 캠페인 설계 위반 재발 금지
   (shape-20260804/RESULTS.md §6)
2. 추적기 1개만 확인: pgrep -c -f 'shape-trace-v[3].sh'
3. fresh boot 여부 기록 (절대값 주장 셀은 fresh 에서만)
4. 서버·모듈·lib 한 벌 확인 (v4 OPTIMAL_RUNBOOK 로그 게이트)
```

## 실행 블록

| # | 블록 | 셀/부하 | 시간 | 서버 상태 | 채우는 공백 |
|---|---|---|---|---|---|
| 1 | **E0 drain_empty_max 확정** | 8부하 | ~20분 | v4 계측빌드, 재기동 8 | [exp2 PLAN §E0](osdi-0804/exp2/PLAN.md) — 이후 전 블록 값 고정 |
| 2 | **shape 캠페인 마감** | 30셀×3부하 | ~4h | 〃 | **보류(2026-08-06)** — shape RESULTS §6 전체. 재개 시 `tools/night-block2.sh` (KTC 셀 C1-256/128 이 맨 앞) |
| 3 | **v4 게이트 세분 재실행** | 3부하×120s | ~10분 | 〃 (운영값) | KTC §5-③: 게이트 조건에서 p50/p99 + v2내부 + 클라측 동시 기록 |
| 4 | **osdi exp4 batching** | 10구성×3부하 + 저부하 4부하 | ~45분 | 〃, 재기동 10 | [exp4 PLAN](osdi-0804/exp4/PLAN.md) — c1 span 실측 포함 |
| 5 | **지연 분해 정밀 + conn↔depth** | 20부하 × 60초 | ~45분 | 〃 | [exp2 PLAN](osdi-0804/exp2/PLAN.md) (b)(c) — 계층 1·2·3 을 pipeline 전 축 × 두 워크로드로. 블록 2 에서 뺀 시간을 여기 쓴다 |
| 6 | **osdi exp3 값 크기** | 탐침 ≤2 + 15부하 | ~25분 | 〃, 크기별 프리로드 | [exp3 PLAN](osdi-0804/exp3/PLAN.md) |
| 7 | **osdi exp1 port 측** | 24부하 (곡선 21 + zipf 3) + genie CPU 2회 | ~25분 | v4 **PROF=0** 재기동 1 | [exp1 PLAN](osdi-0804/exp1/PLAN.md) |
| 8 | **osdi exp1 stock 측** | 24부하 | ~25분 | **stock 97ceee04** 교체 | 〃 off-box 재측정 (co-located −31.7% 보정 검증) |
| 9 | **v3 소급 블록** | 3×100s + 15×30s | ~35분 | **v3 c8aeae5b** 교체 | KTC §5-①(새 운영점 GET·혼합 span v2) + §5-②(EXP-0 재실행, 수집열 sync/xfer/crypto 추가) |
| 10 | **검증 소셀** | 2부하×30s | ~5분 | v4, inline off | 원인 A 소급 검증: `ext_submit_inline=off ext_submit_batch=3` (스레드당 4연결에서 3은 발화 가능) vs `batch=20` — admit 붕괴 여부. `EXP1_FINDINGS` no-op 시험 주석 근거 |

총 ~6.5 h. 블록 2 이후는 순서 조정 가능하나 **1(E0)이 항상 먼저**고,
서버 교체가 필요한 7~9 는 뒤로 묶는다.

**블록 4~8(osdi)은 경향성 라운드 — 측정당 30초** (관리자 결정 2026-08-05).
절대값·최종 그림용 본측정(60초×3런 규율)은 이 라운드 결과 검토 후 별도
편성한다. 블록 2·3·9 는 각자 기존 규율(캠페인 설계 60초·게이트 120초·
v3 100초)을 따른다.

## 차단 목록 — genie 복귀만으로는 못 하는 것

```text
real-world dataset 셀 (exp1)    키 분포 자산(DPA-Store 사용분) 확보 필요
KTC §5-⑤ v3 클라측 분해         v3 빌드에 srv/que/bk 계측 이식 필요 (소급 불가)
```

## 결과 기입처

**원본은 전부 `experiments/night-20260806/` 에 남긴다** (`tools/night-save.sh`):
`ariel/trace*.csv` 추적기 원본 · `rows.tsv` 절단 결과(계층 1·2·3) ·
`ariel/arm/` 셀별 무장 지문 · `genie/` 클라이언트 raw · `manifest.tsv` 셀 경계.
절단은 결정적이라 절단기를 고치면 과거 셀까지 다시 계산된다 — 그래서 원본을 남긴다.

문서 반영: 블록 3 → KTC §4-1 · 블록 5 → `LATENCY_BREAKDOWN.md` ·
블록 4·6·7·8 → `osdi-0804/exp*/` · 블록 9 → KTC §1-(b)·§2 · 블록 10 →
`EXP1_FINDINGS.md` + `V3_TO_V4_CHANGES.md §2`.
