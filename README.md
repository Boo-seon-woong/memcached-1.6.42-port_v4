# memcached-1.6.42 remote-memory port (v3)

memcached extstore를 AES-256-GCM 보호 one-sided RDMA remote memory로 바꾼
remote-only port다. client protocol은 TCP 그대로이며 local hash에는
`ITEM_HDR` stub만 남는다. 서버는 AMD SEV-SNP guest 안에서 돌고, 값은 원격
박스의 RDMA MR에 있다.

## 현재 상태 — 이중 게이트 충족 (2026-07-31)

```text
계약   1:10 혼합(SET:GET) 10 M ops/s  AND  GET-only 10 M ops/s — 동시 충족
       두 워크로드 모두 GET span < 30 µs  AND  SET span < 30 µs
우선   span 이 처리량보다 앞선다. 상충하면 span을 지킨다.
```

빌드 `771ca34068c7609936b2e58a`(`ce92044`, 브랜치 `v3-set-pac`), off-box
fresh boot, mcT=28 / W=24 / QP 2·워커 / hashpower 22, 1 M 키 × 64 B:

| 워크로드 | 총 ops/s | GET span | SET span | 판정 |
|---|---:|---:|---:|---|
| **1:10 혼합** | **10,194,599** | 16.03 µs | 14.51 µs | PASS |
| **GET-only** | **11,778,792** | 15.96 µs | — | PASS |
| SET-only | 4,240,796 | — | 7.63 µs | 참고 |

`get_misses = read_fail = write_fail = engine_dead = slot_acct_leak = 0`,
hit 100%. op당 CPU는 `C_get 2.369 µs`, `C_set 6.63 µs`.

여기까지 온 경로 네 단계 — 각각이 필요했고 어느 하나만으로는 못 간다:

| 단계 | 1:10 | GET-only | SET-only |
|---|---:|---:|---:|
| pac (SET 완료 수거 비동기화) | 8.035 M¹ | 10.241 M | 2.348 M |
| + coherent MR (SWIOTLB 바운스 제거, 커널 패치) | 9.466 M | 11.322 M | 2.640 M |
| + loc magazine 스캔 (전역 뮤텍스 이탈) | 9.670 M | 11.138 M | 4.121 M |
| + GCM 컨텍스트 1회 키잉 | **10.195 M** | **11.779 M** | 4.241 M |

¹ 1:9 측정. 비율 변경만으로 +1.4%.

## 토폴로지

```text
host (ariel)   AMD EPYC 9124, guest = SEV-SNP 30 vCPU, HCA vfio passthrough
memory node    genie — ConnectX 200 Gb/s, genie_memd가 4 GiB MR을 노출
fabric         IB 직결, IPoIB 4092 MTU
부하           genie의 memtier → guest 10.99.0.3:11411 (TCP over IPoIB)
데이터 경로     guest memcached → genie MR, IBV_WR_RDMA_READ/WRITE만
```

genie는 부하 생성기이자 수동 메모리 타깃이다. **데이터 경로에서 CPU를 쓰지
않는다**(one-sided). v2 시절의 guest 내 co-located 구성은 델타 관측용으로만
쓰며 절대값 판정에 쓰지 않는다.

## 문서 읽기 순서

**운영·현행**

1. [md/OPTIMAL_RUNBOOK.md](md/OPTIMAL_RUNBOOK.md) — 최적 운영점 한 벌(조건·세팅·기대치)
2. [md/MANUAL_TEST_PROCEDURE.md](md/MANUAL_TEST_PROCEDURE.md) — 사람이 순차 실행하는 단계별 절차
3. [md/SET_CAMPAIGN_HANDOFF.md](md/SET_CAMPAIGN_HANDOFF.md) — 캠페인 전 기록. **수치의 단일 출처**
4. [md/OPTIMIZATION_HISTORY.md](md/OPTIMIZATION_HISTORY.md) — 어떤 최적화가 얼마를 벌었나

**구조**

5. [md/V3_ARCHITECTURE.md](md/V3_ARCHITECTURE.md) — v3 구조
6. [md/GET_WORKFLOW.md](md/GET_WORKFLOW.md) / [md/SET_WORKFLOW.md](md/SET_WORKFLOW.md) — 경로별 타임라인과 코드 앵커
7. [GLOSSARY.md](GLOSSARY.md) — 변수, 단위, correctness 계약

**이력 (당시 기록이며 현재 상태가 아니다)**

8. [md/V2_ARCHITECTURE.md](md/V2_ARCHITECTURE.md), [md/V2_THROUGHPUT_MAXIMIZATION.md](md/V2_THROUGHPUT_MAXIMIZATION.md) — v2 캠페인
9. [SOURCE_CHANGE_SPEC.md](SOURCE_CHANGE_SPEC.md), [EXTSTORE_RDMA_PORTING.md](EXTSTORE_RDMA_PORTING.md) — v1 이력

8~9의 `ext_threads`/`ext_io_depth` 설명은 v1 기록이며 현재 실행 계약이 아니다
(삭제된 옵션이다).

