#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stubs="$tmpdir/stubs"
mkdir -p "$stubs"

# A curl stub that "downloads" a fixture payload of our choosing, so the test
# exercises omarchy-webapp-install's icon handling without the network.
cat >"$stubs/curl" <<'CURL'
#!/bin/bash
while (($#)); do
  if [[ $1 == -o ]]; then
    cp "$STUB_ICON_PAYLOAD" "$2"
    exit 0
  fi
  shift
done
exit 1
CURL
chmod +x "$stubs/curl"

# The fixtures are tiny 2x2 images in the three formats sites actually serve
# for icons. download_icon accepts anything with an image/* MIME type, so a
# site serving WebP or ICO used to land in a file named .png -- which the
# icon theme spec only looks up by name and GTK 4.24 then draws blank.
printf 'UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA=' | base64 -d >"$tmpdir/icon.webp"
printf 'AAABAAEAAgIAAAEAIABAAAAAFgAAACgAAAACAAAABAAAAAEAIAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAD/AAD//wAA//8AAP//AAD/AAAAAAAAAAA=' | base64 -d >"$tmpdir/icon.ico"
printf 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAQMAAABIeJ9nAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQCAAJz5pZEAAAAHdElNRQfqChIQLBoT3iRVAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTEwLTE4VDE2OjQ0OjI2KzAwOjAwSpKMLAAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMC0xOFQxNjo0NDoyNiswMDowMDBs2hVPAAAADElEQVQI12NgYGAAAAAEAAEnNCcKAAAAAElFTkSuQmCC' | base64 -d >"$tmpdir/icon.png"

for f in icon.webp icon.ico icon.png; do
  case $f in
  icon.webp) mime=image/webp ;;
  icon.ico) mime=image/vnd.microsoft.icon ;;
  icon.png) mime=image/png ;;
  esac
  [[ $(file -b --mime-type "$tmpdir/$f") == "$mime" ]] ||
    fail "test fixture $f is a $mime image" "$(file "$tmpdir/$f")"
done
pass "test fixtures decode to the image formats they claim"

icon_dir="$tmpdir/home/.local/share/icons/hicolor/256x256/apps"

install_with_icon() {
  local payload="$1" app="$2"

  rm -rf "$tmpdir/home"
  mkdir -p "$tmpdir/home"
  HOME="$tmpdir/home" PATH="$stubs:$ROOT/bin:$PATH" STUB_ICON_PAYLOAD="$payload" \
    "$ROOT/bin/omarchy-webapp-install" "$app" "https://example.com" "https://example.com/icon" \
    >"$tmpdir/out" 2>"$tmpdir/err"
}

# A WebP served for a site's icon must end up on disk as real PNG data.
install_with_icon "$tmpdir/icon.webp" "Webp App"
[[ $(file -b --mime-type "$icon_dir/webp-app.png") == image/png ]] ||
  fail "a downloaded WebP icon is saved as PNG data" "$(file "$icon_dir/webp-app.png" 2>&1 || true)"
pass "a downloaded WebP icon is saved as real PNG data"

# Same for the .ico files favicon endpoints still serve.
install_with_icon "$tmpdir/icon.ico" "Ico App"
[[ $(file -b --mime-type "$icon_dir/ico-app.png") == image/png ]] ||
  fail "a downloaded ICO icon is saved as PNG data" "$(file "$icon_dir/ico-app.png" 2>&1 || true)"
pass "a downloaded ICO icon is saved as real PNG data"

# A favicon .ico usually carries several sizes, smallest first here (1x1, 2x2).
# The largest becomes the icon, and no per-frame -N.png files are left beside it.
printf 'AAABAAIAAQEAAAEAIAAwAAAAJgAAAAICAAABACAAQAAAAFYAAAAoAAAAAQAAAAIAAAABACAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAD//wAAAAAoAAAAAgAAAAQAAAABACAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAA/wAA//8AAP//AAD//wAA/wAAAAAAAAAA' | base64 -d >"$tmpdir/multi.ico"
install_with_icon "$tmpdir/multi.ico" "Multi App"
[[ $(file -b "$icon_dir/multi-app.png") == "PNG image data, 2 x 2,"* ]] ||
  fail "a multi-size ICO icon is saved as its largest size, as PNG data" "$(file "$icon_dir/multi-app.png" 2>&1 || true)"
[[ $(ls "$icon_dir") == "multi-app.png" ]] ||
  fail "a multi-size ICO icon leaves only one file behind" "$(ls "$icon_dir")"
pass "a multi-size ICO icon is saved as its largest size, alone"

# Past a million pixels magick prints the area as 1.04858e+06, which must still
# outrank a 256x256 frame's plain 65536.
magick -size 256x256 xc:blue -size 1024x1024 xc:red "gif:$tmpdir/big.gif"
install_with_icon "$tmpdir/big.gif" "Big App"
[[ $(file -b "$icon_dir/big-app.png") == "PNG image data, 1024 x 1024,"* ]] ||
  fail "a frame past a million pixels is still the largest" "$(file "$icon_dir/big-app.png" 2>&1 || true)"
pass "a frame past a million pixels is still the largest"

# A genuine PNG passes through untouched.
before=$(sha256sum "$tmpdir/icon.png" | cut -d' ' -f1)
install_with_icon "$tmpdir/icon.png" "Png App"
[[ $(file -b --mime-type "$icon_dir/png-app.png") == image/png ]] ||
  fail "a downloaded PNG icon stays a PNG" "$(file "$icon_dir/png-app.png" 2>&1 || true)"
[[ $(sha256sum "$icon_dir/png-app.png" | cut -d' ' -f1) == "$before" ]] ||
  fail "a downloaded PNG icon is kept byte for byte"
pass "a downloaded PNG icon passes through unchanged"

# If the misnamed file cannot be converted, it must not be left behind as a
# blank icon: download_icon fails and the web app install reports the failure.
broken_magick="$stubs/magick"
printf '#!/bin/bash\nexit 1\n' >"$broken_magick"
chmod +x "$broken_magick"
if HOME="$tmpdir/home" PATH="$stubs:$ROOT/bin:$PATH" STUB_ICON_PAYLOAD="$tmpdir/icon.webp" \
  "$ROOT/bin/omarchy-webapp-install" "Broken App" "https://example.com" "https://example.com/icon" \
  >"$tmpdir/out" 2>"$tmpdir/err"; then
  fail "an unconvertible icon fails the install"
fi
grep -Fq 'Failed to download icon' "$tmpdir/out" ||
  fail "an unconvertible icon reports the download failure" "$(cat "$tmpdir/out")"
[[ ! -e $icon_dir/broken-app.png ]] ||
  fail "an unconvertible icon is not left behind as a blank .png" "$(file "$icon_dir/broken-app.png")"
[[ ! -e "$tmpdir/home/.local/share/applications/Broken App.desktop" ]] ||
  fail "an unconvertible icon writes no desktop file"
pass "an unconvertible icon fails the install instead of leaving a blank .png"
