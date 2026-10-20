#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export PATH="$tmp/bin:$ROOT/bin:$PATH"
export CUSTOM_AGENT_RESULT="$tmp/result"
mkdir -p "$HOME/.config/omarchy/agents" "$tmp/bin"
cat >"$HOME/.config/omarchy/agents/example" <<'SH'
#!/bin/bash
printf '%s\0' "$PWD" "$@" >"$CUSTOM_AGENT_RESULT"
SH
cat >"$tmp/bin/omarchy-launch-tui" <<'SH'
#!/bin/bash
[[ $1 == --app-id=org.omarchy.agent ]]
shift
exec "$@"
SH
chmod +x "$HOME/.config/omarchy/agents/example" "$tmp/bin/omarchy-launch-tui"
# Selection launches the executable and preserves the caller's working directory.
omarchy-default-agent custom:example
[[ $(omarchy-default-agent) == custom:example ]]
mapfile -d '' -t result <"$CUSTOM_AGENT_RESULT"
[[ ${result[0]} == "$PWD" && ${#result[@]} == 1 ]]
# Prompt bytes remain one argument, including newlines, shell syntax and dashes.
prompt=$'--profile other; $(touch should-not-exist)\nsecond line'
omarchy-agent --inline --prompt "$prompt"
mapfile -d '' -t result <"$CUSTOM_AGENT_RESULT"
[[ ${#result[@]} == 2 && ${result[1]} == "$prompt" ]]
# Both terminal and inline paths preserve prompt semantics.
omarchy-agent --prompt "$prompt"
mapfile -d '' -t result <"$CUSTOM_AGENT_RESULT"
[[ ${#result[@]} == 2 && ${result[1]} == "$prompt" ]]
# The existing CLI rejects empty prompts before launching any agent.
if omarchy-agent --inline --prompt "" 2>/dev/null; then
  fail "custom agent rejects an empty --prompt"
fi
# Home launches follow the existing Work-directory rule.
mkdir -p "$HOME/Work"
(cd "$HOME" && omarchy-agent --inline)
mapfile -d '' -t result <"$CUSTOM_AGENT_RESULT"
[[ ${result[0]} == "$HOME/Work" ]]
for invalid in custom:missing custom:../example custom:; do
  if omarchy-default-agent "$invalid" 2>/dev/null; then
    fail "custom agent rejects invalid launcher: $invalid"
  fi
  [[ $(omarchy-default-agent) == custom:example ]]
done
chmod -x "$HOME/.config/omarchy/agents/example"
if omarchy-default-agent custom:example 2>/dev/null || omarchy-agent --inline 2>/dev/null; then
  fail "custom agent rejects non-executable launcher"
fi
pass "custom agent selection, launch, prompt preservation and failure checks"
