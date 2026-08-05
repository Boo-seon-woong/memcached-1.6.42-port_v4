# Optimal 시행 런북 (v4 최종 운영점)

기준일: **2026-08-03**, 배포 바이너리 sha `b4c18e9710cc693c48531181`
(브랜치 `v4`). 이 문서 하나로 최적 시행을 재현할 수 있도록 조건·세팅·환경·
기대치·주의사항을 모두 담는다.

> ### 계약과 달성 상태
>
> ```text
> 계약   1:10 혼합(SET:GET) 10 M ops/s  AND  GET-only 10 M ops/s — 동시 충족
>        두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
>        span 정의는 v3 — backend 진입에서 응용 가시 완료까지
> ```
>
> #### span 정의 — 정본
>
> **2026-08-01 에 v2 에서 v3 로 넓혔다.** 서버는 두 정의를 동시에 내보내므로
> 어느 쪽 수치인지 반드시 확인해야 한다.
>
> **두 정의가 무엇을 재는가 — 이것이 차이의 전부다:**
>
> | | 재는 것 |
> |---|---|
> | **span v2** | **장치가 실제로 일한 시간.** RDMA 전송과 암복호. **대기는 앞뒤로 전부 밖이다** |
> | **span v3** | **요청을 backend 에 맡긴 순간부터 응용이 결과를 쓸 수 있을 때까지.** 제출 대기와 가시화 대기를 포함한다 |
>
> 한 줄로: **v2 는 "얼마나 빨리 전송했나", v3 는 "얼마나 빨리 답했나".**
>
> 구간으로 옮기면 차이는 정확히 이것이다.
>
> ```text
> GET   v2 는 post 부터, v3 는 backend 진입부터. 끝은 같다.
>       차이 = admit                    제출을 기다린 시간
>
> SET   v2 는 seal→CQE, v3 는 진입→WFLIGHT 해제.
>       차이 = admit (앞) + ret (뒤)    제출 대기 + 완료를 응용에 보이기까지
> ```
>
> **정의를 바꿔도 서버는 그대로다.** v2 로 계약을 통과하면서 클라이언트가
> SET 지연을 7.45 ms 로 보고할 수 있었던 이유가 이것이다 — 전송은 7.8 µs 로
> 빨랐고, 그 앞뒤의 대기가 계측 밖이었다.
>
> ```text
>                시작                                   끝
> span v2 GET    READ post 직전                         복호 완료
> span v3 GET    storage_get_item() 진입  (:470)        복호 완료          ← 계약
> span v2 SET    seal                                   WRITE CQE 관측
> span v3 SET    storage_store_item_pac() 진입 (:904)   ITEM_WFLIGHT 해제  ← 계약
>                                                       (storage.c:876)
> ```
>
> **v3 는 v2 를 포함한다.** `GET v3 = admit + v2`, `SET v3 = admit + v2 + ret`.
> 세 성분은 각각 독립 집계라 합이 v3 와 맞는지가 정합성 검사가 된다.
>
> ```text
> stats 필드   extstore_prof_read_e2e_avg_ns    ← v3 (계약)
>              extstore_prof_read_avg_ns        ← v2 (참고)
>              extstore_prof_span_ver           ← 3 이어야 한다
> ```
>
> 왜 넓혔는지와 그때 드러난 대기는
> [`EXTENDED_SPAN_DIAGNOSIS.md`](EXTENDED_SPAN_DIAGNOSIS.md).
>
> **2026-08-03 최종 게이트에서 전부 충족됐다** (각 120 초):
>
> ```text
> GET-only  13.397 M   span 21.90 = adm 4.39 + v2 17.51        ✓ ✓
> 1:9 혼합  11.099 M   GET 22.31 = 9.17 + 13.14                ✓ ✓
>                      SET  9.11 = 0.52 + 7.97 + 0.62          ✓ ✓
> ```
>
> **측정 비율은 `--ratio=1:9` 다 — 계약 문구의 `1:10` 이 아니다.**
> `1:9` 는 SET 비중 10%, `1:10` 은 9.09% 이고 SET 이 GET 보다 비싸므로
> **1:9 가 더 무거운 쪽**이다. 즉 계약을 보수적으로 만족한다(비율 차이만으로
> 약 1.4% — v3 기록). 1:10 수치를 주장하려면 그 비율로 다시 재야 한다.
>
> 근거는 [`V4_RESULT.md`](V4_RESULT.md), v3 대비 구조 변화는
> [`V3_TO_V4_CHANGES.md`](V3_TO_V4_CHANGES.md).

