#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

STUB_DIR="$TMPDIR/stub"
mkdir -p "$STUB_DIR"

# Qt diagnostics reach stdout ahead of the payload: since Qt 6.12, the
# non-UTF-8 locale warning prints on the qs ipc client's stdout (#15834), so
# omarchy-shell is stubbed to emit that preamble before the plugin JSON.
cat >"$STUB_DIR/omarchy-shell" <<'STUB'
#!/bin/bash
printf '  WARN: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\n'
printf 'Qt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.\n'
cat "$FAKE_PLUGINS"
STUB
chmod +x "$STUB_DIR/omarchy-shell"

cat >"$TMPDIR/plugins.json" <<'JSON'
[
  {"id": "omarchy.clock", "name": "Clock", "kinds": ["bar-widget"], "enabled": true, "firstParty": true}
]
JSON

list() {
  PATH="$STUB_DIR:$PATH" FAKE_PLUGINS="$TMPDIR/plugins.json" \
    "$ROOT/bin/omarchy-plugin-list" "$@"
}

out=$(list)
[[ $out == *"omarchy.clock"* ]] \
  || fail "the table skips the Qt locale warning and lists the plugin" "$out"
pass "the table skips the Qt locale warning and lists the plugin"

out=$(list --json)
[[ $out == \[* ]] \
  || fail "--json output starts with the payload, not the warning" "$out"
pass "--json output starts with the payload, not the warning"

# A clean payload keeps working.
cat >"$STUB_DIR/omarchy-shell" <<'STUB'
#!/bin/bash
cat "$FAKE_PLUGINS"
STUB
chmod +x "$STUB_DIR/omarchy-shell"

cat >"$TMPDIR/plugins.json" <<'JSON'
[
  {"id": "acme.weather", "name": "Weather", "kinds": ["bar-widget"], "enabled": false, "firstParty": false}
]
JSON

out=$(list)
[[ $out == *"acme.weather"* ]] || fail "a clean payload still lists its plugin" "$out"
out=$(list --json)
[[ $(jq -r '.[0].id' <<<"$out") == "acme.weather" ]] || fail "a clean payload passes through --json whole" "$out"
pass "a clean payload still lists its plugin"

# No JSON at all is an error, not an empty plugin list.
cat >"$STUB_DIR/omarchy-shell" <<'STUB'
#!/bin/bash
printf '  WARN: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\n'
STUB
chmod +x "$STUB_DIR/omarchy-shell"

status=0
out=$(list 2>&1) || status=$?
(( status != 0 )) || fail "a payload that never arrives is an error" "$out"
[[ $out == *"no plugin list"* ]] || fail "the missing payload says so on stderr" "$out"
pass "a payload that never arrives is an error, not an empty list"
