# GET 경로 전체 워크플로 — 요청 도착부터 응답 송신까지

본문 작성 2026-07-30(v3 기준). **v4 에서 제출·수거·재개의 위치가 바뀌었다** —
아래 §v4 를 먼저 읽고 본문으로 갈 것.

구조 정본은 `md/V2_ARCHITECTURE.md`, v3→v4 구조 변화는
`md/V3_TO_V4_CHANGES.md`, 성능 이력은 `md/OPTIMIZATION_HISTORY.md`,
GET/SET 대조는 `md/GET_SET_CONCURRENCY.md`, 계측 정의는
`md/SPAN_MEASUREMENT_REVIEW.md` 를 따른다.

## §v4. 무엇이 바뀌었나 — 본문보다 이것이 우선한다

**v3 는 GET 을 상류 memcached 의 `io_queue` 배칭에 태웠다. v4 는 우회한다.**
단계 번호는 §1 타임라인과 같다.

| 단계 | v3 (본문) | v4 (현행) |
|---|---|---|
| 6e | `q->stack` 에 삽입만 | **체인에 붙이고, `chain` 건 차면 그 자리에서 post** |
| 8 | pass 끝 `thread_io_queue_submit` 이 일괄 제출 | **없음.** 파싱 루프 안에서 이미 나갔다 |
| 10 | pass 끝 drain 에서 처음 폴링 | **`reap` 건마다 post 자리에서 수거** |
| 13·14 | 보류했다가 **다음 pass** 에 재개 | **거둔 그 pass 에서 재개.** 파싱 중인 연결과 자기 자신만 제외 |

v4 의 실제 흐름:

```text
파싱 루프 (연결 하나의 읽기 버퍼)
 └ GET 하나 파싱
    └ storage_get_item
       ├ p->c = t->cur_conn        ← post 전에 채운다 (아래 위험 ②)
       ├ 체인에 append
       ├ 체인 == chain 건  → pending_chain_flush() → 실제 RDMA READ post
       └ reap 틱          → 체인 flush + CQ drain + 완료 재개
 ⇣ 버퍼를 다 파싱한 뒤
 storage_post_chain_flush()   남은 체인을 내보낸다
 storage_flush_returns()      남은 재개를 처리한다
```

**이 변경이 없앤 대기**(v3 실측):

```text
GET admit  285.16 µs  io_queue 를 연결 20 개 모일 때까지 붙들었다 (GET-only 217.12)
GET v2      26.59 µs  CQE 가 pass 끝까지 폴링조차 안 됐다
SET ret    173.11 µs  CQ 가 이미 비어 재개 블록이 건너뛰어졌다 (SET-only 2371.84)
```

### v4 에서 새로 생긴 위험 셋

인라인 post 는 **완료가 post 직후에 돌아올 수 있게** 만들었다. co-located
RDMA 는 5 µs 라 파싱 루프 안에서 완료가 난다. 여기서 서버가 두 번 죽었다.

```text
① 파싱 중인 연결을 재개하면 죽는다
   drive_machine 이 아직 그 연결을 돌고 있는데 conn_worker_readd 가 걸린다
   → t->cur_conn 으로 표시하고 그 연결만 제외
     (proto_text.c: GET 디스패치 스위치 4 자리 + multiget 루프와 그 오류 경로)

② 자기 자신의 pending 을 재개하면 죽는다
   p->c 가 NULL 인 채 완료가 와서 conn_resp_unsuspend(NULL,…) → segfault at 0xfc
   → p->c = t->cur_conn 을 post **전에** 채운다

③ 락 보유를 추측하면 멈춘다
   meta-get 의 limited_get_locked 가 item_lock 을 쥔 채 들어오고
   storage_set_return_cb 가 같은 락을 다시 잡는다 → 워커가 futex 에서 정지
   → item_trylock 으로 질의한다
```

②는 세 번 만에 잡았다. 앞의 두 번은 추측이었고, 세 번째에 `dmesg` 의 폴트
주소(`0xfc`)를 먼저 본 것이 답이었다.

### 손잡이

| 설정 | 하는 일 | 운영값 |
|---|---|---:|
| `ext_submit_inline` | 이 경로 전체를 켠다 | on |
| `ext_post_chain` | post 를 N 건 묶는다 → `adm` 을 정한다 | 8 |
| `ext_reap_every` | N 건마다 수거·재개 → `v2` 를 정한다 | 8 |

**유효 체인은 `min(chain, reap)` 이다** — `storage.c:607` 이 reap 틱 안에서
`pending_chain_flush()` 를 부르므로 `reap` 이 작으면 체인이 차기 전에 비워진다.
두 값을 따로 조정하면 의도한 값이 안 나온다.

**체인은 건수로만 끊긴다 — 시간 타임아웃이 없다.** 그래서 저부하에서 오히려
`adm` 이 크다(pipe=8 에서 5.83 µs, pipe=256 에서 3.70 µs).

**단일 요청은 체인이 안 차므로 `thread.c:522` 의 루프 레벨 flush 에서
나간다** — stock 의 `thread_io_queue_submit()` 과 같은 지점이다. **갇히지는
않는다**: `event_base_loop(EVLOOP_ONCE)` 가 리턴한 **직후** 조건 없이
실행되므로 체인은 쌓인 그 iteration 안에서 비워지고, **잠들기 전에** 나간다.
v4 가 바꾼 것은 **문턱**이고(연결 20 → 요청 8), 고립된 한 건의 지연은 v3 와
같다.

### 본문 §0 의 기준 수치는 낡았다

