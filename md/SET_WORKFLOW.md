# SET 경로 전체 워크플로 — 요청 도착부터 응답 송신까지

본문 작성 2026-07-30(v3 기준, commit `6428ccd`). **v4 에서 반환 경로가
바뀌었다** — 아래 §v4 를 먼저 읽을 것. 단계마다 코드 위치·잡는 자원·실측
비용을 붙인다. 수치 출처는 `md/SET_COST_ATTRIBUTION.md`(프로파일·A/B),
`md/SET_10M_REQUIREMENTS.md`(예산 산정), `md/GET_SET_CONCURRENCY.md`(구조 대조),
v3→v4 구조 변화는 `md/V3_TO_V4_CHANGES.md`.
비동기 SET 두 갈래가 실측 기각된 경위는 `md/V3_REVIEW_FINDINGS.md` 처분 주석 참조.

## §v4. 무엇이 바뀌었나 — 반환 경로 하나

SET 은 v3 에서 이미 pac(publish-at-command)이었고 **admit 은 처음부터
0.5~0.7 µs 로 좋았다** — 큐에 넣자마자 그 자리에서 flush 했기 때문이다.
v4 가 바꾼 것은 **완료 뒤 재개를 언제 하는가** 하나다.

```text
v3   WRITE CQE 를 거둔다 → 재개는 다음 pass 로 미룬다
     ret 173.11 µs (1:9 혼합)  /  2371.84 µs (SET-only)
v4   거둔 그 pass 에서 재개한다                              ret 0.62 µs
     ├ 큐 상한 flush 안에서 재개 — 잡고 있는 버킷만 보류
     └ 마지막 재개만 보류 (resps_suspended > 1 이면 안전)
```

**"마지막 재개만" 이 핵심이다.** 처음엔 연결 단위로 통째 보류했더니
6 M SET 에 44.5 M 건이 보류돼 `ext_setret_now = 0` 이 됐다 — 즉 재개가 100%
막혔다. 위험한 것은 **마지막 재개뿐**이다: `conn_worker_readd` 는 보류
카운터가 0 이 될 때만 걸린다.

버킷 보류도 처음엔 "호출자가 어느 버킷을 쥐고 있나"를 **추측**했다가
서버가 멈췄다. 지금은 `item_trylock` 으로 **질의**한다 — 실패하면 보류한다.

결과:

```text
혼합 Sv3   188.75 µs → 9.11 µs   (EXP-0 → 최종 게이트)
최종 게이트  9.11 = adm 0.52 + v2 7.97 + ret 0.62
           ret 이 173.11 → 0.62 로 279 배다
```

### 본문의 무효 표기와 기준 수치

본문 §0-1~§0-3 의 "무효" 표기는 그대로 유효하다(alloc 결함 이전 측정).
§0-5 의 "현행 수치"는 **v3 시점**이고 지금은 아니다 — 현행은
`mcT30 / W24 / nqp4 / reap8 / chain8` 에서 **혼합 11.099 M, SET span 9.11 µs**
다(`OPTIMAL_RUNBOOK.md`).

§0-7 의 "레버는 이제 SET 이 아니다"는 v4 에서도 유효하다. 1:9 혼합에서
GET 이 CPU 의 대부분을 쓴다.

아래 본문의 단계별 설명은 **반환 경로(단계 ⑨ 이후)를 빼면** 그대로 유효하다.

> ## ⚠ 2026-07-30 20:55 — 이 문서의 SET 측정치는 전부 무효다
>
> genie가 `extstore_alloc`의 재활용 조건 결함을 잡았다(`678e7a3`). 이 함수는
> **SET 경로 한복판**(단계 7b)이고, 수정 전에는 SET의 약 12%가 느린 페이지
> append 경로로 흘렀으며 그 경로가 페이지를 진행성으로 소진시켰다.
> **7-30에 잰 SET 수치는 전부 그 상태에서 나온 것이다** — §0-1, §0-2, §0-3,
> 그리고 off-box 판정치까지. 재측정 대상 목록은 §0-4.
>
> 무효화되지 않는 것: **§0(7-29 기준선)의 구조적 결론**(락 제거 궤적,
> 동기 구조 상한, span 성분비)과 **GET 수치 전부**(GET은 원격 슬롯을
> 할당하지 않는다). §1~§2의 경로 서술과 §5의 계약도 유효하다 — 단 **7b는
> 이번에 정정됐다**(magazine 히트율 100%는 사실이 아니었다).
>
> 재측정 대상 바이너리: `v3-set-pac` **`785b308`** (alloc 수정 + pac +
> SYNC 배치화 + seal 지연). 5M·10M 산수는 재측정 후 다시 세운다.

> ## ✅ 2026-07-31 — 재측정 완료, 계약 충족. §0-5를 먼저 읽을 것
>
> 위 무효화 이후 세 건이 더 들어갔고(coherent MR, loc magazine 스캔,
> GCM 1회 키잉) **이중 게이트가 충족됐다.** §0~§0-4의 수치는 전부 그 이전
> 상태이며 **현행 값은 §0-5**다. §1~§2의 경로 서술과 §5의 계약은 유효하고,
> §4 레버 원장에 새 항목이 붙었다.

## 0. 기준 수치 (mc28 / W24 / nqp2 / hp22, 2026-07-29 실측)

```text
SET-only 처리량        1.71 M ops/s
프로세스 CPU           7.29 µs/op        (기준 27.41에서 −73%)
워커 벽시계 점유        ~16 µs/op         (기준 87 µs에서)
span (encrypt→CQE)     5.03~5.3 µs       = crypto 1.05 + sync 1.90 + xfer 2.48
                                          4단계 최적화 내내 불변 — RDMA는 병목이 아니다
CPU 포화 상한          28워커 ÷ 7.29 µs = 3.84 M/s   (실측은 그 45%)
동기 구조 하드 상한     28워커 ÷ 5.03 µs(span) = 5.57 M/s
10M 목표 CPU 예산      2.57 µs/op        (GET이 10.12M을 낼 때와 같은 자원)
```

