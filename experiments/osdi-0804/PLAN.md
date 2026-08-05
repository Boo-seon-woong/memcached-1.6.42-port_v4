# OSDI 실험 — 공통 규약과 색인

실험별 계획은 각 디렉터리의 PLAN.md 다. **이 문서는 공통 규약만 갖는다.**
실행 순서 정본은 [`../PENDING.md`](../PENDING.md).

| 실험 | 계획 | 그림 원형 |
|---|---|---|
| exp1 local vs remote | [`exp1/PLAN.md`](exp1/PLAN.md) | DPA-Store Fig.15 |
| exp2 성능 축 + 지연 분해 | [`exp2/PLAN.md`](exp2/PLAN.md) | XSTORE Fig.12a / **12b(저부하)** / SMART **Fig.13**(스레드) |
| exp3 값 크기 | [`exp3/PLAN.md`](exp3/PLAN.md) | XSTORE Fig.16a / SMART Fig.14 |
| exp4 batching 축 | [`exp4/PLAN.md`](exp4/PLAN.md) | (자체) span·client 반대 부호 |

> 관리자 원칙 (2026-08-04): **"결과를 보려고 실험한다. 목표 미달도 데이터로
> 남기고 종결형 서술 금지."** 이전 판의 "확인 사항"이던 그림 번호는 원문
> 캡션으로 확정했다 — 스레드 확장=SMART Fig.13, 값 크기=Fig.14 (위 표 기준).

## 공통 규약 — 전 셀 적용

```text
지속      **측정당 30초, 사이 20초** — 이번 라운드는 경향성 목적 (관리자 결정
          2026-08-05). 절대값·최종 그림 주장은 후속 본측정(60초×3런 규율)으로.
          재시작 간 편차 ±3% 실측이므로 30초 단발로 절대값 주장 금지
램프 편향  30초 창 램프는 **0.063 초분 = −0.21%** (genie 직접 실측 2026-08-06,
          E0-DEM0-P32 15표본). 교차비교 보정 30↔60 +0.10%p / 30↔120 +0.16%p 로
          **σ 1.0% 아래 — 보정하지 않고 각주만 단다.** 이전 −1.66% 추정은
          obwatch 첫 행 결함(`PT` 가 정수 초로 잘려 첫 행 DT 만 부풀었다)에서
          나온 것이라 폐기. SET 램프는 첫 SET 셀에서 따로 확인
채널      conversation.md 에 CELL <id> GO ... / CELL <id> DONE <ops> p99 <ms>
          ariel 샘플러는 부하 트리거 — 시각 동기 불필요. manifest.tsv 에 셀 경계 UTC 기록
부하 공통  memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64
          --key-prefix=m- --key-minimum=1 --key-maximum=1000000
          --key-pattern=R:R --distinct-client-seed --hide-histogram
          (셀별 오버라이드는 각 PLAN 셀 표에 명시)
서버 기본  v4 운영값: mcT=30 (taskset 0-29) -m 2048 -c 16384 -R 1024, hp=22
          W=24 nqp=4 reap=8 chain=8 admit_max=64 setq_max=1 submit_inline
          E0(drain_empty_max) 확정값 — PENDING 블록 1 이후 고정
raw       exp<N>/ariel/<id>.txt (obwatch 전문+서버 명령줄), exp<N>/genie/<id>.txt
          (memtier 전문), rows.tsv 파싱 행
검증      port 셀: err5=0, 셀 fingerprint = stats settings
          (ext_post_chain/ext_reap_every/… 노출값), uniform 셀 hit 100%
바이너리   port: 605340c7 계열 (계측 확장 — PROF on/off 는 셀 표가 정한다)
          stock: 97ceee04 pristine
```

기측정 원본: `../shape-20260804/` (C1 스윕·형태), `../full-20260803/cells.csv`
(θ 스윕·계측 A/B), `md/LATENCY_BREAKDOWN.md` (분해 전문).
