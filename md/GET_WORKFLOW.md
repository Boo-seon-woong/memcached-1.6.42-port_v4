# GET 경로 전체 워크플로 — 요청 도착부터 응답 송신까지

작성 2026-07-30. 대상은 **현재 main의 remote-only GET 경로**다. 코드 위치,
자원 소유권, 비동기 중단/재개, RDMA READ, 복호·검증, 응답 전송 후 해제까지
한 요청의 전 구간을 설명한다.

구조 정본은 `md/V2_ARCHITECTURE.md`, 성능 이력은
`md/OPTIMIZATION_HISTORY.md`, GET/SET 대조는 `md/GET_SET_CONCURRENCY.md`,
계측 정의는 `md/SPAN_MEASUREMENT_REVIEW.md`를 따른다.

## 0. 기준 수치 (mc28 / W24 / nqp2 / hp22, **2026-07-31 정본**)

```text
GET-only 처리량          11.779 M ops/s
READ span avg            15.96 µs   (p50 14.4 / p99 44.3)
C_get                    2.369 µs/op
guest busyCPU            27.9 / 30
GET 동시성               worker당 최대 W=24
1:10 혼합에서의 GET      9.268 M ops/s, span 16.03 µs
```

빌드 `771ca34068c7609936b2e58a`(`ce92044`). GET miss·badcrc·RDMA failure·
engine dead·slot accounting leak 전부 0.

> **이전 판(10.12~10.25 M, span 25.4 µs)은 폐기됐다.** 그 사이 coherent MR이
> SWIOTLB 바운스를, GCM 1회 키잉이 op당 재키잉을 걷어냈다. 경위는
> `OPTIMIZATION_HISTORY.md` ⑨·⑪.

**1:10 혼합에서 GET이 CPU의 78.1%를 쓴다.** SET이 op당 2.8배 비싸도 비중을
곱하면 같은 1% 절감의 가치가 GET : SET = 3.6 : 1이다 — 추가 최적화의 레버는
이쪽이 크다.

`READ span`은 클라이언트 지연이 아니다. 서버의 **RDMA READ post 직전부터
CQE, `SYNC_FOR_CPU`, AES-GCM 복호 완료까지**만 잰다. TCP 수신, 파싱, hash
lookup, 제출 전 큐 대기, 응답 전송은 포함하지 않는다.

## 1. 타임라인 한눈에

워커 하나가 remote hit 한 건을 처리하는 전 구간이다. ◆는 공유 자원,
★는 GET 비동기 경로의 핵심 지점이다.

```text
 단계                         코드                                      자원/상태
────────────────────────────────────────────────────────────────────────────────
 1  소켓 이벤트→읽기          event_handler → try_read_network           worker rbuf
 2  다음 GET prefetch         proto_text.c:392-409                       assoc bucket
 3  명령 파싱                 process_command_ascii → process_get_command —
 4  hash lookup               process_get_cmd → limited_get → item_get   ◆item_lock[hv]
 5  응답 머리 구성            VALUE key flags bytes [cas]                mc_resp
 6  ★READ 등록                storage_get_item                           아래 6a~6e
 6a   평문 목적지 확보        worker TLS plaintext cache                 worker 전용
 6b   pending context 확보    t->io_cache                                worker 전용
 6c   응답 data iov 예약      resp_add_iov(resp, "", len)                아직 빈 포인터
 6d   remote loc 복사         ITEM_HDR → obj_io                          로컬 stub
 6e   IO queue 삽입           q->stack                                   worker 전용
 7  ★응답 suspend             conn_resp_suspend                          connection 보류
 8  batch 제출                thread_io_queue_submit → storage_submit_cb worker 전용
 9  READ post                 extstore_worker_submit → worker_post       아래 9a~9d
 9a   window/ORD 검사         outstanding<W, read_out[QP]<ORD            worker/QP
 9b   bounce slot 확보        bounce_free bitmap                         worker 전용 DMA
 9c   span 시작               io->t_start = prof_rdtsc()                 EXT_RDMA_PROF
 9d   RDMA READ post          ibv_post_send                              worker QP
10  CQ drain                  batch 직후 spin 또는 0-timeout event       worker CQ
11  ★CPU visibility          SYNC_FOR_CPU를 완료 READ 묶음에 1회         batch 상각
12  ★복호·검증                _storage_get_item_cb → ext_crypto_open      transient plaintext
13  완료 보류                 g_ret_head에 pending 삽입                   worker TLS
14  ★응답 resume              storage_flush_returns → conn_resp_unsuspend connection 재개
15  응답 송신                 conn_io_resume → conn_mwrite → transmit    TCP/IPoIB
16  자원 해제                 resp_finish → storage_finalize_cb          plaintext/stub ref
```

