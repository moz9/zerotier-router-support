#!/bin/bash
here=$(cd "$(dirname "$0")" && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}; mkdir -p "$L/results"
bash "$here/e3-cut.sh" > "$L/results/e3-cut.log" 2>&1
grep FINDING "$L/results/e3-cut.log"