두 상한의 의미: CPU를 아무리 깎아도 **동기 구조로는 5.57M이 천장**이고,
CPU 7.29µs로는 **3.84M이 천장**이다. 실측 1.71M은 CPU 상한의 45%로,
나머지 55%는 아래 §3에서 규명되지 않은 대기다(§4-9).

### 0-1. 2026-07-30 동기 경로 재측정 (memtier@genie, 60s 창) — **무효**

> **무효 (2026-07-30 20:55).** alloc 결함 상태에서 측정됨 → 재측정 필요.
> 아래 수치는 이력 보존용이며 어떤 판정의 근거로도 쓰지 않는다.

> **귀속 정정.** 초판은 이 측정을 main `7a09928`으로 적었으나, 당시 떠 있던
> 서버는 **`memcached.cca9807` + `no_ext_async_set`**(PID 33104, 06:46 기동,
> `~/v3-ab-main-vs-cca-20260730-064659/cca_sync3`)였다. §0-2의 A/B가 두
> 바이너리의 동기 경로가 동일 성능임을 보였으므로(1.99M 對 1.99M) 수치 자체는
> **동기 경로 대표값으로 유효**하지만, main 바이너리의 측정은 아니다.

```text
SET-only 처리량        2.27 M ops/s 정상 구간 (60s 창 평균 2.13M)
span                   6.21 µs (p50 5.8 / p99 15.6)
guest busyCPU          25.6 / 30      → guest 전체 ≈ 11.3 µs/op
워커 벽시계 점유        28 ÷ 2.27M = 12.3 µs/op   (7-29의 16.4 µs에서 −25%)
동기 상한 재계산        28 ÷ 6.21 µs(span) = 4.51 M/s — 실측은 그 50%
무결점                 write_fail=0 engine_dead=0 leak=0, 표본 누락 0.0005%
```

위 §0(7-29)과 이 재측정은 **bed·클라이언트 배치·부하 구성이 다르다**
(7-29: 별도 서버 클라이언트 / 7-30: memtier@genie, 구성 파라미터 미기록).
절대값 비교는 금지 규율 그대로이고, 같은 코드 계열에서 점유가 16.4 →
12.3µs로 내려간 것은 §3의 off-CPU 간극(8.7µs)이 **고정 비용이 아니라
공급(클라이언트) 조건에 민감**하다는 신호다 — 이 재측정에서 간극은
12.3 − 11.3 ≈ 1µs 수준으로 줄었다. 규명 시 클라이언트 구성을 함께 기록하고
같은 bed 교대 A/B로만 델타를 주장할 것.

### 0-2. 2026-07-30 pac 1차 A/B — (c) 이전의 첫 실측 (co-located) — **무효**

> **무효 (2026-07-30 20:55).** 세 런 전부 alloc 결함 상태다. 다만 A·B·C가
> **같은 결함을 공유**하므로 "pac이 동기보다 빠르다"는 **부호 판정은 살아
> 있고**, +21%라는 **크기와 절대값은 무효**다. 결함은 SET 경로에 있으므로
> 수정 후 델타가 커질 수도 작아질 수도 있다.

`v3-set-pac` 브랜치(`e424305`)의 publish-at-command 비동기 SET을 동기 경로와
같은 bed에서 3련전으로 비교했다. **클라이언트를 guest 안에 두었으므로**
(memtier가 서버 코어를 잠식) 절대값은 §0·§0-1과 비교 불가이고, 세 런 사이의
우열 판정만 유효하다. 원자료 guest `~/pac-ab-20260730/`.

```text
공통  memtier -t 8 -c 4 --pipeline=64, d64, 1M keys, R:R, distinct-seed, 90s
      서버 -t 28 W24 nqp2 hp22, obwatch 60s 창
```

| run | 바이너리 | 경로 | set/s | Sspan avg/p99 | client avg/p99/p99.9 | busyCPU |
|---|---|---|---:|---:|---:|---:|
| A | cca9807 | 동기 | 1.99M | 6.17 / 15.1 µs | 1.015 / 1.927 / 2.719 ms | 24.1 |
| B | pac-e424305 | **pac on** | **2.41M** | 42.8 / 262.6 µs | **0.834 / 1.583 / 2.271 ms** | 23.1 |
| C | pac-e424305 | pac off | 1.99M | 6.02 / 15.0 µs | 1.011 / 1.935 / 2.815 ms | 23.9 |

- **처리량 +21%**(B 對 C, 단일 바이너리 A/B), **클라이언트 레이턴시 avg −18%
  / p99 −18% / p99.9 −19%**, CPU/op 12.0 → 9.6 µs(**−20%**).
- 정확성: 3런 모두 필수 0 전부 0. pac 218M ops 동안 `ext_pac_fail=0`,
  `ext_pac_fallback=0`.
- **A ≡ C**: cca9807의 동기 경로와 pac 빌드의 동기 경로가 동일 성능 —
  pac 코드가 동기 경로를 회귀시키지 않았다는 확인이자, §0-1 수치를 동기
  경로 대표값으로 계속 쓸 수 있는 근거다.

**Sspan 6 → 43 µs는 성능 악화가 아니라 계측 구간의 이동이다.** 동기 span은
워커가 SET을 잡은 뒤만 재고 워커 차례를 기다리는 큐잉은 구간 밖이다. pac은
그 대기를 (c)(CQE → drain 수거)로 span 안에 들여놓는다. 실제로 클라이언트가
보는 지연은 모든 분위에서 내려갔다. 즉 **이 부하 형상에서 (c) ≈ 36.6 µs avg
/ ~250 µs p99**가 처음으로 정량화됐다 — 깊은 파이프라인(64) + co-located
조건임에 유의. SET에 30 µs급 span 목표를 세운다면 이제 줄일 대상은 drain
수거 주기이고, 그 값이 이 표다.

### 0-3. 2026-07-30 SYNC 배치화 — 1차 목표(5M) 진척 (co-located) — **일부 무효**

