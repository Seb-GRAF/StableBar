# Packages and the store

## Local widget packages

Open **Settings → Packages → Open a folder…** to review a local package. Its page lists the included widgets, setup fields, requirements and commands. A block with `onClickField` is listed by the field it reads its command from. **Add to bar** installs the package if needed and enables it after review; **Use theme** selects a theme. The command-line install operation only installs files and never enables a package.

**Installed** and **Store** organize Packages, with search by name, description or ID. Installed lists **StableBar Essentials**, the widgets and themes included with the app, first, then groups installed packages into **On your bar**, **Not on your bar** and **Themes**. Essentials shows sample widgets with **Add to bar** actions and theme previews. Its Clock & date, Battery, System monitor, Network and Calendar include native details and Content settings. After an app update, existing Store copies of Date, Battery status, System monitor, Network speed and Calendar agenda become built-in automatically. They keep their widget IDs, placement, visibility, settings and profile overrides, with the updated Essentials designs and controls. No reinstall or replacement is needed. Edit them in **Your bar → Content**; they update with the app and no longer appear as separate Store packages. The saved package selections and installed files stay intact for rolling back the app. Official copies installed from a folder also become built-in when their manifest names the StableBar packages repository. Other local packages and private-source copies are unchanged. Installed rows show a small preview beside each package's name and version; Store cards show one above the name. Supplied images show sample content; packages without an image show a theme preview or samples of their included widget types. Previews do not run commands, request permissions, install packages or change your bar. Store shows packages as a grid of cards with their kind, author, description and **Get** button, filtered by **All**, **Widgets** or **Themes**. Packages with an update come first, then installed packages, then the rest, each in alphabetical order. Click a card to open the package's page; **Store** at the top of the page returns to the grid. The package page shows the same preview at a larger size. Installed packages with newer versions in the source they were installed from appear first under **Updates available**, with the installed and new version and an **Update** button. One click downloads, checks, installs and replaces the selected version on the current bar, preserving compatible settings, credentials, widget placement, visibility and overrides. An installed package that is not on the bar stays inactive. Additional commands, hosts or permissions require review before updating. A failed update keeps the previous selection; old files remain available and changing the selected version supports Undo. The reload button beside **Open a folder…** refreshes every source's listing and checks for updates. **General → Updates → Notify about package updates** is on by default and checks shortly after launch, then hourly. A small package button in the bar opens Packages; its × dismisses the notice for those versions, including after relaunch. Updates remain listed in Packages, and a newer version can show the notice again. Turning the setting off stops background package checks and hides the button. A package has **Overview**, **Settings**, **Access** and **Versions** tabs. In Versions, choose **Use** beside an installed version to review it and change the pin. Compatible settings carry over; a value that a new version no longer accepts falls back to that version's default. Settings for an active package save automatically and support Undo. Setup drafts for a package you have not added, another version and unsaved credentials survive navigation within Settings.

