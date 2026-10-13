#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

registry="$ROOT/shell/services/PluginRegistry.qml"
source_text=$(cat "$registry")

# Source wiring: shell start reaps orphaned watchers before starting its
# own, spares one still parented to a live shell, and a graceful stop
# takes its watcher with it.
[[ $source_text == *"function reapOrphanedPluginWatchers()"* ]] ||
  fail "plugin registry reaps orphaned watchers at startup"
[[ $source_text == *"ps -o comm="* && $source_text == *"quickshell|qs"* ]] ||
  fail "watcher reaper spares watchers still parented to a live shell"
[[ $source_text == *"Component.onDestruction"* && $source_text == *"localPluginWatcher.running = false"* ]] ||
  fail "plugin watcher stops with its shell"
[[ $source_text == *"registry.reapOrphanedPluginWatchers()"* ]] ||
  fail "shell init runs the watcher reaper before starting the watcher"
pass "plugin watcher lifecycle is wired to the shell"

command -v inotifywait >/dev/null 2>&1 || { skip "inotifywait not installed; skipping watcher reap check"; exit 0; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/plugins"

# An orphaned watcher: detached, so its parent is gone before the reap.
setsid -f inotifywait -m -r -q -e close_write,create,delete,move --format '%w%f' "$TMPDIR/plugins" </dev/null >/dev/null 2>&1
orphan=""
for _ in {1..30}; do
  orphan=$(pgrep -f "inotifywait -m -r -q -e close_write,create,delete,move --format %w%f $TMPDIR/plugins" | head -1 || true)
  [[ -n $orphan ]] && break
  sleep 0.1
done
[[ -n $orphan ]] || fail "could not start an orphaned plugin watcher"
pass "orphaned plugin watcher started"

# Same flags, unrelated directory: not the shell's watcher to reap.
mkdir -p "$TMPDIR/other"
setsid -f inotifywait -m -r -q -e close_write,create,delete,move --format '%w%f' "$TMPDIR/other" </dev/null >/dev/null 2>&1
unrelated=""
for _ in {1..30}; do
  unrelated=$(pgrep -f "inotifywait -m -r -q -e close_write,create,delete,move --format %w%f $TMPDIR/other" | head -1 || true)
  [[ -n $unrelated ]] && break
  sleep 0.1
done
[[ -n $unrelated ]] || fail "could not start an unrelated watcher"

# The reap itself, exactly as PluginRegistry runs it at shell start
# ($1 is the plugins directory there; the scratch one here).
for p in $(pgrep -f '[i]notifywait -m -r -q -e close_write,create,delete,move' || true); do
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$TMPDIR/plugins" || continue
  parent=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [[ $parent =~ ^[0-9]+$ ]] || continue
  case "$(ps -o comm= -p "$parent" 2>/dev/null)" in quickshell|qs) ;; *) kill "$p" 2>/dev/null || true ;; esac
done

for _ in {1..30}; do
  kill -0 "$orphan" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$orphan" 2>/dev/null; then
  fail "watcher reaper stops an orphaned plugin watcher"
fi
pass "watcher reaper stops an orphaned plugin watcher"

kill -0 "$unrelated" 2>/dev/null || fail "watcher reaper leaves unrelated watchers alone"
kill "$unrelated" 2>/dev/null || true
pass "watcher reaper leaves unrelated watchers alone"

# A watcher still parented to a live shell survives the reap.
live=""
while IFS= read -r p; do
  parent=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [[ $parent =~ ^[0-9]+$ ]] || continue
  case "$(ps -o comm= -p "$parent" 2>/dev/null)" in quickshell|qs) live=$p; break ;; esac
done < <(pgrep -f 'inotifywait -m -r -q -e close_write,create,delete,move' || true)
if [[ -n $live ]]; then
  kill -0 "$live" 2>/dev/null || fail "watcher reaper spares a live shell's watcher"
  pass "watcher reaper spares a live shell's watcher"
else
  echo "ok - watcher reaper spares a live shell's watcher # SKIP no live shell watcher"
fi
