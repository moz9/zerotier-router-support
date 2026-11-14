#!/bin/bash
# PC only (WSL, root). e1b-stale.sh for both router programs at the same time (two labs side by side).
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
bash "$here/e1b-stale.sh" 25.12 > "$L/results/e1b-25.12.log" 2>&1 &
bash "$here/e1b-stale.sh" 24.10 > "$L/results/e1b-24.10.log" 2>&1 &
wait
echo E1B_BOTH_DONE
