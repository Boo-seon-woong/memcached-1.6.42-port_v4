# v4 결과 — span v3 계약

작성 2026-08-02. v3 는 `../memcached-1.6.42-port_v3/` 에 동결돼 있다.

```text
계약   1:10 혼합(SET:GET) 10 M ops/s  AND  GET-only 10 M ops/s
       두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
       span 정의는 v3 — backend 진입에서 응용 가시 완료까지
```

---

## 결론

```text
운영값  ext_admit_max=64  ext_reap_every=12  ext_post_chain=8
        ext_setq_max=1    ext_submit_inline  W=40  nqp=4  mcT=30  -R 1024

GET-only   11.262 M / span 25.98                 처리량 ✓   span ✓   ★ 계약 달성
1:9 혼합    9.193 M / GET 21.30  SET 21.69       처리량 ✗   span ✓   목표의 92%
```

**GET-only 는 계약을 만족한다. 혼합은 span 을 만족하고 처리량이 8% 부족하다.**

출발점과 비교하면:

```text
              혼합 처리량   GET span   SET span
v3 정의 직후     9.83 M      316.24     188.75      둘 다 위반
v4 운영값        9.19 M       21.30      21.69      둘 다 통과
```

span 이 **15 배** 줄었고 처리량은 6% 줄었다.

---

## 1. 무엇이 문제였나 — 대기 세 겹

span 정의를 v2 → v3 로 넓히자 계약이 8 배 초과로 깨졌다. 정의가 성능을 바꾼
것이 아니라, **원래 있던 대기가 계측 안으로 들어온 것**이다. 증거: 클라이언트가
보고한 SET 지연이 7.45 ms 인데 v2 는 7.8 µs 라고 했다.

v3 로 GET 에 추가된 구간(6a~8)은 전부 **워커 전용 로컬 작업**이다 — TLS 캐시
할당, io_cache 할당, 빈 iov, 구조체 복사, 큐 삽입, 카운터 증가. 200 ns 면
끝날 일에 25 µs 가 붙어 있었다. 세 겹이었다:

| 대기 | 크기 | 원인 | 수정 |
|---|---:|---|---|
| 제출 | 9.91 µs | 연결의 읽기 버퍼를 다 파싱해야 io_queue 를 제출 | 파싱 즉시 post (`ext_submit_inline`) |
| 완료 관측 | 31.56 → 5.52 | CQE 가 pass 끝까지 **폴링조차 안 됨** | post 자리에서 수거 |
| SET 재개 | 25.48 µs | 완료를 거두고도 재개를 다음 pass 로 미룸 | 마지막 재개만 보류 |

**SET 이 답을 갖고 있었다.** pac 의 admit 은 처음부터 0.5~0.7 µs 였다 —
`ext_setq_max=1` 이라 큐에 넣자마자 그 자리에서 flush 하기 때문이다.
GET 경로만 상류 memcached 의 io_queue 배칭을 물려받고 있었다.

---

## 2. 코드 변경

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
```

### badcrc — v4 이전부터 있던 정합성 결함

혼합 부하에서 **있는 키가 조용히 MISS 로 돌아가고 있었다**(pipe=256 에서
GET 의 0.025%). 상류 extstore 는 페이지 단위로 재활용하고 `page_version` 으로
낡은 읽기를 걸러내는데, **이 포트는 슬롯 단위로 재활용하면서 버전을 올리지
않는다**(`extstore.c:534`). 그래서 `extstore_check` 가 항상 통과하고 안전망이
무력하다. `storage_delete` 가 unlink 시점에 loc 을 회수해, 읽는 중인 원격
메모리를 다음 SET 이 덮어썼다.

회수를 `item_free` 로 옮겼다 — GET 이 이미 `hdr_it` refcount 를 쥐므로 그것으로
보호가 성립한다. 호출처가 9 군데라 `STORAGE_delete` 매크로 한 곳에서 막았다.

**우리 둘 다 못 봤다**: `err5` 집계에 badcrc 가 없었고 hit 율 0.025% 는
"100%" 로 반올림된다. v3 의 계약 달성치도 이 조건에서 잰 값이다.

---

## 3. 왜 혼합이 10 M 에 못 가나

혼합은 **CPU 로 묶여 있다**(`busy 29.7 / 30`). span 은 예산의 70% 가 남는다.

```text
                        CPU/op   처리량   span
