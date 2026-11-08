# StableBar

StableBar is a native macOS bar built with Swift, AppKit and SwiftUI as a Swift package (macOS 14+, Swift 6). It reads a JSON configuration, by default `~/.config/stablebar/config.json`, and is controlled from its menu-bar icon, the Settings window and the `StableBar` command line. In code, the Settings window is still called Customize (`CustomizationWindow`, `--customize`). The [user guide](docs/README.md) in `docs/` is the user manual, and the [README](README.md) is the project's front page; [CONTRIBUTING.md](CONTRIBUTING.md) covers building, the pull request flow, releases and [what to do when CI fails](CONTRIBUTING.md#when-ci-fails).

## Protect the developer's setup

The developer's own StableBar is usually running while you work.

1. **Their configuration.** Without `--config`, a dev build loads and edits `~/.config/stablebar/config.json`, and commands such as `--set`, `--add` or `--batch` change the bar that is running; `--persist` writes the file. `--reload` and `--trigger` without `--config` reach every running bar. Give the app and every command a scratch file instead. The app creates it from the starter configuration:

   ```sh
   scratch=$(mktemp -d)
   dist/StableBar.app/Contents/MacOS/StableBar --config "$scratch/config.json" &
   pid=$!
   dist/StableBar.app/Contents/MacOS/StableBar --config "$scratch/config.json" --query
   ```

2. **Their running bar.** Never `killall StableBar`, `pkill`, or kill a PID found by name: the developer's bar has the same name. Stop only a process you started, by the PID you captured.
3. **Release files.** semantic-release writes `CHANGELOG.md`, the version and build number in `Resources/Info.plist`, and the download links and version in `site/index.html`. Don't edit those or bump versions by hand; the rest of `Info.plist` and `site/index.html` is ordinary code.

## Build and verify

`swift build` builds the package; `./scripts/build.sh` builds `dist/StableBar.app`. Before opening a pull request, run what CI checks for the files you changed, or `scripts/check.sh`, which runs all of it:

1. `swift build --build-tests`, also after switching branches: `swift test --skip-build` runs whatever test binary the last build left.
2. `swift test --filter <name>` for what you changed. CI runs the whole suite on macOS for every pull request.
3. `node --test .github/scripts/*.test.mjs` when `.github/scripts` changed.
4. `StableBar --validate PATH` for each configuration or example you changed; it doesn't start their scripts.
5. `npx commitlint --from origin/main` (after `npm ci`) on your commits, bodies included: every line at most 100 characters.

The git hooks in `.githooks` check each commit message as it's written and again before a push, in any tool. If `git config core.hooksPath` isn't `.githooks`, run `scripts/check.sh --install-hooks` once, and never skip the hooks with `--no-verify`. Before you finish, run `scripts/check.sh --quick`; in Claude Code a project hook runs it when you stop.

Visible changes (the bar, popups, setup, Settings, the website) need before/after images in the pull request. CI draws them: the screens bot comments with the docs images, the scenes in `scenes/` and the website's pages, drawn from `main` and from your branch (see [Before and after screens](CONTRIBUTING.md#before-and-after-screens)). When no screen shows your change, add or extend a scene so the bot draws it. Also put screenshots of the change in the description when you open the pull request, before and after where you can; the bot's comment comes on top. To look before pushing, `StableBar --render-scenes DIR scenes` draws the scenes offscreen from a build, running nothing. Ask before launching the app or taking screenshots of it: a second bar appears on the developer's screen. Add a recording when motion matters.

## Writing tests

- New tests use Swift Testing; existing XCTest files can stay as they are.
- Most tests run on the main actor, in parallel, on a busy CI runner. Never bound main-actor work with wall-clock time (short sleeps, deadline loops, short timeouts): wait by counting polls, as `awaitCondition` does. A sleep that only checks that nothing happens is fine.
- A fixture that runs git, or a script that runs git, needs a timeout of 60 seconds or more.
- CI's Macs always show scroll bars (17 points); run a layout test with `-AppleShowScrollBars Always` to see what CI sees.
- A purely visual fix is proven with before/after images, not with a UI test.

