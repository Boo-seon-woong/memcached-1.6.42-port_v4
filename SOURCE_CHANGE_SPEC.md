# memcached 1.6.42 → RDMA remote-memory port 소스 변경 명세

기준일: 2026-07-27
기준 commit: `597fc83`
stock tree: `../memcached-1.6.42/`
port tree: 이 디렉터리

이 문서는 구현 전 설계안을 보존하지 않고 현재 source가 실제로 수행하는 동작만
기록한다. 변수와 knob의 정의는 [`GLOSSARY.md`](GLOSSARY.md)에 있고 여기서
반복하지 않는다.

## 1. 변경 범위

이 포트는 client↔memcached TCP protocol을 RDMA로 바꾸지 않는다. memcached
worker, parser, hash, slab, LRU는 유지하고 extstore backend를 flash에서
encrypted remote memory로 교체한다.

| stock extstore | 현재 port |
|---|---|
| RAM item을 background thread가 flash page로 이동 | 성공한 SET 전에 remote WRITE 완료 |
| `pread`/`preadv`/`pwrite` | one-sided RDMA READ/WRITE |
| flash wbuf, page eviction, compaction, recache | staging/bounce pool, remote slot allocator |
| CRC32C | 필수 AES-256-GCM + AAD |
| local full item 또는 flash object | local `ITEM_HDR`, remote encrypted value |
| file path `ext_path=/path:size` | IPv4 peer `ext_path=host:port:size` |

### 변경 파일

| 파일 | 현재 책임 | 변경 성격 |
|---|---|---|
| `extstore.c/.h` | RDMA CM/QP/CQ, shared DMA pool, remote allocator, span profile | 전면 재작성 |
| `storage.c` | memcached item ↔ remote object glue, crypto 호출, plaintext cache | 전면 재작성 |
| `storage.h` | glue API 축소 (`storage_store_item` 추가, write/compact API 삭제) | 축소 |
| `ext_crypto.c/.h` | AES-256-GCM seal/open | 신규 |
| `test_ext_crypto.c` | crypto 자체 검사 | 신규 |
| `memcached.c` | store 성공 전에 `storage_store_item()` 호출, `ITEM_HDR` publish, 삭제된 설정 정리 | 부분 수정 |
| `memcached.h` | remote metadata(`item_hdr.len`), 삭제된 flash 설정/통계 제거 | 부분 수정 |
| `thread.c` | `storage_compact_pause/resume`, `storage_write_pause/resume` 호출 삭제 | 삭제만 |
| `proto_text.c` | `extstore` 명령과 `slabs automove freeratio` 삭제 | 삭제만 |
| `slabs_mover.c` | `slab_automove_extstore` 정책 삭제, 항상 default automove | 삭제만 |
| `Makefile.am` | `slab_automove_extstore.c` 제거, `-lrdmacm -libverbs -lcrypto` 추가 | 부분 수정 |
| `genie-server/genie_memd.c` | remote MR 제공 (별도 프로그램) | 신규 |

`storage.c`는 `ext_crypto.c`를 직접 `#include`한다. autotools object list를
건드리지 않고 crypto TU를 함께 빌드하기 위한 현재 build 선택이다.

### 삭제된 stock 파일

`slab_automove_extstore.c/.h`는 Makefile에서 빠졌다. `ext_global_pool_min` 같은
메모리 압력 수위 개념 자체가 없어졌기 때문이다.

## 2. remote-only 불변식

- storage가 켜진 성공 SET은 local full value를 hash에 publish하지 않는다.
- `STORED`는 AES-GCM seal과 RDMA WRITE CQE가 성공한 뒤에만 반환한다.
- hash에는 key와 remote location을 가진 `ITEM_HDR`만 남는다.
- GET은 매번 `ITEM_HDR`를 통해 remote READ한다. 1 GET = 1 RDMA READ.
- staging 부족은 local fallback이 아니라 wait/backpressure다.
- WRITE 실패는 `NOT_STORED`; READ/GCM 실패는 검증되지 않은 plaintext를
  반환하지 않는다.
