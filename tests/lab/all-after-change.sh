#!/bin/bash
# PC only (WSL, root). The lab runs that a change of the helper, the installers or the guard calls for, one after
# another (they would only slow each other down under qemu): e4 on both releases, e2 on 25.12, e5 on 24.10, then the
# behaviour set with the routers' own shells and shellcheck. Each transcript stays in the lab's results directory;
# this prints the summary lines.   usage: all-after-change.sh [skip-e5]      about 1.5 hours
here=$(cd "$(dirname "$0")" && pwd)
t0=$(date +%s)
for r in 24.10 25.12; do echo "== e4 $r"; bash "$here/e4-run.sh" "$r"; done
echo "== e2 25.12"; bash "$here/e2-run.sh" 25.12; grep -h 'CHECK FAIL' "${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}/results/e2-25.12.log" | cut -c1-200
[ "${1:-}" = skip-e5 ] || { echo "== e5 24.10"; bash "$here/e5-run.sh" 24.10; }
echo "== guard-ash"; bash "$here/guard-ash.sh" 2>&1 | grep -E 'guard scenarios:|^== |clean|GUARD_TESTS|^   [0-9]+ s'
echo "all done in $(( ($(date +%s) - t0) / 60 )) min"
