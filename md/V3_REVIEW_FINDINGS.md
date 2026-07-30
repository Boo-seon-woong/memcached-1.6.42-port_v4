# v3 SET 경로 코드 리뷰 결함 목록 (2026-07-30)

> **처분 (2026-07-30, 실 호스트 재측정 후).** `v3-set-10m`의 비동기 SET은
> 실측에서 기각됐다 — SET-only 1.0M(main 동기 1.68M 대비 −40%), 1:9 혼합에서
> GET 10.7M → 5.1M. 원인은 B-1 수정이 도입한 연결당 직렬화(STORE_PENDING 시
> 연결 파킹)로, 상한이 연결 수 ÷ 파킹 시간(~112연결/100µs ≈ 1.1M)이라 10M에
> 원리적으로 도달 불가. GET-only 계약(10M/30µs)은 통과(10.7M @ 23.7µs).
>
> main에는 **main 코드(SET 1~3단계)에 실재하는 A-결함 수정만** 남긴다:
> 58d24b5 전체 + 717cc56 중 동기 경로 A-2 hunk(_Thread_local wait/io, 조건부
> staging 반납). A-6은 STORE_PENDING enum이 main에 없어 경계 검사만 적용,
> A-8은 async 전용이라 해당 없음. 비동기 SET·CQ channel·mock 계층·미측정
> 최적화 3건(756e45c, 9b847e3, 69421ff)은 `v3-set-10m` 브랜치에 남는다.
> 후속 설계는 §6.5(publish-at-command) 참조.

> **요약 — non-SEV 서버 작업분 (`v3-set-10m` 브랜치, `6c80637..672f018`)**
>
> SEV/RDMA 호스트 접근 불가 기간에 이 서버에서 완료한 것:
>
> 1. **리뷰**: SET 1~3단계 diff + 파킹된 비동기 SET WIP에서 확정 결함 16건
>    (§1~3) — 전부 수정 (58d24b5, 717cc56).
> 2. **CQ completion channel**: fd를 libevent에 등록하되 "폴링 + idle 시
>    통지 fallback"으로 (adbdda8, §4.3). 실행 검증이 잡은 추가 버그 2건
>    수정 후(79910fd) 대기 중 CPU 1.097 → 0.104 core-s/s.
> 3. **mock verbs 계층**(`tools/mock_rdma.c` + 테스트/프로브): RDMA 장치 없이
>    SET 경로를 실제 구동. 기능 20/20, 사전/사후 A/B로 판별력 확인 (§5, §6.2).
> 4. **호스트 비의존 최적화 3건**: SYNC_FOR_DEVICE 배치화 · `set_pending_t`
>    풀링 · SET 키 prefetch — 정확성 검증 완료, **효과는 미측정** (§6.4).
>
> 효과 미측정분은 `OPTIMIZATION_HISTORY.md`("실측 통과분만 기록")에 넣지
> 않았다. 호스트 복구 시 §6.3(측정 목록)과 §6.4(커밋 단위 교대 A/B)가
> 착수 지점이다.

대상 두 diff을 커밋 로그와 대조해 리뷰했다.

- **(A)** `git diff aac7b32...HEAD` — SET 1~3단계: 워커 전용 item/loc magazine,
  카운터 원자화, spin 카운터 배치화 (`md/SET_COST_ATTRIBUTION.md` §7)
- **(B)** `git diff main...origin/v3-async-set` — 4단계 비동기 SET (파킹된 WIP,
  `md/SET_COST_ATTRIBUTION.md` §8)

확정 결함 **18건**. 전부 코드 라인으로 확인했고, 각 항목의 "실패 시나리오"는
그 라인에서 실제로 도달 가능한 경로다.

## 0. 목표 기준 우선순위

목표는 **GET/SET 각각 10 M ops/s, span < 30 µs**다. 이 기준에서 결함들을
세 부류로 나눈다.

| 부류 | 뜻 | 해당 |
|---|---|---|
| **P0 차단** | 이게 고쳐지지 않으면 10 M 측정 자체가 불가능 | B-1 ~ B-6 |
| **P1 부하 시 발현** | 저부하 A/B에서는 안 보이고 목표 부하에서 터진다 | A-1 ~ A-4, A-9, B-7 |
| **P2 정합성** | 지금은 통계·회계만 오염, 향후 기능이 물려받음 | A-5 ~ A-8 |

동기 SET의 상한이 5.57 M(28워커 × 5.03 µs span)이므로 **비동기화는 선택이
아니라 전제**다(`md/SET_10M_REQUIREMENTS.md`). 따라서 P0은 전부 (B) 쪽이다.

