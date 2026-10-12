#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d) || fail "a temporary directory can be created"
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

# The account tools edit fixture passwd and group files, so each command sees
# what the one before it changed. Every call is recorded in calls.log.
cat >"$mock_bin/getent" <<'SH'
#!/bin/bash
file="$OMARCHY_TEST_DIR/$1"
if [[ -n ${2:-} ]]; then
  grep "^$2:" "$file"
else
  cat "$file"
fi
SH

# sudo -l -U reports full sudo for a wheel member once the wheel drop-in exists,
# and for anyone a file in sudoers.d names. Anything else runs as given.
cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$OMARCHY_TEST_DIR/calls.log"
if [[ $1 == "-l" && $2 == "-U" ]]; then
  echo "User $3 may run the following commands on test:"
  if { [[ -e $OMARCHY_SUDOERS_DIR/00-omarchy-wheel ]] && grep -qE "^wheel:.*[:,]$3(,|$)" "$OMARCHY_TEST_DIR/group"; } ||
    grep -qs "^$3 ALL=(ALL) .*ALL$" "$OMARCHY_SUDOERS_DIR"/*; then
    echo "    (ALL) ALL"
  fi
  echo "    (root) NOPASSWD: /usr/bin/omarchy-dns Cloudflare"
  exit 0
fi
exec "$@"
SH

cat >"$mock_bin/visudo" <<'SH'
#!/bin/bash
echo "visudo $*" >>"$OMARCHY_TEST_DIR/calls.log"
[[ -z ${OMARCHY_TEST_VISUDO_FAIL:-} && $(cat "${!#}") == "%wheel ALL=(ALL:ALL) ALL" ]]
SH

cat >"$mock_bin/useradd" <<'SH'
#!/bin/bash
echo "useradd $*" >>"$OMARCHY_TEST_DIR/calls.log"
groups="" shell=""
while (( $# > 1 )); do
  case "$1" in
  -m) ;;
  -s) shell="$2"; shift ;;
  -G) groups="$2"; shift ;;
  esac
  shift
done
name="$1"
uid=$(awk -F: '$3 >= 1000 && $3 < 60000 && $3 > max { max = $3 } END { print max + 1 }' "$OMARCHY_TEST_DIR/passwd")
mkdir -p "$OMARCHY_TEST_DIR/home/$name"
echo "$name:x:$uid:$uid::$OMARCHY_TEST_DIR/home/$name:$shell" >>"$OMARCHY_TEST_DIR/passwd"
echo "$name:x:$uid:" >>"$OMARCHY_TEST_DIR/group"
if [[ $groups == "wheel" ]]; then
  sed -i -E "/^wheel:/ { s/:$/:$name/; t; s/$/,$name/ }" "$OMARCHY_TEST_DIR/group"
fi
SH

cat >"$mock_bin/chpasswd" <<'SH'
#!/bin/bash
echo "chpasswd $*" >>"$OMARCHY_TEST_DIR/calls.log"
cat >>"$OMARCHY_TEST_DIR/shadow"
[[ -z ${OMARCHY_TEST_CHPASSWD_FAIL:-} ]]
SH

cat >"$mock_bin/userdel" <<'SH'
#!/bin/bash
echo "userdel $*" >>"$OMARCHY_TEST_DIR/calls.log"
name="${!#}"
sed -i "/^$name:/d" "$OMARCHY_TEST_DIR/passwd" "$OMARCHY_TEST_DIR/group"
sed -i -E "/^wheel:/ { s/([:,])$name(,|$)/\1/; s/,$// }" "$OMARCHY_TEST_DIR/group"
if [[ $1 == "-r" ]]; then
  rm -rf "${OMARCHY_TEST_DIR:?}/home/${name:?}"
  echo "userdel: $name mail spool (/var/spool/mail/$name) not found" >&2
fi
SH

cat >"$mock_bin/gpasswd" <<'SH'
#!/bin/bash
echo "gpasswd $*" >>"$OMARCHY_TEST_DIR/calls.log"
name="$2"
case "$1" in
-a) sed -i -E "/^wheel:/ { s/:$/:$name/; t; s/$/,$name/ }" "$OMARCHY_TEST_DIR/group" ;;
-d) sed -i -E "/^wheel:/ { s/([:,])$name(,|$)/\1/; s/,$// }" "$OMARCHY_TEST_DIR/group" ;;
esac
echo "Adding/removing user $name"
SH

# Users with programs running are listed in procs; signing out clears them.
cat >"$mock_bin/pgrep" <<'SH'
#!/bin/bash
grep -qxF "$2" "$OMARCHY_TEST_DIR/procs"
SH

# A user in outside_session also has programs that signing out doesn't end.
cat >"$mock_bin/loginctl" <<'SH'
#!/bin/bash
echo "loginctl $*" >>"$OMARCHY_TEST_DIR/calls.log"
if [[ $1 == "terminate-user" ]] && ! grep -qxF "$2" "$OMARCHY_TEST_DIR/outside_session"; then
  sed -i "/^$2$/d" "$OMARCHY_TEST_DIR/procs"
fi
SH

cat >"$mock_bin/pkill" <<'SH'
#!/bin/bash
echo "pkill $*" >>"$OMARCHY_TEST_DIR/calls.log"
sed -i "/^$3$/d" "$OMARCHY_TEST_DIR/procs"
SH

cat >"$mock_bin/chmod" <<'SH'
#!/bin/bash
echo "chmod $*" >>"$OMARCHY_TEST_DIR/calls.log"
SH

cat >"$mock_bin/logger" <<'SH'
#!/bin/bash
[[ $1 == "-t" && $2 == "omarchy-user" && $3 == "--" ]] || exit 1
echo "$4" >>"$OMARCHY_TEST_DIR/journal"
SH

chmod +x "$mock_bin"/*

reset_fixtures() {
  rm -rf "${test_tmp:?}/home" "$test_tmp/sudoers.d" "$test_tmp/calls.log" "$test_tmp/journal" "$test_tmp/shadow"
  mkdir -p "$test_tmp/home/alice" "$test_tmp/home/bob" "$test_tmp/sudoers.d"
  # The owner, alice, was installed from the ISO: sudo by name, no wheel rule.
  echo "alice ALL=(ALL) ALL" >"$test_tmp/sudoers.d/04_alice"
  : >"$test_tmp/calls.log"
  : >"$test_tmp/journal"
  : >"$test_tmp/procs"
  : >"$test_tmp/outside_session"

  cat >"$test_tmp/passwd" <<EOF
root:x:0:0::/root:/usr/bin/bash
alpm:x:970:970:Arch Linux Package Management:/:/usr/bin/nologin
alice:x:1000:1000::$test_tmp/home/alice:/bin/bash
bob:x:1001:1001::$test_tmp/home/bob:/bin/bash
svc:x:1002:1002::/home/svc:/usr/bin/nologin
EOF

  cat >"$test_tmp/group" <<'EOF'
root:x:0:root
wheel:x:998:alice
alice:x:1000:
bob:x:1001:
svc:x:1002:
staff:x:1500:
EOF
}

# Runs an omarchy-user command as alice, an administrator. Callers capture or
# discard stdout, so the commands never see a terminal and never prompt.
run_user() {
  local command="$1"
  shift
  PATH="$mock_bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_TEST_DIR="$test_tmp" \
    SUDO_USER=${RUN_AS:-alice} OMARCHY_LOGIN_DEFS=/dev/null OMARCHY_SUDOERS_DIR="$test_tmp/sudoers.d" \
    "$ROOT/bin/omarchy-user-$command" "$@"
}

wheel_members() {
  grep '^wheel:' "$test_tmp/group" | cut -d: -f4
}

has_user() {
  grep -q "^$1:" "$test_tmp/passwd"
}

# --- omarchy user add ---

reset_fixtures
output=$(printf 's3cret pass:word\n' | run_user add carol --password-stdin 2>&1) ||
  fail "add creates a user with a password from stdin" "$output"
grep -q '^carol:x:1003:1003::.*/home/carol:/bin/bash$' "$test_tmp/passwd" ||
  fail "add creates a user with a password from stdin" "$(cat "$test_tmp/passwd")"