핵심은 6~14다. `storage_get_item()`은 READ 완료를 기다리지 않고 요청만
등록한다. 연결의 해당 응답을 suspend한 뒤 워커는 다른 연결과 요청을 계속
처리한다. 그래서 같은 워커에 최대 `W=24`개의 READ가 동시에 떠 있을 수 있다.

## 2. 단계별 상세

### 1~3. 이벤트 → prefetch → 파싱

libevent가 소켓 가독 이벤트를 올리면 `event_handler()`가 connection state
machine을 실행하고, 수신 바이트는 워커의 rbuf로 들어간다.
`try_read_command_ascii()`는 현재 명령 다음에 이미 `"get "`이 들어와 있으면
다음 첫 key의 hash bucket을 `assoc_prefetch()`한다
(`proto_text.c:392-409`). 현재 요청을 처리하는 동안 다음 bucket의 DRAM
fetch를 겹치는 cross-request 최적화다.

`process_command_ascii()`는 `CMD_GET`, `CMD_GETS`, `CMD_GAT`, `CMD_GATS`를
`process_get_command()`로 보낸다. ASCII multi-get이면 key마다 별도
`mc_resp`와 pending READ를 만들고 마지막에 `END\r\n`을 붙인다. meta GET과
binary GET도 최종적으로 같은 `storage_get_item()`을 사용한다.

### 4. hash에서 ITEM_HDR 조회

`process_get_cmd()` → `limited_get()` → `item_get()` 순서로 key를 찾는다.
`item_get()`은 다음 순서다.

```text
hash(key)
  → assoc_prefetch(hv)
  → item_lock(hv)
  → do_item_get()/assoc_find()
  → item_unlock(hv)
```

락은 lookup 동안만 잡고 `storage_get_item()`에 들어가기 전에 놓는다.
따라서 RDMA 왕복 동안 bucket lock을 들고 있지 않는다. remote hit의 hash
entry에는 값이 아니라 key와 `item_hdr`만 든 `ITEM_HDR` stub이 있고,
`item_hdr`가 `page_id`, `offset`, `page_version`, sealed length를 가리킨다.

### 5~7. 응답 골격 → READ 등록 → suspend

`process_get_cmd()`는 먼저 ASCII `VALUE` 머리와 flags/bytes/CAS를 응답 iov에
넣는다. 값이 `ITEM_HDR`이면 `storage_get_item()`을 호출한다
(`proto_parser.c:655-719`).

`storage_get_item()`이 하는 일:

1. `ITEM_ntotal(it)` 크기의 복호 목적지를 워커 TLS
   `extstore-plaintext` cache에서 확보한다. cache miss에만
   `do_item_alloc_pull()` slab fallback을 탄다.
2. `t->io_cache`에서 `io_pending_storage_t`를 꺼내 connection, response,
   header stub, 복호 목적지와 finalize callback을 묶는다.
3. 값 길이만큼 빈 iov를 예약한다. 이때 `iov_base`는 아직 `""`이고, 복호가
   성공해야 실제 `ITEM_data(read_it)`로 바뀐다.
4. `ITEM_HDR`의 remote location을 `obj_io`에 복사하고
   `mode=OBJ_IO_READ`, callback=`_storage_get_item_cb`로 지정한다.
5. worker의 `IO_QUEUE_EXTSTORE`에 pending을 넣고 즉시 0을 반환한다.

호출자는 `resp->io_pending`을 확인해 `conn_resp_suspend()`를 실행한다. 이는
`resp->suspended=true`, `c->resps_suspended++`만 설정한다. connection이
`conn_mwrite`에 도달하면 suspended response가 있는 동안
`conn_io_queue/conn_io_pending`으로 이동해 전송을 멈춘다.

