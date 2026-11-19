# Decisions

Lasting decisions about how StableBar is built, reviewed and shipped, so they don't get argued again or lost in a closed pull request. Each says what was decided, why, and where. Product choices, such as a feature that was declined, stay in their issues, where the [triage skill](.agents/skills/triage/SKILL.md) finds them.

Add an entry when a pull request sets a rule, a policy or a choice not to do something. Changing or removing one is the maintainers' call.

## Releases

- **Betas from `main`, stable by hand** (2026-10-16, [#3], [#23]). A push to `main` publishes a beta when the app changed since the newest release and a `feat`, `fix`, `perf` or `refactor` commit changed it, and a maintainer promotes a beta to stable, so stable ships what beta users ran. There is no develop branch. Pushes that change only docs, CI or tests don't ship the same app again ([#309]).
- **Merge commits by default** ([CONTRIBUTING](CONTRIBUTING.md#how-we-work)). semantic-release reads each commit that reaches `main`: a merge commit leaves it every commit to read, and a squash leaves one, for when a single commit should stand for the pull request. [Commits and releases](CONTRIBUTING.md#commits-and-releases) says which commits make a release and reach the changelog.
- **An issue for every `fix`, `feat` or `perf`** (2026-10-31, [#390]). The issue holds the problem and the decision; the `Linked issue` check enforces it. Other types can skip it.
- **Updates carry an EdDSA signature as well as the Developer ID** (2026-11-10, [#335]). Sparkle checks both, so the signing team or the key can change in a release while the other still matches. This replaces [#100]'s choice of the Developer ID alone. The feed isn't published without the `SPARKLE_ED_PRIVATE_KEY` secret, and [CONTRIBUTING](CONTRIBUTING.md#commits-and-releases) says how to back up and change the key.

## Reviews and checks

- **cubic reviews every pull request, CodeRabbit the risky ones** (2026-11-17, [#772], [#773]). CodeRabbit's free plan allows each author two reviews an hour, so pull requests opened together went unreviewed. cubic is free for public repositories and resolves its own threads. CodeRabbit, which had reviewed every pull request since 2026-10-31 ([#391]), now reviews those labeled `deep-review`: more than 400 changed lines, a file in `.github/deep-review-paths`, or added by hand. A workflow asks it again every hour when its limit held a review back. No paid review tools or API keys.
- **No auto-merge** (2026-10-31). The rules need no approval, but a maintainer merges; nothing merges itself.
- **A person approves changed screens** (2026-10-31, [#395], [#397]). CI draws before/after screens, and any maintainer, the author too, adds `visual-ok` after looking. A visible change also shows screenshots in its pull request description (2026-11-08, [#484]).
- **Pull requests compare with `main`'s own screens** (2026-11-17). Each push to `main` draws its screens once, and a pull request uses those of its base, drawing from the base only the scenes it adds or edits, instead of drawing the whole base again in every run. Docs images drawn from one commit on different CI Macs, and on two runner images, matched byte for byte. A cancelled draw leaves Visual review pending, not failed. A pull request waits on Linux for `main`'s screens of its base while `main`'s run is drawing them, rather than drawing the base again on a Mac. When the base still has scenes to draw and the app changed, it uses `main`'s release build of the base if that run kept one, and compiles the base otherwise.
- **`main`'s CI doesn't preempt pull requests** (2026-11-17). From 2026-11-16, a run on `main` cancelled the pull request runs it found and restarted their cancelled jobs once its own were done. Main stopped waiting, but in its first day this threw away about 1,600 macOS minutes of cut-off jobs, showed pull requests as failed until the restart, and reran them against the `main` from before the merge. Before it, only one run on `main` had waited long for a Mac (88 minutes). Pull requests now spend fewer macOS minutes instead; if `main` waits again, the answer is a merge queue or more runners, not cancelling pull requests.
- **CI builds with one pinned Xcode** (2026-11-08, [#479]). A runner image update can't change the toolchain under a pull request; moving to a newer Xcode is a pull request of its own.
- **Commit messages are checked before they leave the Mac** (2026-11-08, [#485]). Git hooks check them in every tool, and Claude Code also builds when an agent stops. `STABLEBAR_SKIP_HOOKS=1` turns the hooks off for one person.
- **A flaky test doesn't block a pull request** (2026-11-17). When up to five Swift Testing tests fail, the Test job runs them once more on their own and passes with a warning naming those that pass then. They still get fixed, in a pull request of their own. A test that fails twice, an XCTest failure, a crash, a hang or more failures fail the job.

## Code

- **Sliders may take a role implicitly** (2026-11-17). Sliders with neither `filled` nor another role follow a nonempty `slider` role, so themes can style controls without owning widget layouts. Explicit `filled` choices retain their behavior, and an empty role retains the native control. Other blocks still require explicit roles.
- **Window managers own their gaps** (2026-11-13). StableBar does not turn macOS menu-bar auto-hide off to reserve space: that changes the usable screen area underneath existing window-manager gaps, and the reserved height does not follow StableBar’s height. Keep windows clear remains a correction for ordinary windows after a drag.
- **`BarStore` only wires one bar together** (2026-11-19). It had grown to 74 stored properties and 1,400 lines. Its concerns moved, unchanged, into types of their own: `ConfigurationStore` (files, edits, reload, migrations, theme trials), `WidgetScripts` (scripts, providers, events, click actions, suspension), `BarPresentation` (resolved styles), `AppWatcher` (front app and menu bar owner) and the runtime commands; the sources are grouped in folders by area. Every scene and docs image drew the same pixels before and after, and the command line printed the same. It was a restructuring, not a rewrite: existing state still moves into a `StateMachine` when a bug in it is fixed.
- **Architecture rules are tests** (2026-11-08, [#484]). `ArchitectureRulesTests` caps `BarStore`'s stored state, a number that only goes down, allows no `unowned` reference ([#493]), keeps private macOS API in `PrivateAPI.swift` ([#490]) and keeps state machines free of UI frameworks, tasks, the clock and the system.
- **Decisions about state are state machines, in plain Swift** (2026-11-17). A feature's state is one enum with a pure `handle(event)` that returns an effect for its owner to perform, so every transition has a unit test and no combination of flags can contradict another. A trial on `WidgetPopup`'s hover and click state with The Composable Architecture took 14 more packages and a 37% slower clean build, and its store refuses an action sent while it handles another, which AppKit callbacks do. The same reducer in plain Swift was as easy to test. `SetupPlacement` is the first: setup's placement choice had three fields and a counter checked in three places to drop stale answers. Existing state moves over when a bug in it is fixed, not in a rewrite.
- **Private macOS API is a maintainer's call** (2026-11-08, [#484], [#490]). Every call lives in `PrivateAPI.swift` and is looked up at runtime, never with `@_silgen_name`, so a macOS without one turns off only its feature.
- **The configuration file is public API** (2026-10-26, [#337]). People's files, Store packages and themes depend on it, so changes are additive. Renaming or removing a property, or changing what it means, needs a migration, a test that loads the old form and a maintainer's OK. StableBar 0.9.0 and later, and betas built after [#337], skip the properties they don't know, with a warning, once the configuration says a newer release wrote it. Earlier versions stop at the first one. The [guide](docs/configuration.md#files-from-a-newer-stablebar) has the exact rules. Migrations of an old form run in memory on every file the loader reads, so includes and packages stay as they are, and are saved into the main file and screen setups' own bars at launch. A migration of values people can still choose skips files pinned to a release ([#223]).
- **Theme links carry only a theme** (2026-11-16, [#676]). A
  `stablebar://theme?v=1&package=…&config=…` link carries only `package.json` and `config.json`: at
  most 64 KB for the URL, 32 KB for the two decoded files together, 32 levels of JSON nesting, 16
  profiles and 372 JSON values across both files. Reference expansion shares a budget of 300,000
  units and 8,000,000 bytes of reference origin paths; a link exceeding either is refused as too
  many references. Theme configuration keys are `tokens`,
  `defaults`, `popupDefaults`, `groupDefaults`, `roles`, `workspaceDefaults`, `bar`, `groups` and `profiles`. Other
  keys are refused, including legacy `customization` and `removedWidgets`; an empty `widgets` list
  is ignored. Screenshots, includes and extra files are refused. At the root and in every profile,
  `bar` must be a literal object with only `height`, `margin`, `inset`, `spacing`, `background`,
  `style`, `notchWidth`, `notchSpacing`, `fillNotch`, `popupOffset` and `glass`. Inside `bar`,
  numbers must be literal; colors may use tokens or settings with `choices`. Free-text string settings under
  `bar` are refused, and references cannot supply the `bar` object or its keys. This keeps links
  from changing the bar's edge, its offset or the menu bar's auto-hide. Current and legacy bundled
  theme IDs are reserved, and a non-theme package's ID cannot be reused. An installed ID and
  version are reused only when both files match byte for byte; otherwise the author raises the
  version on the page. The app never renumbers a theme.
- **Theme links bound bar values** (2026-11-16, [#676]). Every numeric value under `bar`, including
  nested styles, states, gradients and every profile, must be a finite JSON number literal.
  References that can supply numbers through tokens, combined profiles or setting choices are
  refused. Bounds use the full property path: `bar.height` 16…100, `bar.inset` 0…100, `bar.spacing`
  0…50, `bar.margin` 0…40 and `bar.popupOffset` 0…40 (its pending control in [#664]). Within
  `bar.style` and its states, border width uses 0…6, corner radius 0…40, font size 6…40,
  horizontal/vertical padding 0…40 and opacity 0…1. `bar.glass.transparency` uses 0…1.
  Gradients in `bar.background` and style backgrounds use locations 0…1 and angle 0…360. These bounds follow Settings controls. With no
  Settings controls, `bar.notchWidth` uses 0…1,000, `bar.notchSpacing` 0…100 and style offsets
  −1,000…1,000. All remaining numeric values use 0…1,000, including style height, spacing and edge
  padding. These refusals apply to links; folder themes keep the ordinary configuration rules.
- **Bar links carry only built-in and Store widgets** (2026-11-18, [#807]). A
  `stablebar://bar?v=1&d=…` link carries what a bar shows on one display, resolved: its look and
  widgets with the active profiles applied, without profiles, screen layouts or `display`. `d` is
  the JSON payload, compressed with zlib's raw DEFLATE and base64url-encoded. The app shares
  `https://stablebar.app/bar.html#v=1&d=…`, a page that opens the link, since social sites don't
  open `stablebar://` links; the fragment never reaches a server. The look is an inline theme,
  `package.json` and `config.json`, under every theme link rule and limit above, made the way
  **Save as Theme…** merges the main file's look into the current theme. It keeps only the
  theme's tokens and those the look refers to, as a token can hold a provider's header. Its ID is
  `shared-` and 8 hex digits of a hash of its files, its name the theme's with "(shared)". A
  built-in widget keeps only `id`, `type`, `role`, `position`, `icon`, `tooltip`, `style`,
  `format`, `text`, `layout`, `hoverLayout`, `overlay`, `popup`, `animation`, `workspace`,
  `group`, `priority`, `overflow`, `transition`, `expandOnHover`, `openOnHover`, `shown`,
  `hidden`, `details`, `hideWhenIdle`, `timeZone`, `background`, `popupBackground` and
  `tooltipBackground`. Its popup loses `onOpen` and `onClose`, and its blocks lose every block
  that runs, opens or changes something (`onClick`, `onClickField`, `open`, `openField`,
  `quitField`, `openMenuBarItem`, `selectInputSourceField`, `selectOutputDeviceField`,
  `onChange`, `onSubmit`, `onStop`, `onStar`, `set`), every `image` block and every list whose
  row is one of those. Script and custom provider widgets, widgets from folders or private
  sources, includes, templates, `environment` and `packageSources` stay behind. A Store package
  carries its ID, version, its widgets' positions and own `group`s, and its number, boolean and
  choice settings; secret and free-text settings keep the package's defaults. The recipient
  applies the same filters, installs packages from the Store, through its review when they need
  one, gets the version the Store lists (the link's while it's the newest), and leaves out
  packages the Store doesn't list. A Store version already on the recipient's bar skips the
  review and keeps its settings, with the link's over them. Without the link's look,
  a widget keeps its `group` only when the bar already has that group. Each group a widget keeps
  gets an empty entry in the main file's `groups`, so the widgets stay valid under another theme. **Use this bar**
  replaces the main file's widgets, packages, widget overrides and order, screen layouts and the
  widget changes in its profiles, and with **Every screen** the look that Save as Theme would
  move, in one undoable change; widgets that included files add stay. When the link centers
  widgets and the Mac has a notched display under a top bar, **Try on Bar** and **Use this bar**
  also write a `screens.laptop.layout` that puts them left of the notch: the bar puts them right
  of it with the right-hand ones, where a bar made on a wide monitor doesn't fit. Other screens
  keep them centered. Limits: 64 KB for the URL,
  128 KB for the decoded payload, 32 levels of JSON nesting and 4,096 JSON values. Theme links
  don't change.
- **A native provider may read a macOS tool's output** (2026-11-16, [#220]). When no public API gives the data and the tool needs no permission, a native provider can run a macOS command-line tool, off the main actor and without a shell: `bluetooth` reads every connected device's battery from `system_profiler`. Apple doesn't document the tool's output keys, so a missing or renamed key leaves that value empty instead of failing the provider.
- **A package can't move another party's credentials** (2026-11-17, [#85], [#744]). A package may set the `url` of a provider, directly or in a profile, only when no file or profile gives that provider a token other than one of that package's own secrets, and no other file sets its `headers`. A package without commands can reach the Store after CI alone, so it must not point your token, a header you typed or another package's secret at its own host. In its own files, a package writes out each provider's `url` and `headers`, without `@token.` references, so StableBar needn't follow tokens to see where a request goes or what it sends. The check doesn't work out which profiles can be active together, so it can refuse an unusual but harmless setup. URLs and headers set in your own files stay free, `@token.` references included.
- **Tests keep their own time** (2026-11-08, [#491]). Code whose tests depend on time takes a clock, and the test clock lives in the repository rather than in a new dependency.
- **Blocking work stays off Swift's shared pool** (2026-11-13, [#618]). The pool has one thread per core, three on CI, and never replaces a blocked one. A slow copy or a lookup that can stall runs through `BlockingWork.run` on a GCD queue, and tests that block such work check that it does. [AGENTS.md](AGENTS.md#writing-tests) has the rule for tests.
- **Comments are for the next reader** (2026-11-10, [#533]). A comment says what the code can't, such as why it must be so, in a line or two. How the bug was found and fixed goes in the issue, the pull request and the commit message. [AGENTS.md](AGENTS.md#writing-comments) has the rule.

[#3]: https://github.com/stablebox/StableBar/issues/3
[#23]: https://github.com/stablebox/StableBar/pull/23
[#85]: https://github.com/stablebox/StableBar/issues/85
[#100]: https://github.com/stablebox/StableBar/pull/100
[#220]: https://github.com/stablebox/StableBar/issues/220
[#223]: https://github.com/stablebox/StableBar/issues/223
[#309]: https://github.com/stablebox/StableBar/pull/309
[#335]: https://github.com/stablebox/StableBar/issues/335
[#337]: https://github.com/stablebox/StableBar/pull/337
[#390]: https://github.com/stablebox/StableBar/pull/390
[#391]: https://github.com/stablebox/StableBar/pull/391
[#395]: https://github.com/stablebox/StableBar/pull/395
[#397]: https://github.com/stablebox/StableBar/pull/397
[#479]: https://github.com/stablebox/StableBar/pull/479
[#484]: https://github.com/stablebox/StableBar/pull/484
[#485]: https://github.com/stablebox/StableBar/pull/485
[#490]: https://github.com/stablebox/StableBar/pull/490
[#491]: https://github.com/stablebox/StableBar/pull/491
[#493]: https://github.com/stablebox/StableBar/pull/493
[#533]: https://github.com/stablebox/StableBar/pull/533
[#618]: https://github.com/stablebox/StableBar/issues/618
[#664]: https://github.com/stablebox/StableBar/issues/664
[#676]: https://github.com/stablebox/StableBar/issues/676
[#744]: https://github.com/stablebox/StableBar/pull/744
[#772]: https://github.com/stablebox/StableBar/issues/772
[#773]: https://github.com/stablebox/StableBar/pull/773
[#807]: https://github.com/stablebox/StableBar/issues/807
