#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

unset XDG_CACHE_HOME

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
export HOME="$stage/home" XDG_RUNTIME_DIR="$stage/runtime" OMARCHY_PATH="$stage/omarchy"
export TEST_LOG="$stage/log" FETCH_DONE="$stage/fetch-done" REAL_INTRO_HELPER="$ROOT/bin/omarchy-theme-bg-boot-intro"
export OMARCHY_BACKGROUND_INTROS_URL="file://$stage/host"
mkdir -p "$stage/bin" "$XDG_RUNTIME_DIR" "$HOME/.local/state/omarchy/current" "$OMARCHY_PATH/themes/demo/backgrounds/intros" "$stage/host/themes/demo/backgrounds/intros"
export PATH="$stage/bin:$ROOT/bin:$PATH"
media="$OMARCHY_PATH/themes/demo/backgrounds"
current="$HOME/.local/state/omarchy/current/background"
marker="$HOME/.local/state/omarchy/background-intro.session-id"
printf 'consumed-login\n' >"$marker"
printf 'custom still\n' >"$stage/plain.webp"
for name in one two retry fast missing default; do printf '%s still\n' "$name" >"$media/$name.webp"; done
for name in one two retry fast; do printf '%s video\n' "$name" >"$stage/host/themes/demo/backgrounds/intros/$name.mp4"; done
printf 'shipped intro\n' >"$media/intros/default.mp4"
printf 'official video\n' >"$media/movie.mp4"
ln -s "$stage/plain.webp" "$current"
cat >"$stage/bin/hyprctl" <<'SH'
#!/bin/bash
printf '{"bool":%s}\n' "${ANIMATIONS:-true}"
SH
cat >"$stage/bin/omarchy-theme-bg-boot-intro" <<'SH'
#!/bin/bash
"$REAL_INTRO_HELPER" "$@"
result=$?
if [[ $1 == --fetch ]]; then printf '%s\n' "$2" >>"$FETCH_DONE"; fi
exit "$result"
SH
cat >"$stage/bin/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "${@: -1}" >>"$TEST_LOG"
if [[ -n ${DOWNLOAD_GATE:-} ]]; then
  touch "$DOWNLOAD_GATE.entered"
  for attempt in {1..500}; do
    [[ -f $DOWNLOAD_GATE.release ]] && break
    sleep 0.01
  done
fi
[[ ${NETWORK_OFFLINE:-false} != true ]] || exit 7
exec /usr/bin/curl "$@"
SH
cat >"$stage/bin/owe" <<'SH'
#!/bin/bash
printf 'owe %s\n' "$*" >>"$TEST_LOG"
case $1 in
  render) printf 'P6\n1 1\n255\n\377\377\377' >"$(jq -r .path <<<"$2")" ;;
  raw)
    video=$(jq -r .path <<<"$2")
    [[ $(readlink -f "$HOME/.local/state/omarchy/current/background") == */"$(basename "${video%.*}").webp" ]]
    ;;
esac
SH
cat >"$stage/bin/omarchy-shell" <<'SH'
#!/bin/bash
[[ $1 != -q ]] || shift
printf 'shell %s\n' "$*" >>"$TEST_LOG"
[[ $2 != themeIntroCoverStatus ]] || echo ready
if [[ $1 == background && $2 == set && -n ${WAIT_FOR_CACHE:-} ]]; then
  for attempt in {1..200}; do
    [[ -f $WAIT_FOR_CACHE ]] && break
    sleep 0.01
  done
  [[ -f $WAIT_FOR_CACHE ]] || exit 1
fi
exit 0
SH
chmod +x "$stage/bin/"*

cache_root="$HOME/.cache/omarchy/background-intros"
cache="$cache_root/${OMARCHY_BACKGROUND_INTROS_URL//[^A-Za-z0-9._-]/_}/themes/demo/backgrounds/intros"
choose() { timeout 3 "$ROOT/bin/omarchy-theme-bg-set" "$1"; }
wait_file() {
  for attempt in {1..300}; do
    [[ -f $1 ]] && return 0
    sleep 0.01
  done
  fail "asynchronous download reaches $1"
}
wait_fetches() {
  local completed
  for attempt in {1..300}; do
    if [[ -f $FETCH_DONE ]]; then
      completed=$(grep -Fc "$1" "$FETCH_DONE" || true)
      (( completed >= $2 )) && return 0
    fi
    sleep 0.01
  done
  fail "background download jobs finish for $1"
}
assert_current() {
  [[ $(readlink -f "$current") == "$1" ]] || fail "download completion never changes the selected background"
  [[ $(<"$marker") == consumed-login ]] || fail "lazy selection leaves login consumption unchanged"
}
raw_count() { grep -c '^owe raw ' "$TEST_LOG" || true; }

