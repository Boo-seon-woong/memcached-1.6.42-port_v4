# SET 26.9 µs/op 내역 규명 + GET이 받은 최적화 중 SET이 못 받은 것

작성 2026-07-29. 프레임 포인터 빌드(`-fno-omit-frame-pointer`)로 SET-only
부하를 프로파일해 비용을 귀속시키고, GET 경로와 대조해 걷어낼 대상을 찾는다.

> ### 2026-07-31 — 이 문서의 26.9 µs는 `C_set 6.63 µs`가 됐다 (4.1배 절감)
>
> 여기서 귀속한 항목들이 이후 순서대로 처리됐다. 경위는
> [`OPTIMIZATION_HISTORY.md`](OPTIMIZATION_HISTORY.md) ⑧~⑪:
>
> | | 처리 |
> |---|---|
> | 워커 동기 점유 | pac이 제거 (SET-only 0.311 M → 2.348 M) |
> | SWIOTLB sync | coherent MR이 제거 (`write_sync` 1,996 → 13 ns) |
> | `extstore_alloc` 전역 락 | loc magazine 스캔 (SET-only 2.640 → 4.121 M) |
> | crypto | GCM 1회 키잉 (`seal` 986 → 817 ns) |
>
> **귀속 방법론은 그대로 유효하다** — 실제로 마지막 두 건도 같은 방식
> (프레임 포인터 없는 스택을 첫 해석 프레임으로 귀속)으로 찾았다. 다만
> **아래 표의 절대값과 비율은 당시 것**이며 현재 구성을 설명하지 않는다.
>
> 현재 SET 프로파일과 남은 항목은 [`SET_WORKFLOW.md`](SET_WORKFLOW.md) 말미와
> [`SET_CAMPAIGN_HANDOFF.md`](SET_CAMPAIGN_HANDOFF.md) §15-2.

## 1. 방법과 판독 주의

leaf가 libc 내부 주소로 잡히는데 **libc는 프레임 포인터도 dynsym 엔트리도
없어** 심볼로 풀리지 않는다. 대신 스택 워커가 libc 프레임을 건너뛰고 다음
walkable 프레임(= memcached 함수)을 남기므로, **"첫 해석 프레임"으로 귀속**
하면 어느 호출자가 그 시간을 쓰는지 확정된다. 아래 표는 그 기준이다.

## 2. 귀속 결과 (60,558 샘플)

| 비용 주체 | 비중 | 정체 |
|---|---:|---|
| `slabs_alloc` | **33.31%** | 전역 `slabs_lock` 대기 |
| `slabs_free` | **13.42%** | 전역 `slabs_lock` 대기 |
| `do_store_item` | 8.49% | |
| `extstore_alloc` | **6.53%** | 전역 엔진 `stats_mutex` (`STAT_L`) |
| `pthread_mutex_lock` | 5.80% | |
| `item_remove` | 4.66% | |
| `storage_store_item` | 4.20% | |
| `storage_delete` | **3.21%** | 전역 엔진 락 경유 |
| `__pthread_mutex_unlock` | 3.17% | |
| `extstore_worker_drain` | 3.13% | CQ 폴링 (동기 대기) |
| `assoc_find` | 2.25% | |
| `extstore_free_loc` | **1.82%** | 전역 엔진 락 |
| `sendmsg` / `ioctl` / `mlx5_poll_cq` | 4.38% | 실제 I/O |
| `ext_crypto_seal` | 0.56% | **암호화는 0.6%뿐** |

### 묶어서 보면

```text
전역 slabs_lock (alloc+free)        46.7%
전역 엔진 락 (extstore alloc/free/delete) 11.6%
기타 mutex                            9.0%
────────────────────────────────────────
락 대기 소계                        ~67%

실제 I/O (sendmsg/ioctl/poll)         4.4%
AES-GCM 암호화                        0.6%
```