본문 §0 은 `mc28 / W24 / nqp2 / hp22` 의 2026-07-31 값이다. 현행은
`mcT30 / W24 / nqp4 / hp22 / reap8 / chain8` 이고 게이트는
**GET-only 13.397 M / span 21.90 µs** 다(`OPTIMAL_RUNBOOK.md`).
아래 본문의 단계별 코드 설명은 위 표의 네 단계를 빼면 그대로 유효하다.

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

## 1. 타임라인 한눈에 (v4)

워커 하나가 remote hit 한 건을 처리하는 전 구간이다. ◆는 공유 자원,
★는 비동기 경로의 핵심 지점, **▶** 는 **span v3 계측 경계**다.

```text
 단계                         코드                                      자원/상태
────────────────────────────────────────────────────────────────────────────────
 1  소켓 이벤트→읽기          event_handler → try_read_network           worker rbuf
 2  다음 GET prefetch         proto_text.c:436                           assoc bucket
 3  명령 파싱                 process_command_ascii → process_get_command —
 4  hash lookup               process_get_cmd → limited_get → item_get   ◆item_lock[hv]
 5  응답 머리 구성            VALUE key flags bytes [cas]                mc_resp
 6 ▶★READ 등록                storage_get_item  (storage.c:459)          아래 6a~6f
 6a   **span v3 시작**        t_enter = extstore_prof_stamp()            storage.c:462
 6b   평문 목적지 확보        worker TLS plaintext cache                 worker 전용
 6c   pending context 확보    t->io_cache                                worker 전용
 6d   응답 data iov 예약      resp_add_iov(resp, "", len)                아직 빈 포인터
 6e   remote loc 복사 + p->c  ITEM_HDR → obj_io, eio->t_enter 저장        storage.c:569
 6f   **체인에 append**       g_chain_n++                                worker 전용
      ├ g_chain_n >= chain(8) → pending_chain_flush()  → 9 로 (즉시)
      └ reap 틱               → 체인 flush + 10~14 (그 자리에서)
 7  ★응답 suspend             conn_resp_suspend                          connection 보류
 8  pass 끝 체인 flush        thread.c:522 storage_post_chain_flush      체인이 안 찼을 때만
 9  READ post                 worker_post (extstore.c:789)               아래 9a~9d
 9a   window/ORD 검사         outstanding<W, read_out[QP]<ORD            worker/QP
 9b   bounce slot 확보        bounce_free bitmap                         worker 전용 DMA
 9c   **span v2 시작**        io->t_start = prof_rdtsc()                 ← v3 아님
 9d   RDMA READ post          ibv_post_send                              worker QP
10  CQ drain                  reap 틱마다 / pass 끝 / 0-timeout 이벤트    worker CQ
11  ★CPU visibility          coherent MR 이라 SYNC 없음                   —
12 ▶★복호·검증                _storage_get_item_cb → ext_crypto_open      transient plaintext
       **span v2·v3 동시 종료**  crypto_done                             extstore.c:1244
13  완료 보류                 g_ret_head 에 pending 삽입                  worker TLS
14  ★응답 resume              storage_flush_returns → conn_resp_unsuspend connection 재개
15  응답 송신                 conn_io_resume → conn_mwrite → transmit    TCP/IPoIB
16  자원 해제                 resp_finish → storage_finalize_cb          plaintext/stub ref
```

### 계측 경계 — v2 와 v3 가 어디서 갈리는가

```text
span v2   9c (post 직전)   →  12 (복호 완료)      admission 을 통째로 빠뜨린다
span v3   6a (진입)        →  12 (복호 완료)      ← 계약이 쓰는 정의
admit     6a → 9c                                 그 차이
```

**세 값은 각각 독립으로 집계된다** — v3 를 admit 에서 빼서 만드는 게 아니다.

```text
prof_r_e2e   crypto_done − t_enter    extstore.c:1244   → extstore_prof_read_e2e_avg_ns
prof_r       crypto_done − t_start    (셀렉터 1)         → extstore_prof_read_avg_ns
prof_r_admit t_start − t_enter        extstore.c:1248   → extstore_prof_read_admit_avg_ns
```

그래서 `admit + v2 = v3` 가 **정합성 검사**로 성립한다. EXP-0 GET-only
pipe=256 에서 `217.12 + 25.16 = 242.28` 대 실측 `242.29` 다.

`tools/exp0-slice.py` 의 `Gv3` 열은 `re2ea`(= `..._e2e_avg_ns`)를 읽는다.
**캠페인 표의 span 은 전부 v3 다.** `..._avg_ns`(v2)도 같이 수집되지만
`+v2` 열에만 쓴다.

> **이 절은 원래 v3 시대 타임라인 그대로였다.** 9c 를 "span 시작"이라고만
> 적어 v2 시작점이 span 의 시작처럼 읽혔고, `t_enter` 를 찍는 6a 가 아예
> 없었다. 측정 자체는 v3 가 맞았지만 **문서만 보면 그렇게 읽히지 않았다** —
> 관리자가 이 절을 읽고 "실험이 정말 v3 로 측정된 게 맞나"를 물어 발견했다.

핵심은 6~14 다. `storage_get_item()` 은 READ 완료를 기다리지 않고 요청만
등록한다. 연결의 해당 응답을 suspend 한 뒤 워커는 다른 연결과 요청을 계속
처리한다. **v4 에서는 6f 의 체인이 차면 그 자리에서 post 되고, reap 틱이면
수거·재개까지 파싱 루프 안에서 일어난다.**

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
