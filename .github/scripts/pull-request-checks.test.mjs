import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { visibleText, needsIssue, closingIssueNumbers, checkLinkedIssue, checkDescription } from "./pull-request-checks.mjs";

const repository = "stablebox/StableBar";
const template = readFileSync(new URL("../pull_request_template.md", import.meta.url), "utf8");
const attribution = "Claude Opus 5.5 via Claude Code";
const filled = ["## Problem", "The clock disappears on a notched display.", "",
  "## Changes", "Keep it left of the notch.", "", "## Testing", "swift test --filter Clock passes.", "",
  "## Merging", "Rebase merge.", "", attribution].join("\n");
const summary = "\n<!-- This is an auto-generated comment: release notes by coderabbit.ai -->\n" +
  "## Summary by CodeRabbit\n* New stuff\n<!-- end of auto-generated comment: release notes by coderabbit.ai -->";
const cubicButtons = "\n\n<!-- This is an auto-generated description by cubic. -->\n" +
  '<a href="https://cubic.dev/pr/stablebox/StableBar/pull/1"><img alt="View guided diff" src="review.svg"></a>\n' +
  "<!-- End of auto-generated description by cubic. -->\n";
const everything = ["Problem", "Changes", "Testing", "attribution line"];

test("visibleText drops comments, auto-generated blocks and carriage returns", () => {
  assert.equal(visibleText("a <!-- x --> b <!-- y\nz --> c"), "a  b  c");
  assert.equal(visibleText("a\n<!-- never closed\nb"), "a\n");
  assert.equal(visibleText("a\r\nb"), "a\nb");
  assert.equal(visibleText("text\n" + summary.trimStart()), "text\n");
  assert.equal(visibleText("text" + cubicButtons), "text\n\n\n");
  assert.equal(visibleText(null), "");
});

test("visibleText keeps the comment markers GitHub shows as text", () => {
  for (const text of ["Handle the literal `<!--` token.", "Replace the <!-- marker\nnext line",
    "```html\n<!-- example\n```\nafter", "`<!-- x -->` stays", "    <!-- indented code"])
    assert.equal(visibleText(text), text, text);
  assert.equal(visibleText("a ` b\n<!-- hidden -->\nc `"), "a ` b\n\nc `");
});

test("needsIssue covers fix, feat and perf, with a scope or a bang", () => {
  for (const title of ["fix: keep the clock", "feat(bar)!: drop the old layout", "perf: draw once", "Fix: capital type"])
    assert.equal(needsIssue(title), true, title);
  for (const title of ["docs: fix a typo", "ci: run tests", "revert: fix: x", "chore(release): 1.0.0", "fixup: x", "fix the clock"])
    assert.equal(needsIssue(title), false, title);
});

test("closingIssueNumbers reads closing keywords for this repository only", () => {
  assert.deepEqual(closingIssueNumbers("Fixes #12", repository), [12]);
  assert.deepEqual(closingIssueNumbers("closes #3 and Resolves: #4, fixes #3", repository), [3, 4]);
  assert.deepEqual(closingIssueNumbers("Fixes stablebox/stablebar#12", repository), [12]);
  assert.deepEqual(closingIssueNumbers("Fixed https://github.com/stablebox/StableBar/issues/12", repository), [12]);
  assert.deepEqual(closingIssueNumbers("Fixes other/repo#12", repository), []);
  assert.deepEqual(closingIssueNumbers("See #12", repository), []);
  assert.deepEqual(closingIssueNumbers("<!-- Fixes #12 -->", repository), []);
  assert.deepEqual(closingIssueNumbers(null, repository), []);
  assert.deepEqual(closingIssueNumbers("Fixes #0", repository), []);
});

test("checkLinkedIssue asks fix, feat and perf pull requests for an issue in this repository", () => {
  const pr = { title: "fix: keep the clock", body: "", repository, baseRef: "main", defaultBranch: "main", closingIssues: [] };
  assert.equal(checkLinkedIssue({ ...pr, title: "docs: explain the clock" }).ok, true);
  assert.equal(checkLinkedIssue({ ...pr, closingIssues: [{ number: 12, repository: "stablebox/stablebar" }] }).ok, true);
  assert.equal(checkLinkedIssue({ ...pr, closingIssues: [{ number: 12, repository: "other/repo" }] }).ok, false);
  assert.equal(checkLinkedIssue({ ...pr, body: "Fixes #12" }).ok, false);
  assert.equal(checkLinkedIssue({ ...pr, baseRef: "fix/parent", body: "Fixes #12" }).ok, true);
  assert.equal(checkLinkedIssue({ ...pr, baseRef: "fix/parent", body: null }).ok, false);
  assert.match(checkLinkedIssue(pr).message, /Fixes #N/);
});

test("checkDescription wants Problem, Changes, Testing and a last attribution line", () => {
  assert.deepEqual(checkDescription(filled).missing, []);
  assert.equal(checkDescription(filled).ok, true);
  assert.deepEqual(checkDescription(filled.replaceAll("\n", "\r\n")).missing, []);
  assert.deepEqual(checkDescription(filled.replace(attribution, "No agent")).missing, []);
  assert.deepEqual(checkDescription(filled.replace(attribution, "no agent.")).missing, []);
  assert.deepEqual(checkDescription(filled.replace(attribution, "Tested on macOS 27.")).missing, ["attribution line"]);
  assert.deepEqual(checkDescription(filled.replace("swift test --filter Clock passes.", "<!-- later -->")).missing, ["Testing"]);
  assert.deepEqual(checkDescription(filled.replace("## Testing", "## testing")).missing, []);
  assert.deepEqual(checkDescription(filled + summary).missing, []);
  assert.deepEqual(checkDescription(filled + cubicButtons).missing, []);
  assert.deepEqual(checkDescription(filled.replace("Keep it left of the notch.", "Handle the literal `<!--` token.")).missing, []);
  assert.deepEqual(checkDescription(filled.replace("swift test --filter Clock passes.", "```html\n<!-- example\n```")).missing, []);
  assert.deepEqual(checkDescription(filled.replace("Keep it left of the notch.", "<!-- unterminated")).missing,
    ["Changes", "Testing", "attribution line"]);
  assert.deepEqual(checkDescription(template).missing, everything);
  assert.deepEqual(checkDescription(null).missing, everything);
  const failed = checkDescription(template);
  assert.equal(failed.ok, false);
  assert.match(failed.message, /Problem, Changes and Testing/);
  assert.match(failed.message, /No agent/);
});
