#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# An installed launcher gets a real icon or the install says so, and removing
# the launcher takes its icon with it whatever format the icon has.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export OMARCHY_PATH="$ROOT"
export XDG_CURRENT_DESKTOP=Hyprland
# The icon search follows the data directories the desktop searches, so the
# test owns them: the data home follows the fake home, and the data
# directories hold only what this file puts there.
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_DATA_DIRS="$test_tmp/data"
mkdir -p "$HOME" "$test_tmp/bin" "$test_tmp/icons"

# A real one pixel PNG, so the icon check sees an image and not a body.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d >"$test_tmp/icon.png"

# The endpoint answers, so the download is exercised without a network. A 404
# answers with a body and exits 0, which is what the install has to catch.
cat >"$test_tmp/bin/curl" <<SH
#!/bin/bash
dest=""
url=""
while (( \$# )); do
  case \$1 in
    -o) dest=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
case "\$url" in
  *notfound*) printf '404: Not Found\n' >"\$dest"; exit 0 ;;
  *notimage*) printf 'this is not an image\n' >"\$dest"; exit 0 ;;
  *slow*) : >"$test_tmp/download-started"; sleep 2; cp "$test_tmp/icon.png" "\$dest"; exit 0 ;;
  *) cp "$test_tmp/icon.png" "\$dest"; exit 0 ;;
esac
SH
chmod +x "$test_tmp/bin/curl"

# The desktop database updater is not needed to exercise the icon handling,
# and it is not installed everywhere, so the test brings its own.
cat >"$test_tmp/bin/update-desktop-database" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$test_tmp/bin/update-desktop-database"

export PATH="$test_tmp/bin:$ROOT/bin:$PATH"

install_tui() {
  "$ROOT/bin/omarchy-tui-install" "$@"
}

icon_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
desktop_file() {
  printf '%s\n' "$HOME/.local/share/applications/$1.desktop"
}

# The answer is downloaded before the icon is written, and the icon directory
# is the one the desktop indexes: a download that is still in flight must not
# leave a file there for the theme to pick up.
rm -f "$test_tmp/download-started"
"$ROOT/bin/omarchy-tui-install" T13 true tile "https://example.invalid/slow.png" >/dev/null 2>&1 &
install_pid=$!
for _ in $(seq 1 100); do
  [[ -e $test_tmp/download-started ]] && break
  sleep 0.05
done
[[ -z "$(ls -A "$icon_dir" 2>/dev/null)" ]] ||
  fail "a download in flight leaves no file in the icon directory" "$(ls -A "$icon_dir")"
wait "$install_pid" || true
pass "a download in flight leaves no file in the icon directory"

# A URL that answers with an error body must not install that body as the
# icon, and the launcher must not be written either.
output=$(install_tui T1 true tile "https://example.invalid/notfound.png" 2>&1) && status=0 || status=$?
(( status != 0 )) || fail "an icon URL that answers with an error body fails the install" "$output"
[[ ! -e $icon_dir/t1.png ]] || fail "an icon URL that answers with an error body leaves no icon" "$(ls "$icon_dir")"
[[ ! -e $(desktop_file T1) ]] || fail "an icon URL that answers with an error body writes no launcher"
pass "an icon URL that answers with an error body fails the install"

# A URL that answers with something that is not an image is the same failure.
output=$(install_tui T2 true tile "https://example.invalid/notimage.png" 2>&1) && status=0 || status=$?
(( status != 0 )) || fail "an icon URL that answers with something else fails the install" "$output"
[[ ! -e $icon_dir/t2.png ]] || fail "an icon URL that answers with something else leaves no icon" "$(ls "$icon_dir")"
pass "an icon URL that answers with something else fails the install"

