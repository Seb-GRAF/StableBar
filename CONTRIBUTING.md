# Contributing

## Setup

StableBar needs macOS 14 or later and Xcode's Swift 6 toolchain. [Build and run](README.md#build-and-run) covers building the app. For development:

```sh
swift build
swift test
```

Node.js runs only the release tooling and the commit message check. `npm ci` installs them, and `npx commitlint --from origin/main` checks your commits before you push.

[t3.json](t3.json) defines project scripts: it builds each new worktree in the background and adds **Test** and **Build app**. Coding agents read [AGENTS.md](AGENTS.md); `CLAUDE.md` points Claude Code to it.

## How we work

1. **Start from an issue** for bugs and features, using the issue forms. The [triage skill](#agent-skills) checks whether a report is already tracked, fixed or supported. A small, obvious fix can go straight to a pull request.
2. **Branch from `main` and open a pull request.** Nobody pushes to `main` directly. Fill in the template: the problem, the changes, how you tested them and how to merge. Upload screenshots of visible changes to the pull request instead of committing them.
3. **Keep one problem per pull request.** Unrelated fixes and cleanups get their own.
4. **Wait for CI.** `Test` and `Commit messages` must pass.
5. **Merge** with a merge commit or a rebase merge, so semantic-release sees each commit. Squash only when the title alone should reach the changelog.

Reviews are requested automatically from the people listed in [CODEOWNERS](.github/CODEOWNERS), but they are not required. Ask for one when a change is risky or outside your usual area.

## Commits and releases

Pull requests run `swift test` on macOS and check that every commit message, and the pull request title, follows [Conventional Commits](https://www.conventionalcommits.org). Squash merges use the title as the commit message.

[semantic-release](https://github.com/semantic-release/semantic-release) reads the commits since the last stable release and decides the next version:

| Commit | Release |
| --- | --- |
| `fix:`, `perf:` | Patch: 0.1.0 → 0.1.1 |
| `feat:` | Minor: 0.1.0 → 0.2.0 |
| `feat!:`, or a `BREAKING CHANGE:` footer | Major: 0.1.0 → 1.0.0 |
| `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, `test:` | None |

Both release channels come from `main`:

- **Beta:** after the tests pass on `main`, CI builds `dist/StableBar.dmg` as the next version plus `-beta.<run number>`, such as `0.5.0-beta.42`, and publishes it as a GitHub prerelease. A beta commits nothing. A push with no releasable commits since the last stable release makes no beta.
- **Stable:** a maintainer starts it from **Actions → CI → Run workflow** on `main`. It releases the newest commit on `main`, and only once that commit has shipped as a beta, so stable ships what beta users have run. It sets `CFBundleShortVersionString` to the version and `CFBundleVersion` to the run number in [Resources/Info.plist](Resources/Info.plist) with `scripts/set-version.sh`, adds its notes to `CHANGELOG.md`, commits both as `chore(release): <version>`, tags `v<version>` and publishes a GitHub release with the DMG.

Both jobs use the CI run number, which only goes up, so a stable build always numbers higher than the betas before it. In-app updates compare that number to find the newest release.

Both jobs sign and notarize the app with a Developer ID when the repository has one, and only then add the release to the update feed: Sparkle installs an update only when it's signed by the same developer as the running app. Without one, builds are ad-hoc signed and `scripts/prepare-app-info.sh` leaves out their `SUFeedURL`. To set it up, add:

- the `DEVELOPER_ID_CERTIFICATE` secret: the Developer ID Application certificate and its private key, exported as a `.p12` and base64-encoded, with its password in the `DEVELOPER_ID_CERTIFICATE_PASSWORD` secret;
- an App Store Connect API key for notarization: the `.p8` file's contents in the `NOTARY_API_KEY` secret, and its key ID and issuer ID in the `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER` variables.

`scripts/publish-appcast.sh` adds each signed release to `appcast.xml` in the `appcast` prerelease, the feed every release checks, with betas on Sparkle's `beta` channel. Each item carries its GitHub release notes, whose bullet points the update tile's popup lists, and a link to the release.

Release jobs set `STABLEBAR_RELEASE_BUILD=1` when packaging to preserve their stamped version and build number. Other app builds get Development metadata from the checkout's Git revision, including changes since its nearest release tag and a `-dirty` suffix for local changes. Without Git metadata, the version is `0.0.0-dev`. This changes only the built app's plist; the tracked release plist stays untouched.

## Agent skills

Skills for coding agents live in [.agents/skills](.agents/skills), one folder per skill with a `SKILL.md`. Codex reads that directory, and `.claude/skills` links to it for Claude Code. Invoke a skill by name (`/triage` in Claude Code, `$triage` in Codex) or describe the task and let the agent choose it.

| Skill | Use |
| --- | --- |
| [triage](.agents/skills/triage/SKILL.md) | Checks a bug report or feature request against issues, pull requests, `main` and releases, and drafts a GitHub issue when nothing covers it. It posts only what you asked it to file or approved. |

To add a skill, create `.agents/skills/<name>/SKILL.md` with `name` and `description` front matter.

## Security

Report vulnerabilities privately, as described in [SECURITY.md](.github/SECURITY.md).
