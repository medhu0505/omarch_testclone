#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
mkdir -p "$mock_bin"

# Stand in for mise, the rea shim it creates and npx, logging each call.
# OMARCHY_TEST_FAIL names the one call that fails, the way a failed download
# or a cancelled setup would.
for command in mise rea npx; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
call="${0##*/} $*"
echo "$call" >>"$OMARCHY_TEST_LOG"
[[ $call == "rea --version" ]] && echo "6.7.0"
[[ $call != "${OMARCHY_TEST_FAIL:-}" ]]
SH
done
chmod +x "$mock_bin"/*

run() {
  HOME="$test_tmp/home" OMARCHY_PATH="$ROOT" OMARCHY_TEST_LOG="$log" \
    PATH="$mock_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/$1" >"$test_tmp/output" 2>&1
}

calls() {
  paste -sd '|' "$log"
}

: >"$log"
run omarchy-install-ai-rea || fail "installing REA succeeds" "$(cat "$test_tmp/output")"
[[ $(calls) == "mise use -g rea|rea --version|npx -y rea-agents@6.7.0 setup" ]] ||
  fail "the install adds REA to mise, then sets up agents through npx at the same version" "$(calls)"
grep -q 'REA has been installed.' "$test_tmp/output" || fail "a finished setup reports the install"
pass "the installer adds REA to mise and registers it with agents through npx at the installed version"

: >"$log"
if OMARCHY_TEST_FAIL="mise use -g rea" run omarchy-install-ai-rea; then
  fail "a failed download fails the install"
fi
[[ $(calls) == "mise use -g rea" ]] || fail "setup does not start after a failed download" "$(calls)"
pass "a failed download stops the install before setup"

: >"$log"
OMARCHY_TEST_FAIL="npx -y rea-agents@6.7.0 setup" run omarchy-install-ai-rea || fail "a cancelled setup still leaves REA installed" "$(cat "$test_tmp/output")"
grep -q "Run 'npx -y rea-agents@6.7.0 setup'" "$test_tmp/output" || fail "a cancelled setup says how to finish it"
pass "a cancelled setup keeps REA and says how to register it later"

: >"$log"
run omarchy-remove-ai-rea || fail "removing REA succeeds" "$(cat "$test_tmp/output")"
[[ $(calls) == "rea uninstall --purge-data|mise uninstall rea --all|mise rm -g rea" ]] ||
  fail "the removal unregisters REA from its agents before mise removes it" "$(calls)"
pass "the removal unregisters REA, then uninstalls it and drops it from mise"

: >"$log"
if OMARCHY_TEST_FAIL="rea uninstall --purge-data" run omarchy-remove-ai-rea; then
  fail "a failed unregistration fails the removal"
fi
[[ $(calls) == "rea uninstall --purge-data" ]] || fail "REA stays installed while agents still point at it" "$(calls)"
pass "a failed unregistration keeps REA installed"
