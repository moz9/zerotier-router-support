import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const helper = fs.readFileSync(path.join(repo, 'openwrt/usr/libexec/zerotier-support/helper'), 'utf8');
const shell = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/sh';
const shellPath = (value) => value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
const body = (name) => {
  const match = helper.match(new RegExp(`^${name}\\(\\) \\{([\\s\\S]*?)^\\}`, 'm'));
  assert.ok(match, `missing ${name}`);
  return match[1];
};

test('Mac installer propagates the remote install failure', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zrs-install-review-'));
  try {
    const bin = path.join(dir, 'bin');
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(dir, 'key'), 'test-private-key');
    fs.writeFileSync(path.join(dir, 'key.pub'), 'ssh-ed25519 AAAATEST test');
    fs.writeFileSync(path.join(bin, 'expect'), `#!/bin/sh
count=0
[ ! -f "$ZRS_TEST_COUNT" ] || count="$(cat "$ZRS_TEST_COUNT")"
count=$((count + 1))
printf '%s' "$count" > "$ZRS_TEST_COUNT"
[ "$count" -eq 1 ]
`, { mode: 0o755 });
    const result = spawnSync(shell, [shellPath(path.join(repo, 'install.sh'))], {
      input: '192.0.2.1\n22\npassword\n', encoding: 'utf8', timeout: 15000,
      env: { ...process.env, PATH: shellPath(bin) + ':' + process.env.PATH,
        ZRS_KEY_PATH: shellPath(path.join(dir, 'key')),
        ZRS_KNOWN_HOSTS: shellPath(path.join(dir, 'known_hosts')),
        ZRS_TEST_COUNT: shellPath(path.join(dir, 'expect-count')) }
    });
    assert.equal(fs.readFileSync(path.join(dir, 'expect-count'), 'utf8'), '2');
    assert.notEqual(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /Готово\./);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Expect expands actual payload paths and verifies each process exit', () => {
  const installer = fs.readFileSync(path.join(repo, 'install.sh'), 'utf8');
  assert.match(installer, /glob -nocomplain -directory \$env\(PAYLOAD_DIR\) \*/);
  assert.match(installer, /\{\*\}\$files/);
  assert.doesNotMatch(installer, /\$env\(PAYLOAD_DIR\)\/\*/);
  assert.ok((installer.match(/set result \[wait\]/g) || []).length >= 3);
  assert.doesNotMatch(installer, /__ZRS_DONE__/);
});

test('rollback snapshot with ZeroTier credentials is private and ACL is valid', () => {
  assert.match(body('snapshot_transport_state'), /mktemp -d \/tmp\/zrs-transport-rollback\.XXXXXX/);
  const acl = JSON.parse(fs.readFileSync(path.join(repo, 'openwrt/usr/share/rpcd/acl.d/zerotier-support.json'), 'utf8'));
  assert.deepEqual(Object.keys(acl['zerotier-support'].read), ['ubus']);
  assert.deepEqual(Object.keys(acl['zerotier-support'].write), ['ubus']);
});

test('failed firewall UCI command is returned before commit', () => {
  const script = `FW_ZONE=zt_support
FW_RULE=allow_zt_support_router
uci() { case "$*" in *' get '*) return 1 ;; set*) return 7 ;; esac; }
ensure_ping_rule() { :; }
ensure_firewall() {${body('ensure_firewall')}
}
if ensure_firewall; then exit 9; fi
`;
  const result = spawnSync(shell, ['-c', script], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('leave refuses an edited network ID before touching ZeroTier', () => {
  const script = `NETWORK_SECTION=router_support
uci() { case "$*" in '-q get zerotier.router_support.id') printf '%s\\n' 0123456789abcdef ;; *) exit 9 ;; esac; }
zerotier-cli() { exit 9; }
leave_network() {${body('leave_network')}
}
if leave_network fedcba9876543210; then exit 8; fi
`;
  const result = spawnSync(shell, ['-c', script], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /отличается от сохранённой сети/);
});
