#!/bin/bash
#
# The migration that gives existing installs the 1-second quiet Limine
# boot: a stock (commented) timeout is replaced, a timeout the user set
# is left alone, quiet is added wherever missing, and a second run
# changes nothing.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1791898365.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"
printf '#!/bin/bash\n[[ ${1:-} == -v ]] && exit 0\nexec "$@"\n' >"$stub_bin/sudo"
chmod +x "$stub_bin/sudo"

conf="$test_dir/limine.conf"
run_migration() {
  PATH="$stub_bin:$PATH" OMARCHY_LIMINE_CONF="$conf" bash -euo pipefail "$migration" >/dev/null
}

printf '### Read more\n#timeout: 3\ndefault_entry: 2\n' >"$conf"
run_migration
grep -Fxq 'timeout: 1' "$conf" || fail "stock boot menu did not get the 1 second timeout"
grep -Fxq 'quiet: yes' "$conf" || fail "stock boot menu did not get quiet boot"
run_migration
[[ $(grep -c '^timeout:' "$conf") == 1 && $(grep -c '^quiet:' "$conf") == 1 ]] ||
  fail "migration is not idempotent"
pass "stock boot menu gets the 1 second quiet boot, once"

printf 'timeout: 5\ndefault_entry: 2\n' >"$conf"
run_migration
grep -Fxq 'timeout: 5' "$conf" || fail "a timeout the user set was replaced"
grep -Fxq 'quiet: yes' "$conf" || fail "quiet boot was not added beside a user timeout"
pass "a timeout the user set stays, and quiet is added"

printf 'default_entry: 2\n' >"$conf"
run_migration
grep -Fxq 'timeout: 1' "$conf" || fail "a boot menu with no timeout line did not get one"
grep -Fxq 'quiet: yes' "$conf" || fail "a boot menu with no timeout line did not get quiet"
grep -Fxq 'default_entry: 2' "$conf" || fail "a boot menu with no timeout line lost its contents"
pass "a boot menu with no timeout line gets one and keeps its contents"

printf 'TIMEOUT: no\nQUIET: no\n' >"$conf"
before=$(cat "$conf")
run_migration
[[ $(cat "$conf") == "$before" ]] || fail "a boot menu set in uppercase was overridden"
pass "a boot menu set in uppercase is the user's and stays"

printf 'timeout: 1\nquiet: yes\n' >"$conf"
before=$(cat "$conf")
run_migration
[[ $(cat "$conf") == "$before" ]] || fail "an already quiet fast boot was changed"
pass "an already quiet fast boot is left alone"

rm -f "$conf"
run_migration
pass "a machine without a Limine menu is left alone"
