# StableBar

A macOS bar that takes its look from themes and its content from widgets. These are the words we use for them.

## Language

### Themes

**Theme**:
A package that sets how the bar, its widgets and its popups look, and runs nothing. One is selected at a time.
_Avoid_: skin

**Included theme**:
A theme that ships with StableBar and shows under **Included** in the gallery and in setup.
_Avoid_: base theme, bundled theme, default theme

**Fallback**:
The values under every theme that fill whatever the selected theme leaves out. They never change.
_Avoid_: Built-in, base layer, defaults

**Classic**:
The floating tiles that the fallback draws on its own: the theme once called Built-in, now in the Store.
_Avoid_: Built-in

**Retired theme**:
A theme StableBar no longer includes. Anyone whose configuration selects it keeps it, unchanged; the last included set lives on in the Store, older ones only in **Yours**.
_Avoid_: legacy theme, Custom, old theme

**Store theme**:
A theme installed from the Store, the shared catalogue of packages, rather than included with StableBar.

**Yours**:
The gallery's section for themes that belong to you: those you saved, opened from a link or a folder, or kept when they retired.
_Avoid_: personal theme, custom theme

**Base theme**:
The theme a new theme starts from in the website's theme creator.

### Setup

**Preset**:
A set of widgets, built-in or from the Store, with their layouts, that setup adds to the bar. It doesn't choose the look.
_Avoid_: widget set, template
