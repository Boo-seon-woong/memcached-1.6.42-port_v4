# 확장 span latency — 측정·분해·해결 (KTC 0806, 목표 1)

작성 2026-08-05. 구성은 관리자 지정 4단이다. **새 측정 없음** — genie 불가로
전부 기측정 원장 발췌이며, 표마다 출처·구성·빌드를 단다. **잰 적 없는 값은
공백(—)으로 두고 §5 에 측정 대상으로 모았다.** 배경 서사는
[`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md) /
[`EXTENDED_SPAN_DIAGNOSIS.md`](EXTENDED_SPAN_DIAGNOSIS.md)로 미룬다.

> 이전 판 정정: "재정의 직전 공식 기록"으로 07-30 게이트(혼합 8.035 M)를
> 인용했던 것은 **오류**다. 그 수치는 coherent data-MR 이전 것이고, 정본은
> 07-31 이중 게이트(혼합 10.195 M)다 — §1-(a).

---

## 0. 정의와 성분 사다리

```text
span v2   장치가 일한 시간          GET: ibv_post_send → 복호 완료
                                   SET: pac_seal → CQE 관측
span v3   원격화가 추가한 일 전체    GET: storage_get_item() 진입 → 복호 완료
                                   SET: storage_store_item_pac() 진입 → WFLIGHT 해제
기준      "로컬 메모리였으면 하지 않았을 일을 전부 포함한다"
재정의    2026-07-31 밤 (v3 코드 c0c5b4f, stats 에 e2e 8필드 추가)
```

계측은 세 층위다. 각 층위가 언제부터 존재했는지가 이 문서의 공백을 정한다:

```text
층위 1  v3 = admit + v2 (+ ret)           07-31 재정의, 성분 스탬프는 08-01 빌드부터
        (성분별 독립 집계 — 합 검사 성립: 217.12+25.16=242.28 vs 실측 242.29)
층위 2  v2 = sync + xfer + crypto + 잔차   v3 시대(07-29~)부터 stats 에 존재
        잔차 = 배치 직렬화 등 비계측 구간. xfer·sync 는 배치 공유값이라
        GET 은 비가산(−26.15% 실측, §2-3) — SET 은 −1.1%로 사실상 완전 분해
층위 3  클라측 = que + pre + [span v3] + post (+네트워크·클라 큐잉)
        2026-08-04 신설 (v4). v3 시대 데이터 전무
```

워크플로 구간과의 대응 (그림은 §3·§4):

```text
GET  진입→post 대기            = admit     |  SET  진입→seal        = admit
     post→CQE (wire+동기화)    = xfer+sync |       seal→CQE         = xfer+sync+crypto(seal)
     복호·태그 검증            = crypto    |       CQE→WFLIGHT 해제  = ret
     배치 내 차례 대기 등       = 잔차      |
```

---

## 1. [1-1] span 재정의 전후 — 0731 하루의 세 기록 (port_v3)

세 기록 전부 2026-07-31, off-box(genie 부하), fresh boot 계열이다.
혼합 비율 주의: **(a)는 1:10(계약 비율), (b)(c)는 1:9(캠페인 비율)** —
비율 차이만으로 약 1.4% 붙는다(v3 채널 6038행 주의 항목).

### (a) v2 정본 — 이중 게이트 동시 충족 (0731 오전)

```text
빌드   771ca34068c7609936b2e58a (ce92044, v3-set-pac)
       = pac ⊕ coherent data-MR ⊕ magazine 배열 스캔 ⊕ GCM 1회 키잉
서버   $HOME/coherent-mr-v2/bin/memcached -p 11411 -U 0 -t 28
       -m 2048 -c 16384 -R 1024,  W=24  nqp=2  hp=22,  taskset 0-27
부하   memtier -t 28 -c 4 --pipeline=160 -d 64, keyspace 1 M,
       --key-pattern=R:R --distinct-client-seed
창     obwatch 10초 창, fresh boot, coherent MR 2풀, 1 M 프리로드
```

| 워크로드 | 총 ops/s | GET span (v2) | SET span (v2) | busy | 판정 |
|---|---:|---:|---:|---:|---|
| **1:10 혼합** | **10,194,599** (G 9.268 M + S 0.927 M) | **16.03** | **14.51** | 28.1 | **PASS** |
| **GET-only** | **11,778,792** | **15.96** | — | 27.9 | **PASS** |
| SET-only | 4,240,796 | — | 7.63 | 28.0 | (게이트 아님) |

무결점: `get_misses = read_fail = write_fail = engine_dead = leak = 0`,
hit 100%. `badcrc` 10,984(GET 의 0.012%)는 덮어쓰기 경합, 재시도 회수.

**혼합에서도 10 M 을 달성한 기록이 맞다** — v2 정의로 계약 전문 충족.
*출처: v3 `md/SET_CAMPAIGN_HANDOFF.md` §16 (정본), `md/OPTIMAL_RUNBOOK.md` §0·§5.*

### (b) v2 — 운영점 재조정 (0731 낮: 형태 25셀 + W sweep 11셀)

동시성 형태 캠페인이 운영점을 옮겼다: `mcT 28→30, W 24→40, nqp 2→4,
pipe 160→256` (nqp=2 의 실효 동시성 천장 32 를 nqp=4 로 열음).

| 측정 | GET-only | 1:9 혼합 | SET-only | 출처 |
|---|---:|---:|---:|---|
| WU-40 셀 (100초) | 12.668 M (p99 2.415 ms) | 10.558 M (2.895) | 4.077 M (6.079) | 채널 7740행, raw `experiments/wsweep-20260731/genie/WU-40-W{1,2,3}.txt` |
| 관리자 수동 | 12.596 M (busy 29.9) | 10.491 M (29.9) | 4.085 M (29.7) | 채널 7797행 |
| span v2 (같은 자리) | **—** | **—** | 8.234 = crypto 0.940 + sync 0.010 + xfer 6.929 + 잔차 0.355 | 채널 7810행 |

GET·혼합의 **창 단위 span v2 는 이 운영점에서 기록이 없다**(셀 기록이
client ops/p99 만 수집) — 회고 인용("v2 로는 W=48 에서 첫 위반", 채널
8224행)만 남았다. → §5-①

### (c) 재정의 + 같은 운영점 재게이트 (0731 밤) — **1-1 의 본론**

```text
코드   c0c5b4f (v3-set-pac) — e2e(v3) stats 8필드 추가. 성분 스탬프는 아직 없음
배포   ab0ed6f5127e399b99c8ae6b,  구성 (b) 그대로: mcT=30 W=40 nqp=4 pipe=256
부하   genie, 워크로드당 100초, mtT=30 -c 4 pipe=256, perf 미동승
raw    (v3 repo) experiments/gatev3-20260731/genie/{GET,SET,MIX}.txt
```

| 워크로드 | 처리량 | client p99 | span v3 | 같은 창 v2 | 계약(30) |
|---|---:|---:|---:|---:|---:|
| GET-only | 12.003 M | 2.527 ms | **243.99** | — | 8.1 배 초과 |
| 1:9 혼합 | 9.577 M | 3.039 ms | G **323.7** / S **196.4** | — | 10.8 / 6.5 배 |
| SET-only | 4.161 M | 5.983 ms | S **2372** | — | 79 배 |

**같은 서버, 같은 부하 축에서 정의만 바꿨는데 8~79 배 초과다** — 서버가
느려진 게 아니라 원래 있던 대기가 계측 안으로 들어온 것. 동기 증거: (a)가
v2 로 통과하던 시기에 memtier 는 SET 지연 **7.45 ms** 를 보고하고 있었다
(v2 SET-only 7.8 µs 의 955 배가 계측 밖).

이 게이트 런의 **성분 분해(admit/v2/ret)는 없다** — 성분 스탬프가 다음
빌드(08-01, `c8aeae5b`)에서 추가됐기 때문. 이튿날 EXP-0 이 같은 구성으로
재서 채웠고, GET-only 242.29 vs 243.99 로 **0.6% 재현**이다 → §2.
*출처: v3 채널 8194~8281행.*

---

## 2. [1-2] v3 optimal 의 latency breakdown (EXP-0, 08-01)

### 2-1. 구성 — 재현 수준 전문

```text
빌드   c8aeae5bc1804fe025814dc2 (v3-set-pac + admit/ret 성분 분해). 코드 수정 전
서버   mcT = 30   -m 2048 -c 16384 -R 1024,  taskset 0-29
       ext_worker_window(W)=40  ext_qp_per_worker(nqp)=4
       ext_drain_spin=1024  hashpower=22  ORD=0(CM 협상→16)  총 QP=120
환경   MLX5_COHERENT_QP=1  MLX5_COHERENT_CQ=1  EXT_RDMA_PROF=1
       EXT_SLOT_SIZE=256  EXT_READ_SLOTS=64
       ext_loc_mag_depth=64  ext_pac_set=on  ext_setq_max=1  ext_seal_at_flush=off
부하   mtT=30  -c 4 (120 커넥션)  -d 64  --test-time=30
       --key-prefix=m- --key-minimum=1 --key-maximum=1000000
       --key-pattern=R:R --distinct-client-seed
키공간 1,000,000 × 64 B 프리로드 1회.  창: 30초 부하 안쪽 ~27초, (avg×count) 차분
검증   전 셀 err5=0, hit 100%, genie 클라이언트 처리량과 0.2% 이내 일치
```

### 2-2. 층위 1 분해 — 세 워크로드 × pipeline 전 축 (단위 µs)

GET-only (`--ratio=0:1`):

| pipe | ops/s | **Gv3** | =admit | +v2 | busy |
|---:|---:|---:|---:|---:|---:|
| 8 | 3.451 M | 34.02 | 16.57 | 17.44 | 23.6 |
| 16 | 5.418 M | 48.48 | 27.97 | 20.51 | 23.7 |
| 32 | 7.644 M | 76.36 | 53.93 | 22.42 | 24.3 |
| 64 | 9.669 M | 78.70 | 55.44 | 23.25 | 28.6 |
| 128 | 11.676 M | 131.91 | 107.78 | 24.13 | 29.6 |
| 256 | 11.932 M | **242.29** | **217.12** | 25.16 | 29.9 |

1:9 혼합 (`--ratio=1:9`):

| pipe | ops/s | **Gv3** | =admit | +v2 | **Sv3** | =admit | +v2 | +ret | busy |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 3.231 M | 37.39 | 21.47 | 15.94 | 23.57 | 0.71 | 16.34 | 6.52 | 23.6 |
| 16 | 5.004 M | 54.73 | 35.40 | 19.31 | 34.42 | 0.61 | 16.86 | 16.95 | 24.1 |
| 32 | 6.792 M | 92.29 | 69.88 | 22.42 | 57.77 | 0.56 | 16.44 | 40.77 | 24.6 |
| 64 | 8.249 M | 105.39 | 81.53 | 23.87 | 64.16 | 0.55 | 16.35 | 47.26 | 28.7 |
| 128 | 9.838 M | 161.49 | 136.72 | 24.76 | 98.34 | 0.52 | 15.28 | 82.54 | 29.7 |
| 256 | 10.055 M | **311.77** | **285.16** | 26.59 | **188.75** | 0.51 | 15.13 | **173.11** | 29.9 |

SET-only (`--ratio=1:0`, 진단용 — 계약은 혼합 안의 SET):

| pipe | ops/s | **Sv3** | =admit | +v2 | +ret | busy |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 3.329 M | 107.50 | 0.60 | 7.69 | 99.21 | 24.7 |
| 64 | 4.209 M | 451.57 | 0.57 | 7.86 | 443.13 | 29.5 |
| 256 | 4.133 M | **2380.29** | 0.61 | 7.84 | **2371.84** | 29.6 |

요지 셋: **① 대기 두 곳(GET admit·SET ret)만 부하에 비례해 자란다**
(admit 16.57→217.12, ret 6.52→173.11 / 99.21→2371.84). **② v2 는 전 축
평탄**(GET 15.9~26.6 / SET 7.7~16.9) — 데이터 경로 무죄. **③ pipe=256 에서
그 두 대기가 span 의 91.5 / 91.7 / 99.6%.**
*출처: `experiments/exp0-20260801/FINDINGS.md` (표 전문 그대로).*

### 2-3. 층위 2 (v2 내부) — **EXP-0 축에는 없다. 공백이다**

EXP-0 수집기(`trace.csv`)의 열 전문:

```text
ts,cmd_get,cmd_set,get_hits,get_misses,rcount,ravg,rp99,wcount,wavg,wp99,
badcrc,err5,cpu_total,cpu_idle,re2ec,re2ea,re2ep99,we2ec,we2ea,we2ep99,
radmit,wadmit,wret
```

`xfer/sync/crypto` 열이 **없다**. stats 필드 자체는 v3 시대부터 있었으므로
(`extstore_prof_{read,write}_{sync,xfer,crypto}_avg_ns`) 재실행하면 얻을 수
있다 → §5-②. v3 시대에 층위 2 실측이 남은 것은 다음 **두 점뿐**이다:

| 시점 | 워크로드 | 총합 | =sync | +xfer | +crypto | +잔차 |
|---|---|---:|---:|---:|---:|---:|
| 07-29, 1:1 혼합 10초 | SET | 5.91 | 2.13 | 2.48 | 1.24 | 0.06 (−1.1%) |
| 〃 | GET | 18.85 | 4.37 | 8.83 | 0.72 | **4.93 (−26.2%)** |
| 07-31, 새 운영점 | SET-only | 8.234 | 0.010 | 6.929 | 0.940 | 0.355 |
| 07-31, 새 운영점 | GET-only / 혼합 | **—** | | | | |

GET 의 26% 잔차는 결함이 아니라 **구조**다: `xfer/sync` 는 배치 공유
타임스탬프라 배치 내 k 번째 op 의 "자기 차례 대기"가 어느 하위 구간에도 안
잡힌다(v3 `md/SPAN_MEASUREMENT_REVIEW.md` §4 에 원인 특정). SET 은 건별
스탬프라 −1.1%로 완전 분해된다.

### 2-4. 층위 3 (클라이언트측 que/pre/post) — **v3 시대 전무**

계측 자체가 2026-08-04(v4)에 생겼다. v3 의 클라이언트측 분해는 어떤
워크로드·어떤 창에도 없다 → §5-⑤. v4 실측은 §4-2.

---

## 3. [1-3] v3 워크플로 — 실질 대기 지점과 해결

### GET — 대기 지점: 제출 (admit)

```text
v3                                              성분
 ① read · 파싱 · 해시                            (span 밖)
 ② storage_get_item() 진입      ◀ span v3       ┐
 ③ io_queue 삽입                                │
 ④ ── pass 끝까지 대기 ──                        │ admit  (pipe=256: 217~285)
 ⑤ 일괄 submit → window·slot 확보                ┘
 ⑥ ibv_post_send               ◀ span v2        ┐
 ⑦ RDMA 왕복                                    │ v2 = sync+xfer+crypto+잔차
 ⑧ pass 끝 drain: CQE 관측 · 복호  ▶ 두 span 끝  ┘        (25~27, 평탄)
 ⑨ 재개 → 응답                                   (post — v3 시대 미계측)
```

**원인**: 제출 조건 두 개 중 "연결 20개 모임"(`memcached.c:3324`)이 우리
구성에서 **발화 불능** — 커넥션 120 ÷ 스레드 30 = 스레드당 4 뿐인데 20 을
센다. 전부 pass 끝(②번 조건)을 기다리고, pipeline 이 깊을수록 pass 가
길어져 admit 이 부하에 비례한다(§2-2 표).

**해결(v4)**: `ext_submit_inline` — io_queue 를 **우회**하고 파싱 자리에서
post(20 을 낮춘 게 아니라 그 조건이 놓인 경로를 안 쓴다). 잃은 배칭은 요청
수 기준 새 축 둘로 재구성: `ext_post_chain=8` / `ext_reap_every=8`.

### SET — 대기 지점: 재개 (ret)

```text
v3                                              성분
 ① read · 값 수신 · 파싱                         (span 밖)
 ② storage_store_item_pac() 진입 ◀ span v3      ┐ admit (0.5~0.7 — 이미 즉시)
 ③ 원격 슬롯 확보 · stub 준비                    ┘
 ④ pac_seal                     ◀ span v2       ┐
 ⑤ stub 게시(WFLIGHT) → 그 자리 WRITE post       │ v2 (7.7~16.9, 평탄)
 ⑥ CQE 관측 → 주차              ▶ span v2 끝    ┘
 ⑦ ── if(out) 이 참인 pass 를 기다림 ──           ret  (pipe=256: 173~2372)
 ⑧ WFLIGHT 해제                 ▶ span v3 끝
 ⑨ 재개 → STORED                                 (post — v3 시대 미계측)
```

**원인**: 재개(`storage_flush_returns`)가 `thread.c:531` 의 `if (out)` 블록
안에만 있는데, SET 제출 경로가 제출하며 CQ 를 스스로 비워 `out == 0` →
재개 블록이 통째로 건너뛰어진다. SET-only 는 GET 잔여 outstanding 이 없어
거의 항상 스킵 → 2371.84 µs.

**해결(v4)**: 완료를 **거둔 그 자리에서 즉시 실현**(trylock 프로브 →
WFLIGHT 해제, 예외 셋만 미룸) + pass 끝 **무조건** flush(스킵 결함 제거 +
mop-up). `ret 2371.84 → 0.14 µs` (EXP-1 S3b, 커밋 `3a50784`).

*상세(발화 산수·락 사고 두 건·트리거 3종): `V3_TO_V4_CHANGES.md` §2~§3.*

---

## 4. [1-4] v4 워크플로 — 측정 결과

```text
GET (v4)                                     SET (v4)
 ① read · 파싱 · 해시                         ① read · 값 수신 · 파싱
 ② 진입              ◀ span v3               ② 진입              ◀ span v3
 ③ 체인 축적 (≤8)       admit ~4             ③ 슬롯 확보 · stub     admit ~0.5
 ④ 그 자리 post                              ④ pac_seal
 ⑤ RDMA 왕복            v2                   ⑤ stub 게시 → 그 자리 post
 ⑥ reap 틱: CQE · 복호  ▶ 끝                 ⑥ CQE 관측 → 주차      v2
 ⑦ 같은 틱 재개                              ⑦ 같은 호출 trylock 프로브  ret
                                             ⑧ WFLIGHT 해제       ▶ 끝
                                             ⑨ 재개 → STORED
```

### 4-1. 최종 게이트 (2026-08-03) — 정본

```text
기준일 2026-08-03, 배포 바이너리 sha b4c18e9710cc693c48531181
각 120초, 추적기 1개, 아무것도 동승하지 않음 (EXT_RDMA_PROF=1 은 상시)
운영값  ext_admit_max=64  ext_reap_every=8  ext_post_chain=8  ext_setq_max=1
        ext_submit_inline  ext_submit_batch=20(불변·미발화)
        W=24  nqp=4  mcT=30  -R 1024  (캠페인 중 이동: W 40→24, reap 12→8)
부하    mtT=30  -c 4 (120 커넥션)  pipeline=256  -d 64  --test-time=120, 혼합 1:9
```

| 워크로드 | 처리량 | span v3 | =admit | +v2 | +ret | 판정 |
|---|---:|---:|---:|---:|---:|---|
| GET-only | **13.397 M** | **21.90** | 4.39 | 17.51 | — | ✅ ✅ |
| 1:9 혼합 | **11.099 M** | G **22.31** | 9.17 | 13.14 | — | ✅ ✅ |
| 〃 | 〃 | S **9.11** | 0.52 | 7.97 | 0.62 | ✅ |

여유: 혼합 처리량 +11.0%(구속 지표), GET-only +34%, span 여유 GET 34~37% /
SET 229%. 사전 예측 밴드 `13.13~13.67 / 10.86~11.33`(±2σ) 안에 들어왔다.
재검 전 참고 창: SET-only **5.434 M / 7.67 µs** (게이트 비대상).

**게이트 런의 세분 한계 — 공백 명시:**

| 항목 | 게이트 런 기록 | 비고 |
|---|---|---|
| admit / v2 / ret (avg) | ✔ 위 표 | 원장 `full-20260803/cells.csv` |
| span p50 / p99 | **—** | §5-③ |
| v2 내부 (sync/xfer/crypto) | **—** | stats 에 있으나 게이트 수집기가 안 받음. §5-③ |
| 클라이언트측 (srv/que/pre/post) | **—** | 계측이 이튿날(08-04) 신설. §5-③ |

### 4-2. 세분은 이튿날 인접 실측이 채운다 (08-04, 같은 운영값, **별도 런**)

게이트 값이 아니다 — 같은 운영값(W=24 nqp=4 reap=8 chain=8)에서 08-04 계측
확장 빌드로 다시 잰 것. 계측 비용 실측 **−4.2%**(PROF on/off A/B: GET
13.261 vs 13.84 M, 혼합 10.961 vs 11.393 M) — 이하 수치는 전부 PROF=1 쪽.

**(i) 운영점 pipe=256 — 층위 1+3 (빌드 605340c7, `cells.csv` BD 블록):**

```text
GET-only 13.261 M   client 2,277.58 µs (측정창 avg)
├ 네트워크 + 클라이언트 큐잉  1,786   78.4%
└ srv 491.39 (p50 466.8 / p99 959.4)
   ├ que  108.02 (p50 97.5 / p99 304.4)   파이프라인 앞선 명령 대기
   ├ pre + post  361.74                    post 가 지배 (복호→송신 재개 대기)
   └ span v3  21.63 (p50 17.6 / p99 75.8)  ← 계약이 재는 전부 (srv 의 4.4%)

혼합 10.961 M: G 22.64 (p50 17.2) / S 9.23 (p50 7.9), srv 620.13, que 144.89
pipe=1 (저부하 바닥): client 207.20 (p50 183 / p99 559)
  = 네트워크+클라 162.92 + srv 44.28 (que 0.34 / pre 2.45 /
    span 17.88 [admit 7.00 / xfer 8.13] / post 23.62)
```

**pipe=256 GET 의 v2 내부(xfer/crypto/sync)는 이 런에도 없다** → §5-④.

**(ii) pipe 64·384 — 층위 2까지 전 성분 (shape 캠페인 `rows.tsv`, 중단 전 6셀):**

| 셀 | 워크로드 | ops/s | span avg (p50/p99) | =admit | +xfer | +crypto | +sync | +ret | 잔차 | post |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C1-64 | GET-only | 10.051 M | 23.76 (18.8/69.3) | 5.25 | 15.11 | 0.67 | 0.04 | — | 2.69 | 91.0 |
| C1-64 | 혼합 GET | 8.542 M | 25.33 (20.8/78.8) | 10.06 | 11.73 | 0.73 | 0.04 | — | 2.77 | 113.9 |
| C1-64 | 혼합 SET | 〃 | 10.48 (8.0/38.5) | | | | | | | |
| C1-64 | SET-only | 5.611 M | 8.03 (6.5/37.3) | 0.59 | 5.55 | 1.08 | 0.02 | (별도) | 0.79 | 352.3 |
| C1-384 | GET-only | 13.057 M | 22.12 (18.2/66.2) | 4.71 | 14.46 | 0.57 | 0.03 | — | 2.35 | 624.1 |
| C1-384 | 혼합 GET | 10.150 M | 24.48 (20.0/—*) | 9.89 | 11.31 | 0.62 | 0.03 | — | 2.63 | 1236.0 |
| C1-384 | SET-only | 5.737 M | 7.94 (6.6/32.1) | 0.65 | 5.54 | 0.99 | 0.02 | (별도) | 0.74 | 1982.4 |

\* p99 버킷 포화(INVALID).
**운영점 pipe=256 행(C1-256)은 캠페인 중단으로 없다** → §5-④. GET 잔차
~2.4~2.8 µs 는 §2-3 의 배치 직렬화(비계측)와 같은 항목이다.

SET-only v4 종합: 5.6~5.8 M / span 7.8~8.0 µs — v3 의 4.13 M / 2380 µs 대비.

### 4-3. v3 → v4 (같은 pipe=256, EXP-0 대비)

| | v3 (EXP-0, 08-01) | v4 게이트 (08-03) | 변화 |
|---|---:|---:|---:|
| 혼합 처리량 | 10.055 M | 11.099 M | **+10.4%** |
| 혼합 GET span | 311.77 | 22.31 | 14.0 배 ↓ |
| 혼합 SET span | 188.75 | 9.11 | 20.7 배 ↓ |
| GET-only 처리량 / span | 11.932 M / 242.29 | 13.397 M / 21.90 | +12.3% / 11.1 배 ↓ |
| SET-only span | 2380.29 | 7.67~8.0 (참고 창·shape) | **~300 배 ↓** |

정의를 넓혀 대기를 드러내고(§1) 그 대기를 걷어냈더니(§3) 처리량도 올랐다 —
span 감소와 처리량 증가가 같은 수정에서 나왔다.

---

## 5. 공백 목록 — 다음 측정 대상 (전부 genie 필요)

| # | 공백 | 어디서 표기 | 필요한 것 |
|---|---|---|---|
| ① | v3 새 운영점(mcT30/W40/nqp4/pipe256)의 GET·혼합 span v2 창값 | §1-(b) | v3 빌드 재기동 + off-box 부하 |
| ② | v3 의 v2 내부(sync/xfer/crypto) pipeline 축 — GET-only·혼합 | §2-3 | EXP-0 재실행, 수집열 3개 추가 (stats 필드는 이미 있음) |
| ③ | v4 최종 게이트 조건에서 p50/p99·v2 내부·클라측 동시 기록 | §4-1 | 게이트 재실행 (b4c18e97 또는 605340c7, PROF=1) |
| ④ | v4 운영점 pipe=256 의 전 성분 행 (shape C1-256) + xfer 내 wire/CQE 분리 | §4-2 | shape 캠페인 재개 |
| ⑤ | v3 시대 클라이언트측 분해 일체 | §2-4 | 계측이 v4 에만 있으므로 **원리상 소급 불가** — v3 빌드에 srv/que/bk 3점 이식해야 가능 |

---

## 목표 2 상태

논문 공통 실험 요소·본 실험 설계는
[`../experiments/osdi-0804/PLAN.md`](../experiments/osdi-0804/PLAN.md) 진행 중
(exp1 local-vs-remote · exp2 성능축+분해 · exp3 값 크기 · exp4 batching).
stock co-located 예비 13셀 측정 완료(`exp1/stock-colocated/`), off-box
본측정·port 측 YCSB 는 genie 복귀 대기.

## 원본 경로

```text
── port_v3 repo ──
md/SET_CAMPAIGN_HANDOFF.md §16          (a) 이중 게이트 정본
md/OPTIMAL_RUNBOOK.md                   (a) 재현 절차 전문 (서버·부하 명령줄)
conversation.md 5979 / 7627~7796 / 7797 / 8194~8281
                                        이중게이트 · W sweep · 수동측정 · 재정의+재게이트
experiments/wsweep-20260731/genie/      (b) raw
experiments/gatev3-20260731/genie/      (c) raw
md/SPAN_MEASUREMENT_REVIEW.md §4        층위 2 분해 검증 (0729, 비가산 원인)

── port_v4 repo ──
experiments/exp0-20260801/{FINDINGS.md, trace.csv, RESULTS.txt}   §2 전문
experiments/full-20260803/cells.csv     §4-1 게이트 원장 + BD 블록 (§4-2 i)
experiments/shape-20260804/rows.tsv     §4-2 ii 전 성분 행
md/V4_RESULT.md                         최종 게이트 서사 · 손잡이 이동
md/LATENCY_BREAKDOWN.md                 층위 3 정본 (§0 트리 · §3 pipe 스윕)
```
