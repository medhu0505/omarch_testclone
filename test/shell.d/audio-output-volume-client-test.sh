#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command pamixer
if ! command -v cc >/dev/null || ! command -v pkg-config >/dev/null || ! pkg-config --exists libpulse; then
  skip "a C compiler and libpulse headers are needed for the real pamixer fixture"
  exit 0
fi

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/runtime" "$test_dir/namespace-tmp"
real_pamixer=$(command -v pamixer)
cc -shared -fPIC "$ROOT/test/shell.d/fixtures/audio-output-volume/pulse-shim.c" \
  -o "$test_dir/pulse-shim.so" $(pkg-config --cflags --libs libpulse)
cp "$ROOT/bin/omarchy-audio-output-volume" "$test_dir/volume"

cat >"$test_dir/bin/omarchy-audio-output-sink" <<'STUB'
#!/bin/bash
printf 'fixture_sink\n'
STUB
cat >"$test_dir/bin/pamixer" <<'STUB'
#!/bin/bash
printf 'client' >>"$TEST_LOG"
printf ' <%s>' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
exec "$REAL_PAMIXER" "$@"
STUB
cat >"$test_dir/bin/omarchy-osd" <<'STUB'
#!/bin/bash
printf 'osd' >>"$TEST_LOG"
printf ' <%s>' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
STUB
cat >"$test_dir/bin/pactl" <<'STUB'
#!/bin/bash
case "$1" in
  set-sink-mute) exit 0 ;;
  get-sink-volume) printf 'Volume: front-left: 32768 / 50%% / -18.06 dB\n' ;;
  get-sink-mute) printf 'Mute: yes\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$test_dir/bin/"*

for refuse in 1 0; do
  : >"$test_dir/calls"
  if [[ $refuse == "1" ]]; then
    refuse_value=1
    icon="volume-muted"
  else
    refuse_value=""
    icon="volume-high"
  fi
  HOME="$test_dir/home" XDG_RUNTIME_DIR="$test_dir/runtime" \
    TEST_LOG="$test_dir/calls" REAL_PAMIXER="$real_pamixer" REVIEW_REFUSE_MUTE="$refuse_value" \
    LD_PRELOAD="$test_dir/pulse-shim.so" PATH="$test_dir/bin:$PATH" \
    bash "$test_dir/volume" raise || fail "actual pamixer reports state after its unmute callback"
  [[ $(cat "$test_dir/calls") == $'client <--sink> <fixture_sink> <--increase> <5> <--unmute> <--get-mute> <--get-volume>\n'"osd <-i> <$icon> <-p> <55>" ]] ||
    fail "actual pamixer rejected/accepted unmute uses one client and the actual mute icon" "$(cat "$test_dir/calls")"
done
pass "actual pamixer rejected unmute still succeeds but the OSD remains muted"
pass "actual pamixer accepted unmute uses the same one-client state read"

if ! command -v unshare >/dev/null || ! command -v setpriv >/dev/null ||
  ! unshare --user --map-root-user --map-auto --mount true 2>/dev/null; then
  skip "private user/mount namespaces with two mapped UIDs are needed for fallback isolation"
  exit 0
fi

# The second mapped UID really opens the files; a private /tmp mount also keeps
# a regression to the old global lock from touching the host's /tmp.
chmod 755 "$test_dir"
(
  cd "$test_dir"
  REAL_PAMIXER="$real_pamixer" unshare --user --map-root-user --map-auto --mount bash -s <<'NAMESPACE'
set -euo pipefail
mount --bind namespace-tmp /tmp
mkdir /tmp/fixture
mount --bind /proc/self/cwd /tmp/fixture
fixture=/tmp/fixture
trap 'rm -rf "$fixture/users"' EXIT
mkdir -p "$fixture/users/0" "$fixture/users/1"
chmod 700 "$fixture/users/0" "$fixture/users/1"
chown 1:1 "$fixture/users/1"
export PATH="$fixture/bin:$PATH" LD_PRELOAD="$fixture/pulse-shim.so"
unset XDG_RUNTIME_DIR REVIEW_REFUSE_MUTE

run_user() {
  local user="$1" action="$2"
  setpriv --reuid="$user" --regid="$user" --clear-groups \
    env HOME="$fixture/users/$user" TEST_LOG="$fixture/users/$user/calls" \
    bash "$fixture/volume" "$action"
}

for user in 0 1; do
  run_user "$user" raise
  run_user "$user" mute-toggle
  directory="$fixture/users/$user/.cache/omarchy/audio-output-volume"
  [[ $(stat -c '%a %u' "$directory") == "700 $user" ]]
  [[ -f $directory/omarchy-audio-output-volume.lock ]]
  [[ -f $directory/omarchy-audio-output-volume-mute-toggle.last ]]
  [[ $(cat "$fixture/users/$user/calls") == *'osd <-i> <volume-high> <-p> <55>'* ]]
done

# Holding the first user's deterministic lock cannot drop the second user's
# action. Both invocations run without XDG_RUNTIME_DIR.
: >"$fixture/users/1/calls"
flock "$fixture/users/0/.cache/omarchy/audio-output-volume/omarchy-audio-output-volume.lock" \
  setpriv --reuid=1 --regid=1 --clear-groups \
  env HOME="$fixture/users/1" TEST_LOG="$fixture/users/1/calls" \
  bash "$fixture/volume" raise
[[ $(cat "$fixture/users/1/calls") == *'osd <-i> <volume-high> <-p> <55>' ]]
[[ ! -e /tmp/omarchy-audio-output-volume.lock ]]
[[ ! -e /tmp/omarchy-audio-output-volume-mute-toggle.last ]]
NAMESPACE
) || fail "two UIDs can adjust volume with isolated private lock/debounce fallback directories"
pass "two UIDs use owner-only deterministic fallback directories for lock and mute debounce"
pass "the first UID's held fallback lock does not drop the second UID's action"