**SET CPU의 약 2/3이 전역 뮤텍스 두 개에서 소모된다.** RDMA도 암호화도
비용이 아니다.

이것이 앞서 관측된 세 가지를 한꺼번에 설명한다.

- 워커 이용률이 31%인 이유 — 락에 blocked되면 CPU를 쓰지 않는다
- 동시성을 늘려도 SET이 ~300 K에서 상한을 치는 이유 — 전역 락이 직렬화한다
- span(5.03 µs)이 짧은데 op당 86.8 µs가 걸리는 이유 — 대기는 span 밖이다

## 3. GET은 왜 이 비용을 안 내는가

`storage_get_item()`은 복호 목적지를 **워커 전용 캐시**에서 꺼낸다.

```c
if (ntotal <= g_plaintext_slot_size) {
    new_it = do_cache_alloc(g_plaintext_cache);   // 워커 전용, 전역 락 없음
    if (new_it != NULL) read_cache = g_plaintext_cache;
}
if (new_it == NULL) {                              // 캐시 미스일 때만
    g_plaintext_slab_fallback++;
    new_it = do_item_alloc_pull(ntotal, clsid);    // ← 여기서만 slabs_lock
}
```

반면 `storage_store_item()`은 stub item을 **매번** `do_item_alloc()`으로
잡는다 — 전역 `slabs_lock` 경유다. staging 슬롯만 워커 전용
(`extstore_worker_staging_get()` → `bm_alloc`)이고, item 할당은 아니다.

## 4. GET이 받았고 SET이 못 받은 최적화

`md/OPTIMIZATION_HISTORY.md`의 7단계를 경로별로 대조하면 이렇다.

| # | 최적화 | GET | SET |
|---|---|:--:|:--:|
| ① | worker-inline 구조 | ✅ | ✅ |
| ② | vCPU pinning | ✅ | ✅ |
| ③ | off-box client | ✅ | ✅ |
| ④ | **배치 상각** (요청·완료·SYNC) | ✅ | ❌ |
| ⑤ | 설정 튜닝 (W/hp/nqp/MTU) | ✅ | 일부 |
| ⑥ | **in-request bucket prefetch** | ✅ | ❌ |
| ⑦ | **cross-request prefetch** | ✅ | ❌ |
| — | **워커 전용 할당 캐시** | ✅ | ❌ |

⑦은 코드가 명시적으로 GET만 본다 — `proto_text.c:398`이
`memcmp(cont, "get ", 4)`로 다음 명령이 GET일 때만 prefetch한다.

**즉 SET은 ①②③만 받았다.** GET 최적화 4건을 통째로 못 받은 상태이고,
그중 가장 큰 것(워커 전용 캐시)이 지금 SET 비용의 47%를 만들고 있다.

## 5. 걷어낼 수 있는 것 — 예상 효과

| 대상 | 방법 | 근거 | 예상 |
|---|---|---|---|
| **`slabs_lock` (46.7%)** | GET처럼 워커 전용 stub 캐시 도입 | GET이 이미 검증 | 최대 −47% |
| **엔진 전역 락 (11.6%)** | `extstore_alloc`/`free_loc`의 회계를 per-worker로 (drain 경로에 이미 적용한 패턴) | 동일 패턴 기적용 | 최대 −12% |
| **SYNC_FOR_DEVICE (1.9 µs/op)** | 쓰기 배치당 1회로 상각 (GET은 advise 1회에 13 read) | GET이 이미 검증 | −1.6 µs/op |
| 동기 대기 (`drain` 3.13% + 워커 점유) | 비동기 재개 구조 | GET 구조 | 구조적 |
| prefetch ⑥⑦ | SET 키도 prefetch | 저비용 | 소폭 |

앞의 셋만으로 CPU의 **약 60%**가 대상이 된다. 26.9 → 대략 11 µs/op 수준이
1차 목표가 되고, 여기에 비동기화가 얹히면 `md/SET_10M_REQUIREMENTS.md`의
예산(2.57 µs/op)에 대한 재산정이 가능해진다.

