# Packages and the store

## Local widget packages

Open **Settings → Packages → Open a folder…** to review a local package. Its page lists the included widgets, setup fields, requirements and commands. A block with `onClickField` is listed by the field it reads its command from. **Add to bar** installs the package if needed and enables it after review; **Use theme** selects a theme. The command-line install operation only installs files and never enables a package.

**Installed** and **Store** organize Packages, with search by name, description or ID. Installed packages are grouped into **On your bar**, **Installed, not on your bar** and **Themes**, with a separate **StableBar Essentials** collection for included widgets and themes. Essentials shows sample widgets with **Add to bar** actions and theme previews. Installed and Store rows include a preview before you select a package. Supplied images show sample content; packages without an image show a theme preview or samples of their included widget types. Previews do not run commands, request permissions, install packages or change your bar. In Store, the same list shows each package with its kind, author and **Get** button, filtered by **All**, **Widgets** or **Themes**; select one to open its page beside the list. The package page shows the same preview at a larger size. Installed packages with newer Store versions appear first under **Updates available**, with the installed and new version and an **Update** button. One click downloads, checks, installs and replaces the selected version on the current bar, preserving compatible settings, credentials, widget placement, visibility and overrides. An installed package that is not on the bar stays inactive. Additional commands, hosts or permissions require review before updating. A failed update keeps the previous selection; old files remain available and changing the selected version supports Undo. **Check for updates** refreshes the Store listing. **General → Updates → Notify about package updates** is on by default and checks shortly after launch, then hourly. A small package button in the bar opens Packages; its × dismisses the notice for those versions, including after relaunch. Updates remain listed in Packages, and a newer version can show the notice again. Turning the setting off stops background package checks and hides the button. A package has **Overview**, **Settings**, **Access** and **Versions** tabs. In Versions, choose **Use** beside an installed version to review it and change the pin. Compatible settings carry over; a value that a new version no longer accepts falls back to that version's default. Settings for an active package save automatically and support Undo. Setup drafts for a package you have not added, another version and unsaved credentials survive navigation within Settings.

Built-in and Included content ships with the app. A Store draft comes from the Store; Local folder identifies a folder you opened. Installed copies show Listed in Store when their package ID appears in the current catalog, or Installed otherwise. These labels do not establish where an installed copy came from or whether it was reviewed; installation does not record that information.

A package is a folder containing `package.json`, its configuration, and any scripts or assets. [examples/packages/local-clock](../examples/packages/local-clock/package.json) is a working package using a bundled script. Its manifest has this shape:

```json
{
  "id": "local-clock",
  "name": "Local clock",
  "version": "1.0.0",
  "entry": "config.json",
  "settings": {
    "format": {
      "type": "string",
      "title": "Time format",
      "description": "Choose whether the clock includes seconds.",
      "choices": ["%H:%M", "%H:%M:%S"],
      "default": "%H:%M"
    },
    "fontSize": { "type": "number", "title": "Font size", "default": 12 }
  }
}
```

Settings support `string`, `number`, `bool` and `secret`. The first three need a matching `default`. An optional `description` explains a field in the interface. String settings can declare a nonempty `choices` array to show a picker; both the default and supplied values must be among those choices. [package.schema.json](../package.schema.json) describes the manifest and setting fields; StableBar also validates their types and allowed values. Reference a setting as a whole value, such as `"fontSize": "@setting.fontSize"` or `"environment": { "FORMAT": "@setting.format" }`. Put settings needed by shell commands in environment variables and quote them normally in the script.

A `secret` setting, such as `"token": { "type": "secret", "title": "GitHub token" }`, holds an API token and has no `default` or `choices`. Reference it only as a whole value in the `environment` of a widget or provider the package defines, such as `"environment": { "GITHUB_TOKEN": "@setting.token" }`; templates, profiles and the top-level `environment` cannot use it. Type it in **Settings → Packages**; **Open package** in a widget's Content inspector opens that package page. For an active package, choose **Save credentials**; ordinary setting changes do not save credentials. For a package being added, **Add to bar** applies its configuration and then saves the credentials. An error stays visible if the credential write fails. The field shows whether a token is saved without revealing it. StableBar keeps it in the login Keychain, never in a configuration file, and `--query` and Settings show `@secret.<package id>/<setting>` in its place. Commands receive the token when they start, or an empty value when none is saved. **Remove** next to a saved token schedules its deletion for the next credential save or add operation. The token belongs to the package ID, so a new version keeps it, and a package selection cannot set it in `settings`. Builds that are not signed with a Developer ID, which includes current releases and local builds, change their signature with every update, so macOS asks whether StableBar may use its Keychain item the first time a command needs the token after an update; choose **Always Allow** to stop the question until the next update.

A secret keeps the token out of configuration files, `--query` and Settings. It does not protect it from other packages: a package that runs commands can still reach a secret through StableBar, for example by overriding another package's widget. Install packages with commands only from sources you trust. A command that prints its token still shows it in its output and in Status, and programs running under your account can reach a secret through StableBar too, since they can edit your configuration.

Widgets, templates and providers receive `PACKAGE_DIR`, the absolute path of the installed package, for commands such as `"$PACKAGE_DIR/scripts/clock.sh"`.

Packages install atomically into `packages/<id>/<version>` beside the main configuration. Existing versions cannot be overwritten. Configuration includes and static image paths stay inside the package; traversal and symlinks escaping the folder are rejected. Static image paths are resolved relative to the package folder, including token references. Package commands can run arbitrary code as your user; review the files as well as the displayed command strings before enabling an unfamiliar package.