> **무효 (2026-07-30 20:55).** 처리량·CPU/op·환산치는 alloc 결함 상태 →
> 재측정. **살아 있는 것은 `prof_write_sync_avg_ns` 성분 실측**(1.90 → 0.32
> µs/op, 상각 계수 63.7)이다 — advise 호출 자체의 비용이고 alloc 경로와
> 무관하며, 배치 크기 스윕의 상각 계수가 설정값과 정확히 일치한 것도 그렇다.
> 아래 표에서 `set/s`·`busyCPU`·`4.85M`·`5.77`·`3.25`는 폐기 대상,
> `상각 계수`·`sync/crypto/xfer` 성분은 유효.
>
> 코드 참조 `2d0290a`는 alloc 수정 위로 rebase되어 **`90f532e`로 대체**됐다
> (`v3-set-pac`). 재측정은 그 위의 `785b308`로 한다.

1차 목표를 **SET-only 5 M ops/s, span < 30 µs**로 설정하고 착수한 첫 항목.
pac이 비동기 구조를 열어 준 덕에 §4의 최대 단일 레버(SYNC_FOR_DEVICE 상각)를
처음으로 적용할 수 있었다. 코드는 `v3-set-pac` `2d0290a`(→ rebase 후
`90f532e`), guest 바이너리 `memcached.pacb-2d0290a`.
원자료 guest `~/pac-ab-20260730/`.

**배치 크기 스윕** (`ext_setq_max`, 같은 바이너리·같은 bed, 각 50 s 창):

| ext_setq_max | set/s | 상각 계수 | Sspan avg | client avg / p99 / p99.9 |
|---:|---:|---:|---:|---:|
| 1 (대조군) | 2.375M | 1.00 | 105.6 µs | 0.858 / 1.631 / 2.655 ms |
| 4 | 2.653M | 4.00 | 109.1 µs | 0.765 / 1.487 / 2.575 ms |
| 16 | 2.795M | 16.0 | 133.7 µs | 0.726 / 1.407 / 1.991 ms |
| 64 | **2.868M** | 63.7 | 236.9 µs | **0.707 / 1.375 / 1.791 ms** |

**+20.8 %**, 결함 0(`ext_pac_fail` = `ext_pac_fallback` = 0). 상각 계수가 매번
설정값과 같다 — 한 pass가 항상 상한만큼의 SET을 담으므로 배치는 도착률이
아니라 **캡에만** 묶여 있다. 클라이언트 지연은 배치를 키울수록 **좋아진다**
(p99.9 −32.5 %): 파이프라인 클라이언트는 어차피 전체 배치를 기다리므로,
배치가 미루는 것은 서버 span뿐이고 종단 지연은 오히려 줄어든다.

**성분 실측** (`ext_setq_max=64`, `EXT_RDMA_PROF=1`):

```text
prof_write_crypto_avg_ns    921 ns   0.92 µs
prof_write_sync_avg_ns      316 ns   0.32 µs   ← 1.90 µs에서 −1.58 (예측 −1.66)
prof_write_xfer_avg_ns     6358 ns   6.36 µs   ← post → CQE. GET과 같은 정의의 span
prof_write_avg_ns        240559 ns 240.6 µs    ← seal → CQE (수락 큐잉 포함)
```

**§5의 최대 레버가 예측대로 실현됐다: SYNC 1.90 → 0.32 µs/op.**

span 두 수의 차이를 혼동하면 안 된다. GET의 게이트 수치(10 M에서 23.7 µs)는
**post 이후**만 재고, SET의 같은 구간은 지금 **6.36 µs**로 30 µs 아래다.
240 µs는 그 앞의 수락 큐잉까지 포함한 다른 양이며, 클라이언트가 서버 처리량의
몇 배를 밀어넣는 포화 상태에서는 Little의 법칙상 필연이다(GET은 그 구간을
애초에 재지 않는다).

**서버 CPU만 분리** (`/proc/<pid>/stat` utime+stime ÷ cmd_set — 클라이언트
CPU 제외. 스크립트 `~/pac-ab-20260730/srvcpu.sh`):

| 워크로드 | server CPU/op | 실측 rate | 28코어 환산 |
|---|---:|---:|---:|
| SET (pac+batch) | **5.77 µs** | 2.82 M/s | **4.85 M/s** |
| GET (같은 바이너리) | 2.52 µs | 4.73 M/s | 11.11 M/s |

**co-located 환산의 보정 계수.** GET의 정본 off-box 실측은 10.35 M인데 위
환산은 11.11 M이다 — **co-located 환산은 약 7 % 낙관적**이다. 같은 보정을
적용하면 SET는 4.85 × 0.93 ≈ **4.5 M/s**가 off-box 추정치이고, 5 M까지
**CPU/op를 약 10 % 더 깎아야 한다**(5.77 → 5.2 µs 수준).

**다음 대상은 SET − GET = 3.25 µs.** 같은 바이너리·같은 bed에서 잰 차이이므로
프로토콜 처리·소켓·이벤트 루프 같은 공통 비용이 상쇄된 순수 SET 고유분이다.
그중 crypto(0.92)와 sync(0.32)는 GET 쪽 대응 비용과 대체로 상쇄되므로, 남는
것은 **stub item 할당 · 원격 loc 할당 · 해시테이블 게시(unlink+link) · 구 loc
반납 · io_pending 할당**이다. 어느 것이 큰지는 미규명 — bpftrace 프로파일이
다음 단계다(워커 스레드 comm은 `mc-worker`다. 프로세스명으로 필터하면 표본이
0이 된다).

### 0-4. 2026-07-30 20:55 — alloc 결함 수정, 측정치 무효화, 이중 게이트

세 가지가 한꺼번에 바뀌었다.

**(1) alloc 결함 수정 (`678e7a3`, genie).** 단계 7b의 재활용 조건이
"LIFO top의 len ≥ 요청 len"이었다. memtier 키 `m-1`..`m-1000000`은 nkey가
3~9로 갈리므로 `rlen`이 7종이고, **약 12%가 이 조건을 놓쳐 페이지 append
경로로** 흘렀다. 게다가 보수적 축소 스탬프가 기록된 len을 단방향으로
내리깎으므로 미스율은 시간이 갈수록 **올라간다**. 페이지는 회수 기구가 없어
(compaction 없음, `free_pages` 미보충) 159 MB 라이브셋에 4 GiB / 64페이지를
전소시키고, 그 뒤 모든 SET이 `NOT_STORED`였다 — 쓰기 부하 약 7분.
memtier는 이를 `NOT_STORED` + `response parsing failed`로 보고하는데
**두 사건이 아니라 하나**다.

