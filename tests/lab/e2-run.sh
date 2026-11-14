#!/bin/bash
# PC only (WSL, root). e2-guard.sh for one router program, transcript kept in the lab's results directory.
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
bash "$here/e2-guard.sh" "${1:-25.12}" > "$L/results/e2-${1:-25.12}.log" 2>&1
tail -1 "$L/results/e2-${1:-25.12}.log"
