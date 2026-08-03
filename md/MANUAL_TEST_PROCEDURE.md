# 수동 실행 절차서 — optimal throughput test

사람이 두 박스에 직접 접속해 순차 실행하고 결과를 검증하기 위한 문서.
**모든 단계에 실행 위치가 명시돼 있다.** 참조용 배경은
`md/OPTIMAL_RUNBOOK.md`, v3→v4 구조 변화는 `md/V3_TO_V4_CHANGES.md`,
최적화 이력은 `md/OPTIMIZATION_HISTORY.md`.

> **2026-08-03 v4 운영값으로 갱신됨.** 서버 파라미터가 바뀌었다
> (`-t 30`, `taskset 0-29`, `nqp=4`, `reap=8`, `chain=8`, `submit_inline`),
> 부하는 `-t 30 --pipeline=256`, 기대치는 §F-2 다. 기동 게이트에
> **`ext_submit_inline` 판별이 추가**됐다 — stock 이나 옛 빌드가 포트를 쥐고
> 있어도 낡은 로그 때문에 통과처럼 보인 전례가 있다(§D-1).

```text
소요 시간   준비 10~15분 + 측정 6분
접속        [genie]  genie 박스 셸
            [ariel-host]  ariel 호스트 셸
            [ariel-guest] ssh -i ~/.ssh/snp_guest -p 2222 ubuntu@localhost
```

기호: 각 단계 제목의 `[...]`가 실행 위치다. `# =>` 는 기대 출력.

> ### 2026-07-31 — coherent MR 커널 패치 반영. 경로가 전부 바뀌었다.
>
> 이 절차서는 이제 **coherent data MR 빌드**를 기준으로 한다. `~/covlib`는
> 패치 이전 자산이고, 새 자산은 전부 `~/coherent-mr-v2/` 아래에 있다.
> 셋 중 하나라도 옛 경로를 쓰면 **패치 이전을 재게 된다** — 실제로 그 사고가
> 2026-07-30에 있었다.
>
> ```text
> 커널 모듈   ~/coherent-mr-v2/mlx5_ib.ko           (구: ~/covlib/mlx5_ib.ko)
> 사용자 lib  ~/coherent-mr-v2/lib                  (구: ~/covlib)
> 바이너리    ~/coherent-mr-v2/bin/memcached        (구: ~/kvs-port-v3/memcached)
> 대조군      ~/coherent-mr-v2/bin/memcached.pre-pac + EXT_DISABLE_COHERENT_MR=1
> ```
>
> 세 자산은 **한 벌로만 유효하다.** 새 lib는 `mlx5dv_alloc_coherent_mr`을
> 갖고, 새 모듈이 그 요청을 받으며, 새 바이너리가 그것을 호출한다. 섞으면
> 조용히 폴백해 sync 경로로 돌아간다(죽지 않으므로 로그로만 알 수 있다 — §D-1).

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

