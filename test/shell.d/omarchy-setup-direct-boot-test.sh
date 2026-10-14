#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_platform_fixtures "direct boot setup"

command="$ROOT/bin/omarchy-setup-direct-boot"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

# The real platform detectors answer from a fixture, so the Apple Silicon
# refusal is exercised through omarchy-hw-aarch64-apple itself.
fake_platform "$scratch/platform" x86
export OMARCHY_PROC_ROOT="$scratch/platform/proc"
export PATH="$scratch/bin:$scratch/platform/bin:$ROOT/bin:$PATH"
export OMARCHY_DIRECT_BOOT_ROOT="$scratch/root"
export EFI_STATE="$scratch/efi"
export CALL_LOG="$scratch/calls"

# A small NVRAM model after efibootmgr 18: one "num|label|loader|data" line per
# entry, printed with the optional data straight after the loader path; new
# entries take the lowest free number and go first in the order; a boot order
# naming a number with no entry is rejected whole. EFI_FAIL_CREATE and
# EFI_FAIL_DELETE make those writes fail the way a refusing firmware does.
cat > "$scratch/bin/efibootmgr" <<'SH'
#!/bin/bash
entries="$EFI_STATE/entries"
order="$EFI_STATE/order"

if (( $# == 0 )); then
  printf 'BootCurrent: 0000\n'
  [[ -s $order ]] && printf 'BootOrder: %s\n' "$(cat "$order")"
  while IFS='|' read -r num label loader data; do
    printf 'Boot%s* %s\tHD(1,GPT,0000,0x800,0x400000)/%s%s\n' "$num" "$label" "$loader" "$data"
  done < <(sort "$entries")
  exit 0
fi

printf 'efibootmgr %s\n' "$*" >> "$CALL_LOG"
case "$1" in
  --create)
    [[ -z ${EFI_FAIL_CREATE:-} ]] || exit 1
    label="" loader=""
    while (( $# )); do
      case "$1" in
        --label) label="$2"; shift ;;
        --loader) loader="$2"; shift ;;
      esac
      shift
    done
    n=0
    while grep -q "^$(printf '%04X' "$n")|" "$entries"; do n=$(( n + 1 )); done
    num=$(printf '%04X' "$n")
    printf '%s|%s|%s|\n' "$num" "$label" "$loader" >> "$entries"
    if [[ -s $order ]]; then
      printf '%s,%s\n' "$num" "$(cat "$order")" > "$order"
    else
      printf '%s\n' "$num" > "$order"
    fi
    ;;
  --bootnum)
    [[ $3 == "--delete-bootnum" ]] || exit 99
    [[ -z ${EFI_FAIL_DELETE:-} ]] || exit 1
    grep -v "^$2|" "$entries" > "$entries.new" || true
    mv "$entries.new" "$entries"
    sed -E "s/(^|,)$2(,|$)/\1\2/; s/,,/,/; s/^,//; s/,$//" "$order" > "$order.new"
    mv "$order.new" "$order"
    ;;
  --bootorder)
    for num in ${2//,/ }; do
      grep -qi "^$num|" "$entries" || exit 1
    done
    printf '%s\n' "$2" > "$order"
    ;;
  *) exit 99 ;;
esac
SH

cat > "$scratch/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH

cat > "$scratch/bin/findmnt" <<'SH'
#!/bin/bash
printf '/dev/nvme0n1p1\n'
SH

cat > "$scratch/bin/omarchy-state" <<'SH'
#!/bin/bash
printf 'state %s\n' "$*" >> "$CALL_LOG"
SH

cat > "$scratch/bin/gum" <<'SH'
#!/bin/bash
[[ $1 == "confirm" ]]
SH
chmod +x "$scratch/bin/"*

# Reset to a UEFI system with both kernels' UKIs and Omarchy's default boot order.
reset_system() {
  rm -rf "$OMARCHY_DIRECT_BOOT_ROOT" "$EFI_STATE" "$CALL_LOG"
  mkdir -p "$OMARCHY_DIRECT_BOOT_ROOT/sys/firmware/efi" "$OMARCHY_DIRECT_BOOT_ROOT/sys/class/dmi/id" \
    "$OMARCHY_DIRECT_BOOT_ROOT/boot/EFI/Linux" "$OMARCHY_DIRECT_BOOT_ROOT/etc/limine-entry-tool.d" \
    "$OMARCHY_DIRECT_BOOT_ROOT/etc/default" "$EFI_STATE"
  touch "$OMARCHY_DIRECT_BOOT_ROOT/boot/EFI/Linux/omarchy_linux.efi" \
    "$OMARCHY_DIRECT_BOOT_ROOT/boot/EFI/Linux/omarchy_linux-omarchy.efi" "$CALL_LOG"
  printf 'Dell Inc.\n' > "$OMARCHY_DIRECT_BOOT_ROOT/sys/class/dmi/id/bios_vendor"
  printf '%s\n' 'BOOT_ORDER="linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"' \
    > "$OMARCHY_DIRECT_BOOT_ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf"
  printf '%s\n' '0000|UiApp|FvFile(462caa21)|' '0003|Limine|\EFI\limine\limine_x64.efi|' > "$EFI_STATE/entries"
  printf '0003,0000\n' > "$EFI_STATE/order"
}

