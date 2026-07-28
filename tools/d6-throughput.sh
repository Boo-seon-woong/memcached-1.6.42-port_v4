#!/usr/bin/env bash
# Compatibility entrypoint: v2 client-pipeline throughput sweep.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PHASES=${PHASES:-pipeline}
exec "$ROOT/tools/config-matrix-10s.sh" "$@"
