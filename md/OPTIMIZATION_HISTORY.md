# 최적화 히스토리 — 적용분 (v1 → v3 최종)

기준일: 2026-07-29. 최종 도달점 기준으로, **실측 검증을 통과해 실제로 적용된**
최적화만 시간순으로 기록한다. 기각된 가설은 말미의 부록에 한 줄씩만 남긴다
(전체 근거는 `md/V2_THROUGHPUT_MAXIMIZATION.md`).

## 결과 요약

```text
v1 (co-located)                4.165M ops/s @ CPU 3.450 µs/op
v3 최종 (off-box, fresh bed)  10.357M ops/s @ CPU 2.484 µs/op, span avg 26.70 µs
                              300초 지속, GET 무결점, 메모리 노드 CPU 0
```

| 단계 | 도달 처리량 | 주 기여 |
|---|---:|---|
| v1 기준선 | 4.165M | — |
| ① v2 worker-inline 재설계 | 5.560M | 구조 |
| ② vCPU pinning | 7.686M | 방법론/배치 |
| ③ off-box client | 8.322M | 위상 |
| ④ pipeline 배치 상각 (p128) | 9.094M | 부하 형태 |
| ⑤ W/hashpower 튜닝 + 4K MTU + nqp=2 | 9.489M† | 설정 |
| ⑥ in-request bucket prefetch | 10.003M | 코드 |
| ⑦ cross-request prefetch | **10.357M** | 코드 |

† ④와 ⑤는 같은 구간에서 겹쳐 적용됨. 개별 기여는 각 절의 실측치 참조.

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
