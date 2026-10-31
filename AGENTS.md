# StableBar

StableBar is a native macOS bar built with Swift, AppKit and SwiftUI as a Swift package (macOS 14+, Swift 6). It reads a JSON configuration, by default `~/.config/stablebar/config.json`, and is controlled from its menu-bar icon, the Settings window and the `StableBar` command line. In code, the Settings window is still called Customize (`CustomizationWindow`, `--customize`). The [user guide](docs/README.md) in `docs/` is the user manual, and the [README](README.md) is the project's front page; [CONTRIBUTING.md](CONTRIBUTING.md) covers building, the pull request flow and releases.

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
3. **Release files.** semantic-release writes `CHANGELOG.md`, the versions in `Resources/Info.plist` and the website's download version in `site/index.html`. Don't edit them or bump versions by hand.

## Build and verify

- `swift build` builds the package; `./scripts/build.sh` builds `dist/StableBar.app`.
- Run the tests for what you changed with `swift test --filter <name>`. CI runs the whole suite on macOS for every pull request.
- `node --test .github/scripts/*.test.mjs` tests the pull request checks in `.github/scripts`.
- `StableBar --validate PATH` checks a configuration without starting its scripts.
- Visible changes (the bar, popups, setup, Settings, the website) need before/after images in the pull request, and CI draws them: the screens bot comments with the docs images, the scenes in `scenes/` and the website's pages, drawn from `main` and from your branch (see [Before and after screens](CONTRIBUTING.md#before-and-after-screens)). When no screen shows your change, add or extend a scene so the bot draws it, instead of uploading screenshots. To look before pushing, `StableBar --render-scenes DIR scenes` draws the scenes offscreen from a build, running nothing. Ask before launching the app or taking screenshots of it: a second bar appears on the developer's screen. Add a recording when motion matters.

## Hit every surface

A configuration change rarely lives in one place. Before calling one done, say which of these applied:

- **Decoding.** Unknown properties are errors, so a new property needs a coding key and an entry in [stablebar.schema.json](stablebar.schema.json). `schemaListsTheSamePropertiesAsTheDecoders` fails when they differ.
- **Layers.** Values can come from includes, templates, profiles and package overrides, not only the main file.
- **Editing.** The Appearance, Your bar and Profiles sections in Settings, and the command-line edits, which share `ConfigurationEdits.swift`.
- **Docs.** The page in [docs](docs) that documents the feature, and the setups in [examples](examples).

## Pull requests

- Never push to `main`. Open a pull request only when the developer asks for one.
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
