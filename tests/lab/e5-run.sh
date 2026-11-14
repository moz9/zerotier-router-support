#!/bin/bash
# PC only (WSL, root). e5-vendor.sh for one OpenWrt release, transcript kept in the lab's results directory.
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
bash "$here/e5-vendor.sh" "${1:-24.10}" ${2:-} > "$L/results/e5-${1:-24.10}.log" 2>&1
grep -E 'CHECK FAIL|E5_DONE|BROKEN' "$L/results/e5-${1:-24.10}.log" | cut -c1-200
