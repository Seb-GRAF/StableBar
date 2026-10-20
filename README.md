# StableBar

A native, configurable macOS bar built with Swift, AppKit and SwiftUI. One persistent panel per display holds the widgets; workspace changes update their contents without recreating windows.

The default configuration includes a System Settings shortcut, the active app and a clock. It needs no accounts, network services or third-party tools, though windows can extend under the bar without a tiling window manager (see [Keeping windows clear of the bar](#keeping-windows-clear-of-the-bar)). Optional shell widgets use a plain-text or JSON output protocol.

## Install and set up

Open `StableBar.dmg`, drag StableBar to Applications, then open the app. Setup introduces the bar, lets you choose its appearance and placement, offers useful widgets, then reviews access and changes before you apply them. Reopen it with **Getting Started…** in the menu-bar icon's menu, or **Customize StableBar → Settings → Getting started**.

Widgets are the items on your bar. Packages provide extra widgets or themes. After setup, **Arrange my bar** opens editing on the desktop; **Customize widgets** opens **Your bar**, where you can change content, appearance and behavior. The menu-bar icon also links to this user guide.

Setup shows your current theme, appearance, placement and clock. **Keep current** leaves a setting untouched. Choose from the [themes](#themes) that ship with StableBar or those you have installed; **Light**, **Dark** and **Automatic** control the bar's appearance. The preview includes active profiles, and a warning names any profile that still controls a setting, with a button to edit it. Setup saves your defaults and preserves custom widgets, scripts and imported files.

New configurations place the bar below the macOS menu bar; existing configurations retain their position. This placement keeps the menu bar visible but does not reserve space for windows. Setup offers **Keep windows clear of StableBar** and **Keep notifications clear of StableBar**, explains their Accessibility requirement, and gives separate guidance when it detects AeroSpace or yabai. See [Keeping windows clear of the bar](#keeping-windows-clear-of-the-bar).

Choose optional sets of [built-in widgets](#built-in-widgets): **System** shows CPU and memory use with details in its popup; **Meetings** shows your next meeting and today's agenda; **Workspaces** appears when AeroSpace or yabai is on your login shell's `PATH`. Workspaces prefers your configured source and uses the other one when only that one is installed; yabai still needs [its signals](#yabai-workspaces). The sets use native providers and run no scripts. Existing matching widgets are marked **Already added**; selecting a turned-off matching widget enables it while preserving its settings. A different widget with the same ID is kept, and its card explains the conflict. Active profile overrides still apply.

The starter bar needs no special access. Setup lists only the access used by enabled widgets and clearance options, shows its current status and offers a permission action or System Settings link. Status updates when you return from System Settings. A newly chosen Meetings widget uses sample events in the preview. Allow Calendar access in setup, or choose **Set up Meetings later**: finishing without access saves that widget turned off, so it does not prompt immediately after setup. Enable it later in **Your bar**. Existing calendar widgets stay unchanged. Scripts that control other apps ask for Automation access when used; AeroSpace and yabai manage their own Accessibility permission.

Bar settings and **Open at login** are staged until **Apply setup**. Closing the window before then discards those choices; permission buttons act immediately through macOS. Open at login is off until enabled and requires the app to be in Applications. If macOS requires Login Items approval, setup shows the remaining action. A setup that has never been completed opens again on the next launch; you can always reopen it from Settings.

## Build and run

Requires macOS 14+ and Xcode's Swift 6 toolchain. Optional workspace widgets require AeroSpace 0.21+ or yabai on your login shell's `PATH`.

Quit the running app before rebuilding its bundle.

```sh
./scripts/build.sh
open dist/StableBar.app
```

Local app builds show **Development** in **Customize → Settings → About and updates**, with the source revision and a `-dirty` suffix when the checkout has changes. A local rebuild of beta source is still a development build; install the beta DMG for its published version and build number.

For development checks:

```sh
swift test
```

The first launch creates `~/.config/stablebar/config.json` from [Resources/config.json](Resources/config.json), with an offset for your menu bar. Subsequent launches keep your file. If it is a symbolic link, Setup, Customize and command-line saves update the linked file and keep the link. Right-click the bar or use its macOS menu-bar icon to open **Customize StableBar**, **Try Themes…**, **Edit Bar** or quit. While editing, the menus offer **Finish Editing Bar**. **Customize → Settings** controls login, placement, access and workspace connections, opens or reloads the configuration file, and links to setup and help.

### Download a release

Stable releases after v0.4.0 on the [releases page](https://github.com/Seb-GRAF/StableBar/releases) include `StableBar.dmg`. Betas of the next version are marked **Pre-release**. Both are built for Apple silicon. Releases signed with a Developer ID are notarized and open like any app. Earlier ones are ad-hoc signed, so macOS blocks them the first time you open them: allow it in **System Settings → Privacy & Security → Open Anyway**.

### Updates

A release signed with a Developer ID checks GitHub for a newer version shortly after launch and every four minutes. These silent checks pause while an update check, offer, download or installation is already active, and stop making requests when automatic checks are off. A failed check retries at the next interval. Sparkle still chooses the compatible release and handles its download and installation. As soon as a check finds one, an **Update** tile fades in at the right end of the bar and moves the neighboring widgets aside, in your theme's style. Reduce Motion disables that animation. Click it to see what's changed and **Download** the update, then **Install and Relaunch** once it's downloaded. The popup grows to show download and preparation progress while keeping its width and top edge in place. **Check for Updates…** in the menu-bar icon's menu or in **Customize → Settings → About and updates** checks right away and remains available while an update waits. **Customize → Settings → About and updates** also turns off automatic checks, or lets StableBar download updates and install them when it quits.

**Update track** chooses the releases you get. **Stable** gets stable releases. **Beta** gets betas of the next version and stable releases, whichever is newer. An installed beta starts on Beta. Switching back to Stable keeps your beta until a newer stable release is out, because StableBar never installs an older version.

Beta version names include a UTC timestamp and build number, such as `0.5.0-beta.20261020103000.114`, to keep new betas in order on GitHub. In-app updates compare the build number.

Only an app signed with a Developer ID updates itself, because the update must be signed by the same developer as the app it replaces. Ad-hoc signed releases and the builds you make yourself don't check for updates; **Customize → Settings → About and updates** links to the releases page instead.

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

macOS provides no public API for a custom bar to reserve screen space. Without a tiling window manager, enable **Customize → Settings → Displays and placement → Keep windows clear of StableBar** (`bar.keepWindowsClear`, off by default) and allow StableBar in **System Settings → Privacy & Security → Accessibility**. StableBar then moves overlapping ordinary windows below the bar and reduces their height when needed to keep them above the Dock. It follows each display's bar height, offset and scale, and waits until you finish dragging before adjusting a window. See [the window clearance example](examples/window-clearance/config.json).

Native fullscreen windows, minimized windows and dialogs are left alone. Some apps do not expose movable or resizable windows, or enforce a minimum size that cannot fit; StableBar cannot keep those clear. Disabling the option stops adjustments and leaves windows where they are. Revoking Accessibility access pauses adjustments; granting it resumes them. A locally rebuilt, ad-hoc signed app may need to be authorized again.

Leave this option off when another window manager controls your gaps. With AeroSpace, set `gaps.outer.top` in `~/.aerospace.toml` to the bar's panel height (40 by default), plus any `bar.offset` beyond the menu bar; AeroSpace accepts per-monitor values. yabai users can set `external_bar` with the same clearance. A below-bar underline adds its maximum configured gap plus thickness beyond the existing bottom margin. For example, a 38 pt bar with no margin, a 2 pt underline and a 3 pt gap needs 43 pt. With display scale `s`, round upward to whole screen points: `max(ceil(height × s), ceil(height × s − margin + maximum gap × s) + ceil(maximum thickness × s))`. StableBar reserves this maximum across states, so focus or mode changes never move windows or resize panels.

On macOS 26, enable **Customize → Settings → Displays and placement → Keep notifications clear of StableBar** (`bar.keepNotificationsClear`, off by default) to move notification banners 16 points below the bar on the display that shows them. It uses the same Accessibility access and can stay on with AeroSpace or yabai. The Notification Center panel and desktop widgets stay where macOS puts them. This depends on Notification Center's Accessibility structure and does not support macOS 14 or 15.

## Layout and style

Save the configuration to apply changes. Direct saves and atomic file replacements are watched, including files imported with `includes`. Invalid edits retain the last working configuration and show an error indicator; click it to open Customize StableBar, which shows the error. Script instances, their last output, and graph history survive style-only changes, including when a script has an error.

Unknown properties are errors, so a misspelled key cannot be silently ignored. The last working configuration stays in place and the error names the property, for example `widgets.clock: style.fontsize: Unknown property.` For completion and validation in editors that support JSON Schema, start a configuration file with:

```json
"$schema": "https://raw.githubusercontent.com/Seb-GRAF/StableBar/main/stablebar.schema.json"
```

- `bar`: `height`, `offset`, `margin`, `inset`, `spacing`, `background`, `animationDuration` (seconds), `displayScale`, `appearance` (`light` or `dark` keeps the bar and its popups in that appearance; omit it to follow the system).
- `defaults`: styles inherited by every widget.
- `popupDefaults`: styles inherited by every popup, over `defaults`.
- `workspaceSource`: `aerospace` (default) or `yabai`, for workspace widgets and active-display tracking.
- `widgets`: ordered widget definitions with unique `id`, `type`, `position` and optional `style`, `icon`, `onClick` or `open`, `menu`, `popup`.
- `position`: `left`, `notchLeft`, `center`, `notchRight` or `right`.
- Colors: `#RRGGBB` or `#RRGGBBAA` (alpha last), or `{ "light": "#RRGGBB", "dark": "#RRGGBB" }` for a color that follows the light or dark appearance.
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

Include paths are relative to the file that names them; absolute paths and `~` also work. Includes can have their own includes. Files apply in listed order, followed by the containing file. Objects merge recursively, with later values winning. Arrays replace earlier arrays, except top-level `widgets`, which concatenate in order, `packages`, whose selections merge by package ID, and `profiles`, which merge by name. Root package selections can disable or change versions inherited from includes. Modules can contain only a theme, templates, popups, environment variables, or overrides; they do not need widgets.

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

[examples/modular](examples/modular/config.json) is a complete, dependency-free starter with a theme that styles the shared data states, a template, an event-only status that fades in new text, a CPU widget whose rules set those states, a clock whose digits roll, and an optional volume widget that shows the volume for a moment after a scroll or click, or when `volumeChange` reports a change made elsewhere. Try it without replacing your personal configuration:

```sh
./dist/StableBar.app/Contents/MacOS/StableBar --validate examples/modular/config.json
./dist/StableBar.app/Contents/MacOS/StableBar --config examples/modular/config.json
```

From another terminal, run `./dist/StableBar.app/Contents/MacOS/StableBar --trigger demo 'INFO=Build finished'`. The status changes to the supplied text. Enable the sample volume widget through its override to use click-to-mute and scroll-to-adjust.

Each widget can override any of these styles:

`foreground`, `background`, `hoverBackground`, `borderColor`, `borderWidth`, `cornerRadius`, `fontName`, `fontSize`, `fontWeight`, `iconSize`, `paddingHorizontal`, `paddingVertical`, `spacing`, `width`, `accent`, `accentText`, `shadowRadius`, `shadowColor`.

`fontName` is `system` or an installed font name. `fontWeight` is `regular`, `medium`, `semibold` or `bold`. Set `width` on frequently changing widgets to keep their footprint stable. Without a `width`, the active app widget animates to fit each app's name, and the widgets beside it slide along. The workspace highlight uses `accent` and `accentText`; its motion respects Reduce Motion. Set `animationDuration` to `0` to remove transition time.

Styles also accept `hoverForeground`, `height`, `paddingLeading`, `paddingTrailing`, `paddingTop`, `paddingBottom`, `offsetX`, `offsetY` and `opacity`. Side-specific padding overrides horizontal/vertical padding. `ultralight`, `thin` and `light` font weights are available too. Offsets move the drawing without moving its neighbours.

### States

Any style can have `states`: styles that apply over it while a state is active. A state needs only the properties that change:

```json
{
  "defaults": {
    "background": "#25252c",
    "states": { "hover": { "background": "#383842" } }
  },
  "widgets": [
    {
      "id": "status", "type": "text", "text": "Ready", "position": "left",
      "style": { "states": { "hover": { "foreground": "#69d2b0", "borderColor": "#69d2b0" } } }
    }
  ]
}
```

`hover` is active while the pointer is over a bar widget, a workspace cell or a layout block, on that display only. The `open` state is active on a bar widget, its layout and its overlay while its popup shows, on the instance that opened it: not on its copies on other displays, and not when the popup opened from the More widgets menu. A block's own background, border, padding, size, offset and opacity change for `open` only through that block's own `states`. Workspace cells also have a workspace state; see [Workspace appearance](#workspace-appearance). Script and provider widgets can have a data state; see [Data states](#data-states). States apply in a fixed order, later ones winning: the data state, the workspace state, `mode`, `mode.<alias>`, `hover`, then `open`, so an `open` style stays visible while the pointer rests on its widget. A state's style can have its own `states`, which refine later states while both are active: `states.focused.states.hover` styles the focused workspace under the pointer. `bar.style` consumes mode states; group states remain inactive.

`hoverBackground` and `hoverForeground` are shorthand for `states.hover.background` and `states.hover.foreground`. In each style, such as `defaults` or a widget's `style`, the two are compared after includes, packages, themes, templates, widget overrides and profiles merge, so a `states.hover.background` from any layer wins over `hoverBackground` from any layer, and likewise for the foreground; to override a lower layer's hover state, set `states.hover.background`. Customize's **Hover background** rows handle this for you: they set `hoverBackground` and set `states.hover.background` to `null` beside it, so the color you pick wins over a lower layer's hover state but not over an active profile's `hoverBackground`. A hover without a background keeps the background. In a widget's `layout` and `overlay` and in popups, `hover` changes a block's text color and its own background, border, padding, size, offset and opacity. A widget without `layout` draws its default layout with all of its `hover` and `open` styles.

A widget's states merge with those in `defaults`, and every style's states merge through includes, templates, profiles and widget overrides one state and property at a time: a widget's `states.hover.foreground` keeps the theme's `states.hover.background`. Set a state to `null` in a later layer to remove it at the same place: in `defaults` through includes, profiles and packages, and in a widget's `style` through its templates, widget overrides and package widgets. A hover set with `hoverBackground` or `hoverForeground` comes back from the shorthand, so set those to `null` too. Nothing set on a widget (its `style`, a template, a widget override or script output) can remove a state set in `defaults`. A state wins over the base style, so a theme's states also show on widgets that set their own colors.

The bar measures widths without `hover` and `open`, so use them for colors, borders, opacity and offsets rather than sizes.

With `workspaceSource: "aerospace"`, `mode` is active while connected in any binding mode other than `main`. Map your local mode names to semantic aliases in your configuration; themes own the matching appearance:

```json
{
  "modeAliases": { "tailing": "command" },
  "bar": { "style": { "states": {
    "mode.command": { "borderEdges": "all", "borderColor": "@token.warning" }
  } } }
}
```

An unmapped non-main mode activates only `mode`. Aliases start with a letter and contain letters, digits, `_` or `-`; a null mapping clears an inherited mapping. Themes and widget packages cannot define `modeAliases`. The initial mode is read on connect and reconnect, even without a workspace widget; disconnect, stop or switching to yabai clears it. Mode changes update presentation and send `aerospaceMode` to subscribers without reloading configuration or closing popups. Theme/configuration changes still close popups; reopening uses the new theme. A mode state beats a script's plain `barStyle`, and leaving the mode restores the remaining layers, border edges included.

**Migration:** `mode` and every `mode.*` name are reserved. Rename custom output/rule data states that used these names. Previously ignored `bar.style.states.mode` and `mode.<alias>` rules now apply. Script colors still use literal colors; put token-based mode colors in configuration or a theme. Use `--batch '[{"action":"modeAliases","properties":{"tailing":"command"}}]'` to edit mappings through the shared CLI editor. `--query` and Status include the connected mode, active mode states and configuration origins.


### Presentation roles and workspace defaults

`role` is an explicit annotation on a widget or any layout/popup block. The allowed names are `time`, `primary`, `secondary`, `key`, `value`, `heading`, `button`, `meter` and `separator`; unknown names are errors. Nothing selects widgets by type or ID. In particular, two `clock` widgets can use `time` and `secondary` independently. Omitting a role keeps the existing style; Built-in supplies an empty fallback for each role.

```json
{
  "roles": { "time": { "fontName": "Helvetica Neue", "fontSize": 16, "fontWeight": "light" } },
  "workspaceDefaults": {
    "indicator": "underline",
    "indicatorStyle": { "placement": "belowBar", "height": 2 },
    "style": { "fontSize": 13 },
    "appStyle": { "fontSize": 14 }
  },
  "widgets": [
    { "id": "time", "type": "clock", "format": "HH:mm", "position": "right", "role": "time" },
    { "id": "date", "type": "clock", "format": "EEE d MMM", "position": "right", "role": "secondary" }
  ]
}
```

A selected theme can style any subset of roles. Configuration files, includes and profiles can override those styles. Widget packages (including command-capable packages) may annotate widgets and blocks, but cannot define global `roles`, `workspaceDefaults` or `modeAliases`. Role styles accept only style properties: they cannot change actions, providers, visibility, display filters or the row/column structure of a layout.

Layers apply from lowest to highest:

| Element | Base layers |
| --- | --- |
| Bar widget | `defaults` → `roles[role]` → widget `style` → output `widgetStyles` in configuration order → own output `style`/`color` |
| Layout/popup block | inherited text style → `roles[role]` → block `style` → named output style selected by `styleSource`/`styleField` |
| Popup panel | `defaults` → `popupDefaults` → widget's explicit `style` → popup `style`; the bar widget's role is excluded |
| Workspace | `workspaceDefaults` → widget `workspace` |
| Bar strip | `bar.style` → script `barStyle` in configuration order |

Active states apply after the base layers in the order documented above. An explicit widget font beats its role's base font; an active state still beats base values. Role box properties (background, border, padding, dimensions and offsets) apply only to that block. Only the role’s typography, foreground, accent and spacing pass to its children, including their nested states; other inheritance is unchanged. Popups keep ignoring widget data states; they can use mode states in their own base layers and annotated blocks. Put bar-only mode styling in a role or `bar.style` rather than `defaults`.

`workspaceDefaults` permits only `indicator`, `indicatorStyle`, cell `style` and `appStyle`. Widget-level values merge over them, including legacy `focusedStyle`/`visibleStyle`/`focusedAppStyle` aliases; explicit `states` in the same widget still beat its shorthand. Local app-glyph mappings and workspace visibility choices remain widget-owned. Existing include/template/profile/package merge rules apply. Null clears a property within a composed map; a missing/cleared role style falls back to the inherited style. Widget styles retain their existing inheritance semantics.

**Migration:** opt in by adding roles to the time clock, a separate date clock, and popup blocks you want themed. Remove explicit fonts/colors when you want the role to control them. An explicit widget font still reaches its popup; a `time` role font does not. Keep music-popup rows/columns in the widget definition so every theme can style that same structure. Existing `widgetStyles` overrides, including a legacy self-targeted override, remain supported below the widget's own output style.

Customize's **Your bar** section has a role picker and workspace indicator controls. **Appearance** edits role styles, workspace defaults, border edges and your mode mappings; theme cards show sample widgets and the workspace indicator. **Profiles** can override these maps through its JSON editor. The shared CLI uses `roles`, `workspaceDefaults` and `modeAliases` batch actions; `set` assigns a widget's role or layout/block roles. **Status**/`--query` report the role, resolved style, ordered layers and source/token origins.

### Data states

A data state says what a widget's data means, such as a battery running low, so its look can come from the theme. A script, or a command or stream provider, sets it with `state` in its output, for example `{"text":"12%","state":"warning"}`; the next output without `state` clears it. Use these shared names so themes and widget packages agree without hard-coded colors:

| State | Meaning |
| --- | --- |
| `warning` | Needs attention soon, such as a battery at 20 % |
| `critical` | Needs attention now, such as memory at 95 % |
| `active` | On or in progress, such as charging or recording |
| `muted` | Off or quiet, such as muted audio |

Other names work too. `hover`, `open`, `focused`, `visible`, `empty`, `mode` and every `mode.*` name are StableBar's own, so output `state` with one of those names, or an empty one, is ignored. Define each state once in `defaults.states`:

```json
"defaults": {
  "states": {
    "warning": { "foreground": "#f5b041" },
    "critical": {
      "foreground": "#ffffff", "background": "#c0392b",
      "states": { "hover": { "background": "#a93226" } }
    },
    "active": { "foreground": "#69d2b0" },
    "muted": { "opacity": 0.5 }
  }
}
```

A widget's own `states` override the theme's property by property. The data state applies first, so `hover` and `open` still show over it. Hover applies over the data state, so a state that sets a background should also set its hover background in its own `states`. A data state also reaches the widget's `layout` and `overlay` blocks, which apply their own `states` for it. Popups keep their own styles.

Native providers can't return `state`, so a widget can set it with `rules`. The first rule that matches the latest output sets the state; a `state` in the output takes precedence:

```json
{
  "id": "power", "type": "battery", "position": "right",
  "rules": [
    { "when": { "value": "percent", "below": 0.1 }, "state": "critical" },
    { "when": { "value": "percent", "below": 0.2 }, "state": "warning" },
    { "when": { "field": "state", "equals": "charging" }, "state": "active" }
  ]
}
```

`when` compares one entry of the output: `value` names a number in `values`, which matches `below` when it is at or below that number and `above` when it is at or above it (give both for a range); `field` names a string in `fields`, which matches `equals` exactly. A missing value or field doesn't match. Rules are checked when output arrives and belong to the widget, so widgets that share a provider can use different thresholds. Only script and provider widgets accept rules.

### Theme tokens and automatic profiles

Define reusable JSON values in `tokens` and reference them with a whole string such as `"@token.accent"`. Values retain their type: a token can supply a number, boolean, array, object, or string. Tokens can reference other tokens; unknown names and cycles reject the change while the current configuration keeps running. References are not interpolated inside shell commands or other strings.

```json
{
  "tokens": { "accent": { "light": "#db733f", "dark": "#ffa66b" }, "fontSize": 12 },
  "defaults": { "accent": "@token.accent", "fontSize": "@token.fontSize" },
  "profiles": [
    {
      "name": "laptop",
      "when": { "onBattery": true, "displayCount": 1 },
      "configuration": { "bar": { "height": 34 }, "tokens": { "fontSize": 11 } }
    }
  ],
  "widgets": [{ "id": "clock", "type": "clock", "position": "right" }]
}
```

A color token can hold a light and dark pair, as `accent` does here, so it follows the appearance without a profile.

Profiles match `appearance` (`light` or `dark`: `bar.appearance` when set, otherwise the system's), `onBattery`, `displayCount`, `externalDisplay`, and the focused app's bundle identifier in `app`. Conditions in one profile must all match.

Profiles merge by name across packages, themes, includes and the main file. Later values merge recursively into an existing profile without moving it; new names append in order. Matching profiles apply in that order after modules and the root configuration; later profiles win. Set `"enabled": false` on a profile to skip it, even when pinned, or `true` to enable it again. An override can contain only its `name` and the properties to change, for example `{"name":"dark","enabled":false}`.

A profile without `when` always matches. A profile that sets `bar.appearance` changes how the bar looks, not which profiles match. Widgets in profiles append to the bar; use `widgetOverrides` to change existing widgets. Appearance, power, screen and focused-app changes update the active profiles automatically.

Set `"profile": "laptop"` to apply only that profile, regardless of its conditions. Remove `profile` to resume automatic matching, or set it to `null` to override a manual profile inherited from a module. **Customize → Status** reports active profiles and the file, template, override and token sources behind effective widget properties.

In **Customize StableBar → Profiles**, add profiles, edit their conditions, or choose Automatic matching or a pinned profile. The active profiles appear in order; later ones take priority. Each row shows whether it is active, inactive or disabled, and **Enabled** turns it on or off. **Common settings** edits bar height, offset, appearance and default widget font size. Fields name values this profile already sets; an unset number shows the current bar's value. Changing it saves an override in the selected profile. Automatic appearance follows macOS, including when the base configuration sets Light or Dark.

Other settings remain available in **Technical details**, where the configuration JSON has an explicit **Apply configuration** action. Removing an inherited property from that JSON writes a null override; it does not restore inheritance. Common controls save automatically and can be undone or redone. Adding or editing a profile saves only the new profile or changed properties into the main file; unchanged profiles and properties continue to follow their source files. Included files stay unchanged. Set a condition to Any to clear an inherited condition.

Setup, the editor and the command line save changes into the main file's ordinary keys and never edit imported files. A widget defined in the main file, including inside one of its profiles, is changed, removed or reordered where it is defined. A widget from an include or package gets an entry in the main file's `widgetOverrides`; removing it sets `enabled` to `false`. Bar and default-style changes merge into `bar` and `defaults`. Untouched parts of the file keep their formatting and key order. An active profile still applies on top of these changes.

When every widget comes from the main file's `widgets` array, reordering changes that array. Otherwise the order is saved in `widgetOrder`: listed IDs come first, unlisted widgets keep their relative order, and IDs that are not currently present, such as widgets of an inactive profile, are skipped.

Earlier versions saved changes in `customization` and `removedWidgets`. StableBar converts those keys into the ordinary ones the next time it starts. Earlier versions also wrote setup's appearance colors and the starter configuration's accent into `defaults`, where they hid any theme. The first time this version starts, StableBar replaces setup's Light and Dark colors with `bar.appearance`, removes the `null` widget colors that setup's Automatic choice wrote, since `null` now means no color, and removes the starter's `#007aff` accent. Colors you set yourself stay.

### Local widget packages

Open **Customize → Library → Open package folder…** to review a local package. Its page lists the included widgets, setup fields, requirements and commands. A block with `onClickField` is listed by the field it reads its command from. **Add to bar** installs the package if needed and enables it after review; **Use theme** selects a theme. The command-line install operation only installs files and never enables a package.

**Browse** and **Installed** organize the Library, with search by name, description or ID. Installed versions are grouped under one package; **Versions and technical details** lets you select an older version, then add it to roll back the pin. Compatible settings carry over; a value that a new version no longer accepts falls back to that version's default. Settings for an active package save automatically and support Undo. Setup drafts for a package you have not added, another version and unsaved credentials survive navigation within Customize.

A package is a folder containing `package.json`, its configuration, and any scripts or assets. [examples/packages/local-clock](examples/packages/local-clock/package.json) is a working package using a bundled script. Its manifest has this shape:

```json
{
  "id": "local-clock",
  "name": "Local clock",
  "version": "1.0.0",
  "entry": "config.json",
  "settings": {
    "format": {
      "type": "string",
      "title": "Time format",
      "description": "Choose whether the clock includes seconds.",
      "choices": ["%H:%M", "%H:%M:%S"],
      "default": "%H:%M"
    },
    "fontSize": { "type": "number", "title": "Font size", "default": 12 }
  }
}
```

Settings support `string`, `number`, `bool` and `secret`. The first three need a matching `default`. An optional `description` explains a field in the interface. String settings can declare a nonempty `choices` array to show a picker; both the default and supplied values must be among those choices. [package.schema.json](package.schema.json) describes the manifest and setting fields; StableBar also validates their types and allowed values. Reference a setting as a whole value, such as `"fontSize": "@setting.fontSize"` or `"environment": { "FORMAT": "@setting.format" }`. Put settings needed by shell commands in environment variables and quote them normally in the script.

A `secret` setting, such as `"token": { "type": "secret", "title": "GitHub token" }`, holds an API token and has no `default` or `choices`. Reference it only as a whole value in the `environment` of a widget or provider the package defines, such as `"environment": { "GITHUB_TOKEN": "@setting.token" }`; templates, profiles and the top-level `environment` cannot use it. Type it in **Customize → Library**; **Manage credentials…** in a widget's Content settings opens that package page. For an active package, choose **Save credentials**; ordinary setting changes do not save credentials. For a package being added, **Add to bar** applies its configuration and then saves the credentials. An error stays visible if the credential write fails. The field shows whether a token is saved without revealing it. StableBar keeps it in the login Keychain, never in a configuration file, and `--query` and Customize show `@secret.<package id>/<setting>` in its place. Commands receive the token when they start, or an empty value when none is saved. **Remove** next to a saved token schedules its deletion for the next credential save or add operation. The token belongs to the package ID, so a new version keeps it, and a package selection cannot set it in `settings`. Builds that are not signed with a Developer ID, which includes current releases and local builds, change their signature with every update, so macOS asks whether StableBar may use its Keychain item the first time a command needs the token after an update; choose **Always Allow** to stop the question until the next update.

A secret keeps the token out of configuration files, `--query` and Customize. It does not protect it from other packages: a package that runs commands can still reach a secret through StableBar, for example by overriding another package's widget. Install packages with commands only from sources you trust. A command that prints its token still shows it in its output and in Status, and programs running under your account can reach a secret through StableBar too, since they can edit your configuration.

Widgets, templates and providers receive `PACKAGE_DIR`, the absolute path of the installed package, for commands such as `"$PACKAGE_DIR/scripts/clock.sh"`.

Packages install atomically into `packages/<id>/<version>` beside the main configuration. Existing versions cannot be overwritten. Configuration includes and static image paths stay inside the package; traversal and symlinks escaping the folder are rejected. Static image paths are resolved relative to the package folder, including token references. Package commands can run arbitrary code as your user; review the files as well as the displayed command strings before enabling an unfamiliar package.

**Remove from bar…** turns off an entire package and retains its files, settings and credentials. To hide just one of its widgets, use **Your bar**. To delete an installed version, select it in **Library → Versions and technical details → Uninstall this version…**. If selected, that version is disabled in the root configuration, including when its selection comes from an include; an uninstalled theme falls back to Built-in. Other installed versions, saved settings and Keychain secrets are kept for reuse. To delete a saved token, use **Remove** beside it and **Save credentials** before uninstalling. Uninstall checks that the configuration still loads before deleting files. It cannot be undone in Customize; history that needs the deleted files is cleared. Temporary command-line changes stay unsaved. Save or discard them first if they still use that version. The command-line operation always saves current configuration edits and uses the running bar, without a confirmation prompt:

```sh
StableBar --uninstall-package local-clock 1.0.0
```

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

Package selections in modules merge by package ID, with later modules and the root taking precedence. Enabled packages load once before the composed modules and root properties. Root templates, tokens and widget overrides can customize them. Set `enabled` to `false` to stop loading a package; installation alone has no runtime effect. Packages cannot enable other packages. StableBar never updates a package by itself: versions remain pinned until you choose another installed version, and the [store](#store) only tells you about newer ones.

A package whose `package.json` sets `"kind": "widgets"` contains no commands, so it needs no command review. Its configuration can contain only `tokens`, `defaults`, `bar`, `groups`, `profiles`, `widgets`, `templates`, `popups` and `providers`, plus includes inside the package. Nowhere in it, including templates, popups, providers and profiles, can it set `command`, `onClick`, `onClickField`, `rightClick`, `middleClick`, `scrollUp`, `scrollDown`, `mouseEntered`, `mouseExited`, `onChange` or `environment`, so script widgets and `command` or `stream` providers are rejected too. Built-in widget types, native providers and [`open`](#mouse-actions) remain available, and built-in widgets keep their own behaviour: a `workspaces` widget still talks to AeroSpace or yabai. StableBar checks this when the package is reviewed, installed and loaded, and **Customize → Library** and `--inspect-package` say that it contains no commands instead of listing them. Enable it in `packages` like any widget package. [examples/packages/system-monitor](examples/packages/system-monitor/config.json) shows CPU and memory with a popup.

### Store

**Customize → Library** lists widget packages from the [StableBar store](https://github.com/Seb-GRAF/stablebar-packages), with their descriptions and versions. Select one to download and inspect it, review its included widgets, setup and access requirements, then choose **Add to bar**. Loading the list does not download every package; only the chosen package is inspected. A package that needs a newer StableBar shows the version it requires and cannot be installed. **Reload Store** refreshes the index. Installed packages remain available when the Store cannot be reached. On the command line, give `--install-package` a package ID instead of a folder; this installs without enabling:

```sh
StableBar --install-package nord
```

**Customize → Appearance** also shows uninstalled themes under **From the Store**. Their cards show a sample bar styled by the downloaded theme. Choose **Get** to download, check, install and select a theme in one step; progress and any error appear on its card. Themes run no commands and skip the command review; **Get** refuses themes that declare hosts, permissions, required tools or secret settings. Store previews and downloads are cached while StableBar runs. If the Store is unavailable, your installed themes still work.

A store package with a newer version is marked **Update available**. Choose **Review update**, review its setup and access, then add the new version; the old version stays installed so you can roll back. When the new version runs commands, contacts hosts or uses macOS permissions that the enabled version does not, StableBar lists them and asks before enabling it.

Every store package is open source in [stablebar-packages](https://github.com/Seb-GRAF/stablebar-packages), and that repository's CI builds and publishes the archives, not the package's author. Themes and packages that contain no commands are published once they pass CI. A maintainer reads every version of a package that runs commands before it is published. StableBar downloads the index and the archives over HTTPS and checks each archive against the SHA-256 in the index before reviewing it.

These optional `package.json` keys describe a package, and the review shows them:

| Key | Meaning |
| --- | --- |
| `description` | One sentence for the store and the review |
| `author` | Person, organization or handle |
| `repository` | `https` URL of the package's source |
| `screenshot` | Path inside the package to a PNG or JPEG |
| `minimumVersion` | Oldest StableBar version that can run it, such as `0.6.0`. An older StableBar refuses to review or install it. |
| `requires` | Command-line tools needed on the login shell's PATH, such as `jq` or `gh`. The review names the ones it cannot find. |
| `permissions` | macOS permissions: `calendars`, `automation`, `accessibility`, `bluetooth` or `location` |
| `hosts` | Hostnames the package contacts, such as `api.github.com` |

StableBar shows `requires`, `permissions` and `hosts` but does not enforce them. For store packages, a maintainer checks them against the code.

### Themes

StableBar ships with five themes and the Built-in fallback. Themes follow the system's appearance, or the one `bar.appearance` sets. Notch stays black in both appearances.

| Theme | ID | Look |
| --- | --- | --- |
| **Built-in** | none | Each widget is its own floating tile. |
| **Rosé Pine** | `rose-pine` | Rounded tiles in Dawn and Main colors, with an Iris accent. |
| **Everforest** | `everforest` | A full-width strip in warm forest colors, with underlined workspaces. |
| **Léman** | `leman` | A rounded floating bar in lake blue-green colors, with a teal accent. |
| **Blueprint** | `blueprint` | A thin outlined bar in tracing-paper and cyanotype colors, set in Menlo. |
| **Notch** | `notch` | A pure black strip that blends into the MacBook notch, with a cyan accent. |

Choose one in setup or in **Customize → Appearance**. Appearance's full-width cards show the same sample bar in each theme's style: three workspaces, Finder, a battery percentage and a clock. The sample shows the theme's bar, widget tiles, fonts, colors and workspace indicator, in the light or dark appearance your bar uses now. Click a card to apply and save it immediately; a checkmark marks your choice, and **Undo** restores the previous theme. You can also select a theme that ships with StableBar by its ID:

```json
{ "theme": { "id": "rose-pine" } }
```

To try themes on your real bar, choose **Try Themes…** from the bar's right-click menu or its menu-bar icon. A small panel opens below the bar on that screen. Use **←** and **→** or the arrow buttons to cycle through the themes that ship with StableBar, starting with Built-in, then your installed themes, in the gallery's order; every display changes together. **Return** or **Keep** saves the shown theme, and **Undo** in Customize reverses it. **Esc**, **Cancel** or a click outside restores the previous look without saving. Quitting while trying also leaves the saved theme alone. Opening **Edit Bar** cancels a theme trial; starting **Try Themes…** finishes editing the bar. Temporary command-line changes stay applied and unsaved throughout. **Keep windows clear** uses the saved bar’s size until you choose **Keep**.

Older configurations can still select `slate`, `paper`, `graphite`, `menu-bar`, `island`, `minimal` or `terminal` without a version. Their appearance and overrides are preserved on update. The active theme is shown as **Custom**; the old themes are not offered under **Browse themes**. Choosing a new theme replaces Custom, and Undo restores it.

Without `theme`, StableBar uses Built-in. Built-in also loads under every other theme, so a theme only needs what it changes: one that defines only tokens restyles widgets through Built-in's `defaults`, and anything it leaves out keeps Built-in's value.

A theme is a package whose `package.json` sets `"kind": "theme"`. Its configuration can contain only `tokens`, `defaults`, `popupDefaults`, `roles`, `workspaceDefaults`, `bar`, `groups` and `profiles`, plus includes inside the package. Widgets, templates, widget overrides, popups, providers, environment variables and any other key are rejected when the theme is reviewed, installed or loaded, so a theme runs no commands and needs no command review. The themes that ship with StableBar are in [Resources/themes](Resources/themes); [Rosé Pine](Resources/themes/rose-pine/config.json) defines every token below. Give each color a light and a dark value, such as `{ "light": "#1f2329", "dark": "#e6e9ef" }`, instead of a dark profile.

A theme can change the whole look, not only its colors. [Everforest](Resources/themes/everforest/config.json) draws the strip with `bar.style` and removes the widget tiles by setting `background`, `borderColor` and `shadowColor` to `null` in `defaults`. Popups would lose their background with them, so it gives popups their own in `popupDefaults`. [Léman](Resources/themes/leman/config.json) adds `bar.margin` and a corner radius so the strip floats.

Install your own theme like any other package, then select it with its version:

```json
{ "theme": { "id": "my-theme", "version": "1.0.0" } }
```

Only one theme is active: `theme` must name a theme, and `packages` cannot list one. An installed theme accepts the same `enabled` and `settings` as a package selection, and you can also enable it in **Customize → Library**. Widget packages load first, then Built-in, then the selected theme, then includes and the main file. A theme's tokens, `defaults` and `bar` settings override a widget package's, and yours override the theme's. Profiles merge by name across these layers, keeping their order; later properties override earlier ones. A theme’s profiles remain unless you disable them with `"enabled": false`. **Built-in** in setup removes `theme`. In Appearance it removes the main file’s selection, or selects Built-in explicitly when an included file chooses another theme. Choosing a theme in Appearance or Try Themes replaces the version and settings inherited from an included file.

When your main file sets values that the selected theme also sets, Appearance names them below the gallery. **Reset them** removes those values in one saved, undoable change. This includes bar dimensions, shared styles and a widget’s own style where it overrides the theme’s defaults or that widget’s role. Theme color changes count too, including colors inherited from Built-in. Active profiles in your main file are included; included files, templates and packages are left alone. The Light/Dark/Automatic choice is kept. Other settings still follow the usual layer order.

[Tonhalle Line](examples/packages/tonhalle-line) is an installable theme with a 38 pt Helvetica strip in forest ink and warm paper, a matching light palette, and brass warning colors. Version **1.1.0** adds a Light 16 pt `time` role, popup heading/key/value/button/meter roles, a 2 pt workspace underline below the strip, and a four-edge brass outline for `mode.command`. Other labels remain 13 pt regular; a `secondary` date stays smaller. Install its folder through **Customize → Library**, then select it in Appearance:

```json
{ "theme": { "id": "tonhalle-line", "version": "1.1.0" } }
```

Version 1.1.0 requires a StableBar build with shared presentation support; earlier builds reject its new properties. Installed versions are immutable: if you installed the earlier 1.0.0 theme, install 1.1.0 alongside it, then select 1.1.0. Keep the theme selected through `theme`; do not include or copy its styles into your configuration. That lets switching themes replace its appearance. User overrides still win.

The [presentation example](examples/presentation/config.json) separates the time and date clocks, annotates popup elements, and owns a horizontal music-popup layout. It has 18 widgets, a shared sample provider, a group, constrained labels, a disabled widget and an event-driven mode label. Copy its `config.json`, `sample.json` and `mode.sh` together into a scratch directory and install the theme for that configuration. Its sample data is local; its buttons open the named macOS applications/settings. Change `modeAliases` to match your local AeroSpace names. The example maps `tailing` to `command`; the theme contains no local mode names and runs no commands. Use Dark Appearance for the original ink palette. A theme switch closes an open popup; reopen it to see the new role styling and unchanged layout.


Popups inherit `popupDefaults` and then `defaults`, and the workspace highlight uses `defaults.accent`. Every theme defines these tokens, so widgets, widget packages, popups, layouts and workspace styles can use them, for example `"foreground": "@token.textMuted"`:

| Token | Use |
| --- | --- |
| `surface` | Widget background |
| `surfaceRaised` | Hover background and raised surfaces |
| `text` | Primary text |
| `textMuted` | Secondary text |
| `accent` | Highlights, the workspace indicator and progress fills |
| `track` | Progress and graph tracks |
| `hairline` | Borders and dividers |
| `warning` | Warning text or fills |
| `critical` | Critical text or fills |

A reference to a token that no layer defines is an error. Built-in defines all of these, so your own widgets can use them under any theme. Their names are reserved for colors: Built-in's `defaults` use `text`, `surface`, `surfaceRaised` and `accent`, so a token of yours with one of these names replaces the theme's color and must be a color. A widget package should still define fallback values for the shared tokens it uses, so it passes review on its own; Built-in and any other theme replace them.

### Liquid Glass

`bar.glass` is experimental. It draws backgrounds as native Liquid Glass, the material of the macOS 26 Dock, on top of any theme:

```json
"bar": { "glass": { "enabled": true, "transparency": 0.4 } }
```

Every widget, popup and bar that has a background becomes glass in the same shape, tinted with that background's color, so hover, open and data-state colors still show. Borders, corners, shadows and text keep the theme's style. Transparent backgrounds stay transparent. `transparency` (0.3 by default) sets how much glass shows through the color, from `0`, the theme's color, to `1`, pure glass; the higher it is, the more a busy or bright wallpaper can make text hard to read. StableBar uses Apple's clear glass with the theme's color as its dimming layer: the frosted regular glass switches small elements between light and dark to match what is behind them, which would leave theme text unreadable. Set `widgets`, `popups` or `bar` to `false` to keep that surface's plain color. Before macOS 26, StableBar draws the colors as usual.

Glass in a background window renders flat, without refraction. StableBar's bar and popups report themselves as active to AppKit so the glass refracts. The glass setting doesn't change their keyboard behavior.

### Displays and notch placement

`notchLeft` ends before the notch and `notchRight` starts after it. `bar.notchSpacing` controls the gap on each side (16 by default). The notch comes from the screen's unobscured top areas; `bar.notchWidth` can override its width. On screens without a notch, `notchLeft`, `center` and `notchRight` form one centered group, measured from the visible content. Hidden groups leave no gap. With a notch, `center` joins the right side, between `notchRight` and `right`.

Each widget accepts `display`: `"all"` (default), `"active"`, `"main"`, `"builtIn"`, `"external"`, `"notched"`, `"unnotched"`, or an array of screen numbers, for example `[1, 2]`. Numbers are one-based positions in `NSScreen.screens`, matching AeroSpace and SketchyBar; they can change when displays are rearranged. `active` follows the configured workspace source's focus. With AeroSpace, use `aerospace list-monitors --format '%{monitor-name}|%{monitor-appkit-nsscreen-screens-id}'` to list them. yabai display IDs are mapped to these screen numbers, independently of yabai's display ordering.

Set `bar.displayScale` to `{ "builtIn": 0.85, "external": 1 }` to shrink the laptop bar while keeping external displays at their original size. Each factor scales the bar height, widgets, text and spacing; omitted display types use `1`. Factors must be positive, and other keys are rejected. The bar offset, margin and popup sizes stay in screen points. This setting also works inside automatic profiles.

`bar.style` accepts `background`, `cornerRadius`, `borderColor`, `borderWidth` and `borderEdges`. The border defaults to `"bottom"`; `"all"` draws all four edges just inside the visible strip, following its corners. The outline does not change panel size, window clearance or clicks. A notch or the system menu bar can obscure part of the top edge. `bar.margin` (0 by default) insets the bar's background and widgets from every edge of the bar, so a rounded `bar.style` floats below the top of the screen and in from its sides. The bar keeps its height, so the visible strip is `height` minus twice the margin. Scripts can return `barStyle` to change those properties; later widgets override earlier widgets when they set the same property.

### Composing widgets

A widget's `layout` uses the same blocks as a popup. Use rows and columns to style the label, icon and other elements independently. Bar layouts take their content's width; popup layouts fill their available width. Give graphs, progress blocks and images explicit sizes when they should have a fixed footprint.

A widget without `layout` draws a default layout made of the same blocks: a `row` of its icon (`symbol`) and text (`field`), at least a line of text tall even when it shows only the icon. Script and provider widgets whose output has a `value` show a 40 × 16 `graph` before them, and active-app widgets show the app's icon instead of a `symbol`. Workspaces and spacers keep their own views. A `layout` replaces the default layout, so block options work on built-in widgets too, for example an app name that scrolls when it doesn't fit: `"layout": { "type": "field", "field": "text", "scrollSpeed": 30, "style": { "width": 120 } }`.

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

Bar layouts receive the widget's `text` and `icon` as fields, beside the script's own fields: a text widget's `text`, a clock's time in its `format`, the frontmost app's name, or a script's or provider's `text` and `icon`.

Script output ignores unknown top-level fields, but styles, animations and menu items in it use the configuration's property names and reject unknown ones. Script output may include `style` to override the widget style, `display` to change its display filter, and `styles` to supply named element styles. A block with `"styleSource": "countdown"` reads `styles.countdown`, overlaid on its configured style. A list row can use `styleField` to read the style name from a field in that row. Scripts can return `widgetStyles`, keyed by widget ID, to style another widget (for example, change a workspace underline when the window-manager mode changes). Later scripts take precedence; a widget's own `style` output takes precedence over those overrides. Omitted overrides return to the configured style on the next update.

Widgets and blocks accept `animation` with `duration` in seconds and `curve`: `linear`, `easeIn`, `easeOut`, `easeInOut`, `smooth` or `spring`. Widget animation defaults to `bar.animationDuration`. Block style animations are opt-in. Progress values use a 0–1 scale, clipped to that range when drawn. A progress block can also read a numeric string from its current list row when there is no matching entry in `values`. With a matching entry in `targets`, a progress rule starts at `values[source]` and animates toward `targets[source]`; without a target it animates between readings. Reduce Motion disables these animations.

Widgets and text, field and symbol blocks accept `transition`, so changed text and symbols animate instead of snapping: `fade` cross-fades, `roll` slides the new content up from below, `numeric` rolls the digits that changed (symbols fade), and `none`, the default, swaps them at once. A widget's `transition` applies to its default layout and to the text, field and symbol blocks of its `layout` and `overlay` that set none of their own. A transition uses the block's `animation`, else the widget's; in popups, the block's or 0.22 seconds. Blocks that appear or disappear, such as with `hideWhenEmpty`, don't transition, but a widget with a `transition` fades or rolls in and out when its output's `hidden` changes, and the widgets beside it slide into place. Reduce Motion turns transitions off.

### Workspace appearance

A `workspaces` widget (also accepted as `aerospace`) accepts `workspace` with:

- `indicator`: `background` (default), `underline` or `none`.
- `indicatorStyle`: underline `height`, `width`, `background`, `cornerRadius`, `offsetX`, `offsetY` and `placement`. `"cell"` (default) preserves the cell-relative underline; `"belowBar"` puts its top at the visible bar background's bottom plus `offsetY`, independently of the cell height. Negative `offsetY` moves the underline upward; Customize's **Your bar** and **Appearance → Advanced appearance → Workspace defaults** controls accept negative offsets too. Its `states.focused` and `states.visible` style the underline under the focused workspace and under a workspace shown on a display without focus; mode states apply after those.
- `style`: cell typography, foreground, width, height, horizontal/side padding and spacing. Its `states` style each cell by workspace state: `focused` (the focused workspace), else `visible` (shown on a display without focus), else `empty` (no windows), so a cell has at most one. `focusedStyle`, `visibleStyle` and `emptyStyle` are shorthand for those states. The background indicator uses the state's background or border color. `hover` changes the label and app glyphs; the indicators follow the workspace state. `defaults.states` don't apply to cells.
- `showEmpty` and `showApps`: control empty workspaces and app icons.
- `windows`: when `true`, shows one item per window instead of one per app. Each item keeps its app icon or `appGlyphs` glyph. Clicking it focuses that window; clicking the workspace number or cell padding switches workspace. `showApps: false` hides these items too.
- `titleLength`: maximum characters of each window title when `windows` is enabled. Omit it or use `0` for icons only. For example, `"workspace": { "windows": true, "titleLength": 24 }`. The full title is available on hover. Titles refresh with workspace and window events; yabai users can also register `window_title_changed`.
- `appStyle`: font and foreground for app glyphs, width and height in screen points for native app icons (14 × 14 by default). `focusedAppStyle` and `visibleAppStyle` are shorthand for its `states.focused` and `states.visible`.
- `appGlyphs`: app bundle ID or app name to text glyph. Set `appStyle.fontName` to an installed icon font to use its ligatures. A key ending in `*` matches app names that start with the rest of the key, such as `Adobe Photoshop*` for `Adobe Photoshop 2026`. Exact bundle IDs and names win over these keys, and among them the longest key wins. Use `"*"` alone for the fallback glyph; otherwise unmapped apps retain native icons.

Cells fit their labels and app icons by default, with the same widget padding as other widgets. Vertical widget padding extends the selection background so it fills the widget's height. Set `workspace.style.height` for a fixed cell content height before that padding.

Adjust only the workspace widget's padding in **Customize → Your bar → Text and shape → Vertical padding**, or set its `style.paddingVertical`, for example `"style": { "paddingVertical": 4 }`. `style.paddingTop` and `style.paddingBottom` override it individually.

For a sliding underline, set `workspace.indicator` to `underline`, `workspace.style.height` to the bar's height, and `workspace.indicatorStyle` to `{ "height": 2, "background": "#f1efe8", "states": { "visible": { "background": "#f1efe866" } } }`, which dims the underline on displays without focus. The widget's `animation` controls its motion.

To place it just below the bar instead, use `"indicatorStyle": { "placement": "belowBar", "height": 2, "offsetY": 0 }`; set `offsetY` to a positive gap when wanted. Its span follows the visible cell and is clipped to the workspace widget's scrolling region. Overflowed widgets and hidden measuring copies emit no underline. This decoration does not stretch the colored background or move labels. A native decoration window reserves space for every configured state and always ignores mouse events. The bar itself keeps its original hit bounds and background menu; clicks in the extra strip pass to the window beneath; popups open below the bar/decorations on the display of the instance that opened them. Reduce Motion disables underline motion, and edges align to display pixels.

For glyphs from [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font), install the font from its releases or with `brew install --cask font-sketchybar-app-font`, then save the [sketchybar-app-font module](examples/modules/sketchybar-app-font.json) next to your configuration:

```sh
curl -fLo ~/.config/stablebar/sketchybar-app-font.json \
  https://raw.githubusercontent.com/Seb-GRAF/StableBar/main/examples/modules/sketchybar-app-font.json
```

The module sets the `appGlyphs` token to the font's map of app names to ligatures, with `:default:` as the fallback. Include it and opt in from a workspace widget:

```json
{
  "includes": ["sketchybar-app-font.json"],
  "widgets": [
    {
      "id": "spaces", "type": "workspaces", "position": "left",
      "workspace": {
        "appGlyphs": "@token.appGlyphs",
        "appStyle": { "fontName": "sketchybar-app-font", "fontSize": 14 }
      }
    }
  ]
}
```

Your own `tokens.appGlyphs` merges into the module's map, so `{ "tokens": { "appGlyphs": { "com.example.Notes": ":notes:" } } }` adds or changes one app. The module's `sketchybarAppFontVersion` token names the font release it was generated from; install that release or a newer one. `scripts/update-app-glyphs.sh` regenerates the module from the font's latest release.

### Script events

Add `events` to a script widget to refresh it on named events, alongside its interval. Set `"interval": null` to run once at startup and then only on events or after a click action. Omitting the interval keeps the default 30-second polling. Numeric intervals must be greater than zero. StableBar knows these events:

| Event | Sent when | `INFO` |
| --- | --- | --- |
| `frontApp` | The frontmost app changes | The app's name, or `Desktop` |
| `workspace` | The focused workspace changes | The workspace's name; `SID` is its display number |
| `aerospaceMode` | Initial connection, binding-mode change or disconnect | The mode's name; empty on disconnect, stop or a source switch |
| `wake` | The Mac wakes from sleep | Not set |
| `yabai` | `StableBar --trigger yabai` runs, usually from a yabai signal; StableBar also refreshes its workspaces | The trigger's `INFO`, if any |
| `powerSourceChange` | The Mac switches between its power adapter and battery | `ac` or `battery` |
| `volumeChange` | The default output device's volume or mute state changes | The volume as a whole percentage, empty without a volume control; `MUTED` is `true` or `false` |
| `outputDeviceChange` | The default output device changes | The device's name, empty when there is none |

`powerSourceChange` comes from the `battery` data source, and `volumeChange` and `outputDeviceChange` from the `audio` source. Subscribing to one of them runs that source while the subscribing widget is enabled, even when no widget shows it, and keeps it running while its own widgets are hidden. A provider of another type named `battery` or `audio`, such as your own stream, keeps the built-in source from starting. Other names subscribe to macOS distributed notifications, for example `com.spotify.client.PlaybackStateChanged`.

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
| `INFO` | For StableBar's events, as the table above lists; for a trigger, its `INFO` value; otherwise the distributed notification's JSON payload when available |
| `SID` | Display number for pointer actions and workspace events |
| `BUTTON` | `left`, `right` or `middle` for widget mouse clicks |
| `MODIFIER` | Space-separated `shift`, `ctrl`, `alt`, `cmd`, `fn` for pointer actions |
| `SCROLL_DELTA` | Signed vertical scroll delta for scroll actions |

Script output can also set `onClick` for a state-dependent click action; popups and menus still take precedence. Named graph data goes in `series`, a dictionary of arrays; only the latest 60 samples of each graph are retained.

### Tooltips

Set a widget's `tooltip` to show text when the pointer rests on it. It works without a popup and keeps the widget's click action. For example, add `"tooltip": "Will not sleep for 1 hour"` to an Amphetamine widget. You can also edit **Tooltip** in **Customize → Your bar**.

Tooltips inherit `defaults`, `popupDefaults`, and the widget's explicit `style`, using the same colors, font, border, corners, shadow, and glass treatment as popups. Their size fits the text.

A configured tooltip overrides the script's tooltip. To show changing information, such as the remaining awake time, leave the widget's `tooltip` unset and return `tooltip` in the script's JSON output:

```json
{"text":"","icon":"pill.fill","tooltip":"Will not sleep for 1 hour"}
```

The script supplies the current text on each update; StableBar does not calculate the remaining time. Clearing the field in Customize restores the script's tooltip. In JSON, `"tooltip": ""` hides it. Script errors still appear in tooltips.

### Mouse actions

Keep `onClick` for the primary action. To open a URL or an app without a shell, set `open` instead: an `http`, `https`, `mailto` or `x-apple.systempreferences` URL, or an application bundle identifier. StableBar opens it through macOS. Any other value is a configuration error, and a widget cannot set both `onClick` and `open`. A popup or menu takes precedence over either.

The whole widget tile, including its padding and configured width and height, is clickable when it has a primary action, popup or menu.

```json
{ "id": "date", "type": "clock", "position": "right", "format": "EEE d MMM", "open": "com.apple.iCal" }
```

Add `actions` to any widget for additional controls:

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

Command-line changes are live for the current session. Customize shows a notice with **Save** and **Discard** for these temporary changes. Changes made in Customize save separately and leave temporary command-line changes applied on top. Add `--persist` to save the session changes into the root file. `--reset` discards unsaved session changes and reloads the files. Session edits reapply over external file changes. Imports and package source files are preserved.

Use one batch for changes that must appear together:

```sh
StableBar --batch '[
  {"action":"set","id":"clock","properties":{"position":"left"}},
  {"action":"bar","properties":{"height":44}},
  {"action":"defaults","properties":{"fontSize":13}}
]' --persist
```

A batch validates the whole resulting configuration before replacing the running bar or writing the file. A failed batch leaves both intact. Supported edit actions are `set` (`id`, `properties`), `add` (`properties`, including `id`), `remove` (`id`), `reorder` (`ids`), `bar`/`defaults`/`popupDefaults`/`roles`/`workspaceDefaults`/`modeAliases`/`tokens` (`properties`, merged into those keys), `workspaceSource` (`name`: `aerospace` or `yabai`, omitted for the default AeroSpace source), `unset` (`properties` naming the keys to remove from the main file, with `id` for a widget, for example `{"action":"unset","id":"clock","properties":{"style":{"foreground":null}}}`), `profile` (`name`, omitted for automatic), `profiles` (`profiles`, definitions merged by name; set `enabled` to `false` to disable one), `package` (`properties`: `id`, `version`, optional `enabled` and `settings`), and `theme` (the same `properties`, with only `id` for a theme that ships with StableBar, omitted for Built-in).

Without `id`, `unset` can also address widget definitions by their ID and profiles by their name in the main file. For example, `{"action":"unset","properties":{"widgets":{"clock":{"style":{"foreground":null}}},"profiles":{"night":{"configuration":{"bar":{"height":null}}}}}}` removes the clock’s text color and the night profile’s bar height in one edit. Empty objects are removed, except an emptied profile `configuration` stays as `{}`.

- `--validate [PATH]`: compose and validate files without starting scripts.
- `--refresh ID`: refresh a running widget. Hidden, suspended providers must first be made visible or explicitly resumed with **Customize → Status → Resume for testing**.
- `--trigger EVENT [KEY=VALUE ...]`: send an event. Without `--config`, this broadcasts to all subscribed bars for compatibility; with `--config`, it targets that configuration.
- `--reload`: reload configuration; without `--config`, notify all running bars.
- `--packages`, `--inspect-package PATH`, `--install-package PATH|ID`, `--enable-package ID VERSION [--persist]`, `--uninstall-package ID VERSION`: review and manage packages. `--install-package` installs a folder, or a package from the [store](#store) when its argument is not a folder. Installation does not enable commands. Uninstall requires the bar to be running and always saves configuration edits before removing that version. Package selections belong in the root file or its includes; use profile widget overrides to hide package widgets contextually.

### Customize

Open **Customize StableBar…** from the menu-bar icon or by right-clicking the bar, reopen the running app, or run `StableBar --customize`. Its sidebar starts with **Your bar**, followed by **Appearance**, **Library**, **Profiles**, **Settings** and **Status**. **Search settings** finds controls by their purpose, including login, permissions, clock format, displays and widget appearance, and jumps to the matching section.

**Settings** contains **Open at login**, display scale, offset and margin, window and notification clearance, permission status and recovery actions, and the workspace source and reconnect action. It also opens or reloads configuration files, links to setup and the user guide, and contains **About and updates**. Login and permission actions affect macOS immediately; configuration changes use the same saved-change history as the other editor sections.

**Appearance** starts with the current [theme](#themes); expand **Browse themes** to compare sample bars, select a theme or **Get** one from the Store. A notice names your settings that override the chosen theme, with **Reset them** to let its values apply. Appearance also keeps the bar light or dark or lets it follow the system, and edits the theme's colors. Each theme color has a light and a dark value; changing one saves it in your configuration's `tokens`, so every widget, popup and package that uses it follows. **Liquid Glass** controls [glass surfaces](#liquid-glass) and transparency. **Default widget appearance** sets shared colors, shadow, font, weight, size, padding and corners; individual widgets can override them. **Popups** sets background, border, shadow and weight over those defaults. **Bar** sets the bar's background, border, corners, height, inset and spacing. **Advanced appearance** contains presentation roles, workspace defaults and AeroSpace mode aliases. Display placement and window clearance are in Settings.

**Your bar** groups widgets by position. Drag within or between groups to move them; widgets that share a group move together, with one Undo step. Use the arrow buttons or ⌥⌘↑ and ⌥⌘↓ to move the selected widget up or down. Empty positions remain available, including both sides of the notch when a display or widget uses them; **Position** and **Move to** always offer every position. **Add widget** searches separate **Built-in**, **Store** and **Script** choices. A built-in choice remains the same as the Store loads and stays available offline. Double-click an entry or select it and press Return to add it. Adding a package already on the bar selects its widget and keeps its position and compatible settings. Packages with commands, permissions, hosts, required tools or secret settings show their review before you add them. New widgets go to the end of the selected widget's position, or Right if none is selected, and become selected.

Choose **Arrange on desktop** in Your bar, or **Edit Bar** in the bar's right-click or menu-bar icon menu, to arrange widgets on every display. Widgets keep their look and size inside dashed outlines. Each position has a softly outlined tray, including empty positions; position names appear only while dragging. Trays tint the theme’s bar surface, and their outlines, **+** and names are drawn to read on it. On a theme that leaves the bar see-through, such as Built-in, each tray gets a light or dark backing that the widgets’ text reads on, so the trays stay readable over any wallpaper. The bar grows just enough for the trays and badges. Widgets hidden by their output or screen choice appear as named placeholders with a crossed-out eye; empty widgets show their names too. Turned-off widgets aren't shown; turn one on again in **Customize → Your bar**, or add a Store package again with **+**. Other names appear in tooltips. Drag a widget to an insertion line within or between positions; grouped widgets move together. If a position is too crowded to fit, faded edges and arrows show where more widgets are available: use the mouse wheel or swipe sideways to reach them. **+** opens an **Add here** popover below it, with search and a two-column choice of widgets. Adding puts the widget exactly where that **+** sits. Packages with commands, permissions, hosts, required tools or secret settings are reviewed in the popover first. The **−** badge on a widget’s top-left corner removes it from the bar; widgets from packages or includes are turned off. Click a widget to open its settings here. Its usual clicks, popups and mouse actions pause while editing. The update tile isn't shown while editing the bar. The widget's context menu also offers **Move Left**, **Move Right** and **Move To**. With VoiceOver, use the widget's **Move left** and **Move right** accessibility actions. Changes save automatically. **Undo** and **Done** sit in a small panel below the bar. Use **Undo**, or ⌘Z and ⇧⌘Z while the bar has focus, to undo and redo through the same history as Customize. **Esc** closes an open Add here popover first. **Done**, **Esc** while the bar has focus, **Finish Editing Bar** or an explicit or external configuration reload restores the normal bar. Automatic profile changes keep editing open. Temporary command-line changes stay separate and unsaved.

Widgets use your chosen IDs as names. Widgets added in Customize use their package name, short text or type, with numbers to tell matching names apart. The selected widget starts with its on/off switch, current status and a **Troubleshoot** link. **Content** contains text, icon, clock format and ordinary package settings. Package fields state that they are shared by the package's widgets; **Manage credentials…** and **Manage package…** open the same package in Library. **Behavior and placement** contains click behavior, tooltip, popup-on-hover, screens and position. **Appearance** exposes colors, font, size, padding, corners and border without opening an advanced section.

Choose an app or web page to open on click. Workspaces offers **Show each window** and **Window title length**, and keeps its own clicks to switch workspaces or focus windows. App menus keeps its clicks to open menus; Spacer has no click control. **Technical details** contains the widget ID, presentation role, transition, workspace presentation and JSON editor. Existing commands, menus and detailed layouts remain available through JSON. A color can follow a theme token such as Text or Accent, or use a custom light and dark pair.

Style controls name their value's source. **Why?** shows the saved value, effective value and contributing sources in priority order, including theme/package defaults, includes, templates, profiles, tokens and applicable widget output or active states. It explains the display scope, such as a widget at rest versus hovered. A warning identifies a saved value that is currently overridden; editing it changes that saved value while the higher-priority source still controls the result. Open the controlling profile or source file from the explanation. **Reset to default** removes the saved property so inheritance can apply again; writing `null` clears that level and is a different operation. A separate **Remove this override** action handles a main-file widget override. Opening a menu or selecting its current value leaves it unchanged.

Configuration changes in Your bar, Appearance, Profiles and Settings apply immediately and save to your main file. Ordinary settings for active packages use the same automatic save and Undo history; Library drafts and credential edits have their own explicit actions. Typing or dragging saves when you pause; closing Customize or quitting StableBar saves pending configuration changes. **Undo** (⌘Z) discards a pending change or reverses the last saved change, and **Redo** (⇧⌘Z) restores changes, with one step per burst. If the file changes outside Customize, affected history is cleared so Undo cannot overwrite those changes. An invalid change is rejected and its error is shown. If a pending change cannot be saved, it is discarded with an explanation so you can keep using Customize or quit.

**Profiles** shows the active [profiles](#theme-tokens-and-automatic-profiles) in priority order, chooses automatic matching or a pinned profile, and edits conditions, bar height, offset, appearance and default widget font size. **Technical details** keeps the configuration JSON for other settings such as role styles, workspace defaults and mode aliases.

**Library** reviews local folders and [store](#store) packages, lists their included widgets and requirements, and provides **Add to bar**, ordinary settings, credential saves, version selection and removal. Installing files, adding widgets, turning off a package and uninstalling a version are separate states. Themes are primarily browsed in Appearance; selecting an installed theme in Library still offers **Use theme**.

**Status** shows widget health and the last successful source update, with clear states for failures, missing access, disabled or paused widgets, connections and updates. Select a widget to allow access, **Refresh data**, **Restart connection**, reconnect workspaces or **Configure widget**. Shared data sources name the other widgets an action affects.

Opening Status does not resume a hidden provider. **Resume for testing** keeps a paused source active until you choose **Stop testing**, select another widget, leave Status or close Customize. **Technical details** contains run duration, completed-command CPU time, counters, **Test click action** and **Broadcast event**. Broadcasting an event can refresh other subscribed widgets too.

**Capture output and configuration** creates a snapshot only when requested. It includes the composed configuration, source paths, resolved styles and presentation layers, widget/provider output, graph samples and diagnostics. JSON formatting runs off the main thread. The snapshot is labelled with its capture time and stays unchanged until **Refresh snapshot**; **Copy snapshot** copies that captured text. Snapshot refresh reads current data and does not itself restart a source.

**Settings → About and updates** shows a released app's channel (Stable or Beta), full version and build number. Local app builds show Development and their source revision; builds without version metadata show Development with the version unavailable. It also checks for [updates](#updates), chooses the update track and turns automatic checks and installs on or off.

## Built-in widgets

| Type | Content | Additional fields |
| --- | --- | --- |
| `workspaces` (or `aerospace`) | Occupied or visible workspaces on this display, with app icons; click to switch | — |
| `activeApp` | Frontmost app name and icon | — |
| `appMenu` | Frontmost app's menus; click a title to open its menu | `expandOnHover`: show only the app name until hovered (default `false`) |
| `appleMenu` | Apple logo; click to open the Apple menu | — |
| `clock` | Local date/time, updated each minute, or each second when the format shows seconds | `format`: DateFormatter format |
| `text` | Static text and optional icon | `text` |
| `script` | Output of a shell command | `command`, `interval` in seconds or `null` for event-only updates |
| `provider` | Shared command, stream or native data | `provider`: key from the top-level `providers` object |
| `system`, `network`, `battery`, `audio`, `calendar` | Native CPU and memory, network, battery, audio output or calendar data | — |

**Add widget** includes Clock, Active app, Apple menu, App menus, Battery, Sound, CPU, Network, Calendar, Workspaces, Text and Spacer. Text starts with “New widget”. Apple menu and App menus need Accessibility access; Calendar asks for Calendar access; Workspaces needs AeroSpace or yabai. Script starts with a clock command you can change under Technical details.

The AeroSpace connection subscribes to workspace, monitor, window and focus events. It loads an initial snapshot, coalesces pending events and reconnects after a disconnect. The accent color marks the focused workspace; an outline marks a workspace visible on another monitor. Empty, inactive workspaces are hidden. App icons are deduplicated per workspace unless `workspace.windows` is enabled. Active-app updates come from NSWorkspace notifications.

### App menus

An `appMenu` widget shows the frontmost app's menus, such as File, Edit and View, with the app's own menu in bold. In **Customize → Your bar**, select App menus and turn on **Expand on hover** to show only the app name until the pointer enters the widget. The menus stay expanded while one is open. Leave the setting off to show all titles.

The Apple logo is a separate `appleMenu` widget. Add **Apple menu** to show it, or leave it out to keep only the app's menus.

```json
{
  "widgets": [
    { "id": "apple", "type": "appleMenu", "position": "left" },
    { "id": "menus", "type": "appMenu", "position": "left", "expandOnHover": true }
  ]
}
```

StableBar reads the titles through Accessibility when you switch apps, wake or unlock your Mac, and when the pointer enters either widget. If a read fails while an app is becoming ready, the widgets keep their last complete menus and retry for a few seconds. Clicking a title opens that menu below it, read from the app when it opens, so it works while the macOS menu bar is hidden; choosing an item chooses it in the app. These menus show items, separators, checkmarks and submenus, but not keyboard shortcuts. Allow StableBar in **System Settings → Privacy & Security → Accessibility**; until then the widgets show a warning that opens that pane. While a StableBar window such as Customize is in front, the widgets keep the previous app's menus.

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
             window_created window_destroyed window_focused window_moved window_minimized window_deminimized window_title_changed \
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

- `hidden`: removes the widget when true (unless it has an error). Give the widget a `transition` to fade or roll it in and out.
- `interval`: overrides the next polling delay in seconds; must be greater than zero. Omit it to use the configured interval.
- `menu`: an array of `{ "title": "Issue", "detail": "In progress", "onClick": "open …" }`, displayed in a themed popup. Rows without `onClick` show information. A menu takes precedence over the widget's click command. Static widgets can also define `menu` in their configuration.
- `value`: a graph sample, displayed on a 0–1 scale with the last 60 samples. Each update adds one, even when it repeats the previous output; such an update changes only the graph, unless it repeats a `temporary` that ran out.
- `fields`: named display strings for popup field blocks.
- `lists`: named arrays of objects containing display strings for popup list blocks.
- `state`: the widget's data state, such as `warning`; see [Data states](#data-states).
- `temporary`: fields shown over the output's own for `duration` seconds, before the widget returns to its output (at most one day). A volume script can return `{"text":"","icon":"speaker.wave.2","temporary":{"fields":{"text":"62%"},"duration":1.5}}` after a change. A `text` or `icon` field replaces the widget's text or icon, and an empty `icon` hides it. A different `temporary` starts over, as does the same one after it ran out; the same one again while it shows, or an output without one, lets it run out.

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

Provider `type` is `command`, `stream`, `system`, `network`, `battery`, `audio` or `calendar`. `command` and `stream` require a shell `command`. `interval` defaults to 5 seconds: the polling interval for commands, `system` and `network`, and for `calendar` until it has access; the first reconnect delay for streams; and for `audio` and `battery`, which update when macOS reports a change, the first retry delay after a failure. That first delay is `interval`, or 1 second if `interval` is shorter. `timeout` defaults to 10 seconds and applies to command providers; streams remain running until they exit, fail, suspend or stop. Provider intervals and timeouts must be positive and finite.

A widget with `type` set to `system`, `network`, `battery`, `audio` or `calendar` uses the provider of that name. Without a definition in `providers`, it is a native provider of that type with default settings, shared by every widget that names it. Define a provider with the same name to change its interval or other settings. `{ "id": "power", "type": "battery", "position": "right" }` is enough for a battery widget.

Provider `environment` overlays the top-level environment. `NAME` is the provider name and `CONFIG_DIR` remains the main configuration directory. The environment of a consuming widget applies to that widget's actions, not the shared update process. Add `events` to a provider or consuming widget to request updates; one event refreshes a shared provider once. An explicit refresh restarts a stream's process with the new event payload, and restarts the listener of a push source such as `battery`, which then reads its current state again.

A stream writes one complete JSON object per line, including `text`, and flushes stdout after each update. Empty lines are ignored; the final line may omit its newline. Streaming output represents current state: when updates arrive faster than the UI consumes them, only the newest pending update is retained. Each line is limited to 1 MiB; stderr retains its latest 16 KiB. Malformed output stops the process and retains the last good value. Clean exits and failures reconnect with exponential backoff, capped at five minutes or the configured interval if longer. Ten seconds of successful streaming resets the failure streak.

Set `whenVisible` to `true` to suspend a provider when none of its consumers is visible on any display, including widgets moved to overflow. Removing or disabling the last consuming widget stops the provider. System sleep suspends scripts and providers; resuming preserves the last output and graph history, and starts a fresh update with `SENDER=resume`. A suspended or stopped `audio` or `battery` provider removes its macOS listeners. A provider whose events a widget subscribes to stays running; see [Script events](#script-events).

Native providers use public macOS APIs and launch no shell commands:

| Type | Output contract |
| --- | --- |
| `system` | `value` and `values.cpu`: CPU fraction; `values.memory`: used-memory fraction; `values.memoryUsed` and `values.memoryTotal`: bytes. `fields.cpu` and `fields.memory` are whole percentages. Used memory includes internal, wired and compressed pages, excluding purgeable pages. |
| `network` | `values.download` and `values.upload`: aggregate bytes/second across up `en*` Wi-Fi/Ethernet interfaces. `fields.interface`: interface names. `lists.interfaces`: rows with `name`, `download`, `upload`. Virtual VPN interfaces are excluded to avoid counting the same traffic twice. |
| `battery` | `value` and `values.percent`: charge fraction. `fields.percent`: whole percentage; `fields.state`: `charging`, `charged`, `battery` or `ac`; `fields.present`: `true`/`false`; optional `fields.timeRemaining`: minutes. Desktops without a battery return `AC` without a charge value. Updates when the charge, the time remaining or the power source changes, without polling. |
| `audio` | `value` and `values.volume`: output-volume fraction when supported. `fields.device`, `fields.deviceID`, `fields.volumeAvailable` and optional `fields.muted`; `lists.devices`: output-device rows with `id` and `name`. Fixed-volume devices can omit volume, and no output device returns `No output`. Updates as soon as the volume, the mute state or the default output device changes, without polling. |
| `calendar` | The next meeting and today's agenda; see [Calendar](#calendar). |

Fractions use 0–1. CPU and network rates are deltas; their first sample after startup or resume is zero. `audio` and `battery` add a graph sample for each change rather than each interval. Native audio is a data source; use a control's `onChange` command to change volume or devices.

Native providers can't return `state`. Give their widgets `rules` to set a data state from `values` or `fields`, such as a battery `warning` at 20 %; see [Data states](#data-states).

Scripts and providers expose diagnostics in **Customize → Status** and the runtime query: running/suspended state, last event/start/update, execution duration, bounded stdout/stderr, execution/failure/restart counts and next retry delay. Streams and the native sources macOS notifies of changes, such as `battery` and `audio`, count as running while connected, and each update sets their last update time. CPU time is cumulative completed-command CPU time, not a live resource meter for a running stream. Diagnostics and graph history survive style-only edits and suspension. The existing process-group cancellation limit for deliberately detached descendants also applies to streams.

### Calendar

A `calendar` provider reads your calendars through EventKit. It asks for Calendars access the first time it updates, not when StableBar starts, and setup lists that access whenever an enabled widget shows a calendar provider. All-day events are skipped.

| Setting | Default | Meaning |
| --- | --- | --- |
| `calendars` | all | Calendar names to include, as shown in Calendar |
| `lookahead` | `24` | Hours ahead to look for the next meeting |
| `soon` | `15` | Whole minutes before the start when the `soon` phase begins |
| `now` | `5` | Whole minutes before the start when the `now` phase begins |

Output:

- `text`: the next meeting's title, `No meetings` or `No calendar access`.
- `fields.access`: `granted`, `denied` or `notDetermined`. Without access, it is the only field.
- `fields.phase`: `none` when no meeting starts within `lookahead`; otherwise `later`, `soon`, `now`, or `live` while the meeting runs.
- `fields.title`, `fields.start` and `fields.end`: the meeting in progress, or else the next one. Times use your short time format.
- `fields.minutes`: whole minutes until it starts, or until it ends while `live`, rounded up.
- `fields.link`: the first Google Meet (`meet.google.com`), Zoom (`zoom.us`) or Teams (`teams.microsoft.com`, `teams.live.com`) HTTPS URL in the event's URL, location or notes. A link ends at the first character other than `A–Z a–z 0–9 . _ ~ % / ? = & + # : @ -`, so it never contains a quote or other shell syntax. Use it with `openField`. `fields.joinCommand` is `open '<link>'` and exists only with a link; use it with `onClickField`.
- `values.remaining`: before the start, the share of the `soon` lead time left; while `live`, the share of the meeting left. `targets.remaining` is the value one minute later, so a progress block with a 60-second `linear` animation shrinks smoothly.
- `lists.today`: today's events in start order, with `title`, `start` and `end`, plus `link` and `joinCommand` when the event has a link.

With access, the provider updates at each minute and phase boundary and when your calendars or the Calendars permission change. Until access is granted, it checks again every `interval`. `denied` also covers restricted and add-only access; change it in **System Settings → Privacy & Security → Calendars**.

```json
{
  "providers": {
    "meetings": { "type": "calendar", "calendars": ["Work"], "soon": 10 }
  },
  "widgets": [
    {
      "id": "meeting", "type": "provider", "provider": "meetings", "position": "right",
      "layout": {
        "type": "row", "style": { "spacing": 6 },
        "children": [
          { "type": "field", "field": "text" },
          { "type": "field", "field": "minutes", "hideWhenEmpty": "minutes" },
          { "type": "text", "text": "min", "hideWhenEmpty": "minutes" }
        ]
      },
      "overlay": {
        "type": "progress", "source": "remaining", "height": 2,
        "animation": { "curve": "linear", "duration": 60 }
      },
      "popup": {
        "style": {},
        "layout": {
          "type": "column",
          "children": [
            {
              "type": "row",
              "children": [
                { "type": "field", "field": "title" },
                { "type": "symbol", "name": "video", "openField": "link", "hideWhenEmpty": "link" }
              ]
            },
            {
              "type": "list", "source": "today",
              "row": {
                "type": "row", "openField": "link",
                "children": [
                  { "type": "field", "field": "start", "style": { "width": 56 } },
                  { "type": "field", "field": "title" }
                ]
              }
            },
            {
              "type": "button", "title": "Calendar access",
              "onClick": "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'"
            }
          ]
        }
      }
    }
  ]
}
```

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

The [interactive example](examples/interactive/config.json) combines groups, an expanding spacer, constrained text that rolls to the new app's name, and all popup controls. Copy both files from `examples/interactive` into your configuration directory. Its controls update demo state in `.control-state` next to the configuration; they do not alter macOS settings. The app list opens the selected application.

## Custom popups

Add `popup` to any widget. For a popup shared by multiple widgets, define it once in the top-level `popups` object and set each widget's `popupName` to its key. Each anchor uses its own script data. An inline `popup` takes precedence over `popupName`. It takes precedence over `menu` and `onClick`. Its layout is independent of the script, so you can change the layout without changing the data source or rebuilding the app. The example below uses the fields returned by the script output that follows it. While a popup shows, the widget that opened it uses its `open` state; see [States](#states).

Widgets with `menu` entries already open a shared popup without additional configuration. To customize that popup, add `popup` with your preferred style and `"layout": { "type": "menu" }`. You can also place a `menu` block alongside other blocks in a custom layout. Entries retain their titles, details and click commands, and refresh while the popup is open.

Set `popup.openOnHover` to `true` to open after hovering for 0.4 seconds. The popup stays open while the pointer is over the widget or popup, with a short grace period to cross the gap. Leaving both closes it. Clicking the widget or inside the popup keeps it open until dismissed; buttons and controls still follow `dismissOnAction` and `dismissOnControl`. Hovering another widget does not replace a popup kept open by a click. Click-only behavior remains the default. **Customize → Your bar → Open popup on hover** changes an inline popup; for a shared popup, set `openOnHover` in its entry under `popups`.

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

`style` and `layout` are required. Use `"style": {}` to inherit the widget's theme. Without `height`, a popup fits its content when it opens; set `height` for a fixed size. Popup colors, typography, borders, corners and shadow inherit widget styles, then `popupDefaults`, then `defaults`. Popup width defaults to 360 points independently of the bar widget width; set it with `popup.style.width`. Padding and spacing can be overridden separately. Height is capped to the space below the bar; long content scrolls.

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

Display blocks can also have `onClick`, or `onClickField` to read a command from the current fields/list row. This allows a symbol button or a clickable agenda row. To open a URL or an app without a shell, use `open`, with the values a widget accepts, or `openField` to read one from the current fields/list row; a field value that `open` would reject does nothing when clicked. A block cannot combine `onClick` or `onClickField` with `open` or `openField`. A popup accepts `alignment` (`leading`, `center`, `trailing`) and `offset` for placement relative to its widget's drawn instance, including widget style offsets. With a below-bar indicator, the vertical gap starts below the visible bar and its reserved decoration strip, so a popup cannot cover the underline. A popup's optional `animation` controls its opening/closing fold and fade, revealing the content at its final size so the fold does not introduce scrollbars. Reduce Motion keeps only the fade. Native panel animation maps `smooth` and `spring` to ease-in-out; other curves retain their names. `dismissOnAction` defaults to `true`; set it to `false` for player controls that should keep the popup open. Images load asynchronously and update when their source path changes. Use a different local filename for each cover, or supply its URL.

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

For new native widget types, add a case to `WidgetContent`, decode its settings in `WidgetConfiguration`, return what it shows from `WidgetConfiguration.label` and give it a default layout in `WidgetConfiguration.defaultLayout`. New popup components belong in `PopupContent` and `PopupBlockView`. Runtime SwiftUI plugins and arbitrary chart types are not implemented.


## Architecture

- [Configuration.swift](Sources/StableBar/Configuration.swift): config, widget definitions and style inheritance.
- [StyleResolution.swift](Sources/StableBar/StyleResolution.swift): style layers and states resolved in one place for bar widgets, workspace cells, layout blocks and the bar, and the rules that set data states.
- [WidgetLabel.swift](Sources/StableBar/WidgetLabel.swift): what each widget type shows and the default layout it draws.
- [BarStore.swift](Sources/StableBar/BarStore.swift): live reload, shared provider lifetimes, visibility, sleep and each widget's resolved style.
- [ConfigurationLoader.swift](Sources/StableBar/ConfigurationLoader.swift): includes, profiles, tokens and provenance.
- [ConfigurationEdits.swift](Sources/StableBar/ConfigurationEdits.swift): file-preserving edits shared by CLI and editor.
- [RuntimeControl.swift](Sources/StableBar/RuntimeControl.swift): local request/reply control endpoint.
- [ConfigurationEditor.swift](Sources/StableBar/ConfigurationEditor.swift): preview, undo/redo and validated persistence.
- [NativeMetrics.swift](Sources/StableBar/NativeMetrics.swift): CPU, memory, network and calendar readings.
- [AudioMonitor.swift](Sources/StableBar/AudioMonitor.swift): output-device readings and CoreAudio change listeners.
- [PowerMonitor.swift](Sources/StableBar/PowerMonitor.swift): battery readings and power-change notifications.
- [WidgetPackage.swift](Sources/StableBar/WidgetPackage.swift): package inspection, installation, store downloads and version selection.
- [Workspaces.swift](Sources/StableBar/Workspaces.swift): AeroSpace subscriptions, yabai refreshes and workspace actions.
- [Yabai.swift](Sources/StableBar/Yabai.swift): yabai snapshots mapped to workspaces and screen numbers.
- [ScriptWidget.swift](Sources/StableBar/ScriptWidget.swift): the runner that applies a data source's output, with diagnostics, retries and suspension.
- [DataSource.swift](Sources/StableBar/DataSource.swift): the data source protocol, and the command, stream, polling and push sources.
- [DataSourceRegistry.swift](Sources/StableBar/DataSourceRegistry.swift): each data source type, the settings it reads, how it runs and the access it needs.
- [BuiltInEvents.swift](Sources/StableBar/BuiltInEvents.swift): the events StableBar sends itself and what `INFO` holds.
- [BarView.swift](Sources/StableBar/BarView.swift): native rendering and selection animation.
- [LayoutConfiguration.swift](Sources/StableBar/LayoutConfiguration.swift): groups, priority overflow and notch-aware placement.
- [PopupConfiguration.swift](Sources/StableBar/PopupConfiguration.swift): popup layout blocks.
- [PopupView.swift](Sources/StableBar/PopupView.swift): shared popup rendering and script bindings.
- [WidgetPopup.swift](Sources/StableBar/WidgetPopup.swift): anchored panel, dismissal and screen placement.
- [StableBarApp.swift](Sources/StableBar/StableBarApp.swift): non-activating panels and application lifecycle.

There is no web view, custom drawing loop or private window-server API. Styling and data updates are separate from window placement. Performance and long-term stability still need measurement with your actual widgets and displays.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers development setup, pull requests, commit messages, releases and the skills for coding agents. Report security issues privately, as described in [SECURITY.md](.github/SECURITY.md).

## License

StableBar is available under the [MIT License](LICENSE), including commercial use and redistribution.