cd memcached-1.6.42-port_v4/genie-server
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
sudo rmmod mlx5_ib && sudo insmod ~/coherent-mr-v2/mlx5_ib.ko
sleep 3
sudo ip addr add 10.99.0.3/24 dev ibp1s0
sudo ip link set ibp1s0 up
sleep 2
sudo ip link set ibp1s0 mtu 4092
```

`rmmod`는 RDMA를 쓰는 프로세스가 하나도 없어야 성공한다. `Module ... is in
use`가 나오면 memcached·genie_memd가 남아 있는 것이다(§G로 먼저 정리).

### C-2. 확인

```sh
nproc                                  # => 30
lsmod | grep -E "^mlx5_ib|^snp_shared" # => 둘 다 로드됨
cat /sys/class/net/ibp1s0/mtu          # => 4092   (2044면 genie opensm 확인)
ping -c2 -W2 10.99.0.2                 # => 0% packet loss
```

`ping` 실패 시 원인은 대개 **genie 쪽**이다 — Phase A-2로 돌아갈 것.

### C-3. **coherent MR 확인** — 새 모듈이 실제로 올라갔는지

`lsmod`는 이름만 보므로 구·신 모듈을 구별하지 못한다. `modinfo`도 디스크의
파일을 읽을 뿐 적재된 것을 보지 않는다. **판별은 기능으로 한다.**

```sh
LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib $HOME/coherent-mr-v2/bin/coherent_mr_smoke
# => coherent MR OK addr=0x... length=2097152 lkey=0x...
```

실패하면 옛 모듈이 올라가 있거나 lib가 옛 것이다. **여기서 통과하지 못하면
이후 측정은 전부 패치 이전 경로다** — Phase C-1부터 다시 한다.

---

## Phase D — [ariel-guest] 서버 기동 + keyspace 프리로드

### D-0a. 관측 도구 배포 (최초 1회)

```sh
# ariel 호스트에서
scp -i ~/.ssh/snp_guest -P 2222 ~/2026/memcached-1.6.42-port_v4/tools/obwatch.sh ubuntu@localhost:/tmp/
```

### D-0. **바이너리 확인** — 최적 구성의 전제

측정 대상은 `~/coherent-mr-v2/bin/memcached`다. **파일 이름만으로는 무엇이
들어 있는지 알 수 없다** — 2026-07-30에 이것 때문에 두 번 사고가 났다.
한 번은 런북이 다른 경로를 띄워 동기 경로를 재고 "개선이 없다"는 결론이 날
뻔했고, 한 번은 배포본이 pac도 alloc 수정도 없는 구버전인 채로 12시간 돌았다.
**표지를 직접 확인하는 것 말고 안전한 방법이 없다.**

```sh
sha256sum ~/coherent-mr-v2/bin/memcached | cut -c1-24
# => b4c18e9710cc693c48531181     ★ v4 기록 바이너리 — §F-2 의 모든 수치를 낸 그것
```

> **sha 는 재빌드로 재현되지 않는다.** 같은 소스·같은 커밋에서 다시 빌드해도
> 툴체인이 다르면 다른 sha 가 나온다(실측: 같은 트리를 호스트에서 빌드하면
> `03554b68574c1b5cd0cdac68`). 그러므로 이 sha 는 **"기록치를 낸 바로 그
> 바이너리"의 신원**이지 빌드 검증용 체크섬이 아니다. 재배포했다면 새 sha 를
> 기록하고, 내용 검증은 아래 기능 게이트로 한다.

sha 가 다르고 새로 배포해야 하면 **v4 저장소 `main`** 에서 빌드한다.
v3 저장소나 옛 `v3-set-pac` 브랜치를 쓰지 말 것 — v4 의 노브
(`ext_submit_inline`, `ext_reap_every`, `ext_post_chain`)가 없다.

```sh
# ariel 호스트에서
cd ~/2026/memcached-1.6.42-port_v4 && git checkout main && make -j"$(nproc)"
scp -i ~/.ssh/snp_guest -P 2222 memcached ubuntu@localhost:/tmp/mc.new
# guest에서 (서버가 실행 중이면 "Text file busy" — 먼저 내릴 것)
install -m755 /tmp/mc.new ~/coherent-mr-v2/bin/memcached
sha256sum ~/coherent-mr-v2/bin/memcached | cut -c1-24   # 새 sha 를 기록해 둘 것
```

> v3 시대의 대조군 바이너리(`memcached.pre-pac` / `.precrypto` / `.premagscan`)
> 는 guest 에 남아 있으면 그대로 두어도 되지만 **v4 기준선이 아니다.**
> v4 의 유일한 무변수 A/B 는 §F-4 의 `EXT_DISABLE_COHERENT_MR=1` 이다.

> 🛑 **아래 `stats` 확인은 D-1 로 서버를 띄운 *다음*에 한다.** 여기 D-0 에
> 적혀 있는 것은 "무엇을 확인할지"의 목록이고, 실행 시점은 D-1 이후다.
> **위에서부터 순서대로 실행하면 서버가 없는 상태에서 `nc` 를 때리게 되고,
> 연결 거부는 조용해서 출력이 한 줄도 안 나온다** — 그 침묵은 "pac 없는
> 동기 바이너리"와 화면상 구별되지 않는다. 2026-08-03 에 이 함정을 밟았다.
>
> **판별법**: `cmd_set` 은 어떤 memcached 에도 있다. 아래에서 `cmd_set` 조차
> 안 나오면 그것은 바이너리 문제가 아니라 **서버가 안 떠 있는 것**이다.

D-1 기동 후 아래를 확인한다. **전부 통과해야 이 절차서가 유효하다.**

```sh
printf 'stats settings\r\nquit\r\n' | nc -q1 127.0.0.1 11411 | grep -E 'ext_pac_set|ext_seal_at_flush'
# => STAT ext_pac_set yes           (없으면 pac이 없는 동기 바이너리)
# => STAT ext_seal_at_flush no      (yes면 처리량이 3.15배 떨어진다 — 기각된 노브)
printf 'stats\r\nquit\r\n' | nc -q1 127.0.0.1 11411 | grep -E 'ext_setq_max|extstore_alloc_failures'
# => STAT ext_setq_max 1            (기본값. SET span < 30 µs를 위한 설정)
# => STAT extstore_alloc_failures 0 (항목 자체가 없으면 678e7a3 이전 빌드다)

