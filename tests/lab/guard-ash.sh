#!/bin/bash
# PC only (WSL, root). Runs the guard's behaviour tests (tests/guard-scenarios.sh) three times:
#   with the PC's own sh, and with the routers' own BusyBox ash of OpenWrt 24.10 and 25.12 (under qemu, in the lab
#   roots made by lab-roots.sh; no network, nothing leaves the chroot). Then shellcheck.
# usage: guard-ash.sh [scenario]
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}
only=${1:-}
rc=0
t0=$(date +%s)
echo "== PC sh ($(readlink -f /bin/sh))"
sh "$repo/tests/guard-scenarios.sh" "$repo/openwrt/usr/libexec/zerotier-support/guard" $only || rc=1
echo "   $(( $(date +%s) - t0 )) s"
for r in 24.10 25.12; do
  R=$L/root-$r
  [ -x "$R/bin/busybox" ] || { echo "no lab root $R: run lab-roots.sh first"; rc=1; continue; }
  t0=$(date +%s)
  echo "== router ash, OpenWrt $r: $(strings "$R/bin/busybox" | grep -m1 'BusyBox v' | cut -d' ' -f1-2)"
  rm -rf "$R/tmp/zrs-test"; mkdir -p "$R/tmp/zrs-test"
  cp "$repo/tests/guard-scenarios.sh" "$repo/openwrt/usr/libexec/zerotier-support/guard" "$R/tmp/zrs-test/"
  unshare --net --mount bash -c '
    R=$1; only=$2
    mount --make-rprivate /; mount -t proc proc "$R/proc"
    exec chroot "$R" /usr/bin/qemu-aarch64-static /bin/ash -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin TMPDIR=/tmp/zrs-test ZRS_TEST_SH=/bin/ash; /bin/ash /tmp/zrs-test/guard-scenarios.sh /tmp/zrs-test/guard $only"
  ' _ "$R" "$only" || rc=1
  rm -rf "$R/tmp/zrs-test"
  echo "   $(( $(date +%s) - t0 )) s"
done
if [ -z "$only" ]; then
  echo "== shellcheck"
  shellcheck --severity=warning -s sh "$repo/openwrt/usr/libexec/zerotier-support/guard" "$repo/openwrt/usr/libexec/zerotier-support/helper" \
    "$repo/router-install.sh" "$repo/router-direct-install.sh" "$repo/tests/guard-scenarios.sh" && echo "   clean" || rc=1
fi
[ $rc = 0 ] && echo GUARD_TESTS_PASSED || echo GUARD_TESTS_FAILED
exit $rc