Built-in and Included content ships with the app. Installing a package records the source it came from: the StableBar Store, a [private source](#private-sources), or **Local folder** for a folder you opened. Its page and its row in Installed show that source. A copy from the Store says the Store built and published it, and that a maintainer read it when it runs commands; a copy from a private source shows **From** its name and host, and that StableBar’s maintainers didn’t review it. A package installed before StableBar recorded sources shows **Listed in the Store** when the Store lists its ID, or **On this Mac** otherwise, and its review status is unknown. Uninstalling the last version of a package deletes its record.

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

A package whose `package.json` sets `"kind": "widgets"` contains no commands, so it needs no command review. Its configuration can contain only `tokens`, `defaults`, `bar`, `groups`, `profiles`, `widgets`, `templates`, `popups` and `providers`, plus includes inside the package. Nowhere in it, including templates, popups, providers and profiles, can it set `command`, `onClick`, `onClickField`, `rightClick`, `middleClick`, `scrollUp`, `scrollDown`, `mouseEntered`, `mouseExited`, `onChange` or `environment`, so script widgets and `command` or `stream` providers are rejected too. Built-in widget types, native providers, [`open`](widgets.md#mouse-actions) and [`quitField`](popups.md), which asks before it quits anything, remain available, and built-in widgets keep their own behaviour: a `workspaces` widget still talks to AeroSpace, yabai or OmniWM. StableBar checks this when the package is reviewed, installed and loaded, and **Settings → Packages** and `--inspect-package` say that it contains no commands instead of listing them. Enable it in `packages` like any widget package. [examples/packages/system-monitor](../examples/packages/system-monitor/config.json) shows CPU in the bar, in the theme's warning colors when the Mac is under strain, and a popup with CPU and memory details and the apps using the most memory or CPU, each with a button that quits it.

## Store

**Settings → Packages → Store** lists widget packages from the [StableBar store](https://github.com/Seb-GRAF/stablebar-packages), with their descriptions and versions. Select one to download and inspect it, review its included widgets, setup and access requirements, then choose **Add to bar**. Loading the list does not download every package; only the chosen package is inspected. A package that needs a newer StableBar shows the version it requires and cannot be installed. The reload button at the top of Packages refreshes the index. Installed packages remain available when the Store cannot be reached.

With a [private source](#private-sources) added, the grid lists the packages of every source, and search covers them all. **All sources**, next to **All**, **Widgets** and **Themes**, narrows the grid to one source. Each card is tagged with its source: **StableBar Store**, or the private source's name with a lock. When two sources list the same package ID, both cards appear. Once one copy is installed, the other source's card shows **Installed from** the installing source instead of **Get** and sorts with the installed packages; uninstall that copy before getting the other.

On the command line, give `--install-package` a package ID instead of a folder; this installs without enabling. When more than one source lists the ID, add `--source` with the source's `id`:

```sh
StableBar --install-package nord
StableBar --install-package clock --source acme
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

## Private sources

A private source is a package index that your team hosts, for packages that can't go in the public Store, such as widgets for an internal GitLab or company tools. Its packages appear in Packages, **Settings → Theme** and **Add widget** beside the Store's. The StableBar Store is always on.

To add one, open **Settings → Packages → Sources…** and choose **Add source…**. Enter a name, the index URL and, if the index needs one, your token. When you pause typing, StableBar loads the index and shows how many packages it found, or what went wrong, with **Check again** to retry. **Add source** is available after a successful check. A URL you already have is reported with that source's name. The sheet lists the StableBar Store, then each private source with its package count or error, whether a token is saved, and the file that defines it when it comes from an include. **Edit** changes a source's name, URL and token; **Remove token** deletes its token and **Remove source** removes it from your configuration, with Undo. A source from an include keeps its name and URL; change those in that file.

Sources are saved in `packageSources` in your configuration:

```json
{
  "packageSources": [
    {
      "id": "acme",
      "name": "Acme",
      "url": "https://gitlab.example.com/api/v4/projects/412/packages/generic/stablebar/store/index.json"
    }
  ]
}
```

`id` uses letters, numbers, dots, dashes and underscores, and must be unique. It ties installed packages to the source, so you can rename a source or move its URL. A saved token keeps working only on the same host (see [Tokens](#tokens)). `stablebar` and `local` are reserved, and only the public Store can be named **StableBar Store**, in any capitalization. `url` must use `https` and have no user name, password, `?query` or `#fragment` (use a token instead), because archives are read from the index's folder. A team can share its sources through an [include](configuration.md#modules-templates-and-overrides): sources merge by `id`, with later modules and the main file winning. Packages and profiles can't add sources. StableBar 0.6.0 and later read `packageSources`; older versions refuse a configuration that contains it, so add sources to a shared include once everyone has updated.

### Joining with a link

A source's row has **Copy join link**, which copies a `stablebar://add-source` link. Send it to your team: opening it in macOS opens **Settings → Packages → Sources…** with the **Add source** form filled in. The link holds the source's name, index URL and id, such as `stablebar://add-source?name=Acme&url=https://gitlab.example.com/…/index.json&id=acme`. It never holds a token, and StableBar ignores any `token` in a link; each member enters their own in the form. Nothing is added until you review the form, let it check the index and choose **Add source**. The form says it was opened from a link, because packages from a source can run commands once you review them: add it only if you trust who publishes it. If you already have that URL, the form says "You already have this source" with its name, and nothing is added. If the link's id is taken, the form picks another id. A link is refused unless its URL uses `https` and has no user name, password, `?query` or `#fragment`. A link named StableBar Store is refused too.

### Tokens

Each member uses their own token: a GitLab personal access token with the `read_api` scope, or a GitHub token that can read the repository. Use a fine-grained token with **Contents: read** when the repository belongs to you or to an organization you're in, and a classic token with the `repo` scope when it belongs to another person's account: a fine-grained token can't read that repository, and GitHub answers 404. Enter it in the source's form. StableBar keeps it in the login Keychain, never in a configuration file, and Settings only shows whether one is saved. As with package secrets, macOS may ask whether StableBar may use it after an update; choose **Always Allow**. Removing a source keeps its token, so Undo brings the source back working.

A token is sent only to the scheme, host and port of the index URL it was saved for: to the index, its archives and screenshots on that host. A redirect to another host drops it. If a source's URL moves to another host, the token isn't sent there; enter it again. For a URL whose path starts with `/api/v4/`, as on GitLab, it goes in a `PRIVATE-TOKEN` header; otherwise in `Authorization: Bearer`. Configuration and package commands can't read a source token.

When a source fails, Packages names it and the reason, such as a refused token for HTTP 401 or 403. GitHub answers 404 when the token is missing or can't read the repository. Other sources and installed packages keep working.

### Hosting a source

A source is an `index.json` in the same format as the Store's in [stablebar-packages](https://github.com/Seb-GRAF/stablebar-packages), with the archives it lists. Archive paths are relative to the index and must stay on its host. Each package's `source` repository URL is optional in a private index. Host it in one of these places:

- **A private GitHub repository:** commit the index and archives to a branch and use `https://raw.githubusercontent.com/OWNER/REPO/BRANCH/index.json`, with a token that can read the repository (see [Tokens](#tokens)). GitHub serves a private repository's release assets only through its API, so release assets don't work.
- **GitLab's generic package registry:** upload the index and archives to one package version and use `https://<host>/api/v4/projects/<id>/packages/generic/<name>/<version>/index.json`, with a `read_api` token.
- **Any HTTPS server** that serves the files, with or without a bearer token.

### Publishing a source

Keep your packages in a folder, one package per subfolder, each with a `package.json`. `StableBar --build-source` checks every package the way a review does, writes one `<id>-<version>.tar.gz` archive for each package version that isn't published yet, and writes the `index.json` that lists them. It needs StableBar 0.6.0 or later, on a Mac.

A published archive never changes, so a package you change needs a new `version` in its `package.json`. Pass the index you published last time with `--previous`: each version it lists that is still in the folder keeps its entry and its archive, and only new versions get archives. Without `--previous`, the command refuses to overwrite an archive that is already in the output folder. The new index lists only the packages in the folder: removing a package's folder drops it from the index, so members can't get it any more, while its old archive stays hosted until you delete it.

**On a Mac:**

```sh
StableBar --build-source ./packages ./dist --previous ./previous/index.json --url https://example.com/store/index.json --name "My team"
```

It lists the packages in the index and the new files, and with `--url` and `--name` prints a `stablebar://add-source` [join link](#joining-with-a-link) for your team. `--url` is the address the index will have, an `https` URL without a user name, password, `?query` or `#fragment`. Upload the new files in `dist` and the new `index.json`. A package's `screenshot` is copied as `<id>-<version>-<file name>`.

**GitHub, private repository:** a workflow on a macOS runner can build the source and keep it on a `store` branch. Members read `https://raw.githubusercontent.com/OWNER/REPO/store/index.json` with a token that can read the repository.

```yaml
name: Publish packages
on:
  push:
    branches: [main]
    paths: [packages/**]
permissions:
  contents: write
jobs:
  publish:
    runs-on: macos-latest
    env:
      GH_TOKEN: ${{ github.token }}
      STORE_URL: https://raw.githubusercontent.com/${{ github.repository }}/store/index.json
    steps:
      - uses: actions/checkout@v4
      - name: Get StableBar
        run: |
          gh release download --repo Seb-GRAF/StableBar --pattern StableBar.dmg --dir "$RUNNER_TEMP"
          hdiutil attach -nobrowse -readonly -mountpoint "$RUNNER_TEMP/stablebar" "$RUNNER_TEMP/StableBar.dmg"
      - name: Build and publish
        run: |
          remote="https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git"
          if git ls-remote --exit-code --heads "$remote" store > /dev/null; then
            git clone --branch store --single-branch "$remote" store
          else
            git init --initial-branch store store
            git -C store remote add origin "$remote"
          fi
          previous=()
          if [ -f store/index.json ]; then previous=(--previous store/index.json); fi
          "$RUNNER_TEMP/stablebar/StableBar.app/Contents/MacOS/StableBar" --build-source packages dist "${previous[@]}" --url "$STORE_URL" --name "My team"
          cp dist/* store/
          cd store
          git add --all
          git -c user.name=github-actions -c user.email=actions@github.com commit --message "Publish packages" || exit 0
          git push origin store
```

**GitLab:** GitLab usually has no macOS runners, so build on a Mac and upload each new file, and the new `index.json`, to the generic package registry. Use a token with the `api` scope; members read with `read_api`. Download the index you published last time with the same token and pass it as `--previous`; on the very first build there is none, so leave out the download and `--previous`. Start from an empty `dist`, so it holds only the new files and the index:

```sh
INDEX="https://<host>/api/v4/projects/<id>/packages/generic/stablebar/store/index.json"
mkdir -p previous
curl --fail --header "PRIVATE-TOKEN: $TOKEN" -o previous/index.json "$INDEX"
StableBar --build-source ./packages ./dist --previous ./previous/index.json --url "$INDEX" --name "My team"
for file in dist/*; do
  curl --fail --header "PRIVATE-TOKEN: $TOKEN" --upload-file "$file" "${INDEX%/index.json}/$(basename "$file")"
done
```

`--fail` stops `curl` on an HTTP error, such as a refused token, instead of saving or uploading the error page.

**Linux CI, without macOS:** `scripts/build-index.sh` in [stablebar-packages](https://github.com/Seb-GRAF/stablebar-packages) writes the same format. It doesn't run StableBar's checks, so a package that StableBar would refuse only fails when someone installs it.

### Packages from a private source

A private package's page shows **From** the source's name and host, and "StableBar’s maintainers didn’t review this package." Once installed, it also says that updates are checked there. Review its commands and files before you enable it. Each installed package remembers its source, and its updates come only from there. A package installed from a folder, or before StableBar recorded sources, gets updates from the StableBar Store. When you remove a source, packages installed from it keep working, show the source's name followed by "(removed)" and get no updates.

One source owns each installed package ID:

- Installing from a source, with **Get**, **Add to bar** or `--install-package`, claims an ID that no source owns yet, including a package installed from a folder or before StableBar recorded sources. Nothing is uninstalled, so it stays on your bar with its settings. When the same version is already installed that way, its files must be the ones the source publishes; a copy with different files is refused until you uninstall it. Other versions already installed that way stay **Local folder** until you get or add the source's copy of them, which needs the same files too.
- Another source can't install an ID that a source owns. Uninstall every version first.
- Opening a folder with another version of an owned package installs it, so you can test it; updates still come from the source. That version shows **Local folder**, and `--packages` lists it as `local`. Getting or adding the same version from the owning source treats it like any folder copy: it becomes the source's only when its files are the ones the source publishes.
- Uninstalling the last version releases the ID.