수정: 물리 슬롯 간격을 `slot_size` 균일로 바꿔 free list를 완전 대체
가능하게 만들었다. 기록되는 `out->len`은 여전히 호출자의 실제 len이라 stub과
seal이 일치한다(불일치하면 GET이 1바이트 더 읽어 GCM이 영구 실패). 비용은
라이브 객체당 `slot_size − len` 바이트. 아울러 `extstore_alloc` 실패가 아무
카운터도 올리지 않아 **막힌 store가 stats에서 보이지 않던 것**도 고쳤다
(`extstore_write_failures`는 RDMA WRITE 완료 오류만 센다) — 신규
`extstore_alloc_failures`.

배포 검증(프리로드 1M, `785b308`):

```text
extstore_pages_free      60      (1M item에 4페이지)   ← 수정 전 64장 전소
extstore_alloc_failures   0
ext_pac_fallback          0
curr_items        1,000,000
```

**(2) 무효화 원장.** 결함이 SET 경로 한복판이므로 7-30의 SET 측정은 전부
"12%가 느린 경로 + 진행 중인 소진" 상태였다.

| 무효화 | 값 | 재측정 |
|---|---|:--:|
| off-box SET-only | 2.85 M @ 8.42 µs/op | ✅ |
| off-box 1:9 혼합 | 8.81 M @ 3.17 µs/op | ✅ |
| co-located SET 서버 CPU/op (§0-3) | 5.77 µs | ✅ |
| SET 고유 비용 (§0-3) | 3.25 µs (5.77 − 2.52) | ✅ |
| co-located pac 델타 (§0-2) | +21% | ✅ (부호는 유효) |
| 동기 재측정 (§0-1) | 2.27 M @ 6.21 µs | ✅ |
| GET-only | 2.72 µs/op | ❌ 불필요 — GET은 alloc을 안 탄다 |

수정으로 SET이 **빨라졌을 가능성이 크다**(느린 경로 12% 제거). 5M·10M 판정
산수는 재측정 뒤에 다시 세운다.

**(3) 목표가 이중 게이트가 됐다.** 관리자 지시로 **GET-only도 혼합과 동시에
10M / span < 30 µs**를 충족해야 한다. 이 변경으로 권고 하나가 철회된다 —
`ext_drain_spin` 상향(drain을 굵게 해 SYNC 상각을 올리는 것)의 근거였던
span 여유 5.06 µs는 **혼합 런의 GET span**(24.94)에서 나온 값인데, 이제
구속 조건은 **GET-only의 26.7 µs = 여유 3.3 µs**다. drain을 두 배로 굵게
하면 배치 내 대기가 그만큼 늘어 3.3 µs를 넘긴다. 잘못된 예산을 인용했다.

이중 게이트에서 GET 쪽에 남는 레버는 사실상 하나다. GET CPU 2.72 µs의 구성:

```text
crypto (복호)          0.60 µs    하한
sync (SYNC_FOR_CPU)    0.544 µs   = 지연 5.49 ÷ advise당 10.1건
나머지                 ~1.58 µs   프로토콜·소켓·해시·iov (7단계 기적용)
```

- `ext_drain_empty_max`는 **이미 기각된 가설**(OPTIMIZATION_HISTORY 부록:
  "poll 4.4회/op뿐, spin=1로도 무변화"). 지금도 GET당 4.18회로 같다.
- drain 굵게 = span 초과. **불가**.
- **sync ioctl 제거만이 CPU와 span을 동시에 낮춘다** — 유일하게 두 게이트와
  양립하는 레버이고, 경로는 coherent-MR 커널 트랙이다(1회 실패 이력: 모듈
  세트 적용 시 GCM 전량 실패 = SWIOTLB를 실제로 우회하지 못함).
  애플리케이션 코드 밖의 작업이다.

**다음 행동**: genie가 `785b308`로 GET-only / SET-only / 1:9 재측정.
그 결과가 §0-1~§0-3을 대체한다.

### 0-5. 2026-07-31 정본 — **현행 수치는 이것이다**

빌드 `771ca34068c7609936b2e58a`(`ce92044`). off-box, fresh boot, obwatch 창.

```text
SET-only 처리량        4.241 M ops/s        (7-29 기준선 0.311 M 대비 13.6배)
C_set                  6.63 µs/op           (26.9 → 6.63, 4.1배 절감)
SET span               7.63 µs (SET-only) / 14.51 µs (1:10 혼합)
busyCPU                28.0 / 30            ← 포화. 오래 미해결이던 유휴가 사라졌다
1:10 혼합 총 처리량     10.195 M ops/s       GET span 16.03 / SET span 14.51 → PASS
```

**§0의 두 상한은 둘 다 무너졌다.** "동기 구조 하드 상한 5.57M"은 pac이
동기 구조 자체를 없애 무의미해졌고, "CPU 상한의 45%밖에 못 낸다"던 미달은
전역 `e->mutex` 경합이었다(§4의 새 항목).

crypto·sync 성분도 바뀌었다:

```text
             7-29        7-31
crypto      1.05 µs     0.82 µs      GCM 1회 키잉
sync        1.90 µs     0.013 µs     coherent MR — 사실상 소멸
```

### 0-6. SET에 남은 비용 (2026-07-31 perf, `mc-worker`)

| 항목 | 비중 | 판정 |
|---|---:|---|
| `do_item_unlink`+`do_item_link`+`item_acct_add` | 16.3% | 덮어쓰기마다 새 item 할당·link·옛 것 unlink. **손대지 않기로 함** |
| `storage_store_item_pac` | 7.80% | pac 진입점 |
| `assoc_find` | 5.52% | GET의 2.7배. **미귀속**(프레임 포인터 없음) |
| EVP + `ext_crypto_seal` | ~5.4% | 걷어냄 |
| `extstore_alloc` | 1.85% | magazine 수정 후 잔여 |