> 주의: 위 예상은 **락 대기가 사라지면 그 시간이 회수된다**는 가정에 기댄
> 상한이다. 실제로는 경합이 다른 지점으로 이동할 수 있으므로, 한 건씩
> 교대 A/B로 검증해야 한다 — 이 캠페인에서 7건 중 6건이 그렇게 죽었다.

## 6. 착수 순서 (수정)

앞서 `SET_10M_REQUIREMENTS.md` §6에서 "26.9 µs 규명 먼저"라고 했고, 그것이
이 문서다. 규명 결과에 따라 순서를 다시 잡는다.

```text
1) 워커 전용 stub 할당 캐시     ← 최대 단일 항목(47%), GET에 검증된 패턴
2) 엔진 전역 락 잔여 제거        ← 12%, 이미 쓰던 패턴의 확장
3) SYNC_FOR_DEVICE 배치화        ← 예산 산정을 바꾸는 항목
4) 비동기 재개 구조              ← 가장 큰 작업. 1~3 후 상한이 확정된다
```

1·2는 구조 변경 없이 가능하고 서로 독립이다. 4를 먼저 하면 락 경합이 그대로
남은 채 동시성만 올려 경합을 악화시킬 수 있다.


---

## 7. 적용 결과 (2026-07-29)

§6의 순서대로 1~3단계를 적용하고 각 단계를 교대 A/B로 검증했다. 각 단계 후
재프로파일해 다음 대상을 데이터로 정했다 — 세 번 모두 예상과 달랐다.

| 단계 | 내용 | SET-only | CPU/op | A/B |
|---|---|---:|---:|---|
| 기준 | xpf | 320 K/s | 27.41 µs | — |
| ① | 워커 전용 **item** magazine | 472 K/s | 19.23 | +47.3%, 쌍 3/3 |
| ② | 워커 전용 **remote-loc** magazine | 911 K/s | 12.04 | +88.4%, 쌍 4/4 |
| ③ | 카운터 5종을 원자 연산으로 | 1.68 M/s | 7.39 | +80.3%, 쌍 3/3 |
| ③′ | spin 카운터 배치화 | 1.71 M/s | 7.29 | +2.3%, 쌍 3/3 |

**누적 5.3배, CPU/op −73%.** span은 5.1~5.3 µs로 불변 — RDMA는 처음부터
병목이 아니었고 지금도 아니다.

혼합 워크로드가 더 크게 개선됐다. SET이 워커를 점유하는 시간이 87 µs에서
16 µs로 줄면서 head-of-line blocking이 완화된다.

```text
1:1 혼합   이전 0.591 M/s 합계  →  현재 2.05 M/s 합계  (+247%)
```

### 각 단계에서 경합이 이동한 경로

프로파일 상위가 매 단계 완전히 바뀌었다. 이것이 "한 건씩 적용하고 재프로파일"
규율의 근거다.

```text
xpf   slabs_alloc 33.3 + slabs_free 13.4          (전역 slabs_lock)
 ①    extstore_alloc 30.8 + storage_delete 16.5   (전역 엔진 mutex)
 ②    do_item_unlink 22.3 + do_item_link 12.9     (STATS_LOCK, lru_locks)
 ③    storage_store_item 46.6                     (동기 대기 busy-wait)
```

③ 이후 남은 최대 항목은 **동기 대기 자체**이고, 이는 4단계(비동기)의 대상이다.

## 8. 4단계(비동기 SET) — 미완, 브랜치 보존 (§9의 실측 후기로 대체됨)

`v3-async-set` 브랜치에 구현돼 있다. **기능은 정확하다** — 크래시 없음,
`curr_items`가 `cmd_set`을 정확히 추적, miss/RDMA 실패/leak 0. 구현 중 두
버그를 잡았다.

