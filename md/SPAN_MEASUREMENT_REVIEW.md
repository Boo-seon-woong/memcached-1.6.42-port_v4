# span latency 계측 검증 — 정의 대조

> **[v3 시점 기록]** 이 문서는 그 시점의 기록으로 보존한다. 현재 운영값은
> [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md), 최신 결과는
> [`V4_RESULT.md`](V4_RESULT.md) 다.

작성 2026-07-29. 기밀 컴퓨팅에서의 **원격 메모리 접근 시간**으로 정의된 두
지표에 대해, 코드가 그 구간을 정확히 재는지 검증한다.

> ## ⚠ 이 문서가 검증한 것은 **span v2 정의**다
>
> 아래 §1·§2 의 "정의 부합 ✅" 와 §6 의 "계측 결함은 발견되지 않았다" 는
> **v2 정의에 대한 판정**이다. **계약은 2026-08-01 에 v3 로 바뀌었고**
> v2 는 그 앞뒤의 대기를 통째로 빠뜨린다 — 실측으로 GET admit 217~285 µs,
> SET ret 173~2372 µs 였다.
>
> ```text
> span v2 GET   RDMA READ post 직전 → 복호 완료      ← 이 문서가 검증한 것
> span v3 GET   storage_get_item() 진입 → 복호 완료   ← 계약이 쓰는 것
> span v2 SET   seal → WRITE CQE
> span v3 SET   storage_store_item_pac() 진입 → ITEM_WFLIGHT 해제
> ```
>
> **v3 계측의 검증은 §7 에 있다.** §1~§6 은 v2 판정으로 유효하되
> "계측에 결함이 없다"를 v3 에 대한 보증으로 읽으면 안 된다.
>
> 특히 §5-2 의 "GET 은 window 대기 **제외**, SET 은 **포함**" 은 v2 의
> 성질이다. **v3 에서는 둘 다 포함**이고, 그 비대칭이 없어진 것이 v3 정의를
> 도입한 이유 중 하나다.

## 대상 정의

```text
GET latency: RDMA READ post 직전 → CQE 수신 → SYNC_FOR_CPU/private 반영
             → AES-GCM decrypt 완료
SET latency: AES-GCM encrypt 시작 직전 → SYNC_FOR_DEVICE
             → RDMA WRITE CQE 수신
```

## 1. GET — 정의 부합 ✅

| 정의상 지점 | 코드 | 위치 |
|---|---|---|
| RDMA READ post 직전 | `ts = prof_rdtsc(); ios[i]->t_start = ts;` 직후 `ibv_post_send` | `extstore.c:716-719` |
| CQE 수신 | `t_poll = prof_rdtsc()` (`ibv_poll_cq` 반환 직후) | `extstore.c` drain |
| SYNC_FOR_CPU 반영 | `ibv_advise_mr(SYNC_FOR_CPU, FLUSH)` 후 `t_sync_done` | drain |
| decrypt 완료 | `ext_crypto_open()` 직후 `extstore_prof_stamp()` | `storage.c:239-240` |
| **기록값** | `prof_record(hist, count, sum, crypto_done − io->t_start)` | `extstore.c:1017` |

기록값 = `crypto_done − t_start` = **post 직전 → decrypt 완료**. 정의와 일치.

## 2. SET — 정의 부합 ✅

| 정의상 지점 | 코드 | 위치 |
|---|---|---|
| encrypt 시작 직전 | `prof_start = extstore_prof_stamp()` 직후 `ext_crypto_seal()` | `storage.c:592-596` |
| (encrypt 완료) | `prof_crypto_done`; `io.t_start=prof_start, .t_end=prof_crypto_done` | `storage.c:611,633` |
| SYNC_FOR_DEVICE | `ibv_advise_mr(SYNC_FOR_DEVICE, FLUSH)` — 전후로 `t_sync_start`/`ts` | `extstore.c:764-772` |
| WRITE CQE 수신 | drain의 `t_poll` | `extstore.c` drain |
| **기록값** | `prof_record(prof_w_hist, …, t_poll − io->t_start)` | `extstore.c:861` |

기록값 = `t_poll − prof_start` = **encrypt 시작 직전 → CQE 수신**. 정의와 일치.

