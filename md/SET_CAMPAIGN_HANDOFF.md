# SET/혼합 캠페인 인수인계 — 2026-07-30 ~ 31

두 에이전트(ariel=Claude, codex)가 번갈아 작업했다. 이 문서는 **어느 쪽이든
이어받을 수 있도록** 목표 변천·확정된 사실·기각된 레버·현재 차단 요인을 한 곳에
모은 것이다.

> **coherent data MR 구현 상세는 `md/CODEX_PROGRESS.md`가 정본이다.**
> 이 문서의 §8은 요약이고, 산출물 SHA256·검증 경계·재개 순서는 그쪽을 볼 것.
> (이 문서는 그것을 읽기 전에 작성됐고, §8의 과장 하나를 아래에서 정정했다.)

세부 로그는 `conversation.md`, 비용 모델은
`SET_WORKFLOW.md`·`SET_COST_ATTRIBUTION.md`·`SET_10M_REQUIREMENTS.md`.

---

## 0. 목표 (여러 번 바뀌었다 — 최신만 유효)

```text
최종   1:10 혼합 10 M ops/s   AND   GET-only 10 M ops/s   — 동시 충족
       두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
우선   span < 30 µs 가 10 M ops/s 보다 우선한다. 상충 시 span을 지킨다.
```

폐기된 이전 목표: SET-only 10M(실현 불가 판정) → SET-only 5M(중간 관문) →
1:9 혼합 10M. **"GET-only 기준이며 W2~W4는 게이트 대상이 아니다"는 폐기됐다.**

---

## 1. 현재 실측 기준선 (정본 off-box, `span-1f3390a`, batch=1)

| 워크로드 | 처리량 | Gspan | Sspan | busyCPU | CPU/op |
|---|---:|---:|---:|---:|---:|
| GET-only | 10.241M ✅ | 24.49 µs ✅ | — | 28.2 | 2.754 µs |
| 1:9 혼합 | 8.035M | 24.46 µs ✅ | 19.34 µs ✅ | 27.9 | 3.472 µs |
| SET-only | 2.348M | — | 15.63 µs ✅ | 24.8 | 10.562 µs |

**span 계약은 세 워크로드 모두 이미 충족한다. 남은 것은 혼합 처리량뿐이다.**

CPU 예산 모델이 실측과 1.8% 안에서 맞는다(혼합 1:9 모델 3.534 vs 실측 3.472).
따라서 아래 산수는 신뢰할 수 있다.

```text
1:10 전환      평균 CPU/op 3.464 → 28.2/3.464 = 8.14M   (1:9의 8.03M에서 +1.4%뿐)
10M 필요 평균  28.2/10 = 2.820 µs                       → −18.6% 필요
```

---

## 2. 구현물 — 브랜치 `v3-set-pac`

| 커밋 | 내용 | 상태 |
|---|---|---|
| `563fab0` | **pac** (publish-at-command 비동기 SET). 게시는 명령 시점, 응답만 CQE 이후. GET의 io_pending 수거 구조 재사용 | **on** |
| `b19af7b` | staging 슬롯 대기 (파이프라인 10번째부터 NOT_STORED 결함 수정) | 상시 |
| `90f532e` | **SYNC_FOR_DEVICE 배치화** (`ext_setq_max`) | on, 기본 1 |
| `785b308` | seal-at-flush (암호화를 flush로) | **off — 기각** |
| `7d32280` | flush에서 **명시적 완료 수거** | 상시 |
| `61d6a74` | 수거 후 drain 이벤트 arm (수거가 만든 정지 수정) | 상시 |
| `2029c73` | seal-at-flush 기본 off | — |
| `1f3390a` | **batch 기본값 1** (span 우선) + staging을 런타임 batch로 산정 | — |
| `1f9e826` | **coherent data MR 풀** (codex) | on, 폴백 있음 |
| `1362a38` | coherent MR 폴백 런타임 선택 (codex) | — |

### 런타임 노브

```text
ext_pac_set / no_ext_pac_set          기본 on    pac 자체
ext_setq_max=1..64                    기본 1     SYNC 배치 크기 (span 손잡이)
ext_seal_at_flush / no_...            기본 off   기각됨. 켜지 말 것
EXT_DISABLE_COHERENT_MR=1  (env)                 coherent MR 끄고 sync 폴백 (A/B용)
EXT_SKIP_DMA_SYNC=1        (env)                 sync 강제 생략 — 정합성 깨짐, 상한 측정용
```

