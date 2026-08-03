# 최적화 히스토리 — 적용분 (v1 → v3 최종)

> **[v3 시점 기록]** 이 문서는 그 시점의 기록으로 보존한다. 현재 운영값은
> [`OPTIMAL_RUNBOOK.md`](OPTIMAL_RUNBOOK.md), 최신 결과는
> [`V4_RESULT.md`](V4_RESULT.md) 다.  v4 캠페인은 V4_RESULT.md §14.

기준일: **2026-07-31**. **실측 검증을 통과해 실제로 적용된** 최적화만 시간순으로
기록한다. 기각된 가설은 말미의 부록에 한 줄씩만 남긴다
(전체 근거는 `md/V2_THROUGHPUT_MAXIMIZATION.md`, `md/SET_CAMPAIGN_HANDOFF.md`).

## 결과 요약

```text
v1 (co-located)               4.165 M ops/s @ CPU 3.450 µs/op
GET-only 최종 (off-box)      11.779 M ops/s @ C_get 2.369 µs, span 15.96 µs
1:10 혼합 최종 (off-box)     10.195 M ops/s, GET span 16.03 / SET span 14.51 µs
                             양 게이트 동시 충족, 무결점, 메모리 노드 CPU 0
```

**①~⑦은 GET 전용 캠페인이었고 ⑧~⑪이 혼합 게이트 캠페인이다.** ⑦까지의
"도달 처리량" 열은 전부 GET-only 수치이며, ⑧부터는 워크로드가 늘어 열이 셋이다.

| 단계 | GET-only | 1:10 혼합 | 주 기여 |
|---|---:|---:|---|
| v1 기준선 | 4.165 M | — | — |
| ① v2 worker-inline 재설계 | 5.560 M | — | 구조 |
| ② vCPU pinning | 7.686 M | — | 방법론/배치 |
| ③ off-box client | 8.322 M | — | 위상 |
| ④ pipeline 배치 상각 (p128) | 9.094 M | — | 부하 형태 |
| ⑤ W/hashpower 튜닝 + 4K MTU + nqp=2 | 9.489 M† | — | 설정 |
| ⑥ in-request bucket prefetch | 10.003 M | — | 코드 |
| ⑦ cross-request prefetch | 10.357 M | — | 코드 |
| ⑧ pac — SET 완료 수거 비동기화 | 10.241 M | 8.035 M‡ | 구조 |
| ⑨ coherent data MR (커널 패치) | 11.322 M | 9.466 M | 커널+코드 |
| ⑩ loc magazine 스캔 | 11.138 M | 9.670 M | 코드 |
| ⑪ GCM 컨텍스트 1회 키잉 | **11.779 M** | **10.195 M** | 코드 |

† ④와 ⑤는 같은 구간에서 겹쳐 적용됨. 개별 기여는 각 절의 실측치 참조.
‡ 1:9 측정. 비율이 1:10으로 바뀌며 +1.4%가 붙는다.

> ⑦의 10.357 M과 ⑧의 10.241 M은 **회귀가 아니다.** 다른 bed·다른 창에서 잰
> 별개 측정이고 차이는 bed 드리프트(±2~3%) 안이다. ⑧의 값어치는 GET 숫자가
> 아니라 SET-only가 0.311 M → 2.348 M(7.6배)로 풀린 것이다.

---

## ① v2 재설계: worker-inline RDMA (구조)

**무엇**: v1의 IO thread 계층(`ext_threads`, `ext_io_depth`, 전역 staging
mutex/cond, submit queue)을 삭제하고, memcached worker가 QP/CQ/bounce/staging을
직접 소유·구동. GET은 같은 worker에서 post→drain→sync→decrypt, SET은 seal→
WRITE→CQE 확인 후 STORED (P2a/P2b).

**메커니즘**: thread 간 hand-off(큐잉, futex, 컨텍스트 스위치)를 op당 경로에서
제거. worker당 1..4 RC QP + 공유 CQ 1개.

**실측**: 4.165M → 5.560M (+33.5%), CPU/op 3.450 → 2.021 µs (−41%).
SET inline까지 포함해 1.991 µs.

**위치**: `extstore.c`(engine 전체), `storage.c`(submit/flush), `thread.c`
drain point. 사양은 `md/V2_CODE_SPEC.md`.

## ② vCPU pinning: identity map (방법론이자 성능)

**무엇**: qemu에 `-name guest=sev-snp,debug-threads=on`을 주고 부팅 후 vCPU
스레드를 host CPU에 항등 pin. launcher(`~/2026/sev/run_sev_snp_rdma.py`)가
기본 수행, `.vcpu_pin_map`으로 재정의, `--no-pin-vcpus`로 비활성.

