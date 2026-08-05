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
| 2 | **shape 캠페인 마감** | 29셀×3부하 + 재측정 8부하 | ~3h | 〃 | shape RESULTS §6 전체: A16-5, A 곱32/64/128(15), B(7), C2(6), A16-2·C1-128·**C1-256** 서버창, C1 클라 p50/p99 보충 → KTC §5-④ |
| 3 | **v4 게이트 세분 재실행** | 3부하×120s | ~10분 | 〃 (운영값) | KTC §5-③: 게이트 조건에서 p50/p99 + v2내부 + 클라측 동시 기록 |
| 4 | **osdi exp4 batching** | 10구성×3부하 + 저부하 4부하 | ~45분 | 〃, 재기동 10 | [exp4 PLAN](osdi-0804/exp4/PLAN.md) — c1 span 실측 포함 |
| 5 | **osdi exp2 (b)(c)** | 1 + 6부하 | ~10분 | 〃 | [exp2 PLAN](osdi-0804/exp2/PLAN.md) — E0 값 반영 저부하 분해, conn↔depth |
| 6 | **osdi exp3 값 크기** | 탐침 ≤2 + 15부하 | ~25분 | 〃, 크기별 프리로드 | [exp3 PLAN](osdi-0804/exp3/PLAN.md) |
| 7 | **osdi exp1 port 측** | 24부하 (곡선 21 + zipf 3) + genie CPU 2회 | ~25분 | v4 **PROF=0** 재기동 1 | [exp1 PLAN](osdi-0804/exp1/PLAN.md) |
| 8 | **osdi exp1 stock 측** | 24부하 | ~25분 | **stock 97ceee04** 교체 | 〃 off-box 재측정 (co-located −31.7% 보정 검증) |
| 9 | **v3 소급 블록** | 3×100s + 15×30s | ~35분 | **v3 c8aeae5b** 교체 | KTC §5-①(새 운영점 GET·혼합 span v2) + §5-②(EXP-0 재실행, 수집열 sync/xfer/crypto 추가) |
| 10 | **검증 소셀** | 2부하×30s | ~5분 | v4, inline off | 원인 A 소급 검증: `ext_submit_inline=off ext_submit_batch=3` (스레드당 4연결에서 3은 발화 가능) vs `batch=20` — admit 붕괴 여부. `EXP1_FINDINGS` no-op 시험 주석 근거 |

총 ~6.5 h. 블록 2 이후는 순서 조정 가능하나 **1(E0)이 항상 먼저**고,
서버 교체가 필요한 7~9 는 뒤로 묶는다.

### 2026-08-06 무인 야간 실행 순서 (관리자: 아침까지 완주)

```text
1 → 3 → 4 → 5 → 6 → 10 → 7 → 8 → 9 → 2
```

기본 순서에서 **블록 2(shape 마감, ~3h)를 맨 뒤로** 뺐다. 근거 둘:
KTC 0806 이 오늘이라 그 공백을 메우는 3·9 가 앞서야 하고, 2 를 두 번째로
두면 나머지 여덟 블록이 밤을 못 넘긴다. 2 는 v4 내부 완결성 항목이라
부분 완주도 그대로 쓸모가 있다(셀 단위 독립). 바이너리 교체는
10(v4) → 7(v4 PROF=0) → 8(stock) → 9(v3) → 2(v4) 로 한 번씩만 지나간다.

빌드: 전 블록 `c11ede3ebd2a45d8f32e9943` (8 stock·9 v3 제외).
`ext_drain_empty_max` / `ext_qp_per_worker` / `ext_ord_limit` / `ext_read_slots`
지문 노출 추가분 포함 — 이전 배포본(`be6b7804`)에는 없었다.

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

블록 2 → `shape-20260804/{rows.tsv,RESULTS.md}` · 블록 3 → KTC §4-1 갱신 ·
블록 4~8 → `osdi-0804/exp*/{ariel,genie,rows.tsv}` · 블록 9 → KTC §1-(b)·§2 갱신 ·
블록 10 → `EXP1_FINDINGS.md` 주석.