# 부하를 조금 준 뒤 pac 경로가 실제로 타는지 (핵심 확인)
printf 'stats\r\nquit\r\n' | nc -q1 127.0.0.1 11411 | grep -E "cmd_set|ext_pac_posted|ext_pac_fallback"
# => ext_pac_fallback 0   ★ 이것이 판정 기준이다. 0 이면 전 건이 비동기 경로.
# => ext_pac_posted 는 0 보다 커야 한다 (0 이면 전부 동기 폴백)
```

> ⚠️ **`ext_pac_posted == cmd_set` 으로 판정하지 말 것.** 옛 문서에 그렇게
> 적혀 있었지만 틀렸다. `g_pac_posted`/`g_pac_fallback`(`storage.c:57,59`)은
> **기동 이후 누적이고 리셋되지 않는데**, `cmd_set` 은 `stats reset` 으로
> 0 이 된다(`memcached.c:211`). obwatch 는 창을 열 때마다 `stats reset` 을
> 하므로, 측정을 한 번이라도 돌린 뒤에는 `ext_pac_posted > cmd_set` 이 되는
> 것이 **정상**이다(실측: posted 593,039,296 vs cmd_set 552,699,145).
> 굳이 대조하려면 두 값 모두 차분을 쓰고, 평소 판정은 **`ext_pac_fallback = 0`**
> 하나로 한다.

`ext_setq_max`를 1보다 크게 두면 SET들이 한 이벤트루프 통과분으로 묶여
SYNC를 분할상환하지만 **span 계약이 깨진다**(batch=64에서 SET span 255 µs).
coherent MR에서는 SYNC 자체가 없으므로 배치할 이유도 없다. **1을 유지한다.**

> 참고: 옛 판별자 `grep -ac assoc_prefetch`는 **더 이상 쓰지 않는다.** 그
> 심볼은 GET prefetch용이라 동기 빌드와 pac 빌드가 양쪽 다 갖고 있어
> SET 경로를 전혀 구별하지 못한다.

### D-1. 서버 기동 (tmux — ssh 세션이 끊겨도 유지)

> ⚠️ **kill 직후 바로 기동하면 안 된다.** `kill -9` 뒤 30워커 + QP 120개
> (`workers × ext_qp_per_worker` = 30 × 4) +
> MR 해제가 끝나야 포트가 풀리는데, 그 전에 새 서버가 bind하면
> `failed to listen on TCP port 11411: Address already in use`로 **새 서버가
> 조용히 죽고**, 이후 측정은 옛 프로세스(또는 아무것도 없는 상태)를 잰다.
> 2026-07-30에 이 레이스로 GET 회귀를 오판할 뻔했다. 아래 대기 루프 필수.

```sh
tmux kill-session -t mc 2>/dev/null
for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done
pkill -f '^/tmp/mc_' 2>/dev/null   # stock 대조 등 스테이징 바이너리도 죽인다
: > /tmp/mc.log                    # 낡은 로그를 읽고 게이트를 오판한 전례가 있다
# 포트가 실제로 풀릴 때까지 대기 — 생략 금지
for i in $(seq 1 30); do ss -ltn | grep -q ':11411 ' || break; sleep 1; done
ss -ltn | grep -q ':11411 ' && { echo "포트가 아직 잡혀 있다"; ss -ltnp | grep 11411; }