**메커니즘**: host는 SMT 형제가 `(N, N+16)`인 물리 16코어. pin 없이는 guest
`taskset`이 물리 배치를 통제하지 못해 **모든 코어 배분 실험이 오염**되고,
worker들이 같은 물리 코어에 겹쳐 앉았다.

**실측**: 동일 자원에서 7.686M 도달(직전 최고 7.09M). 부수 발견: 물리 코어는
하드 상한이 아니다 — server 16 스레드를 물리 8코어에 몰아도 −9.5%뿐
(SMT 2번째 스레드 효율 ~90%, 워크로드는 지연 바운드).

## ③ off-box client: 부하 생성을 genie로 이전 (위상)

**무엇**: memtier를 guest 내부(loopback)에서 genie 박스(IPoIB, `10.99.0.3:11411`)
로 이전. guest 30 vCPU 전부를 서버에 배정.

**메커니즘**: co-located에서 client가 11.2 cpu-equiv(물리 16코어의 70%)를
소모 — 10M은 40 스레드를 32 논리 CPU에 요구해 산수상 불성립이었다. IPoIB
전송은 loopback보다 op당 비싸지만(수신 경로 포함 +0.5~0.6 µs/op) 해방되는
코어가 압도적으로 크다. 데이터 경로는 one-sided READ/WRITE뿐이라
**genie CPU 소모는 0** (누적 ~1.3e10 READ에서 0 jiffies 실측).

**실측**: 8.322M (+8% 즉시, 이후 모든 상위 기록의 전제). 서버 스레드 스윕
결과 mcT=28이 무릎(29는 softirq 경합으로 역효과).

**부속 실측**: IPoIB 패킷당 guest CPU 3.08~3.38 µs — 크기 무관 고정비.

## ④ 클라이언트 pipeline 심화: 배치 상각 (부하 형태)

**무엇**: memtier `--pipeline` 64 → 128(→160). 접속 수는 줄이는 방향
(depth-on-fewer-connections)이 일관되게 우세: 최종 형태 `-t28 -c4 -p160`.

**메커니즘**: 프로파일 차분으로 규명 — worker 수 증가 시의 효율 저하는
경합이 아니라 **배치당 고정비(sync ioctl, sendmsg)의 상각 악화**였다.
pipeline을 깊게 하면 worker wakeup당 처리 op가 늘어 고정비가 흩어진다.
span(post→decrypt)은 W가 결정하므로 pipeline 심화는 게이트를 건드리지
않는다 — 초과 부하는 소켓에서 대기한다.

**실측**: p64→p128 +10.5% (8.23→9.09M), sendmsg 0.589→0.380 µs/op.
p160 채택. (p192는 +1.0% 실질로 검증됐으나 최종 운영점에는 불포함.)

## ⑤ 설정 튜닝 묶음

| 항목 | 값 | 실측 근거 |
|---|---|---|
| `ext_worker_window` | **24** | 교대 A/B(xpf 최종 구성)로 정산: W24 10.003M vs W28 9.919M(서버 평균, 쌍 부호 엇갈림 = 실질 무승부)에 **span 23.5 vs 25.9~28.0 µs** — 동등 throughput에 여유 +2.4µs. 순차 사다리의 '24→28 +0.9%p'는 재현 안 됨(은퇴 방법의 3번째 반증). 32는 span>30 게이트 사망. span을 소비하는 유일한 노브 |
| `hashpower` | 22 | assoc_find 0.66→0.55 µs/op (W=24와 동반 적용 시 span −2.3 µs) |
| `ext_qp_per_worker` | 2 | 4와 성능 동일(무승부), QP 총수 절반(112→56)으로 단순화. 1은 ORD 16 < W라 파킹 발생, −4% |
| IPoIB MTU | 4092 | opensm `mtu=5`(genie) + 양측 `ip link set mtu 4092`. ~+1%, span −0.3 µs. datagram 유지(mlx5 enhanced IPoIB는 CM 미지원) |
| `ext_drain_spin` | 1024 | v2 초기 실측 무릎 (8은 p99 붕괴) |

## ⑥ in-request bucket prefetch (코드, +1.6%)

**무엇**: `item_get()`에서 `hash()` 직후, `item_lock()` 직전에 hash bucket
라인을 prefetch.

```c
hv = hash(key, nkey);
assoc_prefetch(hv);      /* bucket 라인 페치 시작 */
item_lock(hv);           /* ~50-150 ns의 coherency 왕복과 중첩 */
do_item_get(...);        /* assoc_find가 warm 라인을 침 */
```