---

## 1. P0 — 비동기 SET 경로 (10 M의 전제 조건)

### B-1. `storage_flush_set_returns`가 LIFO로 게시해 SET 순서를 뒤집는다

`storage.c:611` — ready 목록을 `g_setp_ready_v[--g_setp_ready_n]`로 뒤에서부터
꺼내고, 게시 시점의 조건 검사 없이 `item_replace`/`do_item_link`를 호출한다.

```c
while (g_setp_ready_n > 0) {
    set_pending_t *p = g_setp_ready_v[--g_setp_ready_n];   /* LIFO */
```

같은 연결에서 파이프라인으로 들어온 `set k v1; set k v2`가 한 drain에 함께
완료되면 pop 순서가 v2 → v1이 되어 **v1이 최종값으로 남는다**. 클라이언트는
둘 다 `STORED`를 받았으므로 조용한 데이터 손상이다.

같은 뿌리에서 파생되는 세 가지가 더 있다.

- 이미 `DELETED`를 응답한 키가 뒤늦은 `do_item_link`로 **부활**한다.
- `do_item_link`가 `it->time = current_time`을 찍으므로 대기 중 들어온
  `flush_all`이 **무효화되지 않는다**(`item_is_flushed`가 통과시킨다).
- 같은 연결의 파이프라인 `set k` → `get k`에서 GET이 **miss**한다.
  memcached는 연결 간 순서는 보장하지 않지만 **연결 내 순서는 보장**한다.

> 정정 필요: `storage.c:562`의 주석은 "SET 의미론은 last-write-wins이고
> memcached는 동시 연결 간 순서를 보장하지 않으므로 정상 동작"이라고 적고
> 있다. 연결 **내** 순서에는 해당하지 않는 논거다.

### B-2. `_finalize_mset`에 `STORE_PENDING` 분기가 없다 — resp use-after-free

`proto_text.c:65`. ascii meta-set(`ms`)은 `complete_nread_ascii`에서
`_finalize_mset()`으로 빠지는데 그쪽 `switch`에는 `STORE_PENDING`이 없어
`default`로 떨어진다.

```c
default:
    out_errstring(c, "SERVER_ERROR Unhandled storage type.");
```

suspend 없이 즉시 응답하고 resp가 전송·회수된 뒤, CQE 콜백이 그 resp에
`resp_reset()`을 걸고 쓴다. `conn_resp_unsuspend`는 `resps_suspended`를 -1로
만든다(assert 빌드는 abort, NDEBUG는 연결 영구 정지). 브랜치에서
`ext_async_set` 기본값이 true이므로 `ms` 한 번으로 도달한다.

### B-3. binary SET의 `STORE_PENDING`이 상태 전이를 안 해 `conn_nread`를 재진입한다

`proto_bin.c:389`.

```c
if (ret == STORE_PENDING) { conn_resp_suspend(c, c->resp); return; }
```

`conn_set_state(c, conn_new_cmd)`도, `item_remove(c->item)`도 없이 반환한다.
ascii 경로는 같은 위험을 주석으로 명시하고 전이를 넣어뒀는데(`proto_text.c`
`case STORE_PENDING`) binary에는 안 넣었다. `drive_machine`의 while 루프가
`rlbytes == 0`인 `conn_nread`로 되돌아와 `complete_nread` → `store_item`을
같은 item으로 반복 호출한다 → **원격 WRITE 중복 post, 같은 resp 반복
suspend**, staging 풀이 마를 때까지.

### B-4. pending SET이 staging 슬롯을 물고 있어 워커당 9건에서 막힌다

`storage.c:785` + `extstore.c:671`.

```c
e->w_staging_slots = e->write_slots / nworkers;   /* 256/28 = 9 */
```

동기 SET은 슬롯을 함수 안에서만 잡았으므로 워커당 1개면 충분했다. 비동기는
post부터 이벤트 루프 레벨 flush까지 물고 있으므로 **한 배치 안의 pending 수만큼**
필요하다. 초과하면 `staging_get`이 NULL → `-1` → 정상 SET에 `NOT_STORED`.

리포지토리의 memtier 설정이 pipeline ≥ 8을 쓰므로 기본 설정에서 바로 걸린다.
10 M 목표에는 워커당 outstanding 25건이 필요하다(`SET_10M_REQUIREMENTS.md`)
— **현재 상한의 3배**다.

### B-5. `setp_out_string`이 프로토콜을 모른다

`storage.c:590`. 완료 응답을 항상 ascii `"STORED\r\n"`로 쓴다.

