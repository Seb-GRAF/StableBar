# Built-in widgets

| Type | Content | Additional fields |
| --- | --- | --- |
| `workspaces` (or `aerospace`) | Occupied or visible workspaces on this display, with app icons; click to switch | — |
| `activeApp` | Frontmost app name and icon | — |
| `appMenu` | Frontmost app's menus; click a title to open its menu | `expandOnHover`: show only the app name until hovered (default `false`) |
| `appleMenu` | Apple logo; click to open the Apple menu | — |
| `controlCenter` | Control Center icon; click to open macOS Control Center | — |
| `menuBarItems` | Grid symbol; click to list the items in the macOS menu bar, with their apps' icons, and open one | — |
| `clock` | Local date/time, updated each minute, or each second when the format shows seconds | `format`: DateFormatter format |
| `text` | Static text and optional icon | `text` |
| `script` | Output of a shell command | `command`, `interval` in seconds or `null` for event-only updates |
| `provider` | Shared command, stream or native data | `provider`: key from the top-level `providers` object |
| `system`, `network`, `battery`, `audio`, `calendar` | Native CPU and memory, network, battery, audio output or calendar data | — |

**Add widget** includes Clock & date, Active app, Apple menu, App menus, Control Center, Menu bar items, Battery, Sound, System monitor, Network, Calendar, Workspaces, Text and Spacer. Text starts with “New widget”. Apple menu, App menus, Control Center and Menu bar items need Accessibility access; Calendar asks for Calendar access; Workspaces needs AeroSpace, yabai, [OmniWM](#omniwm-workspaces) or [macOS Spaces](#macos-spaces-workspaces). Script starts with a clock command you can change through **More → Edit as JSON…**.

The AeroSpace connection subscribes to workspace, monitor, window and focus events. It loads an initial snapshot, coalesces pending events and reconnects after a disconnect with exponential backoff, capped at five minutes, and at once when AeroSpace launches. Ten seconds of connection resets the backoff. The accent color marks the focused workspace; an outline marks a workspace visible on another monitor. Empty, inactive workspaces are hidden. App icons are deduplicated per workspace unless `workspace.windows` is enabled. Active-app updates come from NSWorkspace notifications.

Window dragging is enabled only for the AeroSpace and yabai workspace sources. Drag an app icon onto another workspace to move that app's windows from the original workspace. With `workspace.windows: true`, dragging an item moves only that window; the [presentation example](../examples/presentation/config.json) uses this mode. Empty workspaces appear while dragging, and the destination is outlined; you can also drop onto a workspace on another display. Moving does not switch to the destination. Escape or dropping outside a workspace cancels the move. Clicks keep their usual behavior. OmniWM and macOS Spaces do not support dragging windows from the widget.

## Essentials details and settings

**Clock & date**, **Battery**, **System monitor**, **Network** and **Calendar** include detail popups when added from Essentials or **Add widget**. They replace the Date, Battery status, System monitor, Network speed and Calendar agenda Store choices. Previously installed Store copies become built-in automatically and keep their saved settings and overrides; local folders and private sources can still offer packages with those IDs.

Select a widget in **Settings → Bar → Content** to change what it shows. **Behavior → Details popup** turns its built-in popup on or off. Existing native widgets can opt in with `"details": true`. The five former Store packages gain Essentials details automatically when the app updates, while preserving saved settings and overrides. A custom `popup`, `popupName`, menu, `onClick` or `open` keeps its action instead of the built-in details.

- **Clock & date:** choose a time, date or combined format, or enter a custom DateFormatter pattern. Choose **Follow this Mac** or a time zone. The popup shows the current time and date and a month calendar with previous/next month and Today controls. **Open Calendar** opens the Calendar app; the month view needs no Calendar permission. The week starts on the day in your macOS regional settings.
- **Battery:** keeps the native battery glyph and its percentage/charging tooltip. The existing display choices can show a percentage, meter or graph. Its details show charge, power source, a time estimate when available, battery health and Battery settings.
- **System monitor:** shows CPU and memory, load, heat, memory pressure, swap and uptime, plus the apps using the most memory or CPU. The quit button asks before quitting. Set the refresh interval, number of apps, sort order and warning thresholds in Content. Set the app count to 0 to stop app sampling; set a threshold to 101% to turn off that threshold. Pressure and heat still warn. Newly added System monitor widgets use the theme’s warning and critical colors.
- **Network:** shows upload/download rates and a breakdown by active network interface. Choose bytes (KiB/s, MiB/s) or bits (kbit/s, Mbit/s), and the refresh interval. It uses the same native Ethernet/Wi-Fi interface counters as before.
- **Calendar:** shows the next meeting and its countdown, today’s agenda and meeting links. Set the rolling lookahead and the upcoming/starting warning times. Calendar access is requested when its source runs. The lookahead is a number of hours, not a today-only cutoff.

Data settings belong to the widget’s provider. Widgets sharing that provider share its settings; the inspector says so when several widgets use it. Edits made while editing a profile stay in that profile and support Undo. Custom layouts remain available through **Edit as JSON…**.

```json
{
  "providers": {
    "system": { "type": "system", "interval": 2, "processes": 5, "sortBy": "memory", "cpuWarning": 0.9, "memoryWarning": 0.9 },
    "network": { "type": "network", "interval": 5, "units": "bytes" }
  },
  "widgets": [
    { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm", "timeZone": "Europe/Zurich", "details": true },
    { "id": "battery", "type": "battery", "position": "right", "details": true },
    { "id": "system", "type": "system", "position": "right", "details": true },
    { "id": "network", "type": "network", "position": "right", "details": true },
    { "id": "calendar", "type": "calendar", "position": "right", "details": true }
  ]
}
```

A System monitor widget with details creates a default system provider sampling every 2 seconds and listing 5 apps, unless that provider is already configured. Other provider defaults are unchanged. For an older widget, turn on Details and set the app count in Content to show its app list.

## App menus

An `appMenu` widget shows the frontmost app's menus, such as File, Edit and View, with the app's own menu in bold. In **Settings → Bar**, select App menus and turn on **Expand on hover** to show only the app name until the pointer enters the widget. Expanding the menus takes the free room beside them and slides only the widgets in that room; nothing hides or moves out of the way. When the menus don't fit there, hovering the app name opens them as a row under the bar instead: click a title to open its menu, then move across the titles. The menus stay expanded while one is open. Leave the setting off to show all titles.

Click a title to open its menu in a popup below the bar, drawn in your theme's popup style. While a menu is open, move the pointer onto another title to switch to its menu, as in the macOS menu bar; with **Morph between popups** on, the open menu changes into the next one. Rest the pointer on an item with a submenu, or click it, to open the submenu beside it.

The Apple logo is a separate `appleMenu` widget. Add **Apple menu** to show it, or leave it out to keep only the app's menus.

Both menu widgets use the configured hover background and keep their normal text color when hovered.

```json
{
  "widgets": [
    { "id": "apple", "type": "appleMenu", "position": "left" },
    { "id": "menus", "type": "appMenu", "position": "left", "expandOnHover": true }
  ]
}
```

StableBar reads the titles through Accessibility when you switch apps, wake or unlock your Mac, and when the pointer enters either widget. If a read fails while an app is becoming ready, the widgets keep their last complete menus and retry for a few seconds. Each menu is read from the app when it opens, so it works while the macOS menu bar is hidden; choosing an item chooses it in the app. These menus show items, separators, checkmarks and submenus, but not keyboard shortcuts. Allow StableBar in **System Settings → Privacy & Security → Accessibility**; until then the widgets show a warning. Its first click shows the macOS prompt, and later clicks open that pane. While a StableBar window such as Settings is in front, the widgets keep the previous app's menus.

## yabai workspaces

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

## OmniWM workspaces

[OmniWM](https://github.com/OmniNull/OmniWM) runs on Apple Silicon Macs with macOS 26 or later. Turn on **Enable IPC** in OmniWM's menu, then set the source:

```json
{
  "workspaceSource": "omniwm",
  "widgets": [{ "id": "spaces", "type": "workspaces", "position": "left" }]
}
```

StableBar runs `omniwmctl` from your login shell's `PATH`, or the copy inside OmniWM's app, so **Install CLI to PATH** is optional. It subscribes to workspace, window, focus and display changes, so OmniWM needs no signals, and it reconnects like the AeroSpace connection, at once when OmniWM launches. Cells keep OmniWM's workspace order and show each workspace's display name. The focused workspace is the active one on the display you're using, even when it is empty. Clicking a workspace runs `omniwmctl workspace focus-name NAME`, and clicking a window item focuses that window. Scratchpad windows aren't shown. If the widget says it can't reach OmniWM, check that OmniWM is running with **Enable IPC** on, then choose **Reconnect** in **Settings → General → Workspaces**.

## macOS Spaces workspaces

Without a tiling window manager, workspace widgets can show your Mission Control Spaces:

```json
{
  "workspaceSource": "spaces",
  "widgets": [{ "id": "spaces", "type": "workspaces", "position": "left" }]
}
```

Choose **Spaces** under **Settings → General → Workspaces** to set the same source. Desktops are numbered across displays like Mission Control, and each display shows its own. Fullscreen apps have no desktop number and don't appear. StableBar refreshes when the active Space changes and when apps launch, quit or come to the front, so a window moved to another Space shows there after the next such change.

Clicking a desktop posts its **Switch to Desktop N** shortcut. Turn those shortcuts on in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, and allow StableBar in **System Settings → Privacy & Security → Accessibility**. macOS offers the shortcuts for desktops 1 to 16. Clicking a window title brings its app to the front. Window titles need Screen Recording access; without it they are empty.

macOS has no public API that lists Spaces or their windows, so this source uses private window-server functions. A macOS update can break it; AeroSpace, yabai and OmniWM don't depend on them.

## Workspace appearance

A `workspaces` widget (also accepted as `aerospace`) accepts `workspace` with:

- `indicator`: `background` (default), `underline` or `none`.
- `indicatorStyle`: underline `height`, `width`, `background`, `cornerRadius`, `offsetX`, `offsetY` and `placement`. `"cell"` (default) preserves the cell-relative underline; `"belowBar"` puts its top at the visible bar background's bottom plus `offsetY`, independently of the cell height. Negative `offsetY` moves the underline upward; the **Bar → Style → Workspaces** and **Theme → Advanced → Workspace look** controls in Settings accept negative offsets too. Its `states.focused` and `states.visible` style the underline under the focused workspace and under a workspace shown on a display without focus; mode states apply after those.
- `style`: cell typography, foreground, width, height, horizontal/side padding and spacing. Its `states` style each cell by workspace state: `focused` (the focused workspace), else `visible` (shown on a display without focus), else `empty` (no windows), so a cell has at most one. `focusedStyle`, `visibleStyle` and `emptyStyle` are shorthand for those states. The background indicator uses the state's background or border color. `hover` changes the label and app glyphs; the indicators follow the workspace state. `defaults.states` don't apply to cells.
- `showEmpty` and `showApps`: control empty workspaces and app icons.
- `windows`: when `true`, shows one item per window instead of one per app. Each item keeps its app icon or `appGlyphs` glyph. Clicking it focuses that window; clicking the workspace number or cell padding switches workspace. `showApps: false` hides these items too.
- `titleLength`: maximum characters of each window title when `windows` is enabled. Omit it or use `0` for icons only. For example, `"workspace": { "windows": true, "titleLength": 24 }`. The full title is available on hover. Titles refresh with workspace and window events; yabai users can also register `window_title_changed`.
- `appStyle`: font and foreground for app glyphs, width and height in screen points for native app icons (14 × 14 by default). `focusedAppStyle` and `visibleAppStyle` are shorthand for its `states.focused` and `states.visible`.
- `appGlyphs`: app bundle ID or app name to text glyph. Set `appStyle.fontName` to an installed icon font to use its ligatures. A key ending in `*` matches app names that start with the rest of the key, such as `Adobe Photoshop*` for `Adobe Photoshop 2026`. Exact bundle IDs and names win over these keys, and among them the longest key wins. Use `"*"` alone for the fallback glyph; otherwise unmapped apps retain native icons.

Cells fit their labels and app icons by default, with the same widget padding as other widgets. Vertical widget padding extends the selection background so it fills the widget's height. Set `workspace.style.height` for a fixed cell content height before that padding.

Adjust only the workspace widget's padding in **Settings → Bar → Style → Padding and corners**, or set its `style.paddingVertical`, for example `"style": { "paddingVertical": 4 }`. `style.paddingTop` and `style.paddingBottom` override it individually.

For a sliding underline, set `workspace.indicator` to `underline`, `workspace.style.height` to the bar's height, and `workspace.indicatorStyle` to `{ "height": 2, "background": "#f1efe8", "states": { "visible": { "background": "#f1efe866" } } }`, which dims the underline on displays without focus. The widget's `animation` controls its motion.

To place it just below the bar instead, use `"indicatorStyle": { "placement": "belowBar", "height": 2, "offsetY": 0 }`; set `offsetY` to a positive gap when wanted. Its span follows the visible cell and is clipped to the workspace widget's scrolling region. Overflowed widgets and hidden measuring copies emit no underline. This decoration does not stretch the colored background or move labels. A native decoration window reserves space for every configured state and always ignores mouse events. The bar itself keeps its original hit bounds and background menu; clicks in the extra strip pass to the window beneath; popups open below the bar/decorations on the display of the instance that opened them. Reduce Motion disables underline motion, and edges align to display pixels.

For glyphs from [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font), install the font from its releases or with `brew install --cask font-sketchybar-app-font`, then save the [sketchybar-app-font module](../examples/modules/sketchybar-app-font.json) next to your configuration:

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

## Menu bar items

A `controlCenter` widget opens macOS Control Center. A `menuBarItems` widget shows a grid symbol; click it to see every item in the macOS menu bar as a row of icons, in menu bar order. Each icon is its app's icon, or a system symbol for Battery, Clock, Control Center and Search. Rest the pointer on an icon to see its name. Click the widget again to close the row.

Clicking an icon whose app has an ordinary menu opens that menu below it, in your theme's popup style. While a menu is open, move the pointer to another icon to switch to its menu. Items that draw their own panel, such as Control Center, Battery or Clock, open their panel as macOS does. To open them, StableBar briefly brings out the hidden menu bar and keeps it invisible until the item closes. Both widgets need Accessibility access. StableBar's own menu bar icon isn't listed.

## Tooltips

Set a widget's `tooltip` to show text when the pointer rests on it. It works without a popup and keeps the widget's click action. For example, add `"tooltip": "Will not sleep for 1 hour"` to an Amphetamine widget. You can also edit **Tooltip** in the widget’s **Settings → Bar → Behavior** inspector.

Tooltips inherit `defaults`, `popupDefaults`, and the widget's explicit `style`, using the same colors, font, border, corners, shadow, and glass treatment as popups. Their size fits the text. They open and close with the bar's popup [motion and transition](create-a-widget.md#animation), like the [hover controls](create-a-widget.md#controls-on-hover) of Sound and other widgets.

A tooltip opens once the pointer has rested on its widget for `bar.hoverDelay` milliseconds, 400 by default, the same wait as hover controls and popups that open on hover. Change it under **Delay** in **Settings → General → Hover**. While one of them is open, moving to another widget opens that widget's at once, as macOS does, and with **Morph between popups** the open one moves into it.

A configured tooltip overrides the script's tooltip. To show changing information, such as the remaining awake time, leave the widget's `tooltip` unset and return `tooltip` in the script's JSON output:

```json
{"text":"","icon":"pill.fill","tooltip":"Will not sleep for 1 hour"}
```

The script supplies the current text on each update; StableBar does not calculate the remaining time. Clearing the field in Settings restores the script's tooltip. In JSON, `"tooltip": ""` hides it. Script errors still appear in tooltips.

## Mouse actions

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