# A URL that answers with an image installs that image.
install_tui T3 true tile "https://example.invalid/icon.png" >/dev/null
[[ -s $icon_dir/t3.png ]] || fail "an icon URL that answers with an image installs it" "$(ls "$icon_dir")"
# The answer is written to a temporary file, which is owner-only, and the icon
# is moved into place, so the icon has to be readable like the one a direct
# download would have written.
[[ $(stat -c '%a' "$icon_dir/t3.png") == 644 ]] ||
  fail "the installed icon is readable" "$(stat -c '%a' "$icon_dir/t3.png")"
pass "an icon URL that answers with an image installs it"

# A name that resolves to no icon in the theme is reported, and the launcher
# is still written so the app can be started.
missing="omarchy-test-missing-4f7c2a"
output=$(install_tui T4 true tile "$missing" 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "a name that resolves to no icon still installs the launcher" "$output"
[[ $output == *"$missing"* ]] || fail "a name that resolves to no icon is reported" "$output"
grep -qx "Icon=$missing" "$(desktop_file T4)" || fail "the launcher keeps the icon name it was given" "$(cat "$(desktop_file T4)")"
pass "a name that resolves to no icon is reported"

# A failed reinstall leaves the icon that was installed before it alone.
install_tui T8 true tile "https://example.invalid/icon.png" >/dev/null
[[ -s $icon_dir/t8.png ]] || fail "the first install writes the icon" "$(ls "$icon_dir")"
cp "$icon_dir/t8.png" "$test_tmp/kept-icon.png"
output=$(install_tui T8 true tile "https://example.invalid/notfound.png" 2>&1) && status=0 || status=$?
(( status != 0 )) || fail "a reinstall with a broken icon URL fails" "$output"
cmp -s "$icon_dir/t8.png" "$test_tmp/kept-icon.png" ||
  fail "a failed reinstall keeps the installed icon" "$(file -b "$icon_dir/t8.png")"
pass "a failed reinstall keeps the installed icon"

# The answer is written to a temporary file beside the icon, and the icon
# directory is left holding only the icons that belong there.
[[ $(ls -A "$icon_dir" | grep -c 't[0-9]*\.png\.' || true) == 0 ]] ||
  fail "a failed download leaves no temporary file behind" "$(ls -A "$icon_dir")"
pass "a failed download leaves no temporary file behind"

# An icon the desktop finds in a configured data directory is found here too.
mkdir -p "$test_tmp/data/icons/hicolor/256x256/apps"
cp "$test_tmp/icon.png" "$test_tmp/data/icons/hicolor/256x256/apps/data-dir-icon.png"
output=$(XDG_DATA_DIRS="$test_tmp/data" install_tui T9 true tile data-dir-icon 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "an icon in a configured data directory still installs the launcher" "$output"
[[ $output != *'No icon named'* ]] || fail "an icon in a configured data directory is found" "$output"
pass "an icon in a configured data directory is found"

# The system data directories are searched too, the ones the desktop searches
# when the environment names no list of its own.
system_icon=$(find /usr/share/icons -mindepth 4 -maxdepth 4 \( -type f -o -type l \) -name '*.png' -print -quit 2>/dev/null)
if [[ -z $system_icon ]]; then
  skip "the system data directories are searched" "the system holds no icon to look for"
else
  system_icon_name=$(basename "$system_icon" .png)
  output=$(unset XDG_DATA_DIRS; install_tui T14 true tile "$system_icon_name" 2>&1) && status=0 || status=$?
  (( status == 0 )) || fail "an icon the system provides still installs the launcher" "$output"
  [[ $output != *'No icon named'* ]] || fail "an icon the system provides is found" "$output"
  pass "the system data directories are searched"
fi

# The theme layout is four levels below the theme root, and an entry deeper
# than that is not one the desktop resolves.
mkdir -p "$icon_dir/deeper/nested/dir"
cp "$test_tmp/icon.png" "$icon_dir/deeper/nested/dir/deep-icon.png"
output=$(install_tui T15 true tile deep-icon 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "a name that is too deep still installs the launcher" "$output"
[[ $output == *'No icon named'* ]] || fail "an entry deeper than the theme layout is not found" "$output"
rm -rf "$icon_dir/deeper"
pass "an entry deeper than the theme layout is not found"

# A file whose name starts with the icon name is indexed under its own name,
# so it does not answer for the name that was asked for.
# A theme entry is often a symbolic link to the real image, and the search
# has to see through it, the way the desktop does.
ln -sf "$test_tmp/icon.png" "$icon_dir/linked-icon.png"
output=$(install_tui T11 true tile linked-icon 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "an icon the theme links to still installs the launcher" "$output"
[[ $output != *'No icon named'* ]] || fail "an icon the theme links to is found" "$output"
rm -f "$icon_dir/linked-icon.png"
pass "an icon the theme links to is found"

cp "$test_tmp/icon.png" "$icon_dir/prefixed.other.png"
output=$(install_tui T10 true tile prefixed 2>&1) && status=0 || status=$?
[[ $output == *'No icon named'* ]] || fail "a name that is a prefix of another is reported" "$output"
rm -f "$icon_dir/prefixed.other.png"
pass "a name that is a prefix of another is reported"

# A name that is not an icon at all is reported too, even when the icon
# directory holds a dotfile the search would otherwise match.
printf 'hidden\n' >"$icon_dir/.hidden"
output=$(install_tui T7 true tile . 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "a name that is not an icon still installs the launcher" "$output"
[[ $output == *'No icon named'* ]] || fail "a name that is not an icon is reported" "$output"
rm -f "$icon_dir/.hidden"
pass "a name that is not an icon is reported"

# A name that does resolve is not reported.
mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps"
cp "$test_tmp/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/known-icon.png"
output=$(install_tui T5 true tile known-icon 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "a name that resolves to an icon installs the launcher" "$output"
[[ $output != *known-icon* ]] || fail "a name that resolves to an icon is not reported" "$output"
pass "a name that resolves to an icon is not reported"

# A local icon keeps its format, and removing the launcher takes it away.
printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="red"/></svg>' >"$test_tmp/local.svg"
install_tui T6 true tile "$test_tmp/local.svg" >/dev/null
[[ -e $icon_dir/t6.svg ]] || fail "a local icon is installed with its own format" "$(ls "$icon_dir")"
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-tui-remove" T6 >/dev/null 2>&1
[[ ! -e $icon_dir/t6.svg ]] || fail "removing a launcher removes its icon" "$(ls "$icon_dir")"
[[ ! -e $(desktop_file T6) ]] || fail "removing a launcher removes the launcher"
pass "removing a launcher removes its icon"

# An icon is installed with the format the file it came from had, and the
# formats the theme ships are not the only ones an icon can have: removing the
# launcher takes the icon away whatever format it was installed with.
cp "$test_tmp/icon.png" "$test_tmp/local.jpg"
install_tui T16 true tile "$test_tmp/local.jpg" >/dev/null
[[ -e $icon_dir/t16.jpg ]] || fail "a local icon keeps its own format" "$(ls "$icon_dir")"
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-tui-remove" T16 >/dev/null 2>&1
[[ ! -e $icon_dir/t16.jpg ]] || fail "removing a launcher removes its icon in any format" "$(ls "$icon_dir")"
pass "removing a launcher removes its icon in any format"

# The web app launcher has the same icon to take away.
cp "$test_tmp/local.svg" "$test_tmp/webapp.svg"
install_tui W1 true tile "$test_tmp/webapp.svg" >/dev/null
cp "$test_tmp/webapp.svg" "$icon_dir/w1.svg"
cat >"$HOME/.local/share/applications/W1.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=W1
Exec=omarchy-launch-webapp https://example.com
Icon=w1
EOF
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-webapp-remove" W1 >/dev/null 2>&1
[[ ! -e $icon_dir/w1.svg ]] || fail "removing a web app removes its icon" "$(ls "$icon_dir")"
pass "removing a web app removes its icon"

# The download replaces the caller's own signal handlers and puts them back:
# a command that already handles a signal must not lose it because it
# downloaded an icon.
cat >"$test_tmp/bin/omarchy-icon-helper-check" <<'SH'
#!/bin/bash
source "$OMARCHY_PATH/install/helpers/icon.sh"
trap 'exit 42' INT
mkdir -p "$OMARCHY_ICON_DIR"
omarchy_icon_download "https://example.invalid/icon.png" "$OMARCHY_ICON_DIR/helper-check.png" >/dev/null
trap -p INT | grep -q "exit 42" || exit 1
SH
chmod +x "$test_tmp/bin/omarchy-icon-helper-check"
"$test_tmp/bin/omarchy-icon-helper-check" ||
  fail "a download keeps the caller's signal handler" "the handler was replaced"
pass "a download keeps the caller's signal handler"

# The web app installer downloads the icon the same guarded way: an icon URL
# that answers with an image installs it, and one that answers with an error
# body fails the install and leaves the installed icon alone.
output=$("$ROOT/bin/omarchy-webapp-install" W2 "https://example.invalid" "https://example.invalid/icon.png" 2>&1) && status=0 || status=$?
(( status == 0 )) || fail "a web app with an icon URL installs" "$output"
[[ -s $icon_dir/w2.png ]] || fail "the web app icon is installed" "$(ls "$icon_dir")"
cp "$icon_dir/w2.png" "$test_tmp/kept-webapp-icon.png"
output=$("$ROOT/bin/omarchy-webapp-install" W2 "https://example.invalid" "https://example.invalid/notfound.png" 2>&1) && status=0 || status=$?
(( status != 0 )) || fail "a web app with a broken icon URL fails the install" "$output"
cmp -s "$icon_dir/w2.png" "$test_tmp/kept-webapp-icon.png" ||
  fail "a failed web app reinstall keeps the installed icon" "$(file -b "$icon_dir/w2.png")"
pass "the web app installer downloads its icon the guarded way"

# A name that sanitizes to nothing left the icon at the empty name, where the
# installer wrote it: the file name is the extension alone. That file is
# taken away, and the files that carry a name of their own stay.
cp "$test_tmp/icon.png" "$icon_dir/.png"
cp "$test_tmp/icon.png" "$icon_dir/.named.png"
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-tui-remove" '!!!' >/dev/null 2>&1
[[ ! -e $icon_dir/.png ]] || fail "an icon at the empty name is removed" "$(ls -a "$icon_dir")"
[[ -e $icon_dir/.named.png ]] || fail "an icon with a name of its own stays" "$(ls -a "$icon_dir")"
rm -f "$icon_dir/.named.png"
pass "an icon at the empty name is removed"

# A name the user typed can hold a glob or a path, so it is never matched as
# one: the icons of the other apps stay where they are.
cp "$test_tmp/icon.png" "$icon_dir/other-app.png"
printf 'hidden\n' >"$icon_dir/.hidden"
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-tui-remove" 'T*' >/dev/null 2>&1
[[ -e $icon_dir/other-app.png ]] || fail "a name with a glob removes no other icon" "$(ls -a "$icon_dir")"
[[ -e $icon_dir/.hidden ]] || fail "a name with a glob removes no hidden file" "$(ls -a "$icon_dir")"
OMARCHY_REMOVE_NOTIFY=false "$ROOT/bin/omarchy-tui-remove" '!!!' >/dev/null 2>&1
[[ -e $icon_dir/other-app.png ]] || fail "a name without a letter removes no other icon" "$(ls -a "$icon_dir")"
[[ -e $icon_dir/.hidden ]] || fail "a name without a letter removes no hidden file" "$(ls -a "$icon_dir")"
pass "a name the user typed never removes another icon"