---

## 3. 확정된 사실 (재검증 불필요)

### 3-1. SYNC advise는 no-op이 아니다 — 실제 바운스 복사다

```text
부팅 로그   "Memory encryption is active and system is using DMA bounce buffers"
            SEV라는 이유로 페이지 상태와 무관하게 전량 바운스
증거 1      EXT_SKIP_DMA_SYNC=1 → 읽기 100,000건 중 badcrc 100,000 (전량 실패)
증거 2      서버 정지 시 io_tlb_used −340 슬롯 (두 풀 크기 예측 339와 일치)
```

> `io_tlb_used`는 device open/close의 비동기 슬롯 변동이 섞인다. 위처럼 **기존
> snp_shared 경로가 바운스된다**는 근거로는 충분했지만(예측과 1슬롯 차),
> **coherent MR이 바운스를 안 한다는 단독 증거로는 쓸 수 없다** — codex가
> 시도했고 노이즈로 판정했다(`CODEX_PROGRESS.md` §5).

`extstore.c` 주석의 "snp_shared에서 왔으니 SYNC advise는 no-op 비용"은 **틀렸다.**

### 3-2. 그런데 비용의 99.4%는 복사가 아니라 호출 오버헤드다

batch 스윕을 모델에 적합:

```text
sync/op = 2.408/batch + 0.152 µs        (적합 오차 ±14%)
  호출당 고정비  2.41 µs   ioctl·verbs·MR 조회·swiotlb 슬롯 탐색
  객체당 한계비  0.152 µs
  필수 memcpy    ~0.015 µs (159 B)      ← 전체의 0.6%
```

### 3-3. sync 제거의 상금 (실측)

```text
SET CPU/op   7.43 → 5.69 µs  = −1.74 µs   (처리량 +18.6%, Sspan 12.5 → 8.4 µs)
```

**주의 1**: prof가 보고하는 sync 지연 2.65 µs 전부가 CPU는 아니다. 예산 계산에는
**1.74 µs**를 쓸 것. (초기에 2.56을 그대로 빼서 "10.31M"이라 한 것은 과대추정이었다.)

**주의 2 — 이 수치는 상한이지 달성치가 아니다.** `EXT_SKIP_DMA_SYNC=1`로 sync를
**강제 생략**했을 때의 값이고, 그 구성은 정합성이 깨진다(badcrc 전량). coherent MR
구현이 실제로 얼마를 회수하는지는 **아직 미측정**이다. coherent MR은 sync를
없애면서 정합성도 지키지만, 커널 경로가 달라졌으므로 비용도 다를 수 있다.
`CODEX_PROGRESS.md` §5가 같은 취지로 경고한다.

sync를 양쪽에서 없앴을 때 1:10 혼합 전망:

```text
GET도 같은 비율(66%)로 감소   평균 2.981 → 9.46M   미달
GET은 보고값 전부 감소(낙관)   평균 2.811 → 10.03M  경계
```

**필요조건이지 충분조건이 아니다.** sync 제거 + SET 고유분 절감의 조합이 필요하다.

### 3-4. batch 크기 = span 손잡이 (co-located 스윕)

| `ext_setq_max` | set/s | Sspan avg | p99 |
|---:|---:|---:|---:|
| 64 | 2.68M | 254.7 µs | 858.6 |
| 8 | 2.59M | 58.9 µs | 388.0 |
| 4 | 2.55M | 45.1 µs | 337.7 |
| 2 | 2.43M | 25.1 µs | 235.3 |
| **1** | 2.24M | **13.7 µs** | 95.0 |

혼합에서 워커당 SET 도착 간격이 ~35 µs이므로 **batch ≥ 2는 span 30 µs를 깬다.**
즉 span 계약 아래에서 SYNC 상각은 원리적으로 불가능하고, 그래서 sync 비용은
고정비가 된다 — 이것이 coherent MR이 유일한 남은 길인 이유다.

---

## 4. 기각된 레버 — 다시 시도하지 말 것

