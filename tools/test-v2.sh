#!/usr/bin/env bash
# Local suite for the v2 contract. Hardware RDMA tests are separate.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKIP="$ROOT/t/SKIPPED_V2.list"
PARALLEL=${PARALLEL:-8}

cd "$ROOT"
./testapp

tests=()
while IFS= read -r path; do
    base=${path##*/}
    if ! awk -F' *[|] *' -v base="$base" \
        '$1 == base { found=1 } END { exit !found }' "$SKIP"; then
        tests+=("$path")
    fi
done < <(find t -maxdepth 1 -name '*.t' -print | sort)

prove -j "$PARALLEL" "${tests[@]}"
