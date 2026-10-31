// The GitHub side of the before/after screens, for screens.yml, which runs the default branch's copy.
// It finds the pull request a CI run drew screens for, uploads their images to a monthly pre-release,
// writes the comment, sets the Visual review status, and handles visual-ok and closed pull requests.
// The artifacts come from the pull request's own CI jobs, so they are read as untrusted data.
import { closeSync, existsSync, lstatSync, openSync, readFileSync, readSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { validateArtifact, readManifest, fingerprint, summary, reviewState, commentBody, withReview, noScreensBody, readData,
  findScreensComment, assetName, releaseTag, staleAssets, pullRequestAssets } from "./screens-comment.mjs";
import { decodePNG, encodePNG } from "./png.mjs";

const statusContext = "Visual review";
const approval = "visual-ok";
/** The CI jobs the screens depend on, by the names they show. */
const jobNames = { current: "Check revision", build: "Build release", app: "Draw screens", site: "Draw website screens" };
/** Each kind of screens: its artifact, the ids it may hold, the screens it always has, and the jobs it needs. */
const kinds = {
  app: { artifact: "screens-app", prefixes: ["docs", "scenes"], always: { prefix: "docs", name: "docs images" }, needs: ["current", "build"] },
  site: { artifact: "screens-site", prefixes: ["site"], always: { prefix: "site", name: "website screens" }, needs: ["current"] },
};
const broken = ["failure", "cancelled", "timed_out", "missing"];
/**
 * The files whose changes call for each kind of screens: the patterns CI's Check revision job greps
 * for its screens and site outputs. A test keeps them the same. The bot reads the pull request's
 * files from GitHub, so a run whose job graph skips or drops a screens job can't pass as having none.
 */
export const changePatterns = {
  app: /^(Sources\/|Resources\/|Package\.(swift|resolved)$|scripts\/|scenes\/|examples\/|\.github\/workflows\/ci\.yml$|\.github\/scripts\/(png|compare-screens)\.mjs$)/,
  site: /^(site\/|\.github\/workflows\/ci\.yml$|\.github\/scripts\/(png|compare-screens|capture-site)\.mjs$)/,
};

/**
 * The pull request a completed CI run drew screens for, with what its jobs did, which artifacts it
 * uploaded and which screens its changed files call for, or null when the run isn't CI's for an open
 * pull request's current head. A fork's run lists no pull requests, so it is found by its head branch
 * and commit. A job the run doesn't have is "missing".
 */
export async function findRun({ github, context }) {
  const { owner, repo } = context.repo;
  const run = context.payload.workflow_run;
  if (run.event !== "pull_request" || run.path !== ".github/workflows/ci.yml" || !run.head_repository) return null;
  let numbers = run.pull_requests.map((pr) => pr.number);
  if (numbers.length === 0) {
    const pulls = await github.paginate(github.rest.pulls.list,
      { owner, repo, state: "open", head: `${run.head_repository.owner.login}:${run.head_branch}`, per_page: 100 });
    numbers = pulls.map((pr) => pr.number);
  }
  for (const number of numbers) {
    const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number: number });
    if (pr.state !== "open" || pr.head.sha !== run.head_sha) continue;
    const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, { owner, repo, run_id: run.id, filter: "latest", per_page: 100 });
    const uploaded = (await github.paginate(github.rest.actions.listWorkflowRunArtifacts, { owner, repo, run_id: run.id, per_page: 100 }))
      .map((artifact) => artifact.name);
    const files = (await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number: number, per_page: 100 }))
      .flatMap((file) => [file.filename, file.previous_filename].filter(Boolean));
    return {
      number, head: run.head_sha, runId: run.id,
      jobs: Object.fromEntries(Object.entries(jobNames).map(([key, name]) => [key, jobs.find((job) => job.name === name)?.conclusion ?? "missing"])),
      artifacts: Object.fromEntries(Object.entries(kinds).map(([kind, { artifact }]) => [kind, uploaded.includes(artifact)])),
      expected: Object.fromEntries(Object.keys(kinds).map((kind) => [kind, files.some((file) => changePatterns[kind].test(file))])),
    };
  }
  return null;
}

