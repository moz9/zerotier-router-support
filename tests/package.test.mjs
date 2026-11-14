import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { manifestFiles, manifestText, packageVersion } from '../tools/make-manifest.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relative) => fs.readFileSync(path.join(repo, relative), 'utf8').replaceAll('\r\n', '\n');

test('the list of checksums is up to date (run: node tools/make-manifest.mjs)', () => {
  assert.equal(read('openwrt/MANIFEST.sha256'), manifestText(), 'openwrt/MANIFEST.sha256 is stale');
});

test('one version everywhere: helper, guard, list of checksums', () => {
  const version = packageVersion();
  assert.ok(version, 'ZRS_VERSION is missing in the helper');
  assert.ok(read('openwrt/usr/libexec/zerotier-support/guard').includes(`GUARD_VERSION="${version}"`), 'the guard has another version');
  assert.ok(read('openwrt/MANIFEST.sha256').startsWith(`# zerotier-router-support ${version}\n`));
});

test('the direct installer downloads exactly what the router installer needs and checks it first', () => {
  const direct = read('router-direct-install.sh');
  const files = manifestFiles();
  for (const needed of ['router-install.sh', 'openwrt/usr/libexec/zerotier-support/helper', 'openwrt/usr/libexec/zerotier-support/guard',
    'openwrt/etc/init.d/zerotier-guard', 'openwrt/lib/upgrade/keep.d/zerotier-guard', 'openwrt/lib/upgrade/keep.d/zerotier-router-support']) {
    assert.ok(files.includes(needed), `${needed} is not downloaded`);
  }
  // every payload file the router installer copies is in the download list
  for (const m of read('router-install.sh').matchAll(/\$\{OVERLAY_DIR\}\/([A-Za-z0-9_./-]+)/g)) {
    assert.ok(files.includes(`openwrt/${m[1]}`), `router-install.sh copies openwrt/${m[1]}, which is not downloaded`);
  }
  assert.ok(direct.indexOf('verify_download') < direct.indexOf('sh "${TMP_DIR}/router-install.sh"'), 'the check must come before the install');
  assert.match(direct, /На роутере ничего не изменено/);
});

test('what a management tool compares changes with the version', () => {
  // a management tool that decides "update available" by the checksums of the helper and the panel files sees
  // every release, because the version line changes the helper's checksum
  assert.match(read('openwrt/usr/libexec/zerotier-support/helper'), /^ZRS_VERSION="20\d\d\.\d\d\.\d\d(\.\d+)?"$/m);
});

test('the guard is installed so that an interrupted install cannot leave it half in place', () => {
  const router = read('router-install.sh');
  const put = (what) => router.indexOf(what);
  assert.ok(put('mv "${HELPER_DIR}/guard.new" "${HELPER_DIR}/guard"') > 0, 'the guard is not put in place by a rename');
  assert.ok(put('mv "${GUARD_INIT}.new" "$GUARD_INIT"') > put('mv "${HELPER_DIR}/guard.new" "${HELPER_DIR}/guard"'), 'the service script must come after the program');
  assert.ok(put('"$GUARD_INIT" enable') > put('"${HELPER_DIR}/helper" install'), 'the service is switched on only after the rest succeeded');
  assert.match(read('openwrt/etc/init.d/zerotier-guard'), /\[ -x "\$GUARD" \] \|\| return 0/);
});