> 구조 주의: `post_write`가 `io->t_end`를 SYNC_FOR_DEVICE 완료 시각으로
> **덮어쓴다**(원래 값은 encrypt 완료 시각). 덮어쓰기 전에 `prof_w_crypto_ns`를
> 먼저 적립하고(`extstore.c:763-765`), 이후 `prof_w_xfer_ns`가
> `t_poll − t_end`(= sync 완료 → CQE)를 쓰므로 순서상 문제는 없다. 다만
> `t_end`의 의미가 경로 중간에 바뀌므로 이 구조를 모르고 수정하면 깨진다.

## 3. 계측 품질

| 항목 | 확인 |
|---|---|
| 평균 | `sum/count` **정확값**. 히스토그램 역산 아님 |
| p50/p99 | 100 ns 버킷 × 32768 (0~3.27 ms). 20 µs 지점 해상도 0.5% |
| 스레드 안전 | `g_drain_worker`가 `_Thread_local`(`extstore.c:458`) — 워커 간 오염 없음 |
| 시계 | `CLOCK_MONOTONIC` 대비 50 ms 캘리브레이션, 상대오차 ~1e-6. invariant TSC라 코어 주파수 스케일링 무관 |
| 중복 계상 | 기록 후 `io->t_start = io->t_end = 0` |
| 표본 커버리지 | `prof_read_count`/`prof_write_count`를 `cmd_get`/`cmd_set`와 대조 가능 |

## 4. 실측 분해 검증 (2026-07-29, 1:1 혼합 10초)

하위 구간 지표의 합이 총합과 맞는지 확인했다.

```text
SET  총합  5.91 µs  vs  crypto 1.24 + sync 2.13 + xfer 2.48 =  5.85 µs   차이  −1.10%
GET  총합 18.85 µs  vs  xfer  8.83 + sync 4.37 + crypto 0.72 = 13.92 µs   차이 −26.15%
```

**SET은 −1.1%로 사실상 완전 분해된다.** 잔차는 `obj_io` 구성과 window 대기
루프 등 비계측 구간이다.

**GET의 26% 격차는 배치 직렬화다.** 원인이 구조적으로 특정된다:

```text
t_poll, t_sync_done   ← 배치 전체가 공유하는 단일 타임스탬프
    ↓  for (i = 0; i < c; i++) io->cb(...)   ← 배치 내 자기 차례 대기 (비계측)
    ↓  hash(key) + AAD 구성                  ← 비계측
crypto_start → crypto_done                   ← 여기만 crypto로 계측
```

`xfer`와 `sync`는 **배치 공유값**이라 배치 내 모든 op가 같은 값을 받는 반면
`crypto_done`은 **op별**이다. 따라서 배치의 k번째 op는 앞선 0..k−1의 복호·응답
처리를 기다린 시간만큼 총합이 커지고, 그 시간은 어느 하위 구간에도 안 잡힌다.

**총합 자체는 정의대로 정확하다** — 이 대기는 CQE 수신과 decrypt 완료 사이에
실제로 흐른 시간이므로 정의상 포함되는 것이 맞다. 분해만 되지 않는다.

## 5. 수치를 인용할 때 알아야 할 특성

1. **배치 크기 의존성.** GET latency의 약 1/4이 drain 배치 내 대기다. 측정값이
   drain 배치 크기에 민감하므로, 순수 원격 접근 지연을 보려면 배치 1에서
   재야 한다. 뒤집으면 이 구간은 **줄일 수 있는 대상**이다 — CQE별 즉시
   복호로 바꾸면 span이 내려간다.
2. **window 대기 포함 여부가 GET/SET에서 다르다.** 정의가 서로 다른 지점에서
   시작하기 때문이다.
   - GET: window가 차면 `w->wait_head`에 park되고 **`t_start`는 실제 post
     시점에 찍힌다**(`extstore.c:706-718`) → window 대기 **제외**
   - SET: `t_start`(encrypt 직전)를 찍은 **뒤에** window 대기 루프가 온다
     (`storage.c:635-639`) → window 대기 **포함**

   둘 다 각자의 정의에는 부합한다. 다만 두 수치를 "같은 종류의 지연"으로
   나란히 비교하면 안 된다.
3. **혼합 워크로드에서 read 표본이 `cmd_get`을 초과할 수 있다.** transient
   visibility 실패 시 재시도가 일어나고 시도마다 표본이 남는다(실측 +0.045%).
   재시도 횟수는 `g_read_retry_ct`로 별도 계수된다.

## 6. 판정

