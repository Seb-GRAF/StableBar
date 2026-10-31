import { test } from "node:test";
import assert from "node:assert/strict";
import { validateArtifact, fingerprint, reviewState, commentBody, readData, assetName, releaseTag } from "./screens-comment.mjs";

const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const screen = (id, status, extra = {}) => ({ id, status, changedPixels: status === "changed" ? 120 : 0,
  region: status === "changed" ? { x: 10, y: 20, width: 30, height: 40 } : null, images: {}, ...extra });

test("validateArtifact accepts only PNG images and the manifest", () => {
  const good = [{ name: "manifest.json", size: 100, head: Buffer.from("{") }, { name: "docs~hero-dark-after.png", size: 2048, head: png }];
  assert.deepEqual(validateArtifact(good), { ok: true, problems: [] });
  for (const bad of [{ name: "../x.png", size: 10, head: png }, { name: "a.txt", size: 10, head: png },
    { name: "fake.png", size: 10, head: Buffer.from("GIF89a..") }, { name: "big.png", size: 11 * 1024 * 1024, head: png }]) {
    assert.equal(validateArtifact([...good, bad]).ok, false, bad.name);
  }
  const many = Array.from({ length: 301 }, (_, index) => ({ name: `s${index}.png`, size: 10, head: png }));
  assert.equal(validateArtifact(many).ok, false);
});

test("fingerprint ignores order and follows the after images", () => {
  const first = fingerprint([{ id: "docs/a", afterSha256: "11" }, { id: "docs/b", afterSha256: "22" }]);
  assert.equal(first, fingerprint([{ id: "docs/b", afterSha256: "22" }, { id: "docs/a", afterSha256: "11" }]));
  assert.notEqual(first, fingerprint([{ id: "docs/a", afterSha256: "11" }, { id: "docs/b", afterSha256: "23" }]));
});

test("reviewState follows the visual review rules", () => {
  const changed = [screen("docs/a", "changed"), screen("docs/b", "unchanged")];
  assert.deepEqual(reviewState({ ranScreens: false }), { state: "success", description: "No screens to compare.", removeLabel: false });
  assert.deepEqual(reviewState({ ranScreens: true, screens: [screen("docs/a", "unchanged"), screen("docs/b", "unchanged")], failed: [], labels: [] }),
    { state: "success", description: "2 screens, none changed.", removeLabel: false });
  const waiting = reviewState({ ranScreens: true, screens: changed, failed: [], labels: [], fingerprint: "f1" });
  assert.equal(waiting.state, "pending");
  assert.equal(waiting.description, "1 screen changed: a maintainer adds visual-ok after looking.");
  assert.deepEqual(reviewState({ ranScreens: true, screens: changed, failed: [], labels: ["visual-ok"], approved: "f1", fingerprint: "f1" }),
    { state: "success", description: "1 changed screen approved.", removeLabel: false });
  const stale = reviewState({ ranScreens: true, screens: changed, failed: [], labels: ["visual-ok"], approved: "f0", fingerprint: "f1" });
  assert.equal(stale.state, "pending");
  assert.equal(stale.removeLabel, true);
  const failed = [{ id: "scenes/x", error: "draw: Unknown value " + "y".repeat(200) }];
  const broken = reviewState({ ranScreens: true, screens: changed, failed, labels: [], fingerprint: "f1" });
  assert.equal(broken.state, "failure");
  assert.match(broken.description, /^Drawing the screens failed: scenes\/x/);
  assert.ok(broken.description.length <= 140);
  assert.equal(reviewState({ ranScreens: true, screens: changed, failed, labels: ["visual-ok"], approved: "f1", fingerprint: "f1" }).state, "success");
});

test("commentBody shows changed screens, folds the rest and keeps its data", () => {
  const screens = [screen("docs/hero-dark", "changed", { images: { before: "b.png", after: "a.png", diff: "d.png" } }),
    screen("scenes/new-dark", "added", { images: { after: "n.png" }, note: "The base couldn't draw this scene: draw: Unknown value" }),
    screen("docs/settings-dark", "unchanged")];
  const data = { head: "abcdef1234", fingerprint: "f1", approved: null };
  const body = commentBody({ base: "1234567890", head: "abcdef1234", screens, failed: [], imageURL: (file) => `https://example.test/${file}`,
    review: { state: "pending", description: "2 screens changed: a maintainer adds visual-ok after looking." }, data });
  assert.match(body, /^<!-- stablebar-screens -->/);
  assert.match(body, /`main` at 1234567 → this pull request at abcdef1/);
  assert.match(body, /https:\/\/example\.test\/b\.png/);
  assert.match(body, /https:\/\/example\.test\/d\.png/);
  assert.match(body, /couldn't draw this scene/);
  assert.match(body, /<details><summary>1 unchanged screen<\/summary>/);
  assert.doesNotMatch(body, /docs\/settings-dark.*example\.test/);
  assert.deepEqual(readData(body), data);
  assert.equal(readData("no data here"), null);
});

test("assetName and releaseTag name the uploaded images", () => {
  assert.equal(assetName(412, "abcdef1234", "docs~hero-dark-after.png"), "pr412-abcdef1-docs~hero-dark-after.png");
  assert.equal(releaseTag(new Date("2026-11-03T10:00:00Z")), "pr-previews-2026-11");
});