[[ $(cat "$test_tmp/shadow") == "carol:s3cret pass:word" ]] ||
  fail "add creates a user with a password from stdin" "$(cat "$test_tmp/shadow")"
[[ $(wheel_members) == "alice" ]] || fail "a new user isn't an administrator by default" "$(wheel_members)"
[[ $output == *"Added carol (administrator: no)"* ]] || fail "add reports what it did" "$output"
pass "add creates a user with a password from stdin"

grep -qF "s3cret" "$test_tmp/calls.log" && fail "the password never appears on a command line" "$(cat "$test_tmp/calls.log")"
pass "the password never appears on a command line"

[[ $(cat "$test_tmp/journal") == "login user 'carol' added by alice (administrator: no)" ]] ||
  fail "add writes one plain journal line naming who did it" "$(cat "$test_tmp/journal")"
pass "add writes one plain journal line naming who did it"

reset_fixtures
printf 'pw\n' | run_user add dave --admin --password-stdin >/dev/null ||
  fail "add --admin puts the user in wheel"
[[ $(wheel_members) == "alice,dave" ]] || fail "add --admin puts the user in wheel" "$(wheel_members)"
[[ $(cat "$test_tmp/sudoers.d/00-omarchy-wheel") == "%wheel ALL=(ALL:ALL) ALL" ]] ||
  fail "add --admin gives wheel sudo on an install that granted it only by name"
