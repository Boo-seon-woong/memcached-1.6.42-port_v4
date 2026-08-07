# semi_final 실험 명세 — 라운드 5 (수정 빌드 전면 재측정)

실험 8개 — 변인 6개(pipeline · thread · value_size · ext_post_chain · nqp ·
ORD)를 운영점에서 **하나씩만** 흔들고, 7번은 wire 곱을 256 으로, 8번은
곱(client×pipeline)을 1,024 로 고정한 채 형태만 바꾼다. baseline 없음.

셀 이름 접두는 `R5-`. 결과는 `RESULTS2.md`.
라운드 3(180초, 빌드 `c11ede3e`)의 명세와 결과는 `RESULTS.md` 와 git 이력에
남아 있다.

## 0. 왜 전부 다시 재는가

라운드 3 은 세 결함 위에서 돌았다. 셋 다 고쳤고 그중 둘은 **측정값을 바꿨다.**

```text
① W 가 큐 크기를 정했다      CQ = 2×W×nqp 인데 W=nqp×ORD 라 nqp² 로 커졌다.
                             과대한 큐 비용을 쓰기 경로가 물었다 — 운영점 실측
                             SET +12.3% · MIX +2.5% · GET −0.09%
② ORD 핀이 CM 파라미터로     ORD>16 이 무장 불가였다. 이제 clamp 되고 기록된다.
③ 전 워커 몫을 MR 하나로     coherent MR 은 물리 연속이라 게스트 커널 버디
                             상한(4 MB)에 묶인다. 워커별로 쪼개 nqp=64 가 열렸다.
```

①이 nqp·ORD 에 따라 셀마다 다르게 작용했으므로 **Q·O·S 축은 축 내부가
교란**됐고, 나머지 축도 MIX·SET 절대값이 눌렸다. 빌드가 바뀐 이상 한 빌드에서
전 격자를 다시 재는 것이 일관된 표를 만드는 유일한 방법이다. 측정 시간을
60초로 줄여 그 비용을 감당한다(관리자 결정 2026-08-07).

## 1. 고정 조건 (전 셀 공통)

```text
빌드    memcached.permr  sha b7fe29841a6c04ff45708347
        캠페인 내내 교체하지 않는다
서버    -p 11411 -U 0 -t 30 -m 2048 -c 16384 -R 1024, taskset 0-29
        nqp=4 ORD=0(협상16) chain=8 reap=8 admit_max=0 setq_max=1
        submit_inline, drain_spin=1024, DEM=0, hashpower=22
환경    MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1
        EXT_SLOT_SIZE=256

        ★ W 는 손잡이가 아니다. 연결 시점에 `nqp × 협상ORD` 로 파생된다.
          ext_worker_window 옵션은 제거됐다.
        ★ EXT_READ_SLOTS = max(64, 2 × wire 곱).  wire 곱 = nqp × min(ORD,16)
        ★ slot=256. slot 1024 는 같은 조건 대비 −27.4% 실측이라 되돌렸고,
          그래서 value 축은 d ≤ 128 이다.
부하    genie off-box. memtier -s 10.99.0.3 -p 11411 -P memcache_text
        -t 30 -c 4 --pipeline=256 -d 64 --key-prefix=m-
        --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R
        --distinct-client-seed --hide-histogram --test-time=60
키공간  1,000,000 × d.  프리로드: 재기동·크기 변경 직후 매번
시간    부하 **60초**, 사이 20초. 구성마다 YCSB 3종 (관리자 결정 2026-08-07)
          -C  --ratio=0:1    read 100%
          -B  --ratio=1:19   read 95% / update 5%
          -A  --ratio=1:1    read 50% / update 50%
        순서는 C → B → A 고정 (읽기 전용 먼저, 쓰기 비중이 커지는 순).
        genie 의 `-A` 보고를 확인한 뒤 다음 구성으로 넘어간다.

        ▲ 키 분포: 이 격자는 **uniform**(`--key-pattern=R:R`)이다.
          YCSB 본래 정의는 Zipfian 이고 **이 memtier 빌드는 zipf 를 지원한다**
          (`--key-pattern=Z:Z --key-zipf-exp=0.99`). 다만 상류 2.1.4 태그에는
          없는 기능이라 게스트 바이너리는 master 계열 빌드다 — 버전 문자열만
          2.1.4 로 찍힌다. Zipfian 은 별도 축으로 붙인다(§5).
채널    conversation.md 에 GO/DONE. GO 맨 위에 SERVER: 줄 필수
기록    guest 추적기 42열 1초 + manifest.tsv + genie DONE 줄
저장    ① csv/R5-{OP,P,E,D,C,Q,O,S,T}.csv + rows.tsv + client.tsv
        ② ariel/trace.csv, ariel/arm/<구성>.txt (무장 지문)
        ③ genie/<cell>.txt — memtier 표준출력 전문
게이트  무장마다: **포트를 쥔 프로세스가 지정 바이너리인지 대조** ·
        coherent MR 2줄 · stats 지문 일치 · curr_items 1,000,000 ·
        ext_pac_fallback 0.  셀 유효: err5 0 · hit 100% ·
        listen_disabled_num 증가 0
```

