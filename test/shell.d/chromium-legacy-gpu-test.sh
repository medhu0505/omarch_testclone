#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
export OMARCHY_PCI_DEVICES_PATH="$tmp_dir/devices" OMARCHY_DRM_PATH="$tmp_dir/drm" OMARCHY_PATH="$ROOT" PATH="$ROOT/bin:$PATH"

# Build fake sysfs GPUs from vendor:device:driver:connector:boot_vga specs. An empty
# driver means unbound; an empty connector means the card has no connector.
set_devices() {
  rm -rf "$tmp_dir/devices" "$tmp_dir/drivers" "$tmp_dir/drm"
  mkdir -p "$tmp_dir/devices" "$tmp_dir/drm"
  local slot=0 spec vendor device driver connector boot_vga
  for spec in "$@"; do
    IFS=: read -r vendor device driver connector boot_vga <<<"$spec"
    mkdir -p "$tmp_dir/devices/$slot" "$tmp_dir/drm/card$slot"
    printf '%s\n' "$vendor" >"$tmp_dir/devices/$slot/vendor"
    printf '%s\n' "$device" >"$tmp_dir/devices/$slot/device"
    printf '%s\n' "${boot_vga:-0}" >"$tmp_dir/devices/$slot/boot_vga"
    ln -s "$tmp_dir/devices/$slot" "$tmp_dir/drm/card$slot/device"
    if [[ -n $driver ]]; then
      mkdir -p "$tmp_dir/drivers/$driver"
      ln -s "$tmp_dir/drivers/$driver" "$tmp_dir/devices/$slot/driver"
    fi
    if [[ -n $connector ]]; then
      mkdir -p "$tmp_dir/drm/card$slot-eDP-1"
      printf '%s\n' "$connector" >"$tmp_dir/drm/card$slot-eDP-1/status"
    fi
    slot=$((slot + 1))
  done
}

while IFS='|' read -r description expected devices; do
  set_devices $devices
  status=0
  omarchy-hw-radeon || status=$?
  [[ $status == "$expected" ]] || fail "hw-radeon: $description" "expected $expected, got $status"
  pass "hw-radeon: $description"
done <<'CASES'
iMac12,2: HD 6770M drives the panel, Intel HD 3000 idle|0|0x1002:0x6741:radeon:connected:1 0x8086:0x0116:i915::0
TeraScale only|0|0x1002:0x6741:radeon:connected:1
MacBookPro11,5: panel on Intel, Venus XT idle on radeon|1|0x8086:0x0d26:i915:connected:1 0x1002:0x6821:radeon::0
Venus XT (GCN 1.0) forced onto radeon, driving the panel|1|0x1002:0x6821:radeon:connected:1
Turks 0x6840 (TeraScale inside the Pitcairn span) driving the panel|0|0x1002:0x6840:radeon:connected:1
Pitcairn 0x684c on radeon driving the panel|1|0x1002:0x684c:radeon:connected:1
TeraScale dGPU on an external monitor, Intel on the panel|0|0x8086:0x0116:i915:connected:1 0x1002:0x6741:radeon:connected:0
GCN on amdgpu|1|0x1002:0x6821:amdgpu:connected:1
Intel only|1|0x8086:0x0116:i915:connected:1
Nothing connected, TeraScale is boot VGA|0|0x8086:0x0116:i915:disconnected:0 0x1002:0x6741:radeon:disconnected:1
Nothing connected, TeraScale is not boot VGA|1|0x8086:0x0116:i915:disconnected:1 0x1002:0x6741:radeon:disconnected:0
Unbound display device|1|0x1002:0x6741::connected:1
No GPUs|1|
CASES

flags="$tmp_dir/chromium-flags.conf"
printf '%s\n' '--ozone-platform=wayland' >"$flags"

set_devices 0x1002:0x6741:radeon:connected:1
omarchy-install-chromium-legacy-gpu "$flags" >/dev/null
grep -qxF -- '--disable-gpu-compositing' "$flags" || fail "legacy radeon disables Chromium GPU compositing"
pass "legacy radeon disables Chromium GPU compositing"

omarchy-install-chromium-legacy-gpu "$flags" >/dev/null
(( $(grep -cxF -- '--disable-gpu-compositing' "$flags") == 1 )) || fail "legacy GPU flag is added once"
pass "legacy GPU flag is added once"

printf '%s' '--ozone-platform=wayland' >"$flags"
omarchy-install-chromium-legacy-gpu "$flags" >/dev/null
[[ $(<"$flags") == $'--ozone-platform=wayland\n--disable-gpu-compositing' ]] ||
  fail "legacy GPU flag goes on its own line when the file lacks a final newline" "$(cat "$flags")"
pass "legacy GPU flag goes on its own line when the file lacks a final newline"

HOME="$tmp_dir/home" omarchy-install-chromium-legacy-gpu >/dev/null
[[ ! -e $tmp_dir/home/.config/chromium-flags.conf ]] || fail "legacy GPU setup does not create a missing flags file"
pass "legacy GPU setup does not create a missing flags file"

printf '%s\n' '--ozone-platform=wayland' >"$flags"
set_devices 0x1002:0x6821:amdgpu:connected:1
omarchy-install-chromium-legacy-gpu "$flags" >/dev/null
if grep -q -- '--disable-gpu-compositing' "$flags"; then
  fail "legacy GPU setup leaves other drivers on GPU compositing"
fi
pass "legacy GPU setup leaves other drivers on GPU compositing"

migration_home="$tmp_dir/migration-home"
mkdir -p "$migration_home/.config"
printf '%s\n' '--ozone-platform=wayland' >"$migration_home/.config/chromium-flags.conf"
printf '%s\n' '--ozone-platform=wayland' >"$migration_home/.config/brave-flags.conf"
set_devices 0x1002:0x6741:radeon:connected:1
HOME="$migration_home" bash -euo pipefail "$ROOT/migrations/1790699056.sh" >/dev/null
for browser in chromium brave; do
  grep -qxF -- '--disable-gpu-compositing' "$migration_home/.config/$browser-flags.conf" ||
    fail "legacy GPU migration covers $browser-flags.conf"
done
[[ ! -e $migration_home/.config/chrome-flags.conf ]] || fail "legacy GPU migration does not create missing flags files"
pass "legacy GPU migration covers every installed Chromium browser"

mock_bin="$tmp_dir/mock-bin"
mkdir -p "$mock_bin"
for command in cp omarchy-refresh-limine omarchy-refresh-plymouth omarchy-install-chromium-legacy-gpu; do
  printf '#!/bin/bash\necho %s >>"%s"\n' "$command" "$tmp_dir/reinstall.log" >"$mock_bin/$command"
  chmod +x "$mock_bin/$command"
done
printf '#!/bin/bash\nexit 1\n' >"$mock_bin/omarchy-cmd-present"
chmod +x "$mock_bin/omarchy-cmd-present"
PATH="$mock_bin:$PATH" omarchy-reinstall-configs >/dev/null
grep -A1 -xF cp "$tmp_dir/reinstall.log" | grep -qxF omarchy-install-chromium-legacy-gpu ||
  fail "resetting configs reapplies the legacy GPU flag" "$(cat "$tmp_dir/reinstall.log")"
pass "resetting configs reapplies the legacy GPU flag"