- overwrite는 새 remote slot을 commit하고 새 stub을 publish한 뒤 old slot을
  반환한다.
- `EXT_CRYPTO_KEY`가 없거나 32 byte를 읽지 못하면 storage init이 실패한다.

## 3. SET 경로

```text
client SET
  -> do_store_item()                              memcached.c:1664 / :1722
  -> storage_store_item()                         storage.c:530
       -> unlinked ITEM_HDR 할당 (do_item_alloc)
       -> extstore_alloc() remote loc 할당        extstore.c:625
       -> extstore_staging_get()                  extstore.c:704  (없으면 대기)
       -> AES-256-GCM seal                        ext_crypto.c:41
       -> extstore_submit(WRITE)                  extstore.c:682
       -> IO thread: SYNC_FOR_DEVICE -> post
       -> worker는 condvar에서 WRITE CQE 대기
       -> 성공 시 loc을 채운 ITEM_HDR 반환
  -> do_item_link() 또는 item_replace()
  -> old ITEM_HDR이면 storage_delete()로 remote loc 반환
  -> STORED
```

SET은 호출한 worker thread를 block한다. 따라서 동시 SET 수는 `mcT`와 process
전체 staging slot 수로 제한되고, client `pipeline`을 올려도 늘지 않는다.

## 4. GET 경로

```text
worker가 ITEM_HDR 조회
  -> storage_get_item()                           storage.c:349
       -> worker-private plaintext slot 획득 (§8)
       -> io_pending_storage_t + obj_io 구성
       -> worker의 IO_QUEUE_EXTSTORE stack에 push
  -> storage_submit_cb()                          storage.c:456
       -> stack을 obj_io chain으로 바꿔 extstore_submit() 1회
       -> worker가 처음 고른 QP로 고정 전달 (affinity)
  -> IO thread                                    extstore.c:257
       -> bounce slot 배정, RDMA READ post
       -> CQE reap, batched SYNC_FOR_CPU
       -> _storage_get_item_cb에서 AES-GCM open   storage.c:213
       -> return_io_pending()으로 worker 복귀
  -> response iovec가 plaintext slot을 참조
  -> 전송 완료 뒤 storage_finalize_cb()에서 slot 반환
```

GCM tag mismatch는 최대 `EXT_READ_RETRIES`만큼 같은 remote location을 다시
읽는다. 소진하면 miss로 처리하고 `badcrc_from_extstore`를 올리되 stub은
unlink하지 않는다. 일시적 DMA visibility 실패가 다음 GET에서 회복될 수 있게
하기 위해서이며, RAM full-item 복구 경로는 없다.

## 5. RDMA engine

정의는 [`GLOSSARY.md`](GLOSSARY.md) §3에 있다. 현재 코드의 성질만 적는다.

- `ext_threads = IO thread 수 = RC QP 수`이며 분리할 수 없다.
- 각 IO thread는 QP/CQ 하나와 read-bounce slice 하나를 소유한다.
- 호출 thread는 첫 submit 때 QP 하나를 골라 thread-local로 유지한다.
- producer는 해당 QP queue mutex만 잡는다.
- `outstanding`과 `bounce_free`는 IO-owner 전용이라 lock이 없다.
- 한 posting round는 최대 `min(EXT_WRITE_BATCH, 32)`개의 독립 signaled WR이다.
- READ CQE batch는 한 번의 `SYNC_FOR_CPU`, WRITE batch는 한 번의
  `SYNC_FOR_DEVICE` advise로 처리한다.
- CQE가 없고 outstanding이 남아 있으면 `sched_yield()`로 busy-poll한다. 완전히
  idle일 때만 condvar에서 잔다.
- post 실패 또는 error CQE는 engine을 dead로 만들고 이후 요청을 fail-fast한다.
  자동 reconnect는 없다.

