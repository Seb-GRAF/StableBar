import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, mkdirSync, symlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { comparePair, compareDirectories, main } from "./compare-screens.mjs";
import { decodePNG, encodePNG } from "./png.mjs";

function image(width, height, rgba = [40, 40, 40, 255]) {
  const pixels = new Uint8Array(width * height * 4);
  for (let index = 0; index < width * height; index++) pixels.set(rgba, index * 4);
  return { width, height, rgba: pixels };
}

function paint(target, x, y, width, height, rgba) {
  const copy = { ...target, rgba: Uint8Array.from(target.rgba) };
  for (let row = y; row < y + height; row++) {
    for (let column = x; column < x + width; column++) copy.rgba.set(rgba, (row * copy.width + column) * 4);
  }
  return copy;
}

test("comparePair finds the changed region and ignores noise", () => {
  const base = image(20, 10);
  assert.deepEqual(comparePair(base, base), { status: "unchanged", changedPixels: 0, region: null });
  assert.deepEqual(comparePair(base, paint(base, 5, 2, 3, 3, [200, 40, 40, 255])),
    { status: "changed", changedPixels: 9, region: { x: 5, y: 2, width: 3, height: 3 } });
  assert.equal(comparePair(base, paint(base, 12, 6, 1, 1, [200, 40, 40, 255])).status, "unchanged");
  assert.equal(comparePair(base, paint(base, 0, 0, 20, 10, [41, 41, 41, 255])).status, "unchanged");
  assert.deepEqual(comparePair(base, image(21, 10)), { status: "resized", changedPixels: 0, region: null });
  assert.equal(comparePair(null, base).status, "added");
  assert.equal(comparePair(base, null).status, "removed");
});

test("comparePair compares screens of new heights from the top, to the first change", () => {
  const base = image(20, 10);
  // Rows added at the bottom change from where the shorter image ends.
  assert.deepEqual(comparePair(base, image(20, 14)), { status: "resized", changedPixels: 80, region: { x: 0, y: 10, width: 20, height: 4 } });
  assert.deepEqual(comparePair(base, image(20, 8)), { status: "resized", changedPixels: 40, region: { x: 0, y: 8, width: 20, height: 2 } });
  // A change in the rows both have starts the region there, across the full width, down to the longer image's end.
  const taller = paint(image(20, 14), 5, 2, 3, 3, [200, 40, 40, 255]);
  assert.deepEqual(comparePair(base, taller), { status: "resized", changedPixels: 89, region: { x: 0, y: 2, width: 20, height: 12 } });
});

test("compareDirectories writes images for changed screens only, and notes what the base couldn't draw", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  for (const folder of [before, after, out]) mkdirSync(folder, { recursive: true });
  const base = image(60, 30);
  writeFileSync(join(before, "same-dark.png"), encodePNG(base));
  writeFileSync(join(after, "same-dark.png"), encodePNG(base));
  writeFileSync(join(before, "moved-dark.png"), encodePNG(base));
  writeFileSync(join(after, "moved-dark.png"), encodePNG(paint(base, 10, 10, 4, 4, [255, 255, 255, 255])));
  writeFileSync(join(after, "new-dark.png"), encodePNG(base));
  writeFileSync(join(after, "odd name-dark.png"), encodePNG(base));
  const { screens, failed } = compareDirectories(before, after, out,
    { prefix: "scenes", beforeErrors: { new: `draw: Unknown value ${"y".repeat(1200)}` } });
  assert.deepEqual(screens.map((screen) => [screen.id, screen.status]),
    [["scenes/moved-dark", "changed"], ["scenes/new-dark", "added"], ["scenes/same-dark", "unchanged"]]);
  const moved = screens[0];
  assert.deepEqual(Object.keys(moved.images).sort(), ["after", "before", "diff"]);
  assert.deepEqual(readdirSync(out).sort(),
    ["scenes~moved-dark-after.png", "scenes~moved-dark-before.png", "scenes~moved-dark-diff.png", "scenes~new-dark-after.png"]);
  // An image smaller than the smallest crop is shown whole.
  const crop = decodePNG(readFileSync(join(out, moved.images.after)));
  assert.deepEqual([crop.width, crop.height], [60, 30]);
  // The trusted half takes messages of at most 1,000 characters.
  assert.match(screens[1].baseError, /^draw: Unknown value y+…$/);
  assert.equal(screens[1].baseError.length, 1000);
  assert.equal(screens[2].images.after, undefined);
  assert.deepEqual(failed, [{ id: "scenes/odd name-dark", error: "Its name may use only letters, digits, dots, dashes and underscores." }]);
});

