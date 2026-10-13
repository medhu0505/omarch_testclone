#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
export CALL_LOG="$tmp_dir/calls"
real_udevadm=$(command -v udevadm || true)
export PATH="$tmp_dir/bin:$PATH"

printf '#!/bin/bash\necho "udevadm $*" >> "$CALL_LOG"\n' > "$tmp_dir/bin/udevadm"
cat > "$tmp_dir/bin/omarchy-hw-aarch64-qualcomm" <<'SH'
#!/bin/bash
[[ ${IS_QUALCOMM:-1} == 1 ]]
SH
cat > "$tmp_dir/bin/sudo" <<'SH'
#!/bin/bash
"$@"
SH
chmod +x "$tmp_dir/bin/"*

setup="$ROOT/install/hardware/qualcomm/charger-events.sh"
migration="$ROOT/migrations/1791908710.sh"
rules="$tmp_dir/etc/udev/rules.d/71-omarchy-qualcomm-charger-events.rules"
trigger='udevadm trigger --action=change --subsystem-match=power_supply --sysname-match=qcom-battmgr-ac --sysname-match=qcom-battmgr-usb --sysname-match=qcom-battmgr-wls'

run_migration() {
  : > "$CALL_LOG"
  OMARCHY_QUALCOMM_CHARGER_RULES="$rules" bash -euo pipefail "$migration" >/dev/null 2>&1
}

IS_QUALCOMM=0 run_migration
[[ ! -e $rules && ! -s $CALL_LOG ]] && pass "other machines are left alone" || fail "other machines are left alone"

run_migration
[[ -f $rules ]] && pass "Snapdragon machines get the rule" || fail "Snapdragon machines get the rule"
[[ $(stat -c %a "$rules") == "644" ]] && pass "the rule is world-readable, root-writable" || fail "the rule is world-readable, root-writable"
grep -Fxq "udevadm control --reload" "$CALL_LOG" && grep -Fxq "$trigger" "$CALL_LOG" &&
  pass "UPower rereads the charger supplies without a reboot" || fail "UPower rereads the charger supplies without a reboot"

run_migration
[[ ! -s $CALL_LOG ]] && pass "another user's run is a no-op" || fail "another user's run is a no-op"

echo '# administrator copy' > "$rules"
run_migration
grep -Fxq '# administrator copy' "$rules" && pass "an existing rule file is kept" || fail "an existing rule file is kept"

# The rule replays events on the charger supplies when the battery reports. If
# it matched a supply it replays, every replay would fire it again.
rule_line=$(sed -n '/^ACTION==/p' "$setup")
[[ $rule_line == *'KERNEL=="qcom-battmgr-bat"'* && $rule_line != *'--sysname-match=qcom-battmgr-bat'* ]] &&
  pass "the rule cannot trigger itself" || fail "the rule cannot trigger itself"

# New installs get the same rule from the hardware setup, only on Snapdragon.
setup_rules_dir="$tmp_dir/setup/rules.d"
(
  omarchy-hw-aarch64-qualcomm() { return 1; }
  OMARCHY_QUALCOMM_UDEV_RULES_DIR="$setup_rules_dir"
  source "$setup"
)
[[ ! -e $setup_rules_dir ]] && pass "new installs on other machines get no rule" || fail "new installs on other machines get no rule"
(
  omarchy-hw-aarch64-qualcomm() { return 0; }
  OMARCHY_QUALCOMM_UDEV_RULES_DIR="$setup_rules_dir"
  source "$setup"
)
setup_rule="$setup_rules_dir/71-omarchy-qualcomm-charger-events.rules"
rule_from() { sed -n "/$2/,/^ *$3\$/p" "$1" | sed '1d;$d;s/^ *//'; }
if [[ -f $setup_rule && $(<"$setup_rule") == "$(rule_from "$migration" '"$rules" <<' RULES)" ]]; then
  pass "new installs and the migration write the same rule"
else
  fail "new installs and the migration write the same rule"
fi
grep -Fq 'hardware/qualcomm/charger-events.sh' "$ROOT/install/hardware/all.sh" &&
  pass "the hardware setup runs for new installs" || fail "the hardware setup runs for new installs"

if [[ -n $real_udevadm ]] && "$real_udevadm" verify --help >/dev/null 2>&1; then
  "$real_udevadm" verify --no-summary "$setup_rule" >/dev/null 2>&1 &&
    pass "udevadm verify accepts the rule" || fail "udevadm verify accepts the rule"
fi