이 시점까지 원격 값은 읽지 않았다. 로컬에 존재하는 것은 stub, 빈 응답 자리,
pending context, 복호 목적지뿐이다.

### 8~9. 이벤트 루프 단위 batch 제출 → RDMA READ

이벤트 루프 한 번이 끝나면 worker가 `thread_io_queue_submit()`을 호출한다
(`thread.c:507-511`). `storage_submit_cb()`는 쌓인 pending을 `obj_io`
chain으로 바꿔 해당 worker의 `extstore_worker_submit()`에 넘기고 drain
event를 arm한다.

`worker_post()`는 owner worker만 건드리는 자원으로 READ를 게시한다.

- `outstanding < ext_worker_window`: worker 전체 미완료 상한.
- `read_out[qp] < ext_ord_limit`: QP별 RDMA READ/atomic depth 상한.
- `bounce_free`: NIC이 ciphertext를 쓸 worker-private DMA slot.
- `rr`: ORD 여유가 있는 QP를 고르는 round-robin cursor.
- `ext_batch`: 한 `ibv_post_send()` chain에 묶는 최대 WR 수.

자리가 없으면 실패시키지 않고 worker의 FIFO wait list에 park한다. CQE가
capacity를 돌려주면 `extstore_worker_drain()` 말미가 wait list를 다시
`worker_post()`한다.

실제로 post할 batch가 정해지면 모든 `io->t_start`를 `prof_rdtsc()`로 찍고
`IBV_WR_RDMA_READ` chain을 한 번에 `ibv_post_send()`한다. 이 timestamp가
READ span의 시작점이므로 **wait list나 제출 queue에서 기다린 시간은 span
밖**이다.

### 10~11. CQ 수거 → batched SYNC_FOR_CPU

CQ는 별도 IO thread가 아니라 요청을 받은 worker가 직접 거둔다. 지점은 둘이다.

| drain 지점 | 위치 | 역할 |
|---|---|---|
| (a) batch 직후 | `thread.c`의 worker loop | 최대 `ext_drain_spin`회 bounded poll |
| (b) 잔여 완료 | `ext_drain_handler()` | 0-timeout self event; outstanding 동안 재무장 |

`extstore_worker_drain()`은 최대 `ext_batch`개의 CQE를 `ibv_poll_cq()`로
꺼낸다. 성공한 READ들의 bounce SGE를 모아
`ibv_advise_mr(...SYNC_FOR_CPU, FLUSH...)`를 **한 번** 호출한다. SEV guest가
NIC이 쓴 ciphertext를 CPU에서 보도록 만드는 단계이며, batch당 한 번이라
여러 READ가 비용을 나눠 가진다.

sync가 끝난 뒤 각 CQE의 callback을 호출하고 bounce slot, QP별 `read_out`,
worker `outstanding`을 반환한다. poll 오류나 CQE 실패는 engine을 dead로
표시하고 남은 parked op도 callback 실패 경로로 보내 무한 대기를 막는다.

### 12. AES-GCM open, 재시도, 응답 값 연결

`_storage_get_item_cb()`는 worker의 drain loop 안에서 실행된다. 성공 CQE면
stub의 key hash와 remote `page_id/offset/page_version`으로 AAD를 재구성하고,
bounce의 `[nonce|ciphertext|tag]`를 `read_it`으로 `ext_crypto_open()`한다.

검증 성공 시 예약했던 응답 iov의 `iov_base`를
`ITEM_data(read_it)`으로 바꾼다. 평문은 이 transient buffer에만 있고 hash
table에는 게시되지 않는다.

tag 검증 실패는 검증되지 않은 평문을 응답하지 않고 같은 READ를 최대
`EXT_READ_RETRIES`만큼 worker에 재제출한다. 재시도까지 실패하면 miss로
변환한다. binary는 status/body length를 miss 형태로 고치고, ASCII는 값
iov를 지워 `END` 또는 meta `EN`만 남긴다. remote storage 기동에는
`EXT_CRYPTO_KEY`가 필수이고 운영 경로는 AES-256-GCM을 항상 사용한다.

### 13~14. drain 밖에서 connection resume

callback은 connection을 즉시 깨우지 않는다. 아직 drain이 bounce slot과
outstanding을 정산 중이므로, 재진입을 막기 위해 완료 pending을 worker TLS
`g_ret_head`에 넣기만 한다.

