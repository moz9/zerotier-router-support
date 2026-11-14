#!/bin/bash
# PC only (WSL, root). e4-upgrade.sh for one OpenWrt release, transcript kept in the lab's results directory.
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
bash "$here/e4-upgrade.sh" "${1:-25.12}" > "$L/results/e4-${1:-25.12}.log" 2>&1
grep -E 'CHECK FAIL|E4_DONE|BROKEN' "$L/results/e4-${1:-25.12}.log" | cut -c1-200
