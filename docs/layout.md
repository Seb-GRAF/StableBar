# Displays and layout

## Displays and notch placement

`notchLeft` ends before the notch and `notchRight` starts after it. `bar.notchSpacing` controls the gap on each side (16 by default). The notch comes from the screen's unobscured top areas; `bar.notchWidth` can override its width. On screens without a notch, `notchLeft`, `center` and `notchRight` form one centered group, measured from the visible content. Hidden groups leave no gap. With a notch, `center` joins the right side, between `notchRight` and `right`.

Each widget accepts `display`: `"all"` (default), `"active"`, `"main"`, `"builtIn"`, `"external"`, `"monitor"` (landscape external screens), `"vertical"` (screens taller than they are wide), `"notched"`, `"unnotched"`, an array of these to show the widget on any of them, for example `["builtIn", "vertical"]`, or an array of screen numbers, for example `[1, 2]`. Numbers are one-based positions in `NSScreen.screens`, matching AeroSpace and SketchyBar; they can change when displays are rearranged. `active` follows the configured workspace source's focus. With AeroSpace, use `aerospace list-monitors --format '%{monitor-name}|%{monitor-appkit-nsscreen-screens-id}'` to list them. yabai and OmniWM display IDs are mapped to these screen numbers, independently of the window manager's display ordering, and so are macOS Spaces displays.

Set `bar.displayScale` to `{ "builtIn": 0.85, "external": 1 }` to shrink the laptop bar while keeping external displays at their original size. Each factor scales the bar height, widgets, text and spacing; omitted display types use `1`. Factors must be positive, and other keys are rejected. The bar offset, margin and popup sizes stay in screen points. This setting also works inside automatic profiles.

`bar.style` accepts `background`, `cornerRadius`, `borderColor`, `borderWidth` and `borderEdges`. The border defaults to `"bottom"`; `"all"` draws all four edges just inside the visible strip, following its corners. The outline does not change panel size, window clearance or clicks. A notch or the system menu bar can obscure part of the top edge. `bar.margin` (0 by default) insets the bar's background and widgets from every edge of the bar, so a rounded `bar.style` floats below the top of the screen and in from its sides. The bar keeps its height, so the visible strip is `height` minus twice the margin. Scripts can return `barStyle` to change those properties; later widgets override earlier widgets when they set the same property.

## Screen setups

A screen setup is a combination of connected screens: the laptop only, a monitor only, the laptop with a monitor, the laptop with a monitor and a vertical monitor, and so on. A vertical monitor is a screen taller than it is wide. Each setup can have its own bar, with its own widgets on each screen, size, theme and placement. StableBar switches bars when you connect or disconnect a screen.

Setups start with the shared bar, your main configuration. In **Settings → Bar**, the menu beside the screen thumbnails names the setup you are editing, and whether it uses the shared bar or its own, such as **Laptop + monitor (connected) · shared bar**. Open it and choose **Give it its own bar**. The same action is available in the **Bar → Placement** inspector. StableBar copies the shared bar into a file beside it, such as `setup-laptop+monitor.json`, and from then on everything you change while those screens are connected changes that bar only, except in **Theme**. Theme changes go to the shared bar and every setup's own bar, so they still show after you connect or disconnect a screen. To change the look of one bar only, choose **This setup only**, or **Shared bar only** while editing the shared bar, next to **All setups** at the top of Theme. One **Undo** reverses a change in every bar. While you edit a profile, Theme changes stay in the bar you're editing. **Copy bar from** starts the own bar from the shared bar or another setup's own bar instead. **Use the shared bar again…** moves its own bar to the Trash after confirmation.

The menu lists the connected setup, each connected kind of screen on its own, such as **Laptop only**, and every setup with its own bar, each marked **own bar** or **shared bar**. Choosing a setup that isn’t connected previews it: the bar on your screens shows that setup's bar and Settings edits it, so you can change the laptop alone while docked. Choosing the connected setup again, closing Settings, or connecting or disconnecting a screen returns to the connected setup. Each file is a normal configuration file: includes, packages and `$CONFIG_DIR` work as in the main file, and command-line changes go to the bar on the screens. Switching bars discards temporary command-line changes and clears Undo. Uninstalling a package version that another setup's bar uses is refused until you remove it from that bar.