- **binary**: 24바이트 응답 헤더가 아니라 텍스트가 스트림에 들어가
  클라이언트 파서가 깨진다. `c->cas`도 설정되지 않는다.
- **meta**: `"HD"` + return flags가 아니라 `"STORED"`가 나가고 `O`(opaque),
  `k`, `c` 플래그가 사라져 파이프라인 상관관계를 잃는다.
- `process_mset_cmd`는 suspend 후 **fall-through**해서
  (`proto_parser.c:1451` 이후) 상태 2바이트가 안 채워진 iov를 suspend된 resp에
  올린다.

### B-6. proxy internal 경로에서 `cur_conn`/`cur_resp`가 stale이다

`proto_parser.c:841`. `process_update_cmd`는 `t->cur_conn`을 쓰지만, proxy
internal(`mcp.internal`) 경로는 `cur_sfd`만 설정한다. 같은 워커가 직전에
처리한 평범한 SET의 `cur_conn`/`cur_resp`가 그대로 남아 있어, pending SET이
**엉뚱한 연결과 회수된 resp에 묶인다**. proxy 자신의 resp는 영구 suspend.

---

## 2. P1 — 목표 부하에서 발현

### A-1. `extstore_worker_drain`이 `ibv_poll_cq` 음수를 "비었음"으로 삼킨다

`extstore.c:874`. 음수 반환에 대해 engine-dead를 세우지 않고 0을 반환하며
`drain_empty`로 집계까지 한다. `storage_store_item`의 대기 루프
(`storage.c:733`/`741`)는 `drain < 0`에서만 빠지므로, 폴링 오류가 지속되면
**워커가 SET 안에서 100% CPU로 livelock**한다. fail-fast도, `engine_dead`
통계도 남지 않는다.

### A-2. engine death 시 in-flight WR의 `wr_id`가 dangling이 된다

`storage.c:739-746`. 다른 워커가 `e->dead`를 세우면 drain이 -1을 반환하고
`wait.done == false`로 루프를 빠져나오는데, 이 워커가 post한 WRITE는 아직
**죽은 스택 프레임의 `obj_io`/`store_wait`를 가리키는 `wr_id`**를 들고 있다.
staging 슬롯도 NIC이 DMA-read 중일 수 있는 상태에서 반납된다. 다음 drain이
그 CQE를 폴링해 `io->cb`를 dangling 포인터로 호출한다.

`ibv_poll_cq`가 dead 검사보다 먼저 실행되므로, 정상 fail-fast여야 할 상황이
UB/크래시가 된다.

### A-3. item magazine이 슬랩 메모리를 숨겨 OOM을 만든다

`items.c:112`. `sl_curr`에 안 보이는 워커 전용 배열로 chunk가 빠진다.
eviction이 없는 포트이므로 할당 실패는 곧 클라이언트 에러다.

```c
if (g_item_mag[id].n == 0)
    g_item_mag[id].n = slabs_alloc_batch(id, g_item_mag[id].v, depth);
```

- `-m` 한계 근처에서 워커 A의 배치가 그 클래스의 마지막 free chunk를 쓸어가면
  나머지 워커는 `do_slabs_newslab` 실패 → `SERVER_ERROR out of memory`.
- chunk 클래스도 그대로 refill된다. `item_free`는 `ITEM_CHUNKED`를 magazine에
  넣지 않으므로 **되돌아오는 경로가 없다** — 워커당 최대 31 × 512 KB,
  28워커면 ~445 MB가 프로세스 종료까지 파킹된다.
- **spill 경로가 아예 없다**: `slabs_free_batch`(`slabs.c:714`)의 호출자가 0건.

### A-9. `extstore_free_loc`의 magazine 경로가 검증을 통째로 건너뛴다

**(A) 중 가장 위험한 항목.** `extstore.c:466`. push 조건이
`loc->len > 0 && loc->page_id < e->page_count`뿐이고, `free_loc_global`이 하던
나머지 검증(`offset + len <= page_size`, `page_version` 일치, obj_count/
bytes_used 정합성, 이중 해제)을 전부 건너뛴다.

전역 경로였다면 `slot_acct_leak`으로 격리됐을 loc이 대신 캐시되고, 다음
`extstore_alloc`이 그것을 꺼내 **원격 WRITE 대상으로 쓴다.** 이 시스템은 stub
손상을 실제로 관측한 이력이 있다(`storage.c`에 badcrc 포렌식이 있다). 손상된
stub이 삭제되면 그 loc이 magazine에 들어가고, 다음 SET의 WRITE가 이웃 페이지의
살아있는 객체 안에 떨어진다. crypto가 켜져 있으면 무관한 키들이 영구히 GCM
실패한다. 이중 해제면 두 객체가 같은 슬롯을 공유한다.

