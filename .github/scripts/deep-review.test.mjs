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
  const files = execFileSync("git", ["ls-files"], { cwd: new URL("../..", import.meta.url), encoding: "utf8" }).split("\n");
  for (const path of deepReviewPaths) assert.ok(files.some((file) => matchesGlob(file, path)), path);
});

test("needsRetry asks CodeRabbit again after its review limit or when it never answered", () => {
  const codeRabbit = { login: "coderabbitai[bot]" };
  const limited = { user: codeRabbit, body: "<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->" };
  const summary = { user: codeRabbit, body: "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->" };
  const cubic = { user: { login: "cubic-dev-ai[bot]" }, body: "rate limited by coderabbit.ai" };
  const pr = { headSha: "b", updatedAt: "2026-11-17T09:00:00Z", reviews: [], comments: [limited], now: Date.parse("2026-11-17T10:00:00Z") };
  assert.equal(needsRetry(pr), true);
  assert.equal(needsRetry({ ...pr, comments: [cubic] }), true);
  assert.equal(needsRetry({ ...pr, comments: [summary] }), false);
  assert.equal(needsRetry({ ...pr, now: Date.parse("2026-11-17T09:20:00Z") }), false);
  assert.equal(needsRetry({ ...pr, reviews: [{ user: codeRabbit, commit_id: "b" }] }), false);
  assert.equal(needsRetry({ ...pr, reviews: [{ user: codeRabbit, commit_id: "a" }] }), true);
});