**Remove from bar…** turns off an entire package and retains its files, settings and credentials. Its widgets' entries in `widgetOverrides`, including those in profiles, are removed with it. To hide just one of its widgets, use **Bar**. To delete an installed version, select it in **Packages → Versions → Uninstall…**. If selected, that version is disabled in the root configuration of the current bar, including when its selection comes from an include, and in the shared bar and every [screen setup](layout.md#screen-setups)'s own bar that selects it. Overrides of its widgets are removed there too, and a screen theme that names it is removed so that screen uses the shared theme; an uninstalled theme falls back to Built-in. Other installed versions, saved settings and Keychain secrets are kept for reuse. To delete a saved token, use **Remove** beside it and **Save credentials** before uninstalling. Uninstall checks that the configuration still loads before deleting files. It cannot be undone in Settings; history that needs the deleted files is cleared. Temporary command-line changes stay unsaved. Save or discard them first if they still use that version. The command-line operation always saves current configuration edits and uses the running bar, without a confirmation prompt:

```sh
StableBar --uninstall-package local-clock 1.0.0
```

```sh
StableBar --inspect-package examples/packages/local-clock
StableBar --install-package examples/packages/local-clock
StableBar --packages
```

Enable an exact installed version in the root configuration:

```json
{
  "packages": [
    { "id": "local-clock", "version": "1.0.0", "enabled": true, "settings": { "format": "%H:%M:%S" } }
  ]
}
```

Package selections in modules merge by package ID, with later modules and the root taking precedence. Enabled packages load once before the composed modules and root properties. Root templates, tokens and widget overrides can customize them. Set `enabled` to `false` to stop loading a package; installation alone has no runtime effect. Packages cannot enable other packages. StableBar never updates a package by itself: versions remain pinned until you choose another installed version, and the [store](#store) only tells you about newer ones.

A package whose `package.json` sets `"kind": "widgets"` contains no commands, so it needs no command review. Its configuration can contain only `tokens`, `defaults`, `bar`, `groups`, `profiles`, `widgets`, `templates`, `popups` and `providers`, plus includes inside the package. Nowhere in it, including templates, popups, providers and profiles, can it set `command`, `onClick`, `onClickField`, `rightClick`, `middleClick`, `scrollUp`, `scrollDown`, `mouseEntered`, `mouseExited`, `onChange` or `environment`, so script widgets and `command` or `stream` providers are rejected too. Built-in widget types, native providers and [`open`](widgets.md#mouse-actions) remain available, and built-in widgets keep their own behaviour: a `workspaces` widget still talks to AeroSpace or yabai. StableBar checks this when the package is reviewed, installed and loaded, and **Settings → Packages** and `--inspect-package` say that it contains no commands instead of listing them. Enable it in `packages` like any widget package. [examples/packages/system-monitor](../examples/packages/system-monitor/config.json) shows CPU and memory with a popup.

## Store

**Settings → Packages → Store** lists widget packages from the [StableBar store](https://github.com/Seb-GRAF/stablebar-packages), with their descriptions and versions. Select one to download and inspect it, review its included widgets, setup and access requirements, then choose **Add to bar**. Loading the list does not download every package; only the chosen package is inspected. A package that needs a newer StableBar shows the version it requires and cannot be installed. **Reload Store** refreshes the index. Installed packages remain available when the Store cannot be reached. On the command line, give `--install-package` a package ID instead of a folder; this installs without enabling:

```sh
StableBar --install-package nord
```

**Settings → Theme** also shows uninstalled themes under **Store**. Their cards show a sample bar styled by the downloaded theme. Choose **Get** to download, check, install and select a theme in one step; progress and any error appear on its card. Themes run no commands and skip the command review; **Get** refuses themes that declare hosts, permissions, required tools or secret settings. Store previews and downloads are cached while StableBar runs. If the Store is unavailable, your installed themes still work.

A store package with a newer version is marked **Update available**. Choose **Review update**, review its setup and access, then add the new version; the old version stays installed so you can roll back. When the new version runs commands, contacts hosts or uses macOS permissions that the enabled version does not, StableBar lists them and asks before enabling it.

Every store package is open source in [stablebar-packages](https://github.com/Seb-GRAF/stablebar-packages), and that repository's CI builds and publishes the archives, not the package's author. Themes and packages that contain no commands are published once they pass CI. A maintainer reads every version of a package that runs commands before it is published. StableBar downloads the index and the archives over HTTPS and checks each archive against the SHA-256 in the index before reviewing it.

These optional `package.json` keys describe a package, and the review shows them:

| Key | Meaning |
| --- | --- |
| `description` | One sentence for the store and the review |
| `author` | Person, organization or handle |
| `repository` | `https` URL of the package's source |
| `screenshot` | Path inside the package to a PNG or JPEG |
| `minimumVersion` | Oldest StableBar version that can run it, such as `0.6.0`. An older StableBar refuses to review or install it. |
| `requires` | Command-line tools needed on the login shell's PATH, such as `jq` or `gh`. The review names the ones it cannot find. |
| `permissions` | macOS permissions: `calendars`, `automation`, `accessibility`, `bluetooth` or `location` |
| `hosts` | Hostnames the package contacts, such as `api.github.com` |

StableBar shows `requires`, `permissions` and `hosts` but does not enforce them. For store packages, a maintainer checks them against the code.
