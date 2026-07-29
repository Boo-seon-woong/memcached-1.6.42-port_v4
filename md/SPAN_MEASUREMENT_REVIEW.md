# span latency 계측 리뷰 (코드 기준)

작성 2026-07-29. `read_avg_ns`(게이트 판정 지표)가 무엇을 재고 무엇을 재지
않는지, 계측이 엄밀한지에 대한 코드 레벨 검토.

## 1. 측정 구간의 정확한 경계

| 지점 | 코드 | 시각 |
|---|---|---|
| 시작 `t_start` | `extstore.c:716-718` — `ibv_post_send()` **직전** 배치 단위로 `rdtsc()` | wire 진입 |
| 중간 `t_end` | `extstore.c` drain — CQE poll 후 `ibv_advise_mr(SYNC_FOR_CPU)` 완료 시점 | DMA 가시화 |
| 종료 | `extstore_prof_read_done()` — AES-GCM 복호 완료 후 `prof_record(crypto_done - t_start)` | 평문 준비 |

즉 **span = post 직전 → CQE → SYNC_FOR_CPU → decrypt 완료**.

## 2. 엄밀한 부분

- **평균은 정확값**이다. `prof_record`가 `sum += ns`, `count++`를 누적하고
  `prof_summarize`가 `sum/count`를 낸다. 히스토그램에서 역산한 근사가 아니다.
- **p50/p99는 100 ns 버킷** 히스토그램(`PROF_BUCKETS 32768`, 0~3.27 ms)에서
  누적분포로 산출. 24 µs 지점에서 해상도 0.4%.
- **워커 간 오염 없음**: `g_drain_worker`가 `_Thread_local`(extstore.c:458)이라
  완료 콜백이 항상 자기 워커 히스토그램에 기록된다.
- **TSC 신뢰 가능**: `CLOCK_MONOTONIC` 대비 50 ms 캘리브레이션. rdtsc와
  clock_gettime 호출 간격(수십 ns)만이 오차원이라 상대오차 ~1e-6.
  invariant TSC이므로 코어 주파수 스케일링(측정 시 71%)의 영향을 받지 않는다.
- **중복 계상 없음**: 기록 후 `io->t_start = io->t_end = 0`. 재시도는 새
  `t_start`를 받아 별도 표본이 된다.
- **표본 커버리지 검증 가능**: `extstore_prof_read_count`를 `cmd_get`과
  대조하면 누락률이 나온다(실측 0.0007% — 리셋 경계 오차).

## 3. 측정에서 **빠지는** 것 — 해석의 핵심

### 3.1 window 대기(parking) 시간이 빠진다

`worker_post()`에서 window(W)가 가득 차면 요청은 `w->wait_head`에 park되고
`wait_enq`만 증가한다(`extstore.c:706-712`). **`t_start`는 이때 찍히지 않고,
실제로 post될 때 찍힌다.** 따라서 window 대기 시간은 span에 잡히지 않는다.

이는 사소하지 않다 — 실측에서 `wait_enq`는 op당 약 3회로, parking은 예외가
아니라 상시 상태다. 그래서:

- pipeline을 깊게 해도 span이 안 움직인다(초과분은 소켓/park에서 대기)
- W를 올리면 span이 오른다(wire 위 동시성이 실제로 늘어남)

이 두 관측은 이 코드 구조의 직접적 귀결이다.

### 3.2 엔진 바깥 전부가 빠진다

TCP recv, 프로토콜 파싱, hash/item lock/assoc_find, io_pending 할당, 응답
구성, sendmsg — 전부 span 밖이다.

### 3.3 결론: span ≠ 서비스 시간

`span 23.9 µs` vs `client avg 1.72 ms`는 72배 차이인데, 대부분은 pipeline
깊이 160에 의한 의도된 대기다. **게이트 30 µs는 클라이언트 체감 지연의
상한이 아니다.** span은 "wire에 올라간 원격 읽기가 평문이 되기까지"를 재는
장치 지표다.

계약이 그렇게 정의돼 있고(`md/V2_CODE_SPEC.md`) 문서에도 그렇게 적혀 있으나,
수치를 인용할 때는 이 구분을 함께 제시해야 오해가 없다.

## 4. 판정

계측 자체는 **정의된 구간에 대해 엄밀하다.** 평균은 정확값, 표본 누락률이
검증 가능하고, 스레드 안전성과 시계 정확도에 문제가 없다.

다만 **그 정의가 서비스 지연이 아니라는 점**이 이 지표의 본질적 한계다.
클라이언트 체감 지연을 계약에 넣으려면 별도 지표(예: request 도착 →
응답 write 완료)를 새로 계측해야 하며, 현재 코드에는 그 계측이 없다.

## 5. 기능 정상성 (2026-07-29 실측 런 기준)

| 확인 항목 | 결과 |
|---|---|
| `prof_read_count` vs `cmd_get` | −0.0007% — 모든 GET이 remote READ를 거침 |
| hit rate | 100.00% |
| correctness 6종 | 전부 0 (miss/badcrc/read·write fail/engine_dead/leak) |
| badcrc = 0 | DMA sync 동작 + GCM 검증 통과 |
| 서버 vs 클라이언트 | 10.229M vs 10.218M — 0.1% 일치 |

기능적으로 정상 동작한 상태에서 나온 수치가 맞다.

한 가지 유보: 해당 런의 창은 **30초**였다. 측정 규율상 30초 단발은 spot
check이며, 확정 주장에는 60초×3 또는 300초 지속이 필요하다.
