# Plan: JetBrains products in Install and Defaults

Revision 2. The user has confirmed the UI flows below: support JetBrains products through the existing menu and default-editor flow, with minimal changes to the launcher. This document is the implementation plan; no runtime changes have been made as part of planning.

## Outcome

Users can install the current JetBrains desktop products available for Linux from Omarchy's menu. Every product that supports the normal editor contract can also be selected through `omarchy default editor <product>` and Setup > Default > Editor. Selecting a missing editor uses the existing floating-terminal installation flow, then persists the selection only after successful installation and launcher verification.

The implementation adds two JetBrains submenus and the necessary package and command mappings. Existing editor entries keep their positions and behavior.

## Agreed user flows

| User action | Visible behavior | Default-editor result |
|---|---|---|
| Choose an uninstalled product under Install > Editor > JetBrains | The usual floating terminal installs it, then the application opens. | The previous default stays selected. |
| Return to Install after successful installation | The product remains listed, dimmed and checked, using the existing installed-state convention. | No change. |
| Choose an installed product under Setup > Default > Editor > JetBrains | The existing notification confirms the choice and its Defaults row receives the checkmark. Selection alone does not launch another IDE window. | The chosen executable becomes the default. |
| Choose a missing product under Setup > Default > Editor > JetBrains | The usual floating terminal installs it and the installer opens the application. The selection is confirmed only after installation and launcher verification succeed. | The chosen executable becomes the default after success. |
| Installation fails, is cancelled, or does not provide the expected launcher | Installation reports the failure through the existing terminal flow. | The previous default stays selected. |
| Launch an installed product through Apps | The application opens through the existing launcher. | No change. |
| Open a configuration from an Omarchy menu | Omarchy opens it in the selected default editor. | Uses the stored choice. |

Both JetBrains editor submenus list the same eligible products in the same alphabetic order. Users can also find them through the existing menu search. Existing Neovim, VSCode, Zed, and other editor entries stay where they are, and choosing them continues to work as before.

Toolbox, Gateway, and the specialized Development tools remain separate install choices. Installing a specific IDE directly from Omarchy does not require the user to first install or navigate Toolbox. License and account setup appear in the product's own first-run UI.

The default applies to Omarchy's editor commands, configuration opening, and programs using the existing editor environment. Double-clicking a file in the file manager retains its current association.

## Boundaries

- Keep the existing menu renderer, navigation, row appearance, search, and checkmarks. Use existing glyphs; adding brand glyphs is outside this change.
- Keep every supported JetBrains editor listed in Defaults, including products that are not installed, just as the existing editor choices work today.
- Do not add an "Install another editor" action, filter Defaults to installed editors, move existing entries, or introduce a new picker.
- Keep the current default state format: one executable name in the existing editor state file. Preserve `EDITOR`, `SUDO_EDITOR`, `--inline`, the terminal-editor branch, UWSM launching, and fallback behavior.
- Keep MIME associations, file-manager integration, themes, keybindings, autostart, and user configuration untouched.
- Installation from Install does not change the default editor. Selecting a product from Defaults explicitly requests installation if needed and selection as the default.
- Interpret the product scope as current Linux desktop applications. Server deployments, cloud services, IDE plugins, language toolchains, and Windows-only applications belong to their existing categories or separate work.

## Product coverage

