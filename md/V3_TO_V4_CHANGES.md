# v3 → v4 — 무엇이 어떻게 바뀌었나

작성 2026-08-03. 기준점은 v3 최종 `c0c5b4f`(브랜치 `v3-set-pac`), 도착점은
v4 `main`. v3 는 `../memcached-1.6.42-port_v3/` 에 동결돼 있다.

이 문서는 **거시 구조**를 다룬다. 셀 단위 측정은
[`V4_RESULT.md`](V4_RESULT.md), 단계별 코드 주석은
[`GET_WORKFLOW.md`](GET_WORKFLOW.md)·[`SET_WORKFLOW.md`](SET_WORKFLOW.md) 에
있다.

```text
소스 변경   10 파일, +442 / −53   (extstore·items·memcached·proto_*·storage·thread)
커밋        23 개 (revert 쌍 1 개 포함)
```

---

## 0. 한 장 요약

v3 는 **계약을 span v2 기준으로 달성**했고, 정의를 span v3 로 넓히자
**8 배 초과로 깨졌다**. v4 가 한 일은 성능 개선이 아니라 **원래 있던 대기를
드러내고 걷어낸 것**이다.

```text
              혼합 처리량   GET span   SET span
v3 (span v2)   9.83 M         7.8        7.8      ✓ ✓   같은 서버를
v3 (span v3)   9.83 M       316.24     188.75     ✗ ✗   다르게 쟀을 뿐
v4 최종       11.10 M        22.31       9.11     ✓ ✓
```

**정의가 성능을 바꾼 것이 아니다.** 증거는 v3 당시 클라이언트가 SET 지연을
7.45 ms 로 보고하는데 서버는 7.8 µs 라고 답하고 있었다는 것이다. 그 차이가
전부 계측 밖의 대기였다.

---

## 1. 아키텍처 — 세 개의 큐를 없앴다

v3 의 GET 경로는 상류 memcached 의 `io_queue` 배칭을 그대로 물려받았다.
그 배칭이 **한 요청을 세 번 기다리게** 했다.

```text
v3   ① 연결의 읽기 버퍼를 끝까지 파싱          ← 제출이 여기까지 기다린다
     ② pass 끝에 io_queue 를 한 번에 제출
     ③ event loop 로 복귀
     ④ 다음 pass 가 되어야 CQ 를 폴링          ← 완료 관측이 여기까지 기다린다
     ⑤ 거둬도 재개는 또 다음 pass              ← 재개가 여기까지 기다린다

v4   ① GET 하나 파싱 → 그 자리에서 post
     ② N 건마다 CQ 수거 + 재개
     ③ 남은 것은 pass 끝 flush 가 처리
```

**대기의 실측 크기 — EXP-0 (v3 코드, 변경 전, pipe=256):**

```text
워크로드      ops/s     span v3    = admit  +  v2   +  ret
GET-only     11.932 M    242.29     217.12    25.16     —
1:9 혼합     10.055 M    311.77     285.16    26.59     —      (GET)
                         188.75       0.51    15.13    173.11  (SET)
SET-only      4.133 M   2380.29       0.61     7.84   2371.84
```

| 대기 | 크기 | 원인 | v4 의 처리 |
|---|---:|---|---|
| **GET admit** | **285.16 µs** | 읽기 버퍼를 다 파싱해야 제출 | 파싱 즉시 post (`ext_submit_inline`) |
| **SET ret** | **173.11 µs** (SET-only 2371.84) | 거두고도 재개를 다음 pass 로 | 거둔 그 pass 에서 재개 |
| GET v2 | 26.59 µs | CQE 가 pass 끝까지 폴링조차 안 됨 | post 자리에서 수거 (`ext_reap_every`) |

**SET-only 가 2380 µs 였다** — 계약선의 79 배다. 원본은
`experiments/exp0-20260801/FINDINGS.md`.

**그런데 SET 이 답을 갖고 있었다.** v3 의 pac(publish-at-command)은 admit 이
처음부터 0.5~0.6 µs 였다 — 큐에 넣자마자 그 자리에서 flush 했기 때문이다.
**GET 만 상류의 배칭을 물려받아 admit 이 285 µs 였고**, v4 는 GET 을 SET 처럼
만든 것이다. SET 은 반환 경로만 고치면 됐다.

```text
                 EXP-0        v4 최종      배율
혼합 GET admit   285.16        9.17        31 배
혼합 SET ret     173.11        0.62       279 배
```

