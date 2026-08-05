# 확장 span latency — 측정·분해·해결 (KTC 0806, 목표 1)

작성 2026-08-05. 구성은 관리자 지정 4단이다. **새 측정 없음** — genie 불가로
전부 기측정 데이터 발췌이며 표마다 출처를 단다. 배경 설명은
[`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md)(구조 정본),
[`EXTENDED_SPAN_DIAGNOSIS.md`](EXTENDED_SPAN_DIAGNOSIS.md)(서사)로 미룬다.

정의 요약 (정본은 [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md)):

```text
span v2   장치가 일한 시간          GET: post→복호       SET: seal→CQE
span v3   원격화가 추가한 일 전체    GET: 진입→복호       SET: 진입→WFLIGHT 해제
기준      "로컬 메모리였으면 하지 않았을 일을 전부 포함한다"
재정의    2026-08-01 (v2 → v3)
```

---

## 1. span 재정의 이후 — v3 optimal 실측

### 1-1. 재정의 직전의 공식 기록 (0730, span v2 정의)

v3 정본 게이트 — 빌드 `span-1f3390a`, `mcT=28 W=24 nqp=2`:

| 워크로드 | 처리량 | Gspan (v2) | Sspan (v2) | 판정 |
|---|---:|---:|---:|---|
| GET-only | 10.241 M | 24.49 µs | — | ✅ |
| 1:9 혼합 | 8.035 M | 24.46 µs | 19.34 µs | ✅ ✅ |
| SET-only | 2.348 M | — | 15.63 µs | ✅ |

*출처: v3 채널 2026-07-30 "두 span 모두 통과" 항목.*

**v2 정의로는 세 워크로드 모두 계약 안이었다.** 그런데 같은 v3 배포본이
SET v2 7.8 µs 를 찍던 그 시각(§1-2 의 구성), memtier 는 SET 지연을
**7.45 ms** 로 보고하고 있었다 — **955 배**가 전부 계측 밖 대기였고, 이
간극이 재정의의 실측 동기다.

### 1-2. 재정의 직후 — 같은 v3 코드를 v3 정의로 (EXP-0, 08-01)

코드 무변경. 서버 `mcT=30 W=40 nqp=4 ORD=협상16`(v3 배포본), `pipe=256`:

| 워크로드 | 처리량 | span v3 | = admit | + v2 | + ret | 계약(30) 대비 |
|---|---:|---:|---:|---:|---:|---:|
| GET-only | 11.932 M | **242.29** | 217.12 | 25.16 | — | 8.1 배 초과 |
| 혼합 GET | 10.055 M | **311.77** | 285.16 | 26.59 | — | 10.4 배 |
| 혼합 SET | 〃 | **188.75** | 0.51 | 15.13 | 173.11 | 6.3 배 |
| SET-only | 4.133 M | **2380.29** | 0.61 | 7.84 | 2371.84 | **79.3 배** |

*출처: `experiments/exp0-20260801/FINDINGS.md` (pipe=256 행).*

**같은 런 안에서 v2 열과 v3 열이 나란히 있다** — 혼합 GET 은 26.59 대
311.77(11.7 배), 혼합 SET 은 15.13 대 188.75(12.5 배). 정의만 바꿨는데
계약이 8~79 배로 깨졌다 = **원래 있던 대기가 계측 안으로 들어온 것**이지
서버가 느려진 것이 아니다.

---

## 2. v3 optimal 의 latency breakdown — 있다

EXP-0 가 **세 워크로드 × pipeline 8~256 전 축**을 `admit / v2 / ret` 로
분해해 뒀다. 요지 셋:

**① 대기는 두 곳에 몰려 있고, 부하에 비례해 자란다.**

```text
pipe          8       16      32      64      128     256
GET admit   16.57   27.97   53.93   55.44  107.78  217.12   ← 제출 대기
혼합 ret     6.52   16.95   40.77   47.26   82.54  173.11   ← 재개 스킵
SET-only ret                99.21*         443.13* 2371.84   (*pipe 16/64)
```

**② 데이터 경로(v2)는 처음부터 무죄다.** 같은 축에서 v2 는
GET 15.9~26.6 / SET 7.7~16.9 µs 로 거의 평탄 — 고칠 것은 전송이 아니라
제출·재개의 시점이었다.

**③ pipe=256 에서 span 의 91~99.6% 가 그 두 대기다.**

```text
혼합 GET    311.77 중 admit 285.16   91.5%
혼합 SET    188.75 중 ret   173.11   91.7%
SET-only   2380.29 중 ret  2371.84   99.6%
```

**없는 것 (v3 시점 한계):** 클라이언트측 분해(`srv/que/pre/post`)와 셀별
클라이언트 latency. 그 계측은 2026-08-04 에 v4 에서 처음 만들어졌다 —
§4 에서 v4 값으로 채운다.

---

## 3. v3 워크플로 — 실질 대기 지점과 해결

### GET — 대기 지점: 제출

```text
v3
 ① read · 파싱 · 해시
 ② storage_get_item() 진입          ◀ span v3 시작
 ③ io_queue 삽입                    ┐
 ④ ── pass 끝까지 대기 ──           │ admit 217~285 µs
 ⑤ 일괄 submit → window·slot 확보   ┘
 ⑥ ibv_post_send                    ◀ span v2 시작
 ⑦ RDMA 왕복                        ┐ v2 25~27 µs
 ⑧ pass 끝 drain: CQE 관측 · 복호   ┘  ▶ 두 span 끝
 ⑨ 재개 → 응답
```

**원인**: 제출 조건 두 개 중 ①("연결 20 개")은 우리 구성에서 **발화
불가능**하다 — 커넥션 120 ÷ 스레드 30 = 스레드당 4 개뿐인데 20 을 센다.
그래서 전부 ②(pass 끝)를 기다리고, pipeline 이 깊을수록 pass 가 길어져
admit 이 부하에 비례한다(①의 표).

**해결**: `ext_submit_inline` — io_queue 를 **우회**하고 파싱 자리에서 post
(20 을 낮춘 것이 아니라 그 조건이 놓인 경로를 안 쓴다). 잃어버린 배칭은
요청 수 기준 새 축 둘로 재구성: `ext_post_chain=8`(post 묶음),
`ext_reap_every=8`(수거 주기).

### SET — 대기 지점: 재개(실현)

```text
v3
 ① read · 값 수신 · 파싱
 ② storage_store_item_pac() 진입    ◀ span v3 시작
 ③ 원격 슬롯 확보 · stub 준비       ─ admit 0.5 µs   (pac — 이미 즉시)
 ④ pac_seal                         ◀ span v2 시작
 ⑤ stub 게시(WFLIGHT) → 그 자리 WRITE post
 ⑥ CQE 관측 → 주차                  ▶ span v2 끝
 ⑦ ── if(out) 이 참인 pass 가 올 때까지 ──     ← 결함
 ⑧ WFLIGHT 해제                     ▶ span v3 끝
 ⑨ 재개 → STORED
```

**원인**: 재개(`storage_flush_returns`)가 `if (out)` 블록 안에만 있는데,
SET 제출 경로가 **제출하면서 CQ 를 스스로 비운다** → `out == 0` → 재개
블록이 통째로 건너뛰어진다. SET-only 는 GET 의 잔여 outstanding 이 없어
거의 항상 스킵 → 2371.84 µs.

**해결**: 완료를 **거둔 그 자리에서 즉시 실현**(trylock 프로브 → WFLIGHT
해제, 예외 셋만 미룸) + pass 끝 **무조건** flush(스킵 결함 제거 + mop-up).
`ret 2371.84 → 0.14 µs` (EXP-1 S3b, 커밋 `3a50784`).

*상세: `V3_TO_V4_CHANGES.md` §2~§3 (발화 산수·락 사고 두 건 포함).*

---

## 4. v4 워크플로 — 측정 결과

```text
GET (v4)                                     SET (v4)
 ① read · 파싱 · 해시                         ① read · 값 수신 · 파싱
 ② 진입              ◀ span v3               ② 진입              ◀ span v3
 ③ 체인 축적 (≤8)       admit ~4 µs          ③ 슬롯 확보 · stub     admit 0.5 µs
 ④ 그 자리 post                              ④ pac_seal
 ⑤ RDMA 왕복                                 ⑤ stub 게시 → 그 자리 post
 ⑥ reap 틱: CQE · 복호  ▶ 끝 (21.9~22.3)     ⑥ CQE 관측 → 주차
 ⑦ 같은 틱 재개                              ⑦ 같은 호출 trylock 프로브
                                             ⑧ WFLIGHT 해제       ▶ 끝 (9.11)
                                             ⑨ 재개 → STORED
```

### 4-1. 최종 게이트 (2026-08-03, 각 120 초)

| 워크로드 | 처리량 | span v3 | = admit | + v2 | + ret | 판정 |
|---|---:|---:|---:|---:|---:|---|
| GET-only | **13.397 M** | 21.90 | 4.39 | 17.51 | — | ✅ ✅ |
| 혼합 GET | **11.099 M** | 22.31 | 9.17 | 13.14 | — | ✅ ✅ |
| 혼합 SET | 〃 | 9.11 | 0.52 | 7.97 | 0.62 | ✅ |

SET-only 는 게이트 대상이 아니라 별도 측정(2026-08-04 형태 캠페인, 계측
확장 빌드): **5.6~5.8 M / span v3 7.8~8.0 µs** (pipe 64~384 에서 평탄).

### 4-2. v3 → v4

| | v3 (EXP-0) | v4 최종 | 변화 |
|---|---:|---:|---:|
| 혼합 처리량 | 10.06 M | 11.10 M | **+10.4%** |
| 혼합 GET span | 311.77 | 22.31 | 14.0 배 ↓ |
| 혼합 SET span | 188.75 | 9.11 | 20.7 배 ↓ |
| GET-only span | 242.29 | 21.90 | 11.1 배 ↓ |
| SET-only span | 2380.29 | ~8.0 | **~300 배 ↓** |

코드 변경 없이 정의를 넓혀 대기를 드러내고(§1), 그 대기를 걷어냈더니
처리량도 올랐다 — span 감소와 처리량 증가가 같은 수정에서 나왔다.

### 4-3. 클라이언트측 분해 — v4 에서 처음 가능해진 것 (§2 의 공백 충당)

계측 3 지점(`srv/que/bk`, 2026-08-04) 이후 운영점(pipe=256, GET-only) 실측:

```text
클라이언트 체감 2,277.58 µs
├ 네트워크 + 클라이언트 큐잉   1,786 µs   78.4%
└ 서버 체류 srv                  491 µs   21.6%
   ├ que   소켓read → 명령시작    108 µs    4.7%
   ├ pre   명령 → backend          ~1 µs    0.0%
   ├ span v3  [계약]               22 µs    0.9%
   └ post  복호 → 송신            360 µs   15.8%
```

저부하(pipe=1) — 큐잉을 걷어낸 바닥:

```text
클라이언트 207.20 µs (p50 183.0 / p99 559.0)
├ 네트워크 + 클라  162.92 µs   78.6%
└ srv               44.28 µs   ├ que 0.34  ├ pre 2.45
                               ├ span v3 17.88 (그중 xfer 8.13)
                               └ post 23.62
```

계약 지표(span v3)는 체감의 **0.9~8.6%** 를 덮고, `post`(복호→송신)가
저부하에서도 RDMA 왕복의 2.9 배다 — 남은 최적화 지점.
상세: [`LATENCY_BREAKDOWN.md`](LATENCY_BREAKDOWN.md).

> 계측 주의: v4 기록치는 전부 `EXT_RDMA_PROF=1`(처리량 −4.2% 실측) 하의
> 값이다 — 더 불리한 조건에서 계약을 충족했다.

---

## 목표 2 상태

논문 공통 실험 요소와 본 실험 설계는
[`../experiments/osdi-0804/PLAN.md`](../experiments/osdi-0804/PLAN.md) 에서
진행 중이다 (exp1 local-vs-remote · exp2 성능축+분해 · exp3 값 크기 ·
exp4 batching 축). stock 측 co-located 예비 13 셀은 측정 완료
(`exp1/stock-colocated/`), off-box 본측정과 port 측은 genie 복귀 대기.

## 원본

```text
experiments/exp0-20260801/FINDINGS.md      EXP-0 전 축 분해 (§1·§2 의 원본)
experiments/EXP1_FINDINGS.md               해결 과정 (S3b·여섯 축)
experiments/full-20260803/cells.csv        캠페인 123 셀 (게이트·chain/reap 축)
experiments/shape-20260804/                SET-only v4 실측
v3 채널 conversation.md (0730 항목)        §1-1 정본 게이트
```