**메커니즘**: SEV 하에서 bucket 접근은 직렬 DRAM 미스(프로파일 최대 단일
leaf, 0.55~0.66 µs/op). lock 획득이 소비하는 시간과 이 페치를 중첩.

**실측**: 교대 A/B 쌍 3개 전부 +부호(+1.80/+1.22/+1.65%), pooled +1.56%,
**span −1.2 µs 동반**. 이 여유가 최초 10M 통과(10.003M @ 25.2 µs)를 만들었다.

**위치**: `assoc.c: assoc_prefetch()`, 호출은 `thread.c: item_get()`.

## ⑦ cross-request prefetch (코드, +5.2% — 최대 단일 레버)

**무엇**: `proto_text.c: try_read_command_ascii()`에서 현재 명령을 처리하기
**전에**, read buffer에 이미 도착해 있는 다음 명령이 `get`이면 그 키를
hash해 bucket을 prefetch.

**메커니즘**: ⑥의 리드타임은 lock 창(~100 ns)뿐이다. p160 부하에서는 다음
요청이 항상 rbuf에 대기 중이므로, 리드타임을 **현재 요청 처리 시간 전체
(수백 ns)** 로 확장할 수 있다. 비용은 op당 MurmurHash 1회 + 260 B 유계 스캔,
상태 변경 없음.

**실측**: 교대 A/B pooled **+5.24%**(서버 측), 쌍 전부 +부호, **span도 전
런 하락**(bucket이 assoc_find 도달 전에 도착 → lock→decrypt 경로 단축),
CPU/op 2.50까지 하락. xpf 레그 전부가 −3% 등급 bed에서도 개별 10.18M+.

## 최종 운영점

```text
binary   memcached @ v3 tree (⑥+⑦ 포함), 태그 v3-10.35M-sustained
server   -t 28, ext_qp_per_worker=2, ext_worker_window=24, hashpower=22,
         ext_drain_spin=1024, EXT_READ_SLOTS=64, EXT_SLOT_SIZE=256
         (10.357M 지속 실측 자체는 W=28에서 수행; 이후 교대 A/B가 W=24를
          동등 throughput + span 여유 +2.4µs로 확정해 운영값을 24로 갱신)
fabric   IPoIB datagram MTU 4092 (opensm 4K broadcast group)
부하      memtier -t28 -c4 --pipeline=160, 1M × 64 B, 100% GET
검증      10.357M × 300 s @ span 26.70 µs, 무결점, genie CPU 0
```

절대값은 bed 등급(fresh boot 최상, 재시작마다 ±2~3%)에 의존한다 — 델타
주장은 교대 A/B로만, 절대값 주장은 fresh boot에서. 이 규율 자체가 이번
캠페인의 산출물이다.

---

## 부록: 기각된 가설 (실측 사인)

| 가설 | 사인 |
|---|---|
| 엔진 전역 stats mutex 제거 | A/B 무차이 (핫패스 정리 차원에서 유지) |
| 빈 CQ 폴링 절감 (`ext_drain_empty_max`) | poll 4.4회/op뿐, spin=1로도 무변화 (입력으로는 유지) |
| item lock 테이블 크기 (`item_lock_power`) | 축소·확대 모두 무익, 기본값 최적 (입력으로는 유지) |
| HCA QP-cache thrash (nqp 축소) | QP를 줄이면 오히려 악화 |
| coherent-MR 모듈 세트 | sync-off 시 GCM 전량 실패 — SWIOTLB 미우회 |
| item lock 64 B 패딩 | 포화 상태 무승부 |
| mcT=29 | −0.6%, p99.9 +30% (softirq 경합) |
| W=32 | 모든 밴드에서 span>30 — 게이트 사망 |
| IPoIB connected mode | mlx5 enhanced IPoIB가 커널에서 거부 |

남은 상한: sync ioctl 0.59 µs/op — advise 배치가 wire burst(W-종속)에 묶여
있어 상각 불가. 다음 단계가 필요하면 방향은 coherent-MR 커널 트랙의 실동작
구현이다.


---

## ⑧ pac — SET 완료 수거를 GET처럼 비동기화 (구조)

**무엇**: `storage_store_item_pac()`. 스텁을 커맨드 시점에 같은 `item_lock`
아래에서 게시하고, `STORED` 응답만 WRITE CQE로 미룬다. GET의
`io_pending`/`g_ret_head`/`storage_flush_returns` 기구를 그대로 쓴다.

