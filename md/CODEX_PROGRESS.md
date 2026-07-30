# Codex 진행 기록 — Coherent Data MR

- 기준 시각: 2026-07-31 KST
- 범위: Claude가 토큰 제한으로 중단한 시점부터 Codex가 이어서 수행한 작업
- 대상: SEV-SNP guest의 `mlx5_ib` coherent data MR 및 memcached extstore sync 제거

## 1. 인수 시점

Claude가 완료한 마지막 확정 관문은 **실제 guest 커널 소스로 현재 배포 모듈을
재빌드하는 것**이었다.

```text
실제 소스       /home/seonung/2026/sev/local-build/AMDSEV/linux/guest
실행 커널 원본  038d61fd642278bab63ee8ef722c50d10ab01e8f
분리 작업본     /home/seonung/2026/sev-guest-kernel/work
재빌드 결과     guest와 vermagic 및 depends 일치
```

이 시점에는 data MR용 `dma_alloc_coherent` 등록·mmap 경로와 extstore 연동은
아직 없었다. Codex는 이 관문부터 이어받았다.

## 2. 결과 요약

| 항목 | 상태 |
|---|---|
| `mlx5_ib` coherent data MR 구현 | 완료 |
| rdma-core/libmlx5 allocator 구현 | 완료 |
| extstore bounce/staging 풀 연동 | 완료 |
| 기존 `/dev/snp_shared` + sync 자동 폴백 | 완료 |
| 커널·rdma-core·memcached 빌드 | 통과 |
| memcached `testapp` | 56/56 통과 |
| guest 2 MiB coherent MR 생성/쓰기/해제 | 통과 |
| 동일 HCA의 raw RC QP 데이터 검증 | 통과 |
| 원격 Genie를 사용한 extstore 종단 검증 | 미완료 — fabric down |
| coherent 대 sync 폴백 성능 A/B | 미측정 |

즉, **코드·빌드·guest 내 HCA 기능 검증까지는 완료**했다. 원격 Genie가 필요한
memcached correctness 및 성능 판정은 아직 완료하지 못했다.

## 3. Codex가 구현한 변경

### 3.1 guest kernel: coherent userspace data MR

```text
작업본   /home/seonung/2026/sev-guest-kernel/work
브랜치   coherent-data-mr-v2
커밋     82ed249cf1c8  mlx5_ib: add coherent userspace data MRs for SEV-SNP
규모     5 files, +307/-1
```

주요 변경:

- `include/uapi/rdma/mlx5-abi.h`
  - `MLX5_IB_REG_MR_FLAG_COHERENT`
  - coherent MR 등록 request/response와 mmap offset
  - `MLX5_IB_MMAP_MR_COHERENT = 11`
- `drivers/infiniband/hw/mlx5/mlx5_ib.h`
  - `MLX5_IB_MMAP_TYPE_MR_COHERENT`
  - coherent MR의 CPU 주소, DMA 주소, 크기, mmap entry 보관 구조
- `drivers/infiniband/hw/mlx5/mr.c`
  - `create_coherent_mr()`
  - `dma_alloc_coherent()`가 반환한 DMA 주소로 PAS를 직접 구성
  - 일반 user MR의 `dma_map_sgtable()` 경로를 타지 않음
  - 등록 실패 및 deregistration 시 mmap entry와 coherent allocation 정리
- `drivers/infiniband/hw/mlx5/main.c`
  - coherent MR mmap/free 처리
  - userspace에는 decrypted mapping 제공

핵심은 shared page를 일반 MR로 다시 등록하는 것이 아니라, 커널이 처음부터
DMA-coherent 버퍼를 할당하고 그 DMA 주소를 MR의 PAS로 쓰는 것이다. 따라서
SWIOTLB bounce를 만들기 위한 일반 DMA map 자체를 피한다.

### 3.2 rdma-core/libmlx5: userspace allocator

```text
저장소    /home/seonung/2026/rdma-core
스냅샷    coherent-data-mr-v2 / 4496bf87535a
기준      stable-v50 a22f15e
```

추가 API:

```c
struct ibv_mr *mlx5dv_alloc_coherent_mr(struct ibv_pd *pd,
                                        size_t length,
                                        int access);
```

동작:

1. userspace VA 범위를 `PROT_NONE`으로 예약한다.
2. coherent 플래그와 예약 VA를 IOVA로 전달해 `REG_MR`을 호출한다.
3. 커널이 반환한 offset으로 `MAP_FIXED` mmap한다.
4. deregistration 때 coherent mapping을 `munmap()`한다.

