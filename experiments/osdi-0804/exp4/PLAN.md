# exp4 — batching 축 (`ext_post_chain` / `ext_reap_every`)

질문 셋: ① 배칭 이득 곡선(chain 1→16) ② 유효 체인 = min(chain, reap) 검증
③ **span 과 client latency 가 같은 노브에 반대 부호** — ③ 이 논문 포인트다.

## 셀 — 10 구성 × 3 워크로드 + 저부하 4 = 34 부하 (각 30초)

```text
축 1   E4-C{1,2,4,8,12,16}    reap=8 고정                       6 구성
축 2   E4-R{1,2,4,12}         chain=8 고정                      4 구성
       (E4-C8 = E4-R8 = 운영점, 한 번만)
워크로드  W1(0:1) / W2(1:9) / W3(1:0) 전부 — W3 생략 금지 (관리자 원칙)
저부하    E4-LO-{c1,c8} × pipe=8, W1/W2                          4 부하
서버   구성마다 재기동: -o ext_post_chain=<c>,ext_reap_every=<r> (그 외 운영값)
       셀 확정 = stats settings fingerprint
부하   공통 규약 그대로 (pipe=256, 저부하 셀만 pipe=8)
기록   전 셀: ops, client avg/p50/p99, span avg/p50/p99, admit/xfer/crypto/sync/ret, busy
```

**2026-08-02 블록 1 데이터(chain 스윕)는 본 그림에 재사용하지 않는다** —
계측 결함(p99=0·버킷 포화) 수정 전 바이너리다. 예측 앵커로만 쓴다. 램프
보정(+0.16%p)은 σ 아래라 앵커 대조에도 얹지 않는다.

## 예측 (사전 등록, ±2σ)

```text
c1    GET ≥ 10 M / span 18~19 (외삽 검증) / MIX < 10 M 재현 (계약 회랑의 존재 이유)
c12   GET span > 30 재현
c16@r8 ≈ c8@r8 (2% 안)          min(chain,reap) 모형. 갈리면 반증 — 그것도 결과
r1    v2 급증 (수거가 pass 끝으로 후퇴) — 미측정 축
client L  chain 에 단조 감소     span 과 반대 부호. 동률이면 ③ 기각
저부하    배칭이 span 만 해치고 처리량을 못 산다 (V4_RESULT §3-3 관찰의 확정)
```

## 그림

```text
(a) x=chain: 좌축 X, 우축 span avg + client avg 겹침 → ③ 교차 부호
(b) throughput-latency 산점, chain 파라미터 (exp2a 와 같은 형식)
```
