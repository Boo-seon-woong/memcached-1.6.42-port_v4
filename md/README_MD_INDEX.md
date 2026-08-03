# md/ 문서 색인 — 무엇이 현행이고 무엇이 기록인가

작성 2026-08-03. **문서가 21 개라 어느 것을 믿어야 하는지가 문제였다.**
이 파일이 그 답이다.

## 현행 — 지금 값을 여기서 읽는다

| 문서 | 무엇 |
|---|---|
| [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md) | **운영값·기동·부하·측정 규율의 정본.** 여기부터 본다 |
| [`MANUAL_TEST_PROCEDURE.md`](MANUAL_TEST_PROCEDURE.md) | 사람이 손으로 실행하는 단계별 절차 |
| [`V4_RESULT.md`](V4_RESULT.md) | 최종 게이트 + 캠페인 전체 결과(§14 는 121 셀 전수 sweep) |
| [`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md) | **v3→v4 구조 변화**(아키텍처·GET/SET 워크플로 거시) |
| [`COLLABORATION.md`](COLLABORATION.md) | genie 와의 측정 조율 규칙 |

## 코드 경로 — 본문은 v3 기준, 상단 §v4 가 차이를 적는다

| 문서 | 주의 |
|---|---|
| [`GET_WORKFLOW.md`](GET_WORKFLOW.md) | **§v4 를 먼저 읽을 것.** 제출·수거·재개 위치가 바뀌었다 |
| [`SET_WORKFLOW.md`](SET_WORKFLOW.md) | **§v4 를 먼저 읽을 것.** 반환 경로가 바뀌었다 |
| [`GET_SET_CONCURRENCY.md`](GET_SET_CONCURRENCY.md) | v3 시점 대조. 구조 비교 목적이면 유효 |
| [`SPAN_MEASUREMENT_REVIEW.md`](SPAN_MEASUREMENT_REVIEW.md) | span 표본 커버리지 정의. 유효 |

## 시대 기록 — 그 시점의 기록이지 현행이 아니다

전부 상단에 `[… 시점 기록]` 배너가 붙어 있다.

```text
v2   V2_ARCHITECTURE  V2_CODE_SPEC  V2_REMODIFICATION_SPEC  V2_THROUGHPUT_MAXIMIZATION
v3   V3_ARCHITECTURE  V3_REVIEW_FINDINGS  OPTIMIZATION_HISTORY
     SET_CAMPAIGN_HANDOFF  SET_10M_REQUIREMENTS  SET_COST_ATTRIBUTION  CODEX_PROGRESS
v4   V4_DESIGN_CONSTRAINT (착수 전 추정)   V4_RECHECK_PLAN (계획, 결과는 V4_RESULT)
```

**옛 판정을 그대로 인용하지 말 것.** 이 포트에서 `reap`·`ext_setq_max`·
flush-락-밖 **세 손잡이가 지형이 바뀌자 부호를 뒤집었다.** 기각 목록은
영구가 아니다.

## v3 문서를 읽을 때 특히 조심할 것

| v3 서술 | v4 |
|---|---|
| 운영점 `mcT=28 nqp=2 pipeline=160` | `mcT=30 nqp=4 pipeline=256 W=24 reap=8 chain=8` |
| span 수치 (v2 기준) | v3 정의로 재정의 — 직접 비교 불가 |
| `mcT=16 → 6.56 M` | 개선 전 빌드. 현재는 **9.279 M** |
| "완료 1 건당 고정비" | 고정이 아니다. 동시성의 함수 |
| depth=1 천장 0.65 M | v4 에서 **11.5 M** |

## 원 데이터

```text
experiments/full-20260803/cells.csv    전수 sweep 캠페인 121 셀 원장
experiments/prof-20260802/             프로파일·창 추적
tools/ledger.py                        원장 조회 (show / cmp)
tools/exp0-slice.py                    창 슬라이스
tools/exp1-arm.sh                      서버 무장 (실제 서비스 빌드까지 판별)
```
