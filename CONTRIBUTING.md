# Contributing

## Setup

Requires macOS 14+ and Xcode's Swift 6 toolchain. Optional workspace widgets require AeroSpace 0.21+ or yabai on your login shell's `PATH`.

Quit the running app before rebuilding its bundle.

```sh
./scripts/build.sh
open dist/StableBar.app
```

Local app builds show **Development** in **Settings → General → Updates**, with the source revision and a `-dirty` suffix when the checkout has changes. A local rebuild of beta source is still a development build; install the beta DMG for its published version and build number.

A development build registers the same `stablebar://` link scheme as the installed app, so macOS may open a source's join link or a package link in either one.

For development checks:

```sh
swift build
swift test
```

Node.js runs only the release tooling and the commit message check. `npm ci` installs them, and `npx commitlint --from origin/main` checks your commits before you push.

[t3.json](t3.json) defines project scripts: it builds each new worktree in the background and adds **Test** and **Build app**. Coding agents read [AGENTS.md](AGENTS.md); `CLAUDE.md` points Claude Code to it.

### Build an installer

Install [create-dmg](https://github.com/create-dmg/create-dmg) once with `brew install create-dmg`, then run:

```sh
./scripts/package.sh
```

This creates `dist/StableBar.dmg` with a custom background and the app beside an Applications shortcut. It builds in a temporary directory, leaving a running `dist/StableBar.app` untouched. The app and installer target the build Mac's processor family.

Local builds are ad-hoc signed. For public distribution without an unidentified-developer warning, use a Developer ID Application certificate and a saved `notarytool` keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='stablebar-notary' ./scripts/package.sh
```

The script signs with the hardened runtime, submits the DMG to Apple, then staples and validates its notarization ticket. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for certificate and keychain-profile setup. A local DMG is suitable for development; building it alone does not make it a notarized release.

## Architecture

- [Configuration.swift](Sources/StableBar/Configuration.swift): config, widget definitions and style inheritance.
- [StyleResolution.swift](Sources/StableBar/StyleResolution.swift): style layers and states resolved in one place for bar widgets, workspace cells, layout blocks and the bar, and the rules that set data states.
- [WidgetLabel.swift](Sources/StableBar/WidgetLabel.swift): what each widget type shows and the default layout it draws.
- [BarStore.swift](Sources/StableBar/BarStore.swift): live reload, shared provider lifetimes, visibility, sleep and each widget's resolved style.
- [ConfigurationLoader.swift](Sources/StableBar/ConfigurationLoader.swift): includes, profiles, tokens and provenance.
- [ConfigurationEdits.swift](Sources/StableBar/ConfigurationEdits.swift): file-preserving edits shared by CLI and editor.
- [RuntimeControl.swift](Sources/StableBar/RuntimeControl.swift): local request/reply control endpoint.
- [ConfigurationEditor.swift](Sources/StableBar/ConfigurationEditor.swift): preview, undo/redo and validated persistence.
- [NativeMetrics.swift](Sources/StableBar/NativeMetrics.swift): CPU, memory, network and calendar readings.
- [AudioMonitor.swift](Sources/StableBar/AudioMonitor.swift): output-device readings and CoreAudio change listeners.
- [PowerMonitor.swift](Sources/StableBar/PowerMonitor.swift): battery readings and power-change notifications.
- [WidgetPackage.swift](Sources/StableBar/WidgetPackage.swift): package inspection, installation, store downloads and version selection.
- [Workspaces.swift](Sources/StableBar/Workspaces.swift): AeroSpace subscriptions, yabai refreshes and workspace actions.
- [Yabai.swift](Sources/StableBar/Yabai.swift): yabai snapshots mapped to workspaces and screen numbers.
- [ScriptWidget.swift](Sources/StableBar/ScriptWidget.swift): the runner that applies a data source's output, with diagnostics, retries and suspension.
- [DataSource.swift](Sources/StableBar/DataSource.swift): the data source protocol, and the command, stream, polling and push sources.
- [DataSourceRegistry.swift](Sources/StableBar/DataSourceRegistry.swift): each data source type, the settings it reads, how it runs and the access it needs.
- [BuiltInEvents.swift](Sources/StableBar/BuiltInEvents.swift): the events StableBar sends itself and what `INFO` holds.
- [BarView.swift](Sources/StableBar/BarView.swift): native rendering and selection animation.
- [LayoutConfiguration.swift](Sources/StableBar/LayoutConfiguration.swift): groups, priority overflow and notch-aware placement.
- [PopupConfiguration.swift](Sources/StableBar/PopupConfiguration.swift): popup layout blocks.
- [PopupView.swift](Sources/StableBar/PopupView.swift): shared popup rendering and script bindings.
- [WidgetPopup.swift](Sources/StableBar/WidgetPopup.swift): anchored panel, dismissal and screen placement.
- [StableBarApp.swift](Sources/StableBar/StableBarApp.swift): non-activating panels and application lifecycle.

There is no web view, custom drawing loop or private window-server API. Styling and data updates are separate from window placement. Performance and long-term stability still need measurement with your actual widgets and displays.

## How we work

1. **Start from an issue** for every `fix`, `feat` or `perf` change, using the issue forms, and link it from the pull request. The [triage skill](#agent-skills) checks whether a report is already tracked, fixed or supported. Other changes, such as CI, tests or docs, can go straight to a pull request.
2. **Branch from `main` and open a pull request.** Nobody pushes to `main` directly. Fill in the template: the problem, the changes, how you tested them and how to merge, and end with the model and harness that did the work, or with "No agent". Upload screenshots of visible changes to the pull request instead of committing them.
3. **Keep one problem per pull request.** Unrelated fixes and cleanups get their own.
4. **Wait for CI.** `Test` and `Commit messages` must pass. `Linked issue` and `Description` check the pull request itself and rerun when you edit its description: a `fix`, `feat` or `perf` pull request closes an issue ("Fixes #N" in the description), and Problem, Changes and Testing are filled in. Depending on what a pull request changes, `Build release`, `Docs images` and `Package` run too ([Commits and releases](#commits-and-releases) lists when). Fix them before merging: the same failure on `main` stops the next beta.
5. **Merge** with a merge commit or a rebase merge, so semantic-release sees each commit. Squash only when the title alone should reach the changelog.

Reviews are requested automatically from the people listed in [CODEOWNERS](.github/CODEOWNERS), but they are not required. Ask for one when a change is risky or outside your usual area.

[CodeRabbit](https://coderabbit.ai) also reviews every pull request once it is out of draft, and comments only on what matters most. Fix each comment or reply why not, then resolve its thread: unresolved conversations block merging. Its rules come from [AGENTS.md](AGENTS.md) and [.coderabbit.yaml](.coderabbit.yaml).

## Commits and releases

Pull requests run `swift test` on macOS and check that every commit message, and the pull request title, follows [Conventional Commits](https://www.conventionalcommits.org). Squash merges use the title as the commit message. The tests load every configuration, module and package in `examples`, and the **Test** job parses each script in `scripts` and `examples` with the shell its first line names. The **Test pull request checks** job runs `node --test` on the logic of `Linked issue` and `Description`, in `.github/scripts`.

A pull request that changes `Sources`, `Resources`, `Package.swift`, `Package.resolved`, `scripts` or the CI workflow also compiles the release and draws the [docs images](#docs-images), as `main` does. If it changes `Resources`, `scripts` or the workflow, the **Package** job builds the DMG as a beta would, ad-hoc signed because pull requests get no Developer ID, and checks its signature, version and starter configuration.

[semantic-release](https://github.com/semantic-release/semantic-release) reads the commits since the last stable release and decides the next version:

| Commit | Release |
| --- | --- |
| `fix:`, `perf:` | Patch: 0.1.0 → 0.1.1 |
| `feat:` | Minor: 0.1.0 → 0.2.0 |
| `feat!:`, or a `BREAKING CHANGE:` footer | Major: 0.1.0 → 1.0.0 |
| `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, `test:` | None |

Queued pushes skip builds when `main` has already moved on. Tests and release compilation run in parallel, with separate Swift build caches for debug and release. Pull requests restore `main`'s release cache but don't save their own. Packaging uses the compiled binary from the same workflow run only after both jobs pass; signing, notarization and publication still happen in the release job.

Both release channels come from `main`:

- **Beta:** after the tests pass on `main`, CI builds `dist/StableBar.dmg` as the next version plus `-beta.<UTC timestamp>.<run number>`, such as `0.5.0-beta.20261020103000.114`, and publishes it as a GitHub prerelease. The timestamp uses `YYYYMMDDHHMMSS` so GitHub's alphabetical prerelease sorting keeps same-day betas in order when the run number gains a digit. A beta commits nothing. A push with no releasable commits since the last stable release makes no beta. Neither does a push that would ship the same app as the beta before it: `scripts/unchanged-app.sh` checks that every commit since that beta is `docs:`, `ci:` or `test:`, and that none of them touches `Sources`, `Resources`, `Package.swift`, `Package.resolved` or `scripts`.
- **Stable:** a maintainer starts it from **Actions → CI → Run workflow** on `main`. It releases the newest commit on `main`, and only once that commit has shipped as a beta, or comes after a beta with only such docs, CI and test commits, so stable ships the app beta users have run. It sets `CFBundleShortVersionString` to the version and `CFBundleVersion` to the run number in [Resources/Info.plist](Resources/Info.plist) with `scripts/set-version.sh`, points the website's download buttons at the version's DMG with `scripts/set-site-version.sh`, adds its notes to `CHANGELOG.md`, commits all three with the [docs images](#docs-images) as `chore(release): <version>`, tags `v<version>` and publishes a GitHub release with the DMG. The release commit skips CI, so the job then starts the **Website** workflow, which deploys the new download once its DMG is public.

To retry a missing beta, use **Actions → CI → Run workflow** on `main` and choose **beta** as the release channel. The default channel is **stable**.

A stable release pushes its commit and tag before it publishes the GitHub release and the update feed. If it fails after that, start a new stable release from **Run workflow** before anything else lands on `main`; **Re-run jobs** would check out the commit before the tag. When the newest commit already carries a stable tag, the run reuses that version's DMG, or builds it again if the release has none, publishes its GitHub release, deploys the website and adds the release to the update feed.

Both jobs use the CI run number, which only goes up, so a stable build always numbers higher than the betas before it. In-app updates compare that number to find the newest release.

Both jobs sign and notarize the app with a Developer ID when the repository has one, and only then add the release to the update feed: Sparkle installs an update only when it's signed by the same developer as the running app. Without one, builds are ad-hoc signed and `scripts/prepare-app-info.sh` leaves out their `SUFeedURL`. To set it up, add:

- the `DEVELOPER_ID_CERTIFICATE` secret: the Developer ID Application certificate and its private key, exported as a `.p12` and base64-encoded, with its password in the `DEVELOPER_ID_CERTIFICATE_PASSWORD` secret;
- an App Store Connect API key for notarization: the `.p8` file's contents in the `NOTARY_API_KEY` secret, and its key ID and issuer ID in the `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER` variables.

`scripts/publish-appcast.sh` adds each signed release to `appcast.xml` in the `appcast` prerelease, the feed every release checks, with betas on Sparkle's `beta` channel. Each item carries its GitHub release notes, whose bullet points the update tile's popup lists, and a link to the release.

A stable release then sets the version and SHA-256 of the `stablebar` cask in [Seb-GRAF/homebrew-tap](https://github.com/Seb-GRAF/homebrew-tap). It pushes with the `HOMEBREW_TAP_TOKEN` secret: a fine-grained token for that repository only, with read and write access to its contents.

Release jobs set `STABLEBAR_RELEASE_BUILD=1` when packaging to preserve their stamped version and build number. Other app builds get Development metadata from the checkout's Git revision, including changes since its nearest release tag and a `-dirty` suffix for local changes. Without Git metadata, the version is `0.0.0-dev`. This changes only the built app's plist; the tracked release plist stays untouched.

## Docs images

`scripts/render-docs-images.sh` draws the images in `docs/images` from the app's own bar, popup and Settings views, with sample data, a fixed date (Thursday 22 October 2026, 09:41 UTC) and a local, empty Store index, and writes them as WebP. Two runs of one commit on one Mac draw the same pixels. It needs `cwebp`: `brew install webp`. The **Docs images** CI job draws them on every push to `main` and on pull requests that change the app, and a stable release commits them, so a change to the bar, popups or Settings doesn't need new images. To show something new, add a scene to [DocsImages.swift](Sources/StableBar/DocsImages.swift).

## Scenes

A scene file in [scenes](scenes) describes one screen to draw: a configuration, inline or as a path such as `../Resources/config.json`, the sample outputs, graph history and AeroSpace workspaces its widgets show, and what to draw: the `bar`, the bar in edit mode (`editBar`), a widget's `popup`, or a `settings` page. [scene.schema.json](scene.schema.json) lists every key. Draw them with:

```sh
StableBar --render-scenes /tmp/scenes scenes
```

It writes `<name>-dark.png` and `<name>-light.png` for each scene, and `scenes.json` with each scene's images or the error that stopped it. It runs nothing (no command, provider, window manager or network request), and every clock shows Thursday 22 October 2026, 09:41 UTC, so two runs of one commit on one Mac draw the same pixels. Text about the Mac itself, such as a display's name or the window managers installed, still comes from the Mac that draws.

A change you can see extends the scene that shows its area, or adds one when none does. Scenes can be edited, merged or deleted. Keep the format additive: a build reports a scene it can't read as an error and draws the others.

## Agent skills

Skills for coding agents live in [.agents/skills](.agents/skills), one folder per skill with a `SKILL.md`. Codex reads that directory, and `.claude/skills` links to it for Claude Code. Invoke a skill by name (`/triage` in Claude Code, `$triage` in Codex) or describe the task and let the agent choose it.

| Skill | Use |
| --- | --- |
| [triage](.agents/skills/triage/SKILL.md) | Checks a bug report or feature request against issues, pull requests, `main` and releases, and drafts a GitHub issue when nothing covers it. It posts only what you asked it to file or approved. |

To add a skill, create `.agents/skills/<name>/SKILL.md` with `name` and `description` front matter.

## Security

Report vulnerabilities privately, as described in [SECURITY.md](.github/SECURITY.md).