코드 기본값은 `ext_threads=1`, `ext_io_depth=64`다. 이는 runtime 기본일 뿐이며
측정 운영점은 `ext_threads/QP=8`, `depth=16`을 명시한다.

## 6. remote memory와 allocator

Genie는 첫 RDMA CM connection의 private data로 `{raddr, rkey, size}`를 전달한다.
Ariel은 같은 peer에 `ext_threads`개의 RC connection을 만들고 모두 같은 MR을 쓴다.
`page_count`는 `ext_path`의 size가 아니라 **genie가 보고한 MR 크기**로 정해진다.

SEV-SNP에서 NIC DMA 대상인 read-bounce와 write-staging pool은
`/dev/snp_shared` mmap을 우선 사용하고, 비TEE에서는 anonymous mmap으로
fallback한다. 두 pool만 MR로 등록하며 plaintext worker cache는 private memory다.

remote MR은 page로 나누고 각 active page에서 bump allocation한다. 삭제·overwrite로
반환된 location은 bucket별 LIFO stack에서 재사용한다. 재사용은 stack top이
요청 길이 이상일 때만 하고, 재사용 시 caller의 실제 len을 다시 기록한다.
그러지 않으면 stub이 주장하는 길이와 seal된 길이가 어긋나 그 key가 영구히
GCM 실패한다. 현재 fixed-size workload에 맞춘 top-only 재사용이며,
mixed-size fragmentation이 실제로 나타나기 전에는 size-class allocator를
추가하지 않는다.

flash compaction, recache, local memcpy backend는 제거됐다.

## 7. crypto

remote object:

```text
12-byte nonce || ciphertext || 16-byte GCM tag
```

AAD:

```c
{ hash(key), page_id, pad, offset, page_version }
```

seal/open용 `EVP_CIPHER_CTX`는 thread-local로 재사용한다. 각 operation은
key/nonce/AAD/tag 상태를 다시 설정한다. crypto 실패 시 context를 폐기해 실패
상태가 다음 operation에 남지 않게 한다.

`test_ext_crypto.c`는 round-trip, AAD mismatch, torn ciphertext, 실패 뒤 context
재사용 복구, nonce 유일성을 검사한다.

```bash
cc -o /tmp/t test_ext_crypto.c ext_crypto.c -lcrypto && /tmp/t
```

## 8. GET plaintext cache

`storage_get_item()`은 worker-local `cache_t`를 lazy-create하고 `EXT_SLOT_SIZE`
크기 slot을 최대 1,024개(`PLAINTEXT_POOL_LIMIT`) 유지한다. `cache_set_limit`은
malloc 총량의 하드 상한이며, 소진되면 `do_cache_alloc`이 NULL을 반환한다.
정상 64 B workload에서는 이 경로가 slab allocator와 futex를 완전히 피한다.

cache 생성 실패, pool 소진, slot보다 큰 item은 기존 slab path로 fallback하고
`extstore_plaintext_slab_fallback`을 증가시킨다. `io_pending_storage_t.read_cache`가
실제 allocator를 기억하므로 응답 완료 뒤 같은 경로로 반환한다. alloc과 free가
모두 같은 worker thread에서 일어나므로 lock 없는 `do_cache_alloc/free`를 쓴다.

## 9. 설정

전체 정의는 [`GLOSSARY.md`](GLOSSARY.md) §3–§4에 있다. 요약:

| `-o` 옵션 | 의미 |
|---|---|
| `ext_path=IPv4:port:size` | Genie endpoint. size는 0 검사에만 쓴다. |
| `ext_threads=N` | IO thread = RC QP 수 |
| `ext_io_depth=N` | QP당 outstanding WR 상한 |
| `ext_page_size=MiB` | remote page 크기 |

환경변수: `EXT_CRYPTO_KEY`(필수), `EXT_SLOT_SIZE`, `EXT_READ_SLOTS`,
`EXT_WRITE_SLOTS`, `EXT_READ_RETRIES`, `EXT_WRITE_BATCH`, `EXT_RDMA_PROF`,
`EXT_SELFTEST`, `EXT_TRACE_SEAL`.

