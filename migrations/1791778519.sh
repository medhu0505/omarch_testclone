echo "Install the Monitor Position application launcher"

application_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
launcher="$application_dir/omarchy-monitor-position.desktop"
mkdir -p "$application_dir"

if [[ ! -e $launcher && ! -L $launcher ]]; then
  cp "$OMARCHY_PATH/applications/omarchy-monitor-position.desktop" "$launcher"
fi

# Refresh on reruns too, in case the first database update failed after copying.
update-desktop-database "$application_dir"