무제한 기준선 (인라인 전)  2.51   11.88 M   243
v4 운영값                 3.26    9.19 M    21
```

**인라인+수거가 CPU/op 0.75 를 쓰고 span 243 → 21 을 샀다.** 프로파일로
그 내역을 갈랐다(기준선 대비):

```text
커널   +0.098      유저   +0.882
  pthread_mutex_lock/unlock  +0.238
  pthread_spin_lock          +0.093   ← 체인으로 회수함
  _mlx5_post_send            +0.051   ← 체인으로 회수함
  나머지: 파싱 경로 전반이 1.5~1.6 배로 고르게
```

**특정 심볼이 아니다.** RDMA 작업을 파싱 사이에 끼워 넣으면서 생긴 확산
비용이고, 겨눌 지점이 없다.

호스트도 여유가 없다 — **AMD EPYC 9124, 물리 16 코어 / 32 스레드, guest 가
이미 30 을 쓴다.** 코어를 늘리는 길은 막혀 있다.

---

## 4. 측정하고 기각한 것

추측이 아니라 실측으로 버린 목록이다.

| 시도 | 결과 |
|---|---|
| EVP 배관 (프로파일 6.61%) | 마이크로벤치 최선 −3.1% → CPU/op 의 0.34% |
| `stats.mutex` 제거 | −0.7% (노이즈) |
| `item_lock` 배열 축소 (15→10) | **−4% 악화** |
| IPoIB connected 모드 | 커널이 거부 (`I/O error`) |
| SWIOTLB 바운스 | op 당 ~400 B ≈ 40 ns |
| rx-usecs coalescing (8→64) | 처리량 불변 (이미 패킷당 1 인터럽트) |
| `-R` 32 | 처리량·span 둘 다 악화 |
| `ext_setq_max` 4 | 혼합 +3%, 두 span 초과. SET 밀도 10% 라 배치를 못 채운다 |
| `admit_max` + `chain` 조합 | 상한이 체인 슬롯을 세어 과도하게 조인다 |

**아홉 개 축을 봤다** — pipeline, 연결 수, `-R`, W, submit_batch, admission,
reap, chain, setq. 혼합 처리량은 9.2~9.5 M 에서 멈춘다.

---

## 5. 남은 8% 를 채우려면

```text
필요        혼합 CPU/op 3.26 → 3.00  (−8%)
```

세 가지뿐이다. 앞의 둘은 이 하드웨어에서 불가능하다.

1. **코어 추가** — 산술적으로 바로 닿는다. 호스트가 물리 16 코어라 불가.
2. **링크 지연 단축** — 단일 요청 왕복 177.8 µs 가 IPoIB 다. connected 모드가
   거부되므로 이 구성에서 불가.
3. **확산 비용 제거** — 파싱과 RDMA 를 같은 스레드에서 번갈아 하는 구조를
   바꾸는 것이다. 예를 들어 파싱 전담/RDMA 전담으로 스레드를 나누면 캐시
   지역성이 회복될 수 있지만, 그건 v4 의 인라인 설계를 되돌리는 방향이라
   span 이 다시 늘 위험이 크다. **측정 없이는 판단할 수 없다.**

---

## 6. 재현

```text
서버   mcT = 30   -m 2048 -c 16384 -R 1024
       ext_worker_window=40  ext_qp_per_worker=4  ext_drain_spin=1024
       hashpower=22  ORD=0(협상→16)  총 QP = 120
       ext_admit_max=64  ext_reap_every=12  ext_post_chain=8
       ext_setq_max=1  ext_submit_inline  ext_submit_batch=20
       ext_loc_mag_depth=64  ext_pac_set=on  ext_seal_at_flush=off
환경   MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1 EXT_SELFTEST=1
       EXT_SLOT_SIZE=256  EXT_READ_SLOTS=64
부하   mtT=30  -c 4 (120 커넥션)  pipeline=256  -d 64  --test-time=30
       --key-prefix=m- --key-minimum=1 --key-maximum=1000000
       --key-pattern=R:R --distinct-client-seed
키공간 1,000,000 × 64 B, 구성마다 재기동 + 프리로드

무장   RE=12 PC=8 SQ=1 INLINE=1 tools/exp1-arm.sh A64
슬라이스 python3 tools/exp0-slice.py experiments/expa-20260801/trace.csv
```

raw 는 `experiments/` 아래. EXP-0 은 `exp0-20260801/FINDINGS.md`,
EXP-1 축별 판정은 `EXP1_FINDINGS.md`, 프로파일은 `perf8-20260802/`,
`perfnow-20260802/`.