Use the current [JetBrains product catalog](https://www.jetbrains.com/products/) as the inventory, supplemented by [Air's Linux installation documentation](https://www.jetbrains.com/help/air/install-the-air-app.html). The package names below were checked against AUR metadata on 2026-10-19; recheck package contents and available Omarchy/Arch repositories before implementing the mappings.

| Product | Product ID | Initial package candidate | Menu placement |
|---|---|---|---|
| Air | `air` | `jetbrains-air` | Editor > JetBrains; Defaults after launcher verification |
| CLion | `clion` | `clion` | Editor > JetBrains; Defaults |
| DataGrip | `datagrip` | `datagrip` | Editor > JetBrains; Defaults |
| GoLand | `goland` | `goland` | Editor > JetBrains; Defaults |
| IntelliJ IDEA | `intellij-idea` | `intellij-idea-ultimate-edition` | Editor > JetBrains; Defaults |
| PhpStorm | `phpstorm` | `phpstorm` | Editor > JetBrains; Defaults |
| PyCharm | `pycharm` | `pycharm` | Editor > JetBrains; Defaults |
| Rider | `rider` | `rider` | Editor > JetBrains; Defaults |
| RubyMine | `rubymine` | `rubymine` | Editor > JetBrains; Defaults |
| RustRover | `rustrover` | `rustrover` | Editor > JetBrains; Defaults |
| WebStorm | `webstorm` | `webstorm` | Editor > JetBrains; Defaults |
| JetBrains Toolbox | `toolbox` | `jetbrains-toolbox` | Development |
| JetBrains Gateway | `gateway` | `jetbrains-gateway` | Development |
| JetBrains MPS | `mps` | `jetbrains-mps` | Development; verify current distribution |

MPS is a specialized language-workbench application. Include its installation in the inventory, and verify its file-opening behavior before offering it as a general default editor. Toolbox and Gateway are management/connection tools and are not default editors. Audit the remaining Linux desktop utilities in the product catalog, including any profiling applications, using the same distinction between a desktop app and a command-line distribution.

Offer one current distribution per product using its public product name. Package naming such as "ultimate-edition" is an implementation detail. Verify existing edition conflicts and let the normal package-manager flow handle them; do not silently remove or replace an existing edition.

Do not add retired products just because an AUR package still exists. [Aqua was discontinued](https://blog.jetbrains.com/qa/2025/04/aqua-sunset/), [Fleet evolved into Air](https://blog.jetbrains.com/fleet/2025/12/the-future-of-fleet/), and the [DataSpell product page](https://www.jetbrains.com/dataspell/) currently redirects to PyCharm for data science. Recheck these statuses during the inventory step and document the resulting coverage explicitly.

## Menu

Add static entries to [the existing menu definition](../default/omarchy/omarchy-menu.jsonc):

```text
Install > Editor > JetBrains
  Air
  CLion
  DataGrip
  GoLand
  IntelliJ IDEA
  PhpStorm
  PyCharm
  Rider
  RubyMine
  RustRover
  WebStorm

Setup > Default > Editor > JetBrains
  The same editor products, in the same order

Install > Development
  JetBrains Gateway
  JetBrains MPS
  JetBrains Toolbox
```

- Use `install.editor.jetbrains.<id>` and `setup.default.editor.jetbrains.<id>` for the editor rows, with an alphabetic product order.
- Install rows use `disabled` presence checks and retain the existing dimmed-with-checkmark behavior once installed. Defaults rows use `checked` comparisons against the stored executable and call `omarchy-default-editor <product-id>`.
- Use short `description` values for search terms such as JetBrains, Python, Java, Kotlin, SQL, and TypeScript. Keep their existing rendering behavior and do not add menu aliases.
- Keep guards compatible with the existing package snapshot and cached default-editor reader described in [the menu reference](../docs/menu.md). They must not inspect the network or launch an IDE.
- Verify normal application discovery from each installed desktop entry. Installed products should appear in Apps through the existing mechanism.
- Add English menu catalog entries alongside the menu changes, following [the i18n reference](../docs/i18n.md). Product names remain unchanged; translations follow the repository's existing workflow.

## Package and platform work

1. Record the actual executable, desktop entry ID, required package set, runtime, architecture support, and package ownership for every product. Check bundled native components rather than trusting an `arch=any` declaration. The current MPS AUR candidate is substantially older than the current product and needs particular attention.
2. Prefer existing configured repository packages through `omarchy-pkg-add`. Use `omarchy-pkg-aur-add` for AUR packages. Keep a single selected package source per product, without an automatic fallback between package managers.
3. Include required split runtime packages explicitly. For example, `jetbrains-air-jre` is only an optional dependency of the AUR Air package. Audit the equivalent split packages for the IntelliJ-based IDEs, and CLion's required build/debug components.
4. Resolve packaging gaps upstream first, then publish builds through the separate `omarchy-pkgs` repository where appropriate. That package work is a dependency of complete platform support, not something a menu change in this repository can accomplish.
5. Aim for the same product coverage on x86 and aarch64. Several current AUR definitions omit aarch64 even where JetBrains supplies the archive; Air is a verified example. Use `omarchy-hw-x86` / `omarchy-hw-aarch64` only when an architecture decision is actually needed. Do not hide a product merely because its package is missing an ARM build.
6. Handle a genuinely unavailable upstream binary using the existing architecture-guard convention and explain that limitation next to the entry. Report packaging failures clearly and leave the previous default intact.

Keep Omarchy-managed installation, updates, and removal under the existing package-management flow. Toolbox remains an optional application with its own management UI. Existing Toolbox launchers already on PATH may be selected through the normal command-presence check; this change does not add Toolbox-directory scanning, generated symlinks, installation migration, or takeover of Toolbox-managed IDEs.

## Commands and default integration

Add a shared installer with the proposed interface `omarchy-install-jetbrains <product-id>`, routed as `omarchy install jetbrains <product-id>`. It serves both the editor rows and the Development tools. Keep it within the existing `install` command group and follow [command metadata requirements](../agents/skills/command-metadata.md).

Keep the product mappings in one small JetBrains-specific catalog, proposed as the sourced Bash library `default/jetbrains/products.sh`. Both the installer and default selection load it through `$OMARCHY_PATH`, only when resolving a JetBrains selection. Use named fields and a Bash array for packages; product IDs, executable names, and desktop IDs must be literal data. Do not evaluate strings as shell commands. The menu remains static; a focused test checks its product coverage against the catalog.

The installer:

- Validates the product ID before installing anything and reports unsupported IDs with usage text and a nonzero status.
- Installs the complete package set, propagates package-manager failure, and checks the expected launcher and desktop entry before reporting success.
- Launches the installed desktop entry through the existing detached `setsid uwsm-app -- gtk-launch ...` pattern after successful installation.
- Leaves existing user settings, credentials, licensing choices, and default-editor selection alone. First-run account and license setup stays in the JetBrains application.

Extend [omarchy-default-editor](../bin/omarchy-default-editor) with the JetBrains product IDs and their actual executable names. The existing editors continue through their existing branches. JetBrains choices use the shared installer from the existing `--install` branch, verify that the executable is now present, and then write the same one-line state value and use the existing translated notification.

Product IDs and executable names are separate: for example, IntelliJ IDEA's public product ID need not equal the package's launcher name. Accept both the selected public ID and the canonical executable where appropriate so setting and reading defaults round-trips correctly. Do not guess mappings from the product display name.

## Launcher compatibility

Start with [omarchy-launch-editor](../bin/omarchy-launch-editor) unchanged. For every proposed default editor, verify opening an individual file and a directory using its real Linux launcher, including paths with spaces and names beginning with a dash. Air needs its own verification; it is not an IntelliJ Platform launcher.

The current GUI invocation is `setsid uwsm-app -- "$editor" -- "$@"`. Keep it when supported. If a particular launcher rejects the operand separator, add the smallest product-specific argument adapter and preserve safe treatment of option-shaped filenames. Do not remove operand protection for other editors or introduce shell evaluation. Store only the executable name in the default state.

Preserve the existing behavior of GUI editors under `--inline`; changing GUI wait semantics or adding `--wait` globally is outside this work. A product is ready for Defaults only after the real launcher passes the file and directory checks. A failed check remains an explicit integration task; it must not silently disappear from the agreed coverage.

## Implementation sequence

1. **Finish the product matrix and packages.** Resolve package names, runtime sets, edition conflicts, desktop IDs, launchers, current product status, and x86/aarch64 gaps. Deliver a per-product matrix with the tested distribution, complete package set, executable, desktop entry ID, architecture results, and default-editor eligibility. Prepare upstream and `omarchy-pkgs` changes where necessary; list their dependencies explicitly. This step is ready when every product has a concrete integration path and each remaining packaging gap is named.
2. **Implement the catalog and shared installer.** Add `default/jetbrains/products.sh` and `bin/omarchy-install-jetbrains`, with command metadata and isolated installer tests. Validate package success/failure, install idempotence, runtime completeness, and detached desktop launching. This step is ready when the CLI installs a selected product through its chosen package helper and cannot report success or launch it after a failed installation.
3. **Wire Defaults and verify launchers.** Extend `bin/omarchy-default-editor` with product/executable normalization and the shared installer. Preserve its existing read path and state format. Test already-installed selection, missing-editor terminal handoff, failure, and post-install command verification. Exercise the real file/directory launchers and add a narrowly scoped change to `bin/omarchy-launch-editor` only if the observed arguments require it. This step is ready when selection round-trips correctly and every eligible IDE opens the test paths without changing other editors' behavior.
4. **Add the menu entries and English catalogs.** Add the two JetBrains editor submenus and the standalone Development tool entries in `default/omarchy/omarchy-menu.jsonc`, plus their English catalog entries in `default/i18n/en/menu.json`. Keep both editor lists aligned and reuse the existing presence guards, checked guards, presentation terminal, icons, and search behavior. This step is ready when all agreed user flows are wired to the tested commands and the existing menu tests pass.
5. **Verify the user experience in Linux.** Run the focused checks below, then exercise the running UI and real applications in disposable environments. Record screenshots for install/default states, verify application discovery, and record actual x86/aarch64 outcomes. This step is ready when the flow table above has been exercised, no installation failure changes the saved default, and unresolved platform coverage is clearly reported.
6. **Document and prepare the change for review.** Add a short user-facing explanation to [Development Tools](../manual/18-development-tools.md), covering where to install products, where to select the default, and the role of optional Toolbox. Include the product matrix, package dependencies, test results, and screenshots in the review notes. Keep repository internals in this plan or developer reference material. This step is ready when a reviewer can assess product coverage and all changes against the agreed scope without reconstructing this conversation.

Keep package changes and the coherent Omarchy integration reviewable separately. Implementation is complete only when the agreed product matrix has a verified outcome for each supported architecture.

## Review checkpoints

- **Package work:** review any upstream or `omarchy-pkgs` changes independently, including runtimes, supported binaries, updates, and removal. Do not count an unpublished package as working support.
- **Omarchy integration:** review the catalog, installer, default-editor mapping, static menu entries, English catalog changes, and their focused tests as one coherent feature. If a launcher adapter is necessary, include its compatibility evidence and regression coverage.
- **Scope check:** confirm that the agreed flows are implemented without changing the menu renderer, adding another Defaults action, changing MIME associations, or rewriting existing editor configuration. Keep unrelated workspace changes out of the feature.

## Verification

Automated coverage should exercise behavior rather than duplicate catalog literals:

- Extend [default-apps-test.sh](../test/shell.d/default-apps-test.sh) for installed selection, missing-editor terminal handoff, correct package/runtime installation, canonical executable persistence, and preservation of the previous default on failure or a missing post-install executable.
- Add a JetBrains installer suite under `test/shell.d/`, using [base-test.sh](../test/shell.d/base-test.sh), for unsupported IDs, package failures, required runtime sets, successful desktop launching, and refusal to launch after installation failure.
- Extend [command-operand-boundaries-test.sh](../test/shell.d/command-operand-boundaries-test.sh) if any launcher argument adapter is needed. Cover spaces and option-shaped filenames while preserving the existing terminal and GUI editor checks.
- Run the existing menu, menu-guards, menu-guard-budget, desktop-entry-launch, editor-env, and i18n checks for the affected behavior. Ensure menu/catalog parity, install guards, default checkmarks, and reader caching remain valid. Run `./test/cli` for routes and metadata.

Use the repository's [acceptance-test procedure](../agents/skills/acceptance-tests.md) for graphical acceptance in a disposable VM and the [visual-verification procedure](../agents/skills/visual-verification.md) for screenshots and inspection. Do not install the suite of IDEs into the active development session.

- Inspect both submenus, keyboard navigation, scrolling, search, installed markers, and the selected default's checkmark. Capture representative states with enough products to expose clipping or scrolling issues.
- Install from Install and confirm the existing default is unchanged. Select a missing product from Defaults and confirm installation followed by selection. Check failure and already-installed paths.
- Smoke-test every eligible editor's actual file/directory launcher, configuration-file opening through Omarchy, application discovery, and absence of duplicate windows caused by the integration. Record x86 and aarch64 results separately.
- Exercise the standard package update/removal path and confirm it leaves personal IDE settings intact. If the selected IDE is later removed, retain the launcher's current fallback behavior.
- Report unavailable VM/platform coverage explicitly instead of marking it as passed. License- or account-dependent features inside an IDE are not part of the installation/default-editor acceptance criteria.

## Completion criteria

- The agreed current Linux desktop product inventory is accounted for, including specialized tools and any documented upstream platform limitations.
- Every file-capable IDE in scope can be installed from the JetBrains submenu and selected from the matching Defaults submenu and CLI.
- Missing defaults use the existing installation flow; failures leave the previous selection intact.
- Existing editor entries, launcher behavior, user configuration, and MIME associations retain their current behavior.
- Package/runtime dependencies, supported architectures, focused automated checks, and real UI/launcher verification are recorded and reviewable.
