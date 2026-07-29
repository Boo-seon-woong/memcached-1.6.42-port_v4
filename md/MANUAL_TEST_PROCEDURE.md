# 수동 실행 절차서 — optimal throughput test

사람이 두 박스에 직접 접속해 순차 실행하고 결과를 검증하기 위한 문서.
**모든 단계에 실행 위치가 명시돼 있다.** 참조용 배경은
`md/OPTIMAL_RUNBOOK.md`, 최적화 이력은 `md/OPTIMIZATION_HISTORY.md`.

```text
소요 시간   준비 10~15분 + 측정 6분
접속        [genie]  genie 박스 셸
            [ariel-host]  ariel 호스트 셸
            [ariel-guest] ssh -i ~/.ssh/snp_guest -p 2222 ubuntu@localhost
```

기호: 각 단계 제목의 `[...]`가 실행 위치다. `# =>` 는 기대 출력.

---

## Phase A — [genie] 메모리 노드 확인/기동

### A-1. 현재 상태 확인

```sh
pgrep -a genie_memd
ip -br addr show ibs3
cat /sys/class/net/ibs3/mtu
systemctl is-active opensm
```

```text
# => genie_memd 프로세스 존재, ibs3 = 10.99.0.2/24 UP, mtu 4092, opensm active
#    네 줄 모두 정상이면 Phase A 끝. Phase B로 이동.
#    genie_memd가 없거나 IP/MTU가 비어 있으면 A-2 (재부팅 후 상태다).
```

### A-2. 재부팅 후 복구 — **순서 중요**

opensm의 4K broadcast group이 MTU 설정보다 먼저 살아 있어야 한다. 아니면
4092가 2044로 조용히 클램프된다.

```sh
systemctl is-active opensm                     # => active
grep mtu=5 /etc/opensm/partitions.conf         # => Default=...,ipoib,mtu=5,rate=2:ALL=full;

sudo ip addr add 10.99.0.2/24 dev ibs3
sudo ip link set ibs3 up
sudo ip link set ibs3 mtu 4092
cat /sys/class/net/ibs3/mtu                    # => 4092  (2044면 opensm 확인)

cd <repo>/genie-server
cc -O2 -o genie_memd genie_memd.c -lrdmacm -libverbs    # 바이너리 없을 때만

# nohup 필수: genie_memd는 SIGHUP을 무시하지 않는다(SigIgn=0). 그냥 `&`로
# 띄우면 SSH를 끊는 순간 죽고, MR이 사라진 증상은 한참 뒤 ariel의 Phase D
# 실패나 측정 중단으로 나타나 원인에서 멀어진다.
nohup ./genie_memd 11212 4g --prefill > ~/genie_memd.log 2>&1 &
sleep 2; pgrep -a genie_memd                   # => 프로세스 확인
```

> 세션을 완전히 분리하려면 `setsid ./genie_memd ... &` 또는 tmux/screen 안에서
> 기동해도 된다. 요점은 **조작자의 터미널에 매달아 두지 말 것**.

> **주의**: `genie_memd`를 재시작하면 ariel 측 preload가 무효가 된다.
> Phase E 이후에 재시작했다면 Phase D-2(프리로드)부터 다시 해야 한다.

---

## Phase B — [ariel-host] guest 기동

```sh
sudo ~/2026/sev/guestctl.sh status              # 이미 떠 있으면 B-2 생략 가능
sudo ~/2026/sev/guestctl.sh down                # 떠 있고 fresh boot를 원하면
sleep 8
sudo ~/2026/sev/guestctl.sh up
grep -i pinned /tmp/snp-guest.log | tail -1
# => "Pinned 30 vCPU threads (identity map to host CPUs)"
```

```sh
# SSH가 열릴 때까지 대기 (도달성 확인만 — 접속되는 것은 아니다)
until ssh -i ~/.ssh/snp_guest -p 2222 -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=no ubuntu@localhost true 2>/dev/null; do sleep 5; done
echo "guest up"
```

> ⚠️ **이 루프는 접속 상태를 남기지 않는다.** 아직 ariel 호스트 셸이다.
> Phase C부터 Phase F까지는 전부 guest 안에서 실행해야 하므로, 반드시
> 다음 단계(C-0)에서 먼저 접속할 것.