pass "add --admin puts the user in wheel and gives wheel sudo"

reset_fixtures
if printf 'pw\n' | OMARCHY_TEST_VISUDO_FAIL=1 run_user add dave --admin --password-stdin >/dev/null 2>&1; then
  fail "add --admin stops when the sudo rule doesn't validate"
fi
has_user dave && fail "add --admin stops when the sudo rule doesn't validate"
[[ -z $(ls "$test_tmp/sudoers.d" | grep -v 04_alice) ]] ||
  fail "a rule that doesn't validate leaves nothing in sudoers.d" "$(ls "$test_tmp/sudoers.d")"
pass "add --admin stops when the sudo rule doesn't validate, and leaves nothing behind"

reset_fixtures
printf 'pw\n' | run_user add carol --password-stdin >/dev/null || fail "add without --admin leaves sudoers alone"
[[ $(ls "$test_tmp/sudoers.d") == "04_alice" ]] || fail "add without --admin leaves sudoers alone" "$(ls "$test_tmp/sudoers.d")"
pass "add without --admin leaves sudoers alone"

reset_fixtures
for name in Eve 1x a.b 'a b' -x x\$ "$(printf 'a%.0s' {1..33})"; do
  if printf 'pw\n' | run_user add "$name" --password-stdin >/dev/null 2>&1; then
    fail "add rejects the invalid name '$name'"
  fi
done
grep -q useradd "$test_tmp/calls.log" && fail "add rejects invalid names before changing anything"
pass "add rejects invalid names before changing anything"

for name in bob root staff; do
  if printf 'pw\n' | run_user add "$name" --password-stdin >/dev/null 2>&1; then
    fail "add refuses a name already used by a user or group: $name"
  fi
done
grep -q useradd "$test_tmp/calls.log" && fail "add refuses a name already used by a user or group"
pass "add refuses a name already used by a user or group"

if printf '\n' | run_user add carol --password-stdin >/dev/null 2>&1; then
  fail "add refuses an empty password"
fi
has_user carol && fail "add refuses an empty password"
pass "add refuses an empty password"

output=$(run_user add carol 2>&1) && fail "add without a terminal needs --password-stdin"
[[ $output == *"--password-stdin"* ]] || fail "add without a terminal needs --password-stdin" "$output"
run_user add --password-stdin >/dev/null 2>&1 && fail "add without a terminal needs a name"
pass "add without a terminal needs a name and --password-stdin"

reset_fixtures
if printf 'pw\n' | OMARCHY_TEST_CHPASSWD_FAIL=1 run_user add carol --password-stdin >/dev/null 2>&1; then
  fail "add rolls back the user when the password can't be set"
fi
has_user carol && fail "add rolls back the user when the password can't be set" "$(cat "$test_tmp/passwd")"
[[ -s $test_tmp/journal ]] && fail "a rolled-back add writes no journal line"
pass "add rolls back the user when the password can't be set"

# --- omarchy user remove ---

reset_fixtures
run_user remove bob >/dev/null 2>&1 && fail "remove without a terminal needs --yes"
has_user bob || fail "remove without a terminal needs --yes"
pass "remove without a terminal needs --yes"

output=$(run_user remove bob --yes 2>&1) || fail "remove deletes the account and keeps the home folder" "$output"
has_user bob && fail "remove deletes the account and keeps the home folder"
[[ -d $test_tmp/home/bob ]] || fail "remove deletes the account and keeps the home folder"
grep -qx "userdel bob" "$test_tmp/calls.log" || fail "remove deletes the account and keeps the home folder" "$(cat "$test_tmp/calls.log")"
pass "remove deletes the account and keeps the home folder"

