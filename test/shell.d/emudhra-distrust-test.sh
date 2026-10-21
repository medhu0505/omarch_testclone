#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export OMARCHY_PATH="$ROOT"
export EMUDHRA_TEST_DIR="$test_tmp"

certificate="$ROOT/default/ca-certificates/emsign-ecc-root-ca-g3.crt"
fingerprint=$(openssl x509 -in "$certificate" -noout -fingerprint -sha256)
[[ ${fingerprint#*=} == "86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B" ]] ||
  fail "blocklist contains the incident's affected root certificate"
[[ $(grep -c '^-----BEGIN CERTIFICATE-----$' "$certificate") == "1" ]] ||
  fail "blocklist contains exactly one certificate"
pass "blocklist pins the affected root by its SHA-256 fingerprint"

mkdir "$test_tmp/bin"
cat >"$test_tmp/bin/install" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 3 && $1 == "-Dm644" && $3 == "/etc/ca-certificates/trust-source/blocklist/omarchy-emsign-ecc-root-ca-g3.crt" ]]
printf 'install\n' >>"$EMUDHRA_TEST_DIR/calls"
/usr/bin/install -m644 "$2" "$EMUDHRA_TEST_DIR/blocklist.crt"
STUB
cat >"$test_tmp/bin/update-ca-trust" <<'STUB'
#!/bin/bash
set -euo pipefail
cmp "$OMARCHY_PATH/default/ca-certificates/emsign-ecc-root-ca-g3.crt" "$EMUDHRA_TEST_DIR/blocklist.crt"
printf 'extract\n' >>"$EMUDHRA_TEST_DIR/calls"
[[ ! -e $EMUDHRA_TEST_DIR/fail-extraction ]]
STUB
cat >"$test_tmp/bin/sudo" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'sudo\n' >>"$EMUDHRA_TEST_DIR/calls"
exec "$@"
STUB
chmod +x "$test_tmp/bin/"*
export PATH="$test_tmp/bin:$PATH"

setup="$ROOT/install/config/distrust-emudhra.sh"
migration="$ROOT/migrations/1792600399.sh"
bash -euo pipefail "$setup"
[[ $(cat "$test_tmp/calls") == $'install\nextract' ]] || fail "fresh setup installs before extracting trust"
[[ $(stat -c '%a' "$test_tmp/blocklist.crt") == "644" ]] || fail "blocklist is world-readable and owner-writable"
pass "fresh setup installs the blocklist and regenerates system trust"

bash -euo pipefail "$migration"
[[ $(tail -3 "$test_tmp/calls") == $'sudo\ninstall\nextract' ]] || fail "migration applies the same setup with privilege elevation"
pass "migration reruns the shared setup safely"

touch "$test_tmp/fail-extraction"
if bash -euo pipefail "$migration"; then
  fail "failed trust extraction must keep the migration pending"
fi
rm "$test_tmp/fail-extraction"
bash -euo pipefail "$migration"
[[ $(tail -3 "$test_tmp/calls") == $'sudo\ninstall\nextract' ]] || fail "migration retries extraction after the blocklist was installed"
pass "extraction failure propagates and a retry repairs the installed blocklist"

test_checkout="$test_tmp/checkout"
mkdir -p "$test_checkout/default/ca-certificates"
export OMARCHY_PATH="$test_checkout"
: >"$test_tmp/calls"
if bash -euo pipefail "$setup" 2>/dev/null; then
  fail "missing certificate must stop setup"
fi
[[ $(cat "$test_tmp/calls") == "install" ]] || fail "missing certificate does not regenerate unchanged trust"
pass "missing certificate fails setup before trust extraction"