> **구성 요소는 한 벌로만 유효하다.** 커널 모듈·사용자 lib·바이너리 셋 중
> 하나라도 옛 경로(`~/covlib`, `~/kvs-port-v3`)를 쓰면 조용히 sync 경로로
> 폴백해 **패치 이전을 재게 된다.** 판별은 §4 의 기동 게이트로 한다.

> 사람이 직접 순차 실행할 목적이라면 **`md/MANUAL_TEST_PROCEDURE.md`** 를
> 쓰고, 이 문서는 배경·근거 참조용으로 본다.

## 0. 기대 성능 (무엇이 나와야 정상인가)

fresh boot, 운영값, 1 M 프리로드 기준.

| 워크로드 | 기대 throughput | GET span | SET span |
|---|---:|---:|---:|
| **GET-only** (게이트) | 13.2~13.5 M ops/s | ~21.9 µs | — |
| **1:9 혼합** (게이트) | 11.0~11.2 M ops/s | ~22.3 µs | ~9.1 µs |
| SET-only (참고) | **미측정** — §9 | — | — |

**재현성을 직접 쟀다** — 같은 구성 반복 측정 기준:

```text
처리량   GET-only σ 1.01%,  혼합 σ 1.04%    →  2σ ≈ 2.0%
span     GET-only σ 0.60%
```

**2% 보다 작은 델타는 한 셀로 구별할 수 없다.** 개선을 주장하려면 반복이
필요하다 — 이 규칙 없이 판정했다가 `nqp=1` 단일 셀의 11.066 M 을 최고값으로
읽었고, 재측정에서 10.834 / 10.852 로 무너졌다.

계약선 대비 여유:

```text
혼합 처리량  +11.0%   ← 구속 지표.  σ 로 10.6
GET-only     +34%
GET span     21.90 대 30 → 37%
혼합 span    GET 34%,  SET 229%
```

- 게이트: **span avg < 30 µs**, GET·SET **둘 다**.
  obwatch 의 `gate` 줄은 GET 만 판정하므로 **`Sspan avg` 열을 직접 읽을 것.**
- 정합성 0-오차가 정상: `get_misses = badcrc_from_extstore =
  extstore_read/write_failures = engine_dead = ext_slot_acct_leak = 0`.
- span 표본 커버리지: `extstore_prof_read_count` 가 `cmd_get` 대비
  **−1.0% ~ +0.2%** 안이면 정상. 근거는 `md/SPAN_MEASUREMENT_REVIEW.md`.
- genie(메모리 노드) CPU 소모 = 0 (one-sided READ).

## 1. 하드웨어/토폴로지

```text
host (ariel)   AMD EPYC 9124 — 물리 16코어 SMT2 (형제쌍 N, N+16), L3 4×CCX
guest          SEV-SNP, 30 vCPU (host CPU에 항등 pin), HCA vfio passthrough
memory node    genie — 48 vCPU Xeon, 62 GiB; ConnectX 200 Gb/s
fabric         IB 직결, IPoIB: guest ibp1s0 10.99.0.3/24 ↔ genie ibs3 10.99.0.2/24
부하 생성       genie의 memtier → 10.99.0.3:11411 (TCP over IPoIB)
데이터 경로     guest memcached → genie 4 GiB MR, IBV_WR_RDMA_READ/WRITE만
```

