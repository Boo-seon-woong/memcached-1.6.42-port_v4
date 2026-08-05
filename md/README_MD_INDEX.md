# md/ 문서 색인

2026-08-04 갱신. **시대 기록 14 개를 삭제하고 9 개만 남겼다**(9,126 → 4,228 행).
지운 것은 최종본에 기여하지 않는 v2·v3 과정 기록과 v4 착수 전 계획이다.
전부 git 이력에 남아 있으므로 필요하면 `git log --diff-filter=D -- md/` 로 찾는다.

## 현행

| 문서 | 무엇 |
|---|---|
| [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md) | **운영값·기동·부하·측정 규율의 정본.** 여기부터 본다 |
| [`MANUAL_TEST_PROCEDURE.md`](MANUAL_TEST_PROCEDURE.md) | 사람이 손으로 실행하는 단계별 절차 |
| [`V4_RESULT.md`](V4_RESULT.md) | 최종 게이트 + 캠페인 전체 결과(§14 는 123 셀 전수 sweep) |
| [`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md) | **v3→v4 단독 완결 문서** — span 정의·문제 원인·해결·구조·결과 |
| [`KTC_0806_SPAN.md`](KTC_0806_SPAN.md) | **KTC 0806 보고 (목표 1)** — 0731 3막(이중게이트→재조정→재정의)→EXP-0 분해→해결→v4. 공백은 §5 측정 목록으로 |
| [`GET_WORKFLOW.md`](GET_WORKFLOW.md) | GET 코드 경로. **§v4 를 먼저 읽을 것** — 본문은 v3 기준 |
| [`SET_WORKFLOW.md`](SET_WORKFLOW.md) | SET 코드 경로. **§v4 와 §1-pac 을 먼저** — 본문 §1 은 동기 대조군 |
| [`SPAN_MEASUREMENT_REVIEW.md`](SPAN_MEASUREMENT_REVIEW.md) | 계측 검증. **§1~§6 은 span v2, v3 검증은 §7** |
| [`EXTENDED_SPAN_DIAGNOSIS.md`](EXTENDED_SPAN_DIAGNOSIS.md) | **span v2→v3 확장의 측정·분해·해결.** v3 워크플로를 몰라도 읽힌다 |
| [`LATENCY_BREAKDOWN.md`](LATENCY_BREAKDOWN.md) | **클라이언트 지연 전체 분해.** 계약은 그 0.9% 만 잰다 |
| [`COLLABORATION.md`](COLLABORATION.md) | genie 와의 측정 조율 규칙 |

## 원 데이터

```text
experiments/PENDING.md                 genie 대기 실험 전체 큐 — 복귀 시 이 순서대로
experiments/osdi-0804/                 OSDI 실험 — 공통 규약 + exp1~4 개별 PLAN
experiments/shape-20260804/            형태 캠페인 v4 — 설계·결과·해석·raw
                                       (2026-08-04 genie 중단으로 미완. RESULTS §6 참조)
experiments/full-20260803/cells.csv    전수 sweep 캠페인 123 셀 원장
experiments/exp0-20260801/FINDINGS.md  span v3 폭증 원인 규명 (두 조건문)
experiments/prof-20260802/             프로파일·창 추적
tools/ledger.py                        원장 조회 (show / cmp)
tools/exp1-arm.sh                      서버 무장 (실제 서비스 빌드까지 판별)
```

## 남은 두 문서를 읽을 때

`GET_WORKFLOW`·`SET_WORKFLOW` 는 **본문이 v3 기준이고 상단 §v4 가 차이를 적는
구조**다. 통합하지 않은 이유는 단계별 코드 위치가 대부분 그대로이고, 바뀐
지점만 대비시키는 편이 오독을 덜 낳기 때문이다. 본문 수치를 인용할 때는
반드시 §v4 와 대조할 것.

## v3 서술을 만나면

| v3 | v4 |
|---|---|
| 운영점 `mcT=28 nqp=2 pipeline=160` | `mcT=30 nqp=4 pipeline=256 W=24 reap=8 chain=8` |
| span 수치 (v2 정의) | v3 정의로 재정의 — 직접 비교 불가 |
| "SET 은 동기, 워커를 점유한다" | pac 이 없앴다. SET 도 비동기 |
| depth=1 천장 0.65 M | v4 에서 **11.5 M** |

**옛 기각 목록을 영구로 읽지 말 것.** `reap`·`ext_setq_max`·flush-락-밖
세 손잡이가 지형이 바뀌자 부호를 뒤집었다.

## 정독 감사 기록 (2026-08-03)

당시 23 개를 **전부 읽고** 고쳤다. 그 전에 grep 기반 감사를 두 번 했고
**두 번 다 "이상 없음"으로 잘못 결론냈다** — 기계 검색은 "수치가 틀렸다"는
잡지만 "문장이 다른 것을 설명한다"는 못 잡는다.

**공통 형태**: 원 분석(EXP-0 FINDINGS, 캠페인 셀, 코드)은 정확한데 **요약이
원본을 대신하면서 틀렸다.** 그래서 요약마다 **원본 링크와 코드 위치**를
박아 넣는 방향으로 고쳤다.