| 레버 | 결과 | 근거 |
|---|---|---|
| 비동기 SET + watermark gating | 동기 대비 **2배 손실**(0.90M vs 1.74M) | 브랜치 `v3-async-set`, 원인 미규명 |
| 비동기 SET + 연결 파킹 | **−40%**, 혼합 GET 반토막 | 상한 = 연결수÷파킹시간 |
| **seal-at-flush** | **처리량 3.15배 하락**(2.68M → 0.85M) | 원인 미규명. 캐시 지역성 아님(crypto +12%뿐), item magazine 아님(`item_mag_depth=64`로 무변화) |
| `ext_drain_empty_max` (GET) | 무효 | `OPTIMIZATION_HISTORY` 부록에 기존 실측 기록 |
| `ext_drain_spin` 상향 | **불가** | GET-only span 여유가 3.3 µs뿐(26.7→30). drain을 굵게 하면 초과 |
| 혼합비 조정만으로 | +1.4% | 1:9 8.03M → 1:10 8.14M |

---

## 5. 내가 정정한 내 오류 (기록에 남은 값 주의)

1. **2.27M 귀속** — main `7a09928`이 아니라 `cca9807`+`no_ext_async_set`였다.
2. **SET 고유 비용** — 2.29 µs로 적었으나 5.77−2.52 = **3.25 µs**다(산수 오류).
3. **sync 제거 효과** — "10.31M"은 과대추정. 실측 상금 기준 9.46~10.03M.
4. **obwatch 초당 행이 ~5% 과대보고** — 정수 초 나눗셈 대 실제 1.05초 루프.
   `date +%s.%N`으로 수정했다. **그 이전 로그의 초당 값은 전부 낙관적이다.**
   판정은 창 총계(`SERVER STATS`)로만 할 것.
5. **cca9807 열화를 "staging 누수"로 라벨** — 근거 부족. 이후 genie가
   `extstore_alloc` 소진으로 근본 원인 규명(`678e7a3`).

---

## 6. 인프라 수정 (측정 신뢰성)

- `tools/obwatch.sh` — 초 단위 → `%s.%N`. 행과 창 총계가 이제 일치한다.
- `md/MANUAL_TEST_PROCEDURE.md` — kill 후 **포트 해제 대기 루프**(누락 시
  `Address already in use`로 새 서버가 죽고 옛 프로세스를 측정한다),
  기동 확인에 bind/reg_mr 실패 포함, 변경된 게이트 기준 명시.
- 자체실험 규모 축소: **100K keys / test-time 20s / 5s 창** (델타 전용,
  절대값 판정 금지). 공용 러너 guest `~/pac-ab-20260730/ab.sh` — 서버가 떠
  있으면 **거부**한다(관리자 bed를 두 번 죽인 뒤 넣은 가드).

---

## 7. 커널 빌드 파이프라인 (1단계 — 완료)

```text
실제 소스     ~/2026/sev/local-build/AMDSEV/linux/guest
              HEAD a78481c9f206 "tmp: coherent baseline for sync-mr patch gen"
              미커밋 4파일 = SYNC_FOR_CPU/DEVICE advise 구현 그 자체
              → 배포된 mlx5_ib.ko = HEAD + 이 diff
내 작업본     ~/2026/sev-guest-kernel/work  (git worktree --detach, 관리자 트리 무영향)
검증          재빌드 모듈의 vermagic·depends가 배포본과 일치
```

**밟은 gotcha 2건 (둘 다 문서에 있던 것):**
1. `Module.symvers` 없이 `M=` 빌드 → 심볼 미해결. 실제 트리 것을 복사.
2. dirty 트리가 vermagic에 `+`를 찍어 로드 거부 → `include/config/kernel.release`와
   `include/generated/utsrelease.h`를 고정하고 해당 디렉터리 clean 후 재빌드.

> vanilla 6.16 + 아카이브 패치로는 **배포본을 재현할 수 없다**
> (cq.c 149줄·qp.c 23줄·main.c 13줄·mlx5_ib.h 15줄 차이). 반드시 실제 트리를 쓸 것.

---

## 8. coherent data MR (2단계 — codex가 구현, 검증 일부 완료)

### 왜 이것인가

