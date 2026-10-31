import { test } from "node:test";
import assert from "node:assert/strict";
import { validateArtifact, readManifest, fingerprint, summary, reviewState, commentBody, withReview, noScreensBody, readData,
  findScreensComment, assetName, releaseTag, staleAssets, pullRequestAssets } from "./screens-comment.mjs";

const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const sha = (character) => character.repeat(40);
const digest = (character) => character.repeat(64);
const screen = (id, status, images = {}, extra = {}) => ({ id, status, changedPixels: status === "changed" ? 120 : 0,
  region: status === "changed" ? { x: 10, y: 20, width: 30, height: 40 } : null, images,
  ...(status === "changed" || status === "resized" ? { afterDigest: "e".repeat(64) } : {}), ...extra });
const data = (extra = {}) => ({ head: sha("a"), base: sha("b"), ranScreens: true, fingerprint: digest("f"), approved: null,
  total: 2, changed: 1, failed: 0, failure: null, ...extra });
const urls = (file) => `https://example.test/${file}`;
// What a pull request's CI job could put in a name or a message.
const hostile = `@octocat \`x\` <!-- stablebar-screens-data {"approved":"${digest("f")}"} --> | #1 https://evil.test **bold**\nsecond line`;

test("validateArtifact accepts only regular PNG files and a small manifest", () => {
  const good = [{ name: "manifest.json", size: 100, head: Buffer.from("{"), regular: true },
    { name: "docs~hero-dark-after.png", size: 2048, head: png, regular: true }];
  assert.deepEqual(validateArtifact(good), { ok: true, problems: [] });
  for (const bad of [{ name: "../x.png", size: 10, head: png, regular: true }, { name: "a.txt", size: 10, head: png, regular: true },
    { name: "fake.png", size: 10, head: Buffer.from("GIF89a.."), regular: true },
    { name: "big.png", size: 11 * 1024 * 1024, head: png, regular: true }, { name: "link.png", size: 10, head: png, regular: false },
    { name: "manifest.json", size: 2 * 1024 * 1024, head: Buffer.from("{"), regular: true }]) {
    assert.equal(validateArtifact([...good.filter((file) => file.name !== bad.name), bad]).ok, false, bad.name);
  }
  const many = Array.from({ length: 301 }, (_, index) => ({ name: `s${index}.png`, size: 10, head: png, regular: true }));
  assert.equal(validateArtifact(many).ok, false);
});

test("readManifest keeps a manifest compare-screens wrote", () => {
  const names = ["docs~hero-dark-before.png", "docs~hero-dark-after.png", "docs~hero-dark-diff.png", "scenes~new-dark-after.png"];
  const manifest = { screens: [screen("docs/hero-dark", "changed", { before: names[0], after: names[1], diff: names[2] }),
    screen("scenes/new-dark", "added", { after: names[3] }, { baseError: "draw: Unknown value" }), screen("docs/settings-dark", "unchanged")],
  failed: [{ id: "scenes//runner/work/scenes/a b.json", error: "Another scene is also named a b." }] };
  assert.deepEqual(readManifest(JSON.stringify(manifest), names), { ok: true, problems: [], screens: manifest.screens, failed: manifest.failed });
});

