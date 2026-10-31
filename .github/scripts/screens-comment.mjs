// The logic of the before/after screens comment and its Visual review status, for screens.yml. The
// workflow runs the default branch's copy and reads the pull request's artifact only as data: the
// pull request's CI job writes it, so every name and message in it is untrusted. Such text reaches
// the comment only inside code spans, and the comment's data is always its last line.
import { createHash } from "node:crypto";

export const botLogin = "github-actions[bot]";
const marker = "<!-- stablebar-screens -->";
const reviewHeading = "**Visual review:**";
const dataPattern = /\r?\n<!-- stablebar-screens-data (\{[^\r\n]*\}) -->\s*$/;
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const maximumFileSize = 10 * 1024 * 1024;
const maximumManifestSize = 1024 * 1024;
const maximumFiles = 300;
const maximumScreens = 300;
const maximumFailures = 50;
const maximumMessage = 1000;
const maximumProblems = 20;
/** GitHub takes 65,536 characters in a comment. */
const maximumComment = 60000;
const maximumRows = 100;
const maximumListed = 20;
const statuses = ["unchanged", "changed", "resized", "added", "removed"];
/** The images a screen comes with: a resized screen lined up from the top has a region and a difference too. */
const imagesOf = (status, region) => ({ unchanged: [], changed: ["after", "before", "diff"], added: ["after"], removed: ["before"],
  resized: region ? ["after", "before", "diff"] : ["after", "before"] })[status];
const isRegion = (region) => hasOnly(region, ["x", "y", "width", "height"]) && isCount(region.x) && isCount(region.y)
  && isCount(region.width, 1) && isCount(region.height, 1);

const isObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const hasOnly = (value, keys) => isObject(value) && Object.keys(value).every((key) => keys.includes(key));
const isCount = (value, minimum = 0) => Number.isSafeInteger(value) && value >= minimum;
const isMessage = (value, limit = maximumMessage) => typeof value === "string" && value.length > 0 && value.length <= limit;
const isHex = (value, length) => typeof value === "string" && value.length === length && /^[0-9a-f]+$/.test(value);
const isImageName = (name) => /^[A-Za-z0-9][A-Za-z0-9._~-]*\.png$/.test(name) && !name.includes("..") && name.length <= 200;
const isScreenId = (id, prefixes) => typeof id === "string" && prefixes.includes(id.split("/")[0])
  && /^[a-z]+\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id) && !id.includes("..") && id.length <= 100;
/** The name compare-screens.mjs gives a screen's image of one kind. */
const imageOf = (id, kind) => `${id.replaceAll("/", "~")}-${kind}.png`;

/** `text` on one line and at most `limit` characters long. */
function cut(text, limit) {
  const characters = Array.from(String(text ?? "").replace(/\s+/g, " ").trim());
  return characters.length <= limit ? characters.join("") : `${characters.slice(0, limit - 1).join("")}…`;
}