DOWNLOAD_GATE="$stage/first" choose "$media/one.webp"
wait_file "$stage/first.entered"
assert_current "$media/one.webp"
[[ ! -f $cache/one.mp4 && $(raw_count) == 0 ]] || fail "a cold selection shows the still immediately"
timeout 1 flock "$XDG_RUNTIME_DIR/omarchy-theme-set.lock" true || fail "the downloader never inherits the selection lock"
touch "$stage/first.release"
wait_fetches "$media/one.webp" 1
wait_file "$cache/one.mp4"
assert_current "$media/one.webp"
[[ $(raw_count) == 0 ]] || fail "finishing the first download cannot start a delayed intro"
WAIT_FOR_CACHE="$cache/fast.mp4" choose "$media/fast.webp"
wait_fetches "$media/fast.webp" 1
assert_current "$media/fast.webp"
[[ -f $cache/fast.mp4 && $(raw_count) == 0 ]] || fail "even a download completed before selection returns cannot autoplay"
choose "$stage/plain.webp"
choose "$media/one.webp"
[[ $(raw_count) == 1 ]] || fail "a later different selection plays the cached intro"
choose "$media/one.webp"
[[ $(raw_count) == 1 ]] || fail "same-image confirmation never restarts an intro"
pass "first selection shows the still without waiting, and a later selection plays the downloaded intro"

DOWNLOAD_GATE="$stage/rapid" choose "$media/two.webp"
wait_file "$stage/rapid.entered"
choose "$stage/plain.webp"
DOWNLOAD_GATE="$stage/rapid" choose "$media/two.webp"
wait_fetches "$media/two.webp" 1
[[ $(grep -c '^curl .*two.mp4$' "$TEST_LOG") == 1 ]] || fail "concurrent selections share one download per clip"
choose "$stage/plain.webp"
touch "$stage/rapid.release"
wait_fetches "$media/two.webp" 2
wait_file "$cache/two.mp4"
assert_current "$stage/plain.webp"
[[ $(raw_count) == 1 ]] || fail "a stale download cannot start playback or undo a newer selection"
pass "rapid selections deduplicate downloads and completion cannot override the latest image"

NETWORK_OFFLINE=true choose "$media/retry.webp"
wait_fetches "$media/retry.webp" 1
assert_current "$media/retry.webp"
[[ ! -f $cache/retry.mp4 && ! -f $cache/retry.mp4.missing ]] || fail "a transient network failure remains retryable"
# Confirming an already-selected image can acquire a missing clip, without
# changing the no-replay rule for the current selection.
choose "$media/retry.webp"
wait_fetches "$media/retry.webp" 2
wait_file "$cache/retry.mp4"
[[ $(raw_count) == 1 ]] || fail "retry completion never starts playback on the current still"
pass "offline selection keeps its still and confirming it later can retry the download without autoplay"

choose "$media/missing.webp"
wait_fetches "$media/missing.webp" 1
wait_file "$cache/missing.mp4.missing"
choose "$media/missing.webp"
wait_fetches "$media/missing.webp" 2
[[ $(grep -c '^curl .*missing.mp4$' "$TEST_LOG") == 1 ]] || fail "a missing hosted intro is requested once"
assert_current "$media/missing.webp"
[[ -z $(find "$cache_root" -name '.intro.*' -print) ]] || fail "failed downloads leave no partial video"
pass "a missing hosted clip keeps the still and does not repeat the failed request"

requests=$(grep -c '^curl ' "$TEST_LOG")
ANIMATIONS=false choose "$media/one.webp"
wait_fetches "$media/one.webp" 2
mkdir -p "$HOME/.local/state/omarchy/toggles"
touch "$HOME/.local/state/omarchy/toggles/background-intros-off"
choose "$media/two.webp"
wait_fetches "$media/two.webp" 3
rm "$HOME/.local/state/omarchy/toggles/background-intros-off"
choose "$media/movie.mp4"
wait_fetches "$media/movie.mp4" 1
mkdir -p "$stage/custom"
printf 'different user image\n' >"$stage/custom/one.webp"
choose "$stage/custom/one.webp"
wait_fetches "$stage/custom/one.webp" 1
[[ $(grep -c '^curl ' "$TEST_LOG") == "$requests" && $(raw_count) == 1 ]] || fail "settings, video backgrounds and custom images cannot download or inherit an official intro"
choose "$media/default.webp"
[[ $(raw_count) == 2 && $(grep -c '^curl ' "$TEST_LOG") == "$requests" ]] || fail "shipped intros play without a download"
pass "disabled settings, video and custom images stay separate, while shipped intros keep working"
