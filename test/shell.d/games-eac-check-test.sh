#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)/base-test.sh"

check_command="$ROOT/bin/omarchy-games-eac-check"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fixture="$test_tmp/system"
stub_bin="$test_tmp/bin"
mkdir -p \
  "$fixture/proc/sys/kernel" \
  "$fixture/sys/class/tpm/tpm0" \
  "$fixture/sys/firmware/efi/efivars" \
  "$fixture/sys/kernel/security/tpm0" \
  "$fixture/sys/kernel/iommu_groups/0/devices" \
  "$fixture/sys/module/signed_module" \
  "$stub_bin"

printf 'signed_module 0 0 - Live 0x0\n' >"$fixture/proc/modules"
printf '2\n' >"$fixture/sys/class/tpm/tpm0/tpm_version_major"
printf '\007\000\000\000\001' >"$fixture/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
printf 'limine_cfg cmdline:quiet path:boot():/EFI/Linux/omarchy.efi\n' >"$fixture/sys/kernel/security/tpm0/binary_bios_measurements"
printf 'iommu.passthrough=0 sysctl.kernel.kexec_load_disabled=1\n' >"$fixture/proc/cmdline"
printf 'none [integrity] confidentiality\n' >"$fixture/sys/kernel/security/lockdown"
printf '1\n' >"$fixture/proc/sys/kernel/kexec_load_disabled"
printf 'lockdown,yama,bpf\n' >"$fixture/sys/kernel/security/lsm"
printf 'Verifying file database and EFI images in /boot...\n✔ /boot/EFI/Linux/omarchy.efi is signed\n' >"$test_tmp/sbctl-output"
export SBCTL_OUTPUT_FILE="$test_tmp/sbctl-output"

cat >"$stub_bin/modinfo" <<'SH'
#!/bin/bash
[[ $1 == "-F" && $2 == "signer" ]] || exit 2
case "$3" in
  signed_module) printf 'Omarchy Test Signing Key\n' ;;
  unsigned_module) printf '\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$stub_bin/modinfo"

cat >"$stub_bin/sbctl" <<'SH'
#!/bin/bash
[[ $1 == "verify" ]] || exit 2
cat "$SBCTL_OUTPUT_FILE"
SH
chmod +x "$stub_bin/sbctl"

no_modinfo_bin="$test_tmp/no-modinfo-bin"
mkdir -p "$no_modinfo_bin"
for utility in cat grep jq od tr; do
  ln -s "$(command -v "$utility")" "$no_modinfo_bin/$utility"
done
ln -s "$stub_bin/sbctl" "$no_modinfo_bin/sbctl"

status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 2 ]] || fail "unknown local trust state returns exit status 2" "$status"

jq -e '
  .schema_version == 1 and
  .command == "omarchy games eac check" and
  .overall == "UNKNOWN" and
  .epic_key_recognition == "UNKNOWN" and
  .official_compatibility == "UNKNOWN" and
  (.checks | length == 8) and
  (.checks[0].status == "UNKNOWN") and
  (.checks[1].status == "PASS") and
  (.checks[2].status == "UNKNOWN") and
  (.checks[3].status == "PASS") and
  (.checks[4].status == "PASS") and
  (.checks[5].status == "PASS") and
  (.checks[6].status == "PASS") and
  (.checks[7].status == "PASS")
' <<<"$output" >/dev/null || fail "JSON reports all eight checks without claiming Epic trust" "$output"
pass "JSON reports observable checks and leaves Epic trust unverified"

printf 'Verifying file database and EFI images in /boot...\n✘ /boot/EFI/Linux/omarchy.efi is not signed\n' >"$test_tmp/sbctl-output"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$no_modinfo_bin" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 1 ]] || fail "missing modinfo does not hide an unsigned tracked boot file" "$status"
jq -e '.checks[0].status == "FAIL" and (.checks[0].detail | contains("omarchy.efi is not signed"))' <<<"$output" >/dev/null ||
  fail "sbctl findings remain visible when modinfo is unavailable" "$output"
pass "sbctl findings are checked even when modinfo is unavailable"

printf 'Verifying file database and EFI images in /boot...\n✔ /boot/EFI/Linux/omarchy.efi is signed\n' >"$test_tmp/sbctl-output"
printf 'iommu.passthrough=0\n' >"$fixture/proc/cmdline"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 2 ]] || fail "a runtime-disabled kexec state without a boot parameter stays unknown" "$status"
jq -e '.checks[6].status == "UNKNOWN" and (.checks[6].detail | contains("does not prove"))' <<<"$output" >/dev/null ||
  fail "kexec status requires evidence from the kernel command line" "$output"
