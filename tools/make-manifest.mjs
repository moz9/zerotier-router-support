// Writes openwrt/MANIFEST.sha256: the checksum of every file the direct installer downloads, as GitHub serves it
// (Unix line endings). The installer on the router compares its downloads with this list before installing anything.
// With a version argument it also sets that version in the helper and in the guard.
//
//   node tools/make-manifest.mjs              refresh the checksums, keep the version
//   node tools/make-manifest.mjs 2026.11.20   new release: set the version, then the checksums
//
// Run it after ANY change of a file that goes to a router; tests/package.test.mjs fails when the list is stale.
// Give a new version whenever such a file changed since the last release: a management tool recognises an update by
// the helper's checksum, and the version line is what makes that checksum change.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = (relative) => path.join(repo, relative);
const lf = (relative) => Buffer.from(fs.readFileSync(file(relative), 'utf8').replaceAll('\r\n', '\n'), 'utf8');
const helperPath = 'openwrt/usr/libexec/zerotier-support/helper';
const guardPath = 'openwrt/usr/libexec/zerotier-support/guard';

export function manifestFiles() {
  const direct = fs.readFileSync(file('router-direct-install.sh'), 'utf8');
  return [...direct.matchAll(/^fetch_file "([^"]+)"$/gm)].map((m) => m[1]).filter((p) => p !== 'openwrt/MANIFEST.sha256');
}
export function packageVersion() {
  return fs.readFileSync(file(helperPath), 'utf8').match(/^ZRS_VERSION="([0-9.]+)"$/m)?.[1];
}
export function manifestText() {
  const lines = manifestFiles().map((p) => `${crypto.createHash('sha256').update(lf(p)).digest('hex')}  ${p}`);
  return `# zerotier-router-support ${packageVersion()}\n${lines.join('\n')}\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const version = process.argv[2];
  if (version) {
    if (!/^20\d\d\.\d\d\.\d\d(\.\d+)?$/.test(version)) throw new Error('version looks like 2026.11.14 or 2026.11.14.2');
    for (const [p, name] of [[helperPath, 'ZRS_VERSION'], [guardPath, 'GUARD_VERSION']]) {
      const text = lf(p).toString('utf8');
      const next = text.replace(new RegExp(`^${name}="[0-9.]+"`, 'm'), `${name}="${version}"`);
      if (!next.includes(`${name}="${version}"`)) throw new Error(`${name} not found in ${p}`);
      fs.writeFileSync(file(p), next);
    }
  }
  fs.writeFileSync(file('openwrt/MANIFEST.sha256'), manifestText());
  console.log(`openwrt/MANIFEST.sha256: version ${packageVersion()}, ${manifestFiles().length} files`);
}