`native_queued_spin_lock_slowpath` 13.21%는 **사라졌다**(§4).

item 재할당 16.3%를 손대지 않는 이유: memcached 코어가 item을 불변으로 두어
독자가 락 없이 읽게 하는 설계다. 제자리 갱신은 그 전제를 무너뜨린다.

### 0-7. 그리고 레버는 이제 SET이 아니다

**1:10 혼합에서 SET은 CPU의 21.9%뿐이고 GET이 78.1%를 쓴다.** SET이 op당
2.8배 비싸다는 사실이 "SET이 병목"처럼 보이게 하지만, 비중을 곱하면 같은 1%
절감의 가치가 **GET : SET = 3.6 : 1**이다. 실제로 마지막 3.4%를 넘긴 것은
GET 쪽 절감이었다(상승분의 105%).

그렇다고 SET 작업이 헛일이었던 것은 아니다 — magazine 수정 없이는 `C_set`이
7.71에 묶여 9.846 M에서 멈춘다. 상세는
[`SET_CAMPAIGN_HANDOFF.md`](SET_CAMPAIGN_HANDOFF.md) §16.

## 1. 타임라인 한눈에

워커 스레드 하나가 SET 1건을 처리하는 전 구간. ★는 SET에만 있는 비용,
◆는 전역 공유 자원(경합 가능 지점).

```text
 단계                        코드                                  자원/락
────────────────────────────────────────────────────────────────────────────
 1  소켓 이벤트→읽기         event_handler → try_read_network       워커 전용 rbuf
 2  명령 파싱                proto_text.c:1224 → :775               —
 3  값 수신 item 할당        proto_parser.c process_update_cmd_start  item magazine(워커 전용)
 4  값 바이트 수신           conn_nread (c->ritem으로 직접)          —
 5  해시+버킷 락             thread.c:1012-1014 store_item          ◆ item_lock[hv]
 6  기존 키 조회             do_store_item → assoc_find             (5의 락 아래)
 7  원격 저장(인라인)        storage.c:559 storage_store_item        아래 7a~7h
 7a   hdr stub 할당          do_item_alloc                          item magazine
 7b   원격 슬롯 할당         extstore_alloc                         loc magazine(워커 전용) → ◆miss ~12%는 엔진 뮤텍스
 7c   staging 슬롯           extstore_worker_staging_get            워커 전용 비트맵
 7d   AES-GCM 봉인           ext_crypto_seal                        ★ 1.05 µs
 7e   window 대기            outstanding≥W면 drain                  (평시 0회전)
 7f   SYNC_FOR_DEVICE        extstore.c:851 ibv_advise_mr           ★ 1.90 µs, SET당 1회
 7g   WRITE post             extstore.c:868 ibv_post_send           QP 라운드로빈
 7h   ★자기 CQE busy-wait    storage.c:661 drain 루프               ★ xfer 2.48 µs 점유
 8  게시                     memcached.c:1663 item_replace           (5의 락 아래) ◆lru_locks
 9  구 원격 슬롯 해제        memcached.c:1666 storage_delete         loc magazine
10  응답                     out_string("STORED") → conn_mwrite      워커 전용 resp
11  전송                     event loop → sendmsg                    파이프라인 iov 묶음
```

GET과의 구조 차이는 7h 하나로 요약된다: GET은 7 시점에 요청을 큐에 걸고
**즉시 반환**(suspend)하여 워커당 W=24건이 wire에 동시에 떠 있지만, SET은
자기 CQE까지 워커를 점유하므로 **워커당 1건**이다.

## 2. 단계별 상세

### 1~2. 이벤트 → 파싱

libevent가 소켓 가독 이벤트를 올리면 `try_read_network`가 워커 전용 rbuf로
`read()`하고, `proto_text.c`의 디스패치가 `"set"`을 찾아
`process_update_command`(proto_text.c:775)로 보낸다. 파이프라인이면 rbuf 안에
여러 명령이 한 read로 들어온다.

- cross-request prefetch(⑦, proto_text.c:398)는 `memcmp(cont, "get ", 4)`로
  **GET만** 본다. SET 키에 대한 확장(69421ff)은 v3-set-10m에 있고 미측정.

### 3~4. 값 수신용 item 할당 + 수신

`process_update_cmd_start`가 key/flags/exptime/vlen을 파싱하고 **값을 받을
실제 item을 먼저 할당**한다. 할당은 step ①의 워커 전용 item magazine을
먼저 치고(items.c:150, 깊이는 클래스당 `ITEM_MAG_MAX_BYTES` 64KB로 유계),
비면 `slabs_alloc_batch`로 refill — 이때만 전역 `slabs_lock`을 잡는다.
실패 시 자기 magazine 전량 spill 후 1회 재시도(items.c:164-170, A-3).

`c->ritem = ITEM_data(it)`(proto_text.c:790)로 소켓 바이트가 item 메모리로
직접 들어간다(rbuf에 이미 있으면 memcpy 1회). 별도 중간 버퍼 없음.

### 5~6. 버킷 락 + 기존 키 조회

`store_item`(thread.c:1009)이 `hash()` 후 `item_lock(hv)`을 잡고
`do_store_item`에 들어간다. **이후 게시(8)와 구 슬롯 해제(9)까지 전부 이 락
아래에서 실행된다** — 7의 원격 왕복(승인 대기 포함 ~16µs 점유)도 마찬가지다.
같은 버킷으로 향하는 다른 워커의 GET/SET은 이 구간 동안 블록된다.
hashpower=22(4M 버킷, 1M 키)라 무관 키의 버킷 충돌 확률은 낮지만,
item_lock은 버킷보다 굵은 granularity(기본 `item_lock_hashpower`)임에 주의.

`do_store_item`은 `do_item_get`(assoc_find)으로 old_it을 찾고, NREAD_SET이면
무조건 `do_store = true`(memcached.c:1646-1648).

