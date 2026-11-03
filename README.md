# StableBar

A native, configurable menu bar for macOS and an alternative to SketchyBar. Built with Swift, AppKit and SwiftUI.

[**Download for Mac**](https://github.com/Seb-GRAF/StableBar/releases/latest) · [Website](https://stablebar.app/) · [User guide](docs/README.md) · [Widget store](https://github.com/Seb-GRAF/stablebar-packages)

<p><img src="docs/images/readme-hero.gif" width="100%" alt="The top of your bar. A closer look at the widgets: Made yours. The camera pulls back and the intro loops."></p>

## Install

Download [StableBar.dmg](https://github.com/Seb-GRAF/StableBar/releases/latest), drag it to Applications and open it. Setup walks you through a preset, a theme and a placement.

Or install with [Homebrew](https://brew.sh):

```sh
brew install --cask seb-graf/tap/stablebar
```

**macOS 14+ · Apple silicon · Free and open source.** Releases update themselves. See [Getting started](docs/getting-started.md) for permissions, beta updates and uninstalling.

## Workspaces and popups

<p><img src="docs/images/readme-workspaces.gif" width="100%" alt="Switching workspaces updates the selected workspace and the app window below, with the screen held still."></p>

Follow your workspaces with [AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai) or [OmniWM](https://github.com/OmniNull/OmniWM). Without a window manager, try the opt-in [macOS Spaces source](docs/widgets.md#macos-spaces-workspaces).

<p><img src="docs/images/readme-popups.gif" width="100%" alt="The pointer opens music controls and then a CPU and memory graph beneath their widgets."></p>

Keep the active app, calendar, system stats and playback controls in reach. Widgets can open popups with graphs, lists and controls. Each display gets its own bar, with room for the notch.

[Built-in widgets](docs/widgets.md) · [Custom popups](docs/popups.md) · [Multiple displays](docs/layout.md)

## Make it yours

<p><img src="docs/images/readme-themes.gif" width="100%" alt="The same bar changes through the included themes while the screen and wallpaper stay still."></p>

Choose from Built-in and six bundled themes, or save your own.

<p><img src="docs/images/readme-edit.gif" width="100%" alt="The pointer opens Edit Bar in Place, drags Now Playing beside the notch and clicks Done."></p>

Right-click the bar and choose **Edit Bar in Place** to drag widgets between positions, add them with **+** or remove them with **−**. Changes save as you go, with undo.

[Themes](docs/themes.md) · [Editing your bar](docs/settings.md)

## Add your widgets

<p><img src="docs/images/readme-script.gif" width="100%" alt="A shell script prints disk usage and its output appears as a widget on the bar."></p>

Run a command that prints text or JSON, and its output becomes a widget. Refresh on a timer or on events.

<p><img src="docs/images/readme-store.gif" width="100%" alt="The pointer gets Weather from the Store, and its widget appears on the bar."></p>

Find widgets and themes in **Settings → Packages → Store**. StableBar shows a package's commands, hosts and permissions before anything runs.

[Create a widget](docs/create-a-widget.md) · [Packages and the store](docs/packages.md#store)

<details>
<summary>A shell script is enough</summary>

```sh
#!/bin/sh
# ~/.config/stablebar/widgets/disk.sh
used=$(df -h / | awk 'NR == 2 { print $5 }')
printf '{"text":"%s","icon":"internaldrive"}' "$used"
```

```json
{
  "id": "disk", "type": "script", "position": "right", "interval": 300,
  "command": "~/.config/stablebar/widgets/disk.sh"
}
```

</details>

## Settings or JSON

<p><img src="docs/images/readme-settings.gif" width="100%" alt="StableBar Settings and config.json open beneath the bar in a fixed view."></p>

Change content, appearance and behavior in Settings, with undo and redo. Or edit `~/.config/stablebar/config.json`: StableBar applies it when you save and keeps the last working bar if a change is invalid. The JSON schema gives your editor completion and validation.

[Settings](docs/settings.md) · [Configuration](docs/configuration.md) · [Command line](docs/command-line.md) · [Example setups](examples)

<details>
<summary>A minimal configuration</summary>

```json
{
  "$schema": "https://raw.githubusercontent.com/Seb-GRAF/StableBar/main/stablebar.schema.json",
  "theme": { "id": "catppuccin" },
  "widgets": [
    { "id": "spaces", "type": "workspaces", "position": "left" },
    { "id": "app", "type": "activeApp", "position": "left" },
    { "id": "power", "type": "battery", "position": "right" },
    { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm" }
  ]
}
```

</details>

## Contributing

Built by [Sebastien Graf](https://github.com/Seb-GRAF) and [Steve Mendes Reis](https://github.com/M4n0x), with help from [everyone who has contributed](https://github.com/Seb-GRAF/StableBar/graphs/contributors).

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build StableBar, run the tests and open a pull request. Report security issues privately through [SECURITY.md](.github/SECURITY.md).

Available under the [MIT License](LICENSE), including commercial use and redistribution.

[![Latest release](https://img.shields.io/github/v/release/Seb-GRAF/StableBar?label=release&color=ffe04a&labelColor=1d1813)](https://github.com/Seb-GRAF/StableBar/releases/latest)
[![CI](https://github.com/Seb-GRAF/StableBar/actions/workflows/ci.yml/badge.svg)](https://github.com/Seb-GRAF/StableBar/actions/workflows/ci.yml)
