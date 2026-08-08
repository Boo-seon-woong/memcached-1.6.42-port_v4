# semi_final R6 러프 그래프

입력은 `RESULTS2.md`의 표이며, 생성기는 `tools/plot-semi-final.py`다.
throughput-latency의 latency는 memtier의 평균 `srv`(us)를 사용했다. 점 라벨은
`PLAN.md`의 변수값이다. 실험 4를 제외한 그래프는 YCSB-C/B/A를 단일 좌표축에
합치고 workload를 색으로 구분한다.
value-size 그래프에서는 비교 시 교란 가능성을 줄이기 위해 24 B와 48 B를 제외한다.

```bash
MPLCONFIGDIR=/tmp/matplotlib python3 tools/plot-semi-final.py
```

출력은 분포를 먼저 나누고, 그 아래에서 파일 형식을 나눈다.

```text
img/semi-final-r6/
├── uniform/
│   ├── png/
│   └── svg/
├── zipfian/
│   ├── png/
│   └── svg/
└── comparison/
    ├── png/
    └── svg/
```

## Uniform

| 실험 | PNG | SVG |
|---|---|---|
| 1. pipeline | [보기](../../img/semi-final-r6/uniform/png/exp1-pipeline-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp1-pipeline-throughput-latency.svg) |
| 2. thread | [보기](../../img/semi-final-r6/uniform/png/exp2-threads-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp2-threads-throughput-latency.svg) |
| 3. value_size | [보기](../../img/semi-final-r6/uniform/png/exp3-value-size-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp3-value-size-throughput-latency.svg) |
| 4. ext_post_chain / YCSB-C | [보기](../../img/semi-final-r6/uniform/png/exp4-ext-post-chain-ycsb-c.png) | [보기](../../img/semi-final-r6/uniform/svg/exp4-ext-post-chain-ycsb-c.svg) |
| 4. ext_post_chain / YCSB-B | [보기](../../img/semi-final-r6/uniform/png/exp4-ext-post-chain-ycsb-b.png) | [보기](../../img/semi-final-r6/uniform/svg/exp4-ext-post-chain-ycsb-b.svg) |
| 4. ext_post_chain / YCSB-A | [보기](../../img/semi-final-r6/uniform/png/exp4-ext-post-chain-ycsb-a.png) | [보기](../../img/semi-final-r6/uniform/svg/exp4-ext-post-chain-ycsb-a.svg) |
| 5. nqp | [보기](../../img/semi-final-r6/uniform/png/exp5-nqp-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp5-nqp-throughput-latency.svg) |
| 6. ORD | [보기](../../img/semi-final-r6/uniform/png/exp6-ord-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp6-ord-throughput-latency.svg) |
| 7. wire 256 shape | [보기](../../img/semi-final-r6/uniform/png/exp7-wire-shape-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp7-wire-shape-throughput-latency.svg) |
| 8. client x pipeline | [보기](../../img/semi-final-r6/uniform/png/exp8-client-pipeline-throughput-latency.png) | [보기](../../img/semi-final-r6/uniform/svg/exp8-client-pipeline-throughput-latency.svg) |

## Zipfian

| 실험 | PNG | SVG |
|---|---|---|
| 1. pipeline | [보기](../../img/semi-final-r6/zipfian/png/exp1-pipeline-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp1-pipeline-throughput-latency.svg) |
| 2. thread | [보기](../../img/semi-final-r6/zipfian/png/exp2-threads-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp2-threads-throughput-latency.svg) |
| 3. value_size | [보기](../../img/semi-final-r6/zipfian/png/exp3-value-size-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp3-value-size-throughput-latency.svg) |
| 4. ext_post_chain / YCSB-C | [보기](../../img/semi-final-r6/zipfian/png/exp4-ext-post-chain-ycsb-c.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp4-ext-post-chain-ycsb-c.svg) |
| 4. ext_post_chain / YCSB-B | [보기](../../img/semi-final-r6/zipfian/png/exp4-ext-post-chain-ycsb-b.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp4-ext-post-chain-ycsb-b.svg) |
| 4. ext_post_chain / YCSB-A | [보기](../../img/semi-final-r6/zipfian/png/exp4-ext-post-chain-ycsb-a.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp4-ext-post-chain-ycsb-a.svg) |
| 5. nqp | [보기](../../img/semi-final-r6/zipfian/png/exp5-nqp-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp5-nqp-throughput-latency.svg) |
| 6. ORD | [보기](../../img/semi-final-r6/zipfian/png/exp6-ord-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp6-ord-throughput-latency.svg) |
| 7. wire 256 shape | [보기](../../img/semi-final-r6/zipfian/png/exp7-wire-shape-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp7-wire-shape-throughput-latency.svg) |
| 8. client x pipeline | [보기](../../img/semi-final-r6/zipfian/png/exp8-client-pipeline-throughput-latency.png) | [보기](../../img/semi-final-r6/zipfian/svg/exp8-client-pipeline-throughput-latency.svg) |

## Distribution comparison

| 실험 | PNG | SVG |
|---|---|---|
| 9. key distribution | [보기](../../img/semi-final-r6/comparison/png/exp9-key-distribution-throughput-latency.png) | [보기](../../img/semi-final-r6/comparison/svg/exp9-key-distribution-throughput-latency.svg) |

## Experiment 4 구성

`img/reference/example_exp4.png`처럼 왼쪽에 throughput-latency, 오른쪽에 같은
셀들의 horizontal stacked span-latency breakdown을 배치했다. 세 패널은
`(a) throughput-latency`, `(b) GET latency breakdown`, `(c) SET latency breakdown`
이다. breakdown 색은 오직 latency component만 의미한다. SET operation이 없는
YCSB-C는 빈 `(c)`를 만들지 않고 `(a)`와 `(b)`의 2패널만 배치한다.

파생 성분은 다음과 같다. 표 반올림 때문에 생기는 음수는 0으로 clamp한다.

```text
GET other v2 = Gv2 - Gsync - Gxfer - Gcrypto
GET return   = Gv3_avg - Gadmit - Gv2
SET other v2 = Sv2 - Sxfer - Scrypto
```

실험 9는 `img/reference/example_exp9.png`의 구성을 따라 단일 scatter로 합쳤다.
YCSB-C/B/A는 색으로, uniform/zipfian은 원/사각형 마커로 구분하며 같은 workload의
두 분포를 선으로 잇는다. 다른 throughput-latency 그림과 동일하게 x축은 throughput,
y축은 `srv avg`이며 두 축 모두 선형이다.