### A-4. loc magazine도 같은 hoarding + 비활성 노브가 도달 불가

`extstore.c:466`. 파킹된 loc은 "사용 중"으로 회계된 채 **소유 스레드만**
재사용할 수 있고(LIFO 최상단, 축소만), 전역 free list는 비어 보인다. 거의 찬
스토어에서 다른 워커의 magazine에 재사용 가능한 슬롯이 남은 채 SET이 실패한다
(28 × 64 × 64 KB ≈ 112 MB).

`extstore_set_loc_mag_depth`는 **호출자가 없다**(`extstore.c:360` 정의,
`extstore.h:126` 선언, 그 외 0건). 주석의 "0 = 비활성"을 설정할 방법이 없어
A/B 검증도 불가능하다.

### B-7. ready 목록이 차면 완료를 조용히 버린다

`storage.c:603`. `g_setp_ready_n < SETP_READY_MAX`(512)가 아니면 그냥 버린다.
resp는 영구 suspend(연결 정지), staging 슬롯과 `hdr_it`는 누수. assert도
통계도 backpressure도 없다. `ext_worker_window`를 512 초과로 설정하면 도달
가능하고, B-3의 재진입 루프로도 도달한다.

---

## 3. P2 — 정합성

### A-5. loc magazine의 축소 재사용이 `bytes_used`를 영구 누수시킨다

`extstore.c:374`. pop이 `out->len`을 작은 값으로 덮어쓰지만 회계는 그대로라
슬롯은 예전 큰 `len`으로 청구된 상태고, 나중 `free_loc_global`은 **작은
`len`만** 빼준다.

```c
if (t->len >= len) { *out = *t; out->len = len; g_loc_mag.n--; return 0; }
```

`p->bytes_used`/`e->stats.bytes_used`가 축소 1회당 `(old - new)`씩 위로
표류한다. 혼합 크기에서 무계이고, 주석의 "보수적, 유계" 주장과 어긋난다
(전역 경로는 균형이 맞고 magazine 경로만 안 맞는다).

### A-6. `STORE_PENDING`이 logger의 `status_map[]`을 넘는다

`logger.c:218`의 배열은 6개(0~5)뿐인데 `STORE_PENDING`은 6이다.

```c
const char * const status_map[] = {
    "not_stored", "stored", "exists", "not_found", "too_large", "no_memory" };
...
keybuf, status_map[le->status], cmd, ...
```

`do_store_item` 끝의 `LOGGER_LOG(LOGGER_ITEM_STORE)`가 그대로 넘긴다.
`watch mutations`가 붙어 있으면 배열 밖을 읽어 `%s`에 넘긴다.

### A-7. engine death 시 파킹된 `wait_head` IO가 방치된다

`extstore.c:848-859`, `:948`. submit/drain refill이 dead일 때 건너뛰므로 대기
중이던 IO가 에러 응답도 못 받고 연결이 매달린다.

### A-8. `ext_async_set=yes`가 false로 파싱되고 `stats settings`에 없다

`memcached.c:5165`(브랜치).

```c
settings.ext_async_set = (subopts_value == NULL) ? true : (atoi(subopts_value) != 0);
```

`atoi("yes")`는 0이므로 켜려고 쓴 `ext_async_set=yes`가 **끈다**. 다른 bool
서브옵션의 관례와도 다르고, `stats settings` 출력에도 빠져 있어 실제 적용값을
확인할 수 없다. warm-restart(`-e`) 시 refill 유래 magazine 항목(`it_flags==0`)이
`slabs_fixup`에 안 잡혀 누수되는 문제도 같은 부류다(extstore+restart 조합은
현재 비활성이라 non-extstore 실행에만 해당).

---

## 4. CQ completion channel 작업에 대한 설계 제약

다음 작업은 **CQ completion channel을 fd로 libevent에 등록**하는 것이다
(`ibv_create_cq`에 채널 지정 + `ibv_req_notify_cq`). 리뷰에서 이 작업에
직접 걸리는 사실들을 정리한다.

### 4.1 검증된 안전 사항 (바꾸지 않아도 되는 것)

- CQ 깊이 `2 × window × nqp`는 window로 제한된 signaled WR 대비 2배 이상 여유.
- `wc.status`는 CQE마다 검사된다.
- item/loc magazine의 상태 전이는 `do_slabs_alloc`/`do_slabs_free`와 정확히
  일치하고, 이 포트에는 slab mover도 LRU crawler도 없어 `ITEM_SLABBED` 상주
  항목과 충돌할 주체가 없다.