/** A digest of an image's pixels, the same for any encoding of them. */
const pixelDigest = ({ width, height, rgba }) => createHash("sha256").update(`${width}x${height}\n`).update(rgba).digest("hex");

/**
 * The screens, failures and images of a downloaded artifact folder, checked as untrusted data. Every
 * image its screens name is decoded within limits and encoded again, so only the bot's own PNGs are
 * uploaded: `files` maps each name to `{data, digest}`, the digest being of the pixels.
 */
export function readArtifact(folder, prefixes, always) {
  if (!existsSync(folder)) return { ok: false, problems: ["It couldn't be downloaded."] };
  const files = readdirSync(folder).map((name) => {
    const path = join(folder, name);
    const stat = lstatSync(path);
    const head = Buffer.alloc(8);
    if (stat.isFile()) {
      const descriptor = openSync(path, "r");
      try {
        readSync(descriptor, head, 0, 8, 0);
      } finally {
        closeSync(descriptor);
      }
    }
    return { name, path, size: stat.size, head, regular: stat.isFile() };
  });
  const checked = validateArtifact(files);
  if (!checked.ok) return checked;
  const manifest = files.find((file) => file.name === "manifest.json");
  if (!manifest) return { ok: false, problems: ["It has no manifest.json."] };
  const read = readManifest(readFileSync(manifest.path, "utf8"), files.map((file) => file.name), prefixes);
  if (!read.ok) return read;
  // A job that drew nothing, or not what it always draws, failed even if it says it didn't.
  if (read.screens.length === 0 && read.failed.length === 0) return { ok: false, problems: ["It holds no screens."] };
  if (always && !read.screens.some((screen) => screen.id.startsWith(`${always.prefix}/`))) return { ok: false, problems: [`It holds no ${always.name}.`] };
  const images = new Map();
  for (const name of new Set(read.screens.flatMap((screen) => Object.values(screen.images)))) {
    let image;
    try {
      image = decodePNG(readFileSync(join(folder, name)));
    } catch (error) {
      return { ok: false, problems: [`\`${name}\` isn't a PNG the bot can read: ${error.message}`] };
    }
    images.set(name, { data: encodePNG(image), digest: pixelDigest(image) });
  }
  return { ...read, files: images };
}

const comments = (github, owner, repo, number) =>
  github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: number, per_page: 100 });
const labelsOf = async (github, owner, repo, number) =>
  (await github.paginate(github.rest.issues.listLabelsOnIssue, { owner, repo, issue_number: number, per_page: 100 })).map((label) => label.name);

async function setStatus({ github, owner, repo, sha, review, url }) {
  await github.rest.repos.createCommitStatus({ owner, repo, sha, state: review.state, context: statusContext, description: review.description,
    ...(url ? { target_url: url } : {}) });
}

/** This month's pre-release for the images, created when missing, never as the latest release. */
async function previewRelease({ github, owner, repo, target }) {
  const tag = releaseTag(new Date());
  const find = async () => (await github.rest.repos.getReleaseByTag({ owner, repo, tag })).data;
  try {
    return await find();
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  try {
    return (await github.rest.repos.createRelease({ owner, repo, tag_name: tag, target_commitish: target, name: `Pull request screens, ${tag.slice(12)}`,
      prerelease: true, make_latest: "false",
      body: "Images for the before and after screens the bot posts on pull requests. An unmerged pull request's images are deleted when it closes." })).data;
  } catch (error) {
    if (error.status === 422) return find();
    throw error;
  }
}

/** Uploads `images`, [file, PNG data] pairs, and returns each file's URL as GitHub answers it. A rerun of a head replaces its images. */
async function upload({ github, owner, repo, number, head, target, images }) {
  const urls = new Map();
  if (images.length === 0) return urls;
  const release = await previewRelease({ github, owner, repo, target });
  const assets = await github.paginate(github.rest.repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
  for (const asset of pullRequestAssets(assets, number).filter((entry) => entry.name.startsWith(assetName(number, head, "")))) {
    await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: asset.id });
  }
  for (const [file, data] of images) {
    const { data: asset } = await github.rest.repos.uploadReleaseAsset({ owner, repo, release_id: release.id, name: assetName(number, head, file), data,
      headers: { "content-type": "image/png", "content-length": data.length } });
    urls.set(file, asset.browser_download_url);
  }
  return urls;
}

