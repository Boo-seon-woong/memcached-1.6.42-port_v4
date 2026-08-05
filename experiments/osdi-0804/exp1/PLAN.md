# exp1 — local vs remote (stock ↔ port), off-box

목적: 처리량·클라이언트 지연에서 local 대비 열화 폭을 보인다. 그림은
DPA-Store Fig.15 형태(워크로드별 latency-throughput). span 은 exp2 소관.

## 확정 (이전 판의 미정 해소)

```text
계측      port 는 EXT_RDMA_PROF=0 — exp1 은 클라 지표만 쓰고, PROF 는 −4.2% 실측.
          stock 엔 계측이 없으므로 켜면 port 만 불리
스레드    mcT=30 / mtT=30 고정 (v4 운영값. "추후 optimal 로 변경" 조항 삭제)
분포      uniform + zipf θ=0.99. memtier Z 는 YCSB ScrambledZipfian 과
          집중도 동일·배치 상이(핫키가 낮은 ID 에 뭉침) — 결과에 각주 1줄로
          처리하고 우회 조치는 하지 않는다
real-world dataset  이번 라운드 제외 — 자산 없음 (PENDING 차단 목록)
지속      셀당 30초 (경향성 라운드 — 공통 규약). co-located 13셀(기측정)은
          60초 — 대조 시 30초 쪽에 **+0.83%p** 를 얹어 읽는다 (램프 계통오차,
          공통 규약). co-located→off-box −31.7% 보정 검증도 같은 보정 후에
```

## YCSB ↔ memtier

| YCSB | read / update | memtier |
|---|---|---|
| A | 50 / 50 | `--ratio=1:1` |
| B | 95 / 5 | `--ratio=1:19` |
| C | 100 / 0 | `--ratio=0:1` |

- `--ratio` 는 **SET:GET** 순서다 — B 의 update 5% 가 `1:19` 이 되는 이유.
- D(latest 분포)·E(scan)는 memcached/memtier 에 대응이 없고 F(RMW)는 부분
  구현뿐 — 셋 다 제외.
- 분포: uniform 셀은 공통 규약의 `R:R` 그대로. zipf 셀은
  `--key-pattern=Z:Z --key-zipf-exp=0.99` — SET 쪽도 `Z` 로 두는 것은 YCSB
  가 read 와 update 에 같은 분포를 쓰기 때문 (memtier 소스 확인: `Z` 는
  양측 유효, exp 범위 (0,5)).

## 셀 — 26 개 (co-located 13셀의 off-box 미러 × 서버 2종)

블록 ST (stock, 먼저 아님 — PENDING 순서상 PT 뒤):

```text
서버  ./memcached(97ceee04) -p 11411 -U 0 -t 30 -m 1024 -c 16384 -R 1024, taskset 0-29
셀    ST-P{1,8,32,64,128,256,384}   GET-only uniform, pipeline 스윕     7
      ST-{A,B,C}-{uni,zipf}         pipe=256                          6
```

블록 PT (port, PROF=0):

```text
서버  v4 운영값 (공통 규약), EXT_RDMA_PROF=0, 1M 프리로드
셀    PT-P{1,8,32,64,128,256,384}   GET-only uniform, pipeline 스윕     7
      PT-{A,B,C}-{uni,zipf}         pipe=256                          6
```

genie CPU 증거 (XSTORE 의 CPU 주장 대응): PT-C-uni 와 PT-A-uni 전후로
`awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat` 2회 — **0 이 그림 재료다.**

## 판정·예측 (사전 등록)

```text
비교 축   같은 셀 id 의 ST vs PT: ops, client avg/p50/p99
앵커      stock off-box 기측정 16.417 M @256 (재현 기대 ±3%)
          port/stock 비율 기대 80~90% (기측정 대조점 89.2%/80.9%)
          co-located→off-box 보정 기대 +46% (11.220→16.4 역산) — 어긋나면 그것이 정보
YCSB-A    stock 자체가 co-located 에서 −89.4% (락 직렬화). off-box 값이 크게
          회복되지 않으면 "메모리 배치가 아니라 락 경합" 해석을 각주로 분리
zipf 셀   port 는 badcrc 급증이 정상 표지 (비용은 직렬화 — full-20260803 θ 스윕)
```

기측정: co-located 13셀 `stock-colocated/RESULTS.md`, θ 스윕
`../../full-20260803/cells.csv` KD 블록, 대조점 pipe8/256.
