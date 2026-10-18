#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

install_script="$ROOT/bin/omarchy-install-gaming-battlenet"

[[ ! -f $ROOT/applications/battlenet.desktop ]] || fail "Battle.net launcher is not part of default application refresh"
[[ -f $ROOT/default/applications/battlenet.desktop ]] || fail "Battle.net launcher template is available to the installer"
grep -F '$OMARCHY_PATH/default/applications/battlenet.desktop' "$install_script" >/dev/null ||
  fail "Battle.net installer installs the launcher from the installer-only template"

pass "Battle.net launcher is only installed by the Battle.net installer"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/gum" <<'SH'
#!/bin/bash
case "$1" in
  confirm)
    [[ ${STUB_GUM_CONFIRM:-1} == 1 ]]
    ;;
  *)
    exit 0
    ;;
esac
SH

cat >"$mock_bin/update-desktop-database" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$mock_bin"/*

fake_home="$test_tmp/home"
mkdir -p "$fake_home/Games/battlenet/testgame" "$fake_home/.local/share/applications" "$fake_home/.cache/omarchy"
touch "$fake_home/Games/battlenet/testgame/game.exe"
touch "$fake_home/.local/share/applications/battlenet.desktop"
touch "$fake_home/.cache/omarchy/Battle.net-Setup.exe"

# Test 1: Decline confirmation aborts without deleting files
STUB_GUM_CONFIRM=0 HOME="$fake_home" OMARCHY_PATH="$ROOT" PATH="$mock_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/omarchy-remove-gaming-battlenet"
[[ -d "$fake_home/Games/battlenet" ]] || fail "cancelling confirmation must preserve Games/battlenet"
[[ -f "$fake_home/Games/battlenet/testgame/game.exe" ]] || fail "cancelling confirmation must preserve installed games"
[[ -f "$fake_home/.local/share/applications/battlenet.desktop" ]] || fail "cancelling confirmation must preserve desktop entry"
pass "omarchy-remove-gaming-battlenet preserves prefix and games when confirmation is declined"

# Test 2: Accept confirmation deletes prefix and desktop entry
STUB_GUM_CONFIRM=1 HOME="$fake_home" OMARCHY_PATH="$ROOT" PATH="$mock_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/omarchy-remove-gaming-battlenet"
[[ ! -e "$fake_home/Games/battlenet" ]] || fail "confirming removal deletes Games/battlenet"
[[ ! -e "$fake_home/.local/share/applications/battlenet.desktop" ]] || fail "confirming removal deletes desktop entry"
[[ ! -e "$fake_home/.cache/omarchy/Battle.net-Setup.exe" ]] || fail "confirming removal deletes cached installer"
pass "omarchy-remove-gaming-battlenet removes Battle.net prefix and files when confirmed"
