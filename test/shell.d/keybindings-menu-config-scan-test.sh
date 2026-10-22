#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

tmpdir=$(mktemp -d) && [[ -n $tmpdir && -d $tmpdir ]] ||
  fail "the test gets a temporary directory to stub Hyprland in"
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"

# No platform package: neither its key names nor its binds.
menu="$tmpdir/omarchy-menu-keybindings"
platform_root_copy "$ROOT/bin/omarchy-menu-keybindings" "$menu" "$tmpdir/no-platform"

# The menu reads binds from Hyprland, which is not running here, so stand in for
# it. The terminal bind is a Lua one: Hyprland reports the chord and the
# description, and the menu recovers the command from the config it scans.
stub_hyprctl() {
  {
    echo '#!/bin/bash'
    echo 'case "$1" in'
    echo '  binds) cat <<'"'"'BINDS'"'"''
    printf 'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: SUPER + RETURN\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Terminal\n\tdispatcher: __lua\n\targ: \n'
    echo 'BINDS'
    echo '  ;;'
    echo '  devices) echo "active keymap: English (US)" ;;'
    echo '  -j) [[ $2 == getoption ]] && cat "'"$stub_bin"'/option-${3#input:}" 2>/dev/null ;;'
    echo 'esac'
  } >"$stub_bin/hyprctl"
  chmod +x "$stub_bin/hyprctl"
}

stub_hyprctl

# The menu scans the user's config for the binds Hyprland reports as Lua. A
# config that walks a result set while it loads (ipairs(hl.get_monitors())) has
# to see an empty one, or the scan never ends and the menu waits on it.
home="$tmpdir/home"
mkdir -p "$home/.config/hypr"
cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
for _, monitor in ipairs(hl.get_monitors()) do
  hl.config({ general = { layout = "master" } })
end

hl.bind("SUPER + RETURN", "omarchy-launch-terminal", { description = "Terminal" })
LUA

rendered=$(env -i PATH="$stub_bin:$ROOT/bin:$PATH" HOME="$home" \
  XDG_CACHE_HOME="$tmpdir/cache" OMARCHY_PATH="$ROOT" \
  timeout 30 bash "$menu" --print)

grep -qP '→ Terminal\texec\tomarchy-launch-terminal$' "$tmpdir"/cache/omarchy/keybindings-*.records ||
  fail "the config scan reaches the binds after a config that walks a result set" "$rendered"
pass "the config scan ends when the config walks a result set"

# A config that never finishes loading must not keep the menu from opening
# either: the scan has a budget, and the binds Hyprland reports are still there
# after it.
home="$tmpdir/hanging-home"
mkdir -p "$home/.config/hypr"
cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
while true do end
LUA

rendered=$(env -i PATH="$stub_bin:$ROOT/bin:$PATH" HOME="$home" \
  XDG_CACHE_HOME="$tmpdir/cache-hanging" OMARCHY_PATH="$ROOT" \
  OMARCHY_KEYBINDINGS_SCAN_TIMEOUT=2 \
  timeout 30 bash "$menu" --print)

grep -q 'SUPER + RETURN  *→ Terminal' <<<"$rendered" ||
  fail "the menu opens when the config never finishes loading" "$rendered"
pass "the menu opens when the config never finishes loading"