`snp_shared`가 `set_memory_decrypted()`로 페이지를 shared로 만들어도 소용없다 —
`ibv_reg_mr`이 `dma_map_sgtable`을 부르고 SEV에서 그것은 무조건 바운스한다.
**바운스를 피하는 길은 페이지를 decrypt하는 것이 아니라 `dma_map`을 아예 부르지
않는 것**이고, `dma_alloc_coherent`는 `dma_handle`을 직접 준다. 이 기법은
이 프로젝트가 QP work-queue에 이미 적용·배포했다(`MLX5_QP_FLAG_COHERENT_BUF`,
`MLX5_COHERENT_QP=1`). 그리고 `rdma-sev/legacy/sev-to-mn/docs/07-*.md`가
**"Coherent data MRs"를 명시적으로 남은 과제로 적어 두었다.**

### 구현 (codex)

```text
kernel      coherent-data-mr-v2 / 82ed249cf1c8
rdma-core   coherent-data-mr-v2 / 4496bf87535a
guest 배포  /home/ubuntu/coherent-mr-v2/   (bin/ lib/ mlx5_ib.ko)
module sha  2f617927b85613da2baa2681e92902c56c4e6fb06651a703f2dbfc66afabb1d6
v3 sha      d7b8c1f35639d2467c4c9a44cca97e44e9eb2d3dfd6099c4b0bbb77298e7994f
```

`extstore.c`는 **`dlopen`/`dlsym`으로** `libmlx5.so.1`에서
`mlx5dv_alloc_coherent_mr`를 찾아 bounce/staging 두 풀을 잡고, **그 풀에
대해서만** `SYNC_FOR_CPU/DEVICE`를 건너뛴다. 심볼이 없거나 할당이 실패하면 기존
`/dev/snp_shared` + `ibv_reg_mr` + sync 경로로 자동 폴백한다. 직접 링크가 아니라
동적 탐색이므로 **같은 바이너리가 stock/non-TEE 환경에서도 동작한다.**

로컬 게이트 통과분: memcached `testapp` **56/56**, guest `coherent_mr_smoke`
(2 MiB coherent MR 생성·쓰기·해제). `tools/test-v2.sh`는 제거된 로컬 slab 계약을
전제하는 Perl 테스트를 포함해 실패하므로 **회귀 판정에 쓰지 말 것.**

### 검증 상태

- ✅ **HCA 수준 통과**: 양 끝점 coherent QP/CQ + coherent data MR,
  RC QP 2개, 4 KiB × 1,000 양방향, **DMA sync 호출 없이** 버퍼 검증 통과
  (`server_rc=client_rc=0`, 3.96~4.28 µs/iter, dmesg 무결함)
- ❌ **fabric 종단 검증 미완** — 아래 차단 요인

---

## 9. 현재 차단 요인 (2026-07-31 확인)

```text
guest ibp1s0        DOWN                    ← 인터페이스가 내려가 있다
guest → 10.99.0.2   100% packet loss
IB 포트             state ACTIVE / phys LinkUp   ← 링크 자체는 살아 있다
로드된 mlx5_ib      /lib/modules/.../mlx5_ib.ko  ← **배포판 기본 모듈**
                                                   (coherent-mr-v2 것이 아니다)
genie 10.20.26.87   ping 응답하나 SSH 타임아웃
memcached           미기동
```

**두 가지가 겹쳐 있다:**
1. guest가 재기동/모듈 재적재를 거치며 **coherent 모듈이 아닌 배포판 모듈**이
   올라와 있고 `ibp1s0`가 down이다 → Phase C(모듈 스왑 + IP) 재실행 필요.
2. genie 쪽 `ibs3=10.99.0.2/24`와 `genie_memd :11212`가 필요하다.

### 복구 순서

```sh
# [genie] ibs3 복구 + genie_memd 상주
sudo ip addr add 10.99.0.2/24 dev ibs3; sudo ip link set ibs3 up
sudo ip link set ibs3 mtu 4092
nohup ./genie_memd 11212 4g --prefill > ~/genie_memd.log 2>&1 &

# [guest] coherent 모듈로 스왑 + IP  (MANUAL_TEST_PROCEDURE Phase C)
sudo rmmod mlx5_ib && sudo insmod ~/coherent-mr-v2/mlx5_ib.ko
sudo ip addr add 10.99.0.3/24 dev ibp1s0; sudo ip link set ibp1s0 up
sudo ip link set ibp1s0 mtu 4092
ping -c2 10.99.0.2
```

---