/** Deletes the images `pick` chooses from every pull request screens pre-release, and counts them. */
async function deleteAssets({ github, owner, repo, pick }) {
  const releases = (await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 }))
    .filter((release) => release.tag_name.startsWith("pr-previews-"));
  let deleted = 0;
  for (const release of releases) {
    const assets = await github.paginate(github.rest.repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
    for (const asset of pick(assets)) {
      await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: asset.id });
      deleted++;
    }
  }
  return deleted;
}

/** What the run's jobs and artifacts give: the screens, the failures, the image files and whether any screens were drawn. */
function gather(run, folders) {
  const screens = [], failed = [], files = new Map();
  let ranScreens = false;
  for (const [kind, { artifact, prefixes, always, needs }] of Object.entries(kinds)) {
    const conclusion = run.jobs[kind];
    if (conclusion === "missing") {
      ranScreens = true;
      failed.push({ id: kind, error: `${jobNames[kind]} is missing from this CI run.` });
      continue;
    }
    if (conclusion === "skipped") {
      const blocker = needs.find((job) => broken.includes(run.jobs[job]));
      if (blocker) {
        ranScreens = true;
        failed.push({ id: kind, error: `${jobNames[blocker]} ${run.jobs[blocker] === "missing" ? "is missing" : `ended with ${run.jobs[blocker]}`}, so ${jobNames[kind]} didn't run.` });
      } else if (run.expected[kind]) {
        ranScreens = true;
        failed.push({ id: kind, error: `${jobNames[kind]} was skipped, but this pull request changes what it draws.` });
      }
      continue;
    }
    ranScreens = true;
    if (conclusion !== "success") {
      failed.push({ id: kind, error: `${jobNames[kind]} ended with ${conclusion}.` });
      continue;
    }
    const read = run.artifacts[kind] ? readArtifact(folders[kind] ?? "", prefixes, always) : { ok: false, problems: ["The job uploaded none."] };
    if (!read.ok) {
      failed.push({ id: kind, error: `The ${artifact} artifact can't be used: ${read.problems.join(" ")}` });
      continue;
    }
    screens.push(...read.screens);
    failed.push(...read.failed);
    for (const [name, image] of read.files) files.set(name, image);
  }
  return { screens, failed, files, ranScreens };
}

/**
 * Publishes a run from findRun: uploads the images of its changed screens, writes or rewrites the
 * comment, sets the status on its head, takes visual-ok off when it approved other screens, and then
 * deletes the images of the pull request's other heads. `folders` hold the downloaded artifacts by kind.
 */
