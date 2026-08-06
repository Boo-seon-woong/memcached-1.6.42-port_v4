# exp3 — 값 크기 (슬롯 256 불변, 수용 상한까지)

관리자 결정: 슬롯을 키우지 않는다. 그림은 XSTORE Fig.16a / SMART Fig.14 형태.

## 상한 — 계산 155 B(키 12 B), 실측 탐침으로 확정

`rlen = ITEM_ntotal + 28(crypto) ≤ 256` (extstore.c:416). 키 12 B 기준 155 B.

```text
탐침 (본 셀 전, 각 30초 GET-only)
  V-PROBE-144:  -d 144 프리로드+부하 → stats ext_pac_fallback
  == 0 이면 V-PROBE-152 한 번 더.  상한 CAP = fallback=0 인 최대 실측값
```

> `storage.c:915` 는 초과 시 **조용히 로컬 슬랩으로** 떨어진다
> (`g_pac_fallback++` 후 동기 저장). 죽지 않으므로 **셀마다 fallback=0
> 확인이 게이트다** — 빠뜨리면 RDMA 를 안 타고 좋은 수치가 나온다.

## 셀 — 5 크기 × 3 워크로드 = 15 부하 (각 30초)

```text
V{16,32,64,128,CAP}-{GET,MIX,SET}     MIX=1:9
서버   운영값 고정 (재기동 불필요). 크기 바꿀 때마다 flush + 1M×d 프리로드
부하   공통 규약에서 -d 만 오버라이드
게이트 셀마다 ext_pac_fallback=0, err5=0, hit 100%
```

64 B 열은 기존 캠페인 전체와의 접점 — 운영점 수치와 ±3% 안이어야 bed 정상.

## 결과

→ [`RESULTS.md`](RESULTS.md) — 상한 152 B, `CPU/op = 2.00 µs + 4.05 ns/B`

## 예측 (사전 등록)

```text
xfer 는 크기에 완만 (256 B 슬롯 단위 전송 — 16 B 도 슬롯 하나)
crypto 는 크기 비례 (GCM 이 실바이트 처리)
→ span 기울기는 crypto 몫. 처리량은 CAP 까지 완만 하락 예상.
   급락하면 그 지점이 결과다 (닫지 않는다)
```