### 7. storage_store_item — 원격 저장 인라인 (storage.c:559)

SET CPU의 46.6%(step ③ 후 프로파일 1위)가 이 함수다. 순서대로:

**7a. hdr stub 할당** — `do_item_alloc(key, nkey, flags, exptime,
sizeof(item_hdr))`. 로컬에 남는 것은 key + 48B item_hdr뿐이다(값은 원격).
item magazine 적용 대상이라 평시 전역 락 없음.

**7b. 원격 슬롯 할당** — `extstore_alloc`(extstore.c:368). 두 층이다.

1. **워커 전용 loc magazine**(extstore.c:378, 깊이 `ext_loc_mag_depth` 기본
   64). pop 조건은 **정확히 같은 len**(A-5) — 축소 재사용을 허용하면 슬롯이
   예전 큰 len으로 청구된 채 `out->len`만 작아지고, 나중 `free_loc_global`이
   작은 len만 빼주므로 `bytes_used`가 차이만큼 영구 표류한다(전역 경로는
   free에서 감산·alloc에서 재가산해 균형이 맞지만 magazine엔 그 쌍이 없다).
2. **miss면 전역 경로**(엔진 뮤텍스). free list는 `678e7a3` 이후 **완전
   대체 가능**하다 — 물리 슬롯 간격이 `slot_size` 균일이라 어떤 빈 슬롯이든
   어떤 요청이든 담는다(`len > slot_size`는 함수 입구에서 이미 거절).
   기록되는 len만 호출자의 실제 len이다. free list가 비면 페이지 append,
   페이지도 없으면 `extstore_alloc_failures`++ 후 실패 = 클라이언트
   `NOT_STORED`.

반납 시 구조 검증 실패분은 전역 경로로 격리된다(A-9).

> **초판의 "고정 크기 워크로드라 히트율 100%"는 틀렸다.** memtier 키
> `m-1`..`m-1000000`은 nkey가 3~9로 갈려 `rlen`이 7종이고, 분포상 약 90%가
> 한 값(nkey 8)에 몰리므로 **magazine 미스가 약 10~12%** 남는다 —
> genie가 계측한 그 12%다. 결함 수정은 미스의 *귀결*(페이지 소진)을 없앴을
> 뿐 **미스 자체는 그대로**다. 즉 SET 8~9건 중 1건은 지금도 엔진 뮤텍스를
> 잡는다. magazine을 전역 경로처럼 대체 가능하게 만드는 것(= 균일 슬롯을
> 전제로 len 조건을 풀고 `bytes_used` 회계를 짝맞추는 것)은 **미검증
> 후보**다 — §4 원장에 올렸다.

**7c. staging 슬롯** — `extstore_worker_staging_get`(extstore.c:822),
워커 전용 비트맵에서 pop. 워커당 슬롯 수 = `write_slots/nworkers`(256/28=9,
extstore.c:713). 동기 경로는 동시 1건이라 1개면 족하다 — 9개는 여유.

**7d. AES-GCM 봉인** — `ext_crypto_seal`이 item 전체를 staging 슬롯에
암호화 복사. **1.05 µs/op** (span 계측 시작점, `EXT_RDMA_PROF=1`).
AAD에 hv/page/offset/version이 들어가 위치 위조를 막는다.

**7e. window 대기** — `outstanding >= g_worker_window`면 drain(storage.c:653).
동기 경로는 outstanding이 항상 0 또는 1이라 **이 루프는 사실상 0회전**이다
(window 대기는 GET/SET 혼합 시 GET READ가 window를 채울 때만 의미).

**7f. SYNC_FOR_DEVICE** — `extstore_worker_post_write`(extstore.c:838) 안에서
`ibv_advise_mr(..., SYNC_FOR_DEVICE, FLUSH, &sg, 1)`(extstore.c:851).
SEV에서 NIC이 읽기 전 staging의 평문 캐시라인을 밀어내는 ioctl로,
**1.90 µs — SET당 1회, 상각 없음**. 대조: GET은 drain 한 번에 평균 13건의
READ를 SYNC_FOR_CPU **1회**로 묶어 op당 0.34µs로 상각한다. 이것이
`SET_10M_REQUIREMENTS.md`가 지목한 최대 단일 레버(브랜치의 756e45c가
이벤트 루프 pass 단위 배치화를 구현했으나 **비동기 큐 전제 + 미측정**;
동기 경로는 post 직후 자기 CQE를 기다리므로 배치로 묶을 "이웃 쓰기"가
같은 워커에 존재하지 않는다 — 동기 구조에서는 이 레버를 당길 자리가 없다).

**7g. WRITE post** — signaled RDMA WRITE 1건, QP 라운드로빈(nqp=2).
`wr_id = &io`(A-2: io/wait는 `_Thread_local` — 엔진 사망 경로에서 스택
프레임과 함께 죽지 않도록).

**7h. 자기 CQE busy-wait** — storage.c:661:

```c
while (!wait.done) {
    spins++;
    if (extstore_worker_drain(w, 32) < 0) break;   /* 음수 = 엔진 사망 (A-1) */
}
```

wire 왕복 **2.48 µs** 동안 `ibv_poll_cq`를 반복한다. spin 횟수는
`ext_worker_write_spins/cmd_set`으로 상시 관측 가능(카운터는 ③′에서 루프 밖
배치 반영으로 바뀜 — 회전마다 전역 _Atomic RMW를 치면 28워커가 캐시라인
하나를 놓고 경합해 그 자체가 비용이었다). 완료 후 staging 반납은
`wait.done` 조건부(A-2) — 미완료면 NIC이 DMA-read 중일 수 있어 의도적 누수.

**여기가 동기 구조의 정의 지점이다.** 이 루프가 워커를 붙잡는 한 워커당
동시성 1, 상한 5.57M. GET처럼 suspend하려면 STORED-after-CQE 계약(아래 §5)
때문에 응답 지연 기구가 필요하고, 그 첫 시도(연결 파킹)는 실측 기각됐다.
두 번째 시도인 pac(`v3-set-pac`)이 이 루프를 GET의 완료 수거 구조로
대체했고 1차 A/B에서 +21%를 냈다(§0-2) — 게시는 8~9 그대로 두고 응답만
미루므로 아래 단계들의 순서·락 구조는 바뀌지 않는다.

