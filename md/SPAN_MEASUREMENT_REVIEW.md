# span latency 계측 검증 — 정의 대조

작성 2026-07-29. 기밀 컴퓨팅에서의 **원격 메모리 접근 시간**으로 정의된 두
지표에 대해, 코드가 그 구간을 정확히 재는지 검증한다.

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