**SMT 배치가 처리량 천장을 정한다.** vCPU 30 개가 host 0..29 에 1:1 로 핀돼
있고 형제쌍이 `(0,16)…(15,31)` 이라 **14 코어가 공유, 2 코어가 단독**이다.
공유 스레드는 단독의 0.7366 배이고, 이 모형이 `mcT` 축 네 점을 1% 안에서
맞힌다(`V4_RESULT.md` §9). **`mcT=30` 이 최적인 이유는 코어 수가 이기기
때문이지 스레드당 효율 때문이 아니다.**

## 2. genie 측 상태

### 2.0 정상 가동 중이라면 (변경 불필요)

```text
genie_memd     :11212, 4 GiB MR, --prefill 빌드 (reject-guard 포함)
opensm         partitions.conf: Default=0x7fff,ipoib,mtu=5,rate=2:ALL=full;
               (mtu=5 = 4K broadcast group — 이것이 없으면 IPoIB 4092 불가)
ibs3           10.99.0.2/24, mtu 4092
```

주의: **genie_memd 재시작은 guest 측 preload 를 무효화**한다. 재시작했다면
guest 에서 반드시 재프리로드.

### 2.1 genie 박스가 재부팅됐다면 — 대부분 소실된다

재부팅 후 자동 복구되는 것은 **opensm 뿐**이다. `genie_memd` 는 systemd unit
이 없는 평범한 프로세스라 죽고, `ibs3` 의 IP 와 MTU 는 netplan/NetworkManager
항목이 없어 **둘 다 사라진다.** 이 상태로 §3 을 진행하면 `ping 10.99.0.2` 가
실패하는데 원인이 guest 쪽처럼 보인다 — 아래를 **순서대로** 먼저 수행할 것.

```sh
# genie 측. opensm의 4K group이 MTU 설정보다 먼저 살아 있어야 한다
# (아니면 4092가 2044로 조용히 클램프된다 — 최초에 실제로 겪은 함정)
systemctl is-active opensm                     # active 확인
grep mtu=5 /etc/opensm/partitions.conf         # 4K broadcast group 확인

sudo ip addr add 10.99.0.2/24 dev ibs3         # 비영구 — 재부팅 시 소실
sudo ip link set ibs3 up
sudo ip link set ibs3 mtu 4092
cat /sys/class/net/ibs3/mtu                    # 4092여야 정상 (2044면 SM 확인)

cd <repo>/genie-server
cc -O2 -o genie_memd genie_memd.c -lrdmacm -libverbs   # 바이너리 없을 때만
./genie_memd 11212 4g --prefill
```

**`genie_memd` 는 §4 보다 먼저 떠 있어야 한다** — `ext_path` 는 엔진 초기화
시점에 연결하므로, 없으면 memcached 가 기동 실패한다.

## 3. guest 부팅 + bringup

```sh
# host에서
sudo ~/2026/sev/guestctl.sh up        # 30 vCPU + identity pin + direct-kernel-boot
# (내부적으로 run_sev_snp_rdma.py; pin 로그 "Pinned 30 vCPU threads" 확인)

# guest에서 (ssh -i ~/.ssh/snp_guest -p 2222 ubuntu@localhost)
sudo insmod ~/pb-guest/snp_shared-6.16.0-snp-guest-038d61fd6422-cachemode.ko
sudo rmmod mlx5_ib && sudo insmod ~/coherent-mr-v2/mlx5_ib.ko   # coherent data MR 빌드
sleep 3
sudo ip addr add 10.99.0.3/24 dev ibp1s0
sudo ip link set ibp1s0 up
sudo ip link set ibp1s0 mtu 4092      # SM이 4K일 때만 적용됨 (아니면 2044로 클램프)
ping -c2 10.99.0.2                    # genie 도달 확인
```

모듈이 실제로 새것인지는 **기능으로 판별한다.** `lsmod` 는 이름만 보고
`modinfo` 는 디스크 파일을 읽을 뿐이다.