## 빌드

```bash
git checkout v3-set-pac      # main은 pac이 없다 — 절반만 들어간다
./configure
make clean
make -j"$(nproc)"
./testapp
./tools/test-v2.sh
```

이 repository에는 과거 생성물이 tracked돼 있어 plain `make`만 실행하면
변경된 source 대신 오래된 object를 relink할 수 있다. 검증 binary는 반드시
`make clean` 뒤 빌드하고 SHA-256을 보존한다.

upstream 전체 `make test`에는 v3가 의도적으로 제거한 eviction, chunked
remote object, flash extstore 옵션 테스트가 포함된다. 호환 suite와 skip
사유는 `tools/test-v2.sh`, `t/SKIPPED_V2.list`가 authority다.

암호화 경로만 따로 검증하려면:

```bash
cc -O2 -o /tmp/tc test_ext_crypto.c ext_crypto.c -lcrypto && /tmp/tc
cc -O2 -I. -o /tmp/cost tools/ext-crypto-cost.c ext_crypto.c -lcrypto -lpthread && /tmp/cost
```

## 실행 예 (최적 운영점)

```bash
cd $HOME/kvs-port && taskset -c 0-27 env \
  LD_LIBRARY_PATH=$HOME/coherent-mr-v2/lib:$HOME/kvs-port \
  MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
  EXT_RDMA_PROF=1 EXT_SELFTEST=1 \
  EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key \
  EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
  $HOME/coherent-mr-v2/bin/memcached -p 11411 -U 0 -t 28 -m 2048 -c 16384 -R 1024 \
  -o ext_path=10.99.0.2:11212:4g,ext_worker_window=24,ext_qp_per_worker=2,\
ext_drain_spin=1024,hashpower=22
```

정상 시작은 log의 `genie_connect OK`, **`coherent MR` 두 줄**,
`extstore selftest: OK`로 확인한다. selftest의 `advise failed` 두 줄은
정상이며 오히려 통과 신호다(coherent MR에는 umem이 없어 ENOENT인데 페이로드는
왕복한다 — sync 없이 데이터가 옳다는 뜻).

커널 모듈·사용자 lib·바이너리 셋은 **한 벌로만 유효하다.** 섞으면 죽지 않고
조용히 sync 경로로 폴백한다. 판별은 `OPTIMAL_RUNBOOK.md` §4의 로그 게이트로.

---

아래는 upstream memcached README다.

# Memcached

Memcached is a high performance multithreaded event-based key/value cache
store intended to be used in a distributed system.

See: https://memcached.org/about

A fun story explaining usage: https://memcached.org/tutorial

If you're having trouble, try the wiki: https://memcached.org/wiki

If you're trying to troubleshoot odd behavior or timeouts, see:
https://memcached.org/timeouts

https://memcached.org/ is a good resource in general. Please use the mailing
list to ask questions, github issues aren't seen by everyone!

## Dependencies

* libevent - https://www.monkey.org/~provos/libevent/ (libevent-dev)
* libseccomp (optional, experimental, linux) - enables process restrictions for
  better security. Tested only on x86-64 architectures.
* openssl (optional) - enables TLS support. need relatively up to date
  version. pkg-config is needed to find openssl dependencies (such as -lz).

## Building from tarball

If you downloaded this from the tarball, compilation is the standard process:

```
./configure
make
make test # optional
make install
```

If you want TLS support, install OpenSSL's development packages and change the
configure line:

```
./configure --enable-tls
```

If you want to enable the memcached proxy:

```
./configure --enable-proxy
```

## Building from git

To build memcached in your machine from local repo you will have to install
autotools, automake and libevent. In a debian based system that will look
like this

```
sudo apt-get install autotools-dev automake libevent-dev
```

After that you can build memcached binary using automake

```
cd memcached
./autogen.sh
./configure
make
make test
```

It should create the binary in the same folder, which you can run

```
./memcached
```

You can telnet into that memcached to ensure it is up and running

```
telnet 127.0.0.1 11211
stats
```

IF BUILDING PROXY, AN EXTRA STEP IS NECESSARY:

The proxy has some additional vendor dependency code that we keep out of the
tree.

```
cd memcached
cd vendor
./fetch.sh
cd ..
./autogen.sh
./configure --enable-proxy
make
make test
```

## Environment

Be warned that the -k (mlockall) option to memcached might be
dangerous when using a large cache. Just make sure the memcached machines
don't swap.  memcached does non-blocking network I/O, but not disk.  (it
should never go to disk, or you've lost the whole point of it)

## Build status

See https://build.memcached.org/ for multi-platform regression testing status.

## Bug reports

Feel free to use the issue tracker on github.

**If you are reporting a security bug** please contact a maintainer privately.
We follow responsible disclosure: we handle reports privately, prepare a
patch, allow notifications to vendor lists. Then we push a fix release and your
bug can be posted publicly with credit in our release notes and commit
history.

## Website

* https://www.memcached.org

## Contributing

See https://github.com/memcached/memcached/wiki/DevelopmentRepos