### 8~9. 게시 + 구 슬롯 해제 (여전히 item_lock 아래)

`item_replace(old_it, hdr_it, hv, cas_in)`(memcached.c:1663) →
`do_item_unlink(old)` + `do_item_link(hdr_it)`. step ③ 이후 curr_items 등
카운터는 원자 갱신(items.c:387-392)이고, `item_stats_sizes`/`item_acct`도
원자화됐다(items.c:338-340 — stub이 전부 같은 클래스라 `lru_locks[id]`가
사실상 전역 락으로 동작했던 지점). 남은 lru_locks 사용처는 OOM 카운터 등
저빈도 경로뿐이다.

old가 원격 stub이면 `storage_delete`(memcached.c:1666)가 구 loc을 loc
magazine으로 반납한다(검증 통과분만, A-9). 신규 키면 `do_item_link`만
(memcached.c:1714 경로).

### 10~11. 응답

`out_string(c, "STORED")` → resp iov에 기록 → `conn_mwrite`. 같은 이벤트
루프 pass에서 파이프라인 응답들이 iov로 묶여 `sendmsg` 소수 회로 나간다.
GET과 달리 여기엔 SET 특유 비용이 없다.

## 3. 비용 회계 — 7.29 µs는 어디에 있고, 없는 8.7 µs는 무엇인가

step ③′ 시점의 상태:

| 계정 | 값 | 비고 |
|---|---:|---|
| 프로세스 CPU/op | 7.29 µs | utime+stime ÷ ops |
| ├ storage_store_item | ~46.6% ≈ 3.4 µs | 프로파일 1위. 7d~7h(봉인+sync ioctl+spin-poll) |
| └ 나머지 ≈ 3.9 µs | 파싱·item 할당·해시·link/unlink·응답·syscall | 개별 미분해 |
| 워커 벽시계 점유/op | ~16 µs | SET 진입~복귀 |
| **점유 − CPU ≈ 8.7 µs** | **미규명** | CPU를 안 쓰는 대기 — 아래 참조 |

이 8.7µs가 실측(1.71M)이 CPU 상한(3.84M)의 45%에 그치는 이유의 실체이고,
**현재 귀속되지 않은 최대 항목**이다. spin-poll은 CPU를 태우므로 여기 못
들어간다. 후보는 futex로 잠드는 구간(item_lock 경합, magazine miss 시
slabs_lock, loc magazine miss 시 엔진 뮤텍스)과 스케줄링 이탈인데, 어느
것도 프로파일로 확정된 바 없다. v2의 GET 캠페인에서 같은 모양의 질문
("점유 90µs vs span 5.4µs")을 규명하지 않고는 다음 단계 예측이 전부
빗나갔다(`GET_SET_CONCURRENCY.md` §4). **여기를 먼저 재는 것이 순서다** —
off-CPU 프로파일(예: sched switch 스택)이 도구다.

> **2026-07-30 갱신 (수치는 무효, 결론은 유효).** 이 간극은 고정 상수가
> 아니다. §0-1에서 공급이 좋아지자 줄었고, §0-2의 pac A/B에서 더 줄었다 —
> 두 측정 모두 alloc 결함 상태라 **크기는 인용 금지**지만, 세 관측이 같은
> 방향을 가리키므로 방향성 결론은 남는다: 간극의 일부는 7h의 동기 대기가
> 만들고(pac이 제거), 나머지는 클라이언트 공급 조건에 딸린다.
> off-CPU 프로파일은 여전히 필요하지만 **`785b308` 재측정 후, pac 적용
> 상태에서** 재는 것이 맞다 — 제거된 항목을 다시 귀속시키는 낭비를 피한다.
>
> 이 간극에 **7b 미스 12%가 섞여 있었다**는 것이 새 정보다. 엔진 뮤텍스
> 대기는 CPU를 태우지 않으므로 정확히 "점유 − CPU"에 들어간다. 재측정에서
> 간극이 줄어든다면 그 일부가 이것이다.

## 4. 이미 당겨졌거나 기각된 레버 (재발명 방지 목록)

| 레버 | 상태 | 결과/근거 |
|---|---|---|
| 워커 전용 item magazine (①) | **적용** | +47%, slabs_lock 46.7%→해소 |
| 워커 전용 loc magazine (②) | **적용** | +88%, 엔진 뮤텍스 해소 |
| 카운터 원자화 (③) | **적용** | +80%, STATS_LOCK/lru_locks 해소 |
| spin 카운터 배치화 (③′) | **적용** | +2.3% |
| 비동기 SET + 연결 파킹 | **실측 기각** | SET-only 1.0M(−40%), 혼합 GET 반토막. 상한 = 연결수÷파킹시간 |
| CQ 인터럽트 주도 진행 | **기각** | SET당 drain 139k회 → 29 set/s. 인터럽트는 idle fallback로만 유효 |
| SYNC_FOR_DEVICE 배치화 | 미측정 (브랜치 756e45c) | 비동기 큐 전제. 동기 경로엔 묶을 이웃 쓰기가 없음 |
| set_pending_t 풀링 | 해당 없음 (비동기 전용) | |
| SET 키 prefetch ⑥⑦ | 미측정 (브랜치 69421ff) | 동기 경로에도 이식 가능. "죽을 확률 최대" 분류 |
| **publish-at-command (pac)** | **구현 완료, 실측 재판정 대기 (브랜치 `v3-set-pac`)** | co-located A/B에서 동기 대비 우세(부호 확정). **크기(+21%)는 alloc 결함으로 무효** — `785b308`로 재측정 (§0-2·§0-4) |
| pac: staging 슬롯 대기 | **적용 (결함 수정)** | 한 pass의 파이프라인 SET이 워커당 슬롯(9)을 넘으면 10번째부터 NOT_STORED — 회수까지 자기 CQ를 걷도록 수정 |
| **SYNC_FOR_DEVICE 배치화** | **적용 (`90f532e`, ex-`2d0290a`)** | **sync 1.90 → 0.32 µs/op** — 성분 실측은 유효. 처리량 델타(+20.8%)는 무효 → 재측정 (§0-3). pac이 전제를 충족시켜 처음 가능해졌다 |
| **extstore_alloc 재활용 조건** | **결함 수정 적용 (`678e7a3`)** | 미스 12% → 페이지 append → 4 GiB 전소 후 전 SET `NOT_STORED`(7분). 균일 슬롯으로 free list를 완전 대체 가능하게. 신규 `extstore_alloc_failures` (§0-4) |
| **seal을 flush로 지연** | 구현, 미측정 (`785b308`, knob 뒤) | enqueue가 아니라 flush에서 봉인 — 재측정 대상 바이너리에 포함돼 있다 |
| loc magazine을 대체 가능하게 (len 조건 해제) | **미검증 후보** | 균일 슬롯이 전제를 이미 만들어 뒀다. 남은 미스 ~12%(= SET당 0.12회 엔진 뮤텍스)를 없앤다. `bytes_used` 회계 짝맞춤이 조건 (§2 7b) |
| `ext_drain_spin` 상향 (SYNC 상각) | **철회** | 근거로 쓴 여유 5.06 µs는 혼합 런 GET span에서 나온 값. 이중 게이트에서 구속은 GET-only 26.7→30 µs = 3.3 µs이고 drain을 굵게 하면 초과 (§0-4) |
| SET 고유 비용 (stub/loc 할당·게시·반납) | **미규명 — 다음 대상, 값은 재측정** | 3.25 µs(5.77−2.52)는 alloc 결함 상태의 수치라 폐기. bpftrace 프로파일은 `785b308` 재측정 후에 (§0-4) |