```sh
LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib $HOME/coherent-mr-v2/bin/coherent_mr_smoke
# => coherent MR OK addr=0x... length=2097152 lkey=0x...
```

함정: `modprobe mlx5_core` 류를 건드리면 stock mlx5_ib 가 자동 로드된다 —
stock 에서는 `create_cq EINVAL`. 모듈 상태가 꼬이면 재부팅이 가장 빠르다.

> 옛 `coherent-mr-20260724` 세트는 여전히 **사용 금지**다(GCM 전량 실패).
> 지금 쓰는 것은 `~/coherent-mr-v2` 이며, `dma_alloc_coherent` 로 받은
> 비바운스 메모리를 MR 로 등록해 SYNC advise 자체를 없앤 빌드다.

## 4. 서버 기동 (v4 최종 운영값)

스크립트가 정본이다:

```sh
AD=64 RE=8 PC=8 SQ=1 INLINE=1 tools/exp1-arm.sh 20 24 4 64
#                                               │  │ │  └ EXT_READ_SLOTS
#                                               │  │ └── nqp
#                                               │  └──── W
#                                               └─────── ext_submit_batch
```

풀어 쓰면:

```sh
cd $HOME/kvs-port && taskset -c 0-29 env \
  LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib:$HOME/kvs-port \
  MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
  EXT_RDMA_PROF=1 EXT_SELFTEST=1 \
  EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key \
  EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
  $HOME/coherent-mr-v2/bin/memcached -p 11411 -U 0 -t 30 -m 2048 -c 16384 -R 1024 \
  -o ext_path=10.99.0.2:11212:4g,ext_worker_window=24,ext_qp_per_worker=4,ext_drain_spin=1024,hashpower=22,ext_submit_batch=20,ext_admit_max=64,ext_submit_inline,ext_reap_every=8,ext_post_chain=8,ext_setq_max=1
```

**기동 게이트 — 셋 다 통과해야 이후 측정이 유효하다.**

```sh
grep -icE "coherent MR [0-9]+B" /tmp/mc.log     # => 2  (READ + WRITE)
pid=$(pgrep -x "memcached[.a-z]*")
tr '\0' '\n' < /proc/$pid/environ | grep -c EXT_DISABLE_COHERENT_MR   # => 0
printf 'stats settings\r\nquit\r\n' | nc -q1 127.0.0.1 11411 \
  | grep -c ext_submit_inline                   # => 1   ★ v4 에서 추가
```

**세 번째 줄이 핵심이다.** stock memcached 나 옛 빌드가 포트를 쥐고 있으면
`ext_submit_inline` 이 없다. **로그만 보면 안 된다** — 이유는 §7.

`selftest` 의 `SYNC_FOR_{DEVICE,CPU} advise failed: No such file or directory`
두 줄은 **정상이며 통과 신호다** — coherent MR 에는 umem 이 없어 advise 가
ENOENT 를 내는데, 바로 다음 줄에서 페이로드가 왕복한다.

### 4-1. 각 값이 왜 그 값인가