pass "kexec requires evidence that it was disabled before init starts"

printf 'iommu.passthrough=0 sysctl.kernel.kexec_load_disabled=1\n' >"$fixture/proc/cmdline"
printf 'Verifying file database and EFI images in /boot...\n✘ /boot/EFI/Linux/omarchy.efi is not signed\n' >"$test_tmp/sbctl-output"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 1 ]] || fail "an unsigned tracked boot file produces a failing result" "$status"
jq -e '.overall == "FAIL" and .checks[0].status == "FAIL" and (.checks[0].detail | contains("/boot/EFI/Linux/omarchy.efi"))' <<<"$output" >/dev/null ||
  fail "the unsigned tracked boot file is named in the report" "$output"
pass "unsigned boot files tracked by sbctl are reported as a failure"

printf 'Verifying file database and EFI images in /boot...\n✔ /boot/EFI/Linux/omarchy.efi is signed\n' >"$test_tmp/sbctl-output"
mkdir -p "$fixture/sys/module/unsigned_module"
printf 'unsigned_module 0 0 - Live 0x0\n' >"$fixture/proc/modules"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 1 ]] || fail "an unsigned loaded module produces a failing result" "$status"
jq -e '.overall == "FAIL" and .checks[0].status == "FAIL" and (.checks[0].detail | contains("unsigned_module"))' <<<"$output" >/dev/null ||
  fail "the unsigned module is named in the report" "$output"
pass "unsigned loaded modules are reported as a failure"

printf '\007\000\000\000\000' >"$fixture/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
printf '0\n' >"$fixture/proc/sys/kernel/kexec_load_disabled"
printf 'none [none] integrity confidentiality\n' >"$fixture/sys/kernel/security/lockdown"
printf 'lockdown,yama\n' >"$fixture/sys/kernel/security/lsm"
printf 'iommu.passthrough=1\n' >"$fixture/proc/cmdline"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 1 ]] || fail "failed security requirements produce a failing result" "$status"
jq -e '
  .overall == "FAIL" and
  .checks[2].status == "FAIL" and
  .checks[4].status == "FAIL" and
  .checks[5].status == "FAIL" and
  .checks[6].status == "FAIL" and
  .checks[7].status == "FAIL"
' <<<"$output" >/dev/null || fail "disabled security requirements are identified" "$output"
pass "disabled Secure Boot, IOMMU passthrough, lockdown, kexec, and BPF LSM are identified"

rm -rf "$fixture/sys/kernel/iommu_groups"
printf 'iommu.passthrough=0 sysctl.kernel.kexec_load_disabled=1\n' >"$fixture/proc/cmdline"
printf 'signed_module 0 0 - Live 0x0\n' >"$fixture/proc/modules"
printf '\007\000\000\000\001' >"$fixture/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
printf 'none [integrity] confidentiality\n' >"$fixture/sys/kernel/security/lockdown"
printf '1\n' >"$fixture/proc/sys/kernel/kexec_load_disabled"
printf 'lockdown,yama,bpf\n' >"$fixture/sys/kernel/security/lsm"
printf 'Verifying file database and EFI images in /boot...\n✔ /boot/EFI/Linux/omarchy.efi is signed\n' >"$test_tmp/sbctl-output"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" --json >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 2 ]] || fail "missing IOMMU sysfs remains unknown" "$status"
jq -e '.checks[4].status == "UNKNOWN" and (.checks[4].detail | contains("interface is unavailable"))' <<<"$output" >/dev/null ||
  fail "missing IOMMU sysfs is distinguished from an inactive IOMMU" "$output"
pass "missing IOMMU sysfs is reported as unknown"

printf '\007\000\000\000\000' >"$fixture/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
rm -f "$fixture/sys/kernel/security/tpm0/binary_bios_measurements"
status=0
if OMARCHY_EAC_CHECK_TEST_ROOT="$fixture" \
  PATH="$stub_bin:$PATH" \
  "$check_command" >"$test_tmp/output" 2>"$test_tmp/stderr"; then
  status=0
else
  status=$?
fi
output=$(<"$test_tmp/output")
[[ $status == 1 ]] || fail "known failures remain non-zero in human output" "$status"
[[ $output == *"UNKNOWN"* && $output == *"read-only report"* ]] || fail "human output explains unknown and read-only results" "$output"
pass "human output is useful and keeps unknown separate from failure"

if "$check_command" --not-an-option >"$test_tmp/invalid-output" 2>&1; then
  fail "unknown options are rejected"
else
  [[ $? == 2 ]] || fail "unknown options use the usage-error status"
fi
pass "unknown options are rejected"
