# v4 결과 — span v3 계약 달성

작성 2026-08-02. v3 는 `../memcached-1.6.42-port_v3/` 에 동결돼 있다.

```text
계약   1:10 혼합(SET:GET) 10 M ops/s  AND  GET-only 10 M ops/s
       두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
       span 정의는 v3 — backend 진입에서 응용 가시 완료까지
```

---

## 최종 게이트

120 초 창, 아무것도 동승하지 않음, 추적기 1 개.

```text
GET-only  12.393 M   span 25.05 = adm 4.05 + v2 21.01                  ✓ ✓
SET-only   5.434 M   span  7.67 = adm 0.71 + v2 6.84 + ret 0.12
1:9 혼합  10.122 M   GET 20.41 = 7.55 + 12.88                          ✓ ✓
                     SET 21.68 = 0.56 + 6.72 + 14.39                   ✓
          10.094 M   GET 20.45   SET 21.70   (재확인)                   ✓ ✓
```

**두 워크로드 모두 처리량과 span 을 만족한다.**

운영값:

```text
ext_admit_max=64  ext_reap_every=12  ext_post_chain=8  ext_setq_max=1
ext_submit_inline  ext_submit_batch=20  W=40  nqp=4  mcT=30  -R 1024
```

여유는 혼합 처리량이 **+1.0~1.2%** 다. genie 가 보고한 bed drift 1.4% 와
같은 자릿수이므로 **넉넉하지 않다.** 다만 120 초 창 두 번과 30 초 창 네 번,
총 여섯 관측이 전부 10 M 위다.

출발점 대비:

```text
              혼합       GET span   SET span
v3 정의 직후   9.83 M     316.24     188.75     둘 다 위반
v4 최종       10.12 M      20.41      21.68     둘 다 통과
```

**span 15 배 감소, 처리량 +3%.**

---

## 1. 무엇이 문제였나 — 대기 세 겹

span 정의를 v2 → v3 로 넓히자 계약이 8 배 초과로 깨졌다. **정의가 성능을 바꾼
것이 아니라 원래 있던 대기가 계측 안으로 들어왔다.** 증거: 클라이언트가 보고한
SET 지연이 7.45 ms 인데 v2 는 7.8 µs 라고 했다.

v3 로 GET 에 추가된 구간은 전부 **워커 전용 로컬 작업**이다 — TLS 캐시 할당,
io_cache 할당, 빈 iov, 구조체 복사, 큐 삽입, 카운터 증가. 200 ns 면 끝날 일에
25 µs 가 붙어 있었다:

| 대기 | 크기 | 원인 | 수정 |
|---|---:|---|---|
| 제출 | 9.91 µs | 연결의 읽기 버퍼를 다 파싱해야 io_queue 제출 | 파싱 즉시 post |
| 완료 관측 | 31.56 → 5.52 | CQE 가 pass 끝까지 **폴링조차 안 됨** | post 자리에서 수거 |
| SET 재개 | 25.48 µs | 거두고도 재개를 다음 pass 로 미룸 | 마지막 재개만 보류 |

**SET 이 답을 갖고 있었다.** pac 의 admit 은 처음부터 0.5~0.7 µs 였다 —
큐에 넣자마자 그 자리에서 flush 하기 때문이다. GET 경로만 상류 memcached 의
io_queue 배칭을 물려받고 있었다.

## 2. 처리량은 락에서 나왔다

span 을 연 뒤 혼합은 9.2 M 이었다. 나머지는 전부 **경합**이었다:

| 수정 | 무엇이었나 | 효과 |
|---|---|---|
| 아이템 카운터 샤딩 | SET 1 건이 공유 캐시라인을 **10 번** 갱신. stub 이 전부 같은 slab class | SET-only +27% |
| refcount 원자화 | GET 이 `item_lock` 을 **두 번** 잡음. 두 번째는 `--refcount` 가 원자가 아니어서 | 두 워크로드 +8.5% |
| 워커 통계 락 제거 | GET 1 건이 `stats.mutex` 를 **두 쌍** 잡음 | 혼합 +0.6% → 계약 |

셋 다 **원자 연산이거나 락이 필요 없는 데이터인데 30 워커가 같은 줄을
두드리던 것**이다. 프로파일에서 `pthread_mutex` 가 계속 1 위였고, 세 번에
걸쳐 `C_get` 2.754 → 2.469, 락 0.504 → 0.291 로 내려갔다.

---

## 3. 코드 변경

```text
3a50784  SET 반환 경로 — 완료를 거둔 그 pass 에서 재개
185ec64  badcrc — 원격 슬롯 회수를 unlink 에서 item_free 로
3edbd11  ext_submit_inline — 파싱 즉시 post, io_queue 우회
9d4a924  post 자리 수거 — 파싱 중인 연결과 자기 자신을 제외
adb82a0  item_trylock — 락 보유를 추측하지 않고 질의
460d326  마지막 재개만 보류 — resps_suspended > 1 이면 안전
30ae0a4  ext_reap_every — 수거를 N 건마다로 상각
6277c37  ext_post_chain — post 를 N 건씩 묶어 QP 스핀락을 1/N 로
c580468  ext_setq_max 를 stats settings 에 노출
b75a61d  아이템 카운터를 워커별로 샤딩
6ba0c55  refcount 원자화 — item_remove 가 0 일 때만 잠근다
d88ea82  워커 통계 뮤텍스 제거
```

### badcrc — v4 이전부터 있던 정합성 결함