> **절대값을 주장할 측정이면 fresh boot에서 하라.** 재시작이 누적된 guest는
> 같은 구성에서도 2~3% 낮게 나온다(문서화된 bed 드리프트).

---

## Phase C — [ariel-guest] 모듈·네트워크 bringup

부팅 직후 1회만. 이미 완료된 guest면 C-2 확인만 하고 넘어간다.

### C-0. **guest 접속** — 여기서부터 실행 위치가 바뀐다

```sh
ssh -i ~/.ssh/snp_guest -p 2222 ubuntu@localhost
```

접속 후 아래로 위치를 확인한다. **Phase F까지 이 셸에서 진행한다.**

```sh
whoami; hostname; nproc
# => ubuntu / (guest hostname) / 30
#    'seonung'이 나오면 아직 호스트다 — 위 ssh를 먼저 실행할 것.
```

### C-1. 모듈 스왑 + IP

```sh
sudo insmod ~/pb-guest/snp_shared-6.16.0-snp-guest-038d61fd6422-cachemode.ko
sudo rmmod mlx5_ib && sudo insmod ~/covlib/mlx5_ib.ko
sleep 3
sudo ip addr add 10.99.0.3/24 dev ibp1s0
sudo ip link set ibp1s0 up
sleep 2
sudo ip link set ibp1s0 mtu 4092
```

### C-2. 확인

```sh
nproc                                  # => 30
lsmod | grep -E "^mlx5_ib|^snp_shared" # => 둘 다 로드됨
cat /sys/class/net/ibp1s0/mtu          # => 4092   (2044면 genie opensm 확인)
ping -c2 -W2 10.99.0.2                 # => 0% packet loss
```

`ping` 실패 시 원인은 대개 **genie 쪽**이다 — Phase A-2로 돌아갈 것.

---

## Phase D — [ariel-guest] 서버 기동 + keyspace 프리로드

### D-0a. 관측 도구 배포 (최초 1회)

```sh
# ariel 호스트에서
scp -i ~/.ssh/snp_guest -P 2222 <repo>/tools/obwatch.sh ubuntu@localhost:/tmp/
```

### D-0. **바이너리 확인** — 최적 구성의 전제

guest의 `~/kvs-port-v3/`에는 A/B용 변종들이 함께 있고, 평범한 `memcached`가
구버전으로 남아 있을 수 있다. **prefetch 두 개(⑥⑦)가 없는 빌드로 돌리면
약 6.9% 낮게 나온다** — 실제로 겪은 사고다.

```sh
grep -ac assoc_prefetch ~/kvs-port-v3/memcached
# => 1 이상이어야 정상. 0이면 구버전이므로 아래로 교체:
#    (서버가 실행 중이면 "Text file busy" — 먼저 내리고 실행)
cp ~/kvs-port-v3/memcached.xpf ~/kvs-port-v3/memcached
grep -ac assoc_prefetch ~/kvs-port-v3/memcached    # => 재확인
```

`memcached.xpf`도 없다면 저장소에서 빌드해 배포한다(호스트에서
`make -j"$(nproc)"` 후 `scp memcached ...:~/kvs-port-v3/memcached`).
기준 빌드의 sha256은 `ed219244c5621570…`.

### D-1. 서버 기동 (tmux — ssh 세션이 끊겨도 유지)

```sh
tmux kill-session -t mc 2>/dev/null
for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done

tmux new-session -d -s mc "cd \$HOME/kvs-port && exec taskset -c 0-27 env \
LD_LIBRARY_PATH=\$HOME/covlib:\$HOME/kvs-port \
MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1 \
EXT_CRYPTO_KEY=\$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
\$HOME/kvs-port-v3/memcached -p 11411 -U 0 -t 28 -m 2048 -c 16384 -R 1024 \
-o ext_path=10.99.0.2:11212:4g,ext_worker_window=24,ext_qp_per_worker=2,ext_drain_spin=1024,hashpower=22 \
> /tmp/mc.log 2>&1"

sleep 8
pgrep -x "memcached[.a-z]*" >/dev/null && echo "server UP" || tail -5 /tmp/mc.log
# => "server UP"
grep -i "genie_connect OK" /tmp/mc.log
# => raddr/rkey/size와 workers=28 qps/worker=2 window=24 ord=16 이 보이면 정상
```

