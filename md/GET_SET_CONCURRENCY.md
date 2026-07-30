# GET 비동기 / SET 동기 — 구조 설명

작성 2026-07-29. SET이 GET보다 33배 느리고 혼합 시 GET까지 끌어내리는 이유는
RDMA가 아니라 **두 경로의 동시성 구조가 다르기 때문**이다. 코드로 설명한다.

## 한 줄 요약

```text
GET  요청을 중단(suspend)시키고 워커는 다른 연결로 넘어간다 → 워커당 W=24개 동시
SET  자기 WRITE CQE가 올 때까지 워커가 busy-wait한다        → 워커당 1개
```

## 1. GET — 중단 / 재개 (asynchronous)

memcached upstream이 원래 flash extstore용으로 갖고 있던 **io_queue +
resp suspend** 기구를 그대로 쓴다. 워커는 절대 블록되지 않는다.

### 1-1. 제출: 요청을 큐에 걸고 즉시 반환

`storage_get_item()` (`storage.c`)이 하는 일은 **등록**이지 대기가 아니다.

```c
io_pending_storage_t *p = do_cache_alloc(t->io_cache);
p->active = true;
p->resp   = resp;              // 나중에 깨울 응답 객체
p->hdr_it = it;                // 원격 위치를 담은 stub
p->read_it = new_it;           // 복호 결과를 받을 로컬 슬롯

resp_add_iov(resp, "", iovtotal);   // 응답 iov 자리만 예약 (데이터는 나중)
resp->io_pending = (io_pending_t *)p;

STAILQ_INSERT_TAIL(&q->stack, (io_pending_t *)p, iop_next);
return 0;                      // ← 여기서 바로 돌아간다
```

응답은 `resp->suspended = true`, `c->resps_suspended++`로 **보류 상태**가 되고,
워커는 같은 연결의 다음 명령, 그리고 **다른 연결들**을 계속 처리한다.

### 1-2. 일괄 제출 → wire

이벤트 루프 한 바퀴가 끝나면 `thread_io_queue_submit(me)`가 큐에 쌓인
요청들을 한 번에 넘긴다 (`thread.c:507`).

```text
storage_submit_cb → extstore_worker_submit → worker_post → ibv_post_send
```

여러 연결의 GET이 **하나의 배치로 묶여** 나간다. 이 배치화가 sync ioctl과
sendmsg 고정비를 상각하는 원천이다.

### 1-3. 완료 → 재개

두 지점에서 CQ를 거둔다.

```c
/* drain point (a) — 배치 직후 유계 스핀 (thread.c:513-531) */
do {
    if (extstore_worker_drain(me->ext_worker, 32) > 0)
        storage_flush_returns();          // ← 완료된 것들을 재개
    ...
} while (out && ++spins < settings.ext_drain_spin);
if (out) worker_storage_arm_drain(me);    /* drain point (b): 0-timeout 이벤트 */
```

완료 콜백 `_storage_get_item_cb()`가 복호까지 마치면
`storage_flush_returns()` → `conn_io_queue_return()` → `storage_return_cb()` →
`conn_resp_unsuspend()`로 응답이 깨어나 전송된다.

**핵심**: 워커는 이 사이 어디에서도 특정 요청을 기다리지 않는다. `W=24`개의
READ가 동시에 wire 위에 떠 있고, 워커는 그동안 다른 일을 한다.

## 2. SET — 동기 대기 (synchronous)

`storage_store_item()`은 명령 처리 경로 **한복판에서 인라인 호출**된다
(`memcached.c:1655`, `do_store_item()` 안).

```c
if (t->storage && storage_store_item(t->storage, it, &remote_it, hv) != 0) {
    do_store = false;                     // 실패하면 저장 안 함
}
```

즉 이 함수가 돌아오기 전까지 `do_store_item()`도, 그 위의 명령 처리도,
**그 워커 자체도** 진행하지 못한다. 내부는 이렇다.

```c
/* storage.c — 인라인 SET */
prof_start = extstore_prof_stamp();
ext_crypto_seal(slot, it, ntotal, &aad);          // AES-GCM 암호화
prof_crypto_done = extstore_prof_stamp();

obj_io io = { …, .t_start = prof_start, .t_end = prof_crypto_done };

while (extstore_worker_outstanding(w) >= g_worker_window)   // window 대기
    extstore_worker_drain(w, 32);

extstore_worker_post_write(w, &io);               // SYNC_FOR_DEVICE + post

while (!wait.done) {                              // ★ 자기 CQE를 기다린다
    atomic_fetch_add(&g_worker_write_spins, 1);
    if (extstore_worker_drain(w, 32) < 0) break;
}

extstore_worker_staging_put(w, slot);
/* … ITEM_HDR 채우고 STORED */
```

