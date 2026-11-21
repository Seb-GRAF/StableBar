# Contributing

## Setup

Requires macOS 14+ and Xcode's Swift 6 toolchain. Optional workspace widgets require AeroSpace 0.21+ or yabai on your login shell's `PATH`.

CI builds with the Xcode that `DEVELOPER_DIR` names in [ci.yml](.github/workflows/ci.yml), currently 26.6, so an update of GitHub's runner image can't change it. A newer Xcode works locally; when CI should move to it, change `DEVELOPER_DIR` in a pull request of its own.

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

`scripts/check.sh` runs what CI checks for your branch: the syntax of the scripts you changed, your commit messages, the build and every test, and the tests in `.github/scripts` when you changed them. `scripts/check.sh --quick` only builds, and only when Swift files changed since its last successful run; `--commits` only checks the messages. In a worktree without `node_modules`, it uses the main checkout's commitlint.

Run `scripts/check.sh --install-hooks` once per clone: it sets `core.hooksPath` to [.githooks](.githooks), so git checks each commit message as you write it and the messages a push sends, in every worktree of the clone and whatever tool commits. Claude Code also runs the quick build when the agent stops, from [.claude/settings.json](.claude/settings.json), and sends a failing build back to work once. To turn the hooks off for yourself, set `STABLEBAR_SKIP_HOOKS=1`, in your shell or, for Claude Code, with `{"env": {"STABLEBAR_SKIP_HOOKS": "1"}}` in `.claude/settings.local.json`; `git config --unset core.hooksPath` turns the git hooks off for the clone.

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