tmux new-session -d -s mc "cd \$HOME/kvs-port && exec taskset -c 0-29 env \
LD_LIBRARY_PATH=\$HOME/coherent-mr-v2/lib:\$HOME/kvs-port \
MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1 EXT_SELFTEST=1 \
EXT_CRYPTO_KEY=\$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
\$HOME/coherent-mr-v2/bin/memcached -p 11411 -U 0 -t 30 -m 2048 -c 16384 -R 1024 \
-o ext_path=10.99.0.2:11212:4g,ext_worker_window=24,ext_qp_per_worker=4,ext_drain_spin=1024,hashpower=22,ext_submit_batch=20,ext_admit_max=64,ext_submit_inline,ext_reap_every=8,ext_post_chain=8,ext_setq_max=1 \
> /tmp/mc.log 2>&1"

sleep 8
pgrep -x "memcached[.a-z]*" >/dev/null && echo "server UP" || tail -5 /tmp/mc.log
# => "server UP"
grep -icE "coherent MR [0-9]+B" /tmp/mc.log
# => 2      ★ 이 줄이 이 절차서의 핵심 게이트다. 0이면 패치 이전 경로다.
grep -iE "genie_connect OK|coherent MR|selftest|Address already in use|reg_mr" /tmp/mc.log

# 로그는 낡을 수 있다 — 지금 떠 있는 프로세스를 직접 본다 (권위 있는 확인)
pid=$(pgrep -x "memcached[.a-z]*")
tr '\0' '\n' < /proc/$pid/environ | grep -E 'EXT_DISABLE_COHERENT_MR|LD_LIBRARY_PATH'
# => LD_LIBRARY_PATH=/home/ubuntu/coherent-mr-v2/lib:...
# => EXT_DISABLE_COHERENT_MR 은 나오지 않아야 한다 (나오면 대조군이 떠 있는 것)

# 떠 있는 것이 v4 포트인지 판별한다 — stock 에는 이 설정이 없다
printf 'stats settings\r\nquit\r\n' | nc -q1 127.0.0.1 11411 | grep -c ext_submit_inline
# => 1      ★ 0 이면 stock 이나 옛 빌드가 포트를 쥐고 있다
```

> **로그 파일 이름만 믿지 말 것.** 2026-07-31에 이 함정을 밟았다 — A/B
> 스크립트가 다른 로그로 출력하는 바람에 `~/mc.log`는 그 전 기동의 것이었고,
> 그것만 보면 coherent 2줄이 멀쩡히 보이는데 **실제로 떠 있는 서버는 폴백
> 구성**이었다. `/proc/$pid/environ`은 낡을 수 없다.

기대 출력:

```text
extstore: genie_connect OK (raddr=0x... rkey=0x... size=4294967296, workers=30 ...)
extstore: coherent MR 458752B at 0x...          ← READ 바운스 풀
extstore: coherent MR 236544B at 0x...          ← WRITE staging 풀
extstore selftest: SYNC_FOR_DEVICE advise failed: No such file or directory
extstore selftest: SYNC_FOR_CPU advise failed: No such file or directory
extstore selftest: OK (256 bytes written and read back)
```

> **selftest의 advise 실패 두 줄은 정상이며, 오히려 통과 신호다.** coherent
> MR에는 umem이 없어 advise 핸들러가 ENOENT를 낸다. 그런데 바로 다음 줄에서
> 페이로드가 왕복한다 — **sync 없이 데이터가 옳다**는 것이 이 패치의 요점이다.
> (데이터 경로는 아예 advise를 호출하지 않는다. 이 메시지는 selftest만의 것이다.)

문제 신호:

```text
"coherent MR" 줄이 0개      → lib 또는 모듈이 옛 것이다. C-3 smoke부터 다시.
"Address already in use"    → 위 대기 루프를 건너뛴 것. 처음부터 다시.
"reg_mr(...) failed"        → SWIOTLB 파편화. 서버 중복 기동이 없는지 확인하고,
                              계속되면 Phase C(모듈 재적재)부터 다시 한다.
