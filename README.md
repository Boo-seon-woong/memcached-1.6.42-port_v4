# memcached-1.6.42 remote-memory port v2

memcached extstore를 AES-256-GCM 보호 one-sided RDMA remote memory로 바꾼
remote-only port다. client protocol은 TCP 그대로이며 local hash에는
`ITEM_HDR` stub만 남는다.

## 현재 상태

P0~P2b source 구현은 완료됐다. GET과 SET은 모두 memcached worker가 자기
QP/CQ/bounce/staging으로 처리하며 extstore IO thread와 구형 submit queue는
삭제됐다. clean build와 `testapp` 56/56은 통과했다.

기존 P2b 동작 실측은 `mcT=12, window=16, pipeline=64, drain_spin=1024`에서
5.646M GET/s, 1.991 server CPU µs/op, correctness 0이었다. 그 측정 당시에도
요청은 전부 inline이었지만 unused bootstrap QP와 dead code가 남아 있었다.
이번 완전 삭제 tree의 Ariel↔Genie smoke와 off-box 성능은 아직 재실행하지
않았으므로 기존 수치를 새 binary의 결과로 간주하면 안 된다.

## 문서 읽기 순서

1. [GLOSSARY.md](GLOSSARY.md) — v2 변수, 단위, correctness 계약
2. [md/V2_REMODIFICATION_SPEC.md](md/V2_REMODIFICATION_SPEC.md) — 계획과 현재 단계
3. [md/V2_CODE_SPEC.md](md/V2_CODE_SPEC.md) — 실제 call path와 검증 게이트
4. [SOURCE_CHANGE_SPEC.md](SOURCE_CHANGE_SPEC.md) — v1 source history
5. [EXTSTORE_RDMA_PORTING.md](EXTSTORE_RDMA_PORTING.md) — v1 설계/실측 history

4~5의 `ext_threads/ext_io_depth` 설명은 v1 기록이며 v2 실행 계약이 아니다.

## 빌드

```bash
./configure
make -j"$(nproc)"
./testapp
./tools/test-v2.sh
```

upstream 전체 `make test`에는 v2가 의도적으로 제거한 eviction, chunked
remote object, flash extstore 옵션 테스트가 포함된다. v2 호환 suite와 skip
사유는 `tools/test-v2.sh`, `t/SKIPPED_V2.list`가 authority다.

## v2 실행 예

```bash
LD_LIBRARY_PATH="$HOME/covlib:$PWD" \
MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
EXT_CRYPTO_KEY="$PWD/ext.key" EXT_SELFTEST=1 \
EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 EXT_RDMA_PROF=1 \
./memcached -p 11211 -U 0 -t 12 -m 2048 -c 8192 -R 1024 \
  -o ext_path=10.99.0.2:11212:4g,ext_worker_window=16,\
ext_qp_per_worker=1,ext_drain_spin=1024
```

정상 시작은 server log의 `genie_connect OK`와
`extstore selftest: OK`로 확인한다. `ext_threads`, `ext_io_depth`는
삭제된 v1 옵션이다.

canonical 실행 도구는 `tools/config-matrix-10s.sh`와
`tools/cpu-stage-detail.sh`다. 결과는 binary hash, 정확한 command,
server/memtier raw text, stats 시작/종료, CSV를 함께 보존한다.

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
