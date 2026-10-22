# Create a widget

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
- `state`: the widget's data state, such as `warning`; see [Data states](styling.md#data-states).
- `temporary`: fields shown over the output's own for `duration` seconds, before the widget returns to its output (at most one day). A volume script can return `{"text":"","icon":"speaker.wave.2","temporary":{"fields":{"text":"62%"},"duration":1.5}}` after a change. A `text` or `icon` field replaces the widget's text or icon, and an empty `icon` hides it. A different `temporary` starts over, as does the same one after it ran out; the same one again while it shows, or an output without one, lets it run out. Its fields come and go with the widget's `animation`, unless Reduce Motion is on.

A nonzero exit, timeout, excessive output or invalid JSON preserves the previous output and adds a warning with the error in its tooltip. Repeated polling failures increase the retry delay exponentially up to five minutes, without shortening a configured interval longer than that. A successful update resets the delay; event-only scripts retry on their next event or action. A completed click action requests an immediate refresh. `onClick` runs only when clicked.

Commands have a 10-second timeout by default. Set a widget's `timeout` to another positive number of seconds; it applies to both updates and actions. Stdout and stderr are each limited to 1 MiB. Successful stderr logging does not corrupt the widget's stdout JSON. Failures display stderr, stdout, or the exit status when neither contains a message.

Commands must finish; do not start background daemons from widget scripts. Timeout, cancellation, and shutdown kill the command's process group and direct process. A descendant that deliberately starts another session or process group can outlive it, but cannot hold the widget's output pipe open past its timeout.

## Script events

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

## Composing widgets

A widget's `layout` uses the same blocks as a popup. Use rows and columns to style the label, icon and other elements independently. Bar layouts take their content's width; popup layouts fill their available width. Give graphs, progress blocks and images explicit sizes when they should have a fixed footprint.

A widget without `layout` draws a default layout made of the same blocks: a `row` of its icon (`symbol`) and text (`field`), at least a line of text tall even when it shows only the icon. Its digits all have the same width, so a number that changes, such as a CPU percentage, doesn't resize the widget. Battery shows only its icon and current value. Sound shows only its speaker icon, whose waves show the volume: none at zero, then one, two or three. The icon keeps the width of three waves, so the widget doesn't change size between levels. After the volume changes, the new volume fades in beside it for a moment, its digits rolling while it keeps changing, then fades out. Muting hides it at once. Hovering it opens a volume slider beside the icon, with the volume, that changes the volume as you drag. On the right of the bar the slider opens to the icon's left, so the icon stays under the pointer; elsewhere it opens to the right. A Sound widget with a `layout` of its own, including a **Display** choice other than its default, has no slider. The bar animates the Sound widget's width as the volume and the slider come and go, unless Reduce Motion is on. Other script and provider widgets whose output has a `value` show a 40 × 16 `graph` before them, and active-app widgets show the app's icon instead of a `symbol`. Workspaces and spacers keep their own views. A `layout` replaces the default layout, so block options work on built-in widgets too, for example an app name that scrolls when it doesn't fit: `"layout": { "type": "field", "field": "text", "scrollSpeed": 30, "style": { "maxWidth": 120 } }`.

For battery, sound and system, **Settings → Bar → Content → Display** offers icon and value, icon only, value only, meter and value, or graph and value. Sound starts with icon, value on change, its default, and system with graph and value. This also works with named battery/audio/system providers and package widgets. Choices use the existing `layout` configuration and support Undo; a hand-written layout stays marked **Custom layout** until you choose another display.

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

## Animation

`bar.motion` sets how the bar moves wherever a widget or popup sets no `animation` or `transition` of its own: widget changes such as colors and the workspace highlight, the widgets that slide aside when the active app or an app menu changes width, popups opening and closing, and changing text. Choose it in **Settings → Theme → Animation**:

- `smooth`, the default: widgets move over 0.35 seconds on a smooth curve, popups fade in over 0.25 seconds, and changing text cross-fades.
- `subtle`: widgets ease out over 0.22 seconds, popups fade in over 0.15 seconds, and text changes at once.
- `snappy`: quick springs with a hint of overshoot, as in iOS. Widgets move over 0.3 seconds, popups zoom out of their widget over 0.35 seconds, and changing text cross-fades.
- `bouncy`: widgets spring with a clear overshoot over 0.45 seconds, popups zoom out of their widget over 0.4 seconds, and changing text rolls up.
- `none`: everything changes at once.

`bar.popupTransition`, **Popups** beside **Motion** in Settings, sets how popups open and close instead of the motion's choice: `fade` fades them in while they grow slightly from their top edge, `unfold` reveals them from top to bottom, `slide` slides them down from the bar, and `zoom` grows them out of the widget that opened them. Each closes the way it opened. With `bar.morphPopups` (**Morph between popups** in Settings, off by default), opening another widget's popup on the same bar while one is open moves the open popup into the new one instead of closing it. `bar.animationDuration` sets another duration for widget motion and keeps the motion's curve. App menus that expand on hover reveal their titles from left to right while the widgets beside them slide, and fold them away the same way. Reduce Motion stops widget motion and transitions; popups only fade.

Widgets and blocks accept `animation` with `duration` in seconds and `curve`: `linear`, `easeIn`, `easeOut`, `easeInOut`, `smooth`, `spring`, `snappy` or `bouncy`. Widget animation defaults to the bar's motion. It doesn't apply to hover: as in the macOS menu bar, a hover highlight on a widget, workspace or app menu appears at once and fades out over 0.1 seconds. Block style animations are opt-in. Progress values use a 0–1 scale, clipped to that range when drawn. A progress block can also read a numeric string from its current list row when there is no matching entry in `values`. With a matching entry in `targets`, a progress rule starts at `values[source]` and animates toward `targets[source]`; without a target it animates between readings. Reduce Motion disables these animations.

Widgets and text, field and symbol blocks accept `transition`, so changed text and symbols animate instead of snapping: `fade` cross-fades, `roll` slides the new content up from below, `numeric` rolls the digits that changed (symbols fade), and `none` swaps them at once. A widget without a `transition` takes the bar's [motion](#animation): `fade` with `smooth` and `snappy`, `roll` with `bouncy`, otherwise `none`. A widget's `transition` applies to its default layout and to the text, field and symbol blocks of its `layout` and `overlay` that set none of their own. A transition uses the block's `animation`, else the widget's; in popups, the block's or 0.22 seconds. Blocks that appear or disappear, such as with `hideWhenEmpty`, don't transition, but a widget whose transition isn't `none` fades or rolls in and out when its output's `hidden` changes, and the widgets beside it slide into place. Reduce Motion turns transitions off.

## Controls on hover

Set `hoverLayout` to reveal extra blocks beside a widget when the pointer enters it. It uses the same blocks as `layout` and `popup`, including sliders. On the right of the bar, the controls open to the left so the widget stays under the pointer. Neighboring widgets move aside, and a slider stays open while you drag it. Motion follows the widget's `animation` and respects Reduce Motion.

```json
"hoverLayout": {
  "type": "slider",
  "title": "Duration (minutes)",
  "source": "duration",
  "min": 15,
  "max": 240,
  "step": 15,
  "onChange": "my-timer set-duration \"$VALUE\"",
  "style": { "width": 100, "height": 16 }
}
```

Provide the current slider value in script output `values.duration`; `onChange` receives `VALUE` when the drag ends. Inline control labels are hidden, with their titles kept for accessibility. Set a width on sliders to give them space in the bar.

A widget with `hoverLayout` runs its `onClick` command when clicked, even when it also has a popup. Without `onClick`, clicking still opens its popup. Tooltips stay hidden while inline controls are available. Add or edit `hoverLayout` through the widget's **Edit as JSON…** action or the CLI; includes, templates, profiles, and package overrides merge it like `layout`. Set it to `null` to remove it.
