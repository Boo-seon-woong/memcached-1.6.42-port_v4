# 무인 야간 캠페인 — 2026-08-06

관리자 지시(2026-08-06 02:0x KST): 대기 큐 전체를 아침까지 중단 없이 완주.
순서는 [`../PENDING.md`](../PENDING.md) 야간 실행 순서 `1→3→4→5→6→10→7→8→9→2`.

```text
빌드    c11ede3ebd2a45d8f32e9943  (블록 8 stock·9 v3 제외 전 블록 공용)
        직전 배포본 be6b7804 은 로컬 HEAD 보다 낡아 지문 3종이 안 나왔다
추적    guest /tmp/night/trace.csv, 1초 간격 42열, 부하 시작마다 stats reset
절단    tools/night-slice.py trace.csv manifest.tsv  (평탄부 1개 = 행 1개)
경계    manifest.tsv — 셀 라벨과 GO 직전 epoch
```

## 이 캠페인에서 먼저 고친 것 (측정 전)

| 고친 것 | 왜 |
|---|---|
| 지문 노출 3종 + `ext_drain_empty_max` | 블록 1 의 노브가 `stats` 에 안 보여 셀 확정 불가였다 |
| 추적기 26열 → 42열 | `srv/que/bk`·`xfer/crypto/sync` 가 없어 블록 3 요구(계층 2·3)를 못 채운다 |
| 부하 시작마다 `stats reset` | p50/p99 는 히스토그램이라 차분 불가 — 리셋 없으면 둘째 셀부터 앞 셀이 섞인다 |
| `obwatch.sh` 첫 행 DT | 기준 시각만 `%s` 로 잘려 첫 행이 절반으로 찍혔다. genie 의 램프 추정(−1.66%)이 이 행에서 나왔다 |

## 블록 진행

| # | 블록 | 상태 | 결과 |
|---|---|---|---|
| 1 | E0 `ext_drain_empty_max` | **완료** | **DEM=0 유지.** 4/16/64 가 pipe32 −8.11/−5.65/−4.61%, 저부하 이득 없음 → [exp2 PLAN §E0](../osdi-0804/exp2/PLAN.md) |
| 3 | v4 게이트 재실행 (3×120s) | 진행 중 | KTC §5-③ (p50/p99 + 계층 2·3 동시) |
| 4 | osdi exp4 batching (10구성) | 대기 | |
| 5 | osdi exp2 (b)(c) | 대기 | |
| 6 | osdi exp3 값 크기 | 대기 | |
| 10 | 원인 A 검증 | 대기 | |
| 7 | osdi exp1 port (24셀) | 대기 | |
| 8 | osdi exp1 stock (24셀) | 대기 | |
| 9 | v3 소급 (KTC §5-①②) | 대기 | |
| 2 | shape 마감 (30셀) | 대기 — 남는 시간만큼 | 부분 완주도 셀 단위로 유효 |

## 램프 편향 — 규약이 바뀌었다

genie 가 30초 창 램프를 직접 재서 **0.063 초분 = −0.21%** 로 확정했다.
이전 규약의 −1.66% 는 위 obwatch 결함에서 나온 과대추정이라 폐기.
교차비교 보정(30↔60 +0.10%p / 30↔120 +0.16%p)은 σ 1.0% 아래라 **적용하지
않고 각주만** 단다.

## 구동기

```text
tools/night-arm.sh      무장 + 프리로드 + 지문 (게이트 셋 실패시 중단)
tools/night-cell.sh     GO 커밋 → genie 응답 대기
tools/night-block2.sh   shape 30셀 (셀마다 재기동)
tools/night-block4.sh   exp4 10구성
tools/night-block6.sh   exp3 상한 탐침 + 4 크기
tools/night-exp1msg.sh  exp1 24셀 GO 생성 (PT/ST)
tools/night-slice.py    사후 절단
```