drain 호출자가 루프 밖에서 `storage_flush_returns()`를 실행하면 다음 경로로
응답이 깨어난다.

```text
storage_flush_returns
  → conn_io_queue_return
  → storage_return_cb
  → conn_resp_unsuspend
  → resps_suspended가 0이면 conn_worker_readd
  → conn_io_resume
```

multi-get처럼 한 connection에 pending response가 여러 개면 마지막 pending이
끝나 `resps_suspended==0`이 될 때만 connection을 다시 event loop에 넣는다.
따라서 먼저 끝난 값만 앞질러 전송하지 않고 connection 내 응답 순서를 지킨다.

### 15~16. TCP 송신 → 수명 종료

`conn_io_resume`은 state를 `conn_mwrite`로 바꾸고, `transmit()`이 준비된
response iov들을 `sendmsg`로 보낸다. off-box 기준 이 TCP 응답은 IPoIB를
통해 Genie의 memtier로 간다. RDMA READ는 guest memcached와 Genie MR 사이의
별도 one-sided 데이터 경로다.

응답 전송이 끝나 `resp_finish()`가 `storage_finalize_cb()`를 호출할 때까지
`read_it`을 해제하면 안 된다. finalize 시점에 plaintext cache 또는 slab으로
복호 버퍼를 반환하고, `ITEM_HDR`의 GET reference를 놓고, pending context를
worker `io_cache`로 돌려보낸다.

일반 READ 실패는 stale remote location을 해제하고 stub을 unlink한다. GCM
검증 실패(`badcrc`)는 transient visibility 문제일 수 있으므로 stub을
보존해 다음 GET이 회복할 기회를 남긴다.

## 3. 동시성과 배치가 만들어지는 지점

```text
connection pipeline
  → 여러 mc_resp / pending READ
  → worker IO queue
  → ext_batch 단위 WR chain
  → worker당 W개 outstanding
  → QP별 ORD개 wire READ
  → CQE 묶음당 SYNC_FOR_CPU 1회
```

클라이언트 `--pipeline`은 요청 공급 깊이이고, `ext_worker_window`는 worker의
RDMA outstanding 상한이다. 둘은 같은 값이 아니다. `ext_qp_per_worker=2`는
worker당 RC QP가 둘이라는 뜻이고, 별도 IO thread 두 개라는 뜻도 아니다.

GET 처리량의 구조적 근거는 다음 세 가지다.

1. 특정 GET을 기다리지 않고 connection response만 suspend한다.
2. 여러 연결의 READ를 한 batch로 post하고 sync 고정비를 상각한다.
3. QP/CQ/bounce/wait list를 owner worker만 다뤄 hot path hand-off와 lock을
   없앤다.

## 4. 실패·경합 시 의미

| 지점 | 동작 | 클라이언트에 검증되지 않은 값 전달 |
|---|---|---|
| plaintext/pending 할당 실패 | GET response 생성 실패 | 없음 |
| window/ORD/bounce 부족 | FIFO wait list에 park | 없음 |
| `ibv_post_send` 실패 | engine dead, callback miss 경로 | 없음 |
| CQ poll/CQE 실패 | engine dead, parked op까지 실패 반환 | 없음 |
| GCM tag 실패 | 유계 재시도, 소진 시 miss | 없음 |
| 전송 전 connection 종료 | finalize/abort 경로로 자원 회수 | 없음 |

GET-only에서 `badcrc_from_extstore != 0`은 이상이다. 혼합 workload에서는
같은 key에 대한 SET과 READ가 겹쳐 transient tag 실패가 생길 수 있고,
재시도로 회복하면 클라이언트 miss는 늘지 않는다. 이 경우에도 tag 검증 전
평문은 절대 응답 iov에 연결하지 않는다.

## 5. 바뀌면 안 되는 계약

1. **remote-only**: hash table에는 `ITEM_HDR`만 남고 평문 값은 GET 수명 동안의
   transient buffer에만 존재한다.
2. **authenticate-before-send**: GCM 검증 성공 전에는 예약 iov의 data pointer를
   평문으로 바꾸지 않는다.
3. **owner-worker**: post, CQ drain, decrypt, resume는 요청을 받은 같은 worker가
   수행한다. 완료를 별도 IO thread로 넘기지 않는다.