**메커니즘**: 이전에는 `storage_store_item()`이
`while (!wait.done) extstore_worker_drain(...)`로 자기 WRITE CQE를 기다려
**워커당 SET 동시성이 1**이었다. GET은 비동기라 워커당 W=24가 동시에 뜨는데
SET만 직렬이었고, 혼합에서는 그 워커의 GET들이 head-of-line blocking을 당했다.

**실측**: SET-only 0.311 M → 2.348 M (7.6배). GET-only는 A/B에서 −1.4%로
span 동일 — 회귀 아님.

**대가**: `STORED`의 내구성 의미는 유지된다(응답은 여전히 CQE 이후). 대신
스텁이 WRITE 완료 전에 보이므로 `ITEM_WFLIGHT`로 그 사이 `storage_delete`가
loc을 해제하지 못하게 막는다. 소유권은 완료 콜백이 `item_lock` 아래에서 정리한다.

**기각된 이웃**: watermark gating(동기 대비 2배 손실), 연결 파킹(−40%),
seal-at-flush(3.15배 손실). 상세는 `md/SET_COST_ATTRIBUTION.md` 부록.

**위치**: `storage.c` `storage_store_item_pac`/`storage_set_return_cb`,
`memcached.c` `do_store_item` 두 경로, `proto_text.c` `cur_async_ok` 게이트.

## ⑨ coherent data MR — SWIOTLB 바운스 제거 (커널 패치 + 코드)

**무엇**: staging/bounce 풀을 `dma_alloc_coherent()`로 받아 그대로 MR로
등록한다(`mlx5dv_alloc_coherent_mr`). 등록 경로가 `dma_map_sgtable()`을
거치지 않으므로 바운스가 생기지 않고, `SYNC_FOR_{DEVICE,CPU}` advise가
아예 필요 없어진다.

**메커니즘**: SEV-SNP는 게스트 사설 메모리를 HCA가 DMA할 수 없어 커널이
**모든 DMA를 SWIOTLB로 바운스**한다. `set_memory_decrypted()`로 페이지를
공유로 만들어도 `ibv_reg_mr`이 `dma_map`을 부르는 한 바운스는 강제된다.
`dma_alloc_coherent`는 `dma_handle`을 직접 주므로 그 호출 자체가 사라진다.

**바운스가 실재함을 먼저 증명했다**: `EXT_SKIP_DMA_SYNC=1`로 advise만 빼자
100,000/100,000 badcrc. 같은 "sync 없음"인데 coherent MR에서는 0이다.

**실측**: `*_sync_avg_ns`가 GET 5,618 → 50 ns, SET 1,996 → 13 ns(계측 하한).
C_get 2.754 → 2.473 µs, **C_set 9.97 → 7.71 µs**. span은 GET −27%, SET −32%.
span 감소분이 sync 감소분보다 큰데, 바운스가 없으면 전송 자체도 짧아지기
때문이고 이 몫은 CPU 모델에 없던 덤이다.

**위치**: 커널 `coherent-data-mr-v2`, 사용자 `~/coherent-mr-v2/lib`,
`extstore.c` `dma_mr_alloc` + advise 게이트 3곳. 대조군은
`EXT_DISABLE_COHERENT_MR=1`(같은 바이너리에서 패치 이전 경로).

## ⑩ loc magazine 스캔 — 전역 뮤텍스 이탈 (코드)

**무엇**: 워커 전용 remote-loc magazine의 적중 조건을 "LIFO 최상단의 `len`
일치"에서 "배열 안에 같은 `len`이 있으면 swap-remove"로 바꿨다.

**메커니즘**: memtier의 `m-1 .. m-1000000`은 nkey가 3~9바이트라 `len`이 7종이고,
최상단이 맞을 확률이 1/7이었다. 나머지는 전역 `e->mutex`로 떨어졌고, perf에서
**SET CPU의 10.3%가 그 뮤텍스의 futex wake**(`try_to_wake_up` → 런큐 스핀락)로
나갔다. 28워커가 한 락에 직렬화되는 형태다.

**정확한 len 제약은 유지한다** — magazine은 push 때 회계를 빼지 않으므로 다른
len으로 pop하면 `bytes_used`가 표류하고, `free_loc_global`이 잔액 부족을
`slot_acct_leak`으로 보고 **슬롯을 버린다**. 통계 오차가 아니라 실제 누수다.

**실측**: 키 길이만 균일하게 바꾼 대조에서 2.12 M vs 3.10 M로 원인을 먼저
확정한 뒤 고쳤다. 같은 부팅 A/B 2.19 M → 3.12 M(+42.2%), p99 절반.
off-box에서 **SET-only 2.640 M → 4.121 M(+56%)**, busyCPU 23.3 → 28.0.