> 무장 게이트에 바이너리 대조가 들어간 이유: `pkill -x memcached` 는 이름이
> 정확히 일치하는 것만 죽여, `memcached.permr` 같은 변종을 띄우면 옛 서버가
> 포트를 쥔 채 남았다. 그러면 로그는 새 구성을, stats 는 옛 서버를 가리키는데도
> 게이트가 통과한다(2026-08-07 실제 발생). 포트 대기도 고정 sleep 이 아니라
> 루프다 — nqp=64 는 QP 1,920 개를 연결하느라 10초로는 모자란다.

## 2. 실험과 값

| # | 실험 | 값 (굵게 = OP값) | 구성 | 바꾸는 방법 |
|---|---|---|---:|---|
| 1 | pipeline | 1, 8, 32, 64, 128, **256**, 384, 512 | 8 | 클라 `--pipeline` 만 |
| 2 | thread (mcT=mtT) | 1, 2, 4, 8, 12, 16, 24, 28, **30** | 9 | 재기동 + genie `-t m` |
| 3 | value_size | 4, 8, 16, 24, 32, 48, **64**, 96, 128 | 9 | flush + `-d` 재프리로드 |
| 4 | ext_post_chain | 1 ~ 16 전 정수 | 16 | 재기동 (reap=8 유지) |
| 5 | nqp | 1, 2, **4**, 8, 16, 64 | 6 | 재기동, ORD=협상16 |
| 6 | ORD | 1, 2, 4, 8, **협상16** | 5 | 재기동, nqp=4 |
| 7 | 형태 (wire 곱 256) | 16×16, 32×8, 64×4, 128×2, 256×1 | 5 | 재기동, nqp·ORD 동시 변경 |
| 8 | client × pipeline (곱 1,024) | 1×1024, 2×512, **4×256**, 8×128, 16×64, 32×32, 64×16, 128×8 | 8 | 클라 `-c`·`--pipeline` 만 |

### 7번 축은 nqp 를 올리는 방향이다 (관리자 결정 2026-08-07)

원안은 곱 256 을 `1×256, 2×128, 4×64, 8×32` 로도 만들려 했지만 **ORD 는 QP
속성이라 16 을 넘길 수 없다** — 그 넷은 clamp 되어 각각 Q1·Q2·Q4·Q8 과 같은
구성이 된다. 같은 곱을 nqp 쪽으로 만들면 다섯 형태가 나오고, 게다가

```text
16×16   32×8   64×4   128×2   256×1
slots 512 · 워커당 bounce 128 KB — 다섯 점의 발자국이 전부 같다
```

**발자국이 동일**하므로 지금까지 형태 판정을 괴롭힌 교란이 없다. 순수하게
"같은 동시성을 QP 수와 깊이로 어떻게 배분하느냐"만 남는다.

### 4번 축은 span 분해까지 본다 (관리자 요청 2026-08-07)

chain 은 한 번에 몇 개를 묶어 post 하느냐다. 배치가 주는 이득과 그 대가인
대기 비용을 보려면 처리량만으로는 부족하다. 셀마다 42열 추적에서 아래를
전부 표에 싣는다.

```text
span v3 = admit + v2(sync + xfer + crypto + 잔차) + ret
GET 측  Gv3_avg · Gv3_p50 · Gv3_p99 · Gadmit · Gv2 · Gxfer · Gcrypto · Gsync
SET 측  Sv3_avg · Sv3_p50 · Sv3_p99 · Sadmit · Sv2 · Sret · Sxfer · Scrypto
클라 측 srv · srv_p50 · srv_p99 · que · bk
```

### 격자를 읽는 규칙

- **wire 실효 = `nqp × min(ORD,16)`.** ORD 는 연결 시 QP 에 박히는 하드웨어
  속성이고 이 HCA 의 `max_qp_rd_atom` 은 16 이다. 그래서 6번 축은 5점이 전부다.
- **발자국은 동시성의 필수 비용이다.** in-flight READ 마다 bounce 슬롯이
  필요하므로 `slots ≥ wire 곱` 은 분리 불가다. 다만 slots 128→512(4배)의
  실측 비용은 1.4% 로 작다.
