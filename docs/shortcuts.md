# Named shortcuts

Apps change global shortcuts through `omarchy shortcut` instead of writing Hyprland config. A shortcut has a dotted id, one or more key chords, a description, and the command it runs. Omarchy declares its own (dictation today) with default keys; apps register theirs under their own reverse-DNS ids.

```bash
omarchy shortcut get omarchy.dictation.hold          # F9 and ALT + Alt_R, one per line
omarchy shortcut set omarchy.dictation.hold F9 "SUPER + R"
omarchy shortcut reset omarchy.dictation.hold        # back to Omarchy's default keys

omarchy shortcut set com.superwhisper.shortcut.hold Super_R \
  --description "Push to talk" --command "superwhisper start" --release "superwhisper stop"
omarchy shortcut list --json
```

Apps that call these often can run the commands directly (`omarchy-shortcut-set` and so on) to skip the router.

## Commands

- `get <id> [--json]` prints the keys bound now, one chord per line, and fails for an unknown id. `--json` adds the description, commands, `default_keys` for Omarchy's own shortcuts, and `bound` (the keys Hyprland actually bound).
- `set <id> <keys>... [--description <text>] [--command <command>] [--release <command>] [--force] [--json]` replaces the keys and applies them at once. A new app shortcut needs `--command`; later calls may pass only keys. `--release` makes it a hold: the command runs on press, the release command on release, the way push-to-talk needs. `set <id> --none` keeps the shortcut but unbinds it.
- `reset <id>` drops the choice: an Omarchy shortcut returns to its default keys, and an app's shortcut is removed. Call it from an app's uninstaller.
- `list [--json]` shows every shortcut.

Keys use the same syntax as `o.bind`: `SUPER + SHIFT + R`, `F9`, `SUPER + code:191`, `SUPER + mouse:275`. A modifier on its own (`Super_R`, `Alt_R`, `Control_R`) is matched with the modifier mask ignored, since that mask changes between its press and release.

Ids starting with `omarchy.` are Omarchy's. Their keys can change, but their description and command cannot.

## Conflicts

`set` refuses keys already in use and exits 2. That covers live Hyprland bindings (Omarchy defaults, the user's own, other apps') and other named shortcuts. Each conflict is printed as `<keys> is already used by "<description>" (<id>)`, or with `--json` as `{"conflicts": [{"keys", "description", "id"}]}`, so a shortcut recorder can show who holds the keys and offer to take them.

Keys used inside a submap, such as `RETURN` in the screenshot picker, are refused even with `--force`: Hyprland unbinds a key in every submap at once, so taking it would break that submap.

`--force` takes the keys. A named shortcut that held them keeps the rest of its keys. An Omarchy default binding stays unbound while the shortcut holds its keys, and it comes back when the shortcut moves off them. A personal binding from `~/.config/hypr/bindings.lua` is only unbound until the next config load, because that file loads after shortcuts and binds it again, so both would run.

`set` needs Hyprland running: only the running config knows Omarchy's default keys and every other binding, so keys chosen without it could neither be checked nor be sure to bind. Without Hyprland, `get` and `list` show the keys someone chose, and `get` fails for an Omarchy shortcut still on its defaults.

## How it works

- `~/.config/omarchy/shortcuts/<id>` holds each changed shortcut as `field=value` lines (`keys` repeated, `description`, `command`, `release`). It is data, never loaded as Lua, because other programs write it. Values are single lines.
- `default/hypr/shortcuts.lua` defines `o.shortcut(id, spec)`, which Omarchy's bindings use to declare defaults, and `o.shortcuts.apply()`, which `default/hypr/omarchy.lua` calls after the defaults and before the dictation backend's own integration, so a backend can still unbind or replace Omarchy's dictation keys. It lays the registry over the declarations and binds each shortcut, first unbinding its keys so it takes them from any default. Personal bindings in `~/.config/hypr/bindings.lua` load after it, so a shortcut can't unbind them at login. `set` reports them as conflicts instead.
- `set` and `reset` apply live with `hyprctl eval 'o.shortcuts.apply({"<id>", ...})'`, naming the shortcuts they changed. Only those are unbound and bound again, so every other shortcut, and anything the user or a backend unbound since the config loaded, is left alone. If the shortcut moves off keys it took from a default, `apply` runs `hyprctl reload` instead, because only the config knows what that default was. An older config without `o.shortcuts` also gets a reload.
- `get` and `list` ask the running compositor with `hyprctl eval "o.shortcuts.snapshot(<path>)"` for what is bound, so they never read stale state.
