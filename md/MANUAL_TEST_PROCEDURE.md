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
./genie_memd 11212 4g --prefill &
sleep 2; pgrep -a genie_memd                   # => 프로세스 확인
```

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
# SSH가 열릴 때까지 대기
until ssh -i ~/.ssh/snp_guest -p 2222 -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=no ubuntu@localhost true 2>/dev/null; do sleep 5; done
echo "guest up"
```

> **절대값을 주장할 측정이면 fresh boot에서 하라.** 재시작이 누적된 guest는
> 같은 구성에서도 2~3% 낮게 나온다(문서화된 bed 드리프트).

---

## Phase C — [ariel-guest] 모듈·네트워크 bringup

부팅 직후 1회만. 이미 완료된 guest면 C-2 확인만 하고 넘어간다.

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

## Phase E — 측정 (양측 협조, 6분)

부하는 genie가 **360초** 돌리고, ariel이 그 안쪽에 **300초 창**을 잡는다.
이렇게 하면 사람이 시각을 정밀하게 맞출 필요가 없다.

### E-1. [genie] 부하 시작 — 먼저 실행

```sh
memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text \
  --ratio=0:1 -d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --key-pattern=R:R --distinct-client-seed --hide-histogram \
  -t 28 -c 4 --pipeline=160 --test-time=360
```

이 명령은 360초간 블록되며 끝나면 요약표를 출력한다. 그대로 두고 **즉시**
E-2로 이동.

### E-2. [ariel-guest] 부하 유입 확인 (약 10초)

```sh
a=$(printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
sleep 3
b=$(printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
echo "현재 부하: $(( (b-a)/3 )) ops/s"
# => 9000000 이상이면 정상. 0이면 genie 명령이 안 돌고 있는 것.
```

### E-3. [ariel-guest] 300초 창 측정 — 이 한 덩어리를 그대로 붙여넣는다

```sh
printf 'stats reset\r\nquit\r\n' | nc 127.0.0.1 11411 >/dev/null
T0=$(date -u +%s); echo "창 시작 $(date -u +%H:%M:%SZ) — 300초 대기"
sleep 300
T1=$(date -u +%s)
printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' > /tmp/result.txt
echo "창 종료 $(date -u +%H:%M:%SZ), 경과 $((T1-T0))초"
```

`stats reset`은 `cmd_get`과 span 히스토그램을 함께 리셋한다(코드 확인:
`stats_reset() → storage_prof_reset()`). 따라서 `/tmp/result.txt`는 **이
300초 창만의 값**이다. `curr_items`(프리로드)는 리셋되지 않는다.

### E-4. [genie] 부하 종료 확인

360초가 지나면 memtier가 요약을 출력한다. `Gets` 행의 ops/s와 `Hits`/`Misses`
를 기록해 둘 것 — ariel 측 수치와 대조한다.

---

## Phase F — [ariel-guest] 결과 검증

### F-1. 계산

```sh
awk -v t=$((T1-T0)) '
/^STAT cmd_get /              {g=$3}
/^STAT get_hits /             {h=$3}
/^STAT get_misses /           {m=$3}
/^STAT badcrc_from_extstore / {b=$3}
/^STAT extstore_read_failures / {rf=$3}
/^STAT extstore_write_failures /{wf=$3}
/^STAT extstore_engine_dead /  {ed=$3}
/^STAT ext_slot_acct_leak /    {lk=$3}
/read_avg_ns /                {ra=$3}
/read_p99_ns /                {rp=$3}
/extstore_prof_read_count /   {pc=$3}
END{
  printf "\n===== 결과 (%d초 창) =====\n", t
  printf "throughput   %.3f M ops/s\n", g/t/1e6
  printf "span avg     %.2f us   %s\n", ra/1000, (ra/1000<30?"PASS":"*** FAIL (게이트 30us) ***")
  printf "span p99     %.1f us\n", rp/1000
  printf "hit rate     %.2f %%\n", (g>0)?h/g*100:0
  printf "\n--- 정합성 (전부 0이어야 정상) ---\n"
  printf "get_misses=%d badcrc=%d read_fail=%d write_fail=%d engine_dead=%d leak=%d\n", m,b,rf,wf,ed,lk
  printf "prof_read_count == cmd_get : %s (%d vs %d)\n", (pc==g?"OK":"*** MISMATCH ***"), pc, g
}' /tmp/result.txt
```

### F-2. 합격 기준

| 항목 | 기준 | 비고 |
|---|---|---|
| throughput | **≥ 10.0 M ops/s** | fresh boot에서 10.0~10.4 기대 |
| span avg | **< 30 µs** | 계약 게이트. W=24에서 23.5~26.7 기대 |
| hit rate | 100.00% | 아니면 `--key-prefix` 불일치 |
| 정합성 6종 | 전부 0 | 하나라도 0이 아니면 **성능 수치 무효** |
| prof_read_count | `== cmd_get` | 모든 GET이 remote READ를 거쳤다는 증거 |

### F-3. genie 수치와 대조

```text
ariel(서버) 수치와 genie(client) 수치는 0.01~0.5% 안에서 일치해야 한다.
1% 이상 벌어지면 창이 어긋난 것 — E-3의 300초가 genie의 360초 안에 온전히
들어갔는지 확인할 것.
```

### F-4. [genie] 메모리 노드 CPU가 0인지 확인 (선택, 아키텍처 검증)

E-1 직전과 E-4 직후에 각각 실행해 값이 **동일**해야 한다.

```sh
awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat
# => 두 시점의 utime/stime이 완전히 같아야 정상 (one-sided READ = 호스트 CPU 0)
```

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
| `Failed to prepare storage workers` | genie_memd 미기동 → Phase A |
| throughput 2~3% 낮음 | bed 드리프트 — fresh boot 후 재시행 |
| span > 30 µs | W 값 확인(24여야 함), guest 재시작 누적 여부 확인 |
| badcrc가 cmd_get과 같음 | DMA sync가 꺼짐 — `EXT_SKIP_DMA_SYNC`를 절대 설정하지 말 것 |

## 부록: 자동화 경로

반복 측정·A/B가 필요하면 수동 대신 `tools/`의 하네스를 쓴다.

```text
tools/obup.sh     기동 + 프리로드 + 1초 샘플러
tools/obslice.sh  UTC 창 절단 (genie가 보고한 창을 그대로 입력)
tools/obsweep.sh  구성 사다리 (mcT:nqp:W 튜플, 부하 감지로 자동 진행)
tools/obalt.sh    바이너리 교대 A/B
```

측정 규율(절대값은 fresh boot, 델타는 교대 A/B, 판정은 60초×3 + 300초 지속)은
`md/OPTIMAL_RUNBOOK.md` §7 참조.