> **정정 (2026-08-03).** 초판은 이 표를 `9.91 / 31.56 / 25.48 µs` 로 적었다.
> 그것은 최초 진단이 아니라 **캠페인 후반 각 수정 시점의 델타**이고, 셋을
> 더해도 67 µs 라 출발점을 설명하지 못했다. 자세한 경위는
> `V4_RESULT.md` §1 의 정정 주석과 §1-1.

### 1-1. 새로 생긴 손잡이 넷

| 설정 | 하는 일 | 기본 | v4 운영값 |
|---|---|---:|---:|
| `ext_submit_inline` | 파싱 즉시 post, `io_queue` 우회 | off | **on** |
| `ext_post_chain` | 인라인 post 를 N 건 묶어 한 번에 | 1 | **8** |
| `ext_reap_every` | N 건마다 CQ 수거 + 재개 | 1 | **8** |
| `ext_admit_max` | 워커당 backend 체류 상한 | 0 | **64** |

**`chain` 과 `reap` 이 span 의 두 구간을 나눠 쥔다** — 이것이 v4 에서 가장
중요한 구조적 사실이고, 캠페인 121 셀이 확인했다:

```text
adm  ←  유효 체인 = min(chain, reap)     storage.c:607 이 reap 틱 안에서
                                          pending_chain_flush() 를 부른다
v2   ←  reap 이 지배 (chain 도 들어온다)
```

`reap` 이 `chain` 보다 작으면 **체인이 차기 전에 reap 이 비운다.** 그래서
`chain` 을 12·16·20·24·32 로 올려도 결과가 같다(§14-1).

---

## 2. GET 워크플로 — 거시 대조

### v3

```text
drive_machine
 └ try_read_network        연결의 읽기 버퍼를 통째로 읽는다
    └ 파싱 루프 (모든 GET)
       └ storage_get_item   eio 를 만들어 q->stack 에 쌓는다   ← post 안 한다
    ⇣ 버퍼를 다 파싱한 뒤
 └ thread_io_queue_submit   쌓인 것을 한 번에 제출
 └ (event loop 복귀)
 ⇣ 다음 pass
 └ drain point              CQ 폴링 → 복호 → 응답 조립
```

**한 연결이 256 개를 파이프라인하면 첫 GET 은 256 번째가 파싱될 때까지
post 조차 안 된다.** 그것이 EXP-0 의 GET admit **285.16 µs**(혼합) /
**217.12 µs**(GET-only)다.

### v4

```text
drive_machine
 └ try_read_network
    └ 파싱 루프
       └ storage_get_item
          ├ eio 준비, p->c = t->cur_conn   ← post 전에 채운다 (아래 2-2)
          ├ 체인에 붙인다
          ├ 체인이 chain 건이면 → pending_chain_flush() → 실제 post
          └ reap 틱이면 → 체인 flush + CQ drain + 재개
 └ storage_post_chain_flush  pass 끝에 남은 것을 내보낸다
 └ storage_flush_returns     pass 끝에 남은 재개를 처리한다
```

핵심은 **파싱 루프 안에서 post·수거·재개가 모두 일어난다**는 것이다.
`io_queue` 는 GET 경로에서 우회된다.

### 2-1. 왜 pass 끝 flush 가 여전히 필요한가

체인은 건수로 끊긴다. **도착이 느리면 건수가 안 차므로** pass 끝에서
비워줘야 한다. 이것 때문에 **저부하에서 오히려 `adm` 이 크다**(pipe=8 에서
5.83 µs, pipe=256 에서 3.70 µs) — 배칭이 시간 기준이 아니라 건수 기준이고
**타임아웃이 없다**(§14-3).

### 2-2. post 자리 재개가 만든 두 가지 위험

인라인 post 는 **완료가 post 직후에 돌아올 수 있게** 만들었다. co-located
RDMA 는 5 µs 라 파싱 루프 안에서 완료가 난다. 여기서 두 번 서버가 죽었다.

```text
① 파싱 중인 연결을 재개하면 죽는다
   drive_machine 이 아직 그 연결을 돌고 있는데 conn_worker_readd 가 걸린다
   → t->cur_conn 으로 표시하고 그 연결만 제외한다 (proto_text.c 4 자리 + multiget)

② 자기 자신의 pending 을 재개하면 죽는다
   p->c 가 아직 NULL 인 채로 완료가 와서 conn_resp_unsuspend(NULL,…) → segfault at 0xfc
   → p->c = t->cur_conn 을 post **전에** 채운다
```