### D-2. 프리로드 (1M × 64 B) — **`--key-prefix=m-` 필수**

```sh
LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-27 \
  $HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
  -d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 \
  -n 7813 --hide-histogram

printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' | grep curr_items
# => STAT curr_items 1000000
```

30~60초 소요. `curr_items`가 1000000이 아니면 다음으로 넘어가지 말 것.

---

## Phase E — 측정 (양측 협조)

부하는 genie가 **창보다 60초 길게** 돌리고, ariel이 그 안쪽에 창을 잡는다.
이렇게 하면 사람이 시각을 정밀하게 맞출 필요가 없다.

### E-1. [genie] 부하 시작 — 워크로드를 하나 골라 실행

공통 인자(모든 워크로드 동일):

```sh
COMMON="-s 10.99.0.3 -p 11411 -P memcache_text -d 64 \
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --key-pattern=R:R --distinct-client-seed --hide-histogram \
  -t 28 -c 4 --pipeline=160"
```

> **`--distinct-client-seed`는 지우지 말 것.** memtier 기본값은 클라이언트
> 전체가 *같은 고정 시드*를 쓰는 것이라, 이 플래그가 없으면 112개 커넥션이
> **동일한 키 순열을 같은 속도로 훑는다.** GET은 hot-key 워크로드가 되어
> 캐시 지역성이 비정상적으로 좋아지고(기록 10.357M과 비교 불가), SET이 섞인
> W2~W4는 모든 클라이언트가 같은 키를 동시에 쓰면서 item lock 경합이 버킷
> 하나로 몰린다 — 혼합 워크로드를 특성화하려는 목적과 정반대다.
> 캠페인의 모든 측정(10.357M 지속 포함)이 이 플래그를 달고 수행됐다.
>
> 반면 프리로드(D-2)에는 이 플래그가 **없는 것이 맞다.** `--key-pattern=P:P`는
> 클라이언트별로 키 구간을 나눠 결정적으로 훑으므로 시드가 결과에 관여하지
> 않는다.

| # | 워크로드 | 명령 | 목적 |
|---|---|---|---|
| **W1** | GET only | `memtier_benchmark $COMMON --ratio=0:1 --test-time=360` | 기준 — optimal 운영점 |
| **W2** | SET only | `memtier_benchmark $COMMON --ratio=1:0 --test-time=360` | remote WRITE 경로. seal→WRITE→CQE→STORED |
| **W3** | SET:GET 1:9 | `memtier_benchmark $COMMON --ratio=1:9 --test-time=360` | 혼합. 읽기/쓰기 경로 동시 부하 |
| **W4** | SET:GET 1:1 | `memtier_benchmark $COMMON --ratio=1:1 --test-time=360` | 쓰기 비중 상한 확인 |

워크로드별 유의사항:

- **W1**은 프리로드(D-2)가 반드시 선행돼야 100% hit이 나온다.
- **W2/W3/W4**는 SET이 섞이므로 **`--key-pattern=R:R`이 기존 키를 덮어쓴다.**
  keyspace 크기는 유지되고 `curr_items`도 1,000,000에서 크게 변하지 않는다.
  GET이 섞인 W3/W4는 hit율이 100%로 유지되는 것이 정상이다.
- SET 경로는 GET과 달리 **STORED 응답 전에 WRITE CQE를 기다린다.** 따라서
  SET 비중이 높을수록 throughput이 낮고 span(write)이 별도로 잡힌다.
- 워크로드를 바꿔 연속 측정할 때 **프리로드를 다시 할 필요는 없다**(서버를
  재시작하지 않는 한). 서버를 재시작했다면 D-2부터.

### E-2. [ariel-guest] 부하 유입 확인