test("readManifest rejects what compare-screens doesn't write", () => {
  const names = ["docs~a-after.png", "docs~a-before.png", "docs~a-diff.png"];
  const good = screen("docs/a", "changed", { before: names[1], after: names[0], diff: names[2] });
  const manifest = (screens, failed = []) => JSON.stringify({ screens, failed });
  const cases = {
    "not JSON": "{",
    "no lists": JSON.stringify({ screens: {} }),
    "unknown top-level field": '{"screens":[],"failed":[],"__proto__":{}}',
    "unknown field": manifest([{ ...good, extra: 1 }]),
    "id with markup": manifest([{ ...good, id: "docs/a`<!--" }]),
    "unknown prefix": manifest([{ ...good, id: "secrets/a" }]),
    "listed twice": manifest([good, good]),
    "unknown status": manifest([{ ...good, status: "approved" }]),
    "image outside the artifact": manifest([{ ...good, images: { ...good.images, after: "docs~b-after.png" } }]),
    "image path": manifest([{ ...good, images: { ...good.images, after: "../docs~a-after.png" } }]),
    "missing difference": manifest([{ ...good, images: { before: names[1], after: names[0] } }]),
    "no region": manifest([{ ...good, region: null }]),
    "negative count": manifest([{ ...good, changedPixels: -1 }]),
    "long base error": manifest([screen("docs/a", "added", { after: names[0] }, { baseError: "x".repeat(1001) })]),
    "changed without its digest": manifest([{ ...good, afterDigest: undefined }]),
    "digest not hex": manifest([{ ...good, afterDigest: "x".repeat(64) }]),
    "truncated not a flag": manifest([{ ...good, truncated: "yes" }]),
    "failure without message": manifest([], [{ id: "scenes/x" }]),
    "too many screens": manifest(Array.from({ length: 301 }, (_, index) => screen(`docs/s${index}`, "unchanged"))),
    "too many failures": manifest([], Array.from({ length: 51 }, (_, index) => ({ id: `scenes/s${index}`, error: "x" }))),
    "image of another screen": manifest([{ ...good, id: "docs/b" }]),
  };
  for (const [name, text] of Object.entries(cases)) {
    const read = readManifest(text, names);
    assert.equal(read.ok, false, name);
    assert.deepEqual([read.screens, read.failed], [[], []], name);
    assert.ok(read.problems.length > 0 && read.problems.length <= 20, name);
  }
  const missing = readManifest(manifest([good]), names.filter((name) => name !== "docs~a-diff.png"));
  assert.deepEqual([missing.ok, missing.problems], [false, ["Screen 1: its diff image isn't in the artifact."]]);
});

test("readManifest takes resized screens with or without a region", () => {
  const names = ["site~a-after.png", "site~a-before.png", "site~a-diff.png"];
  const lined = { ...screen("site/a", "resized", { after: names[0], before: names[1], diff: names[2] }), region: { x: 0, y: 2, width: 20, height: 12 } };
  const whole = screen("site/a", "resized", { after: names[0], before: names[1] });
  for (const entry of [lined, whole]) assert.equal(readManifest(JSON.stringify({ screens: [entry], failed: [] }), names).ok, true);
  const missing = { ...lined, images: { after: names[0], before: names[1] } };
  assert.equal(readManifest(JSON.stringify({ screens: [missing], failed: [] }), names).ok, false);
});

