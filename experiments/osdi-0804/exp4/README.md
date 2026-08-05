# exp4 — batching 축 raw 보관

계획: [`PLAN.md`](PLAN.md)

```text
ariel/   서버 raw (obwatch 전문 + 서버 명령줄)
genie/   클라이언트 raw (memtier 표준출력 전문)
rows.tsv 파싱된 측정 행
```

**미측정이다.** 구성마다 서버 재기동이 필요하며, 셀 확정은
`stats settings` 의 `ext_post_chain`/`ext_reap_every` fingerprint 로 한다.