### 4-1. 2026-07-31에 추가된 항목

**당겨진 것**

| 레버 | 효과 | 비고 |
|---|---|---|
| coherent data MR | `write_sync` 1,996 → 13 ns, `C_set` 9.97 → 7.71 µs | 커널 패치. `EXT_DISABLE_COHERENT_MR=1`이 대조군 |
| loc magazine 스캔 | SET-only 2.640 → 4.121 M, busyCPU 23.3 → 28.0 | 최상단 대신 배열 스캔. 정확한 len 제약은 유지 |
| GCM 컨텍스트 1회 키잉 | `seal` 986 → 817 ns | `seal`/`open` 공유이므로 GET에 10배로 실린다 |

**기각 / 불가**

| 레버 | 사유 |
|---|---|
| SET 도어벨 배칭 | `ext_setq_max=1`이라 묶을 것이 없고, 2 이상은 span 계약을 깬다(64에서 SET span 255 µs). coherent MR에서는 상각할 SYNC도 없다 |
| item 제자리 갱신 | memcached의 item 불변 전제(락 없는 독자)를 무너뜨린다. 이득 16.3% 대비 위험이 나쁘다 |
| magazine의 len 제약 완화 | push 때 회계를 빼지 않으므로 다른 len으로 pop하면 `bytes_used`가 표류하고, `free_loc_global`이 잔액 부족을 `slot_acct_leak`으로 보고 **슬롯을 버린다**. 통계 오차가 아니라 실제 누수다 |

> **`sev_es_ghcb_hv_call`을 비용으로 읽지 말 것.** 프로파일에 1.32%로 뜨지만
> 호출자가 `__perf_event_task_sched_out → amd_pmu_disable_all →
> native_read_msr`다 — perf 자신의 PMU MSR 접근이 SEV에서 트랩하는 것이고,
> 관측하지 않으면 존재하지 않는다.

## 5. 바꿀 수 없는 계약 (설계 제약)

1. **STORED-after-CQE**: WRITE CQE 확인 전에 STORED를 보내면 내구성 깨짐
   (`V2_CODE_SPEC.md`). 응답 시점 제약이지 대기 방식 제약이 아니다 —
   비동기화 자체는 허용된다.
2. **연결 내 순서**: 같은 연결의 `set k v1; set k v2`, `set k; get k`는
   순서 보장. 연결 파킹 없이 이를 지키려면 게시를 명령 시점에 해야 한다
   (= publish-at-command). 게시가 CQE보다 앞서는 순간 read-during-write
   창이 열리고, 혼합 워크로드의 badcrc 재시도(관측 도구 obwatch의 err
   컬럼)가 그 창의 실측치다.
3. **eviction 없음**: 할당 실패는 곧 클라이언트 에러. 메모리를 숨기는
   최적화(magazine류)는 항상 spill 경로를 함께 설계해야 한다(A-3 교훈).

## 6. 관측 지점

```text
EXT_RDMA_PROF=1            span 계측 (Sspan = encrypt 시작 → SYNC → WRITE CQE)
                           주의: SET span은 window 대기 포함 — GET span과 정의가 다르다
stats:
  ext_worker_write_spins   busy-wait 총 회전수 (÷cmd_set = SET당 CQ 폴링 횟수)
  ext_worker_drain_*       drain 호출/empty 횟수
  ext_loc_mag_depth        loc magazine 깊이 (0 = off, A/B용)
  ext_slot_acct_leak       loc 검증 격리 건수 (A-9)
  extstore_alloc_failures  원격 슬롯 할당 실패 = store 만원, SET이 NOT_STORED
                           (678e7a3 신규. 이전에는 막힌 store가 stats에서
                            보이지 않았다 — write_failures는 RDMA 완료 오류만 센다)
  extstore_pages_free      남은 페이지. 쓰기 부하 중 단조 감소하면 누수다
                           (1M item 정상값 = 4장 사용, 60장 잔여)
  ext_pac_fail/_fallback   pac 경로 실패·동기 폴백 (브랜치 전용)
tools/obwatch.sh           get/set rate, span avg/p99, correctness footer
프로파일                    -fno-omit-frame-pointer 빌드 + "첫 해석 프레임" 귀속
                           (libc 심볼 없음 주의, SET_COST_ATTRIBUTION.md §1)
```