★ 표시한 루프가 전부다. **워커가 자기 쓰기 완료를 busy-wait한다.** 실측
`ext_worker_write_spins / cmd_set = 83.5` — SET 하나당 CQ를 83.5번 긁는다.

### 왜 이렇게 만들었나

`STORED`는 **WRITE CQE 확인 후에만** 반환해야 한다는 계약 때문이다
(`md/V2_CODE_SPEC.md`). 원격에 실제로 안착하기 전에 성공을 응답하면 내구성
보장이 깨진다. GET에는 upstream이 물려준 suspend/resume 기구가 있었지만
**SET에는 그 기구가 없어서** 동기 대기로 구현됐다.

## 3. 두 구조가 만드는 결과

| | GET | SET |
|---|---|---|
| 워커당 동시성 | **24** (`ext_worker_window`) | **1** |
| 배치화 | 여러 연결의 요청이 한 배치 | 없음 (1건씩) |
| 워커 점유 | 없음 (중단 후 다른 일) | 완료까지 전점유 |
| 실측 처리량 | 10.12~10.25 M ops/s | 0.294~0.311 M ops/s |
| span | 25.4 µs | 5.4~6.3 µs |

**span만 보면 SET이 4배 빠르다.** RDMA 왕복 자체는 SET이 더 짧다. 그런데
처리량은 33배 낮다 — 구조 차이가 전부다.

### 혼합 워크로드에서 GET까지 느려지는 이유

워커가 SET에 붙잡혀 있는 동안, **같은 워커에 배정된 연결들의 GET이 뒤에서
대기**한다(head-of-line blocking). 그래서 1:1 혼합에서 GET이 10.12 M →
0.296 M으로 무너진다. GET 경로가 느려진 게 아니라 **차례가 오지 않는** 것이다.
근거: 혼합에서도 GET span은 25.4 → 26.0 µs로 거의 그대로다.

## 4. 개선하려면 (미착수 → 2026-07-30 후기 참조)

방향은 **SET을 GET과 같은 중단/재개 구조로 바꾸는 것**이다.

```text
현재: seal → post → [busy-wait CQE] → STORED
목표: seal → post → 응답 suspend → 워커는 다른 연결 처리
                  → CQE 도착 시 resume → STORED
```

`STORED`를 CQE 이후에 보낸다는 계약은 그대로 유지된다 — 응답 시점이 아니라
**대기 방식**만 바뀌기 때문이다. GET이 쓰는 `io_pending_t` / `resp->suspended`
/ `conn_resp_unsuspend()` 기구를 SET에도 태우면 된다.

다만 착수 전 미해결이 하나 있다. SET 1건당 워커 점유는 **90 µs**인데 span은
5.4 µs로 6%뿐이고, 1:9 혼합에서 `busyCPU`가 **23.2/30 (memcached 28코어의
83%)** 로 **워커가 포화되지 않은 채** SET이 ~300 K에서 상한을 친다. 즉 남은
85 µs는 CPU 작업이 아니라 어딘가의 **직렬화·대기**일 가능성이 크다. 그
지점을 먼저 규명하지 않으면 비동기화만으로 얼마가 회수되는지 알 수 없다.

> SET 경로는 이번 캠페인의 최적화 대상이 아니었다. 10M/30 µs 계약은 GET-only
> 기준이며, 위 수치는 기준선 기록이다.

---

## 5. 후기 (2026-07-30) — §4의 "미착수"는 착수·실측됐고, 질문은 바뀌었다

- §4의 방향(중단/재개 구조) 자체는 두 가지 형태로 구현됐고 **둘 다 main에
  오르지 못했다**: watermark gating(`v3-async-set`, 동기 대비 2배 손실
  미규명)과 연결 파킹(`v3-set-10m`, 실 호스트에서 SET-only −40% + 혼합 GET
  반토막으로 기각). 처분 경위는 `V3_REVIEW_FINDINGS.md`, 워크플로 정본은
  `SET_WORKFLOW.md`.
- §4 말미의 미해결("점유 90µs vs span 5.4µs, 남은 85µs의 정체")은 step
  ①②③③′ 이후 규모만 줄어 그대로 남아 있다: **점유 ~16µs vs CPU 7.29µs,
  간극 8.7µs가 off-CPU 대기로 미규명**. 이 규명이 다음 구조 변경
  (publish-at-command)보다 선행이다.
- §3의 혼합 수치(1:1에서 GET 0.296M)는 step 이전 기준이다. step ③′ 시점
  재측정은 1:9 혼합 5.28M, 1:1 혼합 2.73M(`V3_ARCHITECTURE.md` §6).
