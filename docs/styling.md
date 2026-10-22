# Styles and states

## Widget styles

Each widget can override any of these styles:

`foreground`, `background`, `hoverBackground`, `borderColor`, `borderWidth`, `cornerRadius`, `fontName`, `fontSize`, `fontWeight`, `iconSize`, `paddingHorizontal`, `paddingVertical`, `spacing`, `width`, `accent`, `accentText`, `shadowRadius`, `shadowColor`.

`fontName` is `system` or an installed font name. `fontWeight` is `regular`, `medium`, `semibold` or `bold`. Unset, text uses the system font at 13 points, regular, like the macOS menu bar. Set `width` on frequently changing widgets to keep their footprint stable. Without a `width`, the active app widget animates to fit each app's name, and the widgets beside it slide along. The workspace highlight uses `accent` and `accentText`; its motion respects Reduce Motion. Set `bar.motion` to `none` to remove animation.

Styles also accept `hoverForeground`, `height`, `paddingLeading`, `paddingTrailing`, `paddingTop`, `paddingBottom`, `offsetX`, `offsetY` and `opacity`. Side-specific padding overrides horizontal/vertical padding. `ultralight`, `thin` and `light` font weights are available too. Offsets move the drawing without moving its neighbours.

## States

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

`hover` is active while the pointer is over a bar widget, a workspace cell or a layout block, on that display only. The `open` state is active on a bar widget, its layout and its overlay while its popup shows, on the instance that opened it: not on its copies on other displays, and not when the popup opened from the More widgets menu. A block's own background, border, padding, size, offset and opacity change for `open` only through that block's own `states`. Workspace cells also have a workspace state; see [Workspace appearance](widgets.md#workspace-appearance). Script and provider widgets can have a data state; see [Data states](#data-states). States apply in a fixed order, later ones winning: the data state, the workspace state, `mode`, `mode.<alias>`, `hover`, then `open`, so an `open` style stays visible while the pointer rests on its widget. A state's style can have its own `states`, which refine later states while both are active: `states.focused.states.hover` styles the focused workspace under the pointer. `bar.style` consumes mode states; group states remain inactive.

`hoverBackground` and `hoverForeground` are shorthand for `states.hover.background` and `states.hover.foreground`. In each style, such as `defaults` or a widget's `style`, the two are compared after includes, packages, themes, templates, widget overrides and profiles merge, so a `states.hover.background` from any layer wins over `hoverBackground` from any layer, and likewise for the foreground; to override a lower layer's hover state, set `states.hover.background`. The **Hover background** rows in Settings handle this for you: they set `hoverBackground` and set `states.hover.background` to `null` beside it, so the color you pick wins over a lower layer's hover state but not over an active profile's `hoverBackground`. A hover without a background keeps the background. In a widget's `layout` and `overlay` and in popups, `hover` changes a block's text color and its own background, border, padding, size, offset and opacity. A widget without `layout` draws its default layout with all of its `hover` and `open` styles.

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

## Presentation roles and workspace defaults

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

In **Settings → Bar**, a widget’s **More** menu sets its presentation role, and **Style → Workspaces** edits workspace indicators. **Theme → Advanced** edits shared role styles, workspace look and AeroSpace mode names; theme cards show sample widgets and the workspace indicator. **Profiles** can override these maps through its JSON editor or by editing the profile in Bar and Theme. The shared CLI uses `roles`, `workspaceDefaults` and `modeAliases` batch actions; `set` assigns a widget's role or layout/block roles. **Status**/`--query` report the role, resolved style, ordered layers and source/token origins.

## Data states

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
