#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/installed"

# A private package inventory: nothing below can reach the host's package DB.
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
  -Si)
    for package in "$@"; do
      printf 'Name            : %s\n' "$package"
      printf 'Depends On      : %s\n' "${OMARCHY_TEST_DEPENDS[$package]:-glibc}"
      printf '\n'
    done
    ;;
  -S)
    printf 'pacman %s\n' "$*" >>"$OMARCHY_TEST_CALLS"
    for package in "$@"; do touch "$OMARCHY_TEST_INSTALLED/$package"; done
    ;;
  *) exit 99 ;;
esac
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$stub_bin/omarchy-install-gaming-gpu-lib32" <<'SH'
#!/bin/bash
printf 'gpu-lib32\n' >>"$OMARCHY_TEST_CALLS"
exit "${OMARCHY_TEST_GPU_FAIL:-0}"
SH
chmod +x "$stub_bin"/*

export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_CALLS="$test_tmp/calls"
export OMARCHY_TEST_INSTALLED="$test_tmp/installed"
export PATH="$stub_bin:$ROOT/bin:$PATH"

# Associative arrays cannot be exported, so the pacman stub sources them from here.
depends_file="$test_tmp/depends"
cat >"$depends_file" <<'SH'
declare -A OMARCHY_TEST_DEPENDS=(
  [steam]='bash  desktop-file-utils  lib32-vulkan-driver  lib32-glibc'
  [umu-launcher]='python  lib32-vulkan-driver'
  [proton-runner]='lib32-vulkan-driver>=1.3  python'
  [vulkan-tools]='vulkan-driver  lib32-vulkan-driver-extras'
)
SH
sed -i "2i source '$depends_file'" "$stub_bin/pacman"

add() {
  : >"$OMARCHY_TEST_CALLS"
  omarchy-pkg-add "$@" >"$test_tmp/output" 2>&1
}

add steam || fail "steam installs" "$(<"$test_tmp/output")"
[[ $(<"$OMARCHY_TEST_CALLS") == $'gpu-lib32\npacman steam' ]] ||
  fail "the GPU's lib32 driver is installed before steam" "$(<"$OMARCHY_TEST_CALLS")"
pass "the GPU's lib32 driver is installed before steam"

add jq umu-launcher || fail "umu-launcher installs" "$(<"$test_tmp/output")"
[[ $(<"$OMARCHY_TEST_CALLS") == $'gpu-lib32\npacman jq umu-launcher' ]] ||
  fail "any requested package needing lib32-vulkan-driver triggers the driver first" "$(<"$OMARCHY_TEST_CALLS")"
pass "any requested package needing lib32-vulkan-driver triggers the driver first"

add proton-runner || fail "proton-runner installs" "$(<"$test_tmp/output")"
[[ $(<"$OMARCHY_TEST_CALLS") == $'gpu-lib32\npacman proton-runner' ]] ||
  fail "a version-qualified lib32-vulkan-driver dependency triggers the driver first" "$(<"$OMARCHY_TEST_CALLS")"
pass "a version-qualified lib32-vulkan-driver dependency triggers the driver first"

add ripgrep vulkan-tools || fail "unrelated packages install" "$(<"$test_tmp/output")"
[[ $(<"$OMARCHY_TEST_CALLS") == "pacman ripgrep vulkan-tools" ]] ||
  fail "packages without lib32-vulkan-driver leave the GPU drivers alone" "$(<"$OMARCHY_TEST_CALLS")"
pass "packages without lib32-vulkan-driver leave the GPU drivers alone"

add steam || fail "an installed steam is a no-op" "$(<"$test_tmp/output")"
[[ ! -s $OMARCHY_TEST_CALLS ]] || fail "already-installed packages install nothing" "$(<"$OMARCHY_TEST_CALLS")"
pass "already-installed packages install nothing"

rm "$test_tmp/installed/steam"
if OMARCHY_TEST_GPU_FAIL=1 add steam; then
  fail "a failed driver install stops steam from resolving to NVIDIA"
fi
grep -q '^pacman' "$OMARCHY_TEST_CALLS" && fail "steam is not installed after the driver install fails"
pass "a failed driver install stops steam from resolving to NVIDIA"
