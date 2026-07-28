#!/usr/bin/env bash
# Non-TEE v2 mirror. Start loopback genie_memd separately.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export GENIE=${GENIE:-127.0.0.1:11212}
export PHASES=${PHASES:-"threads pipeline window nqp"}
export SERVER_CPUS=${SERVER_CPUS:-0-15}
export CLIENT_CPUS=${CLIENT_CPUS:-16-23}
exec "$ROOT/tools/config-matrix-10s.sh" "$@"
