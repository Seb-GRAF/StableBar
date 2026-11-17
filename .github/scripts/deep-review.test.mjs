import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { matchesGlob } from "node:path";
import { deepReviewPaths, needsDeepReview } from "./deep-review.mjs";

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
