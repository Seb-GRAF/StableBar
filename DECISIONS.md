# Decisions

Lasting decisions about how StableBar is built, reviewed and shipped, so they don't get argued again or lost in a closed pull request. Each says what was decided, why, and where. Product choices, such as a feature that was declined, stay in their issues, where the [triage skill](.agents/skills/triage/SKILL.md) finds them.

Add an entry when a pull request sets a rule, a policy or a choice not to do something. Changing or removing one is the maintainers' call.

## Releases

- **Betas from `main`, stable by hand** (2026-10-16, [#3], [#23]). A push to `main` publishes a beta when the app changed since the newest release and a `feat`, `fix`, `perf` or `refactor` commit changed it, and a maintainer promotes a beta to stable, so stable ships what beta users ran. There is no develop branch. Pushes that change only docs, CI or tests don't ship the same app again ([#309]).
- **Merge commits by default** ([CONTRIBUTING](CONTRIBUTING.md#how-we-work)). semantic-release reads each commit that reaches `main`: a merge commit leaves it every commit to read, and a squash leaves one, for when a single commit should stand for the pull request. [Commits and releases](CONTRIBUTING.md#commits-and-releases) says which commits make a release and reach the changelog.
- **An issue for every `fix`, `feat` or `perf`** (2026-10-31, [#390]). The issue holds the problem and the decision; the `Linked issue` check enforces it. Other types can skip it.
- **Updates carry an EdDSA signature as well as the Developer ID** (2026-11-10, [#335]). Sparkle checks both, so the signing team or the key can change in a release while the other still matches. This replaces [#100]'s choice of the Developer ID alone. The feed isn't published without the `SPARKLE_ED_PRIVATE_KEY` secret, and [CONTRIBUTING](CONTRIBUTING.md#commits-and-releases) says how to back up and change the key.

## Reviews and checks

- **CodeRabbit reviews every pull request** (2026-10-31, [#391]). It's free for open source, its quiet profile posts only what matters, and it reviews every push. No paid review tools or API keys.
- **No auto-merge** (2026-10-31). The rules need no approval, but a maintainer merges; nothing merges itself.
- **A person approves changed screens** (2026-10-31, [#395], [#397]). CI draws before/after screens, and any maintainer, the author too, adds `visual-ok` after looking. A visible change also shows screenshots in its pull request description (2026-11-08, [#484]).
- **CI builds with one pinned Xcode** (2026-11-08, [#479]). A runner image update can't change the toolchain under a pull request; moving to a newer Xcode is a pull request of its own.
- **Commit messages are checked before they leave the Mac** (2026-11-08, [#485]). Git hooks check them in every tool, and Claude Code also builds when an agent stops. `STABLEBAR_SKIP_HOOKS=1` turns the hooks off for one person.

## Code

- **Window managers own their gaps** (2026-11-13). StableBar does not turn macOS menu-bar auto-hide off to reserve space: that changes the usable screen area underneath existing window-manager gaps, and the reserved height does not follow StableBar’s height. Keep windows clear remains a correction for ordinary windows after a drag.
- **Architecture rules are tests** (2026-11-08, [#484]). `ArchitectureRulesTests` caps `BarStore`'s stored state, a number that only goes down, allows no `unowned` reference ([#493]) and keeps private macOS API in `PrivateAPI.swift` ([#490]).
- **Private macOS API is a maintainer's call** (2026-11-08, [#484], [#490]). Every call lives in `PrivateAPI.swift` and is looked up at runtime, never with `@_silgen_name`, so a macOS without one turns off only its feature.
- **The configuration file is public API** (2026-10-26, [#337]). People's files, Store packages and themes depend on it, so changes are additive. Renaming or removing a property, or changing what it means, needs a migration, a test that loads the old form and a maintainer's OK. StableBar 0.9.0 and later, and betas built after [#337], skip the properties they don't know, with a warning, once the configuration says a newer release wrote it. Earlier versions stop at the first one. The [guide](docs/configuration.md#files-from-a-newer-stablebar) has the exact rules. Migrations of an old form run in memory on every file the loader reads, so includes and packages stay as they are, and are saved into the main file and screen setups' own bars at launch. A migration of values people can still choose skips files pinned to a release ([#223]).
- **Tests keep their own time** (2026-11-08, [#491]). Code whose tests depend on time takes a clock, and the test clock lives in the repository rather than in a new dependency.
- **Comments are for the next reader** (2026-11-10, [#533]). A comment says what the code can't, such as why it must be so, in a line or two. How the bug was found and fixed goes in the issue, the pull request and the commit message. [AGENTS.md](AGENTS.md#writing-comments) has the rule.

[#3]: https://github.com/Seb-GRAF/StableBar/issues/3
[#23]: https://github.com/Seb-GRAF/StableBar/pull/23
[#100]: https://github.com/Seb-GRAF/StableBar/pull/100
[#223]: https://github.com/Seb-GRAF/StableBar/issues/223
[#309]: https://github.com/Seb-GRAF/StableBar/pull/309
[#335]: https://github.com/Seb-GRAF/StableBar/issues/335
[#337]: https://github.com/Seb-GRAF/StableBar/pull/337
[#390]: https://github.com/Seb-GRAF/StableBar/pull/390
[#391]: https://github.com/Seb-GRAF/StableBar/pull/391
[#395]: https://github.com/Seb-GRAF/StableBar/pull/395
[#397]: https://github.com/Seb-GRAF/StableBar/pull/397
[#479]: https://github.com/Seb-GRAF/StableBar/pull/479
[#484]: https://github.com/Seb-GRAF/StableBar/pull/484
[#485]: https://github.com/Seb-GRAF/StableBar/pull/485
[#490]: https://github.com/Seb-GRAF/StableBar/pull/490
[#491]: https://github.com/Seb-GRAF/StableBar/pull/491
[#493]: https://github.com/Seb-GRAF/StableBar/pull/493
[#533]: https://github.com/Seb-GRAF/StableBar/pull/533
