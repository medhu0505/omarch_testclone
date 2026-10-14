echo "Install the MiniMax Code agent stub"

if omarchy-cmd-missing mcode && [[ ! -f $HOME/.local/state/omarchy/preinstalls-removed ]]; then
  omarchy-mise-install "npm:@minimax-ai/code[allow_builds=better-sqlite3]" mcode
fi