## 10. GO 이후 즉시 실행할 게이트 (codex가 예고한 순서)

1. `EXT_SELFTEST=1` WRITE→READ 페이로드 게이트 — **sync 호출 둘 다 없는 상태로**
2. SET/GET에서 `badcrc = get_misses = read_failures = write_failures = engine_dead = 0`
3. **coherent vs sync-폴백 A/B** (`EXT_DISABLE_COHERENT_MR=1`이 대조군)
   — span·처리량·CPU/op. 예상 상금은 §3-3의 −1.74 µs/op

그 다음 정본 3종(GET-only / SET-only / 1:10 혼합, fresh boot + 300초 창)으로
이중 게이트를 판정한다.

---

## 11. sync 제거 후에도 남는 것

sync가 사라져도 1:10 혼합은 9.46~10.03M으로 **경계선**이다. 추가 절감이 필요하고,
대상은 **SET 고유 비용**이다:

```text
SET-only sync 제거 시 CPU/op   5.69 µs
  그중 crypto                  ~1.0 µs   (AES-NI, 사실상 하한)
  나머지                       ~4.7 µs   프로토콜·할당·게시·응답
GET의 동종 작업                ~2.2 µs
→ SET 고유분 약 2.5 µs 가 sync와 무관한 절감 대상
```

이 2.5 µs는 아직 프로파일되지 않았다. bpftrace로 볼 때 **워커 스레드 comm은
`mc-worker`**다(프로세스명으로 필터하면 표본이 0이 된다).

부수 미해결: SET-only에서 워커가 11.4% 유휴다(28코어 중 24.8 사용). 혼합은
99.6% 포화라 **혼합 목표를 막지는 않는다.** 성격 판별 도구는
guest `~/pac-ab-20260730/blockprobe.sh`(부하 중 실행, op당 voluntary ctxsw로
"락에 잠듦" vs "할 일 없음"을 가른다).

---

## 12. [2026-07-31] pac ⊕ coherent MR 통합과 게스트 내 정합성 게이트

### 12-1. 배포본이 무엇이었는지부터 (genie의 지적이 맞았다)

genie가 "guest memcached에 `extstore_alloc_failures`가 없다 = 678e7a3 이전
빌드"라고 지적했고, 확인 결과 **그보다 더 뒤처져 있었다**. codex가 배포한
`~/coherent-mr-v2/bin/memcached`에는 `ext_pac_set` 노브 자체가 없었다.

```text
판별 표지                    구버전   신버전
extstore_alloc_failures      없음     있음     ← genie의 678e7a3 수정
ext_pac_set (stats settings) 없음     yes      ← pac 전체
staging 코히런트 MR 크기     64512B   236544B  ← 런타임 배치 기준 sizing
```

원인은 브랜치 분기다. codex의 coherent MR은 `main`에, pac은 `v3-set-pac`에
있었고 둘은 `1f215e2`에서 갈라진 뒤 각각 15/10 커밋 앞서 있었다.
**어느 한쪽 브랜치를 빌드해도 절반만 들어간다.**

### 12-2. 병합 — 충돌은 한 곳, 의미는 AND

겹치는 소스는 `extstore.c` 하나. 충돌 훅도 하나(`worker_post_write_inner`)이고,
양쪽이 같은 advise 호출에 서로 다른 게이트를 달아 둔 것이었다.
pac은 `do_sync`(사전 sync된 post를 위해), main은 `wstaging_coherent`.
**둘 다 필요하므로 AND로 합쳤다.**

```c
    if (do_sync) {
        int adv = (g_skip_dma_sync || e->wstaging_coherent) ? 0
                : ibv_advise_mr(e->pd, IBV_ADVISE_MR_ADVICE_SYNC_FOR_DEVICE, ...);
```

충돌로 표시되지 **않았지만** 같이 고쳐야 했던 곳이 하나 더 있다. 배치 sync
`extstore_worker_sync_for_device()`는 pac이 새로 만든 함수라 main과 충돌하지
않았는데, 코히런트일 때 건너뛰는 게이트가 당연히 빠져 있었다.

```c
    if (g_skip_dma_sync || e->wstaging_coherent || n == 0) return 0;
```

