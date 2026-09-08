import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../openwrt/usr/libexec/zerotier-support/helper', import.meta.url), 'utf8');
test('creates an idempotent echo-request exception restricted to the ZeroTier zone', () => {
  const body = source.match(/ensure_ping_rule\(\)\s*\{([\s\S]*?)\n\}/)?.[1];
  assert.ok(body, 'missing isolated ping rule function');
  const shell = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/sh';
  const fixture = `set -eu\nFW_ZONE=zt_support\nuci() { printf '%s\\n' "$*"; }\nensure_ping_rule() {${body}\n}\nensure_ping_rule\n`;
  const actual = execFileSync(shell, ['-c', fixture], { encoding:'utf8' });
  assert.match(actual, /set firewall\.allow_zt_support_ping=rule/);
  assert.match(actual, /set firewall\.allow_zt_support_ping\.src=zt_support/);
  assert.match(actual, /set firewall\.allow_zt_support_ping\.proto=icmp/);
  assert.match(actual, /set firewall\.allow_zt_support_ping\.icmp_type=echo-request/);
  assert.match(actual, /set firewall\.allow_zt_support_ping\.family=ipv4/);
  assert.match(actual, /set firewall\.allow_zt_support_ping\.target=ACCEPT/);
  assert.doesNotMatch(actual, /src=wan|dest=|add firewall rule|input=ACCEPT/);
  assert.equal(execFileSync(shell, ['-c',fixture],{encoding:'utf8'}), actual);
});
test('every firewall reconciliation installs ping before validation and commit', () => {
  const body=source.match(/ensure_firewall\(\)\s*\{([\s\S]*?)\n\}/)?.[1] ?? '';
  assert.ok(body.includes('ensure_ping_rule || return 1'));
  assert.ok(body.indexOf('ensure_ping_rule') < body.indexOf('fw4 check'));
  assert.ok(body.indexOf('ensure_ping_rule') < body.indexOf('uci commit firewall'));
});