두 지표 모두 **정의된 구간을 정확히 측정한다.** 시작·종료 지점이 정의와
일치하고, 평균은 근사가 아닌 정확값이며, 스레드 안전성·시계 정확도·중복
계상 방지가 확보돼 있고 표본 커버리지를 독립적으로 검증할 수 있다.

계측 결함은 발견되지 않았다. §5의 세 항목은 결함이 아니라 수치를 해석할 때
동반해야 할 특성이다.


---

## 7. span v3 계측 검증 (2026-08-03 추가)

v3 정의가 코드에서 어떻게 구현되고 무엇이 통계로 나가는지 확인한다.

### 7-1. 시작·종료 지점

| 정의상 지점 | 코드 | 위치 |
|---|---|---|
| GET 시작 | `t_enter_v3 = extstore_prof_stamp()` — 함수 첫 줄 | `storage.c:462` |
| GET 종료 | `crypto_done` (복호·태그 검증 완료) | `extstore.c:1243` |
| GET 기록 | `prof_r_e2e += crypto_done − io->t_enter` | `extstore.c:1244-1245` |
| SET 시작 | `t_enter_v3 = extstore_prof_stamp()` — 함수 첫 줄 | `storage.c:895` |
| SET 종료 | `done` (= `ITEM_WFLIGHT` 해제 시점) | `extstore.c:1265` |
| SET 기록 | `prof_w_e2e += done − io->t_enter` | `extstore.c:1265` |

`t_enter` 는 `obj_io` 에 실려 다니고(`extstore.h:114`), 기록 후 0 으로
되돌려 중복 계상을 막는다(`extstore.c:1252`, `:1269`).

### 7-2. 세 성분은 독립 집계다 — 파생이 아니다

이것이 v3 계측에서 가장 중요한 성질이다.

```text
prof_r_e2e    crypto_done − t_enter    셀렉터 2   → extstore_prof_read_e2e_avg_ns
prof_r        crypto_done − t_start    셀렉터 1   → extstore_prof_read_avg_ns
prof_r_admit  t_start − t_enter        extstore.c:1248
                                       → extstore_prof_read_admit_avg_ns
```

`prof_summarize(e, 2, …)` 가 v3, `(e, 1, …)` 가 v2 다(`extstore.c:1174-1178`).
**v3 를 admit 에서 빼서 만들지 않으므로 `admit + v2 = v3` 가 독립적인
정합성 검사**가 된다:

```text
EXP-0 GET-only pipe=256   217.12 + 25.16 = 242.28   대 실측 242.29
최종 게이트 혼합 SET       0.52 + 7.97 + 0.62 = 9.11  대 실측  9.11
```

**두 자리 이상에서 맞는다.** 계측이 자기 자신과 모순되지 않는다는 뜻이다.

### 7-3. 소비 경로 — 어느 필드가 표에 실리는가

```text
서버      extstore_prof_read_e2e_avg_ns / _count      (stats)
추적기    shape-trace-v3.sh 가 그 필드를 수집
슬라이서  exp0-slice.py:58  gv3 = local(a,b,"re2ea","re2ec")
표        Gv3 열
```

**캠페인 전 표의 span 은 v3 다.** `_avg_ns`(v2)도 함께 수집되지만 `+v2`
열에만 쓴다(`exp0-slice.py:60` `gv2 = local(a,b,"ravg","rcount")`).

### 7-4. v2 판정 중 v3 에서 달라지는 것

| §5 항목 | v2 | v3 |
|---|---|---|
| 배치 내 대기 | GET span 의 약 1/4 | 그대로 포함 (v2 구간 안이므로) |
| window 대기 | GET **제외** / SET 포함 | **둘 다 포함** (admit 에 잡힌다) |
| 배치 크기 의존성 | 있음 | 있음 + **체인·reap 의존성이 추가**된다 |

마지막 줄이 v4 에서 새로 생긴 성질이다 — `ext_post_chain` 과
`ext_reap_every` 가 각각 `admit` 과 `v2` 를 지배한다(`V4_RESULT.md` §1-2·§1-3).

### 7-5. 판정

**v3 지표도 정의된 구간을 정확히 측정한다.** 시작·종료가 정의와 일치하고,
세 성분이 독립 집계라 합산 검사가 성립하며, 소비 경로가 v3 필드를 읽는다.

다만 **"span 이 낮다"가 "클라이언트가 빠르다"를 뜻하지 않는다** — v3 는
backend 진입 이후만 잰다. 소켓 버퍼에서 기다린 시간은 여전히 밖이고,
그 성질은 v2·v3 가 같다.
