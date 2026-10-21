#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/lenovo/fix-thinkpad-t14-display-power.sh"
all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1792574886.sh"
config_name=thinkpad-t14-display-power.conf

bash -n "$leaf" || fail "the ThinkPad T14 display fix has valid syntax"
bash -n "$migration" || fail "the ThinkPad T14 display migration has valid syntax"

grep -q 'run_logged .*hardware/lenovo/fix-thinkpad-t14-display-power.sh' "$all" ||
  fail "the ThinkPad T14 display fix runs during hardware setup"
pass "the ThinkPad T14 display fix runs during hardware setup"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

# omarchy-hw-match greps the fixed /sys/class/dmi/id files; point it at fixtures.
mkdir -p "$scratch/dmi"
cat >"$scratch/bin/omarchy-hw-match" <<'SH'
#!/bin/bash
grep -qi -- "$1" "$DMI_NAME_FILE" 2>/dev/null ||
  grep -qi -- "$1" "$DMI_FAMILY_FILE" 2>/dev/null
SH
cat >"$scratch/bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALL_LOG"
[[ ${TEST_SUDO_STATUS:-0} == 0 ]] || exit "$TEST_SUDO_STATUS"
exec "$@"
SH
cat >"$scratch/bin/limine-mkinitcpio" <<'SH'
#!/bin/bash
printf 'limine-mkinitcpio %s\n' "$*" >>"$CALL_LOG"
exit "${TEST_MKINITCPIO_STATUS:-0}"
SH
cat >"$scratch/bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ ${TEST_LIMINE_PRESENT:-1} == 1 ]]
SH
cat >"$scratch/bin/omarchy-state" <<'SH'
#!/bin/bash
printf 'omarchy-state %s\n' "$*" >>"$CALL_LOG"
SH
chmod +x "$scratch/bin"/*

export CALL_LOG="$scratch/calls.log"

# The leaf runs as root during hardware setup and as root from the migration, so
# it writes the drop-in without sudo. The stub above only stands in for the
# privilege the migration takes.
run_leaf() {
  local product_name="$1" product_family="$2" state="$3"
  : >"$CALL_LOG"
  printf '%s\n' "$product_name" >"$scratch/dmi/product_name"
  printf '%s\n' "$product_family" >"$scratch/dmi/product_family"
  DMI_NAME_FILE="$scratch/dmi/product_name" DMI_FAMILY_FILE="$scratch/dmi/product_family" \
    PATH="$scratch/bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_LIMINE_CONFIG_DIR="$state/limine-entry-tool.d" \
    bash -eE -c 'source "$1"' bash "$leaf" </dev/null
}

run_migration() {
  local product_name="$1" product_family="$2" state="$3"
  : >"$CALL_LOG"
  printf '%s\n' "$product_name" >"$scratch/dmi/product_name"
  printf '%s\n' "$product_family" >"$scratch/dmi/product_family"
  DMI_NAME_FILE="$scratch/dmi/product_name" DMI_FAMILY_FILE="$scratch/dmi/product_family" \
    PATH="$scratch/bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_LIMINE_CONFIG_DIR="$state/limine-entry-tool.d" \
    OMARCHY_THINKPAD_T14_DISPLAY_POWER_MARKER="$state/marker" \
    bash -euo pipefail "$migration" </dev/null
}

config="$scratch/t14/limine-entry-tool.d/$config_name"

run_leaf "20W1S7PB00" "ThinkPad T14 Gen 2i" "$scratch/t14"
[[ -f $config ]] || fail "the ThinkPad T14 Gen 2i gets the display drop-in"
grep -Fq 'i915.enable_dc=0' "$config" || fail "the drop-in turns off display power saving" "$(cat "$config")"
grep -Fq 'i915.enable_fbc=0' "$config" || fail "the drop-in turns off frame-buffer compression" "$(cat "$config")"
pass "the ThinkPad T14 Gen 2i gets the display drop-in"

# Rerunning the leaf must not change the drop-in: hardware setup runs again on
# every update, and a rewrite that differs would churn the boot config.
before=$(sha256sum "$config")
run_leaf "20W1S7PB00" "ThinkPad T14 Gen 2i" "$scratch/t14"
[[ $(sha256sum "$config") == "$before" ]] || fail "rerunning the fix leaves the drop-in unchanged"
pass "rerunning the fix leaves the drop-in unchanged"

# A different generation of the same line does not match, and neither does an
# unrelated machine.
for machine in "21HM0000|ThinkPad T14 Gen 3i" "XPS 13 9350|XPS 13 9350"; do
  name=${machine%%|*}
  family=${machine##*|}
  rm -rf "$scratch/other"
  run_leaf "$name" "$family" "$scratch/other"
  [[ ! -e $scratch/other ]] || fail "the $family machine gets no display drop-in"
done
pass "other ThinkPad generations and other machines get no display drop-in"

# An install that predates the leaf never ran it, and a kernel parameter in a
# Limine drop-in only reaches the boot entries on a rebuild.
run_migration "20W1S7PB00" "ThinkPad T14 Gen 2i" "$scratch/migrated"
[[ -f $scratch/migrated/limine-entry-tool.d/$config_name ]] ||
  fail "the migration applies the display drop-in"
grep -q '^limine-mkinitcpio' "$CALL_LOG" || fail "the migration rebuilds the boot entries"
[[ -f $scratch/migrated/marker ]] || fail "the migration records the rebuild"
grep -q '^omarchy-state set reboot-required' "$CALL_LOG" ||
  fail "the migration asks for the reboot that applies it"
pass "the migration applies the display drop-in and rebuilds the boot entries"

# The marker stops another user's run from repeating the machine-wide rebuild.
run_migration "20W1S7PB00" "ThinkPad T14 Gen 2i" "$scratch/migrated"
! grep -q '^limine-mkinitcpio' "$CALL_LOG" || fail "the migration rebuilds only once"
pass "the migration rebuilds only once"

rm -rf "$scratch/other"
run_migration "XPS 13 9350" "XPS 13 9350" "$scratch/other"
[[ ! -e $scratch/other ]] || fail "the migration leaves other machines alone"
pass "the migration leaves other machines alone"

# A machine with no Limine cannot rebuild its boot entries, so the migration
# has nothing to do and must not leave a drop-in behind claiming otherwise.
rm -rf "$scratch/no-limine"
TEST_LIMINE_PRESENT=0 run_migration "20W1S7PB00" "ThinkPad T14 Gen 2i" "$scratch/no-limine"
[[ ! -e $scratch/no-limine ]] || fail "a machine without Limine is left alone"
pass "a machine without Limine is left alone"
