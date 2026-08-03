# Port v3 구조 안내

> **[v3 시점 기록]** 이 문서는 그 시점의 기록으로 보존한다. 현재 운영값은
> [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md), 최신 결과는
> [`V4_RESULT.md`](V4_RESULT.md) 다.  v4 변화는 V3_TO_V4_CHANGES.md.

기준일: 2026-07-30. 기준 commit: **`7a09928` (main)**.

> ### ⚠ 2026-07-31 — 이 문서의 SET 서술은 pac 이전 상태다
>
> §6이 "구조적 한계"로 지목한 **워커당 SET 동시성 1**은 그 뒤 `pac`
> (publish-at-command)으로 해소됐고, SET-only는 0.311 M → 4.241 M이 됐다.
> §6의 "현재 실측" 블록과 §7·§8의 브랜치 기준 서술은 **당시 기록으로만**
> 읽을 것.
>
> 현행 수치와 구조는 [`SET_CAMPAIGN_HANDOFF.md`](SET_CAMPAIGN_HANDOFF.md) §16,
> 운영점은 [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md)가 정본이다.

> **개정 이력.** 초판은 `746bcab`(branch `v3-async-set`) 기준으로 작성됐다.
> 이후 관리자 실측으로 비동기 SET **두 갈래가 모두 main 밖으로** 처분됐다:
>
> - `v3-async-set` (§7의 watermark gating 설계): 정확하지만 동기 대비 2배
>   손실(0.90M vs 1.74M), 원인 미규명 — 브랜치 보존.
> - `v3-set-10m` (연결 파킹 설계 + CQ channel + mock 계층): 실 호스트에서
>   SET-only 1.0M(−40%), 1:9 혼합 GET 반토막으로 **기각** — 브랜치 보존,
>   경위는 `V3_REVIEW_FINDINGS.md` 처분 주석.
>
> main에는 동기 경로(§6) + magazine/원자화(§4·§5) + A-결함 수정(58d24b5,
> A-2)만 있다. §7·§8의 비동기 knob/stat·§10은 브랜치 기준 서술로 남겨둔다.
> 동기 경로의 단계별 워크플로·비용은 `SET_WORKFLOW.md`가 정본이다.

이 문서는 **v3에서 v2 대비 무엇이 바뀌었는지**만 다룬다. v2 구조 전체는
[`V2_ARCHITECTURE.md`](V2_ARCHITECTURE.md)에 있고 그 내용은 v3에서도 그대로
유효하다. 비용 귀속의 근거는 [`SET_COST_ATTRIBUTION.md`](SET_COST_ATTRIBUTION.md),
목표 예산은 [`SET_10M_REQUIREMENTS.md`](SET_10M_REQUIREMENTS.md),
GET/SET 비대칭의 배경은 [`GET_SET_CONCURRENCY.md`](GET_SET_CONCURRENCY.md)에 있다.

---

## 1. 한 장 요약

v2는 **GET 경로**를 worker-inline으로 재구성해 10.357M GET/s를 냈다.
v3은 **SET 경로**에 같은 일을 한다. 코드 변경은 전부 SET 쪽이고 GET 경로는
prefetch 확장 한 줄 외에 손대지 않았다.

바뀐 것 두 축:

```text
① 토폴로지   client가 Ariel guest 밖으로 나갔다 (off-box)
② SET 경로   전역 락 제거 → 카운터 원자화 → 비동기 재개(진행 중)
```

SET-only 처리량 궤적 (교대 A/B, 전부 pair 부호 일치):

| 단계 | 처리량 | CPU/op | commit |
|---|---:|---:|---|
| v2 시작점 | 320 K/s | 27.41 µs | — |
| ① worker-private **item magazine** | 472 K/s | — | `07bedbb` |
| ② worker-private **remote-loc magazine** | 911 K/s | 12.04 µs | `07bedbb` |
| ③ 카운터 5종 **원자화** | 1.68 M/s | 7.39 µs | `e3e27c0` |
| ④ spin 카운터 배치 반영 | 1.71 M/s | 7.29 µs | `1d5ea84` |
| (동기 경로, 브랜치 시점 재측정) | **1.74 M/s** span 5.08 µs | 7.48 µs | `746bcab` |
| (비동기 watermark — **미해결, 브랜치**) | 0.90 M/s | 8.48 µs | `746bcab` |
| (비동기 연결 파킹 — **실측 기각, 브랜치**) | 1.0 M/s, 혼합 GET −50% | — | `cca9807` |
| (동기 재측정, memtier@genie) | **2.27 M/s** span 6.21 µs | guest 11.3 µs | `cca9807`+`no_ext_async_set` |
| (동기, **co-located** A/B 기준선) | 1.99 M/s span 6.0 µs | guest 12.0 µs | `cca9807` / pac-off |
| **(pac — publish-at-command, co-located)** | **2.41 M/s** (+21%) | guest **9.6 µs** | `e424305` (`v3-set-pac`) |

