# Optimal 시행 런북 (v3 최종 운영점)

기준일: **2026-07-31**, 빌드 `771ca34068c7609936b2e58a`(`ce92044`, 브랜치
`v3-set-pac`). 이 문서 하나로 최적 시행을 재현할 수 있도록 조건·세팅·환경·
기대치·주의사항을 모두 담는다.

> ### 계약과 달성 상태
>
> ```text
> 계약   1:10 혼합(SET:GET) 10 M ops/s  AND  GET-only 10 M ops/s — 동시 충족
>        두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
> 우선   span < 30 µs 가 10 M ops/s 보다 앞선다. 상충하면 span을 지킨다.
> ```
>
> **2026-07-31 정본에서 전부 충족됐다.** 1:10 혼합 10.195 M(Gspan 16.03 /
> Sspan 14.51), GET-only 11.779 M(span 15.96). 근거·귀속은
> [`SET_CAMPAIGN_HANDOFF.md`](SET_CAMPAIGN_HANDOFF.md) §16.
>
> 이전 판의 "GET-only 10.357M 단일 게이트"는 **폐기**됐다. 그 수치는 pac·
> coherent MR 이전 것이라 현재 스택과 비교 대상이 아니다.

> **구성 요소는 한 벌로만 유효하다.** 커널 모듈·사용자 lib·바이너리 셋 중
> 하나라도 옛 경로(`~/covlib`, `~/kvs-port-v3`)를 쓰면 조용히 sync 경로로
> 폴백해 **패치 이전을 재게 된다.** 판별은 §4의 로그 게이트로 한다.

> 사람이 직접 순차 실행할 목적이라면 **`md/MANUAL_TEST_PROCEDURE.md`**(양측
> 명령을 실행 위치와 함께 단계별로 나열하고 결과 검증까지 포함)를 쓰고, 이
> 문서는 배경·근거 참조용으로 본다.

## 0. 기대 성능 (무엇이 나와야 정상인가)

fresh boot, W=24, 1 M 프리로드 기준. 셋 다 나와야 정상이다.

| 워크로드 | 기대 throughput | GET span | SET span |
|---|---:|---:|---:|
| **1:10 혼합** (게이트) | 10.1~10.2 M ops/s | ~16.0 µs | ~14.5 µs |
| **GET-only** (게이트) | 11.7~11.8 M ops/s | ~16.0 µs | — |
| SET-only (참고) | 4.2 M ops/s | — | ~7.6 µs |
| 재시작 누적 후 | −2~3%까지 하강 가능 | +1~2 µs | |

op당 CPU는 `C_get 2.369 µs`, `C_set 6.63 µs`다. 혼합 처리량을 예측하려면
`avg = f·C_set + (1−f)·C_get`, `throughput = busyCPU / avg`를 쓴다
(1:10이면 f = 1/11 = 0.0909). 세 창에서 ±1% 안으로 맞는다.

**1:10에서 GET이 CPU의 78.1%를 쓴다.** 같은 1% 절감의 가치가
GET : SET = 3.6 : 1이므로, 추가 최적화는 GET 쪽이 레버가 크다.

- 게이트: **span avg < 30 µs**, GET(`read_avg_ns`)과 SET(`write_avg_ns`)
  **둘 다**. 현재 여유는 GET 14.0 µs / SET 15.5 µs.
  obwatch의 `gate` 줄은 GET만 판정하므로 **`Sspan avg` 열을 직접 읽을 것.**
- 정합성 0-오차가 정상: `get_misses = badcrc_from_extstore =
  extstore_read/write_failures = engine_dead = ext_slot_acct_leak = 0`.
- span 표본 커버리지: `extstore_prof_read_count`가 `cmd_get` 대비 **−1.0% ~
  +0.2%** 안이면 정상. **정확히 같아야 한다는 조건이 아니다** — 부하 중
  `stats reset`은 `cmd_get`을 먼저 리셋하고 prof를 나중에 리셋하므로 그 사이
  op가 `cmd_get`에만 잡히고(+방향), 혼합 워크로드에서는 transient visibility
  재시도가 시도마다 표본을 남겨 prof가 더 커진다(−방향). 근거는
  `md/SPAN_MEASUREMENT_REVIEW.md` §3, §5.
  범위가 비대칭인 이유: **+쪽은 구조적**이라(28 워커 리셋 순회 시간에만
  의존) 실측 ~0.02%에 10배 여유면 충분하지만, **−쪽은 워크로드 의존**이라
  (쓰기 비중과 visibility 실패율에 따라 변동) 1:1 혼합에서 잰 +0.045%가
  일반화된다고 가정할 수 없어 넉넉히 잡았다. 좁히려면 대상 워크로드에서
  재측정할 것.
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