```

**두 풀이 다 coherent여야 한다.** 458752B(READ)만 잡히고 236544B(WRITE)가
없으면 GET만 패치 이득을 받고 SET은 여전히 sync를 낸다 — 혼합 판정이 어긋난다.

### D-2. 프리로드 (1M × 64 B) — **`--key-prefix=m-` 필수**

```sh
LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-29 \
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
  -t 30 -c 4 --pipeline=256"
```

> **`--distinct-client-seed`는 지우지 말 것.** memtier 기본값은 클라이언트
> 전체가 *같은 고정 시드*를 쓰는 것이라, 이 플래그가 없으면 120개 커넥션이
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
| **W1** | GET only | `memtier_benchmark $COMMON --ratio=0:1 --test-time=100` | 기준 — optimal 운영점 |
| **W2** | SET only | `memtier_benchmark $COMMON --ratio=1:0 --test-time=100` | remote WRITE 경로. seal→WRITE→CQE→STORED |
| **W3** | SET:GET **1:9** | `memtier_benchmark $COMMON --ratio=1:9 --test-time=100` | **게이트 대상 혼합 (v4 실측 비율)** |
| **W4** | SET:GET 1:1 | `memtier_benchmark $COMMON --ratio=1:1 --test-time=100` | 쓰기 비중 상한 확인 (게이트 아님) |

> **비율 주의 — 계약 문구는 `1:10`, v4 실측은 전부 `1:9` 다.**
> `1:9` 는 SET 10%, `1:10` 은 9.09% 라 **`1:9` 가 더 무거운 쪽**이므로 계약을
> 보수적으로 만족한다(비율 차이 약 1.4%). 위 표를 `1:9` 로 둔 것은 §F-2 의
> 기록치와 같은 조건에서 재기 위해서다. **1:10 수치를 주장하려면 그 비율로
> 다시 재고, 두 비율을 섞어 인용하지 말 것.**

워크로드별 유의사항:

- **W1**은 프리로드(D-2)가 반드시 선행돼야 100% hit이 나온다.
- **W2/W3/W4**는 SET이 섞이므로 **`--key-pattern=R:R`이 기존 키를 덮어쓴다.**
  keyspace 크기는 유지되고 `curr_items`도 1,000,000에서 크게 변하지 않는다.
  GET이 섞인 W3/W4는 hit율이 100%로 유지되는 것이 정상이다.
- SET은 **`STORED` 응답 전에 WRITE CQE를 기다린다** — 내구성 의미를 지키기
  위해서다. 다만 pac 이후 **워커가 블록되지는 않는다**: 스텁은 커맨드 시점에
  게시되고 연결만 suspend됐다가 완료 콜백에서 재개된다. 그래서 SET 비중이
  높아도 워커 직렬화로 무너지지 않는다(v3 실측 SET-only 0.311 M → 2.348 M.
  **v4 에서는 SET-only 를 재지 않았다** — §F-2).
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
DUR=60 bash /tmp/obwatch.sh
```

`stats reset`으로 창을 열고, 1초마다 실시간 지표를 찍고, `DUR`초 뒤 최종
요약까지 출력한다(빠른 확인 60, 정식 판정 300). 별도 계산 단계(구 F-1)
없이 이것으로 끝난다.

