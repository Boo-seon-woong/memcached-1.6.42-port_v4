# OSDI 제출용 실험 계획 — 2026-08-04

참조 논문은 `paper/` 아래. 계획은 관리자 작성, 이 문서는 그것을 받아
**코드로 확인한 제약**과 **이미 있는 데이터**를 붙인 것이다.

> ### 원칙 — 관리자 지시 (2026-08-04)
>
> **"우리는 성공하려고 실험을 하는 게 아니라 결과를 보려고 실험을 하는 것이다.
> 또한 port_v4 가 앞으로 개선될 수도 있으니 섣불리 결과를 닫으려 하지 말 것."**
>
> 이 문서와 결과 기록은 그 원칙을 따른다. 목표 미달도 데이터로 남기고,
> "달성 불가" 같은 종결형 서술을 쓰지 않는다.

---

## 참조 그림 — 실제로 무엇을 그리는가

인용된 그림을 원문에서 확인했다. 축과 조건이 계획과 맞는지 먼저 본다.

| 인용 | 원문 캡션 | 축 |
|---|---|---|
| DPA-Store Fig.15 | YCSB 워크로드별 ROLEX 대비 | throughput / latency, **uniform 분포로 측정**(hot-entry cache 영향 배제 목적) |
| SMART Fig.14 | "scan under YCSB E with **different value sizes**" | 값 크기 |
| SMART Fig.13 | "scalability of tree indexes under YCSB A" | **스레드 수 확장** |
| XSTORE Fig.12a | throughput-latency (YCSB C, uniform) | 곡선 |
| XSTORE Fig.12b | **end-to-end median latency at low load** | 분해, **저부하 조건** |
| XSTORE Fig.16a | inline vs indirect value | 값 크기 16 B ~ 2 KB |

**확인 사항 둘:**

- exp2(a)를 "SMART Fig.14 처럼" 이라고 적으셨는데 원문 Fig.14 는 **값 크기**
  축이다. 스레드 확장은 **Fig.13** 이다. exp3 가 값 크기이므로 번호가 서로
  바뀐 것으로 보인다 — 의도를 확인해 주시면 반영한다.
- XSTORE Fig.12b 는 **저부하(low load) median** 분해다. 우리 운영점
  (pipeline 256)의 2,278 µs 분해를 그 자리에 놓으면 조건이 달라 비교가
  성립하지 않는다. **pipe=1 데이터가 이미 있다**(207.20 µs, 전체 분해 포함).

---

## exp1 — local vs remote memory KVS

**목적**: 처리량·지연에서 local 대비 열화가 거의 없음을 보인다.
span latency 는 비교 대상이 아니므로 exp2 로 분리한다.

```text
baseline    stock memcached (local memory)
guest vCPU  30
mcT / mtT   30 / 30  (추후 optimal 로 변경)
workload    YCSB A / B / C
분포        uniform, zipfian, real-world dataset(DPA-Store 사용분)
그 외       port 세부는 optimal setting
그림        DPA-Store Fig.15 형태 — 워크로드별 latency-throughput
```

### 계측 설정 — `EXT_RDMA_PROF=off`

**exp1 은 클라이언트측 지표만 쓰므로 서버 계측이 필요 없다.** 그리고
계측을 켜면 처리량이 **4.2% 깎인다**(2026-08-04 무변수 A/B 실측:
GET 4.30%, 혼합 4.10%). stock 에는 그 계측이 없으므로 켜 둔 채 비교하면
port 가 그만큼 불리하다.

```text
BD-PROF-ON-GET   13.245 M      BD-PROF-OFF-GET   13.840 M
BD-PROF-ON-MIX   10.926 M      BD-PROF-OFF-MIX   11.393 M
```

### YCSB ↔ memtier 매핑

| YCSB | 비율 | memtier | 가능 |
|---|---|---|---|
| A | 50 read / 50 update | `--ratio=1:1` | ✅ |
| B | 95 / 5 | `--ratio=1:19` | ✅ |
| C | 100 read | `--ratio=0:1` | ✅ |
| D | latest 분포 | 대응 없음 | ❌ |
| E | scan | memcached 에 scan 없음 | ❌ |
| F | read-modify-write | `--command` 로 부분 | ⚠️ |

