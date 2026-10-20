#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
for command in omarchy-shell update-desktop-database mise omarchy-mise-install; do
  printf '#!/bin/bash\nexit 0\n' >"$scratch/bin/$command"
done
chmod +x "$scratch/bin"/*
export OMARCHY_PATH="$ROOT" PATH="$scratch/bin:$ROOT/bin:$PATH"
# Every command finds its state under the test home, never the caller's.
unset XDG_STATE_HOME

# A new user, as the settings package's skel seeds one.
new_home() {
  local home="$scratch/$1"
  mkdir -p "$home/.local/share/applications" "$home/.config/omarchy" "$home/.local/state"
  cp "$ROOT"/applications/*.desktop "$home/.local/share/applications/"
  cp "$ROOT/config/omarchy/shell.json" "$home/.config/omarchy/shell.json"
  printf '%s\n' "$home"
}

bindings() {
  HOME="$1" XDG_STATE_HOME="${2-}" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
hl = {
  dsp = { exec_cmd = function(command) return { kind = "exec", arg = command } end },
  bind = function(keys, dispatcher, opts)
    if opts and opts.description then print(opts.description) end
  end,
}
require("default.hypr.helpers")
require("default.hypr.bindings.applications")
LUA
}

mapfile -t skipped < <(sed -e '/^#/d' -e '/^$/d' "$ROOT/default/regions/cn/apps-skip")
for required in YouTube X; do
  printf '%s\n' "${skipped[@]}" | grep -qxF "$required" || fail "China leaves out $required"
done
for name in "${skipped[@]}"; do
  [[ -f $ROOT/applications/$name.desktop ]] || grep -qF "\"$name\"" "$ROOT/default/hypr/bindings/applications.lua" ||
    fail "every name China leaves out is a shipped launcher or a preinstalled binding" "$name"
done
pass "China leaves out YouTube and X, and every name it lists exists"

china=$(new_home china)
HOME="$china" omarchy-region-preinstalls cn
for name in "${skipped[@]}"; do
  [[ ! -e $china/.local/share/applications/$name.desktop ]] || fail "China removes the $name launcher"
done
[[ -f $china/.local/share/applications/Basecamp.desktop && -f $china/.local/share/applications/HEY.desktop ]] ||
  fail "China keeps launchers it does not list"
pins=$(HOME="$china" omarchy-dock pinned | paste -sd ' ')
[[ $pins == "org.gnome.Nautilus chromium foot omacalc omawrite" ]] || fail "China unpins X and YouTube from the dock" "$pins"
pass "a China user loses the listed launchers and dock pins and keeps the rest"

china_bindings=$(bindings "$china")
for name in YouTube X "X Post" ChatGPT Grok WhatsApp Signal Music; do
  if grep -qxF "$name" <<<"$china_bindings"; then
    fail "China leaves out the $name binding"
  fi
done
for name in Terminal Email Calendar Obsidian "Music TUI"; do
  grep -qxF "$name" <<<"$china_bindings" || fail "China keeps the $name binding"
done
if grep -qxF YouTube <<<"$(bindings "$china" "$china/.local/state")"; then
  fail "China leaves out the YouTube binding with XDG_STATE_HOME set"
fi
pass "a China user's preinstalled bindings leave out the same apps, with XDG_STATE_HOME empty or set"

HOME="$china" omarchy-refresh-applications
[[ ! -e $china/.local/share/applications/YouTube.desktop && -f $china/.local/share/applications/Basecamp.desktop ]] ||
  fail "a launcher refresh keeps the skipped launchers out"
pass "a launcher refresh does not bring skipped launchers back"

world=$(new_home world)
snapshot() { (cd "$world" && find .local/share/applications .config/omarchy .local/state -type f -exec sha256sum {} + 2>/dev/null | sort); }
before=$(snapshot)
HOME="$world" omarchy-region-preinstalls us
HOME="$world" omarchy-refresh-applications
after=$(snapshot)
[[ $before == "$after" ]] || fail "a region without a skip list changes nothing" "$(diff <(echo "$before") <(echo "$after"))"
world_bindings=$(bindings "$world")
for name in YouTube X ChatGPT WhatsApp; do
  grep -qxF "$name" <<<"$world_bindings" || fail "World keeps the $name binding"
done
pass "World keeps every launcher, pin and binding"

for bad in "" CN ../cn "c n"; do
  if HOME="$world" omarchy-region-preinstalls "$bad" 2>/dev/null; then
    fail "omarchy-region-preinstalls refuses region '$bad'"
  fi
done
pass "omarchy-region-preinstalls takes only a region code"

grep -qF 'omarchy-region-preinstalls" cn' "$ROOT/install/user/region.sh" || fail "a China install's user finalization leaves out the region's apps"
pass "a China install's user finalization leaves out the region's apps"