Within a setup, select a screen-kind thumbnail in **Bar**, then use a widget’s eye control to show or hide it on that kind of screen. A widget's **Shows on** menu also offers the laptop, landscape monitors and vertical monitors, plus display rules. Screens of the same kind remain grouped and show the same widgets; the thumbnails do not select individual monitors of that kind. Specific display IDs remain editable as JSON. While editing the bar in place, a widget's context menu offers the same choices under **Shows On**.

Each kind of screen can also have its own layout, bar size and look. While another kind of screen is connected, moving a widget in **Bar** or on the bar itself moves it only on the selected kind of screen. In the **Bar** inspector, switch from **Every screen** to the selected screen to set its height, corner radius, insets, spacing, background, border, offset or margin. In **Theme**, switch to the selected screen to give it its own theme, appearance, colors, widget, popup and bar styles, Liquid Glass, presentation roles, workspace look and AeroSpace mode names. StableBar saves these under `screens`:

```json
"screens": {
  "laptop": {
    "theme": { "id": "everforest" },
    "tokens": { "accent": "#7fbbb3ff" },
    "defaults": { "fontSize": 14 },
    "popupDefaults": { "cornerRadius": 10 },
    "bar": { "height": 32, "style": { "cornerRadius": 0 } },
    "layout": { "left": ["apple", "workspaces"], "center": [], "right": ["wifi", "clock"] }
  }
}
```

`theme` replaces the shared theme on that kind of screen, and `tokens`, `defaults`, `popupDefaults`, `roles`, `workspaceDefaults` and `modeAliases` merge over the shared ones; active profiles still apply on top. `bar` accepts `height`, `offset`, `margin`, `inset`, `spacing`, `background`, `notchWidth`, `notchSpacing`, `style`, `glass` and `appearance`, merged over the shared `bar`. Each `layout` list names widget IDs, in order, for that position: `left`, `notchLeft`, `center`, `notchRight` or `right`. Widgets the layout doesn't list keep their own position after the listed ones, and IDs that are not present are skipped. Once a kind of screen has a layout, moves on it keep changing that layout, even when it is the only screen connected. A widget's own settings and content stay shared.

Right-click a screen thumbnail, or use its **⋯** button, to split or copy that screen's bar. **Own layout and size for this screen** saves the order it shows now as its layout; turning it off removes its `screens` entry so it follows the shared bar again. **Copy from** gives the screen another screen's widgets, order and bar size in one Undo step.

## Adaptive layout and groups

Widgets keep their configured order within `left`, `notchLeft`, `center`, `notchRight`, and `right`. The center cluster shifts within the free space before anything overflows. On a notched screen, `center` widgets join the right side of the notch; neither side can use the other side's space.

Set `priority` on a widget to keep it visible longer; higher numbers win. The default is `0`. When space runs out, lower-priority widgets move behind a **More widgets** button (**⋯**), drawn like the other widgets. On a notched screen, each side has its own button beside the widget nearest the notch, and among equal priorities the widgets next to the notch go first. Elsewhere one button follows the last widget, and equal priorities overflow from the end of the configuration first. Click the button to show those widgets in a popup, drawn as on the bar: their clicks, popups, workspaces and app menus work there, and app menus show all their titles. A popup opened there replaces the list under the button. Hover popups, tooltips and hover controls don't open in it. Widgets return automatically when space becomes available, and the bar animates them in and out with its motion. A widget that grows under the pointer, such as app menus that expand on hover, keeps its place; its neighbors make room.

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

The [interactive example](../examples/interactive/config.json) combines groups, an expanding spacer, constrained text that rolls to the new app's name, and all popup controls. Copy both files from `examples/interactive` into your configuration directory. Its controls update demo state in `.control-state` next to the configuration; they do not alter macOS settings. The app list opens the selected application.
