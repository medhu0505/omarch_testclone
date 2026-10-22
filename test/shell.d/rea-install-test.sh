#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
mkdir -p "$mock_bin"

# Stand in for mise, the rea shim it creates and npx, logging each call, with
# the release cooldown mise was given. OMARCHY_TEST_FAIL names the one call
# that fails, the way a failed download or a cancelled setup would.
for command in mise rea npx; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
call="${0##*/} $*"
echo "$call${MISE_MINIMUM_RELEASE_AGE:+ [age=$MISE_MINIMUM_RELEASE_AGE]}" >>"$OMARCHY_TEST_LOG"
[[ $call == "rea --version" ]] && echo "6.7.0"
[[ $call != "${OMARCHY_TEST_FAIL:-}" ]]
SH
done

# The remover asks through gum before going on without REA's own uninstall.
# The stub answers "no" unless a test says otherwise, and logs the question.
cat >"$mock_bin/gum" <<'SH'
#!/bin/bash
echo "gum $*" >>"$OMARCHY_TEST_LOG"
exit "${TEST_GUM_STATUS:-1}"
SH
chmod +x "$mock_bin"/*

export HOME="$test_tmp/home" OMARCHY_PATH="$ROOT" OMARCHY_TEST_LOG="$log"
export PATH="$mock_bin:$ROOT/bin:$PATH"

run() {
  "$ROOT/bin/$1" </dev/null >"$test_tmp/output" 2>&1
}

# script(1) puts the command on a pty, the only way -t 0 answers true here.
run_on_terminal() {
  script -qec "'$ROOT/bin/$1'" /dev/null >"$test_tmp/output" 2>&1
}

calls() {
  grep -v '^gum ' "$log" | paste -sd '|'
}

: >"$log"
run omarchy-install-ai-rea || fail "installing REA succeeds" "$(cat "$test_tmp/output")"
[[ $(calls) == "mise use -g rea [age=0]|rea --version|npx -y rea-agents@6.7.0 setup" ]] ||
  fail "the install adds REA to mise without a cooldown, then sets up agents through npx at the same version" "$(calls)"
grep -q 'REA has been installed.' "$test_tmp/output" || fail "a finished setup reports the install"
pass "the installer adds REA to mise and registers it with agents through npx at the installed version"

: >"$log"
if OMARCHY_TEST_FAIL="mise use -g rea" run omarchy-install-ai-rea; then
  fail "a failed download fails the install"
fi
[[ $(calls) == "mise use -g rea [age=0]" ]] || fail "setup does not start after a failed download" "$(calls)"
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

# Without a terminal there is nobody to ask, so a failed unregistration keeps
# REA installed rather than leave agents pointing at it unasked.
: >"$log"
if OMARCHY_TEST_FAIL="rea uninstall --purge-data" run omarchy-remove-ai-rea; then
  fail "a failed unregistration fails the removal without a terminal"
fi
[[ $(calls) == "rea uninstall --purge-data" ]] || fail "REA stays installed when nobody can be asked" "$(calls)"
! grep -q '^gum ' "$log" || fail "nobody is asked without a terminal"
pass "a failed unregistration keeps REA installed when nobody can be asked"

: >"$log"
if OMARCHY_TEST_FAIL="rea uninstall --purge-data" run_on_terminal omarchy-remove-ai-rea; then
  fail "declining to go on keeps the removal failed"
fi
grep -q '^gum confirm --default=false ' "$log" || fail "a failed unregistration asks, defaulting to no" "$(cat "$log")"
[[ $(calls) == "rea uninstall --purge-data" ]] || fail "declining keeps REA installed" "$(calls)"
pass "a failed unregistration asks, and declining keeps REA installed"

: >"$log"
OMARCHY_TEST_FAIL="rea uninstall --purge-data" TEST_GUM_STATUS=0 run_on_terminal omarchy-remove-ai-rea ||
  fail "agreeing to go on removes REA" "$(cat "$test_tmp/output")"
[[ $(calls) == "rea uninstall --purge-data|mise uninstall rea --all|mise rm -g rea" ]] ||
  fail "agreeing removes REA from mise anyway" "$(calls)"
grep -q 'server named rea' "$test_tmp/output" || fail "agreeing says which agent entries to check by hand"
pass "a failed unregistration can still remove REA when the user agrees"
