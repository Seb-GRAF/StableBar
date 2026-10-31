// The logic of the before/after screens comment and its Visual review status, for screens.yml. The
// workflow runs the default branch's copy and reads the pull request's artifact only as data.
import { createHash } from "node:crypto";

const marker = "<!-- stablebar-screens -->";
const dataPattern = /<!-- stablebar-screens-data (\{.*?\}) -->/s;
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const maximumFileSize = 10 * 1024 * 1024;
const maximumFiles = 300;

/** Checks an artifact's files before anything is uploaded: only the manifest and PNG images, small enough. */
export function validateArtifact(files) {
  const problems = [];
  if (files.length > maximumFiles) problems.push(`${files.length} files, more than ${maximumFiles}.`);
  for (const file of files) {
    if (file.name === "manifest.json") continue;
    if (!/^[A-Za-z0-9][A-Za-z0-9._~-]*\.png$/.test(file.name) || file.name.includes("..")) {
      problems.push(`${file.name}: not an image name this bot writes.`);
    } else if (!Buffer.from(file.head ?? []).subarray(0, 8).equals(signature)) {
      problems.push(`${file.name}: not a PNG.`);
    } else if (file.size > maximumFileSize) {
      problems.push(`${file.name}: larger than 10 MB.`);
    }
  }
  return { ok: problems.length === 0, problems };
}

/** One value for the changed screens and their after images, whatever their order. */
export function fingerprint(changed) {
  const lines = changed.map(({ id, afterSha256 }) => `${id} ${afterSha256}`).sort();
  return createHash("sha256").update(lines.join("\n")).digest("hex");
}

const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;
/** A commit status description holds at most 140 characters. */
const fit = (text) => (text.length <= 140 ? text : `${text.slice(0, 139)}…`);

/**
 * The Visual review status: success when nothing needs a look or a maintainer approved these exact
 * screens with visual-ok, pending while changed screens wait for one, failure when drawing failed.
 * `removeLabel` asks to take visual-ok off when it approved other screens than these.
 */
export function reviewState({ ranScreens, screens = [], failed = [], labels = [], approved, fingerprint: current }) {
  if (!ranScreens) return { state: "success", description: "No screens to compare.", removeLabel: false };
  const changed = screens.filter((screen) => screen.status !== "unchanged");
  const labelled = labels.includes("visual-ok");
  const valid = labelled && approved != null && approved === current;
  if (failed.length > 0) {
    if (valid) return { state: "success", description: fit(`Approved with visual-ok although ${plural(failed.length, "screen")} failed to draw.`), removeLabel: false };
    return { state: "failure", description: fit(`Drawing the screens failed: ${failed[0].id}: ${failed[0].error}`), removeLabel: labelled };
  }
  if (changed.length === 0) return { state: "success", description: `${plural(screens.length, "screen")}, none changed.`, removeLabel: false };
  if (valid) return { state: "success", description: `${plural(changed.length, "changed screen")} approved.`, removeLabel: false };
  return { state: "pending", description: `${plural(changed.length, "screen")} changed: a maintainer adds visual-ok after looking.`,
    removeLabel: labelled };
}

function describe(screen) {
  switch (screen.status) {
    case "changed": {
      const { x, y, width, height } = screen.region;
      return [`${screen.changedPixels.toLocaleString("en-US")} pixels`, `${x},${y} · ${width}×${height}`];
    }
    case "added": return ["new", "the whole screen"];
    case "removed": return ["removed", "the whole screen"];
    case "resized": return ["new size", "the whole screen"];
    default: return ["", ""];
  }
}

/** The comment: changed screens with their images, unchanged ones folded, failures, the status and its data. */
export function commentBody({ base, head, screens, failed = [], imageURL, review, data }) {
  const changed = screens.filter((screen) => screen.status !== "unchanged");
  const unchanged = screens.filter((screen) => screen.status === "unchanged");
  const image = (file, label) => `<img src="${imageURL(file)}" alt="${label}">`;
  const lines = [marker, "### Before and after", "",
    `\`main\` at ${base.slice(0, 7)} → this pull request at ${head.slice(0, 7)} · ${plural(screens.length, "screen")} drawn in one CI job · ${changed.length} changed`, ""];
  if (changed.length > 0) {
    lines.push("| Screen | Change | Where (pixels at 2×) |", "| --- | --- | --- |");
    for (const screen of changed) lines.push(`| \`${screen.id}\` | ${describe(screen).join(" | ")} |`);
    lines.push("");
    for (const screen of changed) {
      lines.push(`#### \`${screen.id}\``);
      if (screen.note) lines.push("", screen.note);
      const { before, after, diff } = screen.images;
      if (before && after) {
        lines.push("", "| Before | After |", "| --- | --- |", `| ${image(before, "Before")} | ${image(after, "After")} |`);
      } else if (after) {
        lines.push("", image(after, "After"));
      } else if (before) {
        lines.push("", image(before, "Before"));
      }
      if (diff) lines.push("", `Difference, changed pixels in red:`, "", image(diff, "Difference"));
      lines.push("");
    }
  }
  if (unchanged.length > 0) {
    lines.push(`<details><summary>${plural(unchanged.length, "unchanged screen")}</summary>`, "",
      unchanged.map((screen) => `\`${screen.id}\``).join(", "), "", "</details>", "");
  }
  if (failed.length > 0) {
    lines.push("**Couldn't draw:**", "", ...failed.map((entry) => `- \`${entry.id}\`: ${entry.error}`), "");
  }
  lines.push(`**Visual review:** ${review.description}`, "", `<!-- stablebar-screens-data ${JSON.stringify(data)} -->`);
  return lines.join("\n");
}

/** The data a comment from commentBody carries, or null. */
export function readData(body) {
  const match = dataPattern.exec(body ?? "");
  if (!match) return null;
  try {
    return JSON.parse(match[1]);
  } catch {
    return null;
  }
}

export const isScreensComment = (body) => (body ?? "").startsWith(marker);

/** The name of an uploaded image: the pull request and head commit, then the file. */
export const assetName = (pr, sha, file) => `pr${pr}-${sha.slice(0, 7)}-${file}`;

/** The pre-release that holds a month's images. */
export const releaseTag = (date) => `pr-previews-${date.toISOString().slice(0, 7)}`;
