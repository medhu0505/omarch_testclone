#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin" "$tmp_dir/devices"
export OMARCHY_PCI_DEVICES_PATH="$tmp_dir/devices" OMARCHY_PATH="$ROOT" PATH="$mock_bin:$ROOT/bin:$PATH"

cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$mock_bin/uwsm-app" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"$OMARCHY_TEST_LAUNCH"
SH
cat >"$mock_bin/omarchy-cmd-terminal-cwd" <<'SH'
#!/bin/bash
printf '%s\n' /tmp/project
SH
chmod +x "$mock_bin"/*

write_device() {
  local slot="$1"
  local vendor="$2"
  local class="$3"
  local device_dir="$tmp_dir/devices/$slot"

  mkdir -p "$device_dir"
  printf '%s\n' "$vendor" >"$device_dir/vendor"
  printf '%s\n' "$class" >"$device_dir/class"
}

assert_launch() {
  local description="$1"
  local expected="$2"
  local launch_log="$tmp_dir/launch"

  rm -f "$launch_log"
  OMARCHY_TEST_LAUNCH="$launch_log" bash "$ROOT/bin/omarchy-launch-nautilus"
  [[ $(< "$launch_log") == "$expected" ]] || fail "$description" "expected $expected, got $(< "$launch_log")"
  pass "$description"
}

rm -rf "$tmp_dir/devices"
mkdir -p "$tmp_dir/devices"
status=0
omarchy-hw-vmware-svga || status=$?
[[ $status == 1 ]] || fail "no PCI devices" "expected 1, got $status"
pass "no PCI devices"

write_device 0 0x15ad 0x060400
status=0
omarchy-hw-vmware-svga || status=$?
[[ $status == 1 ]] || fail "VMware bridge is not a display" "expected 1, got $status"
pass "VMware bridge is not a display"

write_device 1 0x8086 0x030000
status=0
omarchy-hw-vmware-svga || status=$?
[[ $status == 1 ]] || fail "Intel display is not VMware SVGA" "expected 1, got $status"
pass "Intel display is not VMware SVGA"
assert_launch "Files launches normally off VMware SVGA" "-- nautilus --new-window"

write_device 2 0x15ad 0x030000
status=0
omarchy-hw-vmware-svga || status=$?
[[ $status == 0 ]] || fail "VMware SVGA display" "expected 0, got $status"
pass "VMware SVGA display"
assert_launch "Files uses Cairo on VMware SVGA" "-- env -u GDK_BACKEND GSK_RENDERER=cairo nautilus --new-window"

launch_log="$tmp_dir/launch"
rm -f "$launch_log"
OMARCHY_TEST_LAUNCH="$launch_log" bash "$ROOT/bin/omarchy-launch-nautilus-cwd"
[[ $(< "$launch_log") == "-- env -u GDK_BACKEND GSK_RENDERER=cairo nautilus --new-window /tmp/project" ]] ||
  fail "Files opens the terminal directory on VMware SVGA" "got $(< "$launch_log")"
pass "Files opens the terminal directory on VMware SVGA"
