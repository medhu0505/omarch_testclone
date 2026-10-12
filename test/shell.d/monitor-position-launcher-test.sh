#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home"
cat >"$scratch/bin/update-desktop-database" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$LAUNCHER_DATABASE_LOG"
if [[ ${LAUNCHER_DATABASE_FAIL:-0} == "1" ]]; then
  exit 1
fi
EOF
chmod +x "$scratch/bin/update-desktop-database"
test_home="$scratch/home"
test_data_home=""
export OMARCHY_PATH="$ROOT" PATH="$scratch/bin:$PATH"
export LAUNCHER_DATABASE_LOG="$scratch/database.log"

migration="$ROOT/migrations/1791778519.sh"
[[ -f $migration ]] || fail "monitor positioning has an update migration"
launcher="$test_home/.local/share/applications/omarchy-monitor-position.desktop"
run_migration() {
  env HOME="$test_home" XDG_DATA_HOME="$test_data_home" bash -euo pipefail "$migration"
}

run_migration
cmp "$ROOT/applications/omarchy-monitor-position.desktop" "$launcher" || fail "the migration installs the launcher for existing users"
[[ $(< "$LAUNCHER_DATABASE_LOG") == "$test_home/.local/share/applications" ]] || fail "the migration refreshes the application database"
pass "existing users receive the Monitor Position launcher"

printf 'custom launcher\n' >"$launcher"
printf 'unrelated launcher\n' >"$test_home/.local/share/applications/personal.desktop"
run_migration
[[ $(< "$launcher") == "custom launcher" ]] || fail "rerunning preserves an existing user launcher"
[[ $(< "$test_home/.local/share/applications/personal.desktop") == "unrelated launcher" ]] || fail "the migration preserves unrelated launchers"
(( $(wc -l <"$LAUNCHER_DATABASE_LOG") == 2 )) || fail "rerunning retries application database refresh"
pass "the migration is idempotent and preserves user launchers"

rm "$launcher"
test_data_home="$scratch/custom data"
run_migration
cmp "$ROOT/applications/omarchy-monitor-position.desktop" "$test_data_home/applications/omarchy-monitor-position.desktop" || fail "the migration honors XDG_DATA_HOME"
[[ ! -e $launcher ]] || fail "a custom data directory leaves the default path alone"
pass "the launcher migration supports a custom data directory"

custom_launcher="$test_data_home/applications/omarchy-monitor-position.desktop"
rm "$custom_launcher"
ln -s "$scratch/missing-custom-launcher" "$custom_launcher"
run_migration
[[ -L $custom_launcher && $(readlink "$custom_launcher") == "$scratch/missing-custom-launcher" ]] || fail "the migration preserves a dangling custom launcher symlink"
pass "custom launcher symlinks are preserved"

test_data_home="$scratch/retry data"
if LAUNCHER_DATABASE_FAIL=1 run_migration; then
  fail "a failed application database update must fail the migration"
fi
run_migration
cmp "$ROOT/applications/omarchy-monitor-position.desktop" "$test_data_home/applications/omarchy-monitor-position.desktop" || fail "a retry completes without replacing unrelated state"
pass "a failed database update can be retried"