- suspend 중 연결이 끊기는 경우는 `conn_closing`으로 올바르게 지연 처리된다.

### 4.2 전환 시 반드시 지켜야 할 것

1. **arm 직후 re-poll**. 현재의 single-shot bounded poll을
   "빌 때까지 poll → `ibv_req_notify_cq` → **한 번 더 poll**"로 바꿔야 한다.
   arm 직전에 도착한 CQE는 notification을 만들지 않으므로, 0-timeout 폴링이
   받쳐주던 구조가 사라지면 그 CQE는 영구 유실된다.
2. `ibv_get_cq_event` 1회당 `ibv_ack_cq_events` 1회 + **재무장**. ack을 빠뜨리면
   `ibv_destroy_cq`가 블록된다.
3. 채널 fd는 **non-blocking**으로 설정한 뒤 현재 `fd = -1`인 `ext_drain_ev`를
   교체해야 한다. 블로킹 fd면 handler가 이벤트 루프를 세운다.
4. `solicited_only = 0`. initiator 쪽 READ/WRITE CQE는 solicited가 아니므로
   1로 두면 이벤트가 오지 않는다.
5. 직접 폴링하는 두 경로(`storage_store_item`의 대기 루프,
   `worker_libevent`의 drain point (a))가 notification이 걸린 CQE를 먼저
   소비할 수 있으므로, **fd handler는 empty poll을 정상으로 취급**해야 한다.

### 4.3 목표 부하에서의 형태 — 인터럽트를 주 진행 수단으로 삼으면 안 된다

`md/SET_COST_ATTRIBUTION.md` §8은 해법을 "폴링이 아니라 인터럽트 구동"으로
적었다. **그대로 하면 10 M에 도달할 수 없다.**

10 M ops/s를 28워커로 나누면 워커당 357 K ops/s = **op당 2.8 µs**이고, 이는
`SET_10M_REQUIREMENTS.md`의 예산과 같은 수다. 완료 1건마다
`ibv_get_cq_event` + `ibv_ack_cq_events` + `ibv_req_notify_cq`를 돌리면
그 자체로 µs 단위가 들어가 예산을 통째로 먹는다.

따라서 채널은 **정지 해소용 안전망**이고 진행은 여전히 폴링이어야 한다.

```text
drain 지점: 빌 때까지 poll  →  완료가 계속 오면 arm하지 않는다 (부하 시 비용 0)
             비었고 outstanding > 0 이면  →  arm  →  re-poll  →  이벤트 루프로 복귀
채널 fd 이벤트: get_cq_event → ack → 다시 위로
```

즉 이 작업은 "폴링 → 인터럽트" 교체가 아니라 **"폴링 + idle 시 인터럽트
fallback"의 추가**다. 전자로 구현하면 `SET_COST_ATTRIBUTION.md` §8이 기록한
29 set/s의 반대편 실패(과도한 통지 비용)로 넘어간다.

> **측정으로 정정 (§6.4).** 초판에 "부하가 높으면 통지가 **한 번도 발생하지
> 않는다"고 적었는데, 이 서버에서 낼 수 있는 부하로는 그렇지 않다. SET당 통지가
> 0.45~0.73건 발생한다. 통지율은 **제공 부하 대 완료 지연의 함수**이고, 여기
> 클라이언트는 워커당 완료 간격 90 µs 수준(목표는 2.8 µs)이라 워커가 실제로
> 대부분 유휴다 — 그때 자는 것은 옳은 동작이다. 동시성을 올릴수록 통지율이
> 0.734 → 0.478 → 0.453으로 내려가는 추세는 예측과 일치하지만, 통지가 사라지는
> 구간까지는 도달하지 못했다. **"목표 부하에서 통지 ≈ 0"은 여전히 미검증
> 예측이다.**

---

## 5. 검증 환경 — mock verbs 계층

SEV vCPU + RDMA NIC 서버는 사고로 접근 불가고, 이 커널에는 `rdma_rxe`도 없어
Soft-RoCE도 못 쓴다. 대신 `tools/mock_rdma.c`로 verbs/rdma_cm 계층을 대체해
**SET 경로를 실제로 구동한다.**

이 치환이 정당한 근거는 §7의 측정이다 — span은 4단계 최적화를 거치며 5.03~5.3 µs로
**한 번도 움직이지 않았다**. RDMA는 고정 비용 상수 컴포넌트이고, 최적화 대상과
이번 리뷰가 건드린 코드는 전부 그 위에 있다.

