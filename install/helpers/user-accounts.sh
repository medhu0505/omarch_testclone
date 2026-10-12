# Shared helpers for the omarchy-user-* commands.
#
# A login account is one in the UID_MIN..UID_MAX range with a login shell.
# Administrators are the members of wheel: the group Omarchy's sudoers and
# polkit (unix-group:wheel) trust, and the only privilege switch these commands
# use.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/as-root.sh"

# The person running the command, also when it runs under sudo.
user_accounts_self() {
  printf '%s\n' "${SUDO_USER:-$(id -un)}"
}

user_accounts_login_def() {
  local value
  value=$(awk -v key="$1" '$1 == key { print $2; exit }' "${OMARCHY_LOGIN_DEFS:-/etc/login.defs}" 2>/dev/null || true)
  if [[ $value =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$2"
  fi
}

# Prints "name<TAB>uid<TAB>gid" for every login account.
user_accounts_login_users() {
  local uid_min uid_max
  uid_min=$(user_accounts_login_def UID_MIN 1000)
  uid_max=$(user_accounts_login_def UID_MAX 60000)

  getent passwd | while IFS=: read -r name _ uid gid _ _ shell; do
    (( uid >= uid_min && uid <= uid_max )) || continue
    [[ $shell == */nologin || $shell == */false ]] && continue
    printf '%s\t%s\t%s\n' "$name" "$uid" "$gid"
  done
}

user_accounts_is_login_user() {
  user_accounts_login_users | awk -F '\t' -v user="$1" '$1 == user { found = 1 } END { exit !found }'
}

user_accounts_is_admin() {
  local wheel gid
  wheel=$(getent group wheel || true)
  [[ ",$(cut -d: -f4 <<<"$wheel")," == *",$1,"* ]] && return 0
  gid=$(getent passwd "$1" | cut -d: -f4)
  [[ -n $gid && $gid == "$(cut -d: -f3 <<<"$wheel")" ]]
}

# Prints the login accounts that are administrators, one per line.
user_accounts_admins() {
  local name
  user_accounts_login_users | while IFS=$'\t' read -r name _ _; do
    if user_accounts_is_admin "$name"; then
      printf '%s\n' "$name"
    fi
  done
}

user_accounts_has_programs() {
  pgrep -u "$1" >/dev/null
}

user_accounts_programs_end() {
  local _
  for _ in {1..10}; do
    user_accounts_has_programs "$1" || return 0
    sleep 0.5
  done
  return 1
}

# Ends the user's login sessions, then any programs that outlive them, such as
# ones started with su or cron. Fails if something is still running.
user_accounts_sign_out() {
  as_root loginctl terminate-user "$1" 2>/dev/null || true
  if ! user_accounts_programs_end "$1"; then
    as_root pkill -KILL -u "$1" || true
    user_accounts_programs_end "$1"
  fi
}

# Lowercase letter or underscore first, then lowercase letters, digits, _ or -,
# at most 32 characters. No dots: sudo ignores sudoers.d files whose names
# contain one, and no trailing $ (machine accounts).
user_accounts_valid_name() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# One plain-language line per change, so `journalctl -t omarchy-user` reads as
# a history of who did what.
user_accounts_log() {
  logger -t omarchy-user -- "$*" 2>/dev/null || true
}

user_accounts_sudoers_dir() {
  printf '%s\n' "${OMARCHY_SUDOERS_DIR:-/etc/sudoers.d}"
}

# Omarchy's first-boot provisioning gives wheel sudo with this drop-in, but an
# install from the ISO grants it to the owner by name instead (archinstall's
# NN_<owner>), so a second administrator would get none. Adding one writes the
# same drop-in; like provisioning, it doesn't look for an equivalent grant,
# since a duplicate is harmless.
user_accounts_ensure_wheel_sudo() {
  local rule staged
  rule="$(user_accounts_sudoers_dir)/00-omarchy-wheel"

  if as_root test -e "$rule"; then
    return 0
  fi

  # sudo skips files whose names contain a dot, so the staged copy stays inert.
  staged="$rule.new"
  if printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' | as_root tee "$staged" >/dev/null &&
    as_root chmod 0440 "$staged" && as_root visudo -cqf "$staged"; then
    as_root mv -f "$staged" "$rule"
    user_accounts_log "administrators in wheel now get sudo from $rule"
  else
    as_root rm -f "$staged"
    return 1
  fi
}

# Prints the files the installer wrote to grant this user sudo by name: NN_<name>
# holding nothing but "<name> ALL=(ALL) ALL". Anything else is left alone.
user_accounts_installer_grants() {
  local file
  while IFS= read -r file; do
    if [[ $(as_root cat "$file" | grep -v '^[[:space:]]*$') == "$1 ALL=(ALL) ALL" ]]; then
      printf '%s\n' "$file"
    fi
  done < <(as_root find "$(user_accounts_sudoers_dir)" -maxdepth 1 -type f -name "[0-9][0-9]_$1")
}

user_accounts_drop_installer_grants() {
  local file
  user_accounts_installer_grants "$1" | while IFS= read -r file; do
    as_root rm -f "$file"
    user_accounts_log "removed the installer's sudo grant for '$1' ($file)"
  done
}

# True when sudo lets the user run any command as root.
user_accounts_has_full_sudo() {
  local privileges
  privileges=$(as_root sudo -l -U "$1" 2>/dev/null) || return 1
  grep -qE '^[[:space:]]+\((ALL|root)( : ALL)?\) (NOPASSWD: )?ALL$' <<<"$privileges"
}
