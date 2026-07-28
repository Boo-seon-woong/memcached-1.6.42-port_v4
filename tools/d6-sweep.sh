#!/usr/bin/env bash
# Compatibility entrypoint: v2 resource sweep.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PHASES=${PHASES:-"threads window nqp"}
exec "$ROOT/tools/config-matrix-10s.sh" "$@"
