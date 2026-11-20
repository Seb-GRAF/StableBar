<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="StableBar's lighthouse icon">
</p>

<h1 align="center">StableBar</h1>

<p align="center">
  A native, configurable menu bar for macOS and an alternative to SketchyBar.<br>
  Themes, widgets, popups and workspaces, set up without writing scripts.
</p>

<p align="center">
  <a href="https://github.com/stablebox/StableBar/releases/latest"><img src="https://img.shields.io/github/v/release/stablebox/StableBar?label=release&color=F0883E" alt="Latest release"></a>
  <a href="https://github.com/stablebox/StableBar/releases"><img src="https://img.shields.io/github/downloads/stablebox/StableBar/total?color=58A6FF" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/stablebox/StableBar?color=56D364" alt="MIT License"></a>
  <a href="https://github.com/stablebox/StableBar/stargazers"><img src="https://img.shields.io/github/stars/stablebox/StableBar?style=flat&color=FFD33D" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://github.com/stablebox/StableBar/releases/latest"><b>Download for Mac</b></a> ·
  <a href="https://stablebar.app/">Website</a> ·
  <a href="docs/README.md">User guide</a> ·
  <a href="https://github.com/stablebox/stablebar-packages">Widget store</a> ·
  <a href="https://github.com/stablebox/StableBar/discussions">Discussions</a>
</p>

<p align="center">
  <a href="https://ko-fi.com/stablebar"><img src="https://img.shields.io/badge/Support_us_on_Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Support us on Ko-fi"></a>
</p>

<p><img src="docs/images/readme-hero.gif" width="100%" alt="The top of your bar. A closer look at the widgets: Made yours. The camera pulls back and the intro loops."></p>

## Install

Download [StableBar.dmg](https://github.com/stablebox/StableBar/releases/latest), drag it to Applications and open it. Setup walks you through a preset, a theme and a placement.

Or install with [Homebrew](https://brew.sh):

```sh
brew install --cask stablebox/tap/stablebar
```

**macOS 14+ · Apple silicon · Free and open source.** Releases update themselves. See [Getting started](docs/getting-started.md) for permissions, beta updates and uninstalling.

## Workspaces and popups

<p><img src="docs/images/readme-workspaces.gif" width="100%" alt="Switching workspaces updates the selected workspace and the app window below, with the screen held still."></p>

Follow your workspaces with [AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai), [OmniWM](https://github.com/OmniNull/OmniWM) or [Rift](https://github.com/acsandmann/rift). Without a window manager, try the opt-in [macOS Spaces source](docs/widgets.md#macos-spaces-workspaces).

<p><img src="docs/images/readme-popups.gif" width="100%" alt="The pointer opens music controls and then a CPU and memory graph beneath their widgets."></p>

Keep the active app, calendar, system stats and playback controls in reach. Widgets can open popups with graphs, lists and controls. Each display gets its own bar, with room for the notch.

[Built-in widgets](docs/widgets.md) · [Custom popups](docs/popups.md) · [Multiple displays](docs/layout.md)

## Make it yours

<p><img src="docs/images/readme-themes.gif" width="100%" alt="The same bar changes through the included themes while the screen and wallpaper stay still."></p>

Choose from seven included themes, get more from the Store, or save your own.

<p><img src="docs/images/readme-edit.gif" width="100%" alt="The pointer opens Edit Bar in Place, drags Now Playing beside the notch and clicks Done."></p>

Right-click the bar and choose **Edit Bar in Place** to drag widgets between positions, add them with **+** or remove them with **−**. Changes save as you go, with undo.

[Themes](docs/themes.md) · [Editing your bar](docs/settings.md)

## Add your widgets

<p><img src="docs/images/readme-script.gif" width="100%" alt="A shell script prints disk usage and its output appears as a widget on the bar."></p>

Run a command that prints text or JSON, and its output becomes a widget. Refresh on a timer or on events.

<p><img src="docs/images/readme-store.gif" width="100%" alt="The pointer gets Weather from the Store, and its widget appears on the bar."></p>

Find widgets and themes in **Settings → Store**. StableBar shows a package's commands, hosts and permissions before anything runs.

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
  "theme": { "id": "clear" },
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

<p>
  <a href="https://github.com/M4n0x"><img src="https://github.com/M4n0x.png?size=96" width="48" height="48" alt="M4n0x"></a>
  <a href="https://github.com/Seb-GRAF"><img src="https://github.com/Seb-GRAF.png?size=96" width="48" height="48" alt="Seb-GRAF"></a>
  <a href="https://github.com/Jonathanm10"><img src="https://github.com/Jonathanm10.png?size=96" width="48" height="48" alt="Jonathanm10"></a>
  <a href="https://github.com/albucci"><img src="https://github.com/albucci.png?size=96" width="48" height="48" alt="albucci"></a>
  <a href="https://github.com/amar9elbeg"><img src="https://github.com/amar9elbeg.png?size=96" width="48" height="48" alt="amar9elbeg"></a>
  <a href="https://github.com/sailedev"><img src="https://github.com/sailedev.png?size=96" width="48" height="48" alt="sailedev"></a>
</p>

Built by [Sebastien Graf](https://github.com/Seb-GRAF) and [Steve Mendes Reis](https://github.com/M4n0x), with help from [everyone who has contributed](https://github.com/stablebox/StableBar/graphs/contributors).

Questions, ideas and setups to share go in [Discussions](https://github.com/stablebox/StableBar/discussions). Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build StableBar, run the tests and open a pull request. Report security issues privately through [SECURITY.md](.github/SECURITY.md).

Available under the [MIT License](LICENSE), including commercial use and redistribution.

If StableBar is useful to you, you can [buy us a coffee on Ko-fi](https://ko-fi.com/stablebar).

[![Latest release](https://img.shields.io/github/v/release/stablebox/StableBar?label=release&color=ffe04a&labelColor=1d1813)](https://github.com/stablebox/StableBar/releases/latest)
[![CI](https://github.com/stablebox/StableBar/actions/workflows/ci.yml/badge.svg)](https://github.com/stablebox/StableBar/actions/workflows/ci.yml)
