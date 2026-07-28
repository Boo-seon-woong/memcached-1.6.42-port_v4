#!/usr/bin/env bash
# v2 co-located matrix. Genie must already be listening.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT_BIN=${PORT_BIN:-"$ROOT/memcached"}
STOCK_BIN=${STOCK_BIN:-"$ROOT/memcached.stock"}
MT=${MT:-"$HOME/memtier/memtier_benchmark"}
GENIE=${GENIE:-10.99.0.2:11212}
OUT=${OUT:-"$HOME/rdma-results/v2-matrix-$(date +%Y%m%d-%H%M%S)"}
PHASES=${PHASES:-"threads pipeline window nqp stock"}
TEST_SECONDS=${TEST_SECONDS:-10}
KEYS=${KEYS:-1000000}
VALUE_SIZE=${VALUE_SIZE:-64}
MT_THREADS=${MT_THREADS:-8}
MT_CLIENTS=${MT_CLIENTS:-16}
SERVER_CPUS=${SERVER_CPUS:-0-15}
CLIENT_CPUS=${CLIENT_CPUS:-16-23}
MC_THREADS=${MC_THREADS:-12}
PIPELINE=${PIPELINE:-64}
WORKER_WINDOW=${WORKER_WINDOW:-16}
QP_PER_WORKER=${QP_PER_WORKER:-1}
DRAIN_SPIN=${DRAIN_SPIN:-1024}
MEM_MB=${MEM_MB:-2048}
KEY_FILE=${KEY_FILE:-"$ROOT/ext.key"}

mkdir -p "$OUT"
CSV="$OUT/results.csv"
printf '%s\n' 'phase,label,mode,mc_threads,mt_threads,mt_clients,pipeline,worker_window,qp_per_worker,cmd_get,remote_reads,server_get_s,remote_get_s,remote_avg_us,remote_p50_us,remote_p99_us,misses,badcrc,read_failures,write_failures,engine_dead,slot_acct_leak,drain_calls,drain_empty,wait_enq,write_spins,status' > "$CSV"