혼합에서 **있는 키가 조용히 MISS 로 돌아가고 있었다**(pipe=256 에서 GET 의
0.025%). 상류 extstore 는 페이지 단위로 재활용하고 `page_version` 으로 낡은
읽기를 걸러내는데, **이 포트는 슬롯 단위로 재활용하면서 버전을 올리지
않는다**(`extstore.c:534`). `storage_delete` 가 unlink 시점에 loc 을 회수해
읽는 중인 원격 메모리를 다음 SET 이 덮어썼다.

회수를 `item_free` 로 옮겼다 — GET 이 이미 refcount 를 쥐므로 그것으로 보호가
성립한다. 호출처가 9 군데라 `STORAGE_delete` 매크로 한 곳에서 막았다.

**우리 둘 다 못 봤다**: `err5` 집계에 badcrc 가 없었고 hit 율 0.025% 는
"100%" 로 반올림된다. v3 의 계약 달성치도 이 조건에서 잰 값이다.

---

## 4. 측정하고 기각한 것

| 시도 | 결과 |
|---|---|
| EVP 배관 | 마이크로벤치 최선 −3.1% → CPU/op 의 0.34% |
| `item_lock` 배열 축소 (15→10) | **−4% 악화** |
| IPoIB connected 모드 | 커널이 거부 (`I/O error`) |
| SWIOTLB 바운스 | op 당 ~400 B ≈ 40 ns |
| rx-usecs coalescing | 처리량 불변 (이미 패킷당 1 인터럽트) |
| `-R` 32 | 처리량·span 둘 다 악화 |
| `ext_setq_max` 4 | 혼합 +3%, 두 span 초과. SET 밀도 10% 라 배치를 못 채운다 |
| `admit_max` + `chain` 조합 | 상한이 체인 슬롯을 세어 과도하게 조인다 |
| `mcT` 16 (물리 코어 독점) | 6.56 M. vCPU 당 효율 +21% 지만 코어 수가 이긴다 |
| flush 를 락 밖으로 | 혼합 9.05 대 9.18. SET span 은 8.6 으로 좋아지나 처리량을 낸다 |
| `reap` 16 (refcount 후) | 처리량 불변, GET span 31.16 초과. 같은 손잡이가 상태에 따라 반대 |

---

## 5. 남은 여유와 다음 표적

혼합 여유가 +1.0~1.2% 로 얇다. 더 필요하면 `C_get 2.469` 에 남은 것:

```text
[k] __irqentry   0.241   9.8%   NIC 인터럽트. coalescing 은 기각됨
락 (item_lock)   0.291  11.8%   조회 1 쌍. 해시 버킷과 합치면 줄지만 큰 변경
해시             0.173   7.0%
평문/응답 할당    0.154   6.2%   64 B 면 resp->wbuf 로 직접 복호 가능 — 미시도
EVP 배관         0.120   4.9%   기각됨
```

**`평문/응답 할당` 은 아직 안 건드렸다.** GET 마다 평문 목적지를 캐시에서
할당하고 복호한 뒤 되돌려주는데, 64 B 값이면 응답 버퍼로 직접 복호하면 그
한 쌍이 사라진다. GET 이 혼합의 90% 라 지렛대가 있다.

기계 한계도 적어둔다:

```text
호스트  AMD EPYC 9124  물리 16 코어 / 32 스레드
guest   -smp 30 (관리자 확정, 변경 없음)
        vCPU 는 호스트 0..29 에 1:1 핀. SMT 짝 (0,16)…(15,31)
        → 14 코어가 SMT 공유, 2 코어 단독

물리 코어 1 개 단독 0.410 M/s,  SMT 2 스레드 0.604 M/s  (배율 1.47)
현재 배치의 천장 = 14×0.604 + 2×0.410 = 9.27 M  ← 이 값은 개선 전 기준이다
```

---

## 6. 재현

```text
서버   mcT = 30   -m 2048 -c 16384 -R 1024   taskset -c 0-29
       ext_worker_window=40  ext_qp_per_worker=4  ext_drain_spin=1024
       hashpower=22  ORD=0(협상→16)  총 QP = 120
       ext_admit_max=64  ext_reap_every=12  ext_post_chain=8
       ext_setq_max=1  ext_submit_inline  ext_submit_batch=20
       ext_loc_mag_depth=64  ext_pac_set=on  ext_seal_at_flush=off
환경   MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1 EXT_SELFTEST=1
       EXT_SLOT_SIZE=256  EXT_READ_SLOTS=64
부하   mtT=30  -c 4 (120 커넥션)  pipeline=256  -d 64  --test-time=120
       --key-prefix=m- --key-minimum=1 --key-maximum=1000000
       --key-pattern=R:R --distinct-client-seed
키공간 1,000,000 × 64 B

무장   RE=12 PC=8 SQ=1 INLINE=1 tools/exp1-arm.sh A64
슬라이스 python3 tools/exp0-slice.py <trace.csv>
```

**측정 위생**: 추적기(`shape-trace.sh`)는 **하나만** 띄운다. 캠페인 중 6 개가
누적돼 후반 셀이 낮게 편향된 적이 있다. perf 는 guest 디스크가 6.8 G 뿐이므로
`-F 199`, 콜그래프 없음, 10 초(약 4 MB)로 뜬다.

raw 는 `experiments/` 아래. EXP-0 은 `exp0-20260801/FINDINGS.md`,
EXP-1 축별 판정은 `EXP1_FINDINGS.md`, 프로파일은 `prof-20260802/`.