심볼은 `MLX5_1.25`로 export했다. 해당 스냅샷은 기존 coherent QP/CQ 변경도 함께
포함한다. 현재 rdma-core 작업 트리의 11개 변경 파일은 이 스냅샷으로 보존되어
있으며, 기존 작업을 잃지 않도록 강제로 clean하지 않았다.

### 3.3 memcached extstore: coherent 풀과 안전한 폴백

대상 파일은 `extstore.c`다.

- `dma_mr_alloc()`가 런타임에 `libmlx5.so.1`을 열고
  `mlx5dv_alloc_coherent_mr` 심볼을 찾는다.
- write staging과 read bounce 풀을 coherent MR로 우선 할당한다.
- coherent staging이면 `SYNC_FOR_DEVICE`를 건너뛴다.
- coherent bounce이면 `SYNC_FOR_CPU`를 건너뛴다.
- 심볼이 없거나 coherent 할당이 실패하면 기존 `/dev/snp_shared` +
  `ibv_reg_mr()` + sync 경로로 자동 폴백한다.
- `EXT_DISABLE_COHERENT_MR=1`로 폴백 경로를 강제해 A/B 대조군으로 쓸 수 있다.

직접 새 libmlx5 심볼에 링크하지 않고 `dlopen()`/`dlsym()`을 사용했다. 이 때문에
stock/non-TEE 환경에서도 동일 memcached binary가 기존 경로로 동작한다.

관련 저장소 커밋:

```text
1f9e826  add coherent data MR pools and request fabric gate
1362a38  keep coherent MR fallback runtime-optional
99123f6  record coherent MR HCA validation and deployed artifacts
```

세 커밋은 `origin/main`에 반영되어 있다. 커밋 작성자 표시는 공유 작업 계정 설정상
`[ariel]`이지만, Claude 중단 뒤 Codex가 이어서 수행한 구간이다.

## 4. 빌드 및 배포 상태

### 4.1 재현 가능한 산출물

| 산출물 | SHA256 |
|---|---|
| `mlx5_ib.ko` | `2f617927b85613da2baa2681e92902c56c4e6fb06651a703f2dbfc66afabb1d6` |
| `libmlx5.so.1.24.50.6` | `d4fe021b5971e2ccd27b5d943897c35fbcbe45aebabebc7a7081210ffc2d1314` |
| `coherent_mr_smoke` | `1aedc70d339f8e09ba0a619d74d9e2d00f86575b7f8bc7a29a6ab71cda05e198` |
| `ibv_rc_pingpong` | `654eb2d4c7d5b48153184754980083366495c85d85c6a0cd462a18667aa38747` |
| v3 `memcached` | `d7b8c1f35639d2467c4c9a44cca97e44e9eb2d3dfd6099c4b0bbb77298e7994f` |

커널 모듈 메타데이터:

```text
depends:  mlx5_core,ib_uverbs,ib_core
vermagic: 6.16.0-snp-guest-038d61fd6422 SMP mod_unload
```

guest 배포 디렉터리:

```text
/home/ubuntu/coherent-mr-v2/
├── mlx5_ib.ko
├── lib/
└── bin/
    ├── memcached
    ├── coherent_mr_smoke
    └── ibv_rc_pingpong
```

새 모듈은 한 차례 `rmmod`/`insmod`로 live-load하여 검증했다. 부팅 시 기본
모듈을 영구 교체한 것은 아니다.

### 4.2 현재 guest 상태

2026-07-31 재확인 결과:

```text
uname -r               6.16.0-snp-guest-038d61fd6422
staged coherent module 2f617927...  (그대로 보존)
설치된 기본 module     825454c7...  (현재 로드된 계열)
ibp1s0                 DOWN
guest -> 10.99.0.2     FABRIC_DOWN
memcached/genie_memd   미기동
```

따라서 guest 재기동 뒤 현재는 coherent 모듈이 아니라 기본 모듈로 돌아온
상태다. 테스트 재개 시 모듈 스왑과 IP 설정을 다시 해야 한다.

롤백 후보는 guest의 다음 파일들이다.

```text
/home/ubuntu/covlib/mlx5_ib.ko
/home/ubuntu/covlib/mlx5_ib.ko.stock-bak
```