## 2. genie 측 상태

### 2.0 정상 가동 중이라면 (변경 불필요)

```text
genie_memd     :11212, 4 GiB MR, --prefill 빌드 (reject-guard 포함)
opensm         partitions.conf: Default=0x7fff,ipoib,mtu=5,rate=2:ALL=full;
               (mtu=5 = 4K broadcast group — 이것이 없으면 IPoIB 4092 불가)
ibs3           10.99.0.2/24, mtu 4092
```

주의: **genie_memd 재시작은 guest 측 preload를 무효화**한다. 재시작했다면
guest에서 반드시 재프리로드.

### 2.1 genie 박스가 재부팅됐다면 — 대부분 소실된다

재부팅 후 자동 복구되는 것은 **opensm뿐**이다. `genie_memd`는 systemd unit이
없는 평범한 프로세스라 죽고, `ibs3`의 IP와 MTU는 netplan/NetworkManager 항목이
없어 **둘 다 사라진다.** 이 상태로 §3을 진행하면 `ping 10.99.0.2`가 실패하는데
원인이 guest 쪽처럼 보인다 — 아래를 **순서대로** 먼저 수행할 것.

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

**`genie_memd`는 §4(서버 기동)보다 먼저 떠 있어야 한다** — `ext_path`는 엔진
초기화 시점에 연결하므로, 없으면 memcached가 기동 실패한다.

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

모듈이 실제로 새것인지는 **기능으로 판별한다.** `lsmod`는 이름만 보고
`modinfo`는 디스크 파일을 읽을 뿐이다.

```sh
LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib $HOME/coherent-mr-v2/bin/coherent_mr_smoke
# => coherent MR OK addr=0x... length=2097152 lkey=0x...
```

함정: `modprobe mlx5_core`류를 건드리면 stock mlx5_ib가 자동 로드된다 —
stock에서는 `create_cq EINVAL`. 모듈 상태가 꼬이면 재부팅이 가장 빠르다.

> 옛 `coherent-mr-20260724` 세트는 여전히 **사용 금지**다(GCM 전량 실패).
> 지금 쓰는 것은 그것과 다른 `~/coherent-mr-v2`이며, `dma_alloc_coherent`로
> 받은 비바운스 메모리를 MR로 등록해 SYNC advise 자체를 없앤 빌드다.

## 4. 서버 기동 (최종 운영값)

```sh
cd $HOME/kvs-port && taskset -c 0-27 env \
  LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib:$HOME/kvs-port \
  MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
  EXT_RDMA_PROF=1 EXT_SELFTEST=1 \
  EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key \
  EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
  $HOME/coherent-mr-v2/bin/memcached -p 11411 -U 0 -t 28 -m 2048 -c 16384 -R 1024 \
  -o ext_path=10.99.0.2:11212:4g,ext_worker_window=24,ext_qp_per_worker=2,ext_drain_spin=1024,hashpower=22
```

**기동 로그 게이트 — 이 줄이 없으면 이후 측정은 전부 무효다.**

```sh
grep -icE "coherent MR [0-9]+B" /tmp/mc.log     # => 2  (READ 458752B + WRITE 236544B)
pid=$(pgrep -x "memcached[.a-z]*")
tr '\0' '\n' < /proc/$pid/environ | grep -c EXT_DISABLE_COHERENT_MR   # => 0
```

`selftest`의 `SYNC_FOR_{DEVICE,CPU} advise failed: No such file or directory`
두 줄은 **정상이며 통과 신호다** — coherent MR에는 umem이 없어 advise가
ENOENT를 내는데, 바로 다음 줄에서 페이로드가 왕복한다. 데이터 경로는 애초에
advise를 호출하지 않는다.

로그 파일은 낡을 수 있으므로 `/proc/$pid/environ` 쪽이 권위 있는 확인이다
(2026-07-31에 이 함정을 밟았다 — `MANUAL_TEST_PROCEDURE.md` §D-1).