## Architecture rules

`ArchitectureRulesTests` checks the first three; its numbers may only go down.

- Don't add stored properties to `BarStore`. New state goes into a type of its own, owned by `BarStore` or by the feature that needs it.
- A helper that points back at `BarStore`, or at another owner, holds it `weak`: a view or a task can keep the helper alive after its owner is gone. Don't add `unowned`.
- Private macOS API lives in `PrivateAPI.swift`, looked up at runtime: on a macOS without one of its calls, the call is nil and its feature turns off instead of crashing. Never use `@_silgen_name`, which binds at launch, and never force-unwrap a lookup. A new call needs a maintainer's OK.
- The configuration file is StableBar's public API: people's files, Store packages and themes depend on it. Keep changes additive. Renaming or removing a property, or changing what it means, needs a migration, a test that loads the old form and a maintainer's OK. An older build skips the properties of a file saved by a newer release, with a warning; keep that working.

## Decide or ask

Decide on your own: refactors that change no behavior, fixes within an issue's scope, tests, and docs for what the code already does.

Ask a maintainer before changing the configuration format, adding a permission or an entitlement, calling private API, adding a dependency, or changing CI, signing or releases. When a choice is a matter of taste, such as a layout or the words on a screen, show two or three options as renders and let the maintainer pick.

## Hit every surface

A configuration change rarely lives in one place. Before calling one done, say which of these applied:

- **Decoding.** Unknown properties are errors, so a new property needs a coding key and an entry in [stablebar.schema.json](stablebar.schema.json). `schemaListsTheSamePropertiesAsTheDecoders` fails when they differ.
- **Layers.** Values can come from includes, templates, profiles and package overrides, not only the main file.
- **Editing.** The Appearance, Your bar and Profiles sections in Settings, and the command-line edits, which share `ConfigurationEdits.swift`.
- **Docs.** The page in [docs](docs) that documents the feature, and the setups in [examples](examples).

## Pull requests

- Never push to `main`. Open a pull request only when the developer asks for one.
- Before starting, look at the open pull requests that touch the files you'll change (`gh pr list`, `gh pr diff <number> --name-only`): build on them or coordinate, rather than collide.
- A `fix`, `feat` or `perf` pull request needs an issue. Before opening it, search with the `triage` skill. If an open issue covers the problem, link it. If none does, file one with `triage` (the request for the pull request covers filing it) and link that. If triage finds the problem already fixed or declined, tell the developer before going on. Other types, such as `ci`, `test`, `docs` or `chore`, can skip the issue.
- Titles follow Conventional Commits in plain words, such as `fix: keep the clock visible on a notched display`. Every commit message is checked too, and the types of the commits that reach `main` decide the next release (see [Commits and releases](CONTRIBUTING.md#commits-and-releases)).
- Fill in the [pull request template](.github/pull_request_template.md), and end the description with the model and harness that did the work. The `Description` check fails without that line, and `Linked issue` fails a `fix`, `feat` or `perf` pull request that closes no issue.
- CodeRabbit reviews every pull request. Answer each of its comments by fixing the code or replying why not, then resolve the thread: unresolved threads block merging.
- Upload screenshots and recordings to the pull request; never commit them. The images in `docs/images` are the exception: they illustrate the README and the guide, and CI draws them (see [Docs images](CONTRIBUTING.md#docs-images)).
- Keep to one problem per pull request.

## Documentation and work artifacts

- The guide in `docs/` is the user manual, and the triage skill relies on it to tell whether something is already supported. When you change how a feature behaves, update its section. Keep the README short: it introduces StableBar and links to the guide. Don't add notes that the code already answers.
- Don't commit plans, specs, research notes or scratch files, even when a skill suggests it. Keep them outside the repository; the issue or pull request is the record.

## Skills

Project skills live in [.agents/skills](.agents/skills), and `.claude/skills` links to it. `triage` checks a report against issues, pull requests, `main` and releases before anything is filed.