> 아래 세 행은 bed·클라이언트 배치가 위 행들과 달라 위쪽과 절대값 비교 불가.
> 특히 마지막 두 행은 클라이언트를 guest 안에 둔 것이라 서로끼리만 비교된다.
> 상세는 `SET_WORKFLOW.md` §0-1(동기 재측정) / §0-2(pac A/B).
>
> 초판은 2.27M 행을 main `7a09928`으로 적었으나 실제 서버는
> `cca9807`+`no_ext_async_set`였다 — co-located A/B가 두 바이너리의 동기
> 경로 동일 성능을 보였으므로 동기 대표값으로는 유효하다.

**5.4배가 전부 전역 락 제거에서 나왔다.** RDMA도 AES-GCM도 비용이 아니었다
(프로파일에서 각각 4.4%, 0.6%).

---

## 2. 토폴로지: client가 밖으로 나갔다

v2의 정본 토폴로지는 "memtier가 Ariel guest 안에서 loopback으로" 였고
off-box는 검증 대상이 **아니라고** 명시돼 있었다. v3이 이 조항을 뒤집는다
(`7ca5ad9`).

이유는 선호가 아니라 측정이다:

```text
co-located:  client가 Ariel의 물리 16코어 중 11.2 cpu-equivalent를
             부하 생성에만 태운다. 10M을 내려면 32 logical CPU 위에
             40 thread가 필요하다 — 코드로는 도달 불가.
off-box:     IPoIB 고정비 3.08 µs/packet(64B) ~ 3.38 µs(1400B)
             = 10M에서 약 2.3 cpu-equivalent. 11.2를 2.3으로 바꾼다.
```

게이트는 영향을 받지 않는다. `avg<30µs` 판정은 `read_avg_ns`(서버 측 span)를
읽지 client end-to-end를 읽지 않으므로, client가 어디 있든 측정 대상이 같다.

하네스: `tools/obup.sh`(기동 + 1M 프리로드 + 초당 샘플링),
`tools/obslice.sh`(UTC 구간으로 샘플 로그 절단).

---

## 3. 왜 SET만 바꿨나

v2 SET은 26.9 µs/op를 썼고, 프레임포인터 빌드 프로파일이 그 **2/3을 전역
뮤텍스 두 개**로 귀속시켰다:

```text
전역 slabs_lock (alloc+free)                46.7%
전역 엔진 락 (extstore alloc/free_loc/delete) 11.6%
기타 mutex                                    9.0%
──────────────────────────────────────────────────
락 대기 소계                                  ~67%
실제 I/O (sendmsg/ioctl/poll_cq)               4.4%
AES-GCM seal                                   0.6%
```

GET이 이 비용을 안 내는 이유는 단순하다 — 복호 목적지를 `_Thread_local`
`cache_t`에서 꺼낸다. SET의 stub item은 **해시테이블에 등재되므로** 같은
캐시를 쓸 수 없고, 그래서 매번 `do_item_alloc()` → `slabs_lock`을 탔다.

v3의 방침은 "GET이 이미 검증한 패턴을 SET에 적용한다" 하나다:
**전역 락 앞에 워커 전용 자유 목록을 두고 배치로 채우고 비운다.**

---

## 4. 워커 전용 magazine 2종

두 magazine 모두 `_Thread_local`이고, 소유 thread만 건드리므로 락이 없다.

### 4.1 item magazine (`items.c:99`)

```text
do_item_alloc_pull(ntotal, id)
  → g_item_mag[id]이 비었으면 slabs_alloc_batch(id, v, depth)  ← 락 1회로 N개
  → pop 후 do_slabs_alloc과 동일한 전이: ITEM_SLABBED 해제, refcount = 1

item_free(it)
  → magazine에 자리가 있으면 do_slabs_free와 동일한 전이만 적용하고 보관
     (it_flags = ITEM_SLABBED, slabs_clsid = clsid)
  → chunked item은 제외 — do_slabs_free_chunked가 따로 필요하다
```