```text
extstore watch — window 300s, opened 02:10:14Z

     t       get/s       set/s     hit%   span_avg   span_p50   span_p99 wait_enq/s   err
------ ----------- ----------- -------- ---------- ---------- ---------- --------- -----
    1s    13.40M      0.000M   100.00    21.90us    20.1us      52.0us     0.0M     0
    2s    13.39M      0.000M   100.00    21.91us    20.1us      52.1us     0.0M     0
    ...

===== SERVER STATS (300s window) =====
Type             Ops/sec      Hits/sec     Span Avg     Span p50     Span p99
------------------------------------------------------------------------------------
Gets       13397000.00   13397000.00     21.900us     20.100us     52.000us
Totals     13397000.00   13397000.00

gate span avg < 30us         PASS  (21.90us, 여유 8.10us)
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

> **2026-07-30 판정 기준 변경 — 이전 기록을 그대로 읽지 말 것.**
> 1. 게이트는 **GET-only(W1)와 혼합(W3) 둘 다** 충족해야 한다(각 10 M ops/s,
>    span < 30 µs). 예전 문서의 "GET-only 기준이며 W2~W4는 게이트 대상이
>    아니다"는 **폐기**됐다. 계약 문구의 비율은 `1:10` 이지만 **v4 실측은
>    전부 `1:9`**(더 무거운 쪽)이다 — §E-1 주석 참조.
> 2. **SET span도 30 µs 미만이어야 한다.** obwatch의 `gate` 줄은 GET span만
>    보므로, SET이 있는 워크로드에서는 `Sspan avg` 열을 직접 확인할 것.
> 3. **span < 30 µs가 10 M ops/s보다 우선한다.** 둘이 상충하면 span을 지킨다.
>    **v4 의 조절 손잡이는 `ext_post_chain`(→ admit)과 `ext_reap_every`(→ v2)
>    다** — 둘 다 낮추면 span 이 내려가고 처리량을 조금 낸다
>    (`V4_RESULT.md` §14-1). `ext_setq_max` 는 1 고정이고 손잡이가 아니다.

| 항목 | 기준 | 비고 |
|---|---|---|
| **coherent MR 풀** | 기동 로그에 `coherent MR` **2줄** | 전제 조건. 0이면 패치 이전을 잰 것이라 **수치 무효** (§D-1) |
| **`*_sync_avg_ns`** | GET·SET 모두 **< 0.1 µs** | 패치가 실제로 먹었다는 사후 증거 (§F-4) |
| gate (GET span) | `span avg < 30us` **PASS** | obwatch가 자동 판정 |
| **SET span** | `Sspan avg < 30 µs` | **obwatch가 판정해 주지 않는다.** 표에서 직접 읽을 것. v4 운영값에서 **~9.1 µs** |
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
>   (실측 예: 641,923건 = 9.9M ops/s에서 65 ms. 당시 워커 28, 현재 30).
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

**v4 최종 게이트** (2026-08-03, 각 120 초, `mcT30/W24/nqp4/reap8/chain8`):

| 워크로드 | 총 ops/s | GET span | SET span | 판정 |
|---|---:|---:|---:|---|
| GET only (`--ratio=0:1`) | **13.397 M** | 21.90 µs | — | 두 게이트 PASS |
| 1:9 혼합 (`--ratio=1:9`) | **11.099 M** | 22.31 µs | 9.11 µs | 두 게이트 PASS |
| SET only (`--ratio=1:0`) | v4 미측정 | — | — | — |

**재현성**: 처리량 σ 약 1.0%, span σ 0.60%. **2% 보다 작은 델타는 한 셀로
판정할 수 없다** — 개선을 주장하려면 반복하라.

**비율 주의**: 위 혼합은 `1:9`(SET 10%)다. 계약 문구는 `1:10`(SET 9.09%)이고
그쪽이 더 쉽다. 두 비율의 수치를 섞어 인용하지 말 것.

참고로 **v3 정본**(빌드 `span-1f3390a`, coherent MR 이전, mc28/W24/nqp2)은
GET-only 10.241 M / 24.49 µs, 1:9 혼합 8.035 M / 24.46 / 19.34 였다.
v4 는 그 대비 혼합 **+38%**, GET span **−9%** 다.

> **아래는 coherent MR 도입 *전* 의 기대치다. 실측으로 답이 나왔으므로
> 이력으로만 읽을 것** — 위 F-2 표가 현행이다.

**coherent MR에 기대했던 것.** 게스트 내 co-located A/B(100 K 키 20초,
mtT=4/mcT=28, **절대값 무의미·델타만**)에서:

| | GET span | SET span | GET sync | SET sync |
|---|---:|---:|---:|---:|
| coherent | **13.2 µs** | **8.6 µs** | 0.04 µs | 0.01 µs |
| 폴백(패치 이전) | 19.5 µs | 12.0 µs | 5.62 µs | 1.99 µs |

span −27~32%, sync는 계측 하한까지. 같은 시험에서 **처리량은 ±노이즈로
움직이지 않았는데, co-located에서는 memtier가 같은 28코어를 놓고 경쟁해
약 3 M ops/s가 클라이언트 쪽 상한이기 때문이다** — 서버가 아낀 CPU가 갈 곳이
없다. **아낀 CPU가 처리량으로 환산되는지는 이 off-box 측정만이 답한다.**
그것이 이번 측정의 목적이다.

CPU 모델 예측은 SET에서 −1.74 µs/op이고, 이는 1:10을 9.46~10.03 M에 놓았다
— **경계선이라고 봤다. 실측은 11.099 M 로 그 위였다.** 다만 co-located에서 span 감소분이 sync 감소분보다 컸다
(GET −6.25 vs −5.58, SET −3.47 vs −1.98). 바운스가 사라지면 전송 자체도
짧아지는데 이 몫은 모델에 없다. 실측이 예측을 웃돌 여지가 여기 있다.

> **pac 이전 기록은 폐기됐다.** 2026-07-29 표(SET-only 0.311 M, "SET이 워커를
> 동기 점유해 워커당 동시성 1")는 pac 도입 전 구조를 설명한 것이다. pac이
> 그 동기 점유를 없앴고 SET-only는 0.311 M → 2.348 M(7.6배)이 됐다. 옛 표를
> 기준선으로 읽지 말 것.

> **"SET은 게이트 대상이 아니다"라는 옛 단서도 폐기됐다.** 현재 계약은
> GET-only와 1:10 혼합 **양쪽** 10 M이고 **SET span도 30 µs 미만**이다.
> 이 문서 안에 그 취지의 문장이 남아 있으면 §F-1 배너가 우선한다.

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

### F-4. span 내역 분해 — 패치가 먹었는지 사후 확인

obwatch는 span 총합만 본다. **sync 성분이 실제로 사라졌는지**는 `stats`의
`extstore_prof_*`에서 직접 읽는다. 이것이 §F-1의 전제 조건을 사후 검증한다.

```sh
printf 'stats\r\nquit\r\n' | nc 127.0.0.1 11411 | tr -d '\r' \
  | grep -E '^STAT extstore_prof_'
