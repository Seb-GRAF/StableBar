import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { matchesGlob } from "node:path";
import { deepReviewPaths, needsDeepReview, needsRetry } from "./deep-review.mjs";

test("needsDeepReview asks for more than 400 changed lines", () => {
  assert.equal(needsDeepReview(["docs/widgets.md"], 400), false);
  assert.equal(needsDeepReview(["docs/widgets.md"], 401), true);
});

test("needsDeepReview matches the listed paths", () => {
  for (const file of ["Sources/StableBar/PrivateAPI.swift", "Sources/StableBar/ICloudSyncSettings.swift",
    ".github/workflows/ci.yml", ".github/scripts/fixtures/screens.json", "scripts/build.sh", "Package.resolved"])
    assert.equal(needsDeepReview(["docs/widgets.md", file], 10), true, file);
  for (const file of ["Sources/StableBar/BarStore.swift", "Sources/StableBar/Settings/PrivateAPI.swift",
    "docs/scripts.md", "Tests/StableBarTests/UninstallTests.swift"])
    assert.equal(needsDeepReview([file], 10), false, file);
});

test("every listed path matches a file", () => {
  const files = execFileSync("git", ["ls-files"],
    { cwd: new URL("../..", import.meta.url), encoding: "utf8", timeout: 60_000 }).split("\n");
  for (const path of deepReviewPaths) assert.ok(files.some((file) => matchesGlob(file, path)), path);
});

test("needsRetry asks CodeRabbit again 30 minutes after its review limit held back the head commit", () => {
  const limited = (user, head) => ({ user: { login: user }, updated_at: "2026-11-17T09:00:00Z",
    body: `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\nbetween a1 and ${head}.` });
  const summary = { user: { login: "coderabbitai[bot]" }, updated_at: "2026-11-17T09:00:00Z",
    body: "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\nbetween a1 and b2." };
  const pr = { headSha: "b2", comments: [limited("coderabbitai[bot]", "b2")], now: Date.parse("2026-11-17T09:30:00Z") };
  assert.equal(needsRetry(pr), true);
  assert.equal(needsRetry({ ...pr, now: Date.parse("2026-11-17T09:29:00Z") }), false);
  assert.equal(needsRetry({ ...pr, headSha: "c3" }), false);
  assert.equal(needsRetry({ ...pr, comments: [summary] }), false);
  assert.equal(needsRetry({ ...pr, comments: [limited("cubic-dev-ai[bot]", "b2")] }), false);
  assert.equal(needsRetry({ ...pr, comments: [] }), false);
});