## 10. 통계와 측정 경계

`EXT_RDMA_PROF=1`일 때 `extstore_prof_span_ver=2`를 출력한다.

| 방향 | total span | breakout |
|---|---|---|
| GET | READ post 직전 → CQE → sync → decrypt 완료 | xfer, sync, crypto |
| SET | encrypt 시작 → sync → CQE | crypto, sync, xfer |

두 방향의 시작점이 비대칭이라 **SET span은 worker→IO enqueue 대기를 포함하고
GET span은 포함하지 않는다**. 또한 `xfer + sync + crypto < total`이 정상이며
차액은 CQE batch 안에서 자기 callback 차례를 기다린 시간이다. 자세한 경계는
[`GLOSSARY.md`](GLOSSARY.md) §6에 있다.

주요 통계:

```text
extstore_prof_{read,write}_{count,avg_ns,p50_ns,p99_ns}
extstore_prof_{read,write}_{crypto_avg_ns,sync_avg_ns,xfer_avg_ns}
extstore_plaintext_slab_fallback
extstore_{read,write}_failures
extstore_read_retries
extstore_get_aborted_{chunked,alloc}
extstore_engine_dead
badcrc_from_extstore
```

histogram은 100 ns × 32,768 bucket이며 3.2767 ms 이상을 마지막 bucket으로
clamp한다. `stats reset`은 profile histogram/sum도 초기화한다.

Port throughput은 remote GET에서 `extstore_prof_read_count / measurement_seconds`를
사용하고 같은 구간 `cmd_get`과 일치해야 한다. memtier Ops/s는 Port headline이 아니다.

## 11. 현재 source 식별

아래 SHA-256은 성능 binary `564505f4…cf33`를 만든 source의 신원이다. 주석
수정만으로도 값이 바뀌므로 측정을 다시 하지 않는 한 손대지 않는다.

`extstore.c`, `storage.c`, `ext_crypto.h`의 주석에 남아 있는
`EXTSTORE_RDMA_SPEC.md`, `SPEC §N`, `P-N` 표기는 이 tree에 없다. 구현 **전**에
쓴 설계 문서이며 `../memcached-1.6.42/EXTSTORE_RDMA_SPEC.md`에 남아 있다.
구현 결과와 어긋나는 부분이 있으므로 현재 동작의 근거로 쓰지 않는다. 이 문서가
그 역할을 대체한다. 주석은 SHA 보존을 위해 그대로 두었다.

| 파일 | SHA-256 |
|---|---|
| `Makefile.am` | `4a757ae0a20ab106c38d6e0f56d14fe4fbd7775821e420983a8b0de70725aa8c` |
| `extstore.c` | `fa1e73abc4e52c505bc98eee31b326a451f9380902c1fdeb4f63f8b5014a93bf` |
| `extstore.h` | `dbaa84116d88b1df83d6cbc5a0ce1d3ad81b9c586d2a82fd80af92f4a90bb747` |
| `storage.c` | `394fa56fcc938dc570afcd962abb2307e09dfcacd3b58072b678ac519a13b42a` |
| `storage.h` | `6f3dec1d93b25c0de434cdc37c2d3e8ba298f6427b246e34c40c47eb601514b8` |
| `memcached.c` | `12a756e020d6196076c40a8eafc7c0d0dc124d253e60b687c3433c5a38f4295d` |
| `memcached.h` | `5909adb4c6f1cbd216caf124c1790a0bf627fad8ce815dcf4436937e8721329a` |
| `thread.c` | `9ab37d73f98149ef58a2494f1d2f6d3e8466ff47e677af4ed29747c61660f475` |
| `proto_text.c` | `5490a8d96d76b52fbc405e0210c9301afeb399d633defc7283ba597e63cbf745` |
| `slabs_mover.c` | `1f093c7d0ff638168c1d66ff71f8d00997d639d5fd07220bdf9355fb35e03939` |
| `ext_crypto.c` | `2a57f7325f2a6cd72458f3c7181923587fbc686955e86f07f850e70f6906655d` |
| `test_ext_crypto.c` | `e9c0ef2d2c3101cab9ec3b5fcdc72aa4e85f35311434f30dd1baeda6289f4d73` |

