# Omarchy Shell and Plugins

Use this guide for the bar, widgets, notifications, menus, shell plugins, idle,
and lock behavior. These surfaces run in one long-lived Quickshell process,
`omarchy-shell`.

## State and Defaults

```text
~/.config/omarchy/shell.json                    # User bar, plugin, and idle overrides
~/.config/omarchy/extensions/omarchy-menu.jsonc # User menu and launcher overrides
~/.config/omarchy/plugins/<plugin-id>/          # User-owned shell plugins
$OMARCHY_PATH/config/omarchy/shell.json         # Packaged shell defaults
$OMARCHY_PATH/shell/plugins/                    # Packaged plugin source
```

`shell.json`, menu extensions, and user plugin files hot-reload when saved.
Use `omarchy restart shell` when a live reload does not apply cleanly. With user
confirmation, `omarchy refresh shell` restores packaged shell configuration.

## Shell Configuration Loop

1. Read the user override and matching packaged default.
2. Prefer the relevant `omarchy bar` or `omarchy plugin` command when available.
3. Otherwise edit the narrowest value in `~/.config/omarchy/shell.json`.
4. Validate JSON with `jq empty ~/.config/omarchy/shell.json`.
5. Observe the requested bar, notification, menu, idle, or lock behavior.

The shell change is complete when JSON validation is clean and the affected
surface behaves as requested. If hot reload does not apply, restart the shell
and repeat the observation.

## Plugin UI Safety

Plugins run inside Omarchy's long-lived, unsandboxed shell. Treat text from network responses, files, IPC, settings, environment variables, and command output as untrusted.

- QML `Text` defaults to `Text.AutoText`. Do not bind untrusted data to an AutoText sink: markup-shaped input such as `<img src="https://example.invalid/tracker">` can be interpreted as rich text and load a resource.
- For display text owned by the plugin, set `textFormat: Text.PlainText`. Prefer a local `PlainText` component when the plugin has multiple text elements.

```qml
Text {
  textFormat: Text.PlainText
  text: modelData.name
}
```

- When passing dynamic text to an Omarchy-owned component whose internal `Text` format the plugin cannot set, neutralize markup in the plugin first with a helper of its own, and add a regression test; Omarchy ships no such helper. Never edit the packaged component to add a plain-text option: that belongs in a pull request to Omarchy.
- Bound and validate downloaded data before displaying or saving it: limit response and collection sizes, string lengths, identifiers, and timestamps.
- Keep network access explicit. Use fixed HTTPS sources, timeouts, response-size limits, and validation. For periodic background refreshes, disclose the behavior and let users enable or disable it. Never execute downloaded content or interpolate untrusted values into shell commands.
- Add regression coverage for markup-shaped input and every shared tooltip or notification sink that receives dynamic text.

## Translations

Omarchy runs in 50 languages, and a plugin should follow the one picked under Setup > Language the way the built-in plugins do: live, without a shell restart. Ship the plugin's strings as flat JSON catalogs in an `i18n/` directory beside its QML, one file per Omarchy language code (`en.json`, `da.json`, `pt-BR.json`; `$OMARCHY_PATH/default/i18n/locales.json` lists all 50), and read them through `Commons.Translations`:

```qml
import qs.Commons as Commons

Item {
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Text {
    textFormat: Text.PlainText
    text: strings.tn("panel.items", count).arg(Commons.I18n.formatNumber(count))
  }
}
```

```json
{ "panel.items": { "one": "%1 item", "other": "%1 items" } }
```

- A string missing from the current language falls back to its base language (`pt-BR` to `pt`), then to `en.json`, then to the key, so a plugin can ship English alone and add languages one file at a time.
- Keep each string whole with `%1` placeholders filled by `.arg()`; never glue translated fragments into a sentence, since other languages reorder words.
- A string that counts something is a plural entry, an object keyed by CLDR category, read with `strings.tn(key, count)`. English needs `one` and `other`; each translation supplies the categories its language uses (Russian `one`, `few`, `many`, `other`; Arabic six; Japanese only `other`; the rules are in `$OMARCHY_PATH/shell/Commons/Plural.js`).
- Write displayed numbers with `Commons.I18n.formatNumber(value, decimals)` so they take the language's decimal separator and digits (`13,1` in Danish).
- Arabic, Hebrew, Persian, and Urdu mirror the layout. A plugin built on `KeyboardPanel` or `PopupCard` is mirrored for free; anything it positions by explicit `x` should follow `LayoutMirroring.enabled`, glyphs that mean back or forward should swap with `Commons.I18n.rightToLeft`, and Left/Right keys should go through `Util.readingKey(event)`.
- Keep calls to `strings.t(...)` inside bindings so a language switch re-renders them. Text built once when something happens keeps the old language until it is rebuilt.
- Format dates with `Qt.locale(Commons.I18n.formatLocale)`, not `Qt.formatDate` or a bare `Qt.locale()`: those follow the locale the shell started with, which changes only when it restarts.
- Keep brand names, units, and keyboard keys as they are, and leave log and diagnostic output in English.
- Use `strings.t()` only for the plugin's own text. `Commons.I18n` holds Omarchy's catalog, which can rename or drop its keys in any update.

## Bar Layout

Discover current bar commands with `omarchy bar --help`. For example:

```bash
omarchy bar move omarchy.clock --section right
```

Use `~/.config/omarchy/shell.json` for layout changes not exposed by a command.
Verify every moved, added, removed, or configured widget in the running bar.

## Built-In Plugins and Widgets

Clone a built-in plugin before customizing its code:

```bash
omarchy plugin clone omarchy.workspaces
# Edit ~/.config/omarchy/plugins/<username>.workspaces/
```

Cloning switches the relevant configuration to the user-owned copy. Saved
changes under `~/.config/omarchy/plugins/` reload automatically and survive
package updates. Force discovery after a failed reload with:

```bash
omarchy-shell shell rescanPlugins
```

Plugin work is complete when the user-owned plugin is active, the requested
behavior has been observed, and the packaged source remains unchanged.

## Menus and Launcher

Put menu overrides in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`; inspect
`$OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc` for current entries and
schema examples. Saved changes hot-reload.

Menu work is complete when the changed entry can be found and its action runs
successfully from the live menu.

## Idle and Lock

Set `idle.screensaver` and `idle.lock` in `~/.config/omarchy/shell.json`. Values
are seconds from the beginning of user inactivity. For example, ten minutes is
`600`.

Idle work is complete when the file passes JSON validation and the configured
screensaver and lock transitions occur at the requested thresholds. Long waits
that were not exercised must be reported as unverified.

## Recovery

After user confirmation:

```bash
omarchy refresh shell
```

Confirm the backup when `shell.json` differed, check the restored JSON, and observe the affected shell
surface before reporting recovery complete.
