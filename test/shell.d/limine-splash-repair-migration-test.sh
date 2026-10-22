#!/bin/bash
#
# The migration that puts splash back into a drifted omarchy-defaults.conf:
# Omarchy's own quiet line gets the token back while the rest of the file and
# any command line a user wrote stay as they are, and the boot image is rebuilt
# once per machine, only where the booted command line lacks the token.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1792673722.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"

# sudo just drops the prefix, and can be denied: the repair goes through it.
printf '#!/bin/bash\n[[ ${SUDO_DENY:-} == 1 ]] && exit 1\nexec "$@"\n' >"$stub_bin/sudo"
# A rebuild records that it ran, and writes the new command line into the boot
# menu, unless it is told to build nothing.
cat >"$stub_bin/limine-mkinitcpio" <<'STUB'
#!/bin/bash
echo rebuilt >>"${REBUILDS:?}"
[[ -z ${REBUILD_FAILS:-} ]] || exit 1
[[ -n ${REBUILD_BUILDS_NOTHING:-} ]] || printf '  cmdline: %s\n' "${NEW_CMDLINE:?}" >"${LIMINE_CONF:?}"
STUB
# limine-entry-tool answers with the command line the config gives the entries
# limine-mkinitcpio builds.
cat >"$stub_bin/limine-entry-tool" <<'STUB'
#!/bin/bash
[[ $1 == "--get-cmdline" ]] || exit 2
printf '%s\n' "${ENTRY_CMDLINE:?}"
STUB
# pacman names the package that owns a kernel's modules.builtin.
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == "-Qqo" && -f ${2%/*}/owner ]] || exit 1
cat "${2%/*}/owner"
STUB
chmod +x "$stub_bin"/*

printf 'load_config() { MKINITCPIO_FALLBACK=${FALLBACKS:-}; }\n' >"$test_dir/limine-common-functions"

# One installed Omarchy kernel, the one the rebuild builds.
modules_dir="$test_dir/modules"
mkdir -p "$modules_dir/linux-omarchy"
touch "$modules_dir/linux-omarchy/modules.builtin"
echo linux-omarchy >"$modules_dir/linux-omarchy/owner"

conf="$test_dir/omarchy-defaults.conf"
menu="$test_dir/limine.conf"

# The drift the issue reports: a backed-up copy of Omarchy's own line that lost
# splash while keeping every parameter the older guards look for.
write_drifted() {
  cat >"$conf" <<'EOF'
TARGET_OS_NAME="Omarchy"

KERNEL_CMDLINE[default]+=" quiet loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0"

KERNEL_CMDLINE[default]+=" systemd.tty.term.console=dumb"
EOF
}

run() { # booted cmdline; further KEY=VALUE arguments go to env
  : >"$test_dir/rebuilds"
  : >"$test_dir/out"
  printf '%s\n' "$1" >"$test_dir/cmdline"
  env PATH="$stub_bin:$ROOT/bin:$PATH" REBUILDS="$test_dir/rebuilds" LIMINE_CONF="$menu" \
    NEW_CMDLINE="$1" ENTRY_CMDLINE="$1" OMARCHY_LIMINE_CONF="$menu" \
    OMARCHY_RUNNING_CMDLINE="$test_dir/cmdline" OMARCHY_LIMINE_DEFAULTS_CONF="$conf" \
    OMARCHY_KERNEL_MODULES_DIR="$modules_dir" \
    OMARCHY_LIMINE_FUNCTIONS="$test_dir/limine-common-functions" \
    OMARCHY_LIMINE_REBUILD_MARKER="$test_dir/marker" "${@:2}" \
    bash -euo pipefail "$migration" >"$test_dir/out"
}
rebuilds() { wc -l <"$test_dir/rebuilds"; }
reset() { rm -f "$test_dir/marker"; }

# The reported machine: Limine with UKIs, so the menu carries no command lines
# of its own, and a booted command line without splash.
write_drifted
run 'root=PARTUUID=1 rw quiet loglevel=0' REBUILD_BUILDS_NOTHING=1
grep -Fxq 'KERNEL_CMDLINE[default]+=" quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0"' "$conf" ||
  fail "the drifted Omarchy line did not get splash back" "content: $(grep quiet "$conf")"
grep -Fxq 'KERNEL_CMDLINE[default]+=" systemd.tty.term.console=dumb"' "$conf" ||
  fail "the repair changed another line of the same file"
grep -Fxq 'TARGET_OS_NAME="Omarchy"' "$conf" || fail "the repair dropped a line from the file"
[[ ! -e $conf.new ]] || fail "the staged rewrite was left behind"
grep -Fq "Restored splash in $conf" "$test_dir/out" || fail "the repair was not reported"
[[ $(rebuilds) == 1 && -e $test_dir/marker ]] ||
  fail "the repaired file was not rebuilt once into the boot image"
pass "a drifted Omarchy line gets splash back, the rest of the file stays, and the boot image is rebuilt once"

before=$(cat "$conf")
run 'root=PARTUUID=1 rw quiet loglevel=0' REBUILD_BUILDS_NOTHING=1
[[ $(cat "$conf") == "$before" ]] || fail "a second run changed the repaired file"
[[ $(rebuilds) == 0 && -e $test_dir/marker ]] ||
  fail "another user's run rebuilt the boot image before the first reboot"
pass "another user before the reboot repairs nothing and rebuilds nothing"

# The file is right and the machine already booted with it: nothing to do.
reset
cp "$ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf" "$conf"
run 'root=PARTUUID=1 rw quiet splash loglevel=0' REBUILD_BUILDS_NOTHING=1
[[ $(rebuilds) == 0 && ! -e $test_dir/marker ]] ||
  fail "a machine that already boots with splash was rebuilt"
pass "a machine that already boots with splash is left alone"

# The guard the issue asks for: the file is right, the boot image predates it.
cp "$ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf" "$conf"
run 'root=PARTUUID=1 rw quiet loglevel=0' \
  NEW_CMDLINE='root=PARTUUID=1 rw quiet splash loglevel=0'
cmp -s "$conf" "$ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf" ||
  fail "the packaged defaults were rewritten"
[[ $(rebuilds) == 1 && -e $test_dir/marker ]] ||
  fail "a boot image that predates splash was not rebuilt"
pass "packaged defaults on a machine booted without splash get one rebuild and no file change"

# A command line the user wrote, with none of the tokens Omarchy ships beside
# splash: not ours to edit.
reset
printf 'KERNEL_CMDLINE[default]=" root=PARTUUID=1 rw quiet splash"\n' >"$conf"
before=$(cat "$conf")
run 'root=PARTUUID=1 rw quiet splash'
[[ $(cat "$conf") == "$before" && $(rebuilds) == 0 && ! -e $test_dir/marker ]] ||
  fail "a command line the user wrote was edited or rebuilt"
pass "a user-written command line is left alone"

# The word quiet inside another parameter's value is not the token, so the line
# is not Omarchy's and is left alone too.
reset
printf 'KERNEL_CMDLINE[default]+=" foo=quiet loglevel=0 vt.global_cursor_default=0"\n' >"$conf"
before=$(cat "$conf")
run 'root=PARTUUID=1 rw quiet loglevel=0' REBUILD_BUILDS_NOTHING=1
[[ $(cat "$conf") == "$before" && $(rebuilds) == 0 ]] ||
  fail "the word quiet inside another value was taken for the token"
pass "quiet inside another parameter's value is not Omarchy's line"

# A drifted line that also carries a setting of the user's own keeps it.
reset
printf 'KERNEL_CMDLINE[default]+=" quiet loglevel=0 vt.global_cursor_default=0 nvidia_drm.fbdev=1"\n' >"$conf"
run 'root=PARTUUID=1 rw quiet loglevel=0' \
  NEW_CMDLINE='root=PARTUUID=1 rw quiet splash loglevel=0'
grep -Fxq 'KERNEL_CMDLINE[default]+=" quiet splash loglevel=0 vt.global_cursor_default=0 nvidia_drm.fbdev=1"' "$conf" ||
  fail "a setting beside splash on the same line was dropped" "content: $(cat "$conf")"
pass "the tokens a user added to Omarchy's line survive the repair"

# A backup= file an editor saved without a last newline keeps its last line.
reset
printf 'KERNEL_CMDLINE[default]+=" quiet loglevel=0 vt.global_cursor_default=0"\nSNAPSHOT_FORMAT_CHOICE=5' >"$conf"
run 'root=PARTUUID=1 rw quiet loglevel=0' REBUILD_BUILDS_NOTHING=1
grep -Fxq 'SNAPSHOT_FORMAT_CHOICE=5' "$conf" ||
  fail "the repair dropped a last line with no trailing newline" "content: $(cat "$conf")"
pass "a last line without a trailing newline survives the rewrite"

# The rebuild failed: the migration stays pending, so the next update retries.
reset
write_drifted
if run 'root=PARTUUID=1 rw quiet loglevel=0' REBUILD_FAILS=1; then
  fail "a rebuild that failed was reported as a success"
fi
grep -Fq ' quiet splash ' "$conf" || fail "the failed run lost the repaired file"
[[ ! -e $test_dir/marker ]] || fail "a failed rebuild was marked as done"
pass "a rebuild that fails leaves the migration pending and the repair in place"

# limine-mkinitcpio exits 0 past a kernel it could not build: the config gives
# splash to the entry the rebuild builds, and the menu has other distributions'
# entries only, so the missing splash is the rebuild's fault.
reset
write_drifted
if run 'root=PARTUUID=1 rw quiet loglevel=0' \
  NEW_CMDLINE='rhgb quiet root=/dev/mapper/fedora' \
  ENTRY_CMDLINE='root=PARTUUID=1 rw quiet splash loglevel=0'; then
  fail "a rebuild that left splash out of the boot menu was reported as a success"
fi
[[ ! -e $test_dir/marker ]] || fail "a rebuild that left splash out of the menu was marked as done"
pass "a boot menu without splash after the rebuild leaves the migration pending"

# The machine's own /etc/default/limine replaces Omarchy's command line with a
# plain KERNEL_CMDLINE[default]=, so no rebuild can add splash. That is the
# administrator's command line: say how to keep Omarchy's defaults, and do not
# stop every later migration on it.
reset
write_drifted
if ! run 'root=PARTUUID=1 rw quiet loglevel=0' \
  NEW_CMDLINE='root=PARTUUID=1 rw quiet loglevel=0' \
  ENTRY_CMDLINE='root=PARTUUID=1 rw quiet loglevel=0'; then
  fail "a command line the administrator owns stopped the migration"
fi
[[ -e $test_dir/marker ]] || fail "a command line the administrator owns left the migration pending"
grep -Fq 'use += rather than =' "$test_dir/out" ||
  fail "a command line the administrator owns got no advice"
pass "a command line the administrator owns is reported, and does not stop the queue"

# The repair itself needs sudo; a denied prompt must not be recorded as done.
reset
write_drifted
before=$(cat "$conf")
if run 'root=PARTUUID=1 rw quiet loglevel=0' SUDO_DENY=1; then
  fail "a denied sudo prompt was reported as a successful migration"
fi
[[ $(cat "$conf") == "$before" ]] || fail "a denied sudo prompt changed the file"
pass "a denied sudo prompt leaves the file and the migration pending"