# The loader of every Omarchy entry, one per line, in listing order.
omarchy_loaders() {
  "$scratch/bin/efibootmgr" | sed -n 's/^Boot[0-9A-F]*\* Omarchy\t.*\/\(.*\)$/\1/p'
}

efi_writes() {
  grep -c '^efibootmgr' "$CALL_LOG" || true
}

reset_system
"$command" >/dev/null
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux-omarchy.efi' ]] || fail "setup points at the kernel BOOT_ORDER prefers" "$(omarchy_loaders)"
pass "setup points at the kernel BOOT_ORDER prefers"

reset_system
printf '%s\n' 'BOOT_ORDER="linux, *"' > "$OMARCHY_DIRECT_BOOT_ROOT/etc/default/limine"
"$command" >/dev/null
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux.efi' ]] || fail "/etc/default/limine overrides the drop-in boot order"
pass "/etc/default/limine overrides the drop-in boot order"

reset_system
printf '%s\n' '# the default kernel' '  BOOT_ORDER = linux, *  ' > "$OMARCHY_DIRECT_BOOT_ROOT/etc/default/limine"
"$command" >/dev/null
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux.efi' ]] || fail "an unquoted BOOT_ORDER is read like limine-entry-tool reads it" "$(omarchy_loaders)"
pass "an unquoted BOOT_ORDER is read like limine-entry-tool reads it"

reset_system
rm "$OMARCHY_DIRECT_BOOT_ROOT/boot/EFI/Linux/omarchy_linux-omarchy.efi"
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
"$command" --refresh
[[ ! -s $CALL_LOG ]] || fail "refresh leaves an entry that already boots the only kernel" "$(cat "$CALL_LOG")"
pass "refresh leaves an entry that already boots the only kernel"

reset_system
printf '0004|Omarchy|\\EFI\\LINUX\\OMARCHY_LINUX.EFI|\n' >> "$EFI_STATE/entries"
printf '0003,0004,0000\n' > "$EFI_STATE/order"
output=$("$command" --refresh)
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux-omarchy.efi' ]] || fail "refresh repoints an upper-case firmware path at the preferred kernel" "$output"
[[ $(cat "$EFI_STATE/order") == "0003,0001,0000" ]] || fail "refresh keeps the entry's place in the boot order" "$(cat "$EFI_STATE/order")"
grep -Fxq 'state set reboot-required' "$CALL_LOG" || fail "refresh requests a reboot"
pass "refresh repoints the entry in place and requests a reboot"

cp "$CALL_LOG" "$scratch/first-refresh"
"$command" --refresh
cmp -s "$CALL_LOG" "$scratch/first-refresh" || fail "a second refresh is a no-op"
pass "a second refresh is a no-op"

reset_system
printf '0004|Omarchy|\\EFI\\LINUX\\OMARCHY_LINUX.EFI|0000424f\n' >> "$EFI_STATE/entries"
printf '0004,0003,0000\n' > "$EFI_STATE/order"
output=$("$command" --refresh)
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux-omarchy.efi' ]] || fail "refresh repoints an entry whose firmware appends optional data to the path" "$output"
[[ $(cat "$EFI_STATE/order") == "0001,0003,0000" ]] || fail "refresh keeps an entry with optional data first in the boot order" "$(cat "$EFI_STATE/order")"
pass "refresh repoints an entry whose firmware appends optional data to the path"

reset_system
printf '%s\n' '0004|Omarchy|\EFI\Linux\omarchy_linux.efi|' '0005|Omarchy|\EFI\Linux\omarchy_linux.efi|' >> "$EFI_STATE/entries"
printf '0005,0003,0004,0000\n' > "$EFI_STATE/order"
output=$("$command" --refresh)
[[ $(omarchy_loaders) == $'\\EFI\\Linux\\omarchy_linux-omarchy.efi\n\\EFI\\Linux\\omarchy_linux.efi' ]] || fail "refresh repoints the Omarchy entry the firmware boots first" "$(omarchy_loaders)"
[[ $(cat "$EFI_STATE/order") == "0001,0003,0004,0000" ]] || fail "refresh replaces the booted entry, not a duplicate with a lower number" "$(cat "$EFI_STATE/order")"
pass "refresh repoints the Omarchy entry the firmware boots first and finds the new entry by number"