불변식: **magazine에 든 item의 상태는 slab 자유 목록에 있을 때와 동일하다.**
그래서 slab 계층에서 보면 이 item들은 여전히 "할당됨"이고, 다른 경로가
가로챌 여지가 없다.

깊이는 `-o item_mag_depth=N` (기본 32, 상한 `ITEM_MAG_MAX`=64). A-3 수정
(58d24b5) 이후 실효 깊이는 클래스당 **바이트 예산**(`ITEM_MAG_MAX_BYTES`
64KB)으로 추가 제한된다 — 큰 클래스는 자동 축소, 512KB chunk 클래스는 0.
할당 실패 시 자기 magazine 전량 spill 후 1회 재시도한다(`items.c:160`).
배치 변형은 `slabs.c:700`의 `slabs_alloc_batch` / `slabs_free_batch`.

측정: 320K → 472K (**+47.3%**). 예측 대비 61%만 회수됐는데, 재프로파일 결과
경합이 사라진 게 아니라 **이동**했다 — `slabs_*`가 프로파일에서 완전히
빠지고 `extstore_alloc`/`storage_delete`/`extstore_free_loc`이 11.6% → 57.8%로
올라왔다. 그래서 다음 단계가 원래 추정보다 훨씬 커졌다.

### 4.2 remote-loc magazine (`extstore.c:353`)

`extstore_alloc`/`extstore_free_loc`은 `e->mutex`(free list + 페이지 할당)와
그 안에 중첩된 `stats_mutex`를 SET 1건마다 5~6회 잡는다. 같은 패턴을 적용한다.

```text
extstore_alloc(len)
  → magazine LIFO 최상단만 검사. top->len >= len 이면 재사용(축소만 허용)
  → 아니면 전역 경로

extstore_free_loc(loc)
  → 자리가 있으면 회계를 건드리지 않고 로컬 보관
  → 가득 차면 절반을 free_loc_global로 반납 (락 1회당 N/2건)
```

**핵심 불변식: magazine에 든 loc은 여전히 '사용 중'으로 회계된다.**
여기서 세 가지가 따라 나온다.

| 성질 | 귀결 |
|---|---|
| push/pop이 회계를 바꾸지 않음 | 전역 상태를 전혀 건드리지 않는다 |
| `obj_count`가 줄지 않음 | 해당 페이지가 재활용될 수 없다 = loc이 stale해지지 않는다 |
| — | 그래서 전역 경로의 version 검증을 우회해도 안전하다 |

A-9 수정(58d24b5) 이후 push 시 구조 검증(len/page_id/offset+len/version)을
통과하지 못한 loc은 전역 경로로 보내 격리한다 — 손상·이중 해제 loc이
다음 SET의 원격 WRITE 대상으로 재사용되는 경로 차단. 재사용 조건도
"축소 허용"에서 **정확히 같은 len**으로 좁혀졌다(A-5, bytes_used 표류 차단).

대가는 통계 과대 보고뿐이고 유계다: 워커 28 × 깊이 64 = 최대 1,792.
실측 `extstore_objects_used` 1,001,337 vs `curr_items` 1,000,000 —
경계 안이고 `slot_acct_leak`은 0.

측정: 484K → 911K (**+88.4%**, 4 pair 전부 일치).

> ~~깊이 기본값은 64이고 setter가 있지만 호출하는 곳이 없다~~ →
> 58d24b5에서 `-o ext_loc_mag_depth=N`으로 배선됐다 (0 = off, `stats`에
> 노출). A/B 검증 축으로 사용 가능하다.

---

## 5. 카운터 원자화 (`e3e27c0`)

magazine 두 개가 붙은 뒤 재프로파일하니 슬랩·엔진 락이 프로파일에서 사라지고
`do_item_unlink` 22.3% / `storage_store_item` 19.1% / `do_item_link` 12.9%가
남았다. 읽어 보면 **키를 덮어쓰는 SET 1건이 카운터 갱신만으로 전역 락을
5번** 잡는다.

| 락 | 횟수/SET | 보호 대상 | v3 |
|---|---:|---|---|
| `cas_id_lock` | 1 | `cas_id` 증가 | `__atomic_add_fetch` (RELAXED) |
| `STATS_LOCK` | 2 | `curr_items`, `curr_bytes`, `total_items` | 원자 갱신 |
| `lru_locks[id]` | 2 | `sizes[id]`, `sizes_bytes[id]` | 원자 갱신 |