The sources are grouped by area in [Sources/StableBar](Sources/StableBar): `App` (launch, the command line, updates, moving and uninstalling the app, reports), `Bar`, `Editing` (editing the bar in place), `Popups`, `Configuration`, `DataSources` (scripts, providers and what they read), `Workspaces`, `MenuBar` (App menus, menu bar items and the menu bar's behavior), `Packages`, `Themes` (themes and bar links), `Settings`, `Setup`, `Rendering` (offscreen scenes and docs images) and `System`.

- [Configuration.swift](Sources/StableBar/Configuration/Configuration.swift): config, widget definitions and style inheritance.
- [StyleResolution.swift](Sources/StableBar/Configuration/StyleResolution.swift): style layers and states resolved in one place for bar widgets, workspace cells, layout blocks and the bar, and the rules that set data states.
- [WidgetLabel.swift](Sources/StableBar/Bar/WidgetLabel.swift): what each widget type shows and the default layout it draws.
- [BarStore.swift](Sources/StableBar/Bar/BarStore.swift): one bar's parts, and showing a configuration across them in order.
- [ConfigurationStore.swift](Sources/StableBar/Configuration/ConfigurationStore.swift): the files that make up a bar, live reload, edits, migrations and writes, screen setups and theme trials.
- [WidgetScripts.swift](Sources/StableBar/DataSources/WidgetScripts.swift): shared provider lifetimes, events, click actions, visibility and sleep.
- [BarPresentation.swift](Sources/StableBar/Bar/BarPresentation.swift): each widget's resolved style and presence, and the bar's style.
- [AppWatcher.swift](Sources/StableBar/Bar/AppWatcher.swift): the front app, the active display and the app that owns the menu bar.
- [ConfigurationLoader.swift](Sources/StableBar/Configuration/ConfigurationLoader.swift): includes, profiles, tokens and provenance.
- [ConfigurationEdits.swift](Sources/StableBar/Configuration/ConfigurationEdits.swift): file-preserving edits shared by CLI and editor.
- [RuntimeControl.swift](Sources/StableBar/App/RuntimeControl.swift): local request/reply control endpoint.
- [RuntimeCommands.swift](Sources/StableBar/App/RuntimeCommands.swift): what a running bar answers on that endpoint.
- [ConfigurationEditor.swift](Sources/StableBar/Settings/ConfigurationEditor.swift): preview, undo/redo and validated persistence.
- [NativeMetrics.swift](Sources/StableBar/DataSources/NativeMetrics.swift): CPU, memory, network and calendar readings.
- [AudioMonitor.swift](Sources/StableBar/DataSources/AudioMonitor.swift): output-device readings and CoreAudio change listeners.
- [PowerMonitor.swift](Sources/StableBar/DataSources/PowerMonitor.swift): battery readings and power-change notifications.
- [WidgetPackage.swift](Sources/StableBar/Packages/WidgetPackage.swift): package inspection, installation, store downloads and version selection.
- [Workspaces.swift](Sources/StableBar/Workspaces/Workspaces.swift): AeroSpace subscriptions, yabai refreshes and workspace actions.
- [Yabai.swift](Sources/StableBar/Workspaces/Yabai.swift): yabai snapshots mapped to workspaces and screen numbers.
- [ScriptWidget.swift](Sources/StableBar/DataSources/ScriptWidget.swift): the runner that applies a data source's output, with diagnostics, retries and suspension.
- [DataSource.swift](Sources/StableBar/DataSources/DataSource.swift): the data source protocol, and the command, stream, polling, push and merge sources.
- [DataSourceRegistry.swift](Sources/StableBar/DataSources/DataSourceRegistry.swift): each data source type, the settings it reads, how it runs and the access it needs.
- [BuiltInEvents.swift](Sources/StableBar/DataSources/BuiltInEvents.swift): the events StableBar sends itself and what `INFO` holds.
- [BarView.swift](Sources/StableBar/Bar/BarView.swift): the bar's layout: measuring widgets, planning space and overflow.
- [WidgetView.swift](Sources/StableBar/Bar/WidgetView.swift): one widget on the bar, its clicks and its popup.
- [WorkspaceView.swift](Sources/StableBar/Workspaces/WorkspaceView.swift): workspaces, their app icons and the selection animation.
- [LayoutConfiguration.swift](Sources/StableBar/Configuration/LayoutConfiguration.swift): groups, priority overflow and notch-aware placement.
- [PopupConfiguration.swift](Sources/StableBar/Configuration/PopupConfiguration.swift): popup layout blocks.
- [PopupView.swift](Sources/StableBar/Popups/PopupView.swift): a popup's frame, background and pin controls.
- [PopupBlockView.swift](Sources/StableBar/Popups/PopupBlockView.swift): the blocks a popup draws and their script bindings.
- [WidgetPopup.swift](Sources/StableBar/Popups/WidgetPopup.swift): anchored panel, dismissal and screen placement.
- [StableBarApp.swift](Sources/StableBar/App/StableBarApp.swift): non-activating panels and application lifecycle.

There is no web view or custom drawing loop. Private macOS API, for hiding and revealing the macOS menu bar, reading Spaces and Lock Screen, is looked up at runtime in [PrivateAPI.swift](Sources/StableBar/System/PrivateAPI.swift), so a macOS without one of its calls only turns that feature off; [AGENTS.md](AGENTS.md#architecture-rules) says when another one is allowed. Styling and data updates are separate from window placement. Performance and long-term stability still need measurement with your actual widgets and displays.

## How we work

1. **Start from an issue** for every `fix`, `feat` or `perf` change, using the issue forms, and link it from the pull request. The [triage skill](#agent-skills) checks whether a report is already tracked, fixed or supported. Other changes, such as CI, tests or docs, can go straight to a pull request.
2. **Branch from `main` and open a pull request.** Nobody pushes to `main` directly. Fill in the template: the problem, the changes, how you tested them and how to merge, and end with the model and harness that did the work, or with "No agent". For visible changes, the screens bot posts before and after images ([Before and after screens](#before-and-after-screens)); upload a recording when motion matters, instead of committing it.
3. **Keep one problem per pull request.** Unrelated fixes and cleanups get their own.
4. **Wait for CI.** `Test` and `Commit messages` must pass. `Linked issue` and `Description` check the pull request itself and rerun when you edit its description: a `fix`, `feat` or `perf` pull request closes an issue ("Fixes #N" in the description), and Problem, Changes and Testing are filled in. Depending on what a pull request changes, `Build release`, `Docs images`, `Package`, `Draw screens` and `Draw website screens` run too ([Commits and releases](#commits-and-releases) lists when). Fix them before merging: the same failure on `main` stops the next beta. When screens changed, `Visual review` waits until a maintainer has looked at them and added the `visual-ok` label.
5. **Merge** with a merge commit or a rebase merge, so semantic-release sees each commit. Squash only when the title alone should reach the changelog. Pull requests merge through a merge queue, which runs `Test` and `Commit messages` again on top of `main` before the pull request lands.

Reviews are requested automatically from the people listed in [CODEOWNERS](.github/CODEOWNERS), but they are not required. Ask for one when a change is risky or outside your usual area.

[cubic](https://cubic.dev) also reviews every pull request once it is out of draft. [CodeRabbit](https://coderabbit.ai) reviews pull requests labeled `deep-review`: the label is added automatically when a pull request changes more than 400 lines or a file listed in [.github/deep-review-paths](.github/deep-review-paths), and you can add it yourself, or ask a maintainer to, when a change is risky. Fix each comment from either or reply why not, then resolve its thread: unresolved conversations block merging. Their rules come from [AGENTS.md](AGENTS.md), [cubic.yaml](cubic.yaml) and [.coderabbit.yaml](.coderabbit.yaml). CodeRabbit allows each pull request author only a few reviews per hour. When its limit holds a review back, the Deep review workflow asks it again every hour, so there's no need to ask with `@coderabbitai review`.

[DECISIONS.md](DECISIONS.md) lists the lasting decisions about releases, reviews and code. A pull request that sets a new rule or policy adds an entry there.

## Commits and releases

Pull requests run `swift test` on macOS and check that every commit message, and the pull request title, follows [Conventional Commits](https://www.conventionalcommits.org). Squash merges use the title as the commit message. The tests load every configuration, module and package in `examples`, and the **Test** job parses each script in `scripts` and `examples` with the shell its first line names. The **Test pull request checks** job runs `node --test` on the scripts in `.github/scripts`: the logic of `Linked issue`, `Description` and the [before and after screens](#before-and-after-screens).

A pull request that changes `Sources`, `Resources`, `Package.swift`, `Package.resolved`, `scripts` or the CI workflow also compiles the release and draws the [docs images](#docs-images), as `main` does. If it changes `Resources`, `scripts` or the workflow, the **Package** job builds the DMG as a beta would, ad-hoc signed because pull requests get no Developer ID, and checks its signature, version and starter configuration. **Draw screens** runs when the app, `scenes`, the `examples` scenes read or the comparison scripts change, and **Draw website screens** when `site` changes.

[semantic-release](https://github.com/semantic-release/semantic-release) reads the commits since the last stable release and decides the next version. Only `feat`, `fix`, `perf` and `refactor` commits that change app inputs (`Sources`, `Resources`, `Package.swift`, `Package.resolved` or `scripts`, except `scripts/set-site-version.sh`) count. Website, guide, CI and test files do not count, regardless of the commit type.

| Commit | Release |
| --- | --- |
| `fix:`, `perf:`, `refactor:` | Patch: 0.1.0 → 0.1.1 |
| `feat:` | Minor: 0.1.0 → 0.2.0 |
| An eligible app commit with `!` or a `BREAKING CHANGE:` footer | Major: 0.1.0 → 1.0.0 |
| `build:`, `chore:`, `ci:`, `docs:`, `style:`, `test:` | None |

Queued pushes skip builds when `main` has already moved on. GitHub runs only a few macOS jobs at once for the account, and `main`'s runs wait for a free Mac like pull requests' do. Tests and release compilation run in parallel, with separate Swift build caches for debug and release. Pull requests restore `main`'s release cache but don't save their own. Packaging uses the compiled binary from the same workflow run only after both jobs pass; signing, notarization and publication still happen in the release job.

Both release channels come from `main`:

- **Beta:** after the tests pass on `main`, CI builds `dist/StableBar.dmg` as the next version plus `-beta.<UTC timestamp>.<run number>`, such as `0.5.0-beta.20261020103000.114`, and publishes it as a GitHub prerelease. The timestamp uses `YYYYMMDDHHMMSS` so GitHub's alphabetical prerelease sorting keeps same-day betas in order when the run number gains a digit. A beta commits nothing. It requires a qualifying app change since the newest release, and skips an unchanged app. Older fixes already shipped in a beta cannot trigger another beta after maintenance changes. A pending feature or fix still gets its beta when a later docs commit lands; the version includes all qualifying changes since the last stable release.
- **Stable:** a maintainer starts it from **Actions → CI → Run workflow** on `main`. It releases the newest commit on `main`, and only once that commit has shipped as a beta, or `scripts/unchanged-app.sh` confirms its app inputs match a previous beta, so stable ships the app beta users have run. A maintenance commit that changes app inputs does not trigger a beta; stable must wait for the next qualifying app change and its beta. It sets `CFBundleShortVersionString` to the version and `CFBundleVersion` to the run number in [Resources/Info.plist](Resources/Info.plist) with `scripts/set-version.sh`, points the website's download buttons at the version's DMG with `scripts/set-site-version.sh`, adds its notes to `CHANGELOG.md`, commits all three with the [docs images](#docs-images) as `chore(release): <version>`, tags `v<version>` and publishes a GitHub release with the DMG. The release commit skips CI, so the job then starts the **Website** workflow, which deploys the new download once its DMG is public.

Before starting a stable release, measure the beta as [Performance](docs/performance.md) describes and update the numbers there if they changed, along with the version, the Mac and the conditions they were measured with.

To retry a missing beta, use **Actions → CI → Run workflow** on `main` and choose **beta** as the release channel. The default channel is **stable**.

A stable release pushes its commit and tag before it publishes the GitHub release and the update feed. If it fails after that, start a new stable release from **Run workflow** before anything else lands on `main`; **Re-run jobs** would check out the commit before the tag. When the newest commit already carries a stable tag, the run reuses that version's DMG, or builds it again if the release has none, publishes its GitHub release, deploys the website and adds the release to the update feed.

Both jobs use the CI run number, which only goes up, so a stable build always numbers higher than the betas before it. In-app updates compare that number to find the newest release.

Both jobs sign and notarize the app with a Developer ID when the repository has one, and only then add the release to the update feed, with an EdDSA signature as well. Without a Developer ID, builds are ad-hoc signed and `scripts/prepare-app-info.sh` leaves out their `SUFeedURL`. To set it up, add to the `release` environment, which only `main` can use:

- the `DEVELOPER_ID_CERTIFICATE` secret: the Developer ID Application certificate and its private key, exported as a `.p12` and base64-encoded, with its password in the `DEVELOPER_ID_CERTIFICATE_PASSWORD` secret;
- an App Store Connect API key for notarization: the `.p8` file's contents in the `NOTARY_API_KEY` secret, and its key ID and issuer ID in the `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER` variables;
- the `SPARKLE_ED_PRIVATE_KEY` secret: the private EdDSA key whose public key is `SUPublicEDKey` in [Resources/Info.plist](Resources/Info.plist);
- the `RELEASE_APP_PRIVATE_KEY` secret: the release app's private key, with its client ID in the `RELEASE_APP_CLIENT_ID` variable. A stable release uses the app to push to `main` and to the Homebrew tap.

`scripts/publish-appcast.sh` adds each signed release to `appcast.xml` in the `appcast` prerelease, the feed every release checks, with betas on Sparkle's `beta` channel. Each item carries its GitHub release notes, whose bullet points the update tile's popup lists, and a link to the release.

Sparkle installs an update when its EdDSA signature matches the running app's key or its Developer ID matches the running app's, so a release can change one of the two while the other still matches, never both at once. An app with the key refuses an update without an EdDSA signature, so `scripts/check-update-key.sh` signs the DMG before either job publishes it, and stops the release when the secret is missing or doesn't match `SUPublicEDKey`.

The private key was made with Sparkle's `generate_keys`, which `swift build` puts in `.build/artifacts/sparkle/Sparkle/bin`, and lives in the maintainer's login keychain. `generate_keys -p` prints its public key. To set the secret from the keychain:

```sh
dir=$(mktemp -d)
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x "$dir/key"
gh secret set SPARKLE_ED_PRIVATE_KEY --env release < "$dir/key"
rm -r "$dir"
```

Before deleting the exported file, keep a copy somewhere safe, such as a password manager: GitHub never shows a secret again. `generate_keys -f <file>` imports that copy into another Mac's keychain. If the key is lost or leaked, make a new one with `generate_keys --account <name>`, put its public key in `SUPublicEDKey`, set the secret to it with `generate_keys --account <name> -x`, and release: installed copies accept that release on its Developer ID and check the new key from then on. To sign with another Developer ID team, keep the key: installed copies accept that release on its EdDSA signature. A copy still on a release from before the key can check only the Developer ID, since Sparkle checks an update against the installed app, not against the release before it. So publish the new team's releases with `generate_appcast --minimum-update-version` set to the build number of the first release with the key: older copies skip them and first update to the old team's newest release.

A stable release then sets the version and SHA-256 of the `stablebar` cask in [stablebox/homebrew-tap](https://github.com/stablebox/homebrew-tap). It pushes with a token from the release app, limited to that repository's contents, so the app must stay installed on `stablebox` with access to `homebrew-tap`.

Release jobs set `STABLEBAR_RELEASE_BUILD=1` when packaging to preserve their stamped version and build number. Other app builds get Development metadata from the checkout's Git revision, including changes since its nearest release tag and a `-dirty` suffix for local changes. Without Git metadata, the version is `0.0.0-dev`. This changes only the built app's plist; the tracked release plist stays untouched.

## Docs images

`scripts/render-docs-images.sh` draws the images in `docs/images` from the app's own bar, popup and Settings views, with sample data, a fixed date (Thursday 22 October 2026, 09:41 UTC) and a local, empty Store index, and writes them as WebP. Like [scenes](#scenes), each is drawn once its views hold still, so two runs of one commit on one Mac draw the same pixels. It needs `cwebp`: `brew install webp`. The **Docs images** CI job draws them on every push to `main` and on pull requests that change the app, and a stable release commits them, so a change to the bar, popups or Settings doesn't need new images. To show something new, add a scene to [DocsImages.swift](Sources/StableBar/Rendering/DocsImages.swift).

## Scenes

A scene file in [scenes](scenes) describes one screen to draw: a configuration, inline or as a path such as `../Resources/config.json`, the package folders to install beside it, such as `../examples/packages/system-monitor`, the sample outputs, graph history, and AeroSpace workspaces or yabai spaces its widgets show, the `wallpaper` behind a bar, a popup or the previews of the bar in Settings and setup, and what to draw: the `bar`, the bar in edit mode (`editBar`), a widget's `popup`, a `settings` page, the `uninstall` sheet for a sample Mac, the `update` popup for a sample offer, a step of `setup`'s tour, or the `accessibilityGuide` panel shown over System Settings. A setup scene pins what setup reads from the Mac, such as the menu bar, the permissions and the battery, and the choices made before its step. Those choices show in the tour but not on the bar, since previewing them would start the commands of the widgets they add. [scene.schema.json](scene.schema.json) lists every key. Draw them with:

```sh
StableBar --render-scenes /tmp/scenes scenes
```

It writes `<name>-dark.png` and `<name>-light.png` for each scene, and `scenes.json` with each scene's images or the error that stopped it. It runs nothing (no command, provider, window manager or network request), and every clock shows Thursday 22 October 2026, 09:41 UTC, so two runs of one commit on one Mac draw the same pixels. Each image is drawn once its views hold still: three drawings in a row match, held for two seconds while a spinner shows, as when a page is loading. Each scene is drawn in a process of its own, as many at a time as the Mac has cores, up to six, so its images don't depend on the scenes drawn before it. Scroll bars always show, as on CI's Macs. Text about the Mac itself, such as a display's name or the window managers installed, still comes from the Mac that draws.

A change you can see extends the scene that shows its area, or adds one when none does. Scenes can be edited, merged or deleted. Keep the format additive: a build reports a scene it can't read as an error and draws the others. Name scene files with letters, digits, dots, dashes and underscores, so the screens bot can show them. Two names that differ only in case are the same name.

## Before and after screens

On a pull request, CI draws the screens twice, from the pull request and from its base, and a bot posts what changed.

- **Draw screens** draws the [docs images](#docs-images) and the [scenes](#scenes) when the app, the scenes, the examples they read or the comparison scripts change. It waits for **Test**, so a push whose tests fail draws nothing, and Visual review says so; rerunning the failed jobs draws the screens too. Both sides draw the pull request's scene files, each beside its own resources and examples, so a new scene shows how `main` draws it too. When the app didn't change, the pull request's app draws both sides. The base's side comes from **Draw main's screens**, which draws every push to `main` once, so the base draws only the scenes the pull request adds or edits. While `main`'s run of the base is still going, **Wait for main's screens** waits for its screens on Linux, for up to 40 minutes. When `main`'s CI didn't draw the base, as for a push that a newer one replaced, a release commit, or a run that ended without them, the base draws everything. The base draws with `main`'s release build of it when that run kept one, and compiles it otherwise.
- **Draw website screens** captures the five pages of `site` at desktop (1440×900) and phone (390×844) size, in light and dark mode, when the website changes. The capture answers requests from the folder and fetches nothing else, seeds `Math.random` and stops the page's clock at the scenes' date, so two captures of one commit match.

CI's Macs draw the same pixels for one commit, so the two sides needn't come from one machine. A pixel counts as changed when a color channel moves by more than 1 and a pixel next to it changed too. A screen whose height changed, such as a website page that grew, is compared from the top: its crop starts at the first change and runs across the full width. A crop shows at most 1,600 rows of a change, and the comment says so when it stops short; the approval still covers the whole image.

These jobs run the pull request's code with a read-only token. The **Screens** workflow runs from `main` when CI finishes, and when a pull request gets or loses `visual-ok`, changes its base, closes or reopens. Each time it reads where the pull request stands, one pull request at a time, so running it again only brings everything up to date. It reads what the jobs uploaded only as data, and:

- comments once on the pull request and rewrites that comment for each new CI run: a table of the changed screens, their before, after and difference images cropped to the change, the unchanged screens folded, and what couldn't be drawn;
- keeps the images as assets of a monthly prerelease, `pr-previews-YYYY-MM`, then `-2` and on when one is full, and deletes a head's images once a newer head replaces them. Closing a pull request without merging deletes all of its images; a merged one keeps its last;
- sets the **Visual review** status on the pull request's head.

| Visual review | When |
| --- | --- |
| Success: "No screens to compare." | The pull request changes neither the app nor the website. |
| Success: "N screens, none changed." | Nothing looks different. |
| Pending | Screens changed. A maintainer looks at them, then adds the `visual-ok` label. |
| Success: "M changed screens approved." | `visual-ok` was added after the comment began showing these screens. |
| Pending: "The base changed…" | The pull request's base changed since its screens were drawn. Push a commit to draw them again. |
| Pending: "… was cancelled…" | CI was cancelled before it drew the screens, as when a newer push replaced the run. The comment stays as it was until CI runs again. |
| Failure | Drawing failed; the comment says what. A `visual-ok` added while it showed the failure still approves it. |

`visual-ok` approves the screens the comment showed when the label was added, so reload the pull request first if a push just landed. Any maintainer can add it, the author too. A later run that shows the same screens against the same base keeps the approval. One that shows other screens, or other failures, takes the label off and the review goes back to pending: look again, and add it again. Removing the label also sends the review back to pending.

Pull requests from forks get the same comment and status: the drawing runs in the fork's pull request, and **Screens** finds the pull request by its branch and head. Two pull requests from one branch at one commit, open or closed, share CI runs the bot can't tell apart, so it compares no screens and fails the review: close the other one if it's open, then push a commit. The comparison runs in the pull request's own CI, so a pull request that changes the CI workflow or the drawing scripts decides what its comparison shows. **Screens** reads the pull request's changed files from GitHub, so screens they call for that weren't drawn fail the review, but review such a change itself before you trust its screens.

## When CI fails

- **A test that passes when it runs again.** Hundreds of tests share the main actor on a 3-core runner, so a test that bounds main-actor work with wall-clock time can run out. When up to five Swift Testing tests fail, **Test** runs them once more on their own: if they pass, the job passes with a **Flaky test** warning naming each one, and its summary lists them. Fix the wait in a pull request of its own, as [Writing tests](AGENTS.md#writing-tests) says. A test that fails again, an XCTest failure or more failures fail the job; rerun the failed jobs with `gh run rerun <run> --failed` once the whole run has finished. A failure that comes back on reruns is a real one, even when the test looks slow. Each run's `test-results` artifact lists every Swift Testing test with its time and failures, kept 30 days, so the same test failing across runs is easy to spot.
- **A crash that ends the test run** (`exited with unexpected signal code 6`). The log doesn't say where. After a local run, look for a `swiftpm-testing-helper` report in `~/Library/Logs/DiagnosticReports`: its crashing thread names the code. Then turn the crash into a test that fails every time.
- **A job that never ran, or a check that stays in progress.** "The job was not acquired by Runner", or a required check still in progress after its steps finished, needs a rerun, not a fix.
- **A failure only CI shows.** CI's Macs always show scroll bars: run the test with `-AppleShowScrollBars Always`. Locally, the popup tests that animate fail while the display sleeps or the screen is locked.
- **Tests that don't match the branch.** `swift build` doesn't rebuild the tests: after switching branches, run `swift build --build-tests` before `swift test --skip-build`.

## Agent skills

Skills for coding agents live in [.agents/skills](.agents/skills), one folder per skill with a `SKILL.md`. Codex reads that directory, and `.claude/skills` links to it for Claude Code. Invoke a skill by name (`/triage` in Claude Code, `$triage` in Codex) or describe the task and let the agent choose it.

| Skill | Use |
| --- | --- |
| [triage](.agents/skills/triage/SKILL.md) | Checks a bug report or feature request against issues, pull requests, `main` and releases, and drafts a GitHub issue when nothing covers it. It posts only what you asked it to file or approved. |

To add a skill, create `.agents/skills/<name>/SKILL.md` with `name` and `description` front matter.

## Security

Report vulnerabilities privately, as described in [SECURITY.md](.github/SECURITY.md).
