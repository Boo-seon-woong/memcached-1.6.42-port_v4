# SET 26.9 µs/op 내역 규명 + GET이 받은 최적화 중 SET이 못 받은 것

작성 2026-07-29. 프레임 포인터 빌드(`-fno-omit-frame-pointer`)로 SET-only
부하를 프로파일해 비용을 귀속시키고, GET 경로와 대조해 걷어낼 대상을 찾는다.

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
