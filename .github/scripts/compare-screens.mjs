// Compares the screens drawn from a pull request (after) with those drawn from its base (before):
//   node compare-screens.mjs BEFORE AFTER OUT --prefix docs [--before-report scenes.json] [--after-report scenes.json]
// It writes cropped before, after and difference images of each changed screen to OUT, and adds the
// screens to OUT/manifest.json: {screens: [{id, status, changedPixels, region, images, afterDigest?,
// truncated?, baseError?}], failed: [{id, error}]}.
// The trusted half of the bot checks that manifest strictly: see readManifest in screens-comment.mjs.
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { pathToFileURL } from "node:url";
import { decodePNG, encodePNG } from "./png.mjs";

/** A pixel changes when one of its channels differs by more than this. */
const noise = 1;
/** Context around a changed region, in image pixels: 24 points at 2×, 16 at 3×. */
const padding = 48;
/** The smallest crop, so a small change still shows what's around it. */
const smallest = { width: 480, height: 160 };
/** A crop's most rows: a long change shows its start. */
const tallest = 1600;
/** The longest message the trusted half takes. */
const maximumMessage = 1000;

const cut = (text, limit) => (text.length <= limit ? text : `${text.slice(0, limit - 1)}…`);
/** A digest of an image's pixels: a changed or resized screen carries its whole after image's, since its crop may show only part. */
const digestOf = ({ width, height, rgba }) => createHash("sha256").update(`${width}x${height}\n`).update(rgba).digest("hex");
/** Image names the bot can show, since they become file and asset names. */
const isPlainName = (name) => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) && !name.includes("..") && name.length <= 80;

/** Which pixels of the top-left `width` by `height` of both images differ. */
function changedMask(before, after, width, height) {
  const mask = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const a = (y * before.width + x) * 4, b = (y * after.width + x) * 4;
      for (let channel = 0; channel < 4; channel++) {
        if (Math.abs(before.rgba[a + channel] - after.rgba[b + channel]) > noise) {
          mask[y * width + x] = 1;
          break;
        }
      }
    }
  }
  return mask;
}

/**
 * How `after` differs from `before`, either of which may be null. A changed pixel with no changed
 * neighbour is noise: it neither makes a screen changed nor widens its region. Screens of one width
 * but new heights are compared from the top: their region runs from the first change, or from where
 * the shorter one ends, to the longer one's end, across the full width. A new width can't be lined up.
 */
export function comparePair(before, after) {
  if (!before) return { status: "added", changedPixels: 0, region: null };
  if (!after) return { status: "removed", changedPixels: 0, region: null };
  if (before.width !== after.width) return { status: "resized", changedPixels: 0, region: null };
  const width = before.width, height = Math.min(before.height, after.height);
  const { changedPixels, region } = significant(changedMask(before, after, width, height), width, height);
  if (before.height === after.height) {
    return changedPixels ? { status: "changed", changedPixels, region } : { status: "unchanged", changedPixels: 0, region: null };
  }
  const longer = Math.max(before.height, after.height), top = region ? region.y : height;
  return { status: "resized", changedPixels: changedPixels + (longer - height) * width, region: { x: 0, y: top, width, height: longer - top } };
}

/** The changed pixels of `mask` that have a changed neighbour, and the region around them. */
function significant(mask, width, height) {
  let changedPixels = 0, minX = width, minY = height, maxX = -1, maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (!mask[y * width + x]) continue;
      let neighbours = 0;
      for (let dy = -1; dy <= 1 && !neighbours; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy;
          if ((dx || dy) && nx >= 0 && ny >= 0 && nx < width && ny < height && mask[ny * width + nx]) {
            neighbours++;
            break;
          }
        }
      }
      if (!neighbours) continue;
      changedPixels++;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
  }
  if (!changedPixels) return { changedPixels: 0, region: null };
  return { changedPixels, region: { x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1 } };
}