- **메모리 한계는 워커당으로 본다.** coherent MR 은 물리 연속이라 단발 4 MB
  (게스트 커널 MAX_ORDER, `/proc/buddyinfo` 11칸)가 상한이고 풀 총량은 실측
  256 MB 다. 워커별 등록이므로 `slots × 256 B ≤ 4 MB`, 즉 워커당 slots ≤ 16,384.
- 8번 축: 총 재요청 수 N = 30 × c × pipe = 30,720 으로 전 구성 동일 —
  바뀌는 것은 연결 수(30~3,840)와 연결당 깊이다. **판정은 memtier 실측으로만
  한다** (연결이 늘면 대기가 커널 소켓 버퍼로 옮겨가 서버 지표가 좋아 보인다).
- 알려진 공백: 같은-곱 깊이-2 대조(8×2, 곱 16)가 격자에 없다.

## 3. 실행 순서 (재기동 최소화 순)

```text
1  R5-OP                                          3부하  가드 시작점 · ≥10M 게이트
2  R5-P{1,8,32,64,128,256,384,512}                8×3   클라만 변경
3  R5-E{1x1024…128x8}                             8×3   클라만 변경
4  R5-D{4,8,16,24,32,48,64,96,128}                9×3   크기마다 flush+프리로드
5  R5-C{1..16}                                   16×3   재기동 16회 (span 분해 필수)
6  R5-Q{1,2,4,8,16,64}                            6×3   재기동 6회
7  R5-O{1,2,4,8,16협상}                            5×3   재기동 5회
8  R5-S{16x16,32x8,64x4,128x2,256x1}              5×3   재기동 5회
9  R5-T{1,2,4,8,12,16,24,28,30}                   9×3   재기동 9회, genie -t m
10 R5-OP-r2                                       3부하  가드 끝점
```

각 GO 는 한 구성의 3부하(-C → -B → -A 순서 고정)를 묶고, genie 의
`-A` 보고를 확인한 뒤 다음 무장으로 넘어간다. 대기 창은 구성당 30분 —
넘기면 그 셀은 버리고 보충 목록(`makeup.tsv`)에 올린다.

드리프트 가드는 `|R5-OP − R5-OP-r2|`. 라운드 3 에서 동일 구성 재현성이
**0.9%** 로 확정됐으므로 판정 기준을 그 위에 둔다 — 1% 미만은 구분 안 됨,
2% 이상은 효과.

## 4. 규모

```text
구성  OP 2 + P 8 + E 8 + D 9 + C 16 + Q 6 + O 5 + S 5 + T 9 = 68
부하  68 × 3 = 204 × (60초 + 사이 20초)                    ≈ 250분
재기동 41회 (+프리로드) · value flush 9회                    ≈ 110분
합계                                                        ≈ 6 시간
```

## 5. Zipfian 축 (계획 — 라운드 5 완료 후)

`--key-pattern=Z:Z --key-zipf-exp=0.99` 로 YCSB 기본 지수를 맞춘다. 분포의
**모양은 YCSB 와 같다** — 지수 의미가 동일한 `1/k^s` 이고, 구현만 이산 zeta
대신 연속 근사(Hörmann-Derflinger 거부-역변환, `obj_gen.cpp:391`)다. n=100만
에서 차이는 무시할 수준이다.

**다른 점은 배치다.** memtier 는 스크램블을 하지 않는다 — `generate_key()` 가
`prefix + key_index` 를 그대로 쓰고 분포의 최빈값이 `key_min` 이라, 핫 키가
문자 그대로 `m-1, m-2, …` 최저 번호다. YCSB 는 `ScrambledZipfian` 으로 순위를
해시에 통과시켜 키공간에 흩뿌린다.

memcached 해시 테이블에는 무해하다(키 문자열을 해시하므로 버킷·락은 흩어진다).
문제는 **원격 저장 쪽**이다 — 프리로드가 순차라 키 번호와 원격 오프셋이 삽입
순서로 대응하므로, 스크램블이 없으면 핫 데이터가 원격 메모리 앞쪽 연속 구간에
몰린다. YCSB 가 스크램블하는 취지가 정확히 이걸 막는 것이다.

```text
이론값 (exp=0.99, 키 100만)
  1위 키 6.50%  ·  상위 10 = 19.2%  ·  상위 1,000 = 50.2%  ·  상위 1% = 66.4%
  12.6M ops/s 라면 1위 키 하나에 초당 82만 요청
```

이 설계에는 값 수준 로컬 캐시가 없어(recache 경로 없음) 핫 키도 매번 RDMA READ
를 탄다. 따라서 Zipfian 은 캐시 효과가 아니라 **skew 아래의 잠금·원격 지역성**
을 재는 축이다. 처리량이 떨어지면 그 폭이 결과다.