| 항목 | 값 | 이유(한 줄) |
|---|---|---|
| binary | `771ca34068c7609936b2e58a` (`ce92044`, `v3-set-pac`) | pac ⊕ coherent MR ⊕ magazine 스캔 ⊕ GCM 1회 키잉. **sha로 확인할 것** — `grep -ac assoc_prefetch`는 GET prefetch만 보므로 SET 경로를 구별 못 한다 |
| `ext_pac_set` (기본 on) | SET 완료를 비동기 수거 | 끄면 워커가 WRITE CQE에 묶여 SET-only 0.31 M로 붕괴 |
| `ext_setq_max=1` (기본) | SET 배치 없음 | 2 이상은 span 계약을 깬다(64에서 SET span 255 µs). coherent MR에서는 상각할 SYNC가 없어 배치할 이유도 없다 |
| `ext_loc_mag_depth=64` (기본) | 워커 전용 loc magazine | 0으로 끄면 전역 `e->mutex`로 몰려 SET −40% |
| `taskset 0-27` / `-t 28` | worker 28 | 29부터 softirq 경합(p99.9 +30%), 30은 게이트 붕괴 |
| `ext_worker_window=24` | W=24 | W28과 동등 throughput, span −2.4 µs (교대 A/B 확정) |
| `ext_qp_per_worker=2` | QP 56개 | 4와 동등, 절반으로 단순화; 1은 ORD<W 파킹으로 −4% |
| `hashpower=22` | 4M buckets | assoc_find −0.1 µs/op |
| `ext_drain_spin=1024` | 실측 무릎 | 낮추면 p99 붕괴 |
| `EXT_READ_SLOTS=64` | worker당 bounce 64 | W보다 크게 유지 |
| `MLX5_COHERENT_QP/CQ=1` | patched verbs 경로 | SEV에서 필수 |
| `EXT_RDMA_PROF=1` | span 계측 | 게이트 판정의 데이터 소스 |
| DMA sync | **coherent MR에서 자동 비활성** | `*_sync_avg_ns`가 계측 하한(<100 ns)이어야 정상. 수천 ns면 폴백이 떠 있는 것이다 |
| `EXT_SKIP_DMA_SYNC` | **절대 설정 금지** | 바운스 MR에서 sync만 빼면 100 %(100,000/100,000) 손상된다. coherent MR과 혼동하지 말 것 |

## 5. keyspace 프리로드 (guest 로컬, 셋업 단계)

```sh
LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-27 \
  $HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
  -d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 \
  -n 7813 --hide-histogram
# 확인: stats의 curr_items == 1000000
```

**`--key-prefix=m-`가 계약이다** — memtier 기본값(`memtier-`)과 다르므로
부하 측이 같은 prefix를 쓰지 않으면 100% miss가 되어 hit 경로가 측정되지
않는다 (실제 사고 전례 있음).

## 6. 부하 (genie 측에서 실행)

```sh
COMMON="-s 10.99.0.3 -p 11411 -P memcache_text -d 64 --key-prefix=m- \
  --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \
  --distinct-client-seed --hide-histogram -t 28 -c 4 --pipeline=160"

memtier_benchmark $COMMON --ratio=0:1  --test-time=300   # GET-only  (게이트)
memtier_benchmark $COMMON --ratio=1:10 --test-time=300   # 1:10 혼합 (게이트)
memtier_benchmark $COMMON --ratio=1:0  --test-time=300   # SET-only  (참고)
```

**게이트는 앞의 둘이고 동시에 충족해야 한다.** 혼합 비율은 1:9에서
**1:10**으로 바뀌었다(2026-07-30) — 이전 기록의 1:9 수치와 직접 비교하지
말 것, 비율 변경만으로 +1.4%가 붙는다.

- `t28 c4 p160` = 112 conns × 160 = 17,920 in-flight.
  depth-on-fewer-connections가 실측 우세 방향.
- p192는 +1.0% 실질이지만 최종 운영점 미포함(선택 사항).
- genie 박스는 8.22M 시점 측정에서 33% busy — 부하 생성은 병목이 아니다
  (10.36M 시점에서 재측정하지 않았으나 결론은 동일).

## 7. 측정 규율 (수치를 주장하려면)

- **서버 측이 authoritative**: `cmd_get` 델타 / 실측 구간, span은
  `read_avg_ns`. client 수치와 0.01~0.5% 오차로 일치해야 정상.
- **절대값 주장 → fresh boot에서.** 재시작마다 bed가 ±2~3% 흔들린다.
- **델타 주장 → 교대 A/B로만** (base/치료 교대, 쌍별 비교). 순차 사다리는
  세션 워밍을 구성 효과로 오독한다(3회 반증됨).
- 30초 단발은 판정 불가. 판정은 60초×3런, 최종 주장은 300초 지속.
- bpftrace 등 트레이서 동승 창의 throughput은 무효(mc28에서 −28% 실측).
- 운영 보조 도구: `tools/obup.sh`(기동+프리로드+샘플러),
  `tools/obslice.sh`(UTC 창 절단), `tools/obsweep.sh`(구성 사다리),
  `tools/obalt.sh`(바이너리 교대 A/B).

## 8. 협업 프로토콜 (genie와의 측정 조율)

`conversation.md` append-only + `[ariel]`/`[genie]` 커밋 + NEXT 토큰 +
commit-monitor 상시 무장 (`md/COLLABORATION.md`). 측정 창은 genie가 UTC로
보고하고 ariel이 서버 측을 절단한다 — 양측이 시각을 맞출 필요 없음.