4. **drain 비재진입**: callback은 pending을 park하고, connection resume는 drain
   loop가 정산을 끝낸 뒤 수행한다.
5. **응답 수명**: plaintext buffer는 `sendmsg`가 끝나 response finalize가
   호출될 때까지 살아 있어야 한다.
6. **유계 자원**: window, ORD, bounce slot이 가득 차면 park하며 로컬 값으로
   fallback하지 않는다.

## 6. 관측 지점

```text
EXT_RDMA_PROF=1
  extstore_prof_read_count
  extstore_prof_read_avg_ns
  extstore_prof_read_p50_ns
  extstore_prof_read_p99_ns
  extstore_prof_read_xfer_avg_ns
  extstore_prof_read_sync_avg_ns
  extstore_prof_read_crypto_avg_ns

stats
  cmd_get / get_misses / get_extstore
  get_oom_extstore / get_aborted_extstore
  badcrc_from_extstore / extstore_read_retries
  extstore_read_failures / extstore_engine_dead
  ext_worker_wait_enq / ext_worker_drain_calls / ext_worker_drain_empty
  ext_slot_acct_leak
```

GET-only 정상 완료의 최소 판정은 miss, badcrc, RDMA read/write failure,
engine dead, slot accounting leak가 모두 0인 것이다. `read_count`는
`stats reset` 경계와 재시도 때문에 `cmd_get`과 소폭 다를 수 있으므로 raw
counter와 workload를 함께 보존한다.

span 총합은 `post 직전 → decrypt 완료`로 정확하지만, 하위 합에는 batch 안에서
앞선 CQE callback의 decrypt를 기다리는 시간이 빠진다. 따라서
`xfer + sync + crypto`가 `read_avg`와 정확히 같지 않은 것은 정상이며,
클라이언트 end-to-end latency와도 같은 열에서 비교하지 않는다.


---

## 부록. 2026-07-31 연산량 감사에서 GET 경로에 대해 확인된 것

perf(`mc-worker`, GET-only) 상위 항목과 판정이다.

| 항목 | 비중 | 판정 |
|---|---:|---|
| EVP 재초기화 (`get_iv_length`+`get_key_length`+`ctrl`+libcrypto) | ~6.0% | **걷어냈다** — 아래 |
| `pthread_mutex_lock`+`unlock` | 9.44% | item_lock. **미귀속** |
| `mlx5_poll_cq_v1` | 3.80% | CQ 폴링 |
| `_copy_from_iter`+`rep_movs_alternative` | 4.37% | TCP 소켓 복사, 고유 |
| `resp_allocate` | 2.88% | 응답 객체 |
| `assoc_find` | 2.07% | 해시 탐색, 고유 |

**걷어낸 것 — GCM 컨텍스트 재키잉.** `ext_crypto_open`이 연산마다
`EVP_DecryptInit_ex(ctx, NULL, NULL, g_key, nonce)`로 키를 넘겨, OpenSSL 3.x가
AES 키 스케줄과 GHASH 테이블을 매번 다시 만들고 그 경로가 provider를 문자열로
조회하고 있었다. 키는 기동 시 한 번 정해진다. 스레드별 ctx에 키를 한 번만 넣고
IV만 바꾸도록 고쳐 `open` 630 → 471 ns, `C_get` 2.523 → 2.369 µs.

**하지 않기로 한 것.**

- **도어벨 배칭** — GET은 **이미 한다.** `worker_post`가 최대 `w->batch`(=32)개
  WR을 체인으로 묶어 `ibv_post_send`를 한 번만 친다.
- **`sev_es_ghcb_hv_call` 2.13%** — 워크로드 비용이 아니다. 호출자가
  `__perf_event_task_sched_out → amd_pmu_disable_all → native_read_msr`로,
  **perf 자신의 PMU MSR 접근이 SEV에서 트랩**하는 것이다. 관측하지 않으면 없다.

**남은 것.** `pthread_mutex_lock`+`unlock` 9.44%가 GET 경로 최대 미귀속
항목이다. 콜그래프가 프레임 포인터 없이 끊겨 어느 락인지 확정하지 못했다 —
`-fno-omit-frame-pointer` 빌드가 있어야 한다.