stock 대비 현재 source numstat:

| 파일 | 추가 | 삭제 |
|---|---:|---:|
| `extstore.c` | 735 | 879 |
| `storage.c` | 328 | 1108 |
| `extstore.h` | 53 | 53 |
| `memcached.c` | 49 | 52 |
| `Makefile.am` | 5 | 3 |
| `storage.h` | 4 | 8 |
| `memcached.h` | 3 | 31 |
| `slabs_mover.c` | 1 | 11 |
| `thread.c` | 0 | 9 |
| `proto_text.c` | 0 | 80 |

재계산:

```bash
for f in Makefile.am extstore.c extstore.h storage.c storage.h \
         memcached.c memcached.h thread.c proto_text.c slabs_mover.c; do
    git diff --no-index --numstat ../memcached-1.6.42/"$f" "$f" || true
done

sha256sum Makefile.am extstore.c extstore.h storage.c storage.h \
    memcached.c memcached.h thread.c proto_text.c slabs_mover.c \
    ext_crypto.c test_ext_crypto.c
```

## 12. 알려진 제약

- **chunked item 미지원.** `ITEM_ntotal(it) > settings.slab_chunk_size_max`인 GET은
  `extstore_get_aborted_chunked`를 올리고 실패한다. SET도 `ITEM_CHUNKED`를 거부한다.
- **value 크기 상한은 `EXT_SLOT_SIZE`.** `extstore_alloc`이 `len > slot_size`를
  거부하므로 측정 설정(`EXT_SLOT_SIZE=256`)에서는 remote object가 256 B를 넘을 수 없다.
- **proxy build 미지원.** `proxy_internal.c`에는 stock 시절의 CRC32C 기반
  extstore GET 경로가 남아 있어 `--enable-proxy` 빌드는 이 backend와 맞지 않는다.
  현재 `config.h`에서 `PROXY`는 undef이므로 빌드에 포함되지 않는다.
- **CRC32C는 data path에서 죽었다.** `crc32c.c`는 여전히 링크되고
  `storage_init()`이 `crc32c_init()`을 부르지만 remote 무결성은 전적으로
  AES-GCM tag가 담당한다. `badcrc_from_extstore`라는 이름은 stock에서 물려받은 것이다.
- **자동 reconnect 없음.** QP 오류 한 번이면 engine이 dead가 되고 프로세스를
  재시작해야 한다.

## 13. 검증과 성능 문서

- 실행/correctness 계약: [`md/experiment.md`](md/experiment.md)
- 현재 운영점: [`md/FRONTIER_7POINT_20260724.md`](md/FRONTIER_7POINT_20260724.md)
- 단일축 민감도: [`md/SENSITIVITY_THREAD_PIPELINE_20260727.md`](md/SENSITIVITY_THREAD_PIPELINE_20260727.md)
- CPU-µs/op 분해: [`md/CPU_COST_ACCOUNTING.md`](md/CPU_COST_ACCOUNTING.md)
- 점진 패치 결과: [`md/CPU_OPTIMIZATION_ROLLOUT.md`](md/CPU_OPTIMIZATION_ROLLOUT.md)
- 최초 전체 matrix: [`md/CONFIG_MATRIX_10S_20260724.md`](md/CONFIG_MATRIX_10S_20260724.md)

성능 측정에 쓴 binary SHA-256은
`564505f442dce8cf0695df4391dae529de33102083f54011ffa8a660a957cf33`이며 이
tree의 `./memcached`와 동일하다.