분포는 memtier 2.1.4 가 `--key-pattern=Z --key-zipf-exp` 로 지원한다.
실측 확인함 — 프리로드 1 M 키에 요청 범위 10 M 으로 잡으면
균등 10.0% hit, `Z θ=0.99` 85.3% hit, `Z θ=2.0` 100% hit.

**단 YCSB 의 `ScrambledZipfianGenerator` 가 아니다.** YCSB 는 랭크를 해시해
핫키를 키스페이스 전역에 흩뿌리는데 memtier 의 `Z` 는 낮은 ID 에 뭉친다.
접근 집중도는 같고 배치가 다르다 — 각주로 명시하거나, 프리로드 키를 해시로
흩뿌려 우회할 수 있다(코드 수정 불필요).

### 이미 측정된 관련 데이터

**θ 스윕(1:9 혼합, 운영점)** — exp1 의 zipfian 셀이 어디에 놓일지 미리 안다.

| θ | 총 ops | GET span | badcrc | busyCPU |
|---|---:|---:|---:|---:|
| 균등 | 11.332 M | 22.16 µs | 8 | 29.9 |
| 0.50 | 11.397 M | 22.04 | 20 | 29.9 |
| 0.75 | 11.202 M | 22.31 | 4,234 | 29.6 |
| 0.90 | 9.573 M | 25.74 | 95,282 | 27.4 |
| 0.99 | 7.481 M | 32.95 | 250,917 | 24.6 |

GET-only(YCSB C 상당)는 θ=0.99 에서도 12.65 M / 23.45 µs 다.

**기전**: `badcrc` 가 31,000 배로 뛰지만 **재시도는 비용이 아니라 표지**다
(0.061% × 19 µs = 0.012 µs 로 span 증가 +10.8 µs 를 설명 못 한다).
비용은 직렬화이고, `busyCPU` 가 29.9 → 24.6 으로 **놀기 시작**하는 것이 증거다.
핫키가 소수 `item_lock` 버킷에 몰리고 SET 이 배타로 잡는다.

**stock 로컬메모리 대조점(기측정)**: pipe=8 3.882 M, pipe=256 16.417 M.
같은 조건 port 는 3.462 / 13.287 M — 각각 **89.2% / 80.9%**.

---

## exp2 — (a) mcT/nqp 별 성능 + (b) 클라이언트 지연 분해

### (a) 축 제안 — pipeline 을 추가할 것

DPA-Store Fig.15 와 XSTORE Fig.12a 는 **throughput-latency 곡선**이고,
그건 offered load 를 바꿔 그린다. **우리 시스템에서 그 축은 `pipeline` 이다.**
`mcT`/`nqp` 는 점을 하나씩 옮길 뿐 곡선을 만들지 않는다.

**pipeline 축은 이미 7 점이 있다** (운영점, GET-only, `EXT_RDMA_PROF=1`):

| pipe | N | ops M | client avg | p50 | p99 | busyCPU |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 120 | 0.574 | 207.20 | 183.0 | 559.0 | 22.3 |
| 8 | 960 | 3.421 | 270.72 | 215.0 | 1031.0 | 23.1 |
| 32 | 3,840 | 7.663 | 474.39 | 391.0 | 1679.0 | 23.5 |
| 64 | 7,680 | 10.027 | — | — | — | 28.8 |
| 128 | 15,360 | 12.668 | 1178.18 | 1127.0 | 2399.0 | — |
| 256 | 30,720 | 13.242 | 2277.58 | 2223.0 | 3951.0 | 29.9 |
| 384 | 46,080 | 13.022 | — | — | — | 29.9 |

**256 이 실측 정점, 384 는 후퇴.** `mcT`/`nqp` 축을 그대로 두되 이 곡선을
같이 실으면 DPA-Store/XSTORE 와 같은 형태가 된다.

### (b) 분해 — 이미 상당 부분 답이 나와 있다

운영점(pipeline 256, GET-only) 실측:

```text
클라이언트 체감 2,277.58 µs
├ 네트워크 + 클라이언트 큐잉   1,786 µs   78.4%
└ 서버 체류 srv                  491 µs   21.6%
   ├ que   소켓read → 명령시작    108 µs    4.7%
   ├ pre   명령 → backend 진입      ~1 µs    0.0%
   ├ span v3  [계약이 재는 전부]    22 µs    0.9%
   └ post  v3완료 → sendmsg        360 µs   15.8%
```

**원인이 셋이고 성격이 다르다:**

| 원인 | 정체 | 출처 | CPU 포화와의 관계 |
|---|---|---|---|
| 파이프라인 직렬화 | 커넥션이 스레드 하나에 고정(`thread.c:720`)되고 read 버퍼 명령을 순차 처리 | **stock** | **무관** |
| `post` 360 µs | 완료를 `g_ret_head` 에 주차(`storage.c:474`), 드레인 끝/reap tick 에서만 방출 | **포트 신설** | **무관** |
| CPU 포화 | pipe 32~64 에서 78.2% → 95.9% | 구조적 | — |

**stock 대조**: `select_thread_round_robin` 과 `conn_parse_cmd` 순차 처리는
pristine 에 그대로 있다(`thread.c:699`). `ext_drain_spin` 과 `g_ret_head` 는
pristine 에 **0 회** — 포트가 만든 것이다.

즉 직렬 구조는 stock 이지만 그것이 비용이 된 것은 **원격화로 op 당 서비스
시간이 1 µs 미만에서 20~25 µs 로 20 배 오른 결과**다. 그리고 지연의 큰 몫
(`post`)은 포트가 스스로 만들었다(v2 P2a 재진입 회피의 대가).

### (b) 조건 — XSTORE Fig.12b 에 맞추려면 저부하여야 한다

원문이 **"at low load"** 다. `pipe=1` 데이터가 이미 있다:

```text
클라이언트 207.20 µs (p50 183.0 / p99 559.0)
├ 네트워크+클라  162.92 µs  78.6%
└ srv             44.28 µs  21.4%
   ├ que           0.34    ← 큐잉이 실제로 사라졌다
   ├ pre           2.45
   ├ span v3      17.88     8.6%
   │   ├ admit     7.00
   │   ├ xfer      8.13     3.9%   RDMA 왕복
   │   ├ crypto    1.61
   │   ├ sync      0.05           coherent MR 이후 계측 하한
   │   └ 나머지     1.09
   └ post         23.62    11.4%  ← 큐잉 0 인데도 xfer 의 2.9 배
```

**저부하에서도 `post` 가 `xfer` 의 2.9 배**라는 것이 이 분해의 핵심이다.
부하 탓이 아니라 비동기 재개 경로의 구조적 비용이다.

---

## exp3 — 값 크기

**관리자 결정: 슬롯을 키우지 않고 현재 서버가 수용 가능한 최대까지만 잰다.**

### 코드가 정하는 상한

```c
extstore.h:81    EXT_SLOT_SIZE_DEFAULT 256
ext_crypto.h:12  EXT_CRYPTO_OVERHEAD    28      /* nonce 12 + tag 16 */
extstore.c:416   if (len > e->slot_size) return -1;
memcached.h:146  ITEM_ntotal = sizeof(_stritem)(48) + nkey + 1 + nbytes
                              + client_flags(4) + cas(8)
```

`rlen = ITEM_ntotal + 28 ≤ 256` 이므로 키 9 B 기준 **값 상한 ≈ 155 B**.

| 키 길이 | 고정분 | 값 상한 |
|---:|---:|---:|
| 8 B | 69 + 28 | **159 B** |
| 12 B | 73 + 28 | 155 B |
| 16 B | 77 + 28 | 151 B |

**계산값이다. 베드가 열리면 실측으로 확인해야 한다** — `ext_pac_fallback`
이 0 이면 원격을 탄 것이고, 0 이 아니면 그 셀은 로컬 슬랩으로 떨어진 것이다.

### 제안 범위

```text
값 16 / 32 / 64 / 128 B   (현재 캠페인은 전부 64 B)
+ 상한 근처 1 점 (144 정도) — fallback 이 안 나는 최대를 실측으로 찾는다
```