export async function publishRun({ github, context, run, folders }) {
  const { owner, repo } = context.repo;
  const { screens, failed, files, ranScreens } = gather(run, folders);
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number: run.number });
  const existing = findScreensComment(await comments(github, owner, repo, run.number));
  const previous = existing ? readData(existing.body) : null;
  let review, body;
  if (!ranScreens) {
    review = reviewState({ ranScreens: false });
    const data = { head: run.head, base: pr.base.sha, ranScreens: false, fingerprint: null, approved: previous?.approved ?? null,
      total: 0, changed: 0, failed: 0, failure: null };
    body = noScreensBody({ reason: `This pull request at ${run.head.slice(0, 7)} changes neither the app nor the website, so there are no screens to compare.`,
      review, data });
  } else {
    const shown = screens.filter((screen) => screen.status !== "unchanged").flatMap((screen) => Object.values(screen.images));
    const urls = await upload({ github, owner, repo, number: run.number, head: run.head, target: context.payload.repository?.default_branch,
      images: shown.map((file) => [file, files.get(file).data]) });
    const print = fingerprint({ screens, failed }, (file) => files.get(file).digest);
    const counts = summary(screens, failed);
    review = reviewState({ ranScreens: true, ...counts, labels: await labelsOf(github, owner, repo, run.number),
      approved: previous?.approved ?? null, fingerprint: print });
    if (review.removeLabel) {
      try {
        await github.rest.issues.removeLabel({ owner, repo, issue_number: run.number, name: approval });
      } catch (error) {
        if (error.status !== 404) throw error;
      }
    }
    const data = { head: run.head, base: pr.base.sha, ranScreens: true, fingerprint: print,
      approved: review.removeLabel ? null : previous?.approved ?? null, ...counts };
    body = commentBody({ baseRef: pr.base.ref, base: pr.base.sha, head: run.head, screens, failed, imageURL: (file) => urls.get(file), review, data });
  }
  let comment = existing;
  if (existing) {
    comment = (await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body })).data;
  } else if (ranScreens) {
    comment = (await github.rest.issues.createComment({ owner, repo, issue_number: run.number, body })).data;
  }
  await setStatus({ github, owner, repo, sha: run.head, review, url: comment?.html_url });
  await deleteAssets({ github, owner, repo, pick: (assets) => staleAssets(assets, run.number, run.head) });
  return review;
}

/** Marks the head as errored when the bot itself fails, so a required Visual review doesn't wait forever. */
export async function failRun({ github, context, run }) {
  const { owner, repo } = context.repo;
  await github.rest.repos.createCommitStatus({ owner, repo, sha: run.head, state: "error", context: statusContext,
    description: "The screens bot failed: see the Screens workflow run.", target_url: `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}` });
}

/**
 * Follows visual-ok being added or removed: an added label approves the fingerprint of the screens the
 * comment shows, a removed one drops the approval. Sets the status when the comment is for the current
 * head; a newer head's run sets its own. Returns the review, or null without the bot's comment.
 */
export async function updateReview({ github, context }) {
  const { owner, repo } = context.repo;
  const pr = context.payload.pull_request;
  const existing = findScreensComment(await comments(github, owner, repo, pr.number));
  const data = existing ? readData(existing.body) : null;
  if (!data) return null;
  const labels = await labelsOf(github, owner, repo, pr.number);
  const approved = !labels.includes(approval) ? null : context.payload.action === "labeled" ? data.fingerprint : data.approved;
  const next = { ...data, approved };
  const review = reviewState({ ...next, labels });
  await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body: withReview(existing.body, review, next) });
  if (data.head === pr.head.sha) await setStatus({ github, owner, repo, sha: data.head, review, url: existing.html_url });
  return review;
}

/** Deletes an unmerged, closed pull request's images from every month, says so in its comment, and counts them. */
export async function deleteScreens({ github, context }) {
  const { owner, repo } = context.repo;
  const number = context.payload.pull_request.number;
  const deleted = await deleteAssets({ github, owner, repo, pick: (assets) => pullRequestAssets(assets, number) });
  const existing = findScreensComment(await comments(github, owner, repo, number));
  const data = existing ? readData(existing.body) : null;
  if (data) {
    const review = { state: "success", description: "Nothing to review: the pull request closed.", removeLabel: false };
    await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id,
      body: noScreensBody({ reason: "This pull request closed without merging, so the images of its screens were deleted.", review, data }) });
  }
  return deleted;
}
