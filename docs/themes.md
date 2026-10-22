# Themes

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/themes-dark.webp">
  <img src="images/themes-light.webp" alt="One bar shown in the Built-in, Blueprint, Everforest, Léman, Notch and Rosé Pine themes">
</picture>

StableBar ships with five themes and the Built-in fallback. Themes follow the system's appearance, or the one `bar.appearance` sets. Notch stays black in both appearances.

| Theme | ID | Look |
| --- | --- | --- |
| **Built-in** | none | Each widget is its own floating tile. |
| **Rosé Pine** | `rose-pine` | Rounded tiles in Dawn and Main colors, with an Iris accent. |
| **Everforest** | `everforest` | A full-width strip in warm forest colors, with underlined workspaces. |
| **Léman** | `leman` | A rounded floating bar in lake blue-green colors, with a teal accent. |
| **Blueprint** | `blueprint` | A thin outlined bar in tracing-paper and cyanotype colors, set in Menlo. |
| **Notch** | `notch` | A pure black strip that blends into the MacBook notch, with a cyan accent. |

Choose one in setup or in **Settings → Theme**. Theme cards show the same sample bar in each theme's style: three workspaces, Finder, a battery percentage and a clock. The sample shows the theme's bar, widget tiles, fonts, colors and workspace indicator, in the light or dark appearance your bar uses now. Click a card to apply and save it immediately; a checkmark marks your choice, and **Undo** restores the previous theme. You can also select a theme that ships with StableBar by its ID:

```json
{ "theme": { "id": "rose-pine" } }
```

To try themes on your real bar, choose **Try Themes…** from the bar's right-click menu or its menu-bar icon. A small panel opens below the bar on that screen. Use **←** and **→** or the arrow buttons to cycle through the themes that ship with StableBar, starting with Built-in, then your installed themes, in the gallery's order; every display changes together. **Return** or **Keep** saves the shown theme, and **Undo** in Settings reverses it. **Esc**, **Cancel** or a click outside restores the previous look without saving. Quitting while trying also leaves the saved theme alone. Opening **Edit Bar in Place** cancels a theme trial; starting **Try Themes…** finishes editing the bar. Temporary command-line changes stay applied and unsaved throughout. **Keep windows clear** uses the saved bar’s size until you choose **Keep**.

Older configurations can still select `slate`, `paper`, `graphite`, `menu-bar`, `island`, `minimal` or `terminal` without a version. Their appearance and overrides are preserved on update. The active theme is shown as **Custom**; the old themes are not offered as separate choices in **Theme**. Choosing a new theme replaces Custom, and Undo restores it.

Without `theme`, StableBar uses Built-in. Built-in also loads under every other theme, so a theme only needs what it changes: one that defines only tokens restyles widgets through Built-in's `defaults`, and anything it leaves out keeps Built-in's value.

A theme is a package whose `package.json` sets `"kind": "theme"`. Its configuration can contain only `tokens`, `defaults`, `popupDefaults`, `roles`, `workspaceDefaults`, `bar`, `groups` and `profiles`, plus includes inside the package. Widgets, templates, widget overrides, popups, providers, environment variables and any other key are rejected when the theme is reviewed, installed or loaded, so a theme runs no commands and needs no command review. The themes that ship with StableBar are in [Resources/themes](../Resources/themes); [Rosé Pine](../Resources/themes/rose-pine/config.json) defines every token below. Give each color a light and a dark value, such as `{ "light": "#1f2329", "dark": "#e6e9ef" }`, instead of a dark profile.

A theme can change the whole look, not only its colors. [Everforest](../Resources/themes/everforest/config.json) draws the strip with `bar.style` and removes the widget tiles by setting `background`, `borderColor` and `shadowColor` to `null` in `defaults`. Popups would show the system's material instead of the theme's colors, so it gives popups their own in `popupDefaults`. [Léman](../Resources/themes/leman/config.json) adds `bar.margin` and a corner radius so the strip floats.

Install your own theme like any other package, then select it with its version:

```json
{ "theme": { "id": "my-theme", "version": "1.0.0" } }
```

Only one theme is active: `theme` must name a theme, and `packages` cannot list one. An installed theme accepts the same `enabled` and `settings` as a package selection, and you can also enable it in **Settings → Packages**. Widget packages load first, then Built-in, then the selected theme, then includes and the main file. A theme's tokens, `defaults` and `bar` settings override a widget package's, and yours override the theme's. Profiles merge by name across these layers, keeping their order; later properties override earlier ones. A theme’s profiles remain unless you disable them with `"enabled": false`. **Built-in** in setup removes `theme`. In Theme it removes the main file’s selection, or selects Built-in explicitly when an included file chooses another theme. Choosing a theme in Theme or Try Themes replaces the version and settings inherited from an included file.