/** Untrusted text as an inline code span: markdown, HTML, links and mentions in it stay plain text. */
const code = (text, limit = 200) => `\`${cut(text, limit).replaceAll("`", "'") || " "}\``;
const entities = { "&": "&amp;", '"': "&quot;", "<": "&lt;", ">": "&gt;" };
const attribute = (value) => String(value).replace(/[&"<>]/g, (character) => entities[character]);
/** The data's JSON, which then holds no "<" or ">" and so can't close its HTML comment early. */
const encodeData = (data) => JSON.stringify(data).replace(/[<>&]/g, (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`);
const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;
const list = (ids, limit) => [...ids.slice(0, limit).map((id) => code(id)), ...(ids.length > limit ? [`and ${ids.length - limit} more`] : [])].join(", ");

/** Checks an artifact's files before anything is read or uploaded: regular files only, PNG images and a small manifest. */
export function validateArtifact(files) {
  const problems = [];
  if (files.length > maximumFiles) problems.push(`${files.length} files, more than ${maximumFiles}.`);
  for (const file of files) {
    const name = code(file.name, 120);
    if (!file.regular) {
      problems.push(`${name}: not a regular file.`);
    } else if (file.name === "manifest.json") {
      if (file.size > maximumManifestSize) problems.push(`${name}: larger than 1 MB.`);
    } else if (!isImageName(file.name)) {
      problems.push(`${name}: not an image name this bot writes.`);
    } else if (!Buffer.from(file.head ?? []).subarray(0, 8).equals(signature)) {
      problems.push(`${name}: not a PNG.`);
    } else if (file.size > maximumFileSize) {
      problems.push(`${name}: larger than 10 MB.`);
    }
  }
  return { ok: problems.length === 0, problems: problems.slice(0, maximumProblems) };
}

function readScreen(screen, where, files, ids, prefixes, problems) {
  if (!hasOnly(screen, ["id", "status", "changedPixels", "region", "images", "afterDigest", "truncated", "baseError"])) {
    problems.push(`${where} isn't a screen as compare-screens.mjs writes it.`);
    return null;
  }
  if (!isScreenId(screen.id, prefixes)) problems.push(`${where}: its id isn't ${prefixes.map((prefix) => `${prefix}/`).join(" or ")} followed by a plain name.`);
  else if (ids.has(screen.id)) problems.push(`${where}: ${code(screen.id)} is listed twice.`);
  ids.add(screen.id);
  if (!statuses.includes(screen.status)) {
    problems.push(`${where}: its status isn't one of ${statuses.join(", ")}.`);
    return null;
  }
  if (!isCount(screen.changedPixels)) problems.push(`${where}: changedPixels isn't a count.`);
  const { region } = screen;
  const regionFits = screen.status === "changed" ? isRegion(region) : screen.status === "resized" ? region === null || isRegion(region) : region === null;
  if (!regionFits) problems.push(`${where}: its region doesn't fit its status.`);
  const kinds = imagesOf(screen.status, regionFits && region !== null);
  if (!hasOnly(screen.images, kinds) || Object.keys(screen.images).length !== kinds.length) {
    problems.push(`${where}: a screen that is ${screen.status} comes with ${kinds.length ? kinds.join(", ") : "no images"}.`);
  } else {
    for (const kind of kinds) {
      const file = screen.images[kind];
      if (typeof screen.id !== "string" || file !== imageOf(screen.id, kind)) problems.push(`${where}: its ${kind} image isn't named after it.`);
      else if (!isImageName(file) || !files.has(file)) problems.push(`${where}: its ${kind} image isn't in the artifact.`);
    }
  }
  if (screen.baseError !== undefined && !isMessage(screen.baseError)) problems.push(`${where}: baseError isn't a message of at most ${maximumMessage} characters.`);
  const cropped = screen.status === "changed" || screen.status === "resized";
  if (cropped ? !isHex(screen.afterDigest, 64) : screen.afterDigest !== undefined) problems.push(`${where}: afterDigest doesn't fit its status.`);
  if (screen.truncated !== undefined && typeof screen.truncated !== "boolean") problems.push(`${where}: truncated isn't true or false.`);
  return {
    id: screen.id, status: screen.status, changedPixels: screen.changedPixels,
    region: regionFits && region !== null ? { x: region.x, y: region.y, width: region.width, height: region.height } : null,
    images: Object.fromEntries(kinds.map((kind) => [kind, screen.images?.[kind]])),
    ...(cropped ? { afterDigest: screen.afterDigest } : {}),
    ...(screen.truncated === true ? { truncated: true } : {}),
    ...(screen.baseError === undefined ? {} : { baseError: screen.baseError }),
  };
}

/**
 * The screens and failures of an artifact's manifest.json, or why it can't be used. `names` are the
 * artifact's files, and `prefixes` the kinds of screens it may hold. Only known fields come back, and
 * every image a screen names is one of those files, named after the screen.
 */
export function readManifest(text, names, prefixes = ["docs", "scenes", "site"]) {
  const invalid = (problems) => ({ ok: false, problems: problems.slice(0, maximumProblems), screens: [], failed: [] });
  let manifest = null;
  try {
    manifest = JSON.parse(text);
  } catch {
    return invalid(["manifest.json isn't JSON."]);
  }
  if (!hasOnly(manifest, ["screens", "failed"]) || !Array.isArray(manifest.screens) || !Array.isArray(manifest.failed)) {
    return invalid(["manifest.json isn't a list of screens and failures."]);
  }
  if (manifest.screens.length > maximumScreens) return invalid([`manifest.json lists more than ${maximumScreens} screens.`]);
  if (manifest.failed.length > maximumFailures) return invalid([`manifest.json lists more than ${maximumFailures} failures.`]);
  const problems = [], files = new Set(names), ids = new Set();
  const screens = manifest.screens.map((screen, index) => readScreen(screen, `Screen ${index + 1}`, files, ids, prefixes, problems));
  const failed = manifest.failed.map((entry, index) => {
    if (hasOnly(entry, ["id", "error"]) && isMessage(entry.id, 300) && isMessage(entry.error)) return { id: entry.id, error: entry.error };
    problems.push(`Failure ${index + 1} isn't an id and a message of at most ${maximumMessage} characters.`);
    return null;
  });
  return problems.length > 0 ? invalid(problems) : { ok: true, problems: [], screens, failed };
}

/**
 * What a maintainer approves with visual-ok: each changed screen with its status, the image the
 * comment shows of it, its after image or, once removed, its before image, the digest of its whole
 * after image, since a crop may show only part of a change, and every failure. `digest(file)` is the
 * bot's own digest of an image it uploads; the whole image's digest comes from the pull request's CI,
 * which decides its screens anyway. Order doesn't matter.
 */
export function fingerprint({ screens = [], failed = [] }, digest) {
  const entries = [
    ...screens.filter((screen) => screen.status !== "unchanged")
      .map((screen) => ["screen", screen.id, screen.status, digest(screen.images.after ?? screen.images.before), screen.afterDigest ?? null]),
    ...failed.map((entry) => ["failed", entry.id, entry.error]),
  ].map((entry) => JSON.stringify(entry)).sort();
  return createHash("sha256").update(JSON.stringify(entries)).digest("hex");
}

/** What the status needs to know of a run's screens, kept in the comment's data for label events. */
export function summary(screens, failed) {
  return { total: screens.length, changed: screens.filter((screen) => screen.status !== "unchanged").length, failed: failed.length,
    failure: failed.length > 0 ? cut(`${failed[0].id}: ${failed[0].error}`, 140) : null };
}

/**
 * The Visual review status, from a run's summary: success when nothing needs a look or a maintainer
 * approved this exact fingerprint with visual-ok, pending while changed screens wait for one, failure
 * when drawing failed. `removeLabel` asks to take visual-ok off when it approved something else.
 */
export function reviewState({ ranScreens, total = 0, changed = 0, failed = 0, failure = null, labels = [], approved = null, fingerprint: current = null }) {
  if (!ranScreens) return { state: "success", description: "No screens to compare.", removeLabel: false };
  const labelled = labels.includes("visual-ok");
  const valid = labelled && approved !== null && approved === current;
  if (failed > 0) {
    if (valid) return { state: "success", description: `Approved with visual-ok although ${plural(failed, "screen")} failed to draw.`, removeLabel: false };
    return { state: "failure", description: cut(`Drawing the screens failed: ${failure ?? "see the comment."}`, 140), removeLabel: labelled };
  }
  if (changed === 0) return { state: "success", description: `${plural(total, "screen")}, none changed.`, removeLabel: false };
  if (valid) return { state: "success", description: `${plural(changed, "changed screen")} approved.`, removeLabel: false };
  return { state: "pending", description: `${plural(changed, "screen")} changed: a maintainer adds visual-ok after looking.`, removeLabel: labelled };
}

function describe(screen) {
  switch (screen.status) {
    case "changed": {
      const { x, y, width, height } = screen.region;
      return [`${screen.changedPixels.toLocaleString("en-US")} pixels`, `${x},${y} · ${width}×${height}`];
    }
    case "added": return ["new", "the whole screen"];
    case "removed": return ["removed", "the whole screen"];
    case "resized": {
      if (!screen.region) return ["new size", "the whole screen"];
      const { x, y, width, height } = screen.region;
      return [`${screen.changedPixels.toLocaleString("en-US")} pixels, new size`, `${x},${y} · ${width}×${height}`];
    }
    default: return ["", ""];
  }
}

function section(screen, imageURL) {
  const image = (file, label) => `<img src="${attribute(imageURL(file))}" alt="${label}">`;
  const lines = [`#### ${code(screen.id)}`];
  if (screen.baseError) lines.push("", `The base couldn't draw this scene: ${code(screen.baseError, 300)}`);
  if (screen.truncated) lines.push("", "The images show the first 1,600 rows of this change.");
  const { before, after, diff } = screen.images;
  if (before && after) {
    lines.push("", "| Before | After |", "| --- | --- |", `| ${image(before, "Before")} | ${image(after, "After")} |`);
  } else if (after) {
    lines.push("", image(after, "After"));
  } else if (before) {
    lines.push("", image(before, "Before"));
  }
  if (diff) lines.push("", "Difference, changed pixels in red:", "", image(diff, "Difference"));
  lines.push("");
  return lines.join("\n");
}

/** The review line, which shows no untrusted text, and the data. */
function reviewSection(review, data) {
  const lines = [`${reviewHeading} ${review.state === "failure" ? "Drawing the screens failed, see “Couldn't draw” above." : review.description}`];
  if (review.removeLabel) lines.push("", "`visual-ok` was taken off: it approved other screens than these.");
  lines.push("", `<!-- stablebar-screens-data ${encodeData(data)} -->`);
  return lines.join("\n");
}

/**
 * The comment: changed screens with their images, unchanged ones folded, failures, the review line and
 * the data. When it would be too long for GitHub, the last changed screens lose their images.
 */
export function commentBody({ baseRef = "main", base, head, screens, failed = [], imageURL, review, data }) {
  const changed = screens.filter((screen) => screen.status !== "unchanged");
  const unchanged = screens.filter((screen) => screen.status === "unchanged");
  const sections = changed.map((screen) => section(screen, imageURL));
  const assemble = (shown) => {
    const lines = [marker, "### Before and after", "", `${code(baseRef, 100)} at ${base.slice(0, 7)} → this pull request at ${head.slice(0, 7)}`
      + ` · ${plural(screens.length, "screen")} drawn in one CI job · ${changed.length} changed`, ""];
    if (changed.length > 0) {
      lines.push("| Screen | Change | Where (image pixels) |", "| --- | --- | --- |");
      for (const screen of changed.slice(0, maximumRows)) lines.push(`| ${code(screen.id)} | ${describe(screen).join(" | ")} |`);
      if (changed.length > maximumRows) lines.push("", `${changed.length - maximumRows} more changed screens aren't in the table.`);
      lines.push("", ...sections.slice(0, shown));
      if (shown < changed.length) {
        lines.push(`Not shown, to keep this comment under GitHub's size limit: ${list(changed.slice(shown).map((screen) => screen.id), maximumRows)}.`, "");
      }
    }
    if (unchanged.length > 0) {
      lines.push(`<details><summary>${plural(unchanged.length, "unchanged screen")}</summary>`, "",
        list(unchanged.map((screen) => screen.id), 2 * maximumRows), "", "</details>", "");
    }
    if (failed.length > 0) {
      lines.push("**Couldn't draw:**", "", ...failed.slice(0, maximumListed).map((entry) => `- ${code(entry.id)}: ${code(entry.error, 300)}`));
      if (failed.length > maximumListed) lines.push(`- and ${failed.length - maximumListed} more`);
      lines.push("");
    }
    lines.push(reviewSection(review, data));
    return lines.join("\n");
  };
  let shown = sections.length;
  let body = assemble(shown);
  while (body.length > maximumComment && shown > 0) body = assemble(--shown);
  return body;
}

/** A comment without screens: why there are none, which is the bot's own text, the review line and the data. */
export function noScreensBody({ reason, review, data }) {
  return [marker, "### Before and after", "", reason, "", reviewSection(review, data)].join("\n");
}

/** `body` with a new review line and data, for label events, which don't draw anything. */
export function withReview(body, review, data) {
  const start = body.lastIndexOf(`\n${reviewHeading} `);
  return `${start >= 0 ? body.slice(0, start + 1) : `${body.trimEnd()}\n\n`}${reviewSection(review, data)}`;
}

function isData(data) {
  return hasOnly(data, ["head", "base", "ranScreens", "fingerprint", "approved", "total", "changed", "failed", "failure"])
    && isHex(data.head, 40) && (data.base === null || isHex(data.base, 40)) && typeof data.ranScreens === "boolean"
    && (data.fingerprint === null || isHex(data.fingerprint, 64)) && (data.approved === null || isHex(data.approved, 64))
    && isCount(data.total) && isCount(data.changed) && isCount(data.failed)
    && (data.failure === null || (typeof data.failure === "string" && data.failure.length <= 300));
}

/** The data on the last line of a comment from commentBody, or null. */
export function readData(body) {
  const match = dataPattern.exec(body ?? "");
  if (!match) return null;
  try {
    const data = JSON.parse(match[1]);
    return isData(data) ? data : null;
  } catch {
    return null;
  }
}

export const isScreensComment = (body) => (body ?? "").startsWith(marker);

/** The bot's screens comment among a pull request's comments. Anyone can post the marker; only the bot's comment counts. */
export function findScreensComment(comments) {
  return comments.find((comment) => comment.user?.login === botLogin && isScreensComment(comment.body)) ?? null;
}

/** The name of an uploaded image: the pull request and head commit, then the file. */
export const assetName = (pr, sha, file) => `pr${pr}-${sha.slice(0, 7)}-${file}`;

/** The pre-release that holds a month's images. */
export const releaseTag = (date) => `pr-previews-${date.toISOString().slice(0, 7)}`;

/** A pull request's images. GitHub may rename the rest of an asset's name, but not this prefix. */
export const pullRequestAssets = (assets, pr) => assets.filter((asset) => asset.name.startsWith(`pr${pr}-`));

/** A pull request's images of other heads than `sha`. */
export const staleAssets = (assets, pr, sha) => pullRequestAssets(assets, pr).filter((asset) => !asset.name.startsWith(assetName(pr, sha, "")));
