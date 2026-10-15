# StableBar

A native, configurable macOS bar built with Swift, AppKit and SwiftUI. One persistent panel per display holds the widgets; workspace changes update their contents without recreating windows.

The default configuration includes a System Settings shortcut, the active app and a clock. It needs no accounts, network services or third-party tools, though windows can extend under the bar without a tiling window manager (see [Keeping windows clear of the bar](#keeping-windows-clear-of-the-bar)). Optional shell widgets use a plain-text or JSON output protocol.

## Install and set up

Open `StableBar.dmg`, drag StableBar to Applications, then open the app. The first launch walks you through a bar preview, widget appearance, placement, clock format, and opening at login. Setup is also available from the menu-bar icon or by right-clicking the bar.

The starter bar needs no special permissions. Scripts that control other apps may prompt for Automation access when used; setup links to the relevant System Settings. AeroSpace and yabai manage their own Accessibility permission. Opening at login uses macOS Login Items and is off until you enable it.

Widgets follow the system's light or dark mode unless you pick a fixed appearance, which sets the global widget colors; individual widget styles still take precedence. Setup preserves custom widgets, scripts, and other settings. Closing setup leaves it available on the next launch. New configurations place the bar below the macOS menu bar; existing configurations retain their position.

## Build and run

Requires macOS 14+ and Xcode's Swift 6 toolchain. Optional workspace widgets require AeroSpace 0.21+ or yabai on your login shell's `PATH`.

Quit the running app before rebuilding its bundle.

```sh
./scripts/build.sh
open dist/StableBar.app
```

For development checks:

```sh
swift test
```

The first launch creates `~/.config/stablebar/config.json` from [Resources/config.json](Resources/config.json), with an offset for your menu bar. Subsequent launches keep your file. Right-click the bar or use its macOS menu-bar icon to open the configuration, reload it, reconnect the workspace source or quit.

### Build an installer

```sh
./scripts/package.sh
```

This creates `dist/StableBar.dmg` with the app and an Applications shortcut. It builds in a temporary directory, leaving a running `dist/StableBar.app` untouched. The app and installer target the build Mac's processor family.

Local builds are ad-hoc signed. For public distribution without an unidentified-developer warning, use a Developer ID Application certificate and a saved `notarytool` keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='stablebar-notary' ./scripts/package.sh
```

The script signs with the hardened runtime, submits the DMG to Apple, then staples and validates its notarization ticket. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for certificate and keychain-profile setup. A local DMG is suitable for development; building it alone does not make it a notarized release.

Keep personal settings in `~/.config/stablebar/config.json` and personal scripts in `~/.config/stablebar/widgets/`, outside the repository. Point commands directly at those scripts. `Resources/config.json` is the shared starter configuration; rebuilding the app does not overwrite your personal file. Local scripts should load any supporting files from their own directory.

StableBar sits at the top edge of each display. `bar.offset` moves it down from that edge. It hides on native fullscreen Spaces. AeroSpace gaps and macOS menu-bar settings are managed separately; this app does not change them. Keep the center clear on a notched display. The default configuration uses only the left and right groups.

### Keeping windows clear of the bar

macOS gives apps no way to reserve screen space, so windows can extend under the bar, as they do with SketchyBar. With AeroSpace, set `gaps.outer.top` in `~/.aerospace.toml` to the bar's height (40 by default), plus any `bar.offset` beyond the menu bar; AeroSpace accepts per-monitor values. yabai users can set `external_bar`. Without a tiling window manager, windows placed at the top of the screen sit partly under the bar.

## Layout and style

Save the configuration to apply changes. Direct saves and atomic file replacements are watched, including files imported with `includes`. Invalid edits retain the last working configuration and show an error indicator; click it to open Customize StableBar, which shows the error. Script instances, their last output, and graph history survive style-only changes, including when a script has an error.

Unknown properties are errors, so a misspelled key cannot be silently ignored. The last working configuration stays in place and the error names the property, for example `widgets.clock: style.fontsize: Unknown property.` For completion and validation in editors that support JSON Schema, start a configuration file with:

```json
"$schema": "https://raw.githubusercontent.com/Seb-GRAF/StableBar/main/stablebar.schema.json"
```

- `bar`: `height`, `offset`, `inset`, `spacing`, `background`, `animationDuration` (seconds), `displayScale`.
- `defaults`: styles inherited by every widget.
- `workspaceSource`: `aerospace` (default) or `yabai`, for workspace widgets and active-display tracking.
- `widgets`: ordered widget definitions with unique `id`, `type`, `position` and optional `style`, `icon`, `onClick`, `menu`, `popup`.
- `position`: `left`, `notchLeft`, `center`, `notchRight` or `right`.
- Colors: `#RRGGBB` or `#RRGGBBAA` (alpha last).
- Icons: SF Symbols names.
- Measurements: points.

### Modules, templates and overrides

Split a setup into JSON files and load them from the main configuration:

```json
{
  "includes": ["theme.json", "widgets/system.json", "widgets/music.json"],
  "environment": { "PLAYER": "Spotify" },
  "widgetOverrides": {
    "clock": { "format": "EEE HH:mm", "style": { "fontSize": 14 } },
    "music": { "enabled": false }
  }
}
```

Include paths are relative to the file that names them; absolute paths and `~` also work. Includes can have their own includes. Files apply in listed order, followed by the containing file. Objects merge recursively, with later values winning. Arrays replace earlier arrays, except top-level `widgets`, which concatenate in order, and `packages`, whose selections merge by package ID. Root package selections can disable or change versions inherited from includes. Modules can contain only a theme, templates, popups, environment variables, or overrides; they do not need widgets.

Define reusable widget properties in `templates`, then select one with `template`:

```json
{
  "templates": {
    "metric": {
      "type": "script", "position": "right", "interval": 30, "timeout": 5,
      "style": { "fontSize": 12, "paddingHorizontal": 10 }
    },
    "eventMetric": { "template": "metric", "interval": null }
  },
  "widgets": [
    {
      "id": "build", "template": "eventMetric", "events": ["build_finished"],
      "command": "printf '%s' \"${INFO:-Waiting for a build}\""
    }
  ]
}
```

Widget properties override their template recursively. `widgetOverrides` applies last, by widget ID, so you can customize imported widgets without editing shared files. Set `enabled` to `false` to hide a widget and stop its script and event subscriptions. Set it back to `true` to restore it. Use `null` to clear an inherited optional property, such as `popup` or `interval`. Overrides must not contain an `id` field. Duplicate widget IDs, unknown override targets, include cycles, and missing or cyclic templates referenced by widgets reject the whole edit.

Included files are watched even outside the main directory. A missing module or directory is watched for repair; the last working bar remains visible meanwhile.

[examples/modular](examples/modular/config.json) is a complete, dependency-free starter with a theme, template, event-only status, and an optional volume widget. Try it without replacing your personal configuration:

```sh
./dist/StableBar.app/Contents/MacOS/StableBar --validate examples/modular/config.json
./dist/StableBar.app/Contents/MacOS/StableBar --config examples/modular/config.json
```

From another terminal, run `./dist/StableBar.app/Contents/MacOS/StableBar --trigger demo 'INFO=Build finished'`. The status changes to the supplied text. Enable the sample volume widget through its override to use click-to-mute and scroll-to-adjust.

Each widget can override any of these styles:

`foreground`, `background`, `hoverBackground`, `borderColor`, `borderWidth`, `cornerRadius`, `fontName`, `fontSize`, `fontWeight`, `iconSize`, `paddingHorizontal`, `paddingVertical`, `spacing`, `width`, `accent`, `accentText`, `shadowRadius`, `shadowColor`.

`fontName` is `system` or an installed font name. `fontWeight` is `regular`, `medium`, `semibold` or `bold`. Set `width` on frequently changing widgets to keep their footprint stable. The workspace highlight uses `accent` and `accentText`; its motion respects Reduce Motion. Set `animationDuration` to `0` to remove transition time.

Styles also accept `hoverForeground`, `height`, `paddingLeading`, `paddingTrailing`, `paddingTop`, `paddingBottom`, `offsetX`, `offsetY` and `opacity`. Side-specific padding overrides horizontal/vertical padding. `ultralight`, `thin` and `light` font weights are available too. Offsets move the drawing without moving its neighbours.

### Theme tokens and automatic profiles

Define reusable JSON values in `tokens` and reference them with a whole string such as `"@token.accent"`. Values retain their type: a token can supply a number, boolean, array, object, or string. Tokens can reference other tokens; unknown names and cycles reject the change while the current configuration keeps running. References are not interpolated inside shell commands or other strings.

```json
{
  "tokens": { "accent": "#db733f", "fontSize": 12 },
  "defaults": { "accent": "@token.accent", "fontSize": "@token.fontSize" },
  "profiles": [
    {
      "name": "dark",
      "when": { "appearance": "dark" },
      "configuration": { "tokens": { "accent": "#ffa66b" } }
    },
    {
      "name": "laptop",
      "when": { "onBattery": true, "displayCount": 1 },
      "configuration": { "bar": { "height": 34 }, "tokens": { "fontSize": 11 } }
    }
  ],
  "widgets": [{ "id": "clock", "type": "clock", "position": "right" }]
}
```

Profiles match `appearance` (`light` or `dark`), `onBattery`, `displayCount`, `externalDisplay`, and the focused app's bundle identifier in `app`. Conditions in one profile must all match. Matching profiles apply in array order after modules and the root configuration; later profiles win. A profile without `when` always matches. Widgets in profiles append to the bar; use `widgetOverrides` to change existing widgets. Appearance, power, screen and focused-app changes update the active profiles automatically.

Set `"profile": "laptop"` to apply only that profile, regardless of its conditions. Remove `profile` to resume automatic matching, or set it to `null` to override a manual profile inherited from a module. The inspector reports active profiles and the file, template, override and token sources behind effective widget properties.

In **Customize StableBar → Editor → Profiles**, add profiles, edit their conditions and configuration, or choose Automatic matching or a pinned profile. Changes use the editor's Undo, Redo, Save and Discard controls. Editing profiles imported from another file writes the full profile list into the main file, preserving their order and configuration; the imported file stays unchanged.

Setup, the editor and the command line save changes into the main file's ordinary keys and never edit imported files. A widget defined in the main file, including inside one of its profiles, is changed, removed or reordered where it is defined. A widget from an include or package gets an entry in the main file's `widgetOverrides`; removing it sets `enabled` to `false`. Bar and default-style changes merge into `bar` and `defaults`. Untouched parts of the file keep their formatting and key order. An active profile still applies on top of these changes.

When every widget comes from the main file's `widgets` array, reordering changes that array. Otherwise the order is saved in `widgetOrder`: listed IDs come first, unlisted widgets keep their relative order, and IDs that are not currently present, such as widgets of an inactive profile, are skipped.

Earlier versions saved changes in `customization` and `removedWidgets`. StableBar converts those keys into the ordinary ones the next time it starts.

### Local widget packages

Open **Customize → Packages** to review a local package folder, inspect its commands and settings, and install it. Installation does not enable a package or execute its commands. Select an installed version, review its commands, adjust its settings, and enable it explicitly. Settings and the selected version are saved in the root configuration. Selecting an older installed version rolls back the pin.

A package is a folder containing `package.json`, its configuration, and any scripts or assets. [examples/packages/local-clock](examples/packages/local-clock/package.json) is a working package using a bundled script. Its manifest has this shape:

```json
{
  "id": "local-clock",
  "name": "Local clock",
  "version": "1.0.0",
  "entry": "config.json",
  "settings": {
    "format": { "type": "string", "title": "Time format", "default": "%H:%M" },
    "fontSize": { "type": "number", "title": "Font size", "default": 12 }
  }
}
```

Settings support `string`, `number`, and `bool`, with a required matching `default`. Reference a setting as a whole value, such as `"fontSize": "@setting.fontSize"` or `"environment": { "FORMAT": "@setting.format" }`. Put settings needed by shell commands in environment variables and quote them normally in the script. Widgets, templates and providers receive `PACKAGE_DIR`, the absolute path of the installed package, for commands such as `"$PACKAGE_DIR/scripts/clock.sh"`.

Packages install atomically into `packages/<id>/<version>` beside the main configuration. Existing versions cannot be overwritten. Configuration includes and static image paths stay inside the package; traversal and symlinks escaping the folder are rejected. Static image paths are resolved relative to the package folder, including token references. Package commands can run arbitrary code as your user; review the files as well as the displayed command strings before enabling an unfamiliar package.

```sh
StableBar --inspect-package examples/packages/local-clock
StableBar --install-package examples/packages/local-clock
StableBar --packages
```

Enable an exact installed version in the root configuration:

```json
{
  "packages": [
    { "id": "local-clock", "version": "1.0.0", "enabled": true, "settings": { "format": "%H:%M:%S" } }
  ]
}
```

Package selections in modules merge by package ID, with later modules and the root taking precedence. Enabled packages load once before the composed modules and root properties. Root templates, tokens and widget overrides can customize them. Set `enabled` to `false` to stop loading a package; installation alone has no runtime effect. Packages cannot enable other packages. There is no network registry or automatic update process: versions remain pinned until you choose another installed version.

### Displays and notch placement

`notchLeft` ends before the notch and `notchRight` starts after it. `bar.notchSpacing` controls the gap on each side (16 by default). The notch comes from the screen's unobscured top areas; `bar.notchWidth` can override its width. On screens without a notch, `notchLeft`, `center` and `notchRight` form one centered group, measured from the visible content. Hidden groups leave no gap. With a notch, `center` remains at the screen's center and should be left empty.

Each widget accepts `display`: `"all"` (default), `"active"`, `"main"`, `"builtIn"`, `"external"`, `"notched"`, `"unnotched"`, or an array of screen numbers, for example `[1, 2]`. Numbers are one-based positions in `NSScreen.screens`, matching AeroSpace and SketchyBar; they can change when displays are rearranged. `active` follows the configured workspace source's focus. With AeroSpace, use `aerospace list-monitors --format '%{monitor-name}|%{monitor-appkit-nsscreen-screens-id}'` to list them. yabai display IDs are mapped to these screen numbers, independently of yabai's display ordering.

Set `bar.displayScale` to `{ "builtIn": 0.85, "external": 1 }` to shrink the laptop bar while keeping external displays at their original size. Each factor scales the bar height, widgets, text and spacing; omitted display types use `1`. Factors must be positive, and other keys are rejected. The bar offset and popup sizes stay in screen points. This setting also works inside automatic profiles.

`bar.style` accepts `background`, `cornerRadius`, `borderColor` and `borderWidth`. The border is drawn along the bottom edge. Scripts can return `barStyle` to change those properties; later widgets override earlier widgets when they set the same property.

### Composing widgets

A widget's `layout` uses the same blocks as a popup. Use rows and columns to style the label, icon and other elements independently. Bar layouts take their content's width; popup layouts fill their available width. Give graphs, progress blocks and images explicit sizes when they should have a fixed footprint.

`overlay` uses the same blocks, aligned to the widget's bottom edge. It occupies no space and does not intercept clicks. This supports an underline, playback progress or a graph underneath the label.

For example, a music script can return:

```json
{
  "text": "Track title",
  "fields": { "artist": "Artist", "artwork": "https://example.com/cover.jpg" },
  "values": { "playback": 0.25 },
  "targets": { "playback": 0.30 }
}
```

The widget can use:

```json
{
  "layout": {
    "type": "row",
    "style": { "spacing": 6 },
    "children": [
      { "type": "field", "field": "artist", "style": { "fontSize": 11, "foreground": "#8e978f" } },
      { "type": "field", "field": "text", "style": { "fontSize": 13, "fontWeight": "medium" } }
    ]
  },
  "overlay": {
    "type": "progress", "source": "playback", "height": 2,
    "style": { "accent": "#f1efe8", "background": "#f1efe829", "cornerRadius": 0 },
    "animation": { "curve": "linear", "duration": 15 }
  }
}
```

`text` and `icon` are supplied to bar layouts from the widget's normal content. Other fields come from the script. Active-app layouts receive `text` as the app name. Use the normal clock rendering for native clock widgets.

Script output ignores unknown top-level fields, but styles, animations and menu items in it use the configuration's property names and reject unknown ones. Script output may include `style` to override the widget style, `display` to change its display filter, and `styles` to supply named element styles. A block with `"styleSource": "countdown"` reads `styles.countdown`, overlaid on its configured style. A list row can use `styleField` to read the style name from a field in that row. Scripts can return `widgetStyles`, keyed by widget ID, to style another widget (for example, change a workspace underline when the window-manager mode changes). Later scripts take precedence; a widget's own `style` output takes precedence over those overrides. Omitted overrides return to the configured style on the next update.

Widgets and blocks accept `animation` with `duration` in seconds and `curve`: `linear`, `easeIn`, `easeOut`, `easeInOut`, `smooth` or `spring`. Widget animation defaults to `bar.animationDuration`. Block style animations are opt-in. Progress values use a 0–1 scale, clipped to that range when drawn. A progress block can also read a numeric string from its current list row when there is no matching entry in `values`. With a matching entry in `targets`, a progress rule starts at `values[source]` and animates toward `targets[source]`; without a target it animates between readings. Reduce Motion disables these animations.

### Workspace appearance

A `workspaces` widget (also accepted as `aerospace`) accepts `workspace` with:

- `indicator`: `background` (default), `underline` or `none`.
- `indicatorStyle`: underline `height`, `width`, `background`, `cornerRadius`, `offsetX`, `offsetY`.
- `style`, `focusedStyle`, `visibleStyle`, `emptyStyle`: cell typography, foreground, width, height, horizontal/side padding and spacing. The background indicator uses the state's background or border color.
- `showEmpty` and `showApps`: control empty workspaces and app icons.
- `appStyle`, `focusedAppStyle`, `visibleAppStyle`: font and foreground for app glyphs, width and height for native app icons.
- `appGlyphs`: app bundle ID or app name to text glyph. Set `appStyle.fontName` to an installed icon font to use its ligatures. Use `"*"` for the fallback glyph; otherwise unmapped apps retain native icons.

For a sliding underline, set `workspace.indicator` to `underline`, `workspace.style.height` to the bar's height, and `workspace.indicatorStyle` to `{ "height": 2, "background": "#f1efe8" }`. The widget's `animation` controls its motion.

### Script events

Add `events` to a script widget to refresh it on named events, alongside its interval. Set `"interval": null` to run once at startup and then only on events or after a click action. Omitting the interval keeps the default 30-second polling. Numeric intervals must be greater than zero. `frontApp`, `workspace`, `aerospaceMode` and `wake` are emitted by StableBar. Other names subscribe to macOS distributed notifications, for example `com.spotify.client.PlaybackStateChanged`.

External hooks can trigger an event without launching another bar:

```sh
/path/to/StableBar.app/Contents/MacOS/StableBar --trigger deploy_started
/path/to/StableBar.app/Contents/MacOS/StableBar --trigger build_finished 'INFO=Build passed' STATUS=success
```

Use that event name in the widget's `events`. Extra `KEY=VALUE` arguments become environment variables, preserving spaces, quotes and equals signs as data. Trigger arguments and distributed-notification data cannot replace variables exported by your login shell, such as `PATH` or `HOME`. Events finish the currently running update and coalesce pending refreshes to the latest event and payload. A widget never runs overlapping update commands. This queue is intended for refreshing current state, not recording every event.

Commands inherit your login shell's environment, then top-level `environment`, then the widget's `environment`, then event data. Values must be strings. StableBar supplies these variables:

| Variable | Value |
| --- | --- |
| `NAME` | Widget ID; event data cannot replace it |
| `CONFIG_DIR` | Directory containing the main configuration; event data cannot replace it |
| `SENDER` | `startup`, `routine`, the subscribed event name, `action` after an action completes, or a mouse event below |
| `INFO` | Explicit trigger value; front-app name for `frontApp`; focused workspace name for `workspace`; mode name for `aerospaceMode`; otherwise the distributed notification's JSON payload when available |
| `SID` | Display number for pointer actions and workspace events |
| `BUTTON` | `left`, `right` or `middle` for widget mouse clicks |
| `MODIFIER` | Space-separated `shift`, `ctrl`, `alt`, `cmd`, `fn` for pointer actions |
| `SCROLL_DELTA` | Signed vertical scroll delta for scroll actions |

Script output can also set `onClick` for a state-dependent click action; popups and menus still take precedence. Named graph data goes in `series`, a dictionary of arrays; only the latest 60 samples of each graph are retained.

### Mouse actions

Keep `onClick` for the primary action. Add `actions` to any widget for additional controls:

```json
"actions": {
  "rightClick": "open -a 'System Settings'",
  "middleClick": "open -a 'Activity Monitor'",
  "scrollUp": "\"$CONFIG_DIR/volume.sh\" up",
  "scrollDown": "\"$CONFIG_DIR/volume.sh\" down",
  "mouseEntered": "\"$CONFIG_DIR/hover.sh\" enter",
  "mouseExited": "\"$CONFIG_DIR/hover.sh\" exit"
}
```

These commands receive `SENDER=mouse.clicked`, `mouse.scrolled`, `mouse.entered` or `mouse.exited`. Scroll direction follows the signed native vertical delta. Only configured mouse actions intercept input; an unconfigured right click opens the bar's management menu. Actions run in order per widget, while other widgets remain independent. Successful actions refresh the same script instance with `SENDER=action`. A failed action marks its widget with a red badge, with the error in its tooltip, until that widget's next action succeeds. Quitting cancels running and queued actions.

### Command-line controls

The executable is `StableBar.app/Contents/MacOS/StableBar`. Prefix commands with `--config PATH` to address a specific running configuration; otherwise live commands target the default configuration. Replies are JSON, and errors exit with status 1. Each configuration has one local control endpoint per user.

```sh
StableBar --query
StableBar --query clock
StableBar --set clock '{"format":"HH:mm:ss","style":{"fontSize":15}}'
StableBar --add '{"id":"note","type":"text","position":"left","text":"Hello"}'
StableBar --reorder note clock
StableBar --remove note
StableBar --profile dark
StableBar --profile auto
StableBar --reset
StableBar --customize
```

Changes are live for the current session and appear as unsaved changes in the editor. Add `--persist` to save the session changes into the root file. `--reset` discards unsaved session changes and reloads the files. Session edits reapply over external file changes. Imports and package source files are preserved.

Use one batch for changes that must appear together:

```sh
StableBar --batch '[
  {"action":"set","id":"clock","properties":{"position":"left"}},
  {"action":"bar","properties":{"height":44}},
  {"action":"defaults","properties":{"fontSize":13}}
]' --persist
```

A batch validates the whole resulting configuration before replacing the running bar or writing the file. A failed batch leaves both intact. Supported edit actions are `set` (`id`, `properties`), `add` (`properties`, including `id`), `remove` (`id`), `reorder` (`ids`), `bar`/`defaults` (`properties`), `profile` (`name`, omitted for automatic), and `package` (`properties`: `id`, `version`, optional `enabled` and `settings`).

- `--validate [PATH]`: compose and validate files without starting scripts.
- `--refresh ID`: refresh a running widget. Hidden, suspended providers must first be made visible or opened in the inspector.
- `--trigger EVENT [KEY=VALUE ...]`: send an event. Without `--config`, this broadcasts to all subscribed bars for compatibility; with `--config`, it targets that configuration.
- `--reload`: reload configuration; without `--config`, notify all running bars.
- `--packages`, `--inspect-package PATH`, `--install-package PATH`, `--enable-package ID VERSION [--persist]`: review and manage local packages. Installation does not enable commands. Package selections belong in the root file or its includes; use profile widget overrides to hide package widgets contextually.

### Editor and inspector

Open **Customize StableBar…** from the menu-bar icon or by right-clicking the bar, reopen the running app, or run `StableBar --customize`.

The **Editor** lists your widgets by position; drag to reorder them. Change positions, icons, text, clock formats, colors, font size, padding and corners, or edit a widget's properties as JSON. **Bar** sets the bar's size and the default text color, background and font size. Changes apply to the bar immediately, like command-line edits without `--persist`. Undo and redo step through them, **Save** writes them to your configuration and **Discard** returns to the saved file. A change that would make the configuration invalid is rejected and its error is shown.

The **Inspector** shows the composed widget configuration, defaults, source paths, provider output, graph samples, command stdout/stderr, timing, CPU time and failure/restart counts. Run a refresh, invoke the widget’s click command, or send an event. Inspecting a hidden provider resumes it while that inspector is visible. Closing the window restores its visibility policy.

The **Packages** tab reviews local folders and their declared commands, edits typed settings, installs versions and enables a chosen version. Select an older installed version to roll back.

## Built-in widgets

| Type | Content | Additional fields |
| --- | --- | --- |
| `workspaces` (or `aerospace`) | Occupied or visible workspaces on this display, with app icons; click to switch | — |
| `activeApp` | Frontmost app name and icon | — |
| `clock` | Local date/time, updated each minute, or each second when the format shows seconds | `format`: DateFormatter format |
| `text` | Static text and optional icon | `text` |
| `script` | Output of a shell command | `command`, `interval` in seconds or `null` for event-only updates |
| `provider` | Shared command, stream or native data | `provider`: key from the top-level `providers` object |
| `system`, `network`, `battery`, `audio` | Native CPU and memory, network, battery or audio output data | — |

The AeroSpace connection subscribes to workspace, monitor, window and focus events. It loads an initial snapshot, coalesces pending events and reconnects after a disconnect. The accent color marks the focused workspace; an outline marks a workspace visible on another monitor. Empty, inactive workspaces are hidden. App icons are deduplicated per workspace. Active-app updates come from NSWorkspace notifications.

### yabai workspaces

Set the source at the top level of your configuration:

```json
{
  "workspaceSource": "yabai",
  "widgets": [{ "id": "spaces", "type": "workspaces", "position": "left" }]
}
```

StableBar reads spaces, windows and displays at startup. Space numbers, app icons, focus animations, `workspace` styling and `"display": "active"` use the same view as AeroSpace. Clicking a space runs `yabai -m space --focus NUMBER`.

Add these [yabai signals](https://github.com/koekeishiya/yabai/blob/master/doc/yabai.asciidoc#signal) to `~/.yabairc` to refresh after changes:

```sh
for event in space_changed space_created space_destroyed display_changed display_added display_removed display_moved \
             window_created window_destroyed window_focused window_moved window_minimized window_deminimized \
             application_hidden application_visible system_woke; do
  yabai -m signal --add label="stablebar-$event" event="$event" \
    action='/Applications/StableBar.app/Contents/MacOS/StableBar --trigger yabai'
done
```

Adjust the app path if installed elsewhere, and include `--config PATH` before `--trigger` if you use a different configuration. Run `StableBar --trigger yabai` to refresh manually, or use **Reconnect yabai** in the bar menu.

## Create a widget

Add an entry to `widgets`:

```json
{
  "id": "my-widget",
  "type": "script",
  "position": "right",
  "command": "~/.config/stablebar/widgets/my-widget.sh",
  "interval": 30,
  "icon": "bolt",
  "onClick": "open -a 'Activity Monitor'",
  "style": {
    "background": "#22252b",
    "foreground": "#eeeeee",
    "width": 100,
    "cornerRadius": 8
  }
}
```

Commands run through `/bin/zsh -c` with your login shell's environment, which StableBar reads once at launch. Restart StableBar after changing `PATH` or other exported variables in your shell profile. Use absolute paths or `~` for your own scripts, and make them executable. Widgets can be written in shell, Python, Swift, Rust or anything that prints to stdout.

Return plain text, or one JSON object:

```json
{"text":"Ready","icon":"checkmark.circle","color":"#228844","tooltip":"All checks passed"}
```

`text` is required; the other output fields are optional:

- `hidden`: removes the widget when true (unless it has an error).
- `interval`: overrides the next polling delay in seconds; must be greater than zero. Omit it to use the configured interval.
- `menu`: an array of `{ "title": "Issue", "detail": "In progress", "onClick": "open …" }`, displayed in a themed popup. Rows without `onClick` show information. A menu takes precedence over the widget's click command. Static widgets can also define `menu` in their configuration.
- `value`: a graph sample, displayed on a 0–1 scale with the last 60 samples.
- `fields`: named display strings for popup field blocks.
- `lists`: named arrays of objects containing display strings for popup list blocks.

A nonzero exit, timeout, excessive output or invalid JSON preserves the previous output and adds a warning with the error in its tooltip. Repeated polling failures increase the retry delay exponentially up to five minutes, without shortening a configured interval longer than that. A successful update resets the delay; event-only scripts retry on their next event or action. A completed click action requests an immediate refresh. `onClick` runs only when clicked.

Commands have a 10-second timeout by default. Set a widget's `timeout` to another positive number of seconds; it applies to both updates and actions. Stdout and stderr are each limited to 1 MiB. Successful stderr logging does not corrupt the widget's stdout JSON. Failures display stderr, stdout, or the exit status when neither contains a message.

Commands must finish; do not start background daemons from widget scripts. Timeout, cancellation, and shutdown kill the command's process group and direct process. A descendant that deliberately starts another session or process group can outlive it, but cannot hold the widget's output pipe open past its timeout.

## Shared providers and native data

Define a provider once and reference it from several widgets. StableBar keeps one sampler or command process for all enabled consumers; each widget can use a different layout, popup, display and style. Provider output uses the same `text`, `fields`, `values`, `lists` and other fields as script output.

```json
{
  "providers": {
    "machine": { "type": "system", "interval": 2 },
    "music": {
      "type": "stream",
      "command": "\"$CONFIG_DIR/music-events\"",
      "interval": 2,
      "whenVisible": true
    }
  },
  "widgets": [
    {
      "id": "cpu", "type": "provider", "provider": "machine", "position": "right",
      "layout": { "type": "field", "field": "cpu" }
    },
    {
      "id": "memory", "type": "provider", "provider": "machine", "position": "right",
      "layout": { "type": "progress", "source": "memory", "style": { "width": 60 } }
    },
    {
      "id": "song", "type": "provider", "provider": "music", "position": "left"
    }
  ]
}
```

Provider `type` is `command`, `stream`, `system`, `network`, `battery` or `audio`. `command` and `stream` require a shell `command`. `interval` defaults to 5 seconds: the polling interval for commands and native sources, or the initial reconnect delay for streams. `timeout` defaults to 10 seconds and applies to command providers; streams remain running until they exit, fail, suspend or stop. Provider intervals and timeouts must be positive and finite.

A widget with `type` set to `system`, `network`, `battery` or `audio` uses the provider of that name. Without a definition in `providers`, it is a native provider of that type with default settings, shared by every widget that names it. Define a provider with the same name to change its interval or other settings. `{ "id": "power", "type": "battery", "position": "right" }` is enough for a battery widget.

Provider `environment` overlays the top-level environment. `NAME` is the provider name and `CONFIG_DIR` remains the main configuration directory. The environment of a consuming widget applies to that widget's actions, not the shared update process. Add `events` to a provider or consuming widget to request updates; one event refreshes a shared provider once. An explicit stream refresh restarts its process with the new event payload.

A stream writes one complete JSON object per line, including `text`, and flushes stdout after each update. Empty lines are ignored; the final line may omit its newline. Streaming output represents current state: when updates arrive faster than the UI consumes them, only the newest pending update is retained. Each line is limited to 1 MiB; stderr retains its latest 16 KiB. Malformed output stops the process and retains the last good value. Clean exits and failures reconnect with exponential backoff, capped at five minutes or the configured interval if longer. Ten seconds of successful streaming resets the failure streak.

Set `whenVisible` to `true` to suspend a provider when none of its consumers is visible on any display, including widgets moved to overflow. Removing or disabling the last consuming widget stops the provider. System sleep suspends scripts and providers; resuming preserves the last output and graph history, and starts a fresh update with `SENDER=resume`.

Native providers use public macOS APIs and launch no shell commands:

| Type | Output contract |
| --- | --- |
| `system` | `value` and `values.cpu`: CPU fraction; `values.memory`: used-memory fraction; `values.memoryUsed` and `values.memoryTotal`: bytes. `fields.cpu` and `fields.memory` are whole percentages. Used memory includes internal, wired and compressed pages, excluding purgeable pages. |
| `network` | `values.download` and `values.upload`: aggregate bytes/second across up `en*` Wi-Fi/Ethernet interfaces. `fields.interface`: interface names. `lists.interfaces`: rows with `name`, `download`, `upload`. Virtual VPN interfaces are excluded to avoid counting the same traffic twice. |
| `battery` | `value` and `values.percent`: charge fraction. `fields.percent`: whole percentage; `fields.state`: `charging`, `charged`, `battery` or `ac`; `fields.present`: `true`/`false`; optional `fields.timeRemaining`: minutes. Desktops without a battery return `AC` without a charge value. |
| `audio` | `value` and `values.volume`: output-volume fraction when supported. `fields.device`, `fields.deviceID`, `fields.volumeAvailable` and optional `fields.muted`; `lists.devices`: output-device rows with `id` and `name`. Fixed-volume devices can omit volume, and no output device returns `No output`. |

Fractions use 0–1. CPU and network rates are deltas; their first sample after startup or resume is zero. Native audio is a data source; use a control's `onChange` command to change volume or devices.

Scripts and providers expose diagnostics in the inspector and runtime query: running/suspended state, last event/start/update, execution duration, bounded stdout/stderr, execution/failure/restart counts and next retry delay. CPU time is cumulative completed-command CPU time, not a live resource meter for a running stream. Diagnostics and graph history survive style-only edits and suspension. The existing process-group cancellation limit for deliberately detached descendants also applies to streams.

## Adaptive layout and groups

Widgets keep their configured order within `left`, `notchLeft`, `center`, `notchRight`, and `right`. The center cluster shifts within the free space before anything overflows. On a notched screen, `center` widgets join the right side of the notch; neither side can use the other side's space.

Set `priority` on a widget to keep it visible longer; higher numbers win. The default is `0`. When space runs out, lower-priority widgets move to the **More widgets** menu. Equal priorities overflow from the end of the configuration first. The menu still opens their popups and runs their click actions. Workspaces remain selectable there. Widgets return automatically when space becomes available.

Use `"overflow": "never"` for essential widgets. If these alone exceed the available width, their containers scroll horizontally so the full content remains reachable. This is useful for a required workspace list on a narrow display.

```json
{
  "groups": {
    "system": {
      "style": {
        "background": "#202027",
        "paddingHorizontal": 4,
        "paddingVertical": 3,
        "borderColor": "#484850",
        "borderWidth": 1,
        "cornerRadius": 12,
        "spacing": 4
      }
    }
  },
  "widgets": [
    { "id": "app", "type": "activeApp", "position": "left", "style": { "minWidth": 80, "maxWidth": 200 } },
    { "id": "space", "type": "spacer", "position": "left" },
    { "id": "status", "type": "text", "text": "Ready", "position": "right", "group": "system" },
    { "id": "time", "type": "clock", "position": "right", "group": "system", "priority": 10 }
  ]
}
```

A named group has one shared background, padding, border and spacing. Members must use the same `position`; their first appearance places the group. A group overflows as one unit, takes its highest member priority, and stays visible if any member sets `overflow` to `never`.

A `spacer` uses the remaining width. Place it between widgets to separate them without choosing a fixed gap. Widget styles accept `minWidth` and `maxWidth` in addition to a fixed `width`.

The [interactive example](examples/interactive/config.json) combines groups, an expanding spacer, constrained text, and all popup controls. Copy both files from `examples/interactive` into your configuration directory. Its controls update demo state in `.control-state` next to the configuration; they do not alter macOS settings. The app list opens the selected application.

## Custom popups

Add `popup` to any widget. For a popup shared by multiple widgets, define it once in the top-level `popups` object and set each widget's `popupName` to its key. Each anchor uses its own script data. An inline `popup` takes precedence over `popupName`. It takes precedence over `menu` and `onClick`. Its layout is independent of the script, so you can change the layout without changing the data source or rebuilding the app. The example below uses the fields returned by the script output that follows it.

Widgets with `menu` entries already open a shared popup without additional configuration. To customize that popup, add `popup` with your preferred style and `"layout": { "type": "menu" }`. You can also place a `menu` block alongside other blocks in a custom layout. Entries retain their titles, details and click commands, and refresh while the popup is open.

```json
"popup": {
  "height": 240,
  "style": {
    "width": 360,
    "paddingHorizontal": 18,
    "paddingVertical": 18,
    "spacing": 12
  },
  "layout": {
    "type": "column",
    "children": [
      {
        "type": "row",
        "children": [
          { "type": "text", "text": "CPU usage" },
          { "type": "field", "field": "usage", "alignment": "trailing", "style": { "fontSize": 28 } }
        ]
      },
      { "type": "graph", "height": 80 },
      { "type": "button", "title": "Activity Monitor", "onClick": "open -a 'Activity Monitor'" }
    ]
  }
}
```

`style` and `layout` are required. Use `"style": {}` to inherit the widget's theme. Without `height`, a popup fits its content when it opens; set `height` for a fixed size. Popup colors, typography, borders, corners and shadow inherit widget styles and then global defaults. Popup width defaults to 360 points independently of the bar widget width; set it with `popup.style.width`. Padding and spacing can be overridden separately. Height is capped to the space below the bar; long content scrolls.

Layout blocks:

| `type` | Required fields | Content |
| --- | --- | --- |
| `row` | `children` | Blocks arranged horizontally |
| `column` | `children` | Blocks arranged vertically |
| `text` | `text` | Static text |
| `field` | `field` | A string from the script's `fields` object, or the current list row |
| `graph` | `height` | The widget's existing 60 samples on the 0–1 scale; optional `source` reads `series[source]` instead and `lineWidth` sets stroke width |
| `list` | `source`, `row` | Repeat the `row` block for each object in `lists[source]` |
| `button` | `title`, `onClick` | Run a command and close the popup |
| `slider` | `title`, `source`, `onChange` | Native slider; reads `values[source]` or numeric `fields[source]`. `min`, `max`, `step` default to 0, 1, 0.01. |
| `toggle` | `title`, `source`, `onChange` | Native toggle; true for `"true"`/`"1"` in fields or 1 in values. |
| `segmented` | `title`, `source`, `options`, `onChange` | Native segmented picker. Options are `{ "title": "Label", "value": "id" }`; selection reads `fields[source]`. |
| `search` | `title`, `source`, `row` | Text field and filtered rows from `lists[source]`. `searchFields` limits matching to named fields; omitted searches all row values. |
| `menu` | — | The widget's script or configured menu entries, with their existing actions |
| `divider` | — | A horizontal rule |
| `image` | `path` or `source` | Local path, `file://`, or HTTP(S) image; `source` reads a path from `fields`. `fit` is `fit` or `fill`; size defaults to 52 × 52. |
| `symbol` | `name` or `source` | SF Symbol; `source` reads its name from `fields`. `style.iconSize` sets its size. |
| `progress` | `source`, `height` | A rule using `values[source]`, optionally moving toward `targets[source]`. `style.accent` is the fill and `style.background` the track. |

Every block accepts `style` and `alignment` (`leading`, `center`, `trailing`). Fonts, text color, accent and spacing inherit from the containing block. Width, padding, background, hover background and border apply only when set on that block. Set a width on numeric fields and their headings to align columns. Blocks without a width use the available space.

Text and field blocks can set `scrollSpeed` in points per second with a fixed `style.width`. Overflow scrolls back and forth with a pause at each end; fitting text and Reduce Motion do not scroll. `hideWhenEmpty` names a field: the block occupies no space when that field is absent or empty, which is useful for optional list-row headings and pipeline details.

Display blocks can also have `onClick`, or `onClickField` to read a command from the current fields/list row. This allows a symbol button or a clickable agenda row. A popup accepts `alignment` (`leading`, `center`, `trailing`) and `offset` for placement relative to its widget. A popup's optional `animation` controls its opening/closing fold and fade. Reduce Motion keeps only the fade. Native panel animation maps `smooth` and `spring` to ease-in-out; other curves retain their names. `dismissOnAction` defaults to `true`; set it to `false` for player controls that should keep the popup open. Images load asynchronously and update when their source path changes. Use a different local filename for each cover, or supply its URL.

Controls pass their new value in the `VALUE` environment variable with `SENDER=control.changed`. Sliders send a number when editing ends, toggles send `true` or `false`, and segmented controls send the selected option's value. Read it as `"$VALUE"` in a shell command; StableBar never inserts the value into command text. Completed actions refresh the widget's data. Controls stay open by default; set `popup.dismissOnControl` to `true` to close after a change. `dismissOnAction` still controls buttons and list rows independently.

Controls support native keyboard traversal, and Escape closes the popup. Search filters locally without running a command; matching ignores case and accents. Use `searchFields` to avoid matching command text or other hidden row fields.

For example, a script can return:

```json
{
  "text": "30%",
  "value": 0.3,
  "fields": { "usage": "30%", "load": "3.2 2.8 2.1" },
  "lists": {
    "processes": [
      { "name": "WindowServer", "pid": "423", "cpu": "90.1%", "memory": "108 MB" }
    ]
  }
}
```

Field and list values are display strings; scripts supply units and formatting. Missing fields display `—` and missing lists are empty while data loads. Values and graphs update while the popup stays open. Click the widget again, click outside, or press Escape to close it. Saving configuration closes the popup; reopen it to see the new layout. Style and layout changes keep healthy scripts and their graph history running.

Add the popup to the script widget that returns those fields.

For new native widget types, add a case to `WidgetContent`, decode its settings in `WidgetConfiguration`, and render it in `WidgetView.content`. New popup components belong in `PopupContent` and `PopupBlockView`. Runtime SwiftUI plugins and arbitrary chart types are not implemented.


## Architecture

- [Configuration.swift](Sources/StableBar/Configuration.swift): config, widget definitions and style inheritance.
- [BarStore.swift](Sources/StableBar/BarStore.swift): live reload, shared provider lifetimes, visibility and sleep.
- [ConfigurationLoader.swift](Sources/StableBar/ConfigurationLoader.swift): includes, profiles, tokens and provenance.
- [ConfigurationEdits.swift](Sources/StableBar/ConfigurationEdits.swift): file-preserving edits shared by CLI and editor.
- [RuntimeControl.swift](Sources/StableBar/RuntimeControl.swift): local request/reply control endpoint.
- [ConfigurationEditor.swift](Sources/StableBar/ConfigurationEditor.swift): preview, undo/redo and validated persistence.
- [NativeMetrics.swift](Sources/StableBar/NativeMetrics.swift): public macOS metric sources.
- [WidgetPackage.swift](Sources/StableBar/WidgetPackage.swift): local package inspection, installation and version selection.
- [Workspaces.swift](Sources/StableBar/Workspaces.swift): AeroSpace subscriptions, yabai refreshes and workspace actions.
- [Yabai.swift](Sources/StableBar/Yabai.swift): yabai snapshots mapped to workspaces and screen numbers.
- [ScriptWidget.swift](Sources/StableBar/ScriptWidget.swift): custom widget output and refresh tasks.
- [BarView.swift](Sources/StableBar/BarView.swift): native rendering and selection animation.
- [LayoutConfiguration.swift](Sources/StableBar/LayoutConfiguration.swift): groups, priority overflow and notch-aware placement.
- [PopupConfiguration.swift](Sources/StableBar/PopupConfiguration.swift): popup layout blocks.
- [PopupView.swift](Sources/StableBar/PopupView.swift): shared popup rendering and script bindings.
- [WidgetPopup.swift](Sources/StableBar/WidgetPopup.swift): anchored panel, dismissal and screen placement.
- [StableBarApp.swift](Sources/StableBar/StableBarApp.swift): non-activating panels and application lifecycle.

There is no web view, custom drawing loop or private window-server API. Styling and data updates are separate from window placement. Performance and long-term stability still need measurement with your actual widgets and displays.

## Releases

Pull requests run `swift test` on macOS and check that every commit message, and the pull request title, follows [Conventional Commits](https://www.conventionalcommits.org). Squash merges use the title as the commit message.

After the tests pass on `main`, [semantic-release](https://github.com/semantic-release/semantic-release) reads the commits since the last tag and decides the next version:

| Commit | Release |
| --- | --- |
| `fix:`, `perf:` | Patch: 0.1.0 → 0.1.1 |
| `feat:` | Minor: 0.1.0 → 0.2.0 |
| `feat!:`, or a `BREAKING CHANGE:` footer | Major: 0.1.0 → 1.0.0 |
| `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, `test:` | None |

A release sets `CFBundleShortVersionString` and `CFBundleVersion` in [Resources/Info.plist](Resources/Info.plist) with `scripts/set-version.sh`, adds its notes to `CHANGELOG.md`, commits both as `chore(release): <version>`, tags `v<version>` and publishes the notes as a GitHub release.

## Agent skills

Skills for coding agents live in [.agents/skills](.agents/skills), one folder per skill with a `SKILL.md`. Codex reads that directory, and `.claude/skills` links to it for Claude Code. Invoke a skill by name (`/triage` in Claude Code, `$triage` in Codex) or describe the task and let the agent choose it.

| Skill | Use |
| --- | --- |
| [triage](.agents/skills/triage/SKILL.md) | Checks a bug report or feature request against issues, pull requests, `main` and releases, and drafts a GitHub issue when nothing covers it. It posts only what you asked it to file or approved. |

To add a skill, create `.agents/skills/<name>/SKILL.md` with `name` and `description` front matter.

## License

StableBar is available under the [MIT License](LICENSE), including commercial use and redistribution.