| 항목 | 값 | 이유 |
|---|---|---|
| binary sha | `b4c18e9710cc693c48531181` | **sha 로 확인.** 기능 grep 은 경로를 구별 못 한다 |
| `taskset 0-29` / `-t 30` | worker 30 | SMT 모형이 최적임을 예측·확인. 28 은 −3%, 20 은 −21% |
| `ext_submit_inline` | **필수** | 파싱 즉시 post. 없으면 제출 대기 285 µs 가 되살아난다 |
| `ext_post_chain=8` | post 8 건 묶음 | 4 는 span −21% 지만 처리량 무릎 아래, **12 이상은 GET span 31 µs 로 계약 위반** |
| `ext_reap_every=8` | 8 건마다 수거·재개 | 12(옛값) 대비 span −17%, 혼합 +2.09%. 4 이하는 처리량을 판다 |
| `ext_worker_window=24` | W=24 | 체류가 11.5 라 24 이상은 안 물린다. 40 대비 혼합 +1.38% |
| `ext_qp_per_worker=4` | QP 120 개 | 같은 총 동시성에서 span U 자의 **바닥**. 1~2 는 ORD 포화, 8~16 은 완료 분산 |
| `ext_admit_max=64` | 워커당 체류 상한 | 바인딩하지 않는다(체류 11.5). 폭주 방지용 |
| `ext_setq_max=1` | SET 배치 없음 | 2 이상은 span 계약을 깬다. coherent MR 에는 상각할 SYNC 가 없다 |
| `hashpower=22` | 4 M buckets | **20 으로 줄이면 −3.8% / −2.5%** — 탐침 증가가 캐시 이득을 이긴다 |
| `ext_drain_spin=1024` | 실측 무릎 | 낮추면 p99 붕괴 |
| `EXT_READ_SLOTS=64` | worker 당 bounce 64 | W 보다 크게 유지 |
| `ext_loc_mag_depth=64` (기본) | 워커 전용 loc magazine | 0 이면 전역 `e->mutex` 로 몰려 SET −40% |
| `MLX5_COHERENT_QP/CQ=1` | patched verbs 경로 | SEV 에서 필수 |
| `EXT_RDMA_PROF=1` | span 계측 | 게이트 판정의 데이터 소스. 자체 비용 0.60% |
| `EXT_SKIP_DMA_SYNC` | **절대 설정 금지** | 바운스 MR 에서 sync 만 빼면 100% 손상. coherent MR 과 혼동 말 것 |

**`chain` 과 `reap` 은 독립이 아니다.** 유효 체인은 `min(chain, reap)` 이고
`storage.c:607` 이 reap 틱 안에서 체인을 flush 한다. 둘을 따로 조정하면
의도한 값이 안 나온다 — `chain` 을 12·16·20·24·32 로 올려도 `reap=12` 면
결과가 전부 같다.

## 5. keyspace 프리로드 (guest 로컬, 셋업 단계)

```sh
LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-29 \
  $HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
  -d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 \
  -n 7813 --hide-histogram
# 확인: stats의 curr_items == 1000000
```

**`--key-prefix=m-` 가 계약이다** — memtier 기본값(`memtier-`)과 다르므로
부하 측이 같은 prefix 를 쓰지 않으면 100% miss 가 되어 hit 경로가 측정되지
않는다 (실제 사고 전례 있음).

**서버를 재기동했으면 반드시 다시 한다.** 포트는 stub 을 로컬에 두므로
재기동하면 사라진다.

## 6. 부하 (genie 측에서 실행)

```sh
COMMON="-s 10.99.0.3 -p 11411 -P memcache_text -d 64 --key-prefix=m- \
  --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \
  --distinct-client-seed --hide-histogram -t 30 -c 4 --pipeline=256"

memtier_benchmark $COMMON --ratio=0:1 --test-time=120   # GET-only (게이트)
memtier_benchmark $COMMON --ratio=1:9 --test-time=120   # 1:9 혼합 (게이트)
```

```text
t30 c4 p256 = 120 conns × 256 = 30,720 in-flight
```

**pipeline 은 128 이상이어야 계약을 만족한다** — 64 에서 혼합 8.30 M 이다.
256 이 꼭짓점이고 384 는 소폭 퇴행한다(`V4_RESULT.md` §8).

**비율 주의**: 위는 `1:9` 다. 계약 문구는 `1:10` 이고 그쪽이 SET 이 적어 더
쉽다. **두 비율의 수치를 섞어 인용하지 말 것** — 비율 차이만으로 약 1.4%.

## 7. 측정 규율 (수치를 주장하려면)