```sh
a=$(printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT (cmd_get|cmd_set) /{s+=$3}END{print s}')
sleep 3
b=$(printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT (cmd_get|cmd_set) /{s+=$3}END{print s}')
echo "현재 부하: $(( (b-a)/3 )) ops/s"
# => 수백만 이상이면 정상. 0이면 genie 명령이 안 돌고 있는 것.
```

### E-3. [ariel-guest] 창 열고 실시간 관측 — **이 한 줄이 측정 전체다**

```sh
DUR=300 bash /tmp/obwatch.sh
```

`stats reset`으로 창을 열고, 1초마다 실시간 지표를 찍고, 300초 뒤 최종
요약까지 출력한다. 별도 계산 단계(구 F-1) 없이 이것으로 끝난다.

```text
extstore watch — window 300s, opened 02:10:14Z

     t       get/s       set/s     hit%   span_avg   span_p50   span_p99 wait_enq/s   err
------ ----------- ----------- -------- ---------- ---------- ---------- --------- -----
    1s    10.229M     0.000M   100.00    23.90us    22.10us     54.9us    31.2M     0
    2s    10.231M     0.000M   100.00    23.90us    22.10us     54.8us    31.1M     0
    ...

===== SERVER STATS (300s window) =====
Type             Ops/sec      Hits/sec     Span Avg     Span p50     Span p99
------------------------------------------------------------------------------------
Gets       10229000.00   10229000.00     23.900us     22.100us     54.900us
Totals     10229000.00   10229000.00

gate span avg < 30us         PASS  (23.90us, 여유 6.10us)
hit rate                     100.00 %

--- correctness (전부 0이어야 정상) ---
get_misses=0 badcrc=0 read_fail=0 write_fail=0 engine_dead=0 leak=0
read span 표본 커버리지 : +0.0007%  OK
   (양수=리셋 경계 누락, 음수=재시도로 표본 증가 — 혼합 워크로드에서 정상)
```

간격을 바꾸려면 `DUR=60 INT=5 bash /tmp/obwatch.sh`.

> 관측 비용은 초당 `stats` 1회 — 10M ops/s 대비 1e-7 수준이라 성능에 영향이
> 없다. 기록 런들도 모두 동일한 1초 샘플러를 켠 채 측정했다.

### E-4. [genie] 부하 종료 확인

memtier 요약의 `Gets`/`Sets` 행 ops/s, `Hits`/`Misses`를 기록해 ariel 수치와
대조한다.

---

## Phase F — 결과 판정

E-3 출력이 곧 판정 자료다. 아래 기준으로 읽는다.

### F-1. 합격 기준

| 항목 | 기준 | 비고 |
|---|---|---|
| gate | `span avg < 30us` **PASS** | 계약. GET이 있는 워크로드에만 적용 |
| correctness 필수 5종 | 전부 0 | `get_misses`/`read_fail`/`write_fail`/`engine_dead`/`leak`. 하나라도 0이 아니면 **성능 수치 무효** |
| `badcrc_from_extstore` | GET-only(W1): **0**<br>혼합(W3/W4): **0이 아닐 수 있음** | 아래 근거 참조 |
| span 표본 커버리지 | `OK` | 아래 근거 참조. 범위 밖이면 계측 이상 |
| hit rate | W1/W3/W4에서 100.00% | 아니면 `--key-prefix` 불일치 |
| 계기 일치 | genie 대비 0.01~0.5% | 1% 이상 벌어지면 창 어긋남 |

> **span 표본 커버리지가 정확히 0이 아닌 것은 정상이다.** obwatch가
> `extstore_prof_read_count`를 `cmd_get`과 대조해 출력하며, 허용 범위는
> **−1.0% ~ +0.2%**다. 두 방향 모두 원인이 규명돼 있다:
> - **+방향(prof가 작음)**: `stats reset`이 `threadlocal_stats_reset()`(=`cmd_get`)을
>   먼저, `storage_prof_reset()`을 나중에 호출하므로 그 사이 완료된 op가
>   `cmd_get`에만 잡힌다. 부하 중 워커 28개를 순회하는 수십 ms에 해당
>   (실측 예: 641,923건 = 9.9M ops/s에서 65 ms).
> - **−방향(prof가 큼)**: 혼합 워크로드에서 transient visibility 재시도가
>   일어나면 시도마다 표본이 남는다(실측 +0.045%).
>
> 따라서 **정확히 일치해야 한다는 조건으로 읽으면 안 된다.** 서버를 멈춘
> 상태이거나 리셋 없이 누적 측정할 때만 일치한다. 상세는
> `md/SPAN_MEASUREMENT_REVIEW.md` §3, §5.

