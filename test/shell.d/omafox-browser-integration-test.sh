#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
calls="$test_tmp/calls"
omarchy_path="$test_tmp/omarchy"
firefox_dist="$test_tmp/usr/lib/firefox/distribution"
zen_dist="$test_tmp/opt/zen-browser/distribution"
migration="$test_tmp/migration.sh"
mkdir -p "$mock_bin" "$test_tmp/home" "$omarchy_path/install/helpers" "$omarchy_path/default/firefox"

# Keep the real migration and helper, with policy paths confined to the fixture.
sed -e "s|/usr/lib/firefox/distribution|$firefox_dist|g" \
  -e "s|/opt/zen-browser/distribution|$zen_dist|g" \
  "$ROOT/migrations/1787954420.sh" >"$migration"
cp "$ROOT/default/firefox/policies.json" "$omarchy_path/default/firefox/policies.json"
cat >"$omarchy_path/install/helpers/browser-policy.sh" <<'SH'
source "$ROOT/install/helpers/browser-policy.sh"

# Replace as_root even when the test itself is root. Strip ownership arguments
# so installs work for unprivileged test users too.
as_root() {
  printf 'as_root:%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
  if [[ $1 == "install" ]]; then
    shift
    local args=()
    while (( $# )); do
      case $1 in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    command install "${args[@]}"
  else
    "$@"
  fi
}

# Fixture policies belong to the test user; simulate trusted ownership.
browser_policy_firefox_policy_file_ok() { [[ -f $1 && ! -L $1 ]]; }
browser_policy_purge_dir() { :; }
SH

cat >"$mock_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ " ${OMARCHY_TEST_INSTALLED_PACKAGES:-} " == *" $1 "* ]]
SH

cat >"$mock_bin/omarchy-pkg-aur-add" <<'SH'
#!/bin/bash
printf 'package:%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
SH

cat >"$mock_bin/omafox" <<'SH'
#!/bin/bash
printf 'omafox:%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
SH

cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
printf 'Unexpected sudo call: %s\n' "$*" >&2
exit 1
SH

chmod +x "$mock_bin"/*

export PATH="$mock_bin:$PATH"
export HOME="$test_tmp/home"
export OMARCHY_PATH="$omarchy_path"
export OMARCHY_TEST_CALLS="$calls"

jq -e '
  .policies.ExtensionSettings["@omafox"] == {
    "installation_mode": "normal_installed",
    "install_url": "https://addons.mozilla.org/firefox/downloads/latest/omafox/latest.xpi"
  }
' "$ROOT/default/firefox/policies.json" >/dev/null || fail "Firefox policy normally installs Omafox from AMO"
pass "Firefox policy normally installs Omafox from AMO"

run_migration() {
  : >"$calls"
  rm -rf "$test_tmp/usr" "$test_tmp/opt"
  OMARCHY_TEST_INSTALLED_PACKAGES=$1 bash -euo pipefail "$migration" >/dev/null
}

run_migration ""
[[ ! -s $calls ]] || fail "Omafox migration skips systems without Firefox or Zen" "$(<"$calls")"
pass "Omafox migration skips systems without Firefox or Zen"

run_migration "firefox"
grep -Fxq 'package:omafox' "$calls" || fail "Omafox migration installs the package for Firefox"
cmp -s "$ROOT/default/firefox/policies.json" "$firefox_dist/policies.json" || fail "Omafox migration installs the Firefox policy"
[[ ! -e $zen_dist ]] || fail "Omafox migration does not install a Zen policy when Zen is absent"
grep -Fxq 'omafox:setup' "$calls" || fail "Omafox migration configures the Firefox user"
pass "Omafox migration configures existing Firefox installs"

run_migration "zen-browser-bin"
grep -Fxq 'package:omafox' "$calls" || fail "Omafox migration installs the package for Zen"
cmp -s "$ROOT/default/firefox/policies.json" "$zen_dist/policies.json" || fail "Omafox migration installs the Zen policy"
[[ ! -e $firefox_dist ]] || fail "Omafox migration does not install a Firefox policy when Firefox is absent"
grep -Fxq 'omafox:setup' "$calls" || fail "Omafox migration configures the Zen user"
pass "Omafox migration configures existing Zen installs"

run_migration "firefox zen-browser-bin"
[[ $(grep -Fxc 'package:omafox' "$calls") == 1 ]] || fail "Omafox migration installs the package once when both browsers exist"
cmp -s "$ROOT/default/firefox/policies.json" "$firefox_dist/policies.json" || fail "Omafox migration refreshes the Firefox policy"
cmp -s "$ROOT/default/firefox/policies.json" "$zen_dist/policies.json" || fail "Omafox migration refreshes the Zen policy"
[[ $(grep -Fxc 'omafox:setup' "$calls") == 1 ]] || fail "Omafox migration runs setup once when both browsers exist"
pass "Omafox migration configures both installed browsers in one pass"

jq '
  .policies.DisableTelemetry = true |
  .policies.ExtensionSettings["@omafox"] = {
    "installation_mode": "blocked",
    "blocked_install_message": "Disabled by administrator"
  }
' "$ROOT/default/firefox/policies.json" >"$test_tmp/blocked-policies.json"
policy_before=$(jq -S . "$test_tmp/blocked-policies.json")
cp "$test_tmp/blocked-policies.json" "$firefox_dist/policies.json"
cp "$test_tmp/blocked-policies.json" "$zen_dist/policies.json"

for attempt in 1 2; do
  OMARCHY_TEST_INSTALLED_PACKAGES="firefox zen-browser-bin" bash -euo pipefail "$migration" >/dev/null
  for dir in "$firefox_dist" "$zen_dist"; do
    [[ $(jq -S . "$dir/policies.json") == "$policy_before" ]] ||
      fail "Omafox migration preserves an existing installation ban in $dir"
  done
done
pass "Omafox migration preserves Firefox and Zen installation bans on repeated runs"
