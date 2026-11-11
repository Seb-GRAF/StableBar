# Questions

These are short answers to common questions, each with a link to the guide for the details; **Settings → Help** in StableBar shows the same page.

## Why do windows go under the bar?

macOS gives a custom bar no way to reserve screen space, so StableBar has to move windows out of the way itself. If you don't use a tiling window manager, turn on **Settings → General → Windows and notifications → Keep windows clear of the bar** and allow StableBar in **System Settings → Privacy & Security → Accessibility**. StableBar then moves windows that overlap the bar below it, and makes them shorter when they would run into the Dock.

If a window manager arranges your windows, leave that switch off and give the window manager a top gap as tall as the bar, 40 points by default, plus any `bar.offset`:

- AeroSpace: `gaps.outer.top` in `~/.aerospace.toml`
- yabai: `external_bar` in your yabai configuration
- OmniWM: `gaps.outer.top` in its `settings.toml`
- Rift: `top` under `[settings.layout.gaps.outer]` in `~/.config/rift/config.toml`

Fullscreen windows, minimized windows and dialogs stay where they are, and a few apps don't let StableBar move their windows. See [Keeping windows clear of the bar](getting-started.md#keeping-windows-clear-of-the-bar).

## How do I hide the macOS menu bar, or keep it?

To hide it, turn on **Settings → General → Native menu bar → Automatically hide the menu bar**; StableBar then sits on the top edge in its place. To keep it, turn that switch off and turn on **Below the menu bar** in **Settings → Bar → Bar → Placement**, so StableBar sits under it. Setup asks the same question with **Replace the menu bar** and **Keep the menu bar**.

This changes the macOS setting itself, so it stays after StableBar quits. The first time, macOS asks to let StableBar control System Events; if you said no, turn on **System Events** under StableBar in **System Settings → Privacy & Security → Automation**.

