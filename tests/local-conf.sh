#!/bin/sh
set -eu
work=$(mktemp -d /tmp/zrs-merge-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
# Load functions without invoking the CLI dispatcher.
sed '/^case "${1:-status}" in/,$d' "$1" > "$work/functions"
. "$work/functions"
printf '%s\n' '{"physical":{"192.0.2.0/24":{"blacklist":true}},"settings":{"primaryPort":9993,"custom":true,"interfacePrefixBlacklist":["tun","warp"]}}' > "$work/input"
merge_local_conf "$work/input" warp > "$work/once"
merge_local_conf "$work/once" warp > "$work/twice"
cmp "$work/once" "$work/twice"
jq -e '.physical["192.0.2.0/24"].blacklist and .settings.custom and .settings.primaryPort == 9993 and .settings.secondaryPort == 25534 and .settings.tertiaryPort == 34923 and .settings.interfacePrefixBlacklist == ["tun","warp"]' "$work/twice" >/dev/null
merge_local_conf "$work/input" '' > "$work/no-warp"
jq -e '.settings.interfacePrefixBlacklist == ["tun","warp"]' "$work/no-warp" >/dev/null
echo '{}' > "$work/empty"
merge_local_conf "$work/empty" warp2 | jq -e '.settings.interfacePrefixBlacklist == ["warp2"]' >/dev/null
echo '{"settings":{"interfacePrefixBlacklist":"invalid"}}' > "$work/bad"
if merge_local_conf "$work/bad" warp >/dev/null 2>&1; then exit 1; fi
echo '{"settings":[]}' > "$work/bad"
if merge_local_conf "$work/bad" warp >/dev/null 2>&1; then exit 1; fi
echo 'PASS: local.conf preserves keys, exclusions, no-WARP state; idempotent; rejects malformed settings'