[[ $(cat "$test_tmp/journal") == "login user 'bob' removed by alice, home folder $test_tmp/home/bob kept" ]] ||
  fail "remove writes one plain journal line" "$(cat "$test_tmp/journal")"
pass "remove writes one plain journal line"

reset_fixtures
echo bob >"$test_tmp/procs"
output=$(run_user remove bob --delete-home --yes 2>&1) || fail "remove --delete-home signs the user out and deletes the home folder" "$output"
grep -qx "loginctl terminate-user bob" "$test_tmp/calls.log" &&
  grep -qx "userdel -r bob" "$test_tmp/calls.log" &&
  [[ ! -e $test_tmp/home/bob ]] ||
  fail "remove --delete-home signs the user out and deletes the home folder" "$(cat "$test_tmp/calls.log")"
[[ $output != *"mail spool"* ]] || fail "userdel's missing mail spool warning is hidden" "$output"
grep -q pkill "$test_tmp/calls.log" && fail "remove only kills programs that outlast signing out"
pass "remove --delete-home signs the user out and deletes the home folder"

reset_fixtures
echo bob >"$test_tmp/procs"
echo bob >"$test_tmp/outside_session"
output=$(run_user remove bob --yes 2>&1) || fail "remove stops programs that signing out leaves running" "$output"
grep -qx "pkill -KILL -u bob" "$test_tmp/calls.log" && ! has_user bob ||
  fail "remove stops programs that signing out leaves running" "$(cat "$test_tmp/calls.log")"
pass "remove stops programs that signing out leaves running"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
output=$(run_user remove alice --yes 2>&1) && fail "remove refuses your own account"
[[ $output == *"your own account"* ]] || fail "remove refuses your own account" "$output"
for name in root svc nobody; do
  if run_user remove "$name" --yes >/dev/null 2>&1; then
    fail "remove refuses system accounts and unknown users: $name"
  fi
done
grep -q userdel "$test_tmp/calls.log" && fail "remove refuses yourself, system accounts and unknown users"
pass "remove refuses yourself, system accounts and unknown users"

reset_fixtures
output=$(RUN_AS=root run_user remove alice --yes 2>&1) && fail "remove refuses the last administrator"
[[ $output == *"last administrator"* ]] || fail "remove refuses the last administrator" "$output"
has_user alice || fail "remove refuses the last administrator"
pass "remove refuses the last administrator"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
RUN_AS=bob run_user remove alice --yes >/dev/null 2>&1 || fail "remove drops the installer's sudo grant for the name"
[[ ! -e $test_tmp/sudoers.d/04_alice ]] || fail "remove drops the installer's sudo grant for the name"
pass "remove drops the installer's sudo grant for the name"

# --- omarchy user admin ---

reset_fixtures
output=$(run_user admin bob on 2>&1) || fail "admin on adds the user to wheel" "$output"
[[ $(wheel_members) == "alice,bob" ]] || fail "admin on adds the user to wheel" "$(wheel_members)"
[[ -e $test_tmp/sudoers.d/00-omarchy-wheel && ! -e $test_tmp/sudoers.d/00-omarchy-wheel.new ]] ||
  fail "admin on gives wheel sudo" "$(ls "$test_tmp/sudoers.d")"
grep -qx "chmod 0440 $test_tmp/sudoers.d/00-omarchy-wheel.new" "$test_tmp/calls.log" ||
  fail "the wheel rule is made read-only before it goes live" "$(cat "$test_tmp/calls.log")"
[[ $(tail -1 "$test_tmp/journal") == "login user 'bob' made an administrator by alice" ]] ||
  fail "admin on writes one plain journal line" "$(cat "$test_tmp/journal")"
pass "admin on adds the user to wheel and gives wheel sudo"

: >"$test_tmp/calls.log"
output=$(run_user admin bob on 2>&1) || fail "admin on for an administrator changes nothing" "$output"
[[ $output == "bob is already an administrator." ]] || fail "admin on for an administrator changes nothing" "$output"
grep -q gpasswd "$test_tmp/calls.log" && fail "admin on for an administrator changes nothing"
pass "admin on for an administrator changes nothing"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
output=$(run_user admin bob on 2>&1) || fail "admin on gives wheel sudo for a member who had none" "$output"
[[ $output == "bob is already an administrator." && -e $test_tmp/sudoers.d/00-omarchy-wheel ]] ||
  fail "admin on gives wheel sudo for a member who had none" "$output"
