echo "Put splash back so the Plymouth LUKS prompt stays graphical"

# omarchy-settings ships omarchy-defaults.conf as a backed-up file, so pacman
# keeps the copy a user changed and writes no .pacnew while the packaged
# content stays the same. A copy whose KERNEL_CMDLINE[default]+= line lost
# `splash` still carries every parameter the other guards look for, so they all
# no-op and nothing reports the drift. Plymouth then skips every graphical
# renderer and serves the LUKS passphrase from the text `details` plugin: no
# logo, a plain console prompt, and no warning. Put the token back on Omarchy's
# own line, and rebuild the boot image once per machine.

defaults_conf="${OMARCHY_LIMINE_DEFAULTS_CONF:-/etc/limine-entry-tool.d/omarchy-defaults.conf}"
running_cmdline="${OMARCHY_RUNNING_CMDLINE:-/proc/cmdline}"
limine_conf="${OMARCHY_LIMINE_CONF:-}"
modules_dir="${OMARCHY_KERNEL_MODULES_DIR:-/usr/lib/modules}"
limine_functions="${OMARCHY_LIMINE_FUNCTIONS:-/usr/lib/limine/limine-common-functions}"
rebuild_marker="${OMARCHY_LIMINE_REBUILD_MARKER:-/var/lib/omarchy/migrations/1792673722}"

omarchy-cmd-present limine-mkinitcpio || exit 0
[[ -f $defaults_conf && -r $defaults_conf ]] || exit 0

# Omarchy's own quiet line, recognised by the tokens it ships beside splash. A
# command line someone wrote themselves is not ours to add splash to, and the
# other KERNEL_CMDLINE[default] lines this file carries are left as they are.
# The `|| [[ -n $line ]]` keeps a last line that has no newline.
file_has_splash=false
repaired=false
lines=()
while IFS= read -r line || [[ -n $line ]]; do
  words=${line//\"/}
  if [[ $line == 'KERNEL_CMDLINE[default]+="'*'"' ]]; then
    if [[ " $words " == *" splash "* ]]; then
      file_has_splash=true
    elif [[ " $words " == *" quiet "* && " $words " == *" loglevel=0 "* &&
      " $words " == *" vt.global_cursor_default=0 "* ]]; then
      line=${line/ quiet / quiet splash }
      repaired=true
      file_has_splash=true
    fi
  elif [[ $line == 'KERNEL_CMDLINE[default]'* ]]; then
    [[ " $words " != *" splash "* ]] || file_has_splash=true
  fi
  lines+=("$line")
done <"$defaults_conf"

# Stage the rewrite beside the file and rename it over, so an interrupted write
# cannot leave a partial drop-in in place: it carries the whole boot command
# line, and a backup= file has no .pacnew to surface the damage.
if [[ $repaired == true ]]; then
  printf '%s\n' "${lines[@]}" | sudo tee "$defaults_conf.new" >/dev/null
  sudo chmod 644 "$defaults_conf.new"
  sudo mv -f -- "$defaults_conf.new" "$defaults_conf"
  echo "Restored splash in $defaults_conf"
fi

# A command line that never carried splash is the user's own; nothing to
# rebuild. One that already boots with it needs no rebuild either.
[[ $file_has_splash == true ]] || exit 0
[[ -r $running_cmdline ]] || exit 0
[[ " $(<"$running_cmdline") " != *" splash "* ]] || exit 0

# The running kernel keeps its command line until reboot, so a marker records
# the machine-wide rebuild: another user's migration must not repeat it before
# then, while a missing marker still retries an interrupted rebuild.
[[ ! -e $rebuild_marker ]] || exit 0

echo "The booted kernel is missing splash; rebuilding the boot image"
sudo limine-mkinitcpio

# The boot menu is on the ESP, which /etc/default/limine names; /boot when it
# does not, or is not there.
limine_menu=$limine_conf
if [[ -z $limine_menu ]]; then
  esp=""
  if [[ -r /etc/default/limine ]]; then
    esp=$(sed -n 's/^ESP_PATH=["'\'']\?\([^"'\'']*\).*/\1/p' /etc/default/limine | tail -n 1)
  fi
  limine_menu="${esp:-/boot}/limine.conf"
fi

# limine-mkinitcpio carries on past a kernel it could not build, a full boot
# partition for one, and still exits 0, so a menu that carries command lines
# has to name splash afterwards. The menu also holds other distributions'
# entries, which never carry Omarchy's splash, so ask limine-entry-tool for the
# command line of each entry the rebuild builds instead. One of them configured
# with splash and none of them in the menu means the rebuild itself went wrong
# and the migration stays pending. A menu with no command lines at all has them
# inside the boot images, and is taken at its word.
menu_cmdlines=$(sudo grep -E '^[[:space:]]*cmdline:' "$limine_menu" 2>/dev/null) || menu_cmdlines=""
built=false
while IFS= read -r menu_cmdline; do
  [[ " ${menu_cmdline//\"/} " != *" splash "* ]] || built=true
done <<<"$menu_cmdlines"

if [[ -n $menu_cmdlines ]] && [[ $built == false ]]; then
  # shellcheck disable=SC2016
  fallback=$(sudo bash -c 'source "$1" && load_config >/dev/null && printf "%s\n" "${MKINITCPIO_FALLBACK:-}"' _ "$limine_functions")
  configured=false
  shopt -s nullglob
  for kernel_dir in "$modules_dir"/*/; do
    [[ -f ${kernel_dir}modules.builtin ]] || continue
    kernel_name=$(pacman -Qqo "${kernel_dir}modules.builtin" 2>/dev/null) || continue
    entries=("$kernel_name")
    [[ $fallback != "yes" && $fallback != "$kernel_name" ]] || entries+=("$kernel_name-fallback")
    for entry in "${entries[@]}"; do
      kernel_cmdline=$(sudo limine-entry-tool --get-cmdline "$entry" | tail -n 1)
      [[ " ${kernel_cmdline//\"/} " != *" splash "* ]] || configured=true
    done
  done
  shopt -u nullglob

  if [[ $configured == true ]]; then
    echo "The boot menu still has no entry with splash after the rebuild" >&2
    exit 1
  fi

  echo "The Limine kernel command line leaves out splash; use += rather than = in /etc/default/limine to keep Omarchy's defaults"
fi

sudo install -Dm644 /dev/null "$rebuild_marker"