/** `region` with `padding` around it, grown to the smallest crop, moved inside `image` and cut to it and to `tallest`. */
function padded(region, image) {
  const span = (start, length, size, minimum) => {
    let from = start - padding, to = start + length + padding;
    if (to - from < minimum) {
      const grow = minimum - (to - from);
      from -= Math.floor(grow / 2);
      to += Math.ceil(grow / 2);
    }
    if (from < 0) {
      to -= from;
      from = 0;
    }
    if (to > size) {
      from = Math.max(0, from - (to - size));
      to = size;
    }
    return [from, to];
  };
  const [x0, x1] = span(region.x, region.width, image.width, smallest.width);
  const [y0, y1] = span(region.y, region.height, image.height, smallest.height);
  return { x: x0, y: y0, width: x1 - x0, height: Math.min(y1, y0 + tallest) - y0, cut: y1 > y0 + tallest };
}

/** The crop of `image` for a screen of a new height: full width, from `padding` above the first change, at most `tallest` rows. */
function resizedCrop(region, image) {
  const y = Math.max(0, region.y - padding);
  return { x: 0, y, width: image.width, height: Math.min(image.height, y + tallest) - y, cut: image.height > y + tallest };
}

/** The part of `image` inside `region`. */
export function crop(image, region) {
  const rgba = new Uint8Array(region.width * region.height * 4);
  for (let row = 0; row < region.height; row++) {
    const start = ((region.y + row) * image.width + region.x) * 4;
    rgba.set(image.rgba.subarray(start, start + region.width * 4), row * region.width * 4);
  }
  return { width: region.width, height: region.height, rgba };
}

/** `after` inside `region`, at 30% brightness, with every changed pixel, and every row `before` doesn't have, red. */
export function differenceImage(before, after, region) {
  const overlap = Math.min(before.height, after.height);
  const mask = changedMask(before, after, after.width, overlap);
  const rgba = new Uint8Array(region.width * region.height * 4);
  for (let row = 0; row < region.height; row++) {
    const y = region.y + row;
    for (let column = 0; column < region.width; column++) {
      const x = region.x + column, source = (y * after.width + x) * 4, target = (row * region.width + column) * 4;
      if (y >= overlap || mask[y * after.width + x]) {
        rgba.set([255, 59, 48, 255], target);
      } else {
        rgba.set([after.rgba[source] * 0.3, after.rgba[source + 1] * 0.3, after.rgba[source + 2] * 0.3, 255], target);
      }
    }
  }
  return { width: region.width, height: region.height, rgba };
}

function read(folder, name) {
  const path = join(folder, name);
  return existsSync(path) ? decodePNG(readFileSync(path)) : null;
}

/** The scene name an image of `name-<appearance>.png` belongs to. */
function sceneName(image) {
  return basename(image, ".png").replace(/-(dark|light)$/, "");
}

/**
 * Compares every PNG in `beforeDir` and `afterDir`, writes the images of changed, added, removed and
 * resized screens to `outDir`, and returns the screens, and as failures the images whose names the
 * bot can't show. `beforeErrors` holds, by scene name, why the base couldn't draw a scene, and
 * `beforeError` why it drew none.
 */
