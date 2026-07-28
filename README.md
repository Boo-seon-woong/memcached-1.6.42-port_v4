# memcached-1.6.42 RDMA remote-memory port

memcached의 extstore backend를 flash에서 **암호화된 원격 메모리**로 교체한 port다.
client↔memcached TCP protocol은 그대로 두고, 성공한 SET value는 AES-256-GCM으로
seal한 뒤 one-sided RDMA WRITE가 완료돼야 `STORED`가 되며, local RAM에는
`ITEM_HDR` stub만 남는다. local value cache도 fallback도 없다.

## 현재 상태

| 항목 | 값 |
|---|---|
| 상태 | 구현 완료, 성능 측정 단계 |
| 기준 commit | `597fc83` |
| 성능 binary SHA-256 | `564505f442dce8cf0695df4391dae529de33102083f54011ffa8a660a957cf33` (tree의 `./memcached`와 동일) |
| guest | SEV-SNP, 24 vCPU, 48 GB configured RAM |
| 운영점 | `mtT=8 × c16`, `mcT=8`, `pipeline=8`, `QP/ext=8`, `depth=16`, `-R 1024` |
| workload | GET-only, 64 B value, 1,000,000 preloaded keys, crypto ON |

같은 binary·같은 운영점의 remote GET throughput 실측:

| 측정일 | remote GET/s | avg | p50 | p99 | 문서 |
|---|---:|---:|---:|---:|---|
| 2026-07-24 | 2.445M | 22.252µs | 20.300µs | 59.600µs | [FRONTIER](md/FRONTIER_7POINT_20260724.md) |
| 2026-07-27 | 2.967M | 20.888µs | 20.400µs | 43.700µs | [SENSITIVITY](md/SENSITIVITY_THREAD_PIPELINE_20260727.md) |

두 값은 같은 binary와 같은 shape인데 21% 차이가 난다. **날짜가 다른 절대값을
섞어 최적점을 고르지 않는다.** 각 결론은 같은 실행 안의 상대 비교로만 내린다.
avg `<30µs`는 두 실행 모두 충족하고 p99 `<30µs`는 어느 point도 충족하지 못했다.

## 읽기 순서

이 순서대로 읽으면 용어 → 구조 → 결정 → 재현 → 결과 → 원자료로 이어진다.

| # | 문서 | 내용 |
|---|---|---|
| 1 | [`GLOSSARY.md`](GLOSSARY.md) | thread, QP, depth, pipeline, slot 등 **모든 변수의 정의**. 다른 문서는 여기 이름만 쓴다. |
| 2 | [`SOURCE_CHANGE_SPEC.md`](SOURCE_CHANGE_SPEC.md) | 현재 source가 실제로 하는 일. 파일별 변경 범위와 불변식. |
| 3 | [`EXTSTORE_RDMA_PORTING.md`](EXTSTORE_RDMA_PORTING.md) | 채택·폐기·보류된 설계 결정과 그 근거. |
| 4 | [`md/experiment.md`](md/experiment.md) | 재현 절차와 측정 계약. |
| 5 | [`md/FRONTIER_7POINT_20260724.md`](md/FRONTIER_7POINT_20260724.md) | 현재 운영점을 고른 실험과 stock 동일-shape control. |
| 6 | [`md/SENSITIVITY_THREAD_PIPELINE_20260727.md`](md/SENSITIVITY_THREAD_PIPELINE_20260727.md) | worker thread / pipeline 단일축 민감도(최신 실행). |
| 7 | [`md/CPU_COST_ACCOUNTING.md`](md/CPU_COST_ACCOUNTING.md) | CPU-µs/op 회계. 최적화 우선순위의 근거. |
| 8 | [`md/CPU_OPTIMIZATION_ROLLOUT.md`](md/CPU_OPTIMIZATION_ROLLOUT.md) | 패치를 하나씩 적용한 당시 측정 기록. |
| 9 | [`md/CONFIG_MATRIX_10S_20260724.md`](md/CONFIG_MATRIX_10S_20260724.md) | 최초 전체 matrix. 5–6의 전 단계 기록. |
| 10 | [`md/RAW_DATA_INDEX.md`](md/RAW_DATA_INDEX.md) | 모든 실험 raw 파일의 위치. |

stock 1.6.42를 이해하기 위한 자료는 별도이며 port 동작을 설명하지 않는다.

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — stock memcached 전체 구조
- [`ARCHITECTURE_STUDY.md`](ARCHITECTURE_STUDY.md) — stock의 데이터부/통신부 분리
- [`EXTSTORE_READING.md`](EXTSTORE_READING.md) — stock extstore(flash) 독해 노트

[`conversation.md`](conversation.md)는 ariel(guest)과 genie(remote host) 사이의
fabric 예약·장애 대응 채널 로그다. 문서가 아니라 append-only 기록이다.

## 빌드와 실행

```bash
./configure && make                # extstore는 기본 on, RDMA/OpenSSL link는 Makefile.am에 있음

LD_LIBRARY_PATH=$HOME/covlib MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
EXT_CRYPTO_KEY=./ext.key EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 EXT_RDMA_PROF=1 \
./memcached -p 11211 -U 0 -t 8 -m 2048 -c 8192 -R 1024 \
    -o ext_path=10.99.0.2:11212:4g,ext_threads=8,ext_io_depth=16
```

covlib(patched libibverbs/libmlx5)와 `MLX5_COHERENT_*`가 없으면 `rdma_cm`이
hang한다. remote 쪽은 `genie-server/genie_memd <port> <size> --prefill`이다.
자세한 조건은 [`GLOSSARY.md`](GLOSSARY.md) §7에 있다.

**빌드 함정**: 이 tree는 automake 1.17로 생성됐는데 시스템 automake는 1.16.5다.
`Makefile.am`을 건드리면 `make`가 regen을 시도하다 실패한다. 편집한 뒤에는
timestamp를 생성물이 더 새것이 되도록 정렬한다.

```bash
touch configure.ac && sleep 1 && touch aclocal.m4 Makefile.am && sleep 1 && \
touch configure config.h.in Makefile.in && sleep 1 && \
touch config.status config.h Makefile stamp-h1
```

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