- 재개 시 응답은 suspend해 둔 `resp`에 써야 한다. `out_string(c, …)`은
  `conn_set_state()`로 연결 상태를 되돌려 파이프라인 중간에서 `c->item`을
  깨뜨린다.
- PENDING 분기는 정상 경로의 `out_string()`이 하던 `conn_set_state(c,
  conn_new_cmd)` 전이를 대신 해줘야 한다. 안 하면 `drive_machine`이
  `conn_nread`로 되돌아와 해제된 `c->item`을 역참조한다.

**막힌 지점은 완료 통지 방식이다.** 기존 0-timeout 자기 재무장 drain 이벤트는
GET처럼 outstanding이 금방 0이 되는 것을 전제한다. 비동기 SET이 쓰기를 오래
물고 있으면 조건이 상시 참이 되어 이벤트 루프를 점유하고 명령 처리·전송을
굶긴다(실측: SET당 drain 139 k회, 99% empty, **29 set/s**). 진전 가드를 넣으면
반대로 뒤집힌다 — 모든 연결이 파킹되면 소켓 이벤트가 없어 `EVLOOP_ONCE`가
블록되고 CQ를 폴링할 주체가 사라진다.

해법은 **CQ completion channel을 fd로 libevent에 등록**하는 것이다
(`ibv_create_cq`에 채널 지정 + `ibv_req_notify_cq`). 폴링이 아니라 인터럽트
구동이 되어야 한다. 현재 GET 지연에 맞춰 튜닝된 폴링 CQ 설정을 바꾸는
작업이므로 별건으로 다룬다.

`md/SET_10M_REQUIREMENTS.md`의 예산 재산정: 현재 CPU 7.29 µs/op 기준 28코어
포화 시 상한은 3.84 M/s이고, 실측 1.71 M은 그 45%다. 나머지 55%가 동기 구조
손실이므로 4단계가 열리면 3.8 M 부근이 목표가 되고, 10 M에는 CPU를 추가로
2.8 µs/op까지 낮춰야 한다.

---

## 9. 4단계 실측 후기 (2026-07-30) — 두 비동기 시도 모두 main 밖

§8의 전망 중 실측으로 정정된 것을 기록한다.

**"폴링이 아니라 인터럽트 구동이 되어야 한다"는 틀렸다.** CQ completion
channel을 주 진행 수단으로 쓰면 완료 1건마다 get_cq_event/ack/re-arm의 µs
단위 비용이 op당 예산(2.8 µs)을 통째로 먹는다. 채널은 idle 시 fallback으로만
유효하다(`V3_REVIEW_FINDINGS.md` §4.3). 그 형태로 구현된 것이 `v3-set-10m`의
adbdda8이고, 대기 중 CPU 1.097 → 0.104 core-s/s를 확인했다.

**비동기 두 갈래의 처분:**

| 갈래 | 설계 | 결과 |
|---|---|---|
| `v3-async-set` | watermark gating (연결 파킹 없음, 응답 전송만 게이트) | 정확하나 동기 대비 2배 손실(0.90M vs 1.74M), op당 ~7µs 유휴 미규명. 브랜치 보존 |
| `v3-set-10m` | 연결 파킹 (STORE_PENDING 시 conn_mwrite 파킹, B-1 순서 수정의 대가) | **실 호스트 기각**: SET-only 1.0M(동기 대비 −40%), 1:9 혼합 GET 10.7M→5.1M. 상한 = 연결수÷파킹시간 |
| **`v3-set-pac`** (세 번째, 2026-07-30) | publish-at-command — 게시는 명령 시점, 응답만 CQE까지. GET의 io_pending 수거 구조 재사용, 배치 없음 | **1차 통과**: co-located A/B에서 +21%(1.99→2.41M), 클라이언트 p99 −18%, CPU/op −20%, 결함 0 |

