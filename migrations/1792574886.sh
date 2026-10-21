echo "Keep the ThinkPad T14 Gen 2i panel from blanking itself"

# The install-time leaf only reaches machines set up after it shipped, and a
# kernel parameter in a Limine drop-in only reaches the boot entries on a
# rebuild. The marker stops another user's run from repeating the machine-wide
# rebuild, while a missing marker retries an interrupted one.
limine_config_dir=${OMARCHY_LIMINE_CONFIG_DIR:-/etc/limine-entry-tool.d}
rebuild_marker=${OMARCHY_THINKPAD_T14_DISPLAY_POWER_MARKER:-/var/lib/omarchy/migrations/1792574886}

omarchy-hw-match "ThinkPad T14 Gen 2i" || exit 0
omarchy-cmd-present limine-mkinitcpio || exit 0
[[ ! -e $rebuild_marker ]] || exit 0

if [[ ! -f $limine_config_dir/thinkpad-t14-display-power.conf ]]; then
  # sudo resets the environment, so the directory the leaf writes to is passed
  # in rather than inherited: the leaf and the check below must name the same
  # one, or the migration would verify a file the leaf never wrote.
  sudo bash -c 'OMARCHY_LIMINE_CONFIG_DIR="$1" bash "$2"' bash \
    "$limine_config_dir" \
    "$OMARCHY_PATH/install/hardware/lenovo/fix-thinkpad-t14-display-power.sh"
fi

if ! grep -Fq 'i915.enable_dc=0' "$limine_config_dir/thinkpad-t14-display-power.conf"; then
  echo "Couldn't apply the ThinkPad T14 Gen 2i display setting; leaving the boot migration pending" >&2
  exit 1
fi

sudo limine-mkinitcpio
sudo install -Dm644 /dev/null "$rebuild_marker"

omarchy-state set reboot-required
