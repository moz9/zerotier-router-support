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

  const configure = helper.match(/configure_network_apply\(\)\s*\{[\s\S]*?\n\}/)?.[0] ?? "";
  const restart = helper.match(/restart_service\(\)\s*\{[\s\S]*?\n\}/)?.[0] ?? "";
  assert.ok(configure.indexOf("ensure_transport_independence") < configure.indexOf("/etc/init.d/zerotier restart"));
  assert.ok(restart.indexOf("ensure_transport_independence") < restart.indexOf("/etc/init.d/zerotier restart"));
});

test("sysupgrade retention and both installers include the same support files", () => {
  const keepPath = "openwrt/lib/upgrade/keep.d/zerotier-router-support";
  const keep = read(keepPath);
  for (const file of ["/etc/zerotier.conf", "/etc/zerotier-router-support.conf", "/etc/nftables.d/20-podkop-zerotier-bypass.nft", "/usr/libexec/zerotier-support/helper"]) {
    assert.ok(keep.includes(file), `retention list omits ${file}`);
  }
  assert.ok(read("install.sh").includes(keepPath));
  assert.ok(read("router-direct-install.sh").includes(keepPath));
  assert.ok(read("router-install.sh").includes('${OVERLAY_DIR}/lib/upgrade/keep.d/zerotier-router-support'));
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

test("the published one-liner is the universal install and update entrypoint", () => {
  const readme = read("README.md");
  const router = read("router-install.sh");

  assert.match(readme, /универсальн[^\n]*установк[^\n]*обновлен/i);
  assert.match(readme, /wget -qO- https:\/\/raw\.githubusercontent\.com\/moz9\/zerotier-router-support\/main\/router-direct-install\.sh \| sh/);
  assert.match(router, /"\$\{HELPER_DIR\}\/helper" install/);
});

test("install automatically upgrades a running configured ZeroTier and verifies recovery", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");
  const installCase = helper.match(/\n\s*install\)\n([\s\S]*?)\n\s*;;/)?.[1] ?? "";
  const upgrade = helper.match(/install_or_upgrade\(\)\s*\{([\s\S]*?)\n\}/)?.[1] ?? "";

  assert.match(installCase, /install_or_upgrade/);
  assert.match(upgrade, /snapshot_transport_state/);
  assert.match(upgrade, /ensure_transport_independence/);
  assert.match(upgrade, /transport_restart_required/);
  assert.match(upgrade, /restart_and_verify_transport/);
  assert.match(upgrade, /restore_transport_snapshot/);
  assert.doesNotMatch(upgrade, /zerotier\.\$\{NETWORK_SECTION\}\.id/);
});

test("upgrade validates the existing virtual networks instead of replacing them", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");

  assert.match(helper, /configured_network_ids\(\)/);
  assert.match(helper, /wait_for_zerotier_ready\(\)/);
  assert.match(helper, /zerotier-cli listnetworks -j/);
  assert.match(helper, /status[^\n]*OK/);
  assert.match(helper, /автоматический откат/i);
});

test("bypass reconciliation removes temporary random ports atomically after restart", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");

  assert.match(helper, /sync_live_bypass_set\(\)/);
  assert.match(helper, /flush set inet fw4 podkop_zerotier_udp_ports/);
  assert.match(helper, /add element inet fw4 podkop_zerotier_udp_ports/);
  assert.match(helper, /nft -f/);
  assert.match(helper, /restart_and_verify_transport[\s\S]*ensure_transport_independence/);
});

test("critical firewall and restart failures are handled explicitly under BusyBox ash", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");

  assert.match(helper, /if ! fw4 check; then[\s\S]*return 1/);
  assert.match(helper, /if ! \/etc\/init\.d\/firewall reload[\s\S]*\/etc\/init\.d\/firewall restart/);
  assert.match(helper, /if ! \/etc\/init\.d\/zerotier restart; then[\s\S]*return 1/);
});

test("status parses network names with spaces from JSON instead of fixed text columns", () => {
  const helper = read("openwrt/usr/libexec/zerotier-support/helper");
  const collect = helper.match(/collect_state\(\)\s*\{([\s\S]*?)\n\}/)?.[1] ?? "";

  assert.match(collect, /zerotier-cli listnetworks -j/);
  assert.match(collect, /portDeviceName/);
  assert.match(collect, /assignedAddresses/);
  assert.doesNotMatch(collect, /network_status=.*awk '\{print \$6\}'/);
});