```text
반복      2% 보다 작은 델타는 한 셀로 판정 불가 (2σ). 개선 후보는 n≥2
절대값    fresh boot 에서. 재시작마다 bed 가 흔들린다
델타      교대 A/B 로만. 순차 사다리는 세션 워밍을 구성 효과로 오독한다(3회 반증)
길이      30 초 단발은 판정 불가. 게이트 주장은 120 초
동승      bpftrace 등 트레이서 동승 창의 throughput 은 무효 (−28% 실측)
추적기    shape-trace 는 하나만.  pgrep -c -f 'shape-trace-v[3].sh'
          (대괄호 없이 세면 자기 명령줄까지 세서 항상 하나 더 나온다)
perf      /usr/lib/linux-tools/6.8.0-111-generic/perf 를 쓴다.
          /usr/bin/perf 는 6.8 래퍼라 6.16 guest 에서 거부한다.
          -F 199, 콜그래프 없음, 10 초 (guest 디스크가 6.8 G 뿐)
```

**검증은 실패 모드가 남길 수 없는 것을 읽어야 한다.** 낡은 산출물이 검증을
대신한 사례가 세 번 있었다:

| 사례 | 무엇이 속였나 | 올바른 확인 |
|---|---|---|
| 추적기 6 개 누적 | `pgrep -f` 가 자기 명령줄을 셈 | 대괄호 패턴 |
| perf 무음 실패 | stderr 를 버려 파일이 안 생긴 걸 못 봄 | 스모크로 샘플 수 확인 |
| **stock 이 포트인 척** | `pkill -x memcached` 가 `mc_stock` 을 못 죽여 포트가 bind 실패로 즉사하고 `/tmp/mc.log` 가 안 덮여 **옛 게이트 줄이 남음** | `stats settings` 의 `ext_submit_inline` |

마지막 것은 `curr_items` 도 `num_threads` 도 두 바이너리가 같아 구별되지
않았고, `ps` 는 tmux 명령줄을 잡아서 못 쓴다. `tools/exp1-arm.sh` 가 이제
`/tmp/mc_*` 도 죽이고 로그를 비운 뒤 기동하며 서비스 중인 빌드를 판정한다.

운영 보조 도구: `tools/obup.sh`(기동+프리로드+샘플러),
`tools/obslice.sh`(UTC 창 절단), `tools/exp0-slice.py`(창 슬라이스),
`tools/ledger.py`(셀 원장), `tools/obalt.sh`(바이너리 교대 A/B).

## 8. 협업 프로토콜 (genie 와의 측정 조율)

`conversation.md` append-only + `[ariel]`/`[genie]` 커밋 + NEXT 토큰 +
commit-monitor 상시 무장 (`md/COLLABORATION.md`). 측정 창은 genie 가 UTC 로
보고하고 ariel 이 서버 측을 절단한다 — 양측이 시각을 맞출 필요 없다.

**두 규칙이 실패로 얻어졌다:**

```text
① genie 가 `<블록> 완료` 를 보내기 전에는 서버를 건드리지 않는다
   — 셀 수를 세는 것으로는 부족하다. 요청 범위 밖의 셀이 올 수 있다
② 서버 값을 바꿨으면 반드시 채널에 알린다
   — 무장만 하고 안 알리면 genie 는 영문 모르고 대기한다
```

①을 어겨 genie 셀을 네 번 죽였고, ②를 어겨 한 번 대기시켰다.

## 9. 이 런북이 다루지 않는 것

```text
SET-only 워크로드   v4 에서 측정하지 않았다. v3 는 셀마다 W1/W2/W3 3 종을
                    쟀는데 v4 캠페인은 GET-only 와 1:9 혼합 2 종만 썼다.
                    계약 지표가 아니라서 뺐지만 v3 대비 공백이다
1:10 비율           계약 문구의 비율. v4 는 전부 1:9 (더 무거운 쪽)로 쟀다
optcand 대응        "각 변경이 얼마씩 기여했나"의 누적 측정.
                    v3 에 있고 v4 에 없다
```

셋 다 측정 자체는 가능하고, 필요해지면 §6 의 부하 문구만 바꾸면 된다.
