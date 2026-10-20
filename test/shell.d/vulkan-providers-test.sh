#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/installed"

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash
cat "$OMARCHY_TEST_PCI"
SH
cat >"$stub_bin/omarchy-hw-x86" <<'SH'
#!/bin/bash
[[ $OMARCHY_TEST_ARCH == "x86" ]]
SH
cat >"$stub_bin/omarchy-hw-aarch64-qualcomm" <<'SH'
#!/bin/bash
[[ $OMARCHY_TEST_ARCH == "aarch64-qualcomm" ]]
SH
cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >>"$OMARCHY_TEST_CALLS"
SH
chmod +x "$stub_bin"/*

export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_PCI="$test_tmp/pci"
export OMARCHY_TEST_CALLS="$test_tmp/calls"
export OMARCHY_TEST_INSTALLED="$test_tmp/installed"
export OMARCHY_TEST_CHANGES="$test_tmp/changes"
export PATH="$stub_bin:$ROOT/bin:$PATH"

amd='c3:00.0 Display controller: Advanced Micro Devices, Inc. [AMD/ATI] Strix Halo'
intel='00:02.0 VGA compatible controller: Intel Corporation Graphics'
nvidia='01:00.0 VGA compatible controller: NVIDIA Corporation Graphics'
apple='00:00.0 Display controller: Apple Inc. AGX'

check_packages() {
  local description="$1" arch="$2" devices="$3" expected="$4"
  local -a expected_packages

  read -r -a expected_packages <<<"$expected"
  printf '%s\n' "$devices" >"$OMARCHY_TEST_PCI"
  : >"$OMARCHY_TEST_CALLS"
  OMARCHY_TEST_ARCH="$arch" bash -euo pipefail "$ROOT/install/hardware/vulkan.sh" >"$test_tmp/output" 2>&1 ||
    fail "$description" "$(<"$test_tmp/output")"
  [[ $(sort "$OMARCHY_TEST_CALLS") == "$(printf '%s\n' "${expected_packages[@]}" | sort)" ]] ||
    fail "$description" "$(<"$OMARCHY_TEST_CALLS")"
  pass "$description"
}

check_packages "x86 AMD Display controllers get both Vulkan providers" x86 "$amd" \
  'vulkan-radeon lib32-vulkan-radeon'
check_packages "x86 Intel controllers get both Vulkan providers" x86 "$intel" \
  'vulkan-intel lib32-vulkan-intel'
check_packages "x86 Intel and AMD controllers get both vendors' providers" x86 "$intel"$'\n'"$amd" \
  'vulkan-intel lib32-vulkan-intel vulkan-radeon lib32-vulkan-radeon'
check_packages "AMD and NVIDIA hybrids add the Radeon providers without replacing NVIDIA" x86 "$amd"$'\n'"$nvidia" \
  'vulkan-radeon lib32-vulkan-radeon'
check_packages "NVIDIA-only setup leaves its providers to nvidia.sh" x86 "$nvidia" ''
check_packages "ARM AMD controllers get no multilib packages" aarch64 "$amd" 'vulkan-radeon'
check_packages "ARM Intel controllers get no multilib packages" aarch64 "$intel" 'vulkan-intel'
check_packages "Apple setup keeps its native provider" aarch64-apple "$apple" 'vulkan-asahi'
check_packages "Qualcomm setup keeps its platform provider without PCI graphics" aarch64-qualcomm '' 'vulkan-freedreno'
check_packages "no supported controller installs no provider" x86 '' ''

for package in lib32-vulkan-radeon lib32-vulkan-intel; do
  grep -Fxq "$package" "$ROOT/install/omarchy-other.packages" ||
    fail "the offline package list includes $package"
done
pass "the offline package list includes both x86 multilib providers"

# Exercise the migration with the real package helpers and a private package
# inventory. No pacman or sudo command below can reach the host's package DB.
rm "$stub_bin/omarchy-pkg-add"
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
operation=$1
shift
while (( $# > 0 )) && [[ $1 == -* ]]; do shift; done
case $operation in
  -Q)
    for package in "$@"; do
      [[ -f $OMARCHY_TEST_INSTALLED/$package ]] || exit 1
    done
    ;;
  -S)
    [[ ${OMARCHY_TEST_PACMAN_FAIL:-0} == "0" ]] || exit 1
    for package in "$@"; do
      if [[ ! -f $OMARCHY_TEST_INSTALLED/$package ]]; then
        touch "$OMARCHY_TEST_INSTALLED/$package"
        printf '%s\n' "$package" >>"$OMARCHY_TEST_CHANGES"
      fi
    done
    ;;
  *) exit 99 ;;
esac
SH
chmod +x "$stub_bin/sudo" "$stub_bin/pacman"

migration="$ROOT/migrations/1792487427.sh"
printf '%s\n' "$amd" >"$OMARCHY_TEST_PCI"
touch "$test_tmp/installed/vulkan-radeon"
: >"$OMARCHY_TEST_CHANGES"
OMARCHY_TEST_ARCH=x86 bash -euo pipefail "$migration" >"$test_tmp/output" 2>&1 ||
  fail "the migration provisions an existing Radeon system" "$(<"$test_tmp/output")"
[[ $(<"$OMARCHY_TEST_CHANGES") == "lib32-vulkan-radeon" ]] ||
  fail "the migration adds the missing Radeon multilib provider" "$(<"$OMARCHY_TEST_CHANGES")"
pass "the migration adds the missing Radeon multilib provider"

: >"$OMARCHY_TEST_CHANGES"
OMARCHY_TEST_ARCH=x86 bash -euo pipefail "$migration" >"$test_tmp/output" 2>&1 ||
  fail "the migration can run twice" "$(<"$test_tmp/output")"
[[ ! -s $OMARCHY_TEST_CHANGES ]] || fail "a repeated migration installs nothing"
pass "the migration is idempotent through the package helpers"

rm "$test_tmp/installed/lib32-vulkan-radeon" "$test_tmp/installed/vulkan-radeon"
OMARCHY_TEST_ARCH=aarch64 bash -euo pipefail "$migration" >"$test_tmp/output" 2>&1 ||
  fail "the migration skips ARM" "$(<"$test_tmp/output")"
[[ ! -s $OMARCHY_TEST_CHANGES ]] || fail "the migration adds no packages on ARM"
pass "the migration adds no packages on ARM"

printf '%s\n' "$nvidia" >"$OMARCHY_TEST_PCI"
touch "$test_tmp/installed/nvidia-580xx-utils" "$test_tmp/installed/lib32-nvidia-580xx-utils"
OMARCHY_TEST_ARCH=x86 bash -euo pipefail "$migration" >"$test_tmp/output" 2>&1 ||
  fail "the migration skips NVIDIA-only hardware" "$(<"$test_tmp/output")"
[[ ! -s $OMARCHY_TEST_CHANGES && -f $test_tmp/installed/nvidia-580xx-utils && -f $test_tmp/installed/lib32-nvidia-580xx-utils ]] ||
  fail "the migration preserves existing NVIDIA drivers"
pass "the migration preserves existing NVIDIA drivers"

printf '%s\n' "$amd" >"$OMARCHY_TEST_PCI"
if OMARCHY_TEST_ARCH=x86 OMARCHY_TEST_PACMAN_FAIL=1 bash -euo pipefail "$migration" >"$test_tmp/output" 2>&1; then
  fail "a failed provider installation fails the migration"
fi
pass "provider installation failures propagate out of the migration"
