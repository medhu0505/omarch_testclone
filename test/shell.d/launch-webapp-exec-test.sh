#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
mkdir -p "$mock_bin" "$test_home/.local/share/applications"
export XDG_CONFIG_HOME="$test_home/.config" XDG_DATA_HOME="$test_home/.local/share"

cat >"$mock_bin/omarchy-cmd-default-browser" <<'SH'
#!/bin/bash
echo brave-browser.desktop
SH
cat >"$mock_bin/omarchy-cmd-browser-handoff" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$OMARCHY_TEST_WEBAPP_LAUNCH"
SH
chmod +x "$mock_bin"/*

launch_log="$test_tmp/launch"

run_launch() {
  HOME="$test_home" PATH="$mock_bin:$PATH" OMARCHY_TEST_WEBAPP_LAUNCH="$launch_log" \
    bash "$ROOT/bin/omarchy-launch-webapp" "$@"
}

cat >"$test_home/.local/share/applications/brave-browser.desktop" <<'EOF'
[Desktop Entry]
Exec=brave %U
EOF

run_launch "https://example.test/app"
expected=$'uwsm-app\n--\nbrave\n--app=https://example.test/app'
[[ $(cat "$launch_log") == "$expected" ]] || fail "web app launcher runs a plain browser entry" "$(cat "$launch_log")"
pass "web app launcher runs a plain browser entry"

cat >"$test_home/.local/share/applications/brave-browser.desktop" <<'EOF'
[Desktop Entry]
Exec=env "BRAVE_FLAG=a b" brave --class=test %U
EOF

run_launch "https://example.test/app" --new-window
expected=$'uwsm-app\n--\nenv\nBRAVE_FLAG=a b\nbrave\n--class=test\n--app=https://example.test/app\n--new-window'
[[ $(cat "$launch_log") == "$expected" ]] || fail "web app launcher runs every word of a wrapped Exec line" "$(cat "$launch_log")"
pass "web app launcher runs every word of a wrapped Exec line"