> ⚠️ **초과 시 조용히 로컬이 된다.** `storage.c:915` 가 `extstore_alloc` 실패에
> `g_pac_fallback++` 하고 `return 0` 이라 호출자가 동기 경로로 저장한다.
> 죽지 않으므로 **셀마다 `ext_pac_fallback = 0` 확인이 필수**다.
> 이 확인을 빠뜨리면 RDMA 를 한 번도 안 타고 좋은 수치가 나온다.

---

## 추가 제안 셋

### ① 메모리 노드 CPU = 0 을 그림으로

XSTORE 가 CPU 절감을 핵심 주장으로 쓴다 — *"DrTM-Tree saturates all CPUs
(24×100%) while XSTORE consumes under half"*. 우리는 **one-sided 라 genie
CPU 가 0** 인데 그것을 보여주는 그림이 계획에 없다.

```sh
awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat   # 실험 전후 2 회
```

`MANUAL_TEST_PROCEDURE §F-3` 에 절차가 이미 있다. **disaggregation 주장의
직접 증거**이고 비용이 거의 0 이다.

### ② `ext_drain_empty_max` 를 수치 뽑기 전에 정할 것

```c
memcached.c:266   settings.ext_drain_spin      = 1024;
memcached.c:267   settings.ext_drain_empty_max = 0;  /* 0 = 중단 없음. "측정으로 정한다" */
```

주석이 측정으로 정한다고 적어놓고 **정해진 적이 없다.** 결과:

```text
pipe 1    busyCPU 22.3 / 30 (74.4%)   0.575 M   op 당 CPU 38.8 µs
pipe 32   busyCPU 23.5 (78.2%)        7.669 M   op 당  3.06 µs
pipe 384  busyCPU 29.9 (99.8%)       13.057 M   op 당  2.29 µs
```

**저부하에서 CPU 의 대부분이 스핀이다.** exp2 의 저부하 구간이 이것 때문에
실제보다 나쁘게 나올 수 있고, 그 수치가 논문에 그대로 실린다.

→ `0 / 4 / 16 / 64` 스윕을 `pipe 1·32` 에서. 서버 재기동 필요, 클라이언트 불변.

### ③ 커넥션 ↔ 깊이 교환 (`N` 고정)

지금까지 **전 셀이 `-c 4`(120 커넥션)** 라 이 축의 데이터가 한 점도 없다.

```text
-t 30 -c 4    --pipeline=256    120 conn   ← 현행
-t 30 -c 16   --pipeline=64     480 conn
-t 30 -c 64   --pipeline=16   1,920 conn
```

두 효과가 반대로 작용한다 — 직렬화 큐 감소(지연↓) vs syscall 분할상환 감소
(CPU/op↑, 처리량↓). **어느 쪽이 큰지 모른다.** 파이프라인 직렬화가 CPU 와
무관하다는 것이 확인됐으므로 해볼 값어치가 있다.

> ⚠️ 판정은 **memtier 실측 latency 로만** 한다. 커넥션을 늘리면 대기가
> `read()` 이전(커널 소켓 버퍼)으로 옮겨가는데 `srv` 는 `read()` 부터 재므로
> **서버 지표만 보면 개선된 것처럼 보인다.**

---

## 실행 순서 제안

```text
0  ext_drain_empty_max 스윕            수치 뽑기 전에 확정
1  exp1   PROF off. YCSB A/B/C × 분포
2  exp2a  pipeline 축 곡선 (7 점 기측정) + mcT/nqp
   exp2b  pipe=1 저부하 분해 (기측정)
3  exp3   값 크기, 셀마다 pac_fallback=0 확인
```

---

## 디렉터리

```text
PLAN.md    이 문서
exp1/      local vs remote
exp2/      성능 축 + 지연 분해
exp3/      값 크기
```

기측정 데이터의 원본:

```text
experiments/shape-20260804/   형태 캠페인 v4 (C1 스윕 7 점 포함)
experiments/full-20260803/    123 셀 원장 (θ 스윕·계측 A/B 포함)
md/LATENCY_BREAKDOWN.md       분해 전문
```