동기 경로(step ①②③③′ + A-결함 수정)가 main이고, A/B 계열 기준선은
1.71~1.74M @ CPU 7.29 µs/op이다. 2026-07-30 동기 재측정은
**2.27M @ span 6.21 µs**(memtier@genie, 서버는 `cca9807`+`no_ext_async_set`
— bed·클라이언트 상이로 절대값 비교 불가, `SET_WORKFLOW.md` §0-1).

**세 시도의 차이가 말하는 것**: 실패한 둘은 응답을 미루면서 **게시까지**
미뤘고(그래서 순서를 지키려 연결이나 전송을 묶어야 했다), pac은 게시를
동기 경로 그대로 두고 응답만 미룬다. 즉 비동기화의 비용은 "기다리는 방식"이
아니라 **"게시를 미룬 대가"**였다. 다음 순서는 off-box 정본 bed에서의 pac
재판정이고, off-CPU 간극 규명은 pac 적용 후 상태에서 하는 것이 맞다
(`SET_WORKFLOW.md` §0-2·§3).

---

## 10. SYNC 배치화 적용 결과 (2026-07-30) — §5 최대 레버 실현

§5가 "가장 큰 단일 레버"로 지목하고 §9가 "pac이 전제를 충족시켰다"고 적은
항목을 적용했다(`v3-set-pac` `2d0290a`). 예측과 실측이 일치한 드문 사례다.

```text
예측 (§4)   sync 1.90 µs → 6배 상각 시 0.32 µs
실측        sync 1.90 µs → 0.32 µs   (상각 계수 63.7)
```

처리량 +20.8 %(2.375 → 2.868 M/s, co-located), 결함 0. 상세·스윕표는
`SET_WORKFLOW.md` §0-3.

### 10.1 갱신된 op당 비용 분해

같은 바이너리·같은 bed에서 GET을 대조군으로 재서 공통 비용을 상쇄시켰다.

| | server CPU/op | 비고 |
|---|---:|---|
| SET (pac + 배치) | **5.77 µs** | 28코어 환산 4.85 M/s |
| GET | 2.52 µs | 28코어 환산 11.11 M/s |
| **차이 = SET 고유** | **3.25 µs** | 다음 최적화 대상 |

측정된 성분: crypto 0.92 µs, sync 0.32 µs. 이 둘은 GET 쪽 대응 비용(복호,
SYNC_FOR_CPU 상각)과 대체로 상쇄되므로, **3.25 µs의 정체는 stub item 할당 ·
원격 loc 할당 · 해시테이블 게시(unlink+link) · 구 loc 반납 · io_pending
할당**이다. 어느 것이 지배적인지는 미규명이고, 이 캠페인의 이력상 예측하지
말고 프로파일해야 한다(매 단계 프로파일 1위가 바뀌었다).

### 10.2 방법론: co-located 환산의 보정 계수

클라이언트를 guest 안에 두면 서버 코어를 잠식하므로 절대값을 못 믿는다.
그런데 **GET을 같은 방식으로 재서 정본 실측과 대조하면 보정 계수가 나온다**:

```text
GET  co-located 28코어 환산   11.11 M/s
GET  off-box 정본 실측        10.35 M/s
                              → co-located 환산이 약 7 % 낙관적
```

이 계수를 SET에 적용해 4.85 → **≈4.5 M/s**를 off-box 추정치로 쓴다. 추정이지
실측이 아니므로 판정은 정본 bed에서 해야 하지만, genie 접근이 없는 기간에도
"어느 방향으로 얼마나 틀리는지"를 알고 진행할 수 있게 해 준다.

> 서버 CPU만 분리하는 측정은 `/proc/<pid>/stat`의 utime+stime 델타를 cmd_set
> 델타로 나눈다(guest `~/pac-ab-20260730/srvcpu.sh`). guest 전체 busyCPU를
> 쓰면 클라이언트 CPU가 섞여 SET 비용이 과대평가된다.
