#!/bin/bash
# PC only (WSL, root). Runs e1-cache.sh for both router programs, one after the other; transcript in the lab dir.
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}
mkdir -p "$L/results"
for v in 25.12 24.10; do
  bash "$here/e1-cache.sh" "$v" > "$L/results/e1-$v.log" 2>&1
done
echo E1_BOTH_DONE
