# Command-line controls

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

Command-line changes are live for the current session. Settings shows a notice with **Save** and **Discard** for these temporary changes. Changes made in Settings save separately and leave temporary command-line changes applied on top. Add `--persist` to save the session changes into the root file. `--reset` discards unsaved session changes and reloads the files. Session edits reapply over external file changes. Imports and package source files are preserved.

Use one batch for changes that must appear together:

```sh
StableBar --batch '[
  {"action":"set","id":"clock","properties":{"position":"left"}},
  {"action":"bar","properties":{"height":44}},
  {"action":"defaults","properties":{"fontSize":13}}
]' --persist
```

A batch validates the whole resulting configuration before replacing the running bar or writing the file. A failed batch leaves both intact. Supported edit actions are `set` (`id`, `properties`), `add` (`properties`, including `id`), `remove` (`id`), `reorder` (`ids`), `screens`/`bar`/`defaults`/`popupDefaults`/`roles`/`workspaceDefaults`/`modeAliases`/`tokens` (`properties`, merged into those keys), `workspaceSource` (`name`: `aerospace` or `yabai`, omitted for the default AeroSpace source), `unset` (`properties` naming the keys to remove from the main file, with `id` for a widget, for example `{"action":"unset","id":"clock","properties":{"style":{"foreground":null}}}`), `profile` (`name`, omitted for automatic), `profiles` (`profiles`, definitions merged by name; set `enabled` to `false` to disable one), `package` (`properties`: `id`, `version`, optional `enabled` and `settings`), and `theme` (the same `properties`, with only `id` for a theme that ships with StableBar, omitted for Built-in).

Without `id`, `unset` can also address widget definitions by their ID and profiles by their name in the main file. For example, `{"action":"unset","properties":{"widgets":{"clock":{"style":{"foreground":null}}},"profiles":{"night":{"configuration":{"bar":{"height":null}}}}}}` removes the clock’s text color and the night profile’s bar height in one edit. Empty objects are removed, except an emptied profile `configuration` stays as `{}`.

- `--validate [PATH]`: compose and validate files without starting scripts.
- `--refresh ID`: refresh a running widget. Hidden, suspended providers must first be made visible or explicitly resumed with **Settings → Status → Resume for testing**.
- `--popup ID`: open the popup or menu of a widget, or close it when it's open. It opens on the active display, as `"display": "active"` defines it; a widget in the **More widgets** menu opens its popup under that menu. Key bindings can call it, for example in `aerospace.toml`: `alt-c = 'exec-and-forget /Applications/StableBar.app/Contents/MacOS/StableBar --popup agenda'`.
- `--trigger EVENT [KEY=VALUE ...]`: send an event. Without `--config`, this broadcasts to all subscribed bars for compatibility; with `--config`, it targets that configuration.
- `--reload`: reload configuration; without `--config`, notify all running bars.
- `--packages`, `--inspect-package PATH`, `--install-package PATH|ID`, `--enable-package ID VERSION [--persist]`, `--uninstall-package ID VERSION`: review and manage packages. `--install-package` installs a folder, or a package from the [store](packages.md#store) when its argument is not a folder. Installation does not enable commands. Uninstall requires the bar to be running and always saves configuration edits before removing that version. Package selections belong in the root file or its includes; use profile widget overrides to hide package widgets contextually.
