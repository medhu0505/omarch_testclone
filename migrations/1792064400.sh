echo "Install workspace default apps hook for existing users"

source_hook="/etc/skel/.config/omarchy/hooks/post-boot.d/workspace-apps"
target_hook="$HOME/.config/omarchy/hooks/post-boot.d/workspace-apps"

# The package provides this hook for new users.
[[ -f "$source_hook" ]] || exit 0

# Preserve an existing user hook rather than overwriting it.
[[ -e "$target_hook" ]] && exit 0

# Install the hook for this existing user.
omarchy hook install post-boot "$source_hook"