②는 세 번 만에 잡았다. 앞의 두 번은 추측이었고, 세 번째에 `dmesg` 의 폴트
주소를 먼저 본 것이 답이었다.

### 2-3. 서버가 멈춘 사례 하나 더

`drain > 0` 가드를 없앴더니 워커들이 futex 에서 멈췄다. meta-get 의
`limited_get_locked` 가 **`item_lock` 을 쥔 채** 이 경로로 들어오고,
`storage_set_return_cb` 가 같은 락을 다시 잡는다. 호출 빈도를 올리자 그 창이
열렸다. **락 보유를 추측하지 말고 `item_trylock` 으로 질의**하도록 고쳤다.

---

## 3. SET 워크플로 — 거시 대조

SET 은 v3 에서 이미 pac 이었다. v4 가 바꾼 것은 **반환 경로 하나**다.

### v3

```text
storage_store_item_pac
 ├ item_lock 아래에서 stub 을 publish        ← 여기까지 0.5~0.7 µs (좋았다)
 ├ ITEM_WFLIGHT 를 세워 storage_delete 를 막는다
 └ WRITE 를 큐에 넣고 그 자리에서 flush
 ⇣
 (WRITE CQE)
 └ 거둔다 → **재개는 다음 pass 로 미룬다**   ← ret 173.11 µs (혼합)
                                                 2371.84 µs (SET-only)
```

### v4

```text
 (WRITE CQE)
 └ 거둔 그 pass 에서 재개한다
    ├ 큐 상한 flush 안에서 재개 — 잡고 있는 버킷만 보류
    └ 마지막 재개만 보류한다 (resps_suspended > 1 이면 안전)
```

**"마지막 재개만"** 이 핵심이다. 처음엔 연결 단위로 통째 보류했더니
6 M SET 에 44.5 M 건이 보류돼 `ext_setret_now = 0` 이 됐다.
위험한 것은 **마지막 재개뿐**이다 — `conn_worker_readd` 는 카운터가 0 이 될
때만 걸리기 때문이다.

결과: 혼합 SET `ret 173.11 → 0.62 µs`, `Sv3 188.75 → 9.11 µs`.
(캠페인 중간의 A-1 시점 A/B 로는 `21.68 → 8.62 µs` 였다 — 그때는 이미
다른 수정들이 들어가 절대값이 달랐다.)

---

## 4. 처리량은 락에서 나왔다

span 을 연 뒤 혼합은 9.2 M 이었다. 나머지는 전부 **경합**이었고, 셋 다
"원자 연산이면 되는데 30 워커가 같은 캐시라인을 두드리던" 것이다.

| 수정 | v3 에서 무엇이었나 | 효과 |
|---|---|---|
| 아이템 카운터 샤딩 | SET 1 건이 공유 캐시라인을 **10 번** 갱신 | SET-only +27% |
| refcount 원자화 | GET 이 `item_lock` 을 **두 번** 잡음 (`--refcount` 가 비원자라) | 두 워크로드 +8.5% |
| 워커 통계 뮤텍스 제거 | GET 1 건이 `stats.mutex` 를 **두 쌍** 잡음 | 혼합 +0.6% |
| `mc_resp` memset | GET 마다 **1028 B** 를 쓸데없이 0 으로 (12 M ops 면 12.3 GB/s) | +8.2% / +6.5% |

마지막 것은 `sizeof(mc_resp)`(1192 B) 대신
`offsetof(mc_resp, wbuf)`(164 B)만 지우는 **한 줄**이다. `wbuf` 는 쓰기 전에
채워지므로 0 으로 만들 이유가 없었다.

---

## 5. 정합성 — v4 이전부터 있던 결함을 잡았다 (badcrc)

혼합에서 **있는 키가 조용히 MISS 로 돌아가고 있었다**(pipe=256 에서 GET 의
0.025%).

```text
상류 extstore   페이지 단위로 재활용하고 page_version 으로 낡은 읽기를 거른다
이 포트         슬롯 단위로 재활용하면서 버전을 안 올린다 (extstore.c:534)
                → storage_delete 가 unlink 시점에 loc 을 회수
                → 읽는 중인 원격 메모리를 다음 SET 이 덮어쓴다
```

회수를 `item_free` 로 옮겼다 — GET 이 이미 refcount 를 쥐므로 그것으로
보호가 성립한다. 호출처가 9 군데라 `STORAGE_delete` 매크로 한 곳에서 막았다.

