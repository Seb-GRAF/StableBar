// Compares the screens drawn from a pull request (after) with those drawn from its base (before):
//   node compare-screens.mjs BEFORE AFTER OUT --prefix docs [--before-report scenes.json] [--after-report scenes.json]
// It writes cropped before, after and difference images of each changed screen to OUT, and adds the
// screens to OUT/manifest.json: {screens: [{id, status, changedPixels, region, images, baseError?}], failed: [{id, error}]}.
// The trusted half of the bot checks that manifest strictly: see readManifest in screens-comment.mjs.
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { pathToFileURL } from "node:url";
import { decodePNG, encodePNG } from "./png.mjs";

/** A pixel changes when one of its channels differs by more than this. */
const noise = 1;
/** Points of context around a changed region, at the renders' 2× scale. */
const padding = 24;
/** The longest message the trusted half takes. */
const maximumMessage = 1000;

const cut = (text, limit) => (text.length <= limit ? text : `${text.slice(0, limit - 1)}…`);
/** Image names the bot can show, since they become file and asset names. */
const isPlainName = (name) => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) && !name.includes("..") && name.length <= 80;

function changedMask(before, after) {
  const mask = new Uint8Array(before.width * before.height);
  for (let index = 0; index < mask.length; index++) {
    for (let channel = 0; channel < 4; channel++) {
      if (Math.abs(before.rgba[index * 4 + channel] - after.rgba[index * 4 + channel]) > noise) {
        mask[index] = 1;
        break;
      }
    }
  }
  return mask;
}

/**
 * How `after` differs from `before`, either of which may be null. A changed pixel with no changed
 * neighbour is noise: it neither makes a screen changed nor widens its region.
 */
export function comparePair(before, after) {
  if (!before) return { status: "added", changedPixels: 0, region: null };
  if (!after) return { status: "removed", changedPixels: 0, region: null };
  if (before.width !== after.width || before.height !== after.height) return { status: "resized", changedPixels: 0, region: null };
  const { width, height } = before;
  const mask = changedMask(before, after);
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
  if (!changedPixels) return { status: "unchanged", changedPixels: 0, region: null };
  return { status: "changed", changedPixels, region: { x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1 } };
}

function padded(region, image) {
  const x = Math.max(0, region.x - padding), y = Math.max(0, region.y - padding);
  return {
    x, y,
    width: Math.min(image.width, region.x + region.width + padding) - x,
    height: Math.min(image.height, region.y + region.height + padding) - y,
  };
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

/** `after` at 30% brightness with every changed pixel red, inside `region`. */
export function differenceImage(before, after, region) {
  const mask = changedMask(before, after);
  const rgba = new Uint8Array(after.rgba.length);
  for (let index = 0; index < mask.length; index++) {
    if (mask[index]) {
      rgba.set([255, 59, 48, 255], index * 4);
    } else {
      rgba.set([after.rgba[index * 4] * 0.3, after.rgba[index * 4 + 1] * 0.3, after.rgba[index * 4 + 2] * 0.3, 255], index * 4);
    }
  }
  return crop({ width: after.width, height: after.height, rgba }, region);
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
    const save = (kind, image) => {
      writeFileSync(join(outDir, file(kind)), encodePNG(image));
      images[kind] = file(kind);
    };
    if (result.status === "changed") {
      const region = padded(result.region, after);
      save("before", crop(before, region));
      save("after", crop(after, region));
      save("diff", differenceImage(before, after, region));
    } else if (result.status === "resized") {
      save("before", before);
      save("after", after);
    } else if (result.status === "added") {
      save("after", after);
    } else if (result.status === "removed") {
      save("before", before);
    }
    const screen = { id, ...result, images };
    const error = beforeErrors[sceneName(name)] ?? beforeError;
    if (result.status === "added" && error) screen.baseError = cut(error, maximumMessage);
    return screen;
  });
  return { screens, failed };
}

/** Scene name to error, from a scenes.json report `--render-scenes` wrote. */
function errors(report) {
  if (!report || !existsSync(report)) return {};
  const scenes = JSON.parse(readFileSync(report, "utf8")).scenes ?? {};
  return Object.fromEntries(Object.entries(scenes).filter(([, entry]) => typeof entry?.error === "string" && entry.error)
    .map(([name, entry]) => [name, entry.error]));
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
  const failed = [...unnamed, ...Object.entries(errors(option("--after-report")))
    .map(([name, error]) => ({ id: cut(`${prefix}/${name}`, 200), error: cut(error, maximumMessage) }))];
  const manifestPath = join(outDir, "manifest.json");
  const manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, "utf8")) : { screens: [], failed: [] };
  manifest.screens.push(...screens);
  manifest.failed.push(...failed);
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  const changed = screens.filter((screen) => screen.status !== "unchanged").length;
  console.log(`${prefix}: ${screens.length} screens, ${changed} changed, ${failed.length} failed`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main(process.argv.slice(2));
