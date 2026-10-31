import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { comparePair, compareDirectories } from "./compare-screens.mjs";
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
  assert.equal(comparePair(base, image(21, 10)).status, "resized");
  assert.equal(comparePair(null, base).status, "added");
  assert.equal(comparePair(base, null).status, "removed");
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
  const crop = decodePNG(readFileSync(join(out, moved.images.after)));
  // The 4-pixel square at x = 10 gets 24 pixels of padding, cut at the left edge: from 0 to 10 + 4 + 24.
  assert.equal(crop.width, 38);
  // The trusted half takes messages of at most 1,000 characters.
  assert.match(screens[1].baseError, /^draw: Unknown value y+…$/);
  assert.equal(screens[1].baseError.length, 1000);
  assert.equal(screens[2].images.after, undefined);
  assert.deepEqual(failed, [{ id: "scenes/odd name-dark", error: "Its name may use only letters, digits, dots, dashes and underscores." }]);
});
