# Coming from SketchyBar

Much of a SketchyBar setup carries over. Items become widgets, plugins stay shell scripts, and scripts get the variables SketchyBar sets, under the same names: `NAME`, `SENDER`, `INFO`, `SID`, `BUTTON`, `MODIFIER`, `SCROLL_DELTA` and `CONFIG_DIR` (see [Script events](create-a-widget.md#script-events)). The bar itself is a JSON file instead of `sketchybarrc`, and plugins print what to show instead of calling `sketchybar --set`.

## What maps to what

| SketchyBar | StableBar |
| --- | --- |
| `sketchybarrc` | `~/.config/stablebar/config.json`, applied when you save it; see [Configuration](configuration.md) |
| `sketchybar --bar` | `bar` |
| `sketchybar --default` | `defaults` |
| `--add item NAME left` (`right`, `center`, `q`, `e`) | A widget with `"id": "NAME"` and `position` `left` (`right`, `center`, `notchLeft`, `notchRight`) |
| Item with `script` and `update_freq` | `script` widget with `command` and `interval` |
| Item with `script` and no `update_freq` | `"interval": null`, which runs it at startup and then only on its events; without `interval`, it runs every 30 seconds |
| `--subscribe NAME EVENT …` | `events` on the widget |
| `sketchybar --set "$NAME" label=… icon=…` in the script | The script prints `text`, or JSON with `text` and `icon`; see [Create a widget](create-a-widget.md) |
| `drawing=off` | `"hidden": true` in the script's output |
| `click_script` | `onClick`, or `open` for a URL or an app |
| `click_script` for the right or middle button | `actions.rightClick`, `actions.middleClick` |
| `mouse.scrolled`, `mouse.entered`, `mouse.exited` | `actions.scrollUp`/`scrollDown`, `mouseEntered`, `mouseExited`; see [Mouse actions](widgets.md#mouse-actions) |
| `label.color`, `background.color`, `background.corner_radius`, `padding_left` | `style.foreground`, `background`, `cornerRadius`, `paddingHorizontal`; see [Styles and states](styling.md) |
| `label.font="Family:Style:Size"` | `style.fontName`, `fontWeight` and `fontSize` |
| `bracket` | `groups`, with `group` on each member; see [Adaptive layout and groups](layout.md#adaptive-layout-and-groups) |
| Items in `popup.NAME` | `menu` in the script's output, or `popup` with a layout; see [Custom popups](popups.md) |
| `graph` items and `--push` | `value` in the script's output, or a `graph` block |
| `slider` items | A `slider` block in a popup or in `hoverLayout` |
| `space` items and a `space.sh` plugin | The `workspaces` widget; see [Built-in widgets](widgets.md) |
| `alias` | An entry in a `menuBarItems` widget's `shown`, with `"display": "live"` to draw it as the menu bar does on macOS 27; see [Items on the bar](widgets.md#items-on-the-bar) |
| `display` and `associated_display` | `display`; see [Displays and notch placement](layout.md#displays-and-notch-placement) |
| `--animate` | `animation` and `transition`; see [Animation](create-a-widget.md#animation) |
| `--add event NAME NOTIFICATION` | The notification's name in `events` |
| `sketchybar --trigger` | `StableBar --trigger` |
| `sketchybar --query`, `--reload`, `--add`, `--set`, `--remove` | `StableBar --query`, `--reload`, `--add`, `--set`, `--remove`; see [Command-line controls](command-line.md) |

## Events

| SketchyBar | StableBar |
| --- | --- |
| `front_app_switched` | `frontApp` |
| `space_change`, or a custom event such as `aerospace_workspace_change` | `workspace` |
| `system_woke` | `wake` |
| `volume_change` | `volumeChange` |
| `power_source_change` | `powerSourceChange` |
| `wifi_change` | `wifiChange` |

`INFO` doesn't always hold what SketchyBar sends: `powerSourceChange` sends `ac` or `battery` rather than `AC` or `BATTERY`, and `workspace` sends the workspace's name rather than a JSON object of displays and spaces. [Script events](create-a-widget.md#script-events) lists what each event sends, and StableBar's other events, such as `outputDeviceChange` and `privacyChange`. StableBar has no `space_windows_change`, `display_change`, `brightness_change`, `media_change`, `system_will_sleep` or global mouse events. A distributed notification can stand in for some, such as `com.spotify.client.PlaybackStateChanged` for Spotify.

## What differs

- **Scripts print, the bar draws.** A script prints plain text or one JSON object, and StableBar shows it on the widget that ran it. To feed several widgets from one command, use a [shared provider](providers.md). To restyle another widget, return `widgetStyles`.
- **Every script runs at startup**, with `SENDER=startup`, so there's no `sketchybar --update` to call. StableBar sends `startup` where SketchyBar sends `forced`.
- **A click refreshes the widget.** When `onClick` finishes, the widget's command runs again with `SENDER=action`.
- **Icons are SF Symbols.** `icon` takes an SF Symbol name, such as `battery.75`. To show a glyph from an icon font, such as a Nerd Font, put it in the text and set the widget's `style.fontName` to that font, or draw it in its own block of a [layout](create-a-widget.md#composing-widgets). For app icons in workspaces, StableBar has a [sketchybar-app-font module](widgets.md#workspace-appearance).
- **Colors put alpha last.** SketchyBar's `0xAARRGGBB` becomes `#RRGGBBAA`: `0xff1e1e2e` is `#1e1e2eff`, or `#1e1e2e`, and `0x80000000` is `#00000080`.
- **Workspaces connect themselves.** The `workspaces` widget reads AeroSpace, OmniWM, Rift or macOS Spaces directly, so AeroSpace's `exec-on-workspace-change` doesn't need to call the bar. yabai needs signals that run `StableBar --trigger yabai`; see [yabai workspaces](widgets.md#yabai-workspaces).
- **Many plugins are built in.** The clock, battery, sound, Wi-Fi, CPU, network, calendar, app menus and more are [built-in widgets](widgets.md) that need no script.

## Port a plugin

SketchyBar's default configuration shows the battery with this item:

```sh
sketchybar --add item battery right \
           --set battery update_freq=120 script="$PLUGIN_DIR/battery.sh" \
           --subscribe battery system_woke power_source_change
```

and this plugin, with its Nerd Font glyphs left out:

```sh
#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

case "${PERCENTAGE}" in
  9[0-9]|100) ICON="…"
  ;;
  [6-8][0-9]) ICON="…"
  ;;
  [3-5][0-9]) ICON="…"
  ;;
  [1-2][0-9]) ICON="…"
  ;;
  *) ICON="…"
esac

if [[ "$CHARGING" != "" ]]; then
  ICON="…"
fi

sketchybar --set "$NAME" icon="$ICON" label="${PERCENTAGE}%"
```

In StableBar, the item becomes a widget in `~/.config/stablebar/config.json`. `update_freq` becomes `interval`, and the two events take their StableBar names:

```json
{
  "widgets": [
    {
      "id": "battery",
      "type": "script",
      "position": "right",
      "command": "\"$CONFIG_DIR/plugins/battery.sh\"",
      "interval": 120,
      "events": ["wake", "powerSourceChange"]
    }
  ]
}
```

Save the plugin as `~/.config/stablebar/plugins/battery.sh` and make it executable with `chmod +x`. Two things change: the glyphs become SF Symbols, and the last line prints JSON instead of calling `sketchybar`:

```sh
#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

case "${PERCENTAGE}" in
  9[0-9]|100) ICON="battery.100"
  ;;
  [6-8][0-9]) ICON="battery.75"
  ;;
  [3-5][0-9]) ICON="battery.50"
  ;;
  [1-2][0-9]) ICON="battery.25"
  ;;
  *) ICON="battery.0"
esac

if [[ "$CHARGING" != "" ]]; then
  ICON="battery.100.bolt"
fi

printf '{"text":"%s%%","icon":"%s"}\n' "$PERCENTAGE" "$ICON"
```

On a Mac without a battery, the script prints nothing and the widget takes no space. StableBar's built-in battery widget does the same without a script: `{ "id": "battery", "type": "battery", "position": "right" }`.