**부수 효과**: 오래 미해결이던 "SET-only가 CPU 포화가 아니다"의 원인이
이것이었다. 이제 SET-only 실효 CPU/op와 혼합에서 푼 `C_set`이 일치한다.

**위치**: `extstore.c` `extstore_alloc` magazine 경로.

## ⑪ GCM 컨텍스트 1회 키잉 (코드)

**무엇**: `ext_crypto_{seal,open}`이 연산마다 `EVP_*Init_ex(ctx, NULL, NULL,
g_key, nonce)`로 키를 넘기던 것을, 스레드별 ctx에 키를 한 번만 넣고 연산은
IV만 바꾸도록(`..., NULL, nonce`) 고쳤다.

**메커니즘**: OpenSSL 3.x는 키가 들어오면 AES 키 스케줄을 다시 펴고 GHASH
테이블(`CRYPTO_gcm128_init`)을 다시 만들며, 그 재초기화 경로가 provider를
**문자열 파라미터로 조회**한다. perf에서 GET CPU의 약 6%가
`EVP_CIPHER_CTX_get_iv_length`/`get_key_length`/`ctrl`이었다.
키는 기동 시 한 번 정해지고 바뀌지 않으므로 전부 불필요한 일이다.

**실측**: 격리 `open` 275.6 → 169.0 ns, `seal` 291.6 → 183.4 ns.
서버 계측 read 630 → 471 ns, seal 986 → 817 ns.
**C_get 2.523 → 2.369 µs**, 1:10 혼합 9.670 M → **10.195 M**.

**주의**: `ext_crypto_init`은 워커가 뜨기 전에 끝나야 한다. 나중에 키를
바꾸면 이미 만들어진 ctx가 옛 키를 계속 쓴다(이 포트에 교체 경로는 없다).
재사용 ctx에 GCM 상태가 남는 위험은 `test_ext_crypto.c`가 거부 경로 뒤에서
길이를 바꿔 1,000회 왕복해 지킨다.

**위치**: `ext_crypto.c` `get_ctx`/`ext_crypto_seal`/`ext_crypto_open`.

---

## ⑧~⑪ 회고 — 레버는 비중이 정한다

마지막 3.4%를 넘긴 것은 ⑪이고, 그 상승분의 **105%가 GET 쪽**이었다
(C_get −6.1%, C_set는 노이즈 안에서 정지). ⑪이 SET 전용 패치가 아니라
`seal`/`open`을 공유하는 헬퍼였고, 1:10에서 GET이 10배 자주 돌리기 때문이다.

**1:10에서 GET이 CPU의 78.1%를 쓴다.** SET이 op당 2.8배 비싸다는 사실이
"SET이 병목"처럼 보이게 하지만, 비중을 곱하면 같은 1% 절감의 가치가
**GET : SET = 3.6 : 1**이다.

그렇다고 ⑧~⑩이 헛일이었던 것은 아니다. ⑩ 없이 ⑪만 있으면 `C_set`이 7.71에
묶여 9.846 M에서 멈추고, ⑪ 없이 ⑩만 있으면 9.670 M이다. **둘 다 필요했다.**

## 감사에서 하지 않기로 한 것들 (2026-07-31 연산량 감사)

- **도어벨 배칭** — GET은 **이미 한다**(`worker_post`가 최대 32개 WR 체인에
  `ibv_post_send` 한 번). SET은 `ext_setq_max=1`이라 묶을 것이 없고 2 이상은
  span 계약을 깬다.
- **`sev_es_ghcb_hv_call` 2.13%** — 워크로드 비용이 **아니다.** 호출자가
  `__perf_event_task_sched_out → amd_pmu_disable_all → native_read_msr`로,
  perf 자신의 PMU MSR 접근이 SEV에서 트랩하는 것이다. 관측하지 않으면 없다.
- **SET의 item 재할당 16.3%**(`do_item_unlink`+`do_item_link`+`item_acct_add`)
  — memcached 코어가 item을 불변으로 두어 독자가 락 없이 읽게 하는 설계다.
  제자리 갱신은 그 전제를 무너뜨린다. 이득 대비 위험이 나쁘다.

**아직 미귀속**: GET의 `pthread_mutex_lock`+`unlock` 9.44%(item_lock)와
SET의 `assoc_find` 5.52%(GET의 2.7배). 콜그래프가 프레임 포인터 없이 끊겨
`-fno-omit-frame-pointer` 빌드가 있어야 규명된다.