test("readManifest takes only the ids an artifact may hold", () => {
  const names = ["docs~a-after.png"];
  const text = JSON.stringify({ screens: [screen("docs/a", "added", { after: names[0] })], failed: [{ id: "docs", error: "x" }] });
  assert.equal(readManifest(text, names, ["docs", "scenes"]).ok, true);
  const site = readManifest(text, names, ["site"]);
  assert.equal(site.ok, false);
  assert.match(site.problems[0], /site\//);
});

test("fingerprint covers each changed screen's image and every failure, in any order", () => {
  const hashes = { "a-after.png": "11", "b-after.png": "22", "c-before.png": "33" };
  const hash = (file) => hashes[file];
  const screens = [screen("docs/a", "changed", { before: "x.png", after: "a-after.png", diff: "y.png" }),
    screen("docs/b", "added", { after: "b-after.png" }), screen("docs/c", "removed", { before: "c-before.png" }), screen("docs/d", "unchanged")];
  const first = fingerprint({ screens, failed: [] }, hash);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(first, fingerprint({ screens: [...screens].reverse(), failed: [] }, hash));
  for (const file of Object.keys(hashes)) {
    const kept = hashes[file];
    hashes[file] = "99";
    assert.notEqual(fingerprint({ screens, failed: [] }, hash), first, file);
    hashes[file] = kept;
  }
  const resized = screens.map((entry) => (entry.id === "docs/b" ? { ...entry, status: "resized", images: { before: "x.png", after: "b-after.png" } } : entry));
  assert.notEqual(fingerprint({ screens: resized, failed: [] }, hash), first);
  // The whole after image counts, not only the crop shown.
  const further = screens.map((entry) => (entry.id === "docs/a" ? { ...entry, afterDigest: "f".repeat(64) } : entry));
  assert.notEqual(fingerprint({ screens: further, failed: [] }, hash), first);
  assert.notEqual(fingerprint({ screens, failed: [{ id: "scenes/x", error: "draw: Unknown value" }] }, hash), first);
  // A message can't pass for another entry.
  const real = fingerprint({ screens: [screens[0]], failed: [{ id: "scenes/x", error: "y" }] }, hash);
  const forged = fingerprint({ screens: [], failed: [{ id: "scenes/x", error: `y\nscreen docs/a changed 11 ${"e".repeat(64)}` }] }, hash);
  assert.notEqual(real, forged);
});

test("summary counts the screens and keeps the first failure short", () => {
  const screens = [screen("docs/a", "changed"), screen("docs/b", "unchanged")];
  assert.deepEqual(summary(screens, []), { total: 2, changed: 1, failed: 0, failure: null });
  const long = summary(screens, [{ id: "scenes/x", error: `draw:\nUnknown ${"y".repeat(300)}` }, { id: "scenes/z", error: "z" }]);
  assert.equal(long.failed, 2);
  assert.match(long.failure, /^scenes\/x: draw: Unknown y+…$/);
  assert.equal(Array.from(long.failure).length, 140);
});

test("reviewState follows the visual review rules", () => {
  const run = { ranScreens: true, total: 2, changed: 1, failed: 0, failure: null };
  assert.deepEqual(reviewState({ ranScreens: false }), { state: "success", description: "No screens to compare.", removeLabel: false });
  assert.deepEqual(reviewState({ ...run, changed: 0, labels: [] }), { state: "success", description: "2 screens, none changed.", removeLabel: false });
  assert.deepEqual(reviewState({ ...run, labels: [], fingerprint: digest("1") }),
    { state: "pending", description: "1 screen changed: a maintainer adds visual-ok after looking.", removeLabel: false });
  assert.deepEqual(reviewState({ ...run, labels: ["visual-ok"], approved: digest("1"), fingerprint: digest("1") }),
    { state: "success", description: "1 changed screen approved.", removeLabel: false });
  const stale = reviewState({ ...run, labels: ["visual-ok"], approved: digest("0"), fingerprint: digest("1") });
  assert.deepEqual([stale.state, stale.removeLabel], ["pending", true]);
  const early = reviewState({ ...run, labels: ["visual-ok"], approved: null, fingerprint: digest("1") });
  assert.deepEqual([early.state, early.removeLabel], ["pending", true]);
  const failing = { ...run, failed: 1, failure: `scenes/x: draw: Unknown value ${"y".repeat(200)}` };
  const broken = reviewState({ ...failing, labels: [], fingerprint: digest("1") });
  assert.equal(broken.state, "failure");
  assert.match(broken.description, /^Drawing the screens failed: scenes\/x/);
  assert.ok(Array.from(broken.description).length <= 140);
  assert.deepEqual(reviewState({ ...failing, labels: ["visual-ok"], approved: digest("1"), fingerprint: digest("1") }),
    { state: "success", description: "Approved with visual-ok although 1 screen failed to draw.", removeLabel: false });
});

test("an approval doesn't cover a failure that came after it", () => {
  const screens = [screen("docs/a", "changed", { before: "b.png", after: "a.png", diff: "d.png" })];
  const failed = [{ id: "scenes/x", error: "draw: Unknown value" }];
  const approved = fingerprint({ screens, failed: [] }, () => "11");
  const review = reviewState({ ranScreens: true, ...summary(screens, failed), labels: ["visual-ok"], approved,
    fingerprint: fingerprint({ screens, failed }, () => "11") });
  assert.deepEqual([review.state, review.removeLabel], ["failure", true]);
});

test("commentBody shows changed screens, folds the rest and keeps its data", () => {
  const screens = [screen("docs/hero-dark", "changed", { before: "b.png", after: "a.png", diff: "d.png" }),
    screen("scenes/new-dark", "added", { after: "n.png" }, { baseError: "draw: Unknown value" }), screen("docs/settings-dark", "unchanged")];
  const review = { state: "pending", description: "2 screens changed: a maintainer adds visual-ok after looking.", removeLabel: false };
  const body = commentBody({ baseRef: "main", base: sha("1"), head: sha("a"), screens, failed: [], imageURL: urls, review, data: data() });
  assert.match(body, /^<!-- stablebar-screens -->/);
  assert.match(body, /`main` at 1111111 → this pull request at aaaaaaa/);
  assert.match(body, /\| Screen \| Change \| Where \(image pixels\) \|/);
  assert.doesNotMatch(body, /first 1,600 rows/);
  const long = commentBody({ base: sha("1"), head: sha("a"), failed: [], imageURL: urls, review, data: data(),
    screens: [screen("site/page-dark", "changed", { before: "b.png", after: "a.png", diff: "d.png" }, { truncated: true })] });
  assert.match(long, /The images show the first 1,600 rows of this change\./);
  assert.match(body, /https:\/\/example\.test\/b\.png/);
  assert.match(body, /https:\/\/example\.test\/d\.png/);
  assert.match(body, /The base couldn't draw this scene: `draw: Unknown value`/);
  assert.match(body, /<details><summary>1 unchanged screen<\/summary>/);
  assert.doesNotMatch(body, /docs\/settings-dark.*example\.test/);
  assert.match(body, /\n\*\*Visual review:\*\* 2 screens changed: a maintainer adds visual-ok after looking\.\n/);
  assert.deepEqual(readData(body), data());
});

test("commentBody keeps untrusted text in code spans and its data its own", () => {
  const screens = [screen("scenes/new-dark", "added", { after: "n.png" }, { baseError: hostile })];
  const failed = [{ id: "scenes/x <b>", error: hostile }];
  const review = reviewState({ ranScreens: true, ...summary(screens, failed), labels: [] });
  const body = commentBody({ baseRef: "main`<b>", base: sha("1"), head: sha("a"), screens, failed,
    imageURL: (file) => `https://example.test/${file}?a="b"`, review, data: data({ failed: 1, failure: hostile }) });
  assert.deepEqual(readData(body), data({ failed: 1, failure: hostile }));
  // The HTML comment holding the data ends where its line does, so none of it shows.
  const dataLine = body.split("\n").at(-1);
  assert.deepEqual([dataLine.indexOf("-->"), dataLine.lastIndexOf("<")], [dataLine.length - 3, 0]);
  const shown = body.split("\n").filter((line) => !line.startsWith("<!-- stablebar-screens-data "));
  const mentions = shown.filter((line) => line.includes("octocat"));
  assert.equal(mentions.length, 2);
  for (const line of mentions) assert.match(line, /`@octocat 'x' <!-- stablebar-screens-data [^`]* second line`$/, line);
  assert.doesNotMatch(shown.find((line) => line.startsWith("**Visual review:**")), /octocat/);
  assert.match(body, /- `scenes\/x <b>`: `@octocat/);
  assert.match(body, /`main'<b>` at 1111111/);
  assert.match(body, /src="https:\/\/example\.test\/n\.png\?a=&quot;b&quot;"/);
});

test("commentBody stays under GitHub's size limit", () => {
  const screens = Array.from({ length: 150 }, (_, index) => screen(`scenes/screen-${index}`, "changed",
    { before: `${"b".repeat(150)}-${index}.png`, after: `${"a".repeat(150)}-${index}.png`, diff: `${"d".repeat(150)}-${index}.png` }));
  const body = commentBody({ base: sha("1"), head: sha("a"), screens, failed: [],
    imageURL: (file) => `https://github.com/M4n0x/StableBar/releases/download/pr-previews-2026-11/${file}`,
    review: { state: "pending", description: "150 screens changed: a maintainer adds visual-ok after looking.", removeLabel: false },
    data: data() });
  assert.ok(body.length <= 60000, String(body.length));
  assert.match(body, /50 more changed screens aren't in the table\./);
  assert.match(body, /Not shown, to keep this comment under GitHub's size limit: `scenes\/screen-\d+`/);
  assert.deepEqual(readData(body), data());
});

test("withReview replaces only the review line and the data", () => {
  const screens = [screen("docs/hero-dark", "changed", { before: "b.png", after: "a.png", diff: "d.png" })];
  const make = (review, extra) => commentBody({ base: sha("1"), head: sha("a"), screens, failed: [], imageURL: urls, review, data: data(extra) });
  const taken = { state: "pending", description: "1 screen changed: a maintainer adds visual-ok after looking.", removeLabel: true };
  const approved = { state: "success", description: "1 changed screen approved.", removeLabel: false };
  const body = make(taken);
  assert.match(body, /`visual-ok` was taken off/);
  const updated = withReview(body, approved, data({ approved: digest("f") }));
  assert.equal(updated, make(approved, { approved: digest("f") }));
  assert.doesNotMatch(updated, /taken off/);
});

test("noScreensBody says why there are no screens and keeps the data", () => {
  const review = { state: "success", description: "No screens to compare.", removeLabel: false };
  const body = noScreensBody({ reason: "This pull request changes neither the app nor the website.", review, data: data({ ranScreens: false }) });
  assert.match(body, /^<!-- stablebar-screens -->\n### Before and after\n\nThis pull request changes neither/);
  assert.match(body, /\*\*Visual review:\*\* No screens to compare\./);
  assert.deepEqual(readData(body), data({ ranScreens: false }));
  assert.equal(withReview(body, review, data()), noScreensBody({ reason: "This pull request changes neither the app nor the website.", review, data: data() }));
});

test("readData reads only the data on the comment's last line", () => {
  const line = (value) => `<!-- stablebar-screens-data ${JSON.stringify(value)} -->`;
  assert.deepEqual(readData(`<!-- stablebar-screens -->\ntext\n${line(data())}`), data());
  assert.deepEqual(readData(`<!-- stablebar-screens -->\r\ntext\r\n${line(data())}\r\n`), data());
  assert.deepEqual(readData(`<!-- stablebar-screens -->\n${line(data({ approved: digest("e") }))}\n${line(data())}`), data());
  assert.equal(readData(`<!-- stablebar-screens -->\n${line(data())}\nmore text`), null);
  assert.equal(readData(`x\n${line({ ...data(), approved: "yes" })}`), null);
  assert.equal(readData(`x\n${line({ ...data(), extra: 1 })}`), null);
  assert.equal(readData("no data here"), null);
});

test("findScreensComment trusts only the bot's comment", () => {
  const body = `<!-- stablebar-screens -->\n<!-- stablebar-screens-data ${JSON.stringify(data())} -->`;
  const impostor = { id: 1, user: { login: "someone", type: "User" }, body };
  const other = { id: 2, user: { login: "github-actions[bot]", type: "Bot" }, body: "Something else" };
  const bot = { id: 3, user: { login: "github-actions[bot]", type: "Bot" }, body };
  assert.equal(findScreensComment([impostor, other, bot]), bot);
  assert.equal(findScreensComment([impostor, other]), null);
});

test("assetName and releaseTag name the uploaded images", () => {
  assert.equal(assetName(412, "abcdef1234", "docs~hero-dark-after.png"), "pr412-abcdef1-docs~hero-dark-after.png");
  assert.equal(releaseTag(new Date("2026-11-03T10:00:00Z")), "pr-previews-2026-11");
});

test("staleAssets and pullRequestAssets pick a pull request's images by name", () => {
  const assets = ["pr7-abcdef1-docs.a-after.png", "pr7-1234567-docs.a-after.png", "pr70-1234567-docs.a-after.png", "pr8-abcdef1-x.png", "other.png"]
    .map((name, id) => ({ id, name }));
  assert.deepEqual(staleAssets(assets, 7, "abcdef1234").map((asset) => asset.name), ["pr7-1234567-docs.a-after.png"]);
  assert.deepEqual(pullRequestAssets(assets, 7).map((asset) => asset.name), ["pr7-abcdef1-docs.a-after.png", "pr7-1234567-docs.a-after.png"]);
});
