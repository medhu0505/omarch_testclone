#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
for command in omarchy-shell update-desktop-database mise omarchy-mise-install pkill pgrep; do
  printf '#!/bin/bash\nexit 0\n' >"$scratch/bin/$command"
done
# A shell restart has no session to reach during an install; record any attempt.
printf '#!/bin/bash\necho restart >>"$RESTART_LOG"\n' >"$scratch/bin/omarchy-restart-shell"
# The fonts installed on this machine; Maple Mono NF CN only where the test says so.
printf '#!/bin/bash\nprintf "JetBrainsMono Nerd Font,JetBrainsMono NF\\n"\n[[ -z ${FONTS_EXTRA:-} ]] || printf "%%s\\n" "$FONTS_EXTRA"\n' >"$scratch/bin/fc-list"
export RESTART_LOG="$scratch/restarts"
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
  for terminal in foot alacritty kitty; do
    mkdir -p "$home/.config/$terminal" && cp "$ROOT/config/$terminal/"* "$home/.config/$terminal/"
  done
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
HOME="$china" FONTS_EXTRA="Maple Mono NF CN" OMARCHY_SETUP_CONTEXT=iso-chroot omarchy-region-preinstalls cn
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

grep -qx 'font=Maple Mono NF CN:size=9' "$china/.config/foot/foot.ini" || fail "China sets Maple in foot" "$(grep '^font' "$china/.config/foot/foot.ini")"
grep -qF 'bold = { family = "Maple Mono NF CN", style = "Bold" }' "$china/.config/alacritty/alacritty.toml" || fail "China sets Maple in alacritty and keeps each style"
grep -qx 'font_family Maple Mono NF CN' "$china/.config/kitty/kitty.conf" || fail "China sets Maple in kitty"
grep -q '<string>Maple Mono NF CN</string>' "$china/.config/fontconfig/fonts.conf" || fail "China makes Maple the fontconfig monospace"
[[ ! -e $RESTART_LOG ]] || fail "an install sets the font without restarting a shell"
pass "a China install sets Maple Mono NF CN in every terminal and fontconfig, with no shell restart"

no_maple=$(new_home no-maple)
HOME="$no_maple" OMARCHY_SETUP_CONTEXT=iso-chroot omarchy-region-preinstalls cn
[[ ! -e $no_maple/.config/fontconfig/fonts.conf ]] && grep -qx 'font=JetBrainsMono Nerd Font:size=9' "$no_maple/.config/foot/foot.ini" ||
  fail "a China install without Maple keeps the default font"
pass "a China install that does not carry Maple keeps the default font"

world=$(new_home world)
snapshot() { (cd "$world" && find .local/share/applications .config .local/state -type f -exec sha256sum {} + 2>/dev/null | sort); }
before=$(snapshot)
HOME="$world" FONTS_EXTRA="Maple Mono NF CN" omarchy-region-preinstalls us
HOME="$world" omarchy-refresh-applications
after=$(snapshot)
[[ $before == "$after" ]] || fail "a region without a skip list changes nothing" "$(diff <(echo "$before") <(echo "$after"))"
world_bindings=$(bindings "$world")
for name in YouTube X ChatGPT WhatsApp; do
  grep -qxF "$name" <<<"$world_bindings" || fail "World keeps the $name binding"
done
pass "World keeps every launcher, pin, binding and its font"

for bad in "" CN ../cn "c n"; do
  if HOME="$world" omarchy-region-preinstalls "$bad" 2>/dev/null; then
    fail "omarchy-region-preinstalls refuses region '$bad'"
  fi
done
pass "omarchy-region-preinstalls takes only a region code"

grep -qF 'omarchy-region-preinstalls" cn' "$ROOT/install/user/region.sh" || fail "a China install's user finalization leaves out the region's apps"
pass "a China install's user finalization leaves out the region's apps"
