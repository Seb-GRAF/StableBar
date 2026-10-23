# Command-line controls

The executable is `StableBar.app/Contents/MacOS/StableBar`; [install the command](#install-the-command) to run it as `stablebar`. Prefix commands with `--config PATH` to address a specific running configuration; otherwise live commands target the default configuration. Replies are JSON, and errors exit with status 1. Each configuration has one local control endpoint per user.

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

A batch validates the whole resulting configuration before replacing the running bar or writing the file. A failed batch leaves both intact. Supported edit actions are `set` (`id`, `properties`), `add` (`properties`, including `id`), `remove` (`id`), `reorder` (`ids`), `screens`/`bar`/`defaults`/`popupDefaults`/`roles`/`workspaceDefaults`/`modeAliases`/`tokens`/`providers` (`properties`, merged into those keys), `workspaceSource` (`name`: `aerospace`, `yabai` or `spaces`, omitted for the default AeroSpace source), `unset` (`properties` naming the keys to remove from the main file, with `id` for a widget, for example `{"action":"unset","id":"clock","properties":{"style":{"foreground":null}}}`), `profile` (`name`, omitted for automatic), `profiles` (`profiles`, definitions merged by name; set `enabled` to `false` to disable one), `package` (`properties`: `id`, `version`, optional `enabled` and `settings`), `packageSource` (`properties`: a whole [source](packages.md#private-sources) with `id`, `name` and `url`, which replaces the source with that `id` or is added; `id` without `properties` removes it, for example `{"action":"packageSource","id":"acme"}`), and `theme` (the same `properties`, with only `id` for a theme that ships with StableBar, omitted for Built-in).

Without `id`, `unset` can also address widget definitions by their ID and profiles by their name in the main file. For example, `{"action":"unset","properties":{"widgets":{"clock":{"style":{"foreground":null}}},"profiles":{"night":{"configuration":{"bar":{"height":null}}}}}}` removes the clock’s text color and the night profile’s bar height in one edit. Empty objects are removed, except an emptied profile `configuration` stays as `{}`.

- `--validate [PATH]`: compose and validate files without starting scripts.
- `--refresh ID`: refresh a running widget. Hidden, suspended providers must first be made visible or explicitly resumed with **Settings → Status → Resume for testing**.
- `--popup ID`: open the popup or menu of a widget, or close it when it's open. It opens on the active display, as `"display": "active"` defines it; a widget in the **More widgets** menu opens its popup under that menu. Key bindings can call it, for example in `aerospace.toml`: `alt-c = 'exec-and-forget /Applications/StableBar.app/Contents/MacOS/StableBar --popup agenda'`.
- `--trigger EVENT [KEY=VALUE ...]`: send an event. Without `--config`, this broadcasts to all subscribed bars for compatibility; with `--config`, it targets that configuration.
- `--reload`: reload configuration; without `--config`, notify all running bars.
- `--packages`, `--inspect-package PATH`, `--install-package PATH|ID [--source SOURCE]`, `--enable-package ID VERSION [--persist]`, `--uninstall-package ID VERSION`: review and manage packages. `--packages` lists installed packages; `source` names the source that installed each one (`stablebar`, a private source's `id`, or `local` for a folder) and is absent for packages installed before StableBar recorded sources. `--install-package` installs a folder, or a package from the [store](packages.md#store) or a [private source](packages.md#private-sources) in the configuration file when its argument is not a folder. When more than one source lists the ID, it names them; add `--source` with a source's `id`. It refuses a package that another source installed. Installation does not enable commands. Uninstall requires the bar to be running and always saves configuration edits before removing that version. Package selections belong in the root file or its includes; use profile widget overrides to hide package widgets contextually.
- `--build-source PACKAGES OUT [--previous FILE] [--url URL --name NAME]`: build a [private package source](packages.md#publishing-a-source) from a folder of packages. It writes an archive for each package version that isn't published yet, and `index.json`, into `OUT`, then prints what to upload. `--previous` is the index you published last time; its versions that are still in `PACKAGES` keep their entries and no archive is written for them, and a package whose folder is gone leaves the index. With `--url` (the index's `https` address) and `--name`, it also prints a join link. It checks each package like `--inspect-package`, needs StableBar 0.6.0 or later, and doesn't use a configuration file or a running bar.

## Install the command

**Settings → General → Command line** installs a `stablebar` command in `/usr/local/bin`, which is on the `PATH` of every Mac, so `stablebar --query` works in any terminal. macOS asks for an administrator password when that folder needs one. The section shows **Installed** once the first `stablebar` on your login shell's `PATH` opens this copy of StableBar, whether StableBar installed it or it links to the app. The command is a short script that runs the copy of StableBar it was installed from, so the button is available only once StableBar is in Applications. When the command opens another copy, for example after you moved StableBar, the section names that copy and **Install** points the command at this one. A `stablebar` command that StableBar didn't install is left as it is. To remove the command, run `sudo rm /usr/local/bin/stablebar`.

## Triage

`triage` hands a problem with your bar, or an idea for StableBar, to a coding agent in the terminal:

```sh
StableBar triage
StableBar triage --agent claude --model opus
```

It runs Claude Code (`claude`) or Codex (`codex`), whichever is on your `PATH`, and asks which when both are; `--agent` picks one, and `--model` passes a model to it. The agent asks what's going on, looks at your configuration, running bar, displays and crash reports, reads StableBar's source at your version, and searches the issues on GitHub. Then it offers to fix your setup, comment on an existing issue or file a new one. It changes your configuration or posts on GitHub only after you say yes. With `--config PATH`, it looks at that configuration.

StableBar first writes what the agent starts from into `~/Library/Caches/StableBar/triage/`: the facts it found about this Mac and the [playbook](../.github/triage/PLAYBOOK.md) the agent follows. The agent switches to the playbook on `main` when it's newer. When neither agent is installed, StableBar prints where these files are, so you can paste the prompt into another agent.
