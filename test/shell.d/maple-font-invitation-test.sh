#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stubs"
export OMARCHY_PATH=$ROOT TEST_LOG=$work/log CURRENT_FONT="JetBrainsMono Nerd Font" INSTALLED_METHOD=none

cat >"$work/stubs/omarchy-notification-send" <<'SH'
#!/bin/bash
[[ -n ${NOTIFY_FAILS:-} ]] && exit 1
while (($# > 0)); do
  if [[ $1 == "--exec" ]]; then shift; echo "exec:$*" >>"$TEST_LOG"; break; fi
  shift
done
SH
printf '#!/bin/bash\necho "$CURRENT_FONT"\n' >"$work/stubs/omarchy-font-current"
printf '#!/bin/bash\necho "{\\"installed_method\\": \\"$INSTALLED_METHOD\\"}"\n' >"$work/stubs/omarchy-input-method"
chmod +x "$work/stubs/"*
export PATH="$work/stubs:$ROOT/bin:$PATH"

invite() {
  HOME=$1 omarchy-font-invite-maple
}

home=$work/home
invite "$home"
[[ $(cat "$TEST_LOG") == "exec:omarchy-install-font Maple Mono CN maplemono-nf-cn Maple Mono NF CN" ]] ||
  fail "the invitation installs and sets Maple Mono NF CN when clicked" "$(cat "$TEST_LOG")"
pass "the invitation installs and sets Maple Mono NF CN when clicked"

invite "$home"
[[ $(grep -c exec: "$TEST_LOG") == 1 ]] || fail "a dismissed invitation is not sent again"
pass "a dismissed invitation is not sent again"

: >"$TEST_LOG"
CURRENT_FONT="Maple Mono NF CN" invite "$work/maple-home"
[[ ! -s $TEST_LOG && ! -e $work/maple-home/.local/state/omarchy/done/maple-font-invitation ]] ||
  fail "someone already on Maple Mono is not invited, and keeps the invitation for later"
pass "someone already on Maple Mono is not invited"

: >"$TEST_LOG"
if NOTIFY_FAILS=1 invite "$work/down-home" 2>/dev/null; then
  fail "an invitation that could not be sent reports failure"
fi
invite "$work/down-home"
[[ -s $TEST_LOG ]] || fail "an invitation that could not be sent is offered again"
pass "an invitation that could not be sent is offered again"

# First boot invites a Chinese keyboard, and no other.
for method in pinyin chewing cangjie5 mozc hangul none; do
  : >"$TEST_LOG"
  HOME=$work/first-$method INSTALLED_METHOD=$method bash "$ROOT/install/user/first-run/maple-font.sh"
  if [[ $method == "pinyin" || $method == "chewing" || $method == "cangjie5" ]]; then
    [[ -s $TEST_LOG ]] || fail "first boot with $method invites to Maple Mono"
  else
    [[ ! -s $TEST_LOG ]] || fail "first boot with $method sends no Maple Mono invitation"
  fi
done
pass "first boot invites a Chinese keyboard to Maple Mono, and no other"

grep -q 'install/user/first-run/maple-font.sh' "$ROOT/bin/omarchy-provision-first-run" || fail "first run sends the invitation"
pass "first run sends the invitation"