`lru_locks[id]`가 특히 나빴다 — **stub item은 전부 같은 slab class**라
per-class 락이 사실상 전역 락으로 동작했다.

정당성: CAS 의미론이 요구하는 것은 유일성과 단조성뿐이고 원자 증가가 둘 다
준다. 나머지 넷은 순수 통계 카운터다.

측정: 932K → 1.68M (**+80.6%**), CPU 12.04 → 7.39 µs/op.
mixed 실행 후 `curr_items` 정확히 1,000,000, miss·RDMA 실패·`engine_dead`·
`slot_acct_leak` 전부 0.

> 계획상 3단계는 SYNC_FOR_DEVICE 배치화였다. 재프로파일이 그것을 CPU의
> 2.35%로 값매겼고(1.82 µs의 벽시계는 대부분 커널·디바이스 대기지 사이클이
> 아니다) 카운터 락이 약 40%였으므로 순서를 데이터에 맞춰 바꿨다.

이어서 `1d5ea84`가 SET 대기 루프 안의 전역 spin 카운터를 루프 밖으로 뺐다 —
SET당 15.6회 × 1.68M = 초당 2600만 RMW가 워커 28개 공유 캐시라인 하나에
꽂히던 것. +2.3%로, 캐시라인 산수가 시사한 것보다 훨씬 작았다.

---

## 6. 동기 SET 경로 (현재 동작하는 것)

v2 §5의 구조 그대로이고, 위 최적화만 얹혔다.

```text
worker: staging slot 확보 (워커 전용 bitmap)
  → do_item_alloc → item magazine                  ← v3
  → extstore_alloc → loc magazine                  ← v3
  → ext_crypto_seal (worker TLS ctx)
  → window 여유 없으면 자기 CQ를 drain하며 대기       (spin 로컬 집계) ← v3
  → SYNC_FOR_DEVICE + ibv_post_send (WRITE, 1건씩)
  → 자기 CQE 도착까지 spin-drain                      ← 워커당 동시성 = 1
  → stub publish (링크 카운터 원자 갱신)              ← v3
  → STORED
```

구조적 한계는 표시한 줄 하나다: **워커가 자기 WRITE CQE를 busy-wait하므로
워커당 SET 동시성이 1**이다. 재프로파일은 `storage_store_item`(= 이 대기
루프)을 SET CPU의 46.6%로 잡았고, 처리량은 CPU 상한의 45%에 머문다.

당시 실측 (2026-07-30, pac 이전 — **현재 값이 아니다**):

```text
SET-only 1.74 M/s, span 5.08 µs, CPU 7.48 µs/op
1:9 mixed 5.28 M/s   1:1 mixed 2.73 M/s   miss 0
```

> **이후 경과.** 위 "구조적 한계"(워커당 SET 동시성 1)는 pac이 없앴다.
> 스텁을 커맨드 시점에 게시하고 `STORED` 응답만 CQE로 미루면 워커가 묶이지
> 않는다. 2026-07-31 정본은 **SET-only 4.241 M/s(span 7.63 µs),
> 1:10 혼합 10.195 M/s**이며 양 게이트를 동시에 통과한다.

---

## 7. 비동기 SET 경로 — **branch `v3-async-set` 전용, main에 없음** (미해결)

동시성 1을 깨려면 GET이 쓰는 것과 같은 구조 — post 후 반환, CQE에서 재개 —
가 필요하다. 구현은 되어 있고 **정확하지만 2배 느리다.**

**계약은 유지된다: `STORED`는 여전히 CQE 이후에만 wire에 나간다.**
바뀌는 것은 기다리는 방식뿐이다.

### 7.1 흐름