> **혼합 워크로드의 `badcrc`는 결함이 아니다.** 같은 키를 한쪽이 읽는 동안
> 다른 쪽이 SET하면 원격 슬롯이 갱신 중인 상태로 읽혀 GCM 태그가 어긋난다.
> 엔진은 이를 transient visibility 실패로 보고 **재시도**하며, 검증되지 않은
> 데이터는 절대 전달하지 않는다. 판정 기준은 **`get_misses = 0`** 이다 —
> 0이면 모든 실패가 재시도로 복구돼 클라이언트는 정상 응답만 받은 것이다.
> (실측 예: 1:1 혼합에서 badcrc 18,555 = GET의 0.21%, `get_misses` 0,
> read span 표본 +0.63% — 재시도분.)
> **GET-only에서 badcrc가 0이 아니면 그건 진짜 이상이다** — 경합 상대가 없다.

### F-2. 워크로드별 기대치 (참고)

실측(2026-07-29, 동일 bed, mc28/W24/nqp2/hp22, `-t28 -c4 -p160`):

| 워크로드 | 총 ops/s | GET span | SET span | 비고 |
|---|---:|---:|---:|---|
| W1 GET only | **10.12~10.25 M** | 25.4 µs | — | 게이트 PASS |
| W2 SET only | **0.311 M** | — | 5.38 µs | GET의 **1/33** |
| W4 1:1 | **0.591 M** (GET 0.296 + SET 0.296) | 26.0 µs | 5.61 µs | badcrc 0.21%, 재시도 복구 |

**SET이 33배 느린 것은 RDMA 때문이 아니다.** SET span은 5.38 µs로 오히려
GET span(25.4 µs)보다 짧다. 원인은 **SET이 워커를 동기 점유**하는 구조다:
`storage_store_item()`이 `while (!wait.done) { extstore_worker_drain(...); }`로
자기 WRITE CQE가 올 때까지 busy-wait하므로(`storage.c:644-647`), 워커당 SET
동시성은 **1**이다. GET은 비동기라 워커당 W=24개가 동시에 뜬다.

**혼합에서 GET까지 느려지는 것도 같은 원인이다.** SET이 워커를 잡고 있는
동안 그 워커의 큐에 있는 GET들이 head-of-line blocking을 당한다. 워커 시간
모델로 검증된다:

```text
SET당 워커 점유  90.1 µs   (span 5.38 µs = 6%, 나머지는 동기 대기 + 프로토콜)
GET당 워커 점유   2.77 µs   (비동기라 W=24 동시 처리)
1:1 쌍당          92.9 µs → 28 worker 기준 0.603 M ops/s 예측
실측                              0.591 M ops/s   (오차 −2.0%)
```

즉 혼합 처리량은 **SET 비중이 결정**한다. 1:9면 SET 하나당 GET 9개가
붙으므로 쌍 비용이 `90.1 + 9×2.77 = 115 µs`, 10 ops → 약 2.4 M ops/s가
예상 범위다.

> SET 경로는 이번 캠페인의 최적화 대상이 **아니었다.** 10M/30 µs 계약은
> GET-only 기준이며, 위 SET/혼합 수치는 기준선 기록이지 게이트 판정 대상이
> 아니다. SET을 개선하려면 동기 대기를 GET처럼 비동기 재개 구조로 바꾸는
> 것이 출발점이고, 그 경우 `STORED`의 내구성 의미(WRITE CQE 확인 후 응답)를
> 유지할 수 있는지가 설계 쟁점이다.

> SET 계열은 이번 캠페인에서 **최적화 대상이 아니었다.** 10M/30µs 계약은
> GET-only 기준이며, W2~W4 수치는 기준선 기록용이지 게이트 판정 대상이 아니다.