pass "admin on gives wheel sudo for a member who had none"

echo bob >"$test_tmp/procs"
output=$(run_user admin bob off 2>&1) || fail "admin off removes the user from wheel" "$output"
[[ $(wheel_members) == "alice" ]] || fail "admin off removes the user from wheel" "$(wheel_members)"
[[ $output == *"keep sudo until bob logs out"* ]] || fail "admin off warns that open sessions keep sudo" "$output"
grep -q terminate-user "$test_tmp/calls.log" && fail "admin off signs nobody out without asking"
pass "admin off removes the user from wheel and warns that open sessions keep sudo"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
run_user admin alice off >/dev/null 2>&1 && fail "admin off refuses your own account"
RUN_AS=bob run_user admin bob off >/dev/null 2>&1 && fail "admin off refuses your own account"
pass "admin off refuses your own account"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
echo "%wheel ALL=(ALL:ALL) ALL" >"$test_tmp/sudoers.d/00-omarchy-wheel"
output=$(RUN_AS=bob run_user admin alice off 2>&1) || fail "admin off also drops the installer's sudo grant" "$output"
[[ $(wheel_members) == "bob" && ! -e $test_tmp/sudoers.d/04_alice ]] ||
  fail "admin off also drops the installer's sudo grant" "$(wheel_members); $(ls "$test_tmp/sudoers.d")"
pass "admin off also drops the installer's sudo grant"

reset_fixtures
sed -i 's/^wheel:x:998:alice$/wheel:x:998:alice,bob/' "$test_tmp/group"
printf '# kept by hand\nalice ALL=(ALL) ALL\n' >"$test_tmp/sudoers.d/04_alice"
output=$(RUN_AS=bob run_user admin alice off 2>&1) && fail "admin off reports a sudo grant it didn't write"
[[ $output == *"another sudo rule"* && -e $test_tmp/sudoers.d/04_alice ]] ||
  fail "admin off reports a sudo grant it didn't write, and leaves it alone" "$output"
pass "admin off reports a sudo grant it didn't write, and leaves it alone"

reset_fixtures
output=$(RUN_AS=root run_user admin alice off 2>&1) && fail "admin off refuses the last administrator"
[[ $output == *"last administrator"* ]] || fail "admin off refuses the last administrator" "$output"
pass "admin off refuses the last administrator"

reset_fixtures
sed -i 's/^bob:x:1001:1001:/bob:x:1001:998:/' "$test_tmp/passwd"
output=$(run_user admin bob off 2>&1) && fail "admin off explains a primary group of wheel"
[[ $output == *"primary group"* ]] || fail "admin off explains a primary group of wheel" "$output"
pass "admin off explains a primary group of wheel"

reset_fixtures
run_user admin svc on >/dev/null 2>&1 && fail "admin refuses system accounts"
run_user admin root on >/dev/null 2>&1 && fail "admin refuses system accounts"
pass "admin refuses system accounts"

run_user admin bob >/dev/null 2>&1 && fail "admin without a terminal needs on or off"
run_user admin on >/dev/null 2>&1 && fail "admin needs a name before on or off"
run_user admin bob maybe >/dev/null 2>&1 && fail "admin rejects anything but on or off"
grep -q gpasswd "$test_tmp/calls.log" && fail "admin changes nothing on bad arguments"
pass "admin rejects incomplete or bad arguments"

# --- running as root ---

# Under sudo or in a root shell the session's OMARCHY_PATH is gone. A user
# namespace stands in for root where the system allows one.
if unshare -r true 2>/dev/null; then
  for command in add remove admin; do
    if output=$(env -u OMARCHY_PATH unshare -r "$ROOT/bin/omarchy-user-$command" bob 2>&1); then
      fail "$command refuses to run as root"
    fi
    [[ $output == *"run this as your user"* ]] || fail "$command explains why it won't run as root" "$output"
  done
  pass "add, remove and admin refuse to run as root, with a clear reason"
else
  skip "add, remove and admin refuse to run as root (no user namespaces here)"
fi