## 5. 검증 결과와 경계

### 통과

1. `make -j32 M=drivers/infiniband/hw/mlx5 modules`
   - 빌드 성공
   - guest와 vermagic 및 dependency 일치
2. rdma-core `mlx5` target 빌드 성공
3. memcached clean build 성공
   - 새 mlx5 API에 대한 직접 동적 의존성 없음
4. `./testapp`
   - 56/56 통과
5. guest `coherent_mr_smoke`
   - 2 MiB coherent MR 생성
   - 전체 버퍼 쓰기
   - MR 해제 성공
6. 동일 guest HCA의 독립 RC QP gate
   - 양쪽 endpoint 모두 coherent QP/CQ 및 coherent data MR
   - 4 KiB × 1,000 양방향 SEND/RECV
   - payload 검증 성공
   - `server_rc=0`, `client_rc=0`
   - 관찰값 3.96–4.28 µs/iter
   - dmesg에서 BUG/Oops/GPF/UAF 없음

마지막 3.96–4.28 µs/iter는 **동일 HCA 기능 smoke 값**이며 원격 fabric 성능
수치가 아니다.

### 아직 통과하지 않은 것

- 원격 Genie를 통한 `EXT_SELFTEST=1` WRITE→READ
- SET/GET의 `badcrc`, `get_misses`, `read_failures`, `write_failures`,
  `engine_dead` 전부 0 확인
- coherent와 `EXT_DISABLE_COHERENT_MR=1` sync 폴백의 span/CPU/op/처리량 A/B
- fresh boot 정본 GET-only, SET-only, 1:10 mixed 장시간 측정

따라서 과거 sync-off 상한 측정의 `SET CPU/op -1.74 µs`와
`Sspan 12.5 -> 8.4 µs`를 이번 구현의 달성 성능으로 주장하면 안 된다.
이번 구현의 실제 성능 개선폭은 아직 미측정이다.

### 검증상 주의점

- `io_tlb_used`는 device open/close 과정의 비동기 슬롯 변화가 섞여 coherent
  MR의 no-bounce 단독 증거로 사용할 수 없었다.
- `tools/test-v2.sh`는 제거된 로컬 slab/large-object 계약을 전제하는 기존 Perl
  테스트(`64bit.t`, `dash-M.t`, `multiversioning.t`)까지 실행해 장시간 실패했다.
  coherent MR 회귀 판정으로 쓰지 않았으며, 로컬 C gate는 `testapp` 56/56이다.
- HCA gate 출력은 `conversation.md`에 요약되어 있으나 전용 raw benchmark
  artifact는 남기지 않았다. 원격 성능 측정 때는 raw 로그를 별도로 보존해야 한다.

## 6. 차단 요인과 재개 순서

현재 blocker는 코드가 아니라 원격 fabric이다.

```text
guest ibp1s0       DOWN
guest 10.99.0.2    도달 불가
Genie 관리망 SSH   마지막 시도에서 timeout
genie_memd :11212  사용 불가
```

Genie가 복구되면 다음 순서만 수행하면 된다.

1. Genie `ibs3=10.99.0.2/24`, MTU 4092, `genie_memd 11212 4g --prefill`
2. guest에서 staged `coherent-mr-v2/mlx5_ib.ko`로 모듈 스왑
3. guest `ibp1s0=10.99.0.3/24`, MTU 4092 설정 후 ping
4. `EXT_SELFTEST=1` correctness gate
5. SET/GET 오류 카운터 gate
6. coherent 대 `EXT_DISABLE_COHERENT_MR=1` A/B
7. fresh boot 정본 3종 워크로드 측정

## 7. 저장소 상태

```text
memcached v3
  /home/seonung/2026/memcached-1.6.42-port_v3
  HEAD = origin/main = 6a5031387d0b
  source 커밋은 push 완료
  빌드 산출물과 .deps 등 tracked 파일은 dirty 상태

kernel worktree
  /home/seonung/2026/sev-guest-kernel/work
  HEAD 82ed249cf1c8
  clean

rdma-core
  /home/seonung/2026/rdma-core
  base HEAD a22f15e
  coherent-data-mr-v2 -> 4496bf87535a
  11개 변경 파일은 의도적으로 보존된 dirty 상태
```

세부 대화 로그는 `conversation.md`, 전체 SET/혼합 캠페인 인수인계는
`md/SET_CAMPAIGN_HANDOFF.md`에 있다.
