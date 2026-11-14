#!/bin/bash
# PC only (WSL, root). e1-cache.sh for one router program, transcript kept in the lab's results directory.
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
export ZT_LAB_NAME=cache${1//./}
bash "$here/e1-cache.sh" "${1:-24.10}" > "$L/results/e1-${1:-24.10}.log" 2>&1
tail -1 "$L/results/e1-${1:-24.10}.log"
