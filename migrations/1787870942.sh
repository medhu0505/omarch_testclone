echo "Let a personal Super + Shift + S binding win now that it is a default"

# Super + Shift + S is now bound to a screenshot by default. Hyprland stacks
# duplicate binds rather than replacing them, so any chord the user has already
# bound themselves would fire alongside the new default: two screenshot pickers
# racing each other, or their own command running with a screenshot on top.
#
# The fix is the one this repo documents everywhere else -- unbind the chord
# before rebinding it. Inserting that line above the user's own bind leaves
# their binding exactly as they wrote it and simply makes it the only one that
# runs. It is deliberately not conditional on which command they bound: a chord
# rebound to something else stacks just as badly as a duplicate screenshot, and
# a user with `omarchy_default_bindings = false` keeps the only screenshot
# shortcut they have either way. Any bind form stacks the same, so o.bind,
# o.bind_toggle, and bare hl.bind all count.
#
# This file is executed by omarchy-migrate (`bash -euo pipefail`), not sourced,
# so the guards are one conditional rather than top-level returns.
bindings_file="$HOME/.config/hypr/bindings.lua"
chord='SUPER + SHIFT + S'
active_bind='^[[:space:]]*(o\.bind|o\.bind_toggle|hl\.bind)\("SUPER \+ SHIFT \+ S"'

# Act only on an active bind of the chord (commented-out template lines don't
# count), and not when it is already unbound before being rebound -- a second
# unbind would be noise in a file the user reads.
#
# --follow-symlinks matters: dotfile-managed configs are usually symlinks into
# a repo, and without it sed replaces the link with a regular file and silently
# detaches the config from the source the user actually edits.
if [[ -f $bindings_file ]] &&
  grep -Eq "$active_bind" "$bindings_file" &&
  ! grep -Eq '^[[:space:]]*hl\.unbind\("SUPER \+ SHIFT \+ S"\)' "$bindings_file"; then
  sed -i --follow-symlinks -E \
    '0,/^[[:space:]]*(o\.bind|o\.bind_toggle|hl\.bind)\("SUPER \+ SHIFT \+ S"/s||-- Super + Shift + S takes a screenshot by default now; this unbind keeps yours the only one that runs.\nhl.unbind("'"$chord"'")\n&|' \
    "$bindings_file"
fi