export function compareDirectories(beforeDir, afterDir, outDir, { prefix, beforeErrors = {}, beforeError }) {
  const list = (folder) => (existsSync(folder) ? readdirSync(folder).filter((name) => name.endsWith(".png")) : []);
  const all = [...new Set([...list(beforeDir), ...list(afterDir)])].sort();
  const names = all.filter((name) => isPlainName(basename(name, ".png")));
  const failed = all.filter((name) => !names.includes(name)).map((name) => ({ id: cut(`${prefix}/${basename(name, ".png")}`, 200),
    error: "Its name may use only letters, digits, dots, dashes and underscores." }));
  mkdirSync(outDir, { recursive: true });
  const screens = names.map((name) => {
    const before = read(beforeDir, name), after = read(afterDir, name);
    const id = `${prefix}/${basename(name, ".png")}`;
    const result = comparePair(before, after);
    const file = (kind) => `${id.replaceAll("/", "~")}-${kind}.png`;
    const images = {};
    let truncated = false;
    const save = (kind, image) => {
      writeFileSync(join(outDir, file(kind)), encodePNG(image));
      images[kind] = file(kind);
    };
    if (result.status === "changed") {
      const region = padded(result.region, after);
      save("before", crop(before, region));
      save("after", crop(after, region));
      save("diff", differenceImage(before, after, region));
      truncated = region.cut;
    } else if (result.status === "resized" && result.region) {
      const beforeCrop = resizedCrop(result.region, before), afterCrop = resizedCrop(result.region, after);
      save("before", crop(before, beforeCrop));
      save("after", crop(after, afterCrop));
      save("diff", differenceImage(before, after, afterCrop));
      truncated = beforeCrop.cut || afterCrop.cut;
    } else if (result.status === "resized") {
      save("before", before);
      save("after", after);
    } else if (result.status === "added") {
      save("after", after);
    } else if (result.status === "removed") {
      save("before", before);
    }
    const screen = { id, ...result, images };
    if (result.status === "changed" || result.status === "resized") screen.afterDigest = digestOf(after);
    if (truncated) screen.truncated = true;
    const error = beforeErrors[sceneName(name)] ?? beforeError;
    if (result.status === "added" && error) screen.baseError = cut(error, maximumMessage);
    return screen;
  });
  return { screens, failed };
}

/** The scenes of a scenes.json report `--render-scenes` wrote, by name: `{images}` or `{error}`. */
function scenesOf(report) {
  if (!report || !existsSync(report)) return {};
  return JSON.parse(readFileSync(report, "utf8")).scenes ?? {};
}

/** Scene name to error, from a scenes.json report. */
function errors(report) {
  return Object.fromEntries(Object.entries(scenesOf(report)).filter(([, entry]) => typeof entry?.error === "string" && entry.error)
    .map(([name, entry]) => [name, entry.error]));
}

/** The images a scenes.json report lists that aren't in `folder`, as failures. */
function undrawn(report, folder, prefix) {
  return Object.entries(scenesOf(report)).flatMap(([name, entry]) => (Array.isArray(entry?.images) ? entry.images : [])
    .filter((image) => typeof image !== "string" || !existsSync(join(folder, basename(image))))
    .map((image) => ({ id: cut(`${prefix}/${name}`, 200), error: cut(`scenes.json lists ${image}, but it wasn't drawn.`, maximumMessage) })));
}

export function main(argv) {
  const [beforeDir, afterDir, outDir, ...options] = argv;
  const option = (name) => {
    const index = options.indexOf(name);
    return index >= 0 ? options[index + 1] : undefined;
  };
  const prefix = option("--prefix");
  if (!beforeDir || !afterDir || !outDir || !prefix) {
    throw new Error("usage: compare-screens.mjs BEFORE AFTER OUT --prefix NAME [--before-report FILE] [--after-report FILE]");
  }
  const beforeReport = option("--before-report");
  const beforeError = beforeReport && !existsSync(beforeReport) ? "The base build wrote no scenes.json, so it may not draw scenes yet." : undefined;
  const { screens, failed: unnamed } = compareDirectories(beforeDir, afterDir, outDir, { prefix, beforeErrors: errors(beforeReport), beforeError });
  const afterReport = option("--after-report");
  const failed = [...unnamed, ...Object.entries(errors(afterReport))
    .map(([name, error]) => ({ id: cut(`${prefix}/${name}`, 200), error: cut(error, maximumMessage) })), ...undrawn(afterReport, afterDir, prefix)];
  const manifestPath = join(outDir, "manifest.json");
  const manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, "utf8")) : { screens: [], failed: [] };
  manifest.screens.push(...screens);
  manifest.failed.push(...failed);
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  const changed = screens.filter((screen) => screen.status !== "unchanged").length;
  console.log(`${prefix}: ${screens.length} screens, ${changed} changed, ${failed.length} failed`);
}

// Node names a module by its real path, so the path it was called by is resolved first.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) main(process.argv.slice(2));