A hidden menu bar still appears when the pointer reaches the top edge. **Reveal delay**, in the same section, makes it wait longer, and **Always hide** keeps it out of sight while StableBar runs. See [Hide the native menu bar](getting-started.md#hide-the-native-menu-bar).

## Where is the configuration file, and how do I apply a change?

It's `~/.config/stablebar/config.json`. **Settings → General → Configuration file** opens it, shows it in Finder or reloads it.

StableBar watches the file and applies a change as soon as you save it. If the change has a mistake, the bar keeps the last working configuration and shows an error indicator; click it to see the error in Settings. Changes you make in Settings apply at once and save to your configuration. See [The configuration file](configuration.md#the-configuration-file).

## Why don't the app menus or the Apple menu open?

They need Accessibility access. Allow StableBar in **System Settings → Privacy & Security → Accessibility**, or click **Allow…** in **Settings → General → Access**. Until you do, App menus shows a warning icon, and clicking the Apple logo asks for access.

The menus follow the app that owns the macOS menu bar, so while Settings or another StableBar window is in front, they keep the previous app's menus. Menus that don't fit, for example beside the notch, are behind **»**. See [App menus](widgets.md#app-menus).

## Which permissions does StableBar ask for, and why?

Setup asks for these in its permissions step, and **Settings → General → Access** lists the ones your bar needs:

- **Accessibility**, for the app menus, the Apple menu, Menu bar items, Workspaces and keeping windows clear of the bar.
- **Automation**, to control System Events, which hides or shows the macOS menu bar.
- **Calendars**, for Meetings and other calendar widgets.

Scripts that control other apps ask for their own Automation access when they run, and Workspaces on macOS Spaces needs Screen Recording to show window titles. See [Install and set up](getting-started.md#install-and-set-up).

## Where did my other apps' menu bar icons go?

The **Menu bar items** widget, a grid symbol, lists them. Rest the pointer on it, or click it, to see every item in the macOS menu bar as a row of icons, then click one to open its menu. It needs Accessibility access. If your bar doesn't have it, add **Menu bar items** with **Add widget** in **Settings → Bar**.

To keep an item you use often on the bar itself, right-click its icon in the row and choose **Show on Bar**; **Hide** takes an item out of the row. In **Settings → Bar**, the widget's **Content** tab arranges them all. See [Menu bar items](widgets.md#menu-bar-items).

## How do I show my workspaces on the bar?

Add **Workspaces** with **Add widget** in **Settings → Bar**. It uses whichever of AeroSpace, yabai, OmniWM or Rift is running, and your macOS Spaces when none is. To pick another source, use **Settings → General → Workspaces**.

Some sources need one step on their side:

- yabai: add StableBar's [signals](widgets.md#yabai-workspaces) to your yabai configuration, then run `yabai --restart-service`.
- OmniWM: turn on [**Enable IPC**](widgets.md#omniwm-workspaces) in OmniWM's menu.
- Rift: turn on [each Space](widgets.md#rift-workspaces) you want it to manage, with **Alt + Z** by default.
- macOS Spaces: turn on the [**Switch to Desktop** shortcuts](widgets.md#macos-spaces-workspaces) and allow Accessibility.

If the widget can't reach your window manager, check that it's running, then choose **Reconnect** in **Settings → General → Workspaces**. See [Built-in widgets](widgets.md).

## How do I change the theme?

Open **Settings → Theme** and click a theme card: it applies and saves at once, and **Undo** brings back the one before. Filter the cards by **Store** for more themes, and choose **Get** to install and use one.

To try themes on the bar itself, choose **Try Themes…** from the bar's right-click menu or the menu-bar icon. Press ← and → to go through them, then Return to keep the one shown, or Esc to go back to your old look.

**Light** and **Dark** in **Settings → Theme** keep the bar in one appearance, and **Automatic** follows your Mac's. See [Themes](themes.md).

## Can my laptop and my external monitor show different widgets?

Yes. StableBar draws a bar on every display, and you choose where each widget shows: select it in **Settings → Bar** and use **Shows on**, beside its name, to pick **All screens**, the laptop, landscape monitors, vertical monitors or **Hidden everywhere**. With more than one kind of screen connected, moving a widget moves it only on the kind of screen selected in **Settings → Bar**.

For a whole different bar when you dock, give that screen setup its own bar: in **Settings → Bar**, open the menu beside the screen thumbnails and choose **Give it its own bar**. StableBar then switches bars when you connect or disconnect a screen.

**Settings → Bar** can also scale the bar down on the laptop only (`bar.displayScale`). See [Screen setups](layout.md#screen-setups).

## Will the notch hide my widgets?

No. On a display with a notch, StableBar places widgets on either side of it, and each side uses only its own room. Widgets set to the center join the right side.

When a side runs out of room, App menus put their last menus behind **»**, and other widgets move behind a **⋯** button on that side; click it to reach them. Give a widget a higher `priority` to keep it on the bar longer.

The **Notch** theme draws a black bar that blends into the notch. See [Displays and notch placement](layout.md#displays-and-notch-placement).

## How do I add a widget that runs my own script?

Add a `script` widget to `widgets` in your configuration file. StableBar runs its `command` every `interval` seconds and shows what it prints:

```json
{
  "id": "my-widget",
  "type": "script",
  "position": "right",
  "command": "~/.config/stablebar/widgets/my-widget.sh",
  "interval": 30
}
```

Keep your scripts in `~/.config/stablebar/widgets/` and make them executable. A script can print plain text, or one JSON object such as `{"text":"Ready","icon":"checkmark.circle"}` to add an SF Symbol, a color or a tooltip.

**Add widget** in **Settings → Bar** also offers **Script**; change its command with **More → Edit as JSON…**. See [Create a widget](create-a-widget.md).

## What can a package from the Store do on my Mac?

A package that runs commands runs them as you, so it can do anything a program you open can do. Before you add one, its page in **Settings → Packages** lists its widgets, the commands it runs, the hosts it contacts and the macOS permissions it uses. StableBar shows those lists but doesn't enforce them, so add packages with commands only from sources you trust.

Themes never run commands. Every Store package is open source, the Store builds and publishes it rather than its author, and a maintainer reads each version of a package that runs commands before it goes out. Packages from a private source aren't reviewed by StableBar's maintainers.

StableBar never updates a package by itself. When you update one whose new version runs new commands, contacts new hosts or needs new permissions, it lists them and asks first. See [Store](packages.md#store).

## How do I update StableBar, or try betas?

StableBar checks for updates by itself. When one is out, a download icon appears at the right end of the bar: click it to read what changed, then choose **Download** and **Install and Relaunch**. **Check for Updates…** in the menu-bar icon's menu checks right away.

To get betas, set the update track to **Beta** in **Settings → General → Updates**. You then get betas of the next version and stable releases, whichever is newer. Going back to **Stable** keeps your beta until a newer stable release is out.

Builds you make yourself, and releases not signed with a Developer ID, don't update themselves; get new versions from the [releases page](https://github.com/Seb-GRAF/StableBar/releases). See [Updates](getting-started.md#updates).

## What do I do when StableBar crashes or something goes wrong?

Open **Settings → Status**. It shows which widgets have a problem and what to do, such as allowing access or restarting a connection. **Crashes**, in its sidebar, lists the times StableBar quit unexpectedly in the last 30 days, and after a new crash the menu-bar icon's menu shows **StableBar Quit Unexpectedly…**.

To report it, open **Settings → Help → Send feedback**, or choose **Send Feedback…** in the menu-bar icon's menu. Choose **Something's wrong** and answer its questions; StableBar adds a bug report with your versions, displays, configuration errors and recent crashes, without your configuration's values; widget errors show what your scripts printed, so read it first. Then send it:

- **Open on GitHub…** fills in the issue form in your browser; nothing is sent until you submit it.
- **Post as @account…** posts the issue for you when the [GitHub CLI](https://cli.github.com) is installed and signed in.
- **Copy** copies the title and answers as Markdown.

**Report a problem**, at the bottom of **Settings → Status**, shows the same bug report, and **Copy bug report** copies it. See [Settings](settings.md).

## Does StableBar use much CPU or battery?

Very little. On a MacBook Pro, the starter bar used under 0.2 % of one CPU core while idle, about 7 seconds of CPU time an hour, with 30 MB of memory and an Energy Impact of 0.1. A larger bar with Workspaces used about 4 % while switching AeroSpace workspaces once a second.

Your own scripts aren't in these numbers: each runs as its own program, and costs what its command costs, as often as its `interval` runs it. Activity Monitor shows StableBar's own **% CPU**, **Energy Impact** and **Memory**. See [Performance](performance.md).

## How do I uninstall StableBar?

Use **Settings → General → Uninstall → Uninstall…**, which lists each step before it starts. It turns off the menu bar auto-hide that StableBar turned on, removes it from Open at login, resets its permissions, deletes its caches and preferences, and moves the app to the Trash.

Your `~/.config/stablebar` folder, with your configuration, scripts and packages, stays unless you check **Also move ~/.config/stablebar to the Trash**.

If Homebrew installed StableBar, run **Uninstall** first and click **Quit StableBar**, then run `brew uninstall --cask stablebar`; `brew uninstall --zap --cask stablebar` does both and also deletes `~/.config/stablebar`. See [Uninstall](getting-started.md#uninstall).
