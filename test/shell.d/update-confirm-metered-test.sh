#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/home"

# The default route goes out wlan0, whose metering and profile come from the
# environment. gum prints the box it was handed and answers with $GUM_ANSWER.
cat >"$stub_bin/ip" <<'STUB'
#!/bin/bash
echo "1.1.1.1 via 192.0.2.1 dev wlan0 src 192.0.2.10 uid 1000"
STUB
cat >"$stub_bin/nmcli" <<'STUB'
#!/bin/bash
case $2 in
  GENERAL.METERED) echo "$TEST_METERED" ;;
  GENERAL.CON-UUID) echo "$TEST_UUID" ;;
  GENERAL.CONNECTION) echo "$TEST_NAME" ;;
esac
STUB
cat >"$stub_bin/gum" <<'STUB'
#!/bin/bash
if [[ $1 == "style" ]]; then
  printf '%s\n' "$@"
else
  [[ $GUM_ANSWER == "yes" ]]
fi
STUB
chmod +x "$stub_bin"/*

remembered="$test_tmp/home/.local/state/omarchy/update-metered-networks"

confirm() {
  HOME="$test_tmp/home" PATH="$stub_bin:$PATH" \
    TEST_METERED="$1" TEST_UUID="$2" TEST_NAME="$3" GUM_ANSWER="$4" \
    bash "$ROOT/bin/omarchy-update-confirm" >"$test_tmp/out" 2>&1
}

warned() {
  grep -q "mobile hotspot or limited data plan" "$test_tmp/out"
}

confirm "no (guessed)" home-uuid "Home" yes || fail "an update on an unmetered network is not confirmed"
! warned || fail "an unmetered network warns about data"
[[ ! -e $remembered ]] || fail "an unmetered network is remembered as acknowledged"
pass "an unmetered network gets the ordinary prompt"

if confirm "yes (guessed)" phone-uuid "Redmi Note 13" no; then
  fail "declining on a hotspot still continues"
fi
warned || fail "a hotspot does not warn about data"
grep -q "Redmi Note 13 is a mobile hotspot" "$test_tmp/out" || fail "the warning does not name the network"
[[ ! -e $remembered ]] || fail "a declined hotspot is remembered as acknowledged"
pass "a hotspot warns, and declining it remembers nothing"

confirm "yes (guessed)" phone-uuid "Redmi Note 13" yes || fail "continuing on a hotspot does not continue"
grep -qx "phone-uuid" "$remembered" || fail "continuing on a hotspot does not remember it"
pass "continuing on a hotspot remembers that network"

confirm "yes (guessed)" phone-uuid "Redmi Note 13" yes || fail "a remembered hotspot is not confirmed"
! warned || fail "a remembered hotspot warns again"
(( $(wc -l <"$remembered") == 1 )) || fail "a remembered hotspot is recorded twice"
pass "a remembered hotspot never warns again"

confirm "yes" friend-uuid "Pixel 8" yes || fail "an explicitly metered network is not confirmed"
grep -q "Pixel 8 is a mobile hotspot" "$test_tmp/out" || fail "a different metered network does not warn"
pass "a different metered network still warns once"

confirm "yes (guessed)" colon-uuid 'Cafe\:Upstairs' no || true
grep -q "Cafe:Upstairs is a mobile hotspot" "$test_tmp/out" || fail "the warning shows nmcli's escaped colons" "$(cat "$test_tmp/out")"
pass "the warning unescapes the network name"
