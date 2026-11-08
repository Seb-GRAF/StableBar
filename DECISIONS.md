# Decisions

Lasting decisions about how StableBar is built, reviewed and shipped, so they don't get argued again or lost in a closed pull request. Each says what was decided, why, and where. Product choices, such as a feature that was declined, stay in their issues, where the [triage skill](.agents/skills/triage/SKILL.md) finds them.

Add an entry when a pull request sets a rule, a policy or a choice not to do something. Changing or removing one is the maintainers' call.

## Releases

- **Betas from `main`, stable by hand** (2026-10-16, [#3], [#23]). A push to `main` publishes a beta when the app changed since the newest release and a `feat`, `fix`, `perf` or `refactor` commit changed it, and a maintainer promotes a beta to stable, so stable ships what beta users ran. There is no develop branch. Pushes that change only docs, CI or tests don't ship the same app again ([#309]).
- **Merge commits by default** ([CONTRIBUTING](CONTRIBUTING.md#how-we-work)). semantic-release reads each commit that reaches `main`, so a merge commit keeps every one in the changelog; squash only when the title alone should reach it.
- **An issue for every `fix`, `feat` or `perf`** (2026-10-31, [#390]). The issue holds the problem and the decision; the `Linked issue` check enforces it. Other types can skip it.

## Reviews and checks

- **CodeRabbit reviews every pull request** (2026-10-31, [#391]). It's free for open source, its quiet profile posts only what matters, and it reviews every push. No paid review tools or API keys.
- **No auto-merge** (2026-10-31). The rules need no approval, but a maintainer merges; nothing merges itself.
- **A person approves changed screens** (2026-10-31, [#395], [#397]). CI draws before/after screens, and any maintainer, the author too, adds `visual-ok` after looking. A visible change also shows screenshots in its pull request description (2026-11-08, [#484]).
- **CI builds with one pinned Xcode** (2026-11-08, [#479]). A runner image update can't change the toolchain under a pull request; moving to a newer Xcode is a pull request of its own.
- **Commit messages are checked before they leave the Mac** (2026-11-08, [#485]). Git hooks check them in every tool, and Claude Code also builds when an agent stops. `STABLEBAR_SKIP_HOOKS=1` turns the hooks off for one person.

## Code

- **Architecture rules are tests** (2026-11-08, [#484]). `ArchitectureRulesTests` caps `BarStore`'s stored state, a number that only goes down, allows no `unowned` reference ([#493]) and keeps private macOS API in `PrivateAPI.swift` ([#490]).
- **Private macOS API is a maintainer's call** (2026-11-08, [#484], [#490]). Every call lives in `PrivateAPI.swift` and is looked up at runtime, never with `@_silgen_name`, so a macOS without one turns off only its feature.
- **The configuration file is public API** (2026-10-26, [#337]). People's files, Store packages and themes depend on it, so changes are additive. Renaming or removing a property, or changing what it means, needs a migration, a test that loads the old form and a maintainer's OK. StableBar 0.9.0 and later, and betas built after [#337], skip the properties they don't know, with a warning, once the configuration says a newer release wrote it. Earlier versions stop at the first one. The [guide](docs/configuration.md#files-from-a-newer-stablebar) has the exact rules. Migrations are still open ([#223]).
- **Tests keep their own time** (2026-11-08, [#491]). Code whose tests depend on time takes a clock, and the test clock lives in the repository rather than in a new dependency.

[#3]: https://github.com/Seb-GRAF/StableBar/issues/3
[#23]: https://github.com/Seb-GRAF/StableBar/pull/23
[#223]: https://github.com/Seb-GRAF/StableBar/issues/223
[#309]: https://github.com/Seb-GRAF/StableBar/pull/309
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
