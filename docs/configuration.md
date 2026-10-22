# Configuration

StableBar reads one JSON file, by default `~/.config/stablebar/config.json`, and any files it includes.

## The configuration file

Save the configuration to apply changes. Direct saves and atomic file replacements are watched, including files imported with `includes`. Invalid edits retain the last working configuration and show an error indicator; click it to open Settings, which shows the error. Script instances, their last output, and graph history survive style-only changes, including when a script has an error.

Unknown properties are errors, so a misspelled key cannot be silently ignored. The last working configuration stays in place and the error names the property, for example `widgets.clock: style.fontsize: Unknown property.` For completion and validation in editors that support JSON Schema, start a configuration file with:

```json
"$schema": "https://raw.githubusercontent.com/Seb-GRAF/StableBar/main/stablebar.schema.json"
```

- `bar`: `height`, `offset`, `margin`, `inset`, `spacing`, `background`, `motion` and `popupTransition` (see [Animation](create-a-widget.md#animation)), `animationDuration` (seconds), `displayScale`, `appearance` (`light` or `dark` keeps the bar and its popups in that appearance; omit it to follow the system).
- `defaults`: styles inherited by every widget.
- `popupDefaults`: styles inherited by every popup, over `defaults`.
- `workspaceSource`: `aerospace` (default) or `yabai`, for workspace widgets and active-display tracking.
- `widgets`: ordered widget definitions with unique `id`, `type`, `position` and optional `style`, `icon`, `onClick` or `open`, `menu`, `popup`.
- `position`: `left`, `notchLeft`, `center`, `notchRight` or `right`.
- Colors: `#RRGGBB` or `#RRGGBBAA` (alpha last), or `{ "light": "#RRGGBB", "dark": "#RRGGBB" }` for a color that follows the light or dark appearance.
- Icons: SF Symbols names.
- Measurements: points.

Backgrounds (`background`, `hoverBackground`, a state's `background` and `bar.background`) can also be a linear gradient. `colors` takes two or more colors, `angle` is in degrees clockwise from towards the top as in CSS (`90`, the default, runs left to right; `180` runs top to bottom), and `locations`, one per color from 0 to 1 in ascending order, place the colors; without them the colors are evenly spaced. Text and border colors stay single colors.

```json
"defaults": { "background": { "gradient": { "colors": ["@token.accent", "#eb6f92"], "angle": 120, "locations": [0, 0.6] } } }
```

## Modules, templates and overrides

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

[examples/modular](../examples/modular/config.json) is a complete, dependency-free starter with a theme that styles the shared data states, a template, an event-only status that fades in new text, a CPU widget whose rules set those states, a clock whose digits roll, and an optional volume widget that shows the volume for a moment after a scroll or click, or when `volumeChange` reports a change made elsewhere. Try it without replacing your personal configuration:

```sh
./dist/StableBar.app/Contents/MacOS/StableBar --validate examples/modular/config.json
./dist/StableBar.app/Contents/MacOS/StableBar --config examples/modular/config.json
```

From another terminal, run `./dist/StableBar.app/Contents/MacOS/StableBar --trigger demo 'INFO=Build finished'`. The status changes to the supplied text. Enable the sample volume widget through its override to use click-to-mute and scroll-to-adjust.

## Theme tokens and automatic profiles

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

Set `"profile": "laptop"` to apply only that profile, regardless of its conditions. Remove `profile` to resume automatic matching, or set it to `null` to override a manual profile inherited from a module. **Settings → Status** reports active profiles and the file, template, override and token sources behind effective widget properties.

In **Settings → Profiles**, add a named profile, turn it on or off, and choose conditions with **+ Condition**. Conditions appear as removable chips; screen count has a stepper, and an app condition stores the chosen app’s bundle identifier. Cards show active and pinned profiles, their conditions and how many values they change. Profiles stay in configuration order; later matches win. Settings does not reorder profiles.

**What it changes** lists the profile’s values. Remove a change saved in your main file with its × button to restore inheritance. **Edit as JSON…** opens the configuration with an explicit **Apply** action; removing an inherited property there writes a null override. Included files stay unchanged. Removing a condition clears it, including an inherited condition.

**Edit the bar for this profile** opens Bar with a banner naming the profile being edited. The same banner stays visible in Theme. The profile menu in the Bar header and at the top of Theme, **No profile** or **Profile: Night**, does the same: choose a profile to edit it, or **No profile** to stop. Changes in Bar and Theme, including Reset, save only in that profile and use the normal Undo/Redo history. The profile is previewed while editing, even if disabled, without saving a pin or changing its enabled state. **Done**, leaving Bar and Theme, choosing another screen setup, or closing Settings restores the previous matching or pin. Widget order, theme selection and package settings apply to the whole bar; finish profile editing before changing them. **Preview now** pins the profile until **Stop previewing** resumes automatic matching; disabled profiles stay off outside editing.

Setup, the editor and the command line save changes into the main file's ordinary keys and never edit imported files. A widget defined in the main file, including inside one of its profiles, is changed, removed or reordered where it is defined. A widget from an include or package gets an entry in the main file's `widgetOverrides`; removing it sets `enabled` to `false`. Bar and default-style changes merge into `bar` and `defaults`. Untouched parts of the file keep their formatting and key order. An active profile still applies on top of these changes.

When every widget comes from the main file's `widgets` array, reordering changes that array. Otherwise the order is saved in `widgetOrder`: listed IDs come first, unlisted widgets keep their relative order, and IDs that are not currently present, such as widgets of an inactive profile, are skipped. On a kind of screen with its own layout, moves change its [`screens`](layout.md#screen-setups) layout instead.

Earlier versions saved changes in `customization` and `removedWidgets`. StableBar converts those keys into the ordinary ones the next time it starts. Earlier versions also wrote setup's appearance colors and the starter configuration's accent into `defaults`, where they hid any theme. The first time this version starts, StableBar replaces setup's Light and Dark colors with `bar.appearance`, removes the `null` widget colors that setup's Automatic choice wrote, since `null` now means no color, and removes the starter's `#007aff` accent. Colors you set yourself stay.