mock이 충실히 재현하는 것 — 코드가 여기에 의존하기 때문이다:

- **one-shot arming.** armed가 아닐 때 보이게 된 완료는 통지되지 않는다. 이것이
  arm → re-poll 순서를 방어적 코드가 아니라 **필수**로 만든다(틀리면 여기서도
  매달린다).
- 완료가 별도 스레드에서 설정 가능한 지연 후 도착한다(기본 5 µs = 실측 span).
- 워커별 CQ 격리(shared-nothing).
- WRITE/READ가 별도 영역에 대한 실제 전송이다 — offset/len이 틀리면 여기서도
  데이터가 깨진다.

재현하지 않는 것: QP 간 순서 보장, RNR/retry, QP error 시 flush 의미론, 장치 자체.

| 이제 가능 | 여전히 불가 |
|---|---|
| 순서·재개 상태기계 실행 검증 | 목표 부하(10 M) 처리량·span |
| 통지/arm/poll 횟수 계수 | CPU/op 예산(2.8 µs) 판정 |
| 대기 중 CPU 소모 정량화 | 실제 NIC 타이밍·SEV DMA |
| 사전/사후 A/B (`tools/mock-build.sh <rev>`) | hoarding 임계(메모리 압박 필요) |

리포지토리의 `Makefile`/`config.status`는 다른 머신 경로가 커밋돼 있어 트리를
`configure`하지 않는다. 트리 밖 빌드로 검증한다.

---

## 6. 처리 결과 (2026-07-30)

3개 커밋으로 16건 전부 수정하고 CQ 완료 채널까지 얹었다. 실행 환경이 없으므로
검증 범위는 §5 그대로다 — **부하 거동은 서버 복구 시 재측정 대상으로 남는다.**

| # | 처리 | 방법 |
|---|---|---|
| B-1 | 수정 | ready 목록 FIFO화 + 연결당 pending 1건 직렬화(`conn_mwrite`) + CAS staleness 가드 + `queued_at` 복원 |
| B-2 | 수정 | ascii 평문 set만 비동기 대상. mset은 동기 경로 + 방어 분기 |
| B-3 | 수정 | binary는 동기 경로로 되돌림 + 방어 분기 |
| B-4 | 수정 | `w_staging_slots`를 워커 window 이상으로 |
| B-5 | 수정 | 비동기를 ascii로 한정(응답기 1개만 유지) + mset fall-through 제거 |
| B-6 | 수정 | `cur_async_ok` 명시 선언(호출 직전 set / 직후 clear) — stale이 구조적으로 불가 |
| B-7 | 수정 | FIFO 전환으로 상한·누락 소멸 |
| A-1 | 수정 | `c < 0`과 `c == 0` 분리, 음수는 engine dead + `-1` |
| A-2 | 수정 | 동기 경로의 `obj_io`/`store_wait`를 `_Thread_local`로(프레임과 함께 죽지 않는다) + 미완료 시 staging 슬롯 의도적 누수 |
| A-3 | 수정 | magazine 깊이를 **개수 대신 바이트 예산**으로(`ITEM_MAG_MAX_BYTES` 64 KB/클래스) + 할당 실패 시 자기 magazine 전량 spill 후 1회 재시도(`slabs_free_batch` 첫 호출자) |
| A-4 | 부분 | `ext_loc_mag_depth` 옵션으로 노브 도달 가능 + stats 노출. **워커 간 hoarding 자체는 남는다**(소유 스레드만 재사용) — 완화 수단이 생긴 것이고 제거된 것이 아니다 |
| A-5 | 수정 | magazine 재사용을 **정확히 같은 len**으로 제한(축소는 균형이 맞는 전역 경로로) |
| A-6 | 수정 | `status_map`에 `pending` 추가 + 인덱스 경계 검사 |
| A-7 | 수정 | `worker_fail_parked()`를 death 관측 3지점에서 호출 |
| A-8 | 수정 | `ext_async_set` / `no_ext_async_set` 값 없는 플래그 쌍 + `stats settings` 노출 |
| A-9 | 수정 | 구조 검증(len/page_id/offset+len/version)을 통과하지 못하면 전역 경로로 보내 격리. `page_size`/`page_count`는 init 전용이고 이 포트에는 페이지 재활용이 없어(`p->version`을 올리는 코드가 없다) 락 없이 읽어도 경합이 없다 |

경미해서 표에서 뺀 것: warm-restart(`-e`) 시 refill 유래 magazine 항목 누수는
extstore+restart 조합이 비활성이라 미처리로 남긴다(A-8 본문 참조).

### 6.1 CQ 완료 채널 — 구현 형태