When your main file sets values that the selected theme also sets, Theme names them below the gallery. **Reset them** removes those values in one saved, undoable change. This includes bar dimensions, shared styles and a widget’s own style where it overrides the theme’s defaults or that widget’s role. Theme color changes count too, including colors inherited from Built-in. Active profiles in your main file are included; included files, templates and packages are left alone. The Light/Dark/Automatic choice is kept. Other settings still follow the usual layer order.

**Save as Theme…**, beside the **Theme** heading, saves your look as a theme of its own. Enter a name, and StableBar installs a theme package in `packages/<id>/1.0.0` beside your configuration and selects it. The package holds the current theme with your changes merged in, and its ID comes from the name: “My Léman” becomes `my-leman`. Your `defaults`, `popupDefaults`, `roles`, `workspaceDefaults`, `groups`, theme colors and any token the current theme defines, and the bar's `height`, `margin`, `inset`, `spacing`, `background`, `style`, `notchWidth` and `notchSpacing` move from your main file into the theme. The bar looks the same, and choosing another theme later replaces the whole look. Tokens you named yourself are copied into the theme and also stay in your file, so your widgets can still use them under other themes. Widget styles, profiles, screen settings, included files and the other `bar` settings stay where they are. One **Undo** restores the previous theme and your values; the saved theme stays installed. Saving again under the same name installs the next version, such as 1.0.1. For an installed theme, **Show in Finder** opens its folder so you can share it. Both appear with **Every screen** selected and while you aren't editing a profile.

[Tonhalle Line](../examples/packages/tonhalle-line) is an installable theme with a 38 pt Helvetica strip in forest ink and warm paper, a matching light palette, and brass warning colors. Version **1.1.0** adds a Light 16 pt `time` role, popup heading/key/value/button/meter roles, a 2 pt workspace underline below the strip, and a four-edge brass outline for `mode.command`. Other labels remain 13 pt regular; a `secondary` date stays smaller. Install its folder through **Settings → Packages**, then select it in Theme:

```json
{ "theme": { "id": "tonhalle-line", "version": "1.1.0" } }
```

Version 1.1.0 requires a StableBar build with shared presentation support; earlier builds reject its new properties. Installed versions are immutable: if you installed the earlier 1.0.0 theme, install 1.1.0 alongside it, then select 1.1.0. Keep the theme selected through `theme`; do not include or copy its styles into your configuration. That lets switching themes replace its appearance. User overrides still win.

The [presentation example](../examples/presentation/config.json) separates the time and date clocks, annotates popup elements, and owns a horizontal music-popup layout. It has 18 widgets, a shared sample provider, a group, constrained labels, a disabled widget and an event-driven mode label. Copy its `config.json`, `sample.json` and `mode.sh` together into a scratch directory and install the theme for that configuration. Its sample data is local; its buttons open the named macOS applications/settings. Change `modeAliases` to match your local AeroSpace names. The example maps `tailing` to `command`; the theme contains no local mode names and runs no commands. Use Dark Appearance for the original ink palette. A theme switch closes an open popup; reopen it to see the new role styling and unchanged layout.

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

## Liquid Glass

`bar.glass` is experimental. It draws backgrounds as native Liquid Glass, the material of the macOS 26 Dock, on top of any theme:

```json
"bar": { "glass": { "enabled": true, "transparency": 0.4 } }
```

Every widget, popup and bar that has a background becomes glass in the same shape, tinted with that background's color, so hover, open and data-state colors still show. Borders, corners, shadows and text keep the theme's style. Transparent backgrounds stay transparent. `transparency` (0.3 by default) sets how much glass shows through the color, from `0`, the theme's color, to `1`, pure glass; the higher it is, the more a busy or bright wallpaper can make text hard to read. StableBar uses Apple's clear glass with the theme's color as its dimming layer: the frosted regular glass switches small elements between light and dark to match what is behind them, which would leave theme text unreadable. Set `widgets`, `popups` or `bar` to `false` to keep that surface's plain color. Before macOS 26, StableBar draws the colors as usual.

Glass in a background window renders flat, without refraction. StableBar's bar and popups report themselves as active to AppKit so the glass refracts. The glass setting doesn't change their keyboard behavior.
