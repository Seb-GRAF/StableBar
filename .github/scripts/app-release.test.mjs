import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { analyzeCommits } from "./app-release.mjs";

class ReleaseHistory {
  constructor(t) {
    this.cwd = mkdtempSync(join(tmpdir(), "stablebar-release-"));
    t.after(() => rmSync(this.cwd, { recursive: true, force: true }));
    this.commits = [];
    this.git("init", "--quiet", "--initial-branch=main");
    this.commit("chore: start", "README.md");
  }

  git(...args) {
    return execFileSync("git", [
      "-c", "user.name=StableBar Tests", "-c", "user.email=tests@example.invalid",
      "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", "-c", "core.hooksPath=/dev/null", ...args,
    ], { cwd: this.cwd, encoding: "utf8" }).trim();
  }

  commit(message, path) {
    const file = join(this.cwd, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${message}\n${this.commits.length}`);
    this.git("add", ".");
    this.git("commit", "--quiet", "-m", message);
    this.commits.unshift({ hash: this.git("rev-parse", "HEAD"), message });
  }

  analyze(channel) {
    return analyzeCommits({}, {
      cwd: this.cwd,
      env: { STABLEBAR_RELEASE_CHANNEL: channel },
      commits: this.commits,
      logger: { log() {} },
    });
  }
}

test("a shipped fix followed by docs, CI and CodeRabbit changes makes no new beta", async t => {
  const history = new ReleaseHistory(t);
  history.git("tag", "v0.9.0");
  history.commit("fix: hide empty widgets", "Sources/StableBar/Widget.swift");
  history.git("tag", "v0.9.1-beta.489");
  history.commit("docs: redraw the website", "site/index.html");
  history.commit("ci: check pull requests", ".github/workflows/ci.yml");
  history.commit("chore: review pull requests with CodeRabbit", ".coderabbit.yaml");
  assert.equal(await history.analyze("beta"), null);
  assert.equal(await history.analyze("stable"), "patch");

  history.commit("ci: draw review screenshots", "Sources/StableBar/DocsImages.swift");
  assert.equal(await history.analyze("beta"), null);
});

test("website-only fixes and features cannot trigger or raise an app release", async t => {
  const history = new ReleaseHistory(t);
  history.git("tag", "v0.9.0");
  history.commit("feat!: rebuild the website", "site/index.html");
  history.commit("fix: correct the guide", "docs/clock.md");
  assert.equal(await history.analyze("beta"), null);
  assert.equal(await history.analyze("stable"), null);

  history.commit("fix: keep the clock visible", "Sources/StableBar/Clock.swift");
  assert.equal(await history.analyze("beta"), "patch");
  assert.equal(await history.analyze("stable"), "patch");
});

test("an unpublished feature still gets a beta after a docs merge", async t => {
  const history = new ReleaseHistory(t);
  history.git("tag", "v0.9.0");
  history.git("switch", "--quiet", "-c", "feat/clock");
  history.commit("feat: add a clock", "Sources/StableBar/Clock.swift");
  history.git("switch", "--quiet", "main");
  history.git("merge", "--quiet", "--no-ff", "-m", "Merge pull request #1", "feat/clock");
  history.commit("docs: explain the clock", "docs/clock.md");
  assert.equal(await history.analyze("beta"), "minor");
  history.git("tag", "v0.10.0-beta.1");
  history.commit("fix: keep the clock visible", "Sources/StableBar/Clock.swift");
  assert.equal(await history.analyze("beta"), "minor");
});

test("eligible app changes set patch, minor and major versions, including the first release", async t => {
  for (const [message, path, expected] of [
    ["fix: keep the clock", "Sources/StableBar/Clock.swift", "patch"],
    ["perf: draw once", "Resources/config.json", "patch"],
    ["refactor(clock): simplify the timer", "Sources/StableBar/Clock.swift", "patch"],
    ["feat: add a dependency", "Package.swift", "minor"],
    ["fix: update Sparkle", "Package.resolved", "patch"],
    ["fix: package the icon", "scripts/package.sh", "patch"],
    ["refactor!: replace the layout", "Sources/StableBar/Layout.swift", "major"],
    ["fix: change configuration\n\nBREAKING CHANGE: remove the old layout", "Sources/StableBar/Layout.swift", "major"],
  ]) {
    const history = new ReleaseHistory(t);
    history.commit(message, path);
    assert.equal(await history.analyze("beta"), expected, message);
    assert.equal(await history.analyze("stable"), expected, message);
  }
});

test("maintenance types do not release even when they change app inputs", async t => {
  const history = new ReleaseHistory(t);
  history.git("tag", "v0.9.0");
  for (const type of ["docs", "ci", "test", "build", "chore", "style"]) {
    history.commit(`${type}: update the fixture`, "Sources/StableBar/DocsImages.swift");
  }
  assert.equal(await history.analyze("beta"), null);
  assert.equal(await history.analyze("stable"), null);
});