§4.3의 결론대로 **폴링 유지 + idle 시 통지 fallback**으로 넣었다.

```text
ext_drain_settle()  ← 정책이 있는 유일한 함수
  빈 drain 이벤트가 연속 ext_cq_arm_after(기본 16)회  →  arm  →  re-poll  →  sleep
  그 전에 완료가 하나라도 오면                        →  카운터 리셋, 폴링 계속
```

부하 중에는 완료가 16회 빈 발사보다 훨씬 먼저 도착하므로 **통지가 한 번도
발생하지 않고**, drain 이벤트는 main과 동일하게 동작한다(GET 10.12 M을 측정한
그 튜닝). 모든 연결이 파킹된 순간에만 통지가 한 번 걸려 `EVLOOP_ONCE`를 깨운다.

5f16f1d가 기록한 두 실패 모드의 가운데를 지난다 — 무조건 재무장은 루프를
굶기고(139 k drains/SET, 29 set/s), 진전 시에만 재무장하면 영구 정지한다.
빈 발사 횟수를 유계로 두면 둘 다 아니고, main에는 없던 **idle spin 상한**까지
생긴다.

`ext_cq_arm_after=0`이면 폴링만 쓴다 — 정지를 재현해 A/B하기 위한 값이다.

### 6.2 mock으로 실제 측정한 결과

`tools/mock-build.sh` + `tools/mock-test.py` + `tools/mock-probe.py`.
사전/사후 비교는 수정 전 WIP(`6c80637`)을 같은 mock으로 빌드해서 했다.

**기능 (20개 단정, `mock-test.py`)** — 현재 20/20 통과. WIP은 5건 실패하고,
실패 방식이 리뷰가 예측한 그대로다.

```text
같은 키로 파이프라인 SET 10건   →  val09가 아니라 val00이 남는다   (LIFO 게시)
set k; get k 파이프라인         →  GET이 miss
set k; delete k 파이프라인      →  키가 되살아난다
noreply set                     →  게시되지 않는다
in-flight 중 flush_all          →  살아남는다                     (게시 시점 stamp)
```

**대기 중 CPU (`mock-probe.py cpu`/`drain`, 완료 5초 지연, SET 1건)**

| | 대기 중 CPU | CQ poll 횟수 |
|---|---:|---:|
| 통지 전환 전(폴링만) | 1.097 core-s/s | 238,324,146 |
| 통지 전환 후 | **0.104** core-s/s | **1,042** |
| 유휴 기준선 | 0.080 core-s/s | — |

워커가 대기 내내 코어 하나를 태우다가 **실제로 잠들게** 됐다. poll 횟수 약
229,000배 감소.

**부하 중 (`mock-probe.py load`, 10초, pipeline 8)** — 채널 비용을
`ext_cq_arm_after=0`(폴링만)과 대조해 분리했다.

| 연결 | 구성 | set/s | 통지/SET | CPU 코어 |
|---:|---|---:|---:|---:|
| 96 | FIXED 폴링만 | 44,635 | 0 | 3.62 |
| 96 | FIXED + 채널 | 44,650 | 0.450 | **2.31** |
| 96 | WIP(직렬화 없음) | 50,606 | 0 | 1.10 |
| 8 | FIXED 폴링만 | 29,257 | 0 | 3.55 |
| 8 | FIXED + 채널 | 26,103 | 0.734 | 1.91 |
| 8 | WIP | 47,752 | 0 | 1.04 |

읽는 방법 — **클라이언트(Python)가 병목**이라 set/s는 하한이고 서버 처리량이
아니다. 의미 있는 것은 같은 부하에서의 비교다.

- **채널은 96연결에서 처리량 중립(44,650 vs 44,635)이고 CPU를 36% 줄인다.**
  8연결에서는 처리량 −11%, CPU −46%.
- **WIP과의 처리량 차이는 채널이 아니라 직렬화다.** 폴링만 켠 FIXED도 같은
  44.6 k이므로, 96연결에서 직렬화 비용이 −12%, 8연결에서 −39%다. 연결 수가
  늘수록 줄어드는 방향이고(53% → 82% → 92%), 이는 §1 B-1이 예측한 대로다.
- WIP의 SET당 CPU가 여전히 낮다(21.7 vs 51.7 µcore-s/SET). 직렬화된 설계는
  워커가 완료 1건을 기다리며 유휴가 되므로 그렇다 — 채널이 이 설계에서 **더**
  중요한 이유이기도 하다.

**정정 두 건.**

