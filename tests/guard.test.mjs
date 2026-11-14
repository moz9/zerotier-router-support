import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relative) => fs.readFileSync(path.join(repo, relative), 'utf8').replaceAll('\r\n', '\n');
const win = process.platform === 'win32';
const shell = win ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/sh';
const guardPath = 'openwrt/usr/libexec/zerotier-support/guard';
const guard = read(guardPath);
const code = guard.split('\n').filter((line) => !line.trim().startsWith('#')).join('\n');

// The behaviour itself is tested by tests/guard-scenarios.sh: a model router around the real script.
// Starting a process is slow on Windows, so there only a few short scenarios run; everything runs on Linux (CI)
// and, with the routers' own BusyBox ash, through tests/lab/guard-ash.sh in WSL.
const scenarios = win && !process.env.ZRS_FULL ? ['kept-settings', 'late-check', 'status-text'] : [''];
for (const name of scenarios) {
  test(`guard behaviour: ${name || 'all scenarios'}`, { timeout: 30 * 60 * 1000 }, () => {
    const args = ['tests/guard-scenarios.sh', guardPath];
    if (name) args.push(name);
    const result = spawnSync(shell, args, { cwd: repo, encoding: 'utf8', timeout: 30 * 60 * 1000 });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /guard scenarios: passed [1-9]\d*, failed 0/);
  });
}

test('the guard never changes settings, installs nothing and deletes nothing of others', () => {
  // uci is only read
  for (const call of code.match(/\buci\b[^\n|;)]*/g) ?? []) {
    assert.match(call, /^uci -q (get|show)\b/, `uci is used for more than reading: ${call}`);
  }
  assert.doesNotMatch(code, /\b(apk|opkg)\s+(add|del|install|remove|update|upgrade)\b/);
  assert.doesNotMatch(code, /\bfw4\s+(restart|flush)\b|\bnft\s+(delete|flush\s+(table|ruleset))\b/);
  assert.doesNotMatch(code, /"?\$R?\/root\//, 'the guard has nothing to do in /root');
  // Podkop: its own init script, stop and start only; none of its files or settings
  const podkop = code.match(/[^\n]*podkop[^\n]*/gi) ?? [];
  for (const line of podkop.filter((l) => /"\$INITD\/podkop" [a-z]/.test(l))) {
    assert.ok(/"\$INITD\/podkop" (enabled|stop|start)\b/.test(line), `Podkop is asked for more than stop and start: ${line.trim()}`);
  }
  assert.doesNotMatch(code, /uci[^\n]*podkop|>\s*"?\$R?\/etc\/(podkop|sing-box)/);
  // every file the guard writes is under its own two directories, the daemon's network file it puts back,
  // or the app's own bypass file restored from the app's own template
  for (const target of code.match(/>>?\s*"\$[A-Z_]+[^"]*"/g) ?? []) {
    assert.match(target, /"\$(LOG|OUT|STATE|RAM|FLASH|LOCK|BYPASS_FILE|1|cs_f|cv_tmp)\b/, `unexpected write target ${target}`);
  }
});

test('reboot is off by default; when switched on it is the last step, rare, never during an upgrade or an install', () => {
  assert.match(code, /^REBOOT=0\b/m, 'the reboot step must be off by default (the owner decided so)');
  assert.match(code, /^PODKOP=0\b/m, 'the Podkop pause must be off by default (the owner decided so)');
  assert.match(code, /REBOOT_MIN_UPTIME=1800/);
  assert.match(code, /REBOOT_GAP=21600/);
  assert.match(code, /FAIL_REBOOT=1800/);
  const busy = code.match(/busy_reason\(\) \{([\s\S]*?)\n\}/)?.[1] ?? '';
  for (const word of ['sysupgrade', 'apk', 'opkg', 'podkop-pe', 'firmware.bin']) {
    assert.ok(busy.includes(word), `busy check does not look for ${word}`);
  }
  const cycle = code.match(/\ncycle\(\) \{([\s\S]*?)\n\}/)?.[1] ?? '';
  assert.ok(cycle.indexOf('if [ -n "$S_BUSY" ]; then') < cycle.indexOf('do_reboot; return 0; fi\n\tif [ "$UP" -ge "$S_NEXT_RESTART" ]'),
    'the busy check must come before the ladder');
});

test('the service restarts the guard without a limit and starts after ZeroTier', () => {
  const init = read('openwrt/etc/init.d/zerotier-guard');
  assert.match(init, /^START=91$/m);
  assert.match(init, /^STOP=\d+$/m);
  assert.match(init, /procd_set_param respawn 3600 5 0/);
  assert.match(init, /guard" save|\$GUARD" save/);
});

test('installers and the upgrade keep-list carry the guard', () => {
  const files = ['openwrt/usr/libexec/zerotier-support/guard', 'openwrt/etc/init.d/zerotier-guard', 'openwrt/lib/upgrade/keep.d/zerotier-guard'];
  const direct = read('router-direct-install.sh');
  const workstation = read('install.sh');
  for (const file of files) {
    assert.ok(direct.includes(`fetch_file "${file}"`), `direct installer omits ${file}`);
    assert.ok(workstation.includes(`"${file}"`), `workstation installer omits ${file}`);
    assert.ok(fs.existsSync(path.join(repo, file)), `${file} is missing`);
  }
  const router = read('router-install.sh');
  assert.match(router, /zerotier-guard/);
  assert.match(router, /"\$GUARD_INIT" enable/);
  const keep = read('openwrt/lib/upgrade/keep.d/zerotier-guard');
  for (const line of ['/usr/libexec/zerotier-support/guard', '/etc/init.d/zerotier-guard', '/etc/zerotier-support/']) {
    assert.ok(keep.split('\n').includes(line), `keep-list omits ${line}`);
  }
});

test('router scripts have Unix line endings in the repository', () => {
  for (const file of [guardPath, 'openwrt/etc/init.d/zerotier-guard', 'openwrt/lib/upgrade/keep.d/zerotier-guard', 'tests/guard-scenarios.sh']) {
    assert.ok(!fs.readFileSync(path.join(repo, file), 'utf8').includes('\r'), `${file} has CRLF`);
  }
});

test('the note for the user says what the guard cannot do', () => {
  const note = read('docs/access-guard.md');
  assert.ok(/не загружается/.test(note), 'the note does not say that a router that does not boot is beyond help');
  assert.ok(/WAN/.test(note), 'the note does not mention a WAN that stays down');
  assert.ok(/откат/i.test(note), 'the note does not say that these models cannot roll a firmware back');
  assert.ok(!/[0-9a-f]{16}/.test(note), 'a network id must not be in the docs');
});
