#!/bin/bash
# PC only (WSL). The guard's behaviour tests with the PC's own sh only (quick, while writing).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
t0=$(date +%s)
sh "$repo/tests/guard-scenarios.sh" "$repo/openwrt/usr/libexec/zerotier-support/guard" ${1:-} 2>&1 | tail -40
echo "$(( $(date +%s) - t0 )) s"