```

```text
── span v3 (계약이 쓰는 것) ─────────────────────────────
extstore_prof_read_e2e_avg_ns     ★ Gv3.  진입 → 복호 완료
extstore_prof_read_admit_avg_ns   ★ adm.  진입 → post
extstore_prof_write_e2e_avg_ns    ★ Sv3.  진입 → WFLIGHT 해제
extstore_prof_write_admit_avg_ns  ★ / _ret_avg_ns  ★ ret ← v4 가 고친 구간
── 전제 조건 사후 검증 ──────────────────────────────────
extstore_prof_read_sync_avg_ns    < 100      ← coherent면 계측 하한(수십 ns)
extstore_prof_write_sync_avg_ns   < 100      ← 수천 ns면 폴백 경로다
extstore_prof_read_xfer_avg_ns               ← 실제 RDMA 왕복
extstore_prof_read_crypto_avg_ns             ← AES-GCM, 사실상 하한(~1 µs)

`_avg_ns`(v2, post 시작)와 `_e2e_avg_ns`(v3, 진입 시작)를 혼동하지 말 것.
게이트는 후자다.
```

> **`*_avg_ns`는 기동 이후 누적 평균이다.** 프리로드 구간이 섞여 들어가므로
> 측정 창만 보려면 `(avg × count)`의 차분을 쓴다. `read_*`는 모두
> `extstore_prof_read_count`를, `write_*`는 `extstore_prof_write_count`를
> 짝으로 쓴다(성분별 count는 없다).
>
> ```text
> 구간 평균 = (avg₂×count₂ − avg₁×count₁) / (count₂ − count₁)
> ```

#### 패치 전후 A/B를 직접 뜨려면

같은 바이너리로 대조군을 만들 수 있다. **환경변수 하나만 추가**하면
`dma_alloc` + `ibv_reg_mr` + sync advise, 즉 패치 이전 경로로 되돌아간다.

```sh
# §D-1의 tmux 줄에서 EXT_RDMA_PROF=1 옆에 추가
EXT_DISABLE_COHERENT_MR=1
# => 기동 로그에 "coherent MR" 줄이 0개가 되고, *_sync_avg_ns가 수천 ns로 돌아온다
```

바이너리·커널·lib를 그대로 두고 경로만 바꾸므로 **다른 변수가 섞이지 않는
유일한 A/B다.** 모듈을 되돌려 비교하지 말 것 — 재적재 사이에 SWIOTLB 상태와
QP 배치가 바뀌어 델타가 오염된다.

---

## Phase G — 정리

```sh
# [ariel-guest] 서버만 내림 (genie 측은 그대로 두는 것이 권장 휴지 상태)
tmux kill-session -t mc
for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done
pkill -f '^/tmp/mc_' 2>/dev/null   # stock 대조 등 스테이징 바이너리도 죽인다
: > /tmp/mc.log                    # 낡은 로그를 읽고 게이트를 오판한 전례가 있다

