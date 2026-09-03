import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(repo, relative), "utf8");

test("ships a persistent early-output bypass for all fixed ZeroTier UDP ports", () => {
  const nft = read("openwrt/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft");

  assert.match(nft, /elements\s*=\s*\{\s*9993,\s*25534,\s*34923\s*\}/);
  assert.match(nft, /hook output priority -151/);
  assert.match(nft, /udp sport @podkop_zerotier_udp_ports/);
  assert.match(nft, /meta mark set 0x00200000/);
});

test("ships fixed secondary and tertiary ports without embedding a network id", () => {
  const config = read("openwrt/usr/libexec/zerotier-support/zerotier-router-support.conf");
  const parsed = JSON.parse(config);

  assert.equal(parsed.settings.secondaryPort, 25534);
  assert.equal(parsed.settings.tertiaryPort, 34923);
  assert.doesNotMatch(config, /[0-9a-f]{16}/i);
});

test("direct and workstation installers deliver both transport templates", () => {
  const direct = read("router-direct-install.sh");
  const workstation = read("install.sh");
  const router = read("router-install.sh");

  for (const file of [
    "openwrt/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft",
    "openwrt/usr/libexec/zerotier-support/zerotier-router-support.conf",
  ]) {
    assert.ok(direct.includes(`fetch_file "${file}"`), `direct installer omits ${file}`);
    assert.ok(workstation.includes(`"${file}"`), `workstation installer omits ${file}`);
  }

  assert.match(router, /20-podkop-zerotier-bypass\.nft/);
  assert.match(router, /zerotier-router-support\.conf/);
});

test("helper applies the bypass before firewall reload and before every ZeroTier restart", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");

  assert.match(helper, /ensure_transport_independence\(\)/);
  assert.match(helper, /zerotier\.global\.port=9993/);
  assert.match(helper, /zerotier\.global\.local_conf_path/);
  assert.match(helper, /\/etc\/nftables\.d\/20-podkop-zerotier-bypass\.nft/);

  const configure = helper.match(/configure_network\(\)\s*\{[\s\S]*?\n\}/)?.[0] ?? "";
  const restart = helper.match(/restart_service\(\)\s*\{[\s\S]*?\n\}/)?.[0] ?? "";
  assert.ok(configure.indexOf("ensure_transport_independence") < configure.indexOf("/etc/init.d/zerotier restart"));
  assert.ok(restart.indexOf("ensure_transport_independence") < restart.indexOf("/etc/init.d/zerotier restart"));
});

test("upgrade protects the currently random ports before the next ZeroTier restart", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");

  assert.match(helper, /current_zerotier_ports\(\)/);
  assert.match(helper, /runtime_port/);
  assert.match(helper, /zrs-bypass-candidate/);
  assert.match(helper, /podkop_zerotier_udp_ports/);
});

test("uninstall instructions remove only the support-owned transport files", () => {
  const readme = read("README.md");

  assert.match(readme, /\/etc\/nftables\.d\/20-podkop-zerotier-bypass\.nft/);
  assert.match(readme, /\/etc\/zerotier-router-support\.conf/);
  assert.doesNotMatch(readme, /rm -rf \/etc\/nftables\.d/);
});