test("main notes every new scene when the base wrote no scenes report", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  for (const folder of [before, after]) mkdirSync(folder, { recursive: true });
  writeFileSync(join(after, "bar-dark.png"), encodePNG(image(8, 8)));
  writeFileSync(join(after, "scenes.json"), JSON.stringify({ scenes: { bar: { images: ["bar-dark.png"] }, broken: { error: "draw: Unknown value" } } }));
  main([before, after, out, "--prefix", "scenes", "--before-report", join(before, "scenes.json"), "--after-report", join(after, "scenes.json")]);
  const manifest = JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"));
  assert.deepEqual(manifest.screens.map((screen) => [screen.id, screen.status, screen.baseError]),
    [["scenes/bar-dark", "added", "The base build wrote no scenes.json, so it may not draw scenes yet."]]);
  assert.deepEqual(manifest.failed, [{ id: "scenes/broken", error: "draw: Unknown value" }]);
});

test("the command lines run when called through a symbolic link", () => {
  // /tmp on macOS is a link to /private/tmp, and Node names a module by its real path.
  const link = join(mkdtempSync(join(tmpdir(), "scripts-")), "scripts");
  symlinkSync(dirname(fileURLToPath(import.meta.url)), link);
  for (const [script, status] of [["compare-screens.mjs", 1], ["capture-site.mjs", 64]]) {
    const run = spawnSync(process.execPath, [join(link, script)], { encoding: "utf8" });
    assert.equal(run.status, status, script);
    assert.match(run.stderr, /usage: /, script);
  }
});

test("crops give a change context: 48 pixels around it, at least 480 by 160, inside the image", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  for (const folder of [before, after]) mkdirSync(folder, { recursive: true });
  const base = image(600, 300);
  writeFileSync(join(before, "middle-dark.png"), encodePNG(base));
  writeFileSync(join(after, "middle-dark.png"), encodePNG(paint(base, 300, 150, 4, 4, [255, 255, 255, 255])));
  writeFileSync(join(before, "edge-dark.png"), encodePNG(base));
  writeFileSync(join(after, "edge-dark.png"), encodePNG(paint(base, 2, 150, 4, 4, [255, 255, 255, 255])));
  const { screens } = compareDirectories(before, after, out, { prefix: "scenes" });
  const size = (file) => { const { width, height } = decodePNG(readFileSync(join(out, file))); return [width, height]; };
  for (const screen of screens) {
    for (const kind of ["before", "after", "diff"]) assert.deepEqual(size(screen.images[kind]), [480, 160], `${screen.id} ${kind}`);
  }
  // The edge's crop moves inside the image rather than shrinking: its change is at its left.
  const edge = decodePNG(readFileSync(join(out, screens[0].images.after)));
  assert.deepEqual([...edge.rgba.subarray((80 * 480 + 2) * 4, (80 * 480 + 2) * 4 + 4)], [255, 255, 255, 255]);
});