**v3 의 계약 달성치도 이 조건에서 잰 값이다.** `err5` 집계에 badcrc 가 없었고
hit 율 0.025% 는 "100%" 로 반올림된다 — 양쪽 다 못 봤다.

---

## 6. 계측 — span v2 에서 v3 로

| | 시작 | 끝 |
|---|---|---|
| span v2 GET | READ post 직전 | 복호 완료 |
| span v2 SET | seal | WRITE CQE |
| **span v3 GET** | **`storage_get_item()` 진입** | 복호 완료 |
| **span v3 SET** | **`storage_store_item_pac()` 진입** | `ITEM_WFLIGHT` 해제 |

v4 는 여기에 **분해**를 더했다(`6d70026`):

```text
span v3 = adm + v2 + ret
          │     │    └ prof_w_ret_ns   완료 → 응용 가시 (SET)
          │     └────── 기존 v2 구간
          └──────────── prof_r_admit_ns / prof_w_admit_ns   진입 → v2 시작
```

**이 분해가 없었으면 이번 캠페인은 못 했다.** `chain` 이 `adm` 을,
`reap` 이 `v2` 를 쥔다는 것도, `W` 를 줄이면 대기가 `adm` 으로 옮겨갈 뿐이라는
것도 이 세 열을 봐야 보인다.

---

## 7. 운영점 이동

```text
                mcT   W    nqp  reap  chain  pipeline
v3 최종          28   24    2     —      —      160
v4 캠페인 초기   30   40    4    12      8      256
v4 최종          30   24    4     8      8      256
```

v3 의 `nqp=2 W=24` 는 실효 동시성 `min(24, 2×16) = 24` 였다. v4 는 `nqp=4` 라
`min(24, 64) = 24` 로 같지만 **형태가 다르다** — 캠페인 실험 A 가 같은 총량에서
`nqp=4` 가 span 의 U 자 바닥임을 보였다(§14-4).

**v4 에서 움직인 두 값은 코드가 아니라 런타임 값이다:**

```text
W    40 → 24    혼합 +1.38%.  창은 24 이상에서 안 물린다 (체류 11.5)
reap 12 →  8    혼합 +2.09%,  GET-only span −17%
```

둘 다 처음엔 "빈 축"이라며 안 재려던 곳에서 나왔다.

---

## 8. 성능 — v3 대비

```text
                    v3 (span v3 기준)   v4 최종      변화
1:9 혼합 처리량        9.83 M          11.10 M     +12.9%
GET span             316.24 µs         22.31 µs     14 배 감소
SET span             188.75 µs          9.11 µs     21 배 감소
GET-only 처리량            —           13.40 M
```

**로컬 메모리(stock) 대비** — 원 frontier 실험과 같은 바이너리(`97ceee04…`)
로 잰 대조:

```text
pipe    Port      stock     비율     원 실험 비율
   8   3.243     3.882    83.5%      72.54%
 256  13.287    16.417    80.9%        —      ← 운영 조건
```

**운영 조건에서 로컬 메모리의 80.9% 를 낸다.** 값을 원격에 두고 one-sided
RDMA 로 읽으며 AES-256-GCM 으로 봉인·복호하고 SEV-SNP guest 안에서 도는
대가가 19.1% 다.

---

## 9. v3 문서를 읽을 때 주의할 것

v3 시절 문서는 **그 시점의 기록으로 유효**하지만, 아래는 v4 에서 뜻이
달라졌으므로 그대로 인용하면 안 된다.

| v3 문서의 서술 | v4 에서 |
|---|---|
| 운영점 `mcT=28 nqp=2 pipeline=160` | `mcT=30 nqp=4 pipeline=256 W=24 reap=8 chain=8` |
| span 수치 (v2 기준) | v3 기준으로 재정의 — 직접 비교 불가 |
| `mcT=16 → 6.56 M` | 개선 전 빌드. 현재 빌드는 **9.279 M** |
| "완료 1 건당 고정비" | 고정이 아니다. 동시성의 함수 (§14-4, B 실험) |
| depth=1 천장 0.65 M | v4 에서 **11.5 M** |
| 기각된 손잡이 목록 | **지형이 바뀌면 부호가 바뀐다.** `reap`·`ext_setq_max`·flush-락-밖 세 개가 실제로 뒤집혔다 |

마지막 줄이 이 포트에서 가장 자주 되풀이된 교훈이다. **옛 판정은 그것이
측정된 지형이 바뀌면 살아남지 못한다.**