병합 커밋 `31c161e`. 남은 advise 호출 지점 5곳을 전수 확인했고, 데이터 경로
3곳(배치 sync·단건 post·READ 회수)은 모두 코히런트 게이트를 갖는다. 나머지
2곳은 기동 시 selftest다.

### 12-3. genie는 재배포할 것이 없다

`genie_memd`는 4 GB MR을 등록해 `(raddr, rkey)`를 넘겨주는 **수동 단면(one-sided)
타깃**이고 데이터 경로에 참여하지 않는다. 슬롯 배치도 암호화도 모른다.
coherent MR 변경은 **게스트가 자기 로컬 버퍼를 어떻게 할당·등록하는가**만
바꾸며 와이어 프로토콜도 원격 MR도 건드리지 않는다. 게다가 genie는 SEV 밖이라
SWIOTLB 바운스 자체가 없다.

실증도 이미 있다 — PID 5137을 그대로 둔 채 새 바이너리가
`genie_connect OK (raddr=0x7722c8000000 rkey=0x182f00 ...)`로 붙었고 페이로드가
왕복했다. genie가 관찰한 나머지도 전부 정상이다: 두 번째 기동이 죽은 것은
5137이 포트를 쥐고 있어서고, `ss -ltnp`에 11212가 없는 것은 제어 채널이
RDMA CM이라서다.

### 12-4. 정합성 게이트 — 통과

```text
extstore: coherent MR 458752B at 0x7f69b821d000     ← wbounce (READ)
extstore: coherent MR 236544B at 0x7f69b81e3000     ← wstaging (WRITE)
extstore selftest: SYNC_FOR_DEVICE advise failed: No such file or directory
extstore selftest: SYNC_FOR_CPU advise failed: No such file or directory
extstore selftest: OK (256 bytes written and read back)
```

advise 두 개가 **실패했는데 페이로드는 왕복했다**. 코히런트 MR에는 umem이 없어
advise 핸들러가 ENOENT를 내지만, 애초에 sync가 필요 없으므로 데이터는 옳다.
(데이터 경로는 §12-2의 게이트로 호출조차 하지 않는다. 이 메시지는 selftest만의 것이다.)

순차 쓰기 100K → 읽기 100K:

```text
cmd_set 100000  cmd_get 100001  get_hits 100000  get_misses 1(memtier 초기 probe)
badcrc 0   read_failures 0   write_failures 0   read_retries 0
engine_dead 0   ext_slot_acct_leak 0   curr_items 100000
```

**이것이 코히런트 MR이 실제로 코히런트하다는 증명이다.** 대조군은 §b4c9fc7의
`EXT_SKIP_DMA_SYNC=1` 실험 — 바운스 MR에서 sync만 빼자 100,000/100,000 badcrc였다.
같은 "sync 없음"인데 코히런트 MR에서는 0이다.

### 12-5. 혼합 부하에서 badcrc가 나왔다 — 두 변경 어느 쪽도 원인이 아니다

1:10 혼합 20초에서 `badcrc 1143`이 잡혔다. 순차 구간에서는 0이었으므로
동시성이다. pac 축과 coherent 축을 각각 끄는 2×2로 분리했다.

| 구성 | 코히런트 풀 | badcrc | retries | ops/s |
|---|---|---|---|---|
| pac + coherent | 2 | 1206 | 3618 | 3,186,179 |
| pac + bounce | 0 | 1126 | 3378 | 2,916,888 |
| nopac + coherent | 2 | 1210 | 3630 | 3,007,020 |
| nopac + bounce | 0 | 1349 | 4047 | 2,822,233 |

*mtT=4(c=8, pipeline=32), mcT=28, ext=28×2qp, 100K 키, 20초, 게스트 내 co-located.*

**네 조합 모두 같은 비율(SET 약 5.6M건당 0.02%)이다.** pac을 꺼도, 코히런트를
꺼도 변하지 않으므로 원인은 둘 다 아니고, 같은 슬롯을 덮어쓰는 SET과 읽는
GET의 기존 경합이다. 모든 조합에서 `retries = 3 × badcrc`, `get_misses 0` —
재시도가 전부 회수한다. GCM 태그가 256B 슬롯 전체를 덮으므로 찢어진 읽기는
반드시 태그에서 걸린다. **정합성은 유지된다.**