# [ariel-host] guest까지 내리려면
sudo ~/2026/sev/guestctl.sh down
```

`genie_memd`와 opensm 4K 설정은 켜둔 채로 두는 것이 정상 휴지 상태다 —
CPU를 쓰지 않고, 다음 시행에서 조율 없이 바로 연결된다.

---

## 부록: 증상별 원인

| 증상 | 원인 / 조치 |
|---|---|
| `stats` grep 이 **한 줄도** 안 나옴 (`cmd_set` 조차) | **서버가 안 떠 있다.** `nc` 연결 거부는 조용하다 — "pac 없는 바이너리"로 오독하기 쉽다. `pgrep -x "memcached[.a-z]*"` 로 먼저 확인 (§D-0 배너) |
| `ext_pac_posted` 가 `cmd_set` 보다 큼 | **정상.** pac 카운터는 리셋되지 않고 `cmd_set` 은 `stats reset` 으로 0 이 된다. 판정은 `ext_pac_fallback = 0` 으로 (§D-0) |
| guest 에 `ibp1s0` 없음 / `ibv_devinfo` 가 `No IB devices found` | HCA 가 guest 에 안 넘어온 것. `guestctl.sh down` 은 NIC 를 호스트 `mlx5_core` 로 되돌린다 — 호스트에서 `lspci -nnk` 로 `c1:00.0` 의 드라이버를 확인하고, `mlx5_core` 면 guest 를 내렸다 다시 올린다(§B) |
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
| badcrc가 cmd_get과 같음 | DMA sync가 꺼짐 — `EXT_SKIP_DMA_SYNC`를 절대 설정하지 말 것. **바운스 MR에서 sync만 빼면 100 % 손상된다**(실측 100,000/100,000) |
| 기동 로그에 `coherent MR` 줄이 없음 | lib 또는 모듈이 옛 것(`~/covlib`) → C-1·C-3 재실행 |
| `coherent MR` 줄이 1개뿐 | 한쪽 풀만 코히런트 — GET만 이득을 받고 SET은 sync를 계속 낸다. 혼합 판정 무효 |
| span은 그대론데 sync만 0 | 정상이 아니다. 폴백이 떠 있는지 `/proc/$pid/environ`로 확인(§D-1) |
| coherent인데 `*_sync_avg_ns`가 수천 ns | `~/mc.log`가 낡았고 실제로는 대조군이 떠 있는 것 → §D-1의 environ 확인 |
| `rmmod: Module mlx5_ib is in use` | memcached·genie_memd가 남아 있음 → Phase G로 정리 후 C-1 |

## 부록: 자동화 경로

반복 측정·A/B가 필요하면 수동 대신 `tools/`의 하네스를 쓴다.

```text
tools/obwatch.sh  창 열기 + 실시간 관측 + 최종 요약 (수동 측정의 기본 도구)
tools/obup.sh     기동 + 프리로드 + 1초 샘플러
tools/obslice.sh  UTC 창 절단 (genie가 보고한 창을 그대로 입력)
tools/obsweep.sh  구성 사다리 (mcT:nqp:W 튜플, 부하 감지로 자동 진행)
tools/obalt.sh    바이너리 교대 A/B
tools/exp1-arm.sh 셀 하나를 무장 (kill → 대기 → 기동 → 빌드 판별). v4 캠페인 하네스
tools/ledger.py   셀 원장 add/show/cmp (experiments/full-20260803/cells.csv)
```

측정 규율(절대값은 fresh boot, 델타는 교대 A/B, 판정은 60초×3 + 300초 지속)은
`md/OPTIMAL_RUNBOOK.md` §7 참조.
