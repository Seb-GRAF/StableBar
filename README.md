<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="">

# StableBar

A native, configurable menu bar for macOS.<br>
Themes, widgets and popups, set up in the app or in plain JSON.

[![Latest release](https://img.shields.io/github/v/release/Seb-GRAF/StableBar?label=release&color=f5821f)](https://github.com/Seb-GRAF/StableBar/releases/latest)
[![CI](https://github.com/Seb-GRAF/StableBar/actions/workflows/ci.yml/badge.svg)](https://github.com/Seb-GRAF/StableBar/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)](#install)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[**Download**](https://github.com/Seb-GRAF/StableBar/releases/latest) · [Website](https://stablebar.app/) · [User guide](docs/README.md) · [Widget store](https://github.com/Seb-GRAF/stablebar-packages) · [Examples](examples)

</div>

<br>

<img src="https://github.com/user-attachments/assets/8d5909cb-f107-48db-a7b3-aabbabf4e860" width="100%" alt="StableBar on the desktop: workspaces with their app icons, the active app, music, the next meeting, CPU and memory, the battery and the clock. It moves to another workspace and back.">

## Features

- **Native.** Swift, AppKit and SwiftUI, with no web view or private window-server API, except in the opt-in [macOS Spaces](docs/widgets.md#macos-spaces-workspaces) workspace source. One panel per display; workspace changes update the widgets in place instead of recreating windows.
- **Guided setup.** Pick a preset, a theme and a placement, and watch each choice on your real bar. Then edit the bar in place, in Settings or in JSON.
- **Themes.** Six ship with the app and more come from the store. **Save as Theme…** turns your own look into one. Experimental Liquid Glass on macOS 26.
- **Built-in widgets.** Workspaces, app menus, the active app, clock, CPU and memory, network, battery, sound and calendar, without running a script.
- **Any script is a widget.** Print text or JSON from any language, refresh on a timer or on events, and open a popup with graphs, lists and controls.
- **Window managers.** Workspaces from [AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai) or [OmniWM](https://github.com/OmniNull/OmniWM). Without one, StableBar can keep windows and notifications clear of the bar.
- **Every display.** Notch-aware placement, widgets per kind of screen and a separate bar for each screen setup.
- **Scriptable.** The command line queries and edits the running bar and sends events from other tools.

## Workspaces

The workspaces widget shows each workspace and its apps from AeroSpace, yabai or OmniWM, and follows you as you switch. Without a window manager, it can show macOS Spaces. See [Built-in widgets](docs/widgets.md).

<img src="https://github.com/user-attachments/assets/66655f52-9458-4488-9e0f-064a8529b4ab" width="100%" alt="The bar's workspaces widget switching between workspaces while the window below changes to each workspace's app">

## Popups

Any widget can open a popup. Build it from rows, columns, text, graphs, lists, buttons, sliders, toggles and search fields, filled with the widget's data. See [Custom popups](docs/popups.md).

<img src="https://github.com/user-attachments/assets/7c0ad0e9-efd0-4ac1-8090-7807de30222c" width="100%" alt="The pointer clicks the meeting, system and music widgets in turn, opening today's agenda, a CPU and memory graph, and the playing track with its controls">

## Themes

Six themes ship with StableBar, alongside Built-in. Choose one during setup, cycle through them on your own bar with **Try Themes…**, or get more from the [store](https://github.com/Seb-GRAF/stablebar-packages). **Save as Theme…** turns your own look into one. See [Themes](docs/themes.md).

<img src="https://github.com/user-attachments/assets/ceb102e2-3704-4198-ba9d-d58bcfc1ecd5" width="100%" alt="The bar and its open agenda popup changing through each theme that ships with StableBar, then back to Built-in">

## Edit the bar in place

Choose **Edit Bar in Place** from the bar's right-click menu to arrange widgets on the bar itself: drag them between positions, remove them with **−** or add one with **+**. Changes save as you go, with undo. See [Settings](docs/settings.md).

<img src="https://github.com/user-attachments/assets/66608625-bef8-4d29-b2db-dcf58ac26876" width="100%" alt="Editing the bar in place: the music widget is dragged from the right of the bar to its center, then Done restores the normal bar">

## Any script is a widget

A widget can run any command that prints text or a JSON object, refresh on a timer or on events, and open a popup with graphs, lists and controls.

<img src="https://github.com/user-attachments/assets/fcd1f43e-311b-4ddf-b225-c830be980d6e" width="100%" alt="A two-line shell script that prints the disk usage is typed, and its output appears on the bar as a new widget">

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

[Create a widget](docs/create-a-widget.md) covers the output format, events and layouts. Share a widget as a [package](docs/packages.md).

## Widget store

**Settings → Packages → Store** lists widgets and themes from the [StableBar store](https://github.com/Seb-GRAF/stablebar-packages). Before anything runs, StableBar shows the commands, hosts and permissions a package uses. See [Packages and the store](docs/packages.md#store).

<img src="https://github.com/user-attachments/assets/51f51f6c-fd6c-4900-83c7-71fe2b4dc6f7" width="100%" alt="The Store in Settings lists widget packages; getting the Weather package marks it installed">

## Settings or JSON

Change content, appearance and behavior in Settings, with undo and redo, or edit the file it saves to. Your bar lives in `~/.config/stablebar/config.json`: StableBar applies the file when you save it, and keeps the last working bar if a change is invalid. The JSON schema gives editors completion and validation. See [Settings](docs/settings.md) and [Configuration](docs/configuration.md).

<img src="https://github.com/user-attachments/assets/47b1b70a-531d-457a-bb83-11d57038acba" width="100%" alt="In config.json the theme is changed from catppuccin to nord and saved, and the bar above switches to Nord; then it is changed back">

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

## Install

1. Download `StableBar.dmg` from the [latest release](https://github.com/Seb-GRAF/StableBar/releases/latest).
2. Open it and drag StableBar to Applications.
3. Open StableBar. Setup walks you through a preset, a theme and a placement.

With [Homebrew](https://brew.sh), `brew install --cask seb-graf/tap/stablebar` replaces the first two steps.

StableBar needs macOS 14 or later on Apple silicon. Releases update themselves; choose the Beta track in **Settings → General → Updates** to get betas. See [Getting started](docs/getting-started.md). To remove StableBar, use **Settings → General → [Uninstall](docs/getting-started.md#uninstall)**, which also turns off the menu bar auto-hide that StableBar turned on.

## Documentation

The [user guide](docs/README.md) documents every feature and configuration option. Start with [Getting started](docs/getting-started.md), or try one of the working setups in [examples](examples).

## Authors

StableBar is built by [Sebastien Graf](https://github.com/Seb-GRAF) and [Steve Mendes Reis](https://github.com/M4n0x), with help from [everyone who has contributed](https://github.com/Seb-GRAF/StableBar/graphs/contributors).

## Contributing

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build StableBar, run the tests and open a pull request. Report security issues privately, as described in [SECURITY.md](.github/SECURITY.md).

## License

StableBar is available under the [MIT License](LICENSE), including commercial use and redistribution.