```text
[요청 처리 중]
do_store_item(comm == NREAD_SET)
  → storage_store_item_async()                     storage.c:819
       · staging slot 먼저 확보 (없으면 0 반환 → 동기 경로가 받는다)
       · item/loc magazine, seal
       · set_pending_t 하나에 재개에 필요한 전부를 담아
         워커 전용 WRITE 체인에 append (게시하지 않는다)
       · 체인이 w->batch에 차면 즉시 게시
       · 체인이 2×window를 넘으면 drain해서 자리를 만든다
       · worker_storage_arm_drain(t)
       · return 1 (STORE_PENDING)
  → do_store_item: 참조만 정리하고 STORE_PENDING 반환 (게시하지 않음)
  → 프로토콜 계층: 응답 확정 + 전송 게이팅 (§7.2)

[이벤트 루프 끝 / drain 이벤트]
storage_submit_set_writes()                        storage.c:643
  → extstore_worker_post_write_batch()             extstore.c:851
       · 배치당 SYNC_FOR_DEVICE advise 1회, ibv_post_send 1회

[CQE]
storage_set_done_cb()                              storage.c:628
  → staging slot 즉시 반납 (flush까지 물면 동시성이 slot 수에 묶인다)
  → ready 목록에 올리기만 한다 (drain 문맥이라 락 금지)

[drain 직후]
storage_flush_set_returns()                        storage.c:657
  → item_lock(hv) 재획득 → do_item_get → item_replace 또는 do_item_link
  → 옛 stub이 ITEM_HDR이면 storage_delete
  → resp->wgated = false; c->resps_gated--
  → event_active(EV_WRITE)
```

재개 시점에 item_lock을 **다시** 잡고 그 시점의 링크 항목을 기준으로
교체한다. SET 의미론은 last-write-wins이고 memcached는 동시 연결 간 순서를
보장하지 않으므로, 대기 중 다른 SET이 끼어들었어도 정상이다.

### 7.2 watermark gating — 연결을 파킹하지 않는다

처음 구현은 GET처럼 `conn_resp_suspend()`로 연결을 파킹했다. ascii SET에서는
그럴 필요가 없다: **SET 응답은 상수**다. 그래서 응답을 지금 확정하고
**전송만** 막는다 (`proto_text.c:200`).

```text
resp->wgated = true;  c->resps_gated++;
  → _transmit_pre / _transmit_post 가 wgated resp에서 멈춘다   memcached.c:2559/2632
  → iovused == 0 이고 head가 gated면 TRANSMIT_SOFT_ERROR (상태는 conn_mwrite 유지)
  → conn_closing 은 resps_gated 도 확인한다                     memcached.c:3321
  → CQE 후 wgated 해제 + event_active — epoll 재등록도 파킹 해제도 없다
```

실패하면 CQE 콜백이 아직 wire에 안 나간 응답을 `NOT_STORED`로 덮는다.

binary / meta / proxy 경로는 상수 응답이 아니므로 기존 방식대로
`conn_resp_suspend()`를 쓴다 (`proto_bin.c:389`, `proto_parser.c:839/1451`).

> 재개 시 절대 `out_string()`을 쓰면 안 된다 — `conn_set_state()`로 연결
> 상태를 되돌리므로 파이프라인 중간에 호출하면 `c->item` 등이 깨진다
> (실측: `complete_nread_ascii`에서 segfault). 전용
> `setp_out_string()`이 suspend해 둔 resp에만 쓴다.

### 7.3 이 과정에서 고친 것

| 증상 | 원인 | 수정 |
|---|---|---|
| SET 데이터 손실 (워커당 9건 초과분) | staging slot을 flush까지 물고 있어 고갈, 초과분을 `NOT_STORED`로 조용히 버림 | slot을 CQE에서 반납, 고갈 시 `return 0`으로 동기 경로 폴백 |
| 14코어 1410%, stats 무응답 (라이브락) | `ext_drain_handler`의 `event_active` 자기 재무장. GET은 outstanding이 금방 0이 되지만 비동기 SET은 상시 >0이라 소켓 이벤트를 굶긴다 | 0-타임아웃 **타이머**(`event_add`)로 다음 루프 패스에 양보 (`thread.c:878`) |
| SYNC_FOR_DEVICE 1.90 µs/op | 동기는 1건씩 post라 상각 불가 | 배치당 1회 → **0.24 µs/op (−87%)**. 비동기에서만 가능하다 |
| op당 `calloc`/`free` | — | `set_pending_t` magazine (`storage.c:594`) |

staging slot 수: `EXT_WRITE_SLOTS`(기본 256) ÷ 워커 수. 28워커면 9개다 —
비동기 워커당 동시성의 실질 상한이므로 올릴 축이다.

### 7.4 미해결: 2배 손실

```text
동기   1.72 M/s   CPU 7.48 µs/op
비동기 0.90 M/s   CPU 8.48 µs/op
```