test("a screen of a new height is cropped from its first change, full width", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  for (const folder of [before, after]) mkdirSync(folder, { recursive: true });
  writeFileSync(join(before, "page-dark.png"), encodePNG(image(100, 50)));
  writeFileSync(join(after, "page-dark.png"), encodePNG(image(100, 80)));
  writeFileSync(join(before, "tall-dark.png"), encodePNG(image(10, 2000)));
  writeFileSync(join(after, "tall-dark.png"), encodePNG(paint(image(10, 2100), 0, 100, 10, 2, [255, 255, 255, 255])));
  writeFileSync(join(before, "wide-dark.png"), encodePNG(image(100, 50)));
  writeFileSync(join(after, "wide-dark.png"), encodePNG(image(120, 50)));
  const { screens } = compareDirectories(before, after, out, { prefix: "site" });
  const size = (file) => { const { width, height } = decodePNG(readFileSync(join(out, file))); return [width, height]; };
  const [page, tall, wide] = screens;
  // Rows added from y = 50: the crops start 48 rows above, and run to each image's end.
  assert.deepEqual([page.status, size(page.images.before), size(page.images.after), size(page.images.diff)],
    ["resized", [100, 48], [100, 78], [100, 78]]);
  const diff = decodePNG(readFileSync(join(out, page.images.diff)));
  assert.deepEqual([...diff.rgba.subarray(0, 4)], [12, 12, 12, 255]);
  assert.deepEqual([...diff.rgba.subarray((60 * 100) * 4, (60 * 100) * 4 + 4)], [255, 59, 48, 255]);
  // A long change shows its first 1,600 rows, and says so.
  assert.deepEqual([size(tall.images.before), size(tall.images.after), tall.truncated], [[10, 1600], [10, 1600], true]);
  assert.equal(page.truncated, undefined);
  // A new width can't be lined up: both images are shown whole.
  assert.deepEqual([wide.region, Object.keys(wide.images).sort(), size(wide.images.after)], [null, ["after", "before"], [120, 50]]);
});

test("changed and resized screens carry a digest of their whole after image", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before");
  mkdirSync(before);
  const page = image(10, 2000);
  writeFileSync(join(before, "page-dark.png"), encodePNG(page));
  // Both changes span rows 100 to 1901, and the crop shows rows 52 to 1651.
  const tall = paint(paint(page, 0, 100, 10, 2, [255, 255, 255, 255]), 0, 1900, 10, 2, [255, 255, 255, 255]);
  const runs = [tall, paint(tall, 0, 1800, 10, 2, [255, 255, 255, 255])].map((after) => {
    const folder = join(root, `after-${Math.random()}`), out = join(root, `out-${Math.random()}`);
    mkdirSync(folder);
    writeFileSync(join(folder, "page-dark.png"), encodePNG(after));
    const [screen] = compareDirectories(before, folder, out, { prefix: "site" }).screens;
    return { screen, crop: readFileSync(join(out, screen.images.after)) };
  });
  // A change inside the region but past the crop leaves the crop as it was, but not the digest.
  assert.deepEqual(runs[0].crop, runs[1].crop);
  assert.equal(runs[0].screen.truncated, true);
  assert.match(runs[0].screen.afterDigest, /^[0-9a-f]{64}$/);
  assert.notEqual(runs[0].screen.afterDigest, runs[1].screen.afterDigest);
});

test("main reports images a scenes report lists that weren't drawn", () => {
  const root = mkdtempSync(join(tmpdir(), "screens-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  for (const folder of [before, after]) mkdirSync(folder, { recursive: true });
  writeFileSync(join(before, "bar-dark.png"), encodePNG(image(8, 8)));
  writeFileSync(join(after, "bar-dark.png"), encodePNG(image(8, 8)));
  const report = { scenes: { bar: { images: ["bar-dark.png", "bar-light.png"] } } };
  writeFileSync(join(before, "scenes.json"), JSON.stringify(report));
  writeFileSync(join(after, "scenes.json"), JSON.stringify(report));
  main([before, after, out, "--prefix", "scenes", "--before-report", join(before, "scenes.json"), "--after-report", join(after, "scenes.json")]);
  const manifest = JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"));
  assert.deepEqual(manifest.failed, [{ id: "scenes/bar", error: "scenes.json lists bar-light.png, but it wasn't drawn." }]);
});