MCPID=
cleanup() {
    if [[ -n "${MCPID:-}" ]]; then
        kill "$MCPID" 2>/dev/null || true
        wait "$MCPID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

stats() {
    exec 9<>/dev/tcp/127.0.0.1/11211 || return 1
    printf 'stats\r\nquit\r\n' >&9
    timeout 5 tr -d '\r' <&9
    exec 9<&- 9>&-
}

statv() {
    awk -v key="$2" '$1 == "STAT" && $2 == key { print $3; found=1; exit }
        END { if (!found) print 0 }' "$1"
}

start_server() {
    local mode=$1 mct=$2 window=$3 nqp=$4 dir=$5
    local -a cmd
    cleanup
    MCPID=
    if [[ "$mode" == port ]]; then
        [[ -x "$PORT_BIN" && -r "$KEY_FILE" ]] ||
            { echo "missing PORT_BIN or 32-byte KEY_FILE" >&2; return 1; }
        cmd=(taskset -c "$SERVER_CPUS" env
            "LD_LIBRARY_PATH=$HOME/covlib:$ROOT"
            MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1
            "EXT_CRYPTO_KEY=$KEY_FILE" EXT_SELFTEST=1
            EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 EXT_RDMA_PROF=1
            "$PORT_BIN" -p 11211 -U 0 -t "$mct" -m "$MEM_MB" -c 8192 -R 1024
            -o "ext_path=$GENIE:4g,ext_worker_window=$window,ext_qp_per_worker=$nqp,ext_drain_spin=$DRAIN_SPIN")
    else
        [[ -x "$STOCK_BIN" ]] || { echo "missing STOCK_BIN" >&2; return 1; }
        cmd=(taskset -c "$SERVER_CPUS" "$STOCK_BIN"
            -p 11211 -U 0 -t "$mct" -m "$MEM_MB" -c 8192 -R 1024)
    fi
    printf '%q ' "${cmd[@]}" > "$dir/server-command.txt"
    printf '\n' >> "$dir/server-command.txt"
    "${cmd[@]}" >"$dir/server.txt" 2>&1 &
    MCPID=$!

    for _ in $(seq 1 60); do
        if ! kill -0 "$MCPID" 2>/dev/null; then return 1; fi
        if stats >"$dir/stats-start.txt" 2>/dev/null; then
            if [[ "$mode" != port ]] ||
               { grep -q 'genie_connect OK' "$dir/server.txt" &&
                 grep -q 'extstore selftest: OK' "$dir/server.txt"; }; then
                sha256sum "/proc/$MCPID/exe" >"$dir/server-sha256.txt"
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

memtier() {
    local pipeline=$1 pattern=$2 ratio=$3 out=$4
    shift 4
    taskset -c "$CLIENT_CPUS" env "LD_LIBRARY_PATH=$HOME/memtier:$ROOT" "$MT"         -s 127.0.0.1 -p 11211 -P memcache_text         --threads="$MT_THREADS" --clients="$MT_CLIENTS" --pipeline="$pipeline"         -d "$VALUE_SIZE" --key-prefix=m- --key-minimum=1 --key-maximum="$KEYS"         --key-pattern="$pattern" --ratio="$ratio" --hide-histogram "$@"         >"$out" 2>&1
}

run_point() {
    local phase=$1 label=$2 mode=$3 mct=$4 pipeline=$5 window=$6 nqp=$7
    local dir="$OUT/$label" status=ok
    mkdir -p "$dir"
    echo "RUN $label"
    if ! start_server "$mode" "$mct" "$window" "$nqp" "$dir"; then
        printf '%s\n' "$phase,$label,$mode,$mct,$MT_THREADS,$MT_CLIENTS,$pipeline,$window,$nqp,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,server_failed" >>"$CSV"
        cleanup; MCPID=
        return
    fi

    local per_client=$(( (KEYS + MT_THREADS * MT_CLIENTS - 1) /
        (MT_THREADS * MT_CLIENTS) ))
    memtier 8 P:P 1:0 "$dir/preload.txt" -n "$per_client"
    stats >"$dir/stats-after-preload.txt"
    [[ $(statv "$dir/stats-after-preload.txt" curr_items) == "$KEYS" ]] ||
        status=preload_failed

    if [[ "$status" == ok ]]; then
        memtier "$pipeline" R:R 0:1 "$dir/warmup.txt" --test-time=2
        exec 9<>/dev/tcp/127.0.0.1/11211
        printf 'stats reset\r\nquit\r\n' >&9
        timeout 5 tr -d '\r' <&9 >"$dir/stats-reset.txt" || true
        exec 9<&- 9>&-
        memtier "$pipeline" R:R 0:1 "$dir/load.txt" --test-time="$TEST_SECONDS"
    fi
    stats >"$dir/stats-final.txt"

    local st="$dir/stats-final.txt"
    local cmd=$(statv "$st" cmd_get) remote=$(statv "$st" extstore_prof_read_count)
    local misses=$(statv "$st" get_misses) badcrc=$(statv "$st" badcrc_from_extstore)
    local rf=$(statv "$st" extstore_read_failures) wf=$(statv "$st" extstore_write_failures)
    local dead=$(statv "$st" extstore_engine_dead) leak=$(statv "$st" ext_slot_acct_leak)
    if [[ "$mode" == port ]]; then
        [[ "$misses" == 0 && "$badcrc" == 0 && "$rf" == 0 && "$wf" == 0 &&
           "$dead" == 0 && "$leak" == 0 && "$remote" == "$cmd" ]] ||
            status=correctness_failed
    else
        remote=0
        [[ "$misses" == 0 ]] || status=correctness_failed
    fi
    local server_rps=$(awk -v n="$cmd" -v s="$TEST_SECONDS" 'BEGIN{printf "%.2f",n/s}')
    local remote_rps=$(awk -v n="$remote" -v s="$TEST_SECONDS" 'BEGIN{printf "%.2f",n/s}')
    local avg=$(awk -v n="$(statv "$st" extstore_prof_read_avg_ns)" 'BEGIN{printf "%.3f",n/1000}')
    local p50=$(awk -v n="$(statv "$st" extstore_prof_read_p50_ns)" 'BEGIN{printf "%.3f",n/1000}')
    local p99=$(awk -v n="$(statv "$st" extstore_prof_read_p99_ns)" 'BEGIN{printf "%.3f",n/1000}')
    printf '%s\n' "$phase,$label,$mode,$mct,$MT_THREADS,$MT_CLIENTS,$pipeline,$window,$nqp,$cmd,$remote,$server_rps,$remote_rps,$avg,$p50,$p99,$misses,$badcrc,$rf,$wf,$dead,$leak,$(statv "$st" ext_worker_drain_calls),$(statv "$st" ext_worker_drain_empty),$(statv "$st" ext_worker_wait_enq),$(statv "$st" ext_worker_write_spins),$status" >>"$CSV"
    cleanup; MCPID=
}

if [[ " $PHASES " == *" threads "* ]]; then
    for n in ${MC_THREAD_VALUES:-8 10 12 14 16}; do
        run_point threads "threads-$n" port "$n" "$PIPELINE" "$WORKER_WINDOW" "$QP_PER_WORKER"
    done
fi
if [[ " $PHASES " == *" pipeline "* ]]; then
    for n in ${PIPELINE_VALUES:-1 8 32 64 96}; do
        run_point pipeline "pipeline-$n" port "$MC_THREADS" "$n" "$WORKER_WINDOW" "$QP_PER_WORKER"
    done
fi
if [[ " $PHASES " == *" window "* ]]; then
    for n in ${WINDOW_VALUES:-1 4 8 16 32 64}; do
        run_point window "window-$n" port "$MC_THREADS" "$PIPELINE" "$n" "$QP_PER_WORKER"
    done
fi
if [[ " $PHASES " == *" nqp "* ]]; then
    for n in ${NQP_VALUES:-1 2 4}; do
        w=$((16 * n))
        run_point nqp "nqp-$n-w$w" port "$MC_THREADS" "$PIPELINE" "$w" "$n"
    done
fi
if [[ " $PHASES " == *" stock "* ]]; then
    run_point stock stock-local stock "$MC_THREADS" "$PIPELINE" 0 0
fi

printf '%s\n' "RESULT_DIR=$OUT"