reset_system
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
printf '0003,0004,0007,0000\n' > "$EFI_STATE/order"
output=$("$command" --refresh) || fail "refresh succeeds when the boot order names a number with no entry" "$output"
[[ $(cat "$EFI_STATE/order") == "0003,0001,0000" ]] || fail "refresh drops a boot order number with no entry so the firmware accepts the order" "$(cat "$EFI_STATE/order")"
pass "refresh drops a boot order number with no entry so the firmware accepts the order"

reset_system
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
printf '0003,0004,0000\n' > "$EFI_STATE/order"
output=$(EFI_FAIL_CREATE=1 "$command" --refresh 2>&1) && fail "refresh fails when the new entry cannot be created" "$output"
[[ $(omarchy_loaders) == '\EFI\Linux\omarchy_linux.efi' ]] || fail "a failed create leaves the old entry in place" "$(omarchy_loaders)"
! grep -q 'delete-bootnum' "$CALL_LOG" || fail "a failed create deletes nothing"
! grep -Fxq 'state set reboot-required' "$CALL_LOG" || fail "a failed create requests no reboot"
pass "refresh fails without touching the old entry when the new one cannot be created"

reset_system
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
printf '0003,0004,0000\n' > "$EFI_STATE/order"
output=$(EFI_FAIL_DELETE=1 "$command" --refresh 2>&1) && fail "refresh fails when the old entry cannot be deleted" "$output"
[[ $output == *"could not delete"*"Boot0004"* ]] || fail "a failed delete names the entry left behind" "$output"
[[ $(omarchy_loaders | wc -l) == "2" ]] || fail "a failed delete leaves both entries" "$(omarchy_loaders)"
! grep -Fxq 'state set reboot-required' "$CALL_LOG" || fail "a failed delete requests no reboot"
pass "refresh fails and says so when the old entry cannot be deleted"

reset_system
printf '0004|Omarchy|\\EFI\\custom\\grubx64.efi|\n' >> "$EFI_STATE/entries"
"$command" --refresh >/dev/null
[[ ! -s $CALL_LOG ]] || fail "refresh leaves entries pointing outside the Omarchy UKIs"
pass "refresh leaves entries pointing outside the Omarchy UKIs"

reset_system
printf '0004|Omarchy|\\EFI\\custom\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
output=$("$command" --refresh)
[[ ! -s $CALL_LOG ]] || fail "refresh leaves an Omarchy UKI outside \\EFI\\Linux\\ alone" "$(cat "$CALL_LOG")"
[[ $output == *"Leaving direct boot entry Boot0004 alone"* ]] || fail "refresh says when it leaves an entry alone" "$output"
pass "refresh leaves an Omarchy UKI outside \\EFI\\Linux\\ alone and says so"

reset_system
printf 'American Megatrends Inc.\n' > "$OMARCHY_DIRECT_BOOT_ROOT/sys/class/dmi/id/bios_vendor"
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
output=$("$command" --refresh) || fail "refresh succeeds on firmware setup refuses" "$output"
[[ ! -s $CALL_LOG ]] || fail "refresh writes nothing on firmware setup refuses" "$(cat "$CALL_LOG")"
[[ $output == *"American Megatrends"*"omarchy-setup-direct-boot"* ]] || fail "refresh says how to boot through Limine again on firmware setup refuses" "$output"
"$command" >/dev/null 2>&1 && fail "setup still refuses American Megatrends firmware"
pass "refresh leaves the entry alone on firmware setup refuses, and says how to switch back to Limine"

reset_system
printf '0004|Omarchy|\\EFI\\Linux\\omarchy_linux.efi|\n' >> "$EFI_STATE/entries"
fake_platform "$scratch/platform" aarch64-apple
"$command" --refresh || fail "refresh succeeds on Apple Silicon"
[[ ! -s $CALL_LOG ]] || fail "refresh writes nothing on Apple Silicon" "$(cat "$CALL_LOG")"
"$command" >/dev/null 2>&1 && fail "setup still refuses Apple Silicon"
fake_platform "$scratch/platform" x86
pass "refresh does nothing on Apple Silicon"

reset_system
"$command" --refresh
[[ ! -s $CALL_LOG ]] || fail "refresh does nothing without direct boot"
rm -r "$OMARCHY_DIRECT_BOOT_ROOT/sys/firmware/efi"
"$command" --refresh || fail "refresh succeeds on systems without UEFI"
pass "refresh does nothing without direct boot or UEFI"