CPU는 13% 차이인데 처리량은 절반이다. **비동기가 op당 약 7 µs를 유휴로
쓴다.** 다음 가설은 전부 측정으로 배제됐다:

```text
동시성 부족(window 24→1)   SYNC 미상각        op당 calloc
체인 큐 깊이               연결 파킹          suspend 배리어
이벤트 루프 라이브락
```

프로파일이 필요하다. 그때까지 **동기 경로가 유일하게 게이트를 통과하는
구성**이다.

> 주의: `settings.ext_async_set` 기본값이 `true`다 (`memcached.c:250`).
> 동기 경로로 측정하려면 `-o ext_async_set=0`을 명시해야 한다.

---

## 8. 새 knob / 새 stat

| knob | 기본 | 의미 |
|---|---:|---|
| `-o item_mag_depth=N` | 32 | 워커 전용 item magazine 깊이. 0 = 비활성, 상한 64 (main) |
| `-o ext_loc_mag_depth=N` | 64 | remote-loc magazine 깊이. 0 = off (main, 58d24b5) |
| `-o ext_async_set=0\|1` | 1 | **branch 전용** — main에 없음 |
| `EXT_WRITE_SLOTS` (env) | 256 | ÷워커 수 = 워커당 staging slot. 동기 경로는 1건이면 족함 |

진단 stat 4종 — **branch 전용** (`stats` 출력). 비동기가 어느 단계에서
멈추는지 가른다:

```text
as_posted     post 성공
as_cb         CQE 콜백 진입
as_flush      게시 + 응답 재개 완료
as_flushcall  flush 함수 호출 횟수
```

정상이면 `as_posted == as_cb == as_flush`. 벌어지는 지점이 막힌 단계다.

---

## 9. 파일별 변경 (v2 → v3)

| 파일 | v3에서 추가된 책임 |
|---|---|
| `items.c` | item magazine, 카운터 원자화, `get_cas_id` 원자화 |
| `slabs.c/.h` | `slabs_alloc_batch` / `slabs_free_batch` |
| `extstore.c/.h` | loc magazine, `extstore_worker_post_write_batch`, `extstore_worker_batch` |
| `storage.c/.h` | 비동기 SET 전부 (`_async` / `submit_set_writes` / `flush_set_returns`), `set_pending_t` magazine, 진단 stat |
| `memcached.c` | `STORE_PENDING` 분기 2곳, transmit 게이팅, `conn_closing` 가드, 새 `-o` 파싱 |
| `proto_text.c` | ascii SET watermark gating, cross-request prefetch를 `set `까지 확장 |
| `proto_bin.c` / `proto_parser.c` | `STORE_PENDING` → `conn_resp_suspend`, `cur_conn`/`cur_resp` 배선 |
| `thread.c` | 루프 끝 `submit_set_writes` + `flush_set_returns`, drain 재무장을 타이머로 |

`LIBEVENT_THREAD`에 `cur_conn`/`cur_resp`가 추가됐다 — `do_store_item`이
suspend 대상 resp를 알아야 하는데 그 시그니처에 conn이 없기 때문이다.
`cur_sfd`를 쓰던 자리마다 함께 채운다.

---

## 10. 남은 순서 (2026-07-30 갱신, main 기준)

```text
2) publish-at-command  ← 구현 완료(v3-set-pac e424305), co-located 1차 통과
                         (+21%, 클라이언트 p99 -18%, 결함 0 — SET_WORKFLOW §0-2)
   다음: off-box 정본 bed에서 W2/W3 재판정 → 통과 시 main 병합 심사

1') off-CPU 간극 규명   ← 순서를 2) 뒤로 돌린다. 간극의 일부를 pac이 이미
                         제거했으므로(CPU/op 12.0→9.6), 재는 것은 pac 적용
                         상태여야 한다 (SET_WORKFLOW.md §3 갱신 주석)

3) 브랜치 미측정분 A/B  ← SYNC 배치화(v3-set-10m 756e45c)·SET prefetch.
                         SYNC 배치화는 비동기 전제였고 pac이 그 문을 열었다.
                         단 배치는 span에 (a)를 더하므로 마감시간 정책과
                         함께 설계할 것
```

loc magazine `-o` 배선은 완료됐다(58d24b5). 현재 배포 구성은 여전히 main의
동기 경로이고(`ext_async_set`/`ext_pac_set` knob 모두 main에 없다), pac은
guest에 변종 바이너리 `memcached.pac-e424305`로만 올라가 있다.