### F-3. [genie] 메모리 노드 CPU가 0인지 확인 (선택, 아키텍처 검증)

**E-1 직전에 한 번, E-4 직후에 한 번** 실행해 두 값이 완전히 같아야 한다.
한 번만 재면 비교 대상이 없어 의미가 없다.

```sh
# E-1 직전
awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat > /tmp/gm_before
# E-4 직후
awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat > /tmp/gm_after
diff /tmp/gm_before /tmp/gm_after && echo "genie CPU = 0 (one-sided READ 확인)"
```

> W2~W4처럼 SET이 섞여도 결과는 같아야 한다 — WRITE도 one-sided이므로
> genie CPU를 쓰지 않는다.

---

## Phase G — 정리

```sh
# [ariel-guest] 서버만 내림 (genie 측은 그대로 두는 것이 권장 휴지 상태)
tmux kill-session -t mc
for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done

# [ariel-host] guest까지 내리려면
sudo ~/2026/sev/guestctl.sh down
```

`genie_memd`와 opensm 4K 설정은 켜둔 채로 두는 것이 정상 휴지 상태다 —
CPU를 쓰지 않고, 다음 시행에서 조율 없이 바로 연결된다.

---

## 부록: 증상별 원인

| 증상 | 원인 / 조치 |
|---|---|
| `ping 10.99.0.2` 실패 | genie 재부팅됨 → Phase A-2 |
| `ibp1s0` MTU가 2044로 되돌아감 | genie opensm의 4K group 없음 → A-2 |
| `create_cq failed: Invalid argument` | stock mlx5_ib가 로드됨 → C-1 재실행 (꼬이면 guest 재부팅이 가장 빠름) |
| `reg_mr ... Input/output error` | 이전 memcached 유령이 snp_shared 점유 → `pgrep -x "memcached[.a-z]*"` 로 전부 kill |
| `Address already in use` | 위와 동일. `-x memcached`만으로는 `.pft/.xpf` 변종이 안 잡힌다 |
| hit rate 0% | `--key-prefix=m-` 불일치 (memtier 기본값은 `memtier-`) |
| `.ko: No such file or directory` + `Cannot find device "ibp1s0"` | **호스트에서 실행 중이다.** 프롬프트가 `seonung@ariel`이면 guest가 아니다 → C-0으로 접속 후 재실행. (호스트에 IB 디바이스가 없고 HCA가 `vfio-pci`에 묶여 있는 것은 정상 — guest에 인계된 상태다) |
| `Failed to prepare storage workers` | genie_memd 미기동 → Phase A. **SSH를 끊었다면 `&`로만 띄운 genie_memd가 SIGHUP으로 죽었을 가능성** — `nohup`/`setsid`로 재기동 |
| throughput 약 7% 낮음 (≈9.7~9.9M) | **prefetch 없는 구버전 바이너리** → D-0으로 확인·교체 |
| throughput 2~3% 낮음 | bed 드리프트 — fresh boot 후 재시행 |
| span > 30 µs | W 값 확인(24여야 함), guest 재시작 누적 여부 확인 |
| badcrc가 cmd_get과 같음 | DMA sync가 꺼짐 — `EXT_SKIP_DMA_SYNC`를 절대 설정하지 말 것 |

## 부록: 자동화 경로

반복 측정·A/B가 필요하면 수동 대신 `tools/`의 하네스를 쓴다.

```text
tools/obwatch.sh  창 열기 + 실시간 관측 + 최종 요약 (수동 측정의 기본 도구)
tools/obup.sh     기동 + 프리로드 + 1초 샘플러
tools/obslice.sh  UTC 창 절단 (genie가 보고한 창을 그대로 입력)
tools/obsweep.sh  구성 사다리 (mcT:nqp:W 튜플, 부하 감지로 자동 진행)
tools/obalt.sh    바이너리 교대 A/B
```

측정 규율(절대값은 fresh boot, 델타는 교대 A/B, 판정은 60초×3 + 300초 지속)은
`md/OPTIMAL_RUNBOOK.md` §7 참조.
