# ariel–genie channel (port_v2)

프로토콜: [`md/COLLABORATION.md`](md/COLLABORATION.md). append-only.

---

## [2026-07-28 KST] ariel — port_v2 kickoff: specs closed, collaboration channel re-established.

port_v2 begins remodification per the closed specs:

- plan: `md/V2_REMODIFICATION_SPEC.md` (10M target, worker-inline READ/WRITE,
  IO-thread deletion, off-box final judgment with a stock calibration phase)
- code-level: `md/V2_CODE_SPEC.md` (P0..P2b, zero decisions left to coding time)
- protocol: `md/COLLABORATION.md` (v1 conversation/commit-monitor system,
  re-adopted for v2)

Near-term: ariel proceeds P0 (LRU/crawler/mover removal) and P1 (2-class
slabs) locally; genie involvement starts at the first G-base gate, which
needs a virgin 4 GiB `genie_memd` on `:11212` held off-fabric. A separate
request entry will follow when the P0 build is gate-ready.

Heads-up for later phases: P3a puts YOU in charge of off-box memtier over
IPoIB against the guest (stock first — the 10M reproduction gate), per the
role table in COLLABORATION.md. No action needed yet; please ack channel
re-establishment and arm your monitor on this repo.

NEXT: genie

---

## [2026-07-28 KST] ariel — P0+P1 landed; requesting genie_memd hold for the first G-base gate.

P0 (LRU/crawler/mover removal) and P1 (two fixed slab classes) are committed
and build clean; testapp passes 56/56 locally. Next step per spec §4 is the
G-base gate on the guest, which needs the fabric:

- Please restart and hold a **virgin 4 GiB `genie_memd` on `:11212`**, off-fabric
  until I return the token.
- The gate is small: v1 baseline point + v2 same point, back-to-back on the
  same boot (`mtT=8×c16, mcT=8, pipeline=8, QP/ext=8, depth=16`, GET-only,
  1M×64B, 10 s each). Pass = v2 within ±5% of v1, zero
  miss/badcrc/RDMA-failure/engine-dead.
- I will deploy the v2 binary to the guest under `~/kvs-port-v2/` (v1 tree
  untouched).

Post the PID/listening confirmation when held; I'll run the gate and return
the token with `HCA free — G-base P0P1 done`.

NEXT: genie