곁가지로 처리량 방향도 보인다(co-located라 절대값은 무의미, 델타만):
coherent가 바운스 대비 +9.2%(pac) / +6.5%(nopac), pac이 nopac 대비
+6.0%(coherent) / +3.4%(바운스). 대략 가산적이며 pac+coherent가
nopac+bounce 대비 **+12.9%**.

### 12-6. 다음

정본 3종(GET-only / SET-only / 1:10 혼합)을 fresh boot + 300초 창으로 off-box
측정. 게스트는 표준 구성 + 1M 프리로드 상태로 복구해 두었다
(`ext_pac_posted 1000000` = 전량 pac 경유, 결함 카운터 전부 0).

---

## 13. [2026-07-31] 커널 패치 전후 span A/B — 상금은 처리량이 아니라 span에 있었다

§12-5의 2×2는 **정합성 격리 시험이었고 게이트 시험이 아니었다.** badcrc가 pac
탓인지 coherent 탓인지만 물었고 span을 아예 수집하지 않았다. 거기 딸려 나온
처리량 델타는 목표와 무관하며, 실제로 노이즈였다 — 같은 1:10 coherent-vs-fallback이
2×2에서 +9.2%, 재측정에서 +1.7%다. **co-located 처리량으로는 이 변경을 못 잰다.**

목표(span 선조건 → 10M)에 맞춘 측정은 다음이다. 대조군 `EXT_DISABLE_COHERENT_MR=1`은
`dma_alloc`+`ibv_reg_mr`+sync advise로 되돌아가므로 **커널 패치 이전 경로와 같다.**

| 워크로드 | 코히런트 풀 | GET span | SET span | ops/s |
|---|---|---|---|---|
| GET-only coherent | 2 | **13.17** | — | 2,872,842 |
| GET-only fallback | 0 | 18.13 | — | 3,014,131 |
| SET-only coherent | 2 | — | **8.05** | 2,193,400 |
| SET-only fallback | 0 | — | 11.91 | 2,120,886 |
| 1:10 coherent | 2 | **13.23** | **8.56** | 3,032,894 |
| 1:10 fallback | 0 | 18.45 | 12.08 | 2,983,164 |

*mtT=4(c=8, pipeline=32), mcT=28, ext=28×2qp, 100K 키, 20초, 게스트 내 co-located.
span은 `extstore_prof_*`의 `(avg×count)` 차분으로 프리로드 구간을 제외한 값.*

**span −27~32%, 처리량 ±노이즈.** 방향이 갈리는 이유는 co-located에서 memtier가
같은 28코어를 놓고 경쟁해 약 3M ops/s가 **클라이언트 쪽 상한**이기 때문이다.
서버에서 아낀 CPU가 갈 곳이 없다. span은 서버 내부 계측이라 그 영향을 받지 않는다.

### 13-1. 메커니즘 확인 — sync 항목이 사라졌다

```text
1:10 혼합, µs
          GET: span   sync   xfer   crypto  | SET: span   sync   xfer   crypto
coherent        13.25   0.04   6.50   0.66  |       8.53   0.01   7.48   0.99
fallback        19.50   5.62   7.83   0.59  |      12.00   1.99   8.95   0.98
```

sync가 계측 하한(0.01~0.04 µs)까지 내려갔다 — 커널 패치가 의도대로 동작한다.

주목할 점은 **span 감소분이 sync 감소분보다 크다**는 것이다. GET은 span −6.25에
sync −5.58, xfer −1.33. SET은 span −3.47에 sync −1.98, xfer −1.47.
바운스가 사라지면 NIC가 실제 버퍼를 직접 읽으므로 전송 자체도 빨라진다.
**이 xfer 이득은 §3-3의 CPU 모델에 들어있지 않던 덤이다.**

### 13-2. co-located가 답할 수 없는 것

아낀 CPU가 처리량으로 환산되는지는 off-box에서만 판정된다. 판정에 필요한 값:

1. off-box 세 워크로드의 span과 CPU/op — 절감분이 §11의 예측(−1.74 µs/op)과 맞는지
2. GET span 여유 — 이전 정본은 10.241M에서 24.49 µs로 여유가 5.5 µs뿐이었다.
   off-box의 sync 성분이 여기 co-located(5.62 µs)와 비슷하다면 여유가 대략 두 배가
   되지만, **부하가 다르므로 가정이지 결론이 아니다.**