1. §4.3의 "목표 부하에서 통지 ≈ 0"은 **미검증**이다(§4.3 인용 블록 참조).
2. WIP의 `got > 0` 게이트는 이 환경에서 **영구 정지를 만들지 않는다.**
   `worker_libevent`의 drain point (a)가 outstanding > 0인 동안 무조건
   재무장하므로, 증상은 정지가 아니라 **코어 하나를 태우는 스핀**이다.
   `SET_COST_ATTRIBUTION.md` §8의 "진전 가드를 넣으면 반대로 뒤집힌다(정지)"는
   서술은 최소한 이 코드 상태에서는 성립하지 않는다. 원래 관측은 실제 호스트의
   실부하에서 나온 것이라 여기서 반증했다고 보지 않고, **측정한 범위에서만**
   정정한다.

### 6.3 서버 복구 시 남은 것

| 항목 | 왜 mock으로 안 되는지 |
|---|---|
| 목표 부하에서 통지율이 ~0으로 가는지 | 클라이언트가 워커당 완료 간격 90 µs밖에 못 낸다(목표 2.8 µs) |
| SET-only 처리량(1.71 M → ?) · span < 30 µs | 실 NIC 타이밍·실 클라이언트 필요 |
| CPU/op 2.8 µs 예산 판정 | mock의 memcpy는 실 NIC DMA 비용이 아니다 |
| 직렬화 비용이 수백 연결에서 흡수되는지 | 그 규모의 부하를 낼 수 없다 |
| A-3/A-4 hoarding 임계 | `-m` 한계 근처의 메모리 압박 필요 |

### 6.4 호스트 없이 적용 가능했던 최적화 3건 (2026-07-30, 리뷰 후속)

`SET_COST_ATTRIBUTION.md`의 미적용 항목 중 구현이 호스트에 의존하지 않는
3건을 각각 독립 커밋으로 적용했다. 셋 다 mock으로 **정확성은 검증**했지만
**효과는 측정 불가**다(µs 단위 이득은 실 NIC 필요) — 호스트 복구 시 커밋
단위로 교대 A/B하고, 죽는 것은 revert한다.

| 커밋 | 내용 | 기대 효과(측정 근거) | mock 검증 |
|---|---|---|---|
| 756e45c | **SYNC_FOR_DEVICE 배치화** — post를 이벤트 루프 pass 끝으로 미뤄 그 pass의 쓰기들을 advise 1회로 동기화. seal→sync→post 순서는 쓰기별로 유지 | 1.90 µs/op의 상각 (§5의 최대 단일 레버, GET은 1:13) | 20/20, 채널 수면 유지, 상각 계수 2.1 (클라이언트 한계) |
| 9b847e3 | **`set_pending_t` 풀링** — SET당 calloc/free를 워커 전용 freelist로 | 10 M 시 초당 천만 malloc/free 제거 | 20/20 |
| 69421ff | **SET 키 prefetch ⑥⑦** — cross-request peek에 `"set "` 추가 + parse 시 bucket prefetch | 문서 분류 "저비용, 소폭" — A/B에서 죽을 확률 최대 | 20/20, t/ 불변 |

배치화의 상각 계수는 `ext_setq_writes / ext_setq_flushes`로 상시 측정된다.
mock에서 2.1에 그친 것은 클라이언트(Python)가 부하를 못 내서다 — 실 부하에서
이 값이 5~13에 도달하는지가 1.9 µs 레버의 실현 여부를 판정한다.

배치화가 추가한 제약 하나: **큐에 있는(post 전) 쓰기도 staging 슬롯을 쥔다.**
`w_staging_slots`가 window+64로 커진 이유이고, `SETQ_MAX`(64)를 키우면 그쪽도
같이 키워야 한다. post 실패는 done_cb(-1) 경로로 합류하는데, 큐 상한 flush가
`item_lock` 아래에서 호출될 수 있어 **flush 안에서 게시를 직접 하면 데드락**
이다(주석에 기록).

### 6.5 남은 설계 선택지

연결당 직렬화가 목표 수치에 걸림돌로 확인되면, 다음 형태는 **게시를 명령
시점으로 되돌리고 응답만 늦추는 것**이다(publish-at-command). 그러면 순서가
동기 경로와 동일해지고 파이프라인도 유지되지만, 게시와 WRITE 완료 사이에 GET이
들어오면 아직 쓰이지 않은 원격 메모리를 읽는다. 그것을 막으려면 stub에
"write in flight"를 표시하고 GET이 그 완료를 기다리게 하는 기구가 필요하다 —
이번 범위보다 크고, 직렬화가 실제로 병목임을 측정으로 보인 뒤에 할 일이다.
