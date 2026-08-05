# 확장 span 지연 — 측정, 분해, 문제 해결

작성 2026-08-05. **v3 워크플로를 모르는 상태에서 읽어도 따라올 수 있도록**
쓴 문서다. 코드 인용은 결론이 아니라 근거로만 쓴다.

셀 단위 수치는 [`V4_RESULT.md`](V4_RESULT.md), 구조 대조는
[`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md), 클라이언트 전체 분해는
[`LATENCY_BREAKDOWN.md`](LATENCY_BREAKDOWN.md).

---

## 1. 왜 재는 구간을 넓혔나

### 1-1. 처음 정의(span v2)가 잰 것

포트의 GET 은 값을 원격 메모리에서 RDMA READ 로 가져온다. 처음에는 그
**전송 구간만** 쟀다.

```text
span v2 (GET)  =  RDMA READ 를 post 한 시각  →  복호가 끝난 시각
span v2 (SET)  =  봉인(seal) 한 시각          →  WRITE CQE 를 본 시각
```

이 정의로 계약(`< 30 µs`)은 통과했다. **GET 7.8 µs, SET 7.8 µs.**

### 1-2. 그런데 클라이언트는 다른 말을 하고 있었다

같은 시각 memtier 가 보고한 SET 지연이 **7.45 ms** 였다. 서버는 7.8 µs 라고
답하는데 클라이언트는 그 **955 배**를 기다리고 있었다.

**차이가 전부 계측 밖이었다.** 요청이 서버에 도착해서 전송이 시작되기까지,
그리고 전송이 끝나서 응답이 나가기까지 — 그 두 구간을 아무도 안 재고 있었다.

### 1-3. 그래서 정의를 넓혔다 (span v3)

```text
span v3 (GET)  =  backend 진입          →  응용에서 값이 보이는 시각
span v3 (SET)  =  backend 진입          →  ITEM_WFLIGHT 해제
```

`backend 진입` 은 `storage_get_item()` / `storage_store_item_pac()` 의 첫
줄이다. **"원격 메모리에 일을 맡기기로 결정한 순간부터, 그 결과를 쓸 수 있게
될 때까지"** 를 잰다.

**정의를 바꿨을 뿐 서버는 그대로였다.** 그런데 계약이 8~79 배로 깨졌다.

---

## 2. v3 에서 GET 하나가 실제로 거치는 길

문제를 이해하려면 이 경로를 먼저 봐야 한다. 조건문 두 줄만 떼어 보면
지엽적으로 보이지만, 경로 위에 놓으면 왜 치명적인지가 드러난다.

### 2-1. 왜 GET 이 즉시 답할 수 없나

stock memcached 는 값이 로컬 메모리에 있으니 해시를 찾아 바로 응답한다.
extstore(외부 저장) 를 쓰면 값이 서버 밖에 있어서 **읽어 오는 동안 기다려야
한다.** 그동안 워커 스레드를 붙잡아 두면 그 스레드가 담당하는 다른 연결이
전부 멈춘다.

그래서 stock 은 이렇게 설계했다:

```text
1  해시에서 헤더를 찾는다 (값은 없고 "어디 있는지" 만 있다)
2  요청을 io_queue 에 넣는다
3  연결을 suspend 하고 워커는 다음 연결로 넘어간다
4  나중에 io_queue 를 한꺼번에 제출(submit)한다
5  IO 가 끝나면 연결을 재개(resume)해서 응답을 보낸다
```

**여기서 두 단어가 핵심이다:**

- **제출(submit)** — 큐에 모인 요청을 실제 IO 로 내보내는 것.
  stock 은 플래시 IO 스레드로 넘기고, 포트는 **RDMA READ 를 post** 한다.
- **재개(resume)** — IO 가 끝난 뒤 suspend 된 연결을 깨워 응답을 보내는 것.

**요청이 기다리는 곳이 두 군데 생긴다: 제출 전과 재개 전.**
span v2 는 그 둘을 다 밖에 두고 3~5 사이만 쟀다. span v3 는 2~5 전체를 잰다.

### 2-2. 제출은 언제 일어나나 — 여기가 첫 번째 문제다

stock 은 제출을 **모아서** 한다. 하나씩 내보내면 IO 스레드 인계 비용
(포트에서는 RDMA doorbell) 을 매번 물기 때문이다. 발화 조건이 둘이다.

```c
/* ① memcached.c:3345 — 같은 스레드에서 IO 걸린 연결이 20 개 쌓이면 */
if (t->conns_tosubmit++ >= settings.ext_submit_batch) {
    thread_io_queue_submit(c->thread);
}

/* ② thread.c:511 — 이벤트루프 한 바퀴(pass)가 끝나면 */
while (!event_base_got_exit(me->base)) {
    event_base_loop(me->base, EVLOOP_ONCE);
    thread_io_queue_submit(me);
```

**`conns_tosubmit` 은 요청 수가 아니라 연결 수다.** 그리고 `t->` 이므로
**스레드마다 따로** 센다.

> #### 그래서 우리 구성에서는 ① 이 한 번도 발화하지 않는다
>
> ```text
> memtier -t 30 -c 4   →  커넥션 120 개
> memcached -t 30      →  스레드 30 개
> 스레드당 커넥션        →  4 개
> ```
>
> 스레드가 가진 연결이 **4 개뿐인데 20 개를 기다린다.** 도달할 수 없다.
> `thread_io_queue_submit` 이 `conns_tosubmit` 을 0 으로 되돌리므로 pass 마다
> 최대 4 까지만 올라간다.
>
> **결과: 모든 GET 이 ② — 이벤트루프 한 바퀴가 끝날 때까지 — 기다린다.**

이것이 `admit` 구간이다. 요청이 backend 에 들어와서 실제로 post 되기까지.

그리고 **파이프라인이 깊을수록 pass 가 길어진다.** 한 pass 에서 파싱할 명령이
많아지기 때문이다. 그래서 `admit` 은 부하와 함께 자란다 —
pipe 8 / 16 / 32 에서 16.6 / 28.0 / 53.9 µs 로 측정됐다.

### 2-3. 재개는 언제 일어나나 — 여기가 두 번째 문제다

제출한 뒤 완료(CQE)를 거두고 연결을 재개해야 한다. v3 의 코드는 이랬다:

```c
thread_io_queue_submit(me);                        /* 제출 */

if (me->ext_worker != NULL) {
    unsigned int out = extstore_worker_outstanding(me->ext_worker);
    if (out) {                                     /* ← 조건문 */
        do {
            if (extstore_worker_drain(...) > 0) {
                storage_flush_returns();           /* ← 재개가 여기 안에만 있다 */
            }
            ...
        } while (out && ++spins < settings.ext_drain_spin);
    }
}
```

**`storage_flush_returns()` — 즉 재개 — 가 `if (out)` 블록 안에만 있다.**
`out` 은 "이 워커가 아직 회수 못 한 IO 가 있는가" 다.

> #### SET 에서 이 조건문이 자기 발등을 찍는다
>
> SET 의 제출 경로(`storage_flush_pending_writes`)는 **제출하면서 완료도
> 같이 거둔다.** 거둔 완료는 재개 대기열에 올려두기만 한다.
>
> 그런데 그 과정에서 **CQ 가 비워진다.** 그러면 바로 다음 줄의
> `extstore_worker_outstanding()` 이 **0** 을 돌려주고, `if (out)` 이 거짓이 되어
> **재개 블록이 통째로 건너뛰어진다.**
>
> ```text
> 제출 경로가 완료를 거둔다  →  CQ 가 빈다  →  out == 0
>                            →  if (out) 이 거짓
>                            →  storage_flush_returns() 가 안 불린다
>                            →  응답이 다음 pass 까지 대기
> ```
>
> **완료가 이미 도착해 있는데도 응답이 안 나간다.** 일을 빨리 끝낸 것이
> 오히려 응답을 늦춘다.

이것이 `ret` 구간이다. 완료를 관측한 뒤 응용에서 보이기까지.

SET-only 에서 이게 극단으로 간다 — GET 이 없으니 CQ 에 남는 것이 더 없고,
`out == 0` 이 더 자주 성립한다.

---

## 3. 측정 — EXP-0 (v3 코드 그대로, `pipe=256`)

정의를 넓힌 직후, **코드를 하나도 안 고친 상태**에서 기준선을 잡았다.

```text
워크로드      ops/s     span v3    = admit  +  v2   +  ret
GET-only     11.932 M    242.29     217.12    25.16     —
1:9 혼합     10.055 M    311.77     285.16    26.59     —      (GET)
                         188.75       0.51    15.13    173.11  (SET)
SET-only      4.133 M   2380.29       0.61     7.84   2371.84
```

원본은 `experiments/exp0-20260801/FINDINGS.md`.

**§2 에서 유도한 두 대기가 그대로 나온다:**

| 구간 | 크기 | §2 의 어느 문제인가 |
|---|---:|---|
| GET `admit` | 217~285 µs | 2-2. pass 끝까지 제출 안 됨 |
| SET `ret` | 173~2,372 µs | 2-3. `if (out)` 이 재개를 건너뜀 |
| GET `v2` | 25~27 µs | 실제 RDMA 왕복 + 복호 |

```text
혼합 GET     311.77 중 admit 285.16  =  91.5%
혼합 SET     188.75 중 ret   173.11  =  91.7%
SET-only    2380.29 중 ret  2371.84  =  99.6%
```

**span 의 91~99.6% 가 전송이 아니라 대기였다.** RDMA 자체는 25 µs 로 이미
충분히 빨랐다.

> **정의가 성능을 바꾼 것이 아니다.** 같은 서버를 다르게 쟀을 뿐이고,
> 그 대기는 span v2 시절에도 똑같이 있었다. 클라이언트가 7.45 ms 를 보고하던
> 것이 그 증거다.

---

## 4. 고친 것 — 각 수정이 어느 대기를 겨냥했나

### 4-1. `admit` → 큐를 거치지 않고 그 자리에서 post

```c
/* storage.c:568 */
/* 인라인 제출이면 큐를 거치지 않는다 — 아래에서 eio 가 다 채워진 뒤
 * 그 자리에서 post 한다. 큐에 넣어두면 이 연결의 나머지 요청이 전부
 * 파싱될 때까지 기다리고, 그 대기가 span v3 의 admit 이다. */
if (!settings.ext_submit_inline)
    STAILQ_INSERT_TAIL(&q->stack, (io_pending_t *)p, iop_next);
```

`ext_submit_inline` 을 켜면 `io_queue` 를 건너뛴다. **pass 끝을 기다리지
않는다.** 발화하지 않는 20 연결 조건도 무관해진다.

배칭 이득이 사라지는 대신 `ext_post_chain`(N 건을 한 submit 으로 묶음)과
`ext_reap_every`(N 건마다 완료 회수) 를 노브로 빼서 **어디서 모을지를 측정으로
정하게** 했다. 운영값은 둘 다 8 이다.

### 4-2. `ret` → 조건문 앞에서 무조건 재개

```c
/* thread.c:522-531 (v4) */
storage_post_chain_flush(me);
storage_flush_pending_writes();
storage_flush_returns();                    /* ← v4 가 추가. 조건문 밖이다 */
unsigned int out = extstore_worker_outstanding(me->ext_worker);
if (out) { ... }
```

`if (out)` 앞에 **무조건 실행되는** `storage_flush_returns()` 를 넣었다.
제출 경로가 CQ 를 비워 `out == 0` 이 되더라도 **이미 거둔 완료는 이 pass 에서
응답으로 나간다.**

코드 주석이 그때의 측정을 적어놨다 — *"측정상 이 한 pass 가 SET span v3 의
287.64 µs 중 대부분이었다(RDMA 자체는 6.79 µs)."*

### 4-3. 그 외 — 노브 넷을 측정으로 정했다

```text
ext_submit_inline   큐 우회 (위 4-1)
ext_post_chain      N 건을 한 submit 으로 묶는다            운영값 8
ext_reap_every      N 건마다 완료를 회수한다                 운영값 8
ext_admit_max       admission 상한                          운영값 64
```

**`reap` 은 캠페인에서 12 → 8 로 내려 GET span 을 17% 줄였다.** 원래 건너뛰려
했던 축인데 재보니 가장 큰 단일 개선이었다.

---

## 5. 결과

```text
              혼합 처리량   GET span v3   SET span v3
v3 (span v2)   10.06 M         7.8           7.8       ✓ ✓   같은 서버를
v3 (span v3)   10.06 M       311.77        188.75      ✗ ✗   다르게 쟀을 뿐
v4 최종        11.10 M        22.31          9.11      ✓ ✓
```

**GET span 14 배, SET span 21 배 감소.** 처리량은 오히려 10.4% 올랐다 —
대기를 걷어내면 같은 CPU 로 더 많이 처리한다.

최종 게이트(각 120 초):

```text
GET-only   13.397 M   span 21.90 µs   (adm 4.39 + v2 17.51)
1:9 혼합   11.099 M   GET 22.31 / SET 9.11 µs
```

---

## 6. 이 과정에서 내가 틀렸던 것

문제 규명이 한 번에 된 것이 아니라 **원인을 두 번 잘못 적었다.** 기록해 둔다.

| 처음 적은 원인 | 실제 |
|---|---|
| "읽기 버퍼를 다 파싱해야 제출" | 버퍼가 아니라 **연결 20 개**가 기준. 그리고 우리 구성에서는 그 조건이 발화조차 안 한다 |
| "재개를 다음 pass 로 미룸" | 미루는 게 아니라 **조건문이 블록을 건너뛴다.** 능동적 지연이 아니라 누락이다 |

둘 다 "대충 맞는 말" 이라 그럴듯했지만, 그대로 뒀으면 **수정 위치를 잘못
잡았을 것이다.** 버퍼가 문제라면 파싱을 고쳐야 하고, 미루는 게 문제라면
스케줄을 고쳐야 한다. 실제 수정은 둘 다 아니었다.

원 분석(`experiments/exp0-20260801/FINDINGS.md` §3·§4)은 정확했는데
**내 요약이 원본을 대신하면서 틀렸다.**

---

## 7. 남은 것 — `post`

span v3 는 22 µs 로 계약 안에 들어왔다. 그런데 **클라이언트 체감은 여전히
2.3 ms** 다. 2026-08-04 에 계측을 넓혀 그 사이를 재보니:

```text
클라이언트 2,277.58 µs
├ 네트워크 + 클라이언트 큐잉   1,786 µs   78.4%
└ 서버 체류                      491 µs   21.6%
   ├ que    소켓read → 명령시작  108 µs
   ├ pre    명령 → backend       ~1 µs
   ├ span v3  [이 문서가 다룬 것]  22 µs    0.9%
   └ post   v3 완료 → sendmsg    360 µs   15.8%
```

**`post` 가 span v3 의 16 배다.** 완료 콜백이 응답을 보내지 않고
`g_ret_head` 에 주차하고(`storage.c:474`), 드레인 루프 끝이나 reap tick 에서만
방출하기 때문이다 — **§2-3 에서 고친 것과 같은 계열의 문제가 한 단계 뒤에
남아 있다.**

다만 `L = N/X` 항등식상 이걸 줄여도 클라이언트 체감이 그만큼 줄지는
**아직 확인되지 않았다.** 대기가 다른 곳으로 옮겨갈 수 있다.
상세는 [`LATENCY_BREAKDOWN.md`](LATENCY_BREAKDOWN.md).
