# Custom popups

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/popups-dark.webp">
  <img src="images/popups-light.webp" alt="Three popups: CPU and memory with a graph, today's agenda, and a panel with a slider, a toggle, a segmented control and a search field">
</picture>

Add `popup` to any widget. For a popup shared by multiple widgets, define it once in the top-level `popups` object and set each widget's `popupName` to its key. Each anchor uses its own script data. An inline `popup` takes precedence over `popupName`. It takes precedence over `menu` and `onClick`. Its layout is independent of the script, so you can change the layout without changing the data source or rebuilding the app. The example below uses the fields returned by the script output that follows it. While a popup shows, the widget that opened it uses its `open` state; see [States](styling.md#states).

Widgets with `menu` entries already open a shared popup without additional configuration. To customize that popup, add `popup` with your preferred style and `"layout": { "type": "menu" }`. You can also place a `menu` block alongside other blocks in a custom layout. Entries retain their titles, details and click commands, and refresh while the popup is open.

Set `popup.openOnHover` to `true` to open after the [hover delay](widgets.md#tooltips), 0.4 seconds by default. The popup stays open while the pointer is over the widget or popup, with a short grace period to cross the gap. An invisible triangle from the widget to the popup protects diagonal movement toward it, so crossing a neighbouring widget does not replace it while you move into it. Moving away or stopping outside closes it after the grace period. Clicking the widget or inside the popup keeps it open until dismissed; buttons and controls still follow `dismissOnAction` and `dismissOnControl`. Hovering another widget does not replace a popup kept open by a click. Click-only behavior remains the default. **Settings → Bar → Behavior → Open its popup on hover** changes an inline popup; for a shared popup, set `openOnHover` in its entry under `popups`.

Set `popup.pinnable` to `true` to show a pin button in the popup's top trailing corner; leave room for it there, and for the close button that joins it while the popup is pinned. Dragging the popup by its background pins it where you drop it. A pinned popup stays on screen through clicks elsewhere, app switches and other popups, keeps updating, and moves when you drag its background. Drag its edges to resize it: it then keeps that size instead of fitting its content, and fields with `maxHeight` take the height you give it. Its buttons and controls don't close it. Pin the widget's popup again later and it glides back to where you left it, at the size you left it. Unpin it to send it back under its widget, where it keeps its size and closes like any open popup. Its close button, clicking the widget or pressing Escape closes a pinned popup, and the next time it opens it glides back to its spot, pinned, until you unpin it. It keeps the layout it opened with until you close it.

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
| `field` | `field` | A string from the script's `fields` object, or the current list row. With `"wrap": true` it shows all of the text over as many lines as it needs, and the text can be selected and copied; `maxHeight` scrolls a wrapping field past that height in points and keeps its newest lines in view as the text grows. `"markdown": true` shows inline Markdown: bold, italics, `code` and links. |
| `graph` | `height` | The widget's existing 60 samples on the 0–1 scale; optional `source` reads `series[source]` instead and `lineWidth` sets stroke width |
| `list` | `source`, `row` | Repeat the `row` block for each object in `lists[source]` |
| `button` | `title`, `onClick` | Run a command and close the popup |
| `slider` | `title`, `source`, `onChange` | Native slider; reads `values[source]` or numeric `fields[source]`. `min`, `max`, `step` default to 0, 1, 0.01. |
| `toggle` | `title`, `source`, `onChange` | Native toggle; true for `"true"`/`"1"` in fields or 1 in values. |
| `segmented` | `title`, `source`, `options`, `onChange` | Native segmented picker. Options are `{ "title": "Label", "value": "id" }`; selection reads `fields[source]`. |
| `chooser` | `title`, `source`, `groupsSource`, `optionsSource`, `onChange` | A pill naming the chosen group, option and level, which opens a panel to change them, as AI apps choose a model. The panel lists the rows of `lists[groupsSource]` (`value`, `title`, and optionally `icon`, `detail`, `option`, `level` and `levelsTitle`). Beside them it shows the chosen group's options, the rows of `lists[optionsSource]` whose `group` names it (`value`, `title`, optional `detail`), and a bar of its levels from `levelsSource`, whose rows have `group`, `value` and `title`. `fields[source]` is the chosen group, and each group row's `option` and `level` are its current choices. A choice shows at once and runs `onChange` with the group in `VALUE`, the option in `OPTION` and the level in `LEVEL`. |
| `search` | `title`, `source`, `row` | Text field and filtered rows from `lists[source]`. `searchFields` limits matching to named fields; omitted searches all row values. |
| `input` | `title`, `onSubmit` | Text field. Return runs `onSubmit` with the text and clears the field. `placeholder` sets the hint shown while it's empty; without one, the title shows. `"autofocus": true` puts the cursor in it when the popup opens from a click. |
| `menu` | — | The widget's script or configured menu entries, with their existing actions |
| `divider` | — | A horizontal rule |
| `image` | `path` or `source` | Local path, `file://`, or HTTP(S) image; `source` reads a path from `fields`. A local app or program shows its Finder icon. `fit` is `fit` or `fill`; size defaults to 52 × 52. |
| `symbol` | `name` or `source` | SF Symbol; `source` reads its name from `fields`. `style.iconSize` sets its size. |
| `progress` | `source`, `height` | A rule using `values[source]`, optionally moving toward `targets[source]`. `style.accent` is the fill and `style.background` the track. |
| `equalizer` | — | Four bars that bounce in the text color while `source` is on, for `"true"`/`"1"` in fields or 1 in values, and settle low when it's off; without `source` they always bounce. `height` defaults to 12. Reduce Motion keeps them still. |
| `battery` | — | A battery like the one in the macOS menu bar, sized by `style.iconSize` and drawn in the text color. Its fill shows `values[source]`, or a 0–1 number in `fields[source]`; `source` defaults to `percent`. A `state` field of `charging` adds a bolt and `charged` a plug, and a `health` field of `service` adds an orange badge. On battery power the fill turns red at 10 % or less. |

Every block accepts `style` and `alignment` (`leading`, `center`, `trailing`). Fonts, text color, accent and spacing inherit from the containing block. Width, padding, background, hover background and border apply only when set on that block. Set a width on numeric fields and their headings to align columns. Blocks without a width use the available space. `minWidth` and `maxWidth` limit a block that has no fixed `width`: in the bar it takes its content's width within them, and in a popup the available space up to `maxWidth`.

Text and field blocks can set `"shimmer": true` to sweep light across their text, as while something works; pair it with `hideWhenEmpty` to show it only then. Reduce Motion keeps it still. Text and field blocks can set `scrollSpeed` in points per second with a fixed `style.width`, or with a `style.maxWidth` so that text that fits takes only its own width instead of leaving a gap after it. Overflow scrolls back and forth with a pause at each end; fitting text and Reduce Motion do not scroll. `hideWhenEmpty` names a field: the block occupies no space when that field is absent or empty, which is useful for optional list-row headings and pipeline details.

Display blocks can also have `onClick`, or `onClickField` to read a command from the current fields/list row. This allows a symbol button or a clickable agenda row. To open a URL or an app without a shell, use `open`, with the values a widget accepts, or `openField` to read one from the current fields/list row; a field value that `open` would reject does nothing when clicked. A block cannot combine `onClick` or `onClickField` with `open` or `openField`. `quitField` reads a process ID from the current fields/list row, such as a `system` provider's [process rows](providers.md#processes), and asks whether to quit that process, naming it or the app it is: **Quit** asks it to quit, as quitting from the Dock does, and **Force Quit** ends it at once, losing any unsaved changes. It can't be combined with the other actions. The whole block, including its padding and configured width and height, is clickable, not only its symbol or text. A popup accepts `alignment` (`leading`, `center`, `trailing`) for horizontal placement relative to its widget's drawn instance, including widget style offsets. Its top attaches to the bottom edge of the visible bar, whatever the widget's height or font size; `offset` is the gap below that edge in points (default `6`; `0` attaches it flush, like a menu). With a below-bar indicator, the gap starts below the bar's reserved decoration strip, so a popup cannot cover the underline. A popup opens and closes with the bar's [motion and popup transition](create-a-widget.md#animation). Its `animation` sets another curve and duration for both, and also animates the popup's height and what changes inside it when its data changes; `"duration": 0` shows and hides it at once. Reduce Motion keeps only the fade. Popups cast the system's window shadow, under the `shadowColor` shadow if one is set. With Liquid Glass off and no `background`, a popup shows the system's translucent material. A popup moves on a real spring with `snappy` and `bouncy`. Its fade, and every move with other curves, approximates `smooth`, `spring` and `snappy` with a matching ease curve and `bouncy` with one that overshoots; other curves retain their names. `dismissOnAction` defaults to `true`; set it to `false` for player controls that should keep the popup open. Images load asynchronously and update when their source path changes. Use a different local filename for each cover, or supply its URL.

Controls pass their new value in the `VALUE` environment variable with `SENDER=control.changed`. Sliders send a number when editing ends, toggles send `true` or `false`, segmented controls send the selected option's value, choosers send the group, option and level described above, and inputs send their text when you press Return. Read it as `"$VALUE"` in a shell command; StableBar never inserts the value into command text. Completed actions refresh the widget's data. Controls stay open by default; set `popup.dismissOnControl` to `true` to close after a change. `dismissOnAction` still controls buttons and list rows independently.

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
