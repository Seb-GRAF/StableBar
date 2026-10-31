// The GitHub side of the before/after screens, for screens.yml, which runs the default branch's copy.
// Every event, a CI run finishing or a pull request labelled, retargeted, closed or reopened, runs one
// reconcile of its pull request, one at a time: plan() reads where the pull request stands and which CI
// run's screens to publish, the workflow downloads that run's artifacts, and apply() makes the comment,
// the images and the Visual review status match. GitHub may drop an event waiting behind another; the
// next one still reconciles everything, since nothing depends on which events ran. visual-ok approves
// the screens the comment shows when it was added after they appeared. The artifacts come from the
// pull request's own CI jobs, so they are read as untrusted data.
import { closeSync, existsSync, lstatSync, openSync, readFileSync, readSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { validateArtifact, readManifest, fingerprint, summary, reviewState, commentBody, withReview, noScreensBody, readData,
  findScreensComment, assetName, releaseTag, staleAssets, pullRequestAssets } from "./screens-comment.mjs";
import { decodePNG, encodePNG } from "./png.mjs";

const statusContext = "Visual review";
const approval = "visual-ok";
const workflowPath = ".github/workflows/ci.yml";
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

/** The open pull request a pull_request run of CI is for: listed on the run, or for a fork, found by its head branch. */
async function pullRequestOfRun({ github, owner, repo, run }) {
  if (!run || run.event !== "pull_request" || run.path !== workflowPath || !run.head_repository) return null;
  if (run.pull_requests.length > 0) return run.pull_requests[0].number;
  const pulls = await github.paginate(github.rest.pulls.list,
    { owner, repo, state: "open", head: `${run.head_repository.owner.login}:${run.head_branch}`, per_page: 100 });
  return (pulls.find((pr) => pr.head.sha === run.head_sha) ?? pulls[0])?.number ?? null;
}

/** The newest finished CI run for a head, preferring the runs GitHub lists the pull request on. */
async function latestRun({ github, owner, repo, number, sha }) {
  const runs = (await github.paginate(github.rest.actions.listWorkflowRuns,
    { owner, repo, workflow_id: "ci.yml", head_sha: sha, event: "pull_request", status: "completed", per_page: 100 }))
    .filter((run) => run.path === workflowPath);
  const listed = runs.filter((run) => run.pull_requests.some((pr) => pr.number === number));
  return [...(listed.length > 0 ? listed : runs)].sort((a, b) => b.run_number - a.run_number)[0] ?? null;
}

/**
 * What a reconcile of the event's pull request does, decided before the workflow downloads anything:
 * "none" for a run that isn't CI's for an open pull request, "close" for a closed pull request,
 * "publish" with the newest finished CI run for its head when the comment doesn't show that run yet,
 * and "review" otherwise. A publication carries what the run's jobs did, which artifacts it uploaded
 * and which screens the pull request's files call for. A job the run doesn't have is "missing".
 */
export async function plan({ github, context }) {
  const { owner, repo } = context.repo;
  const number = context.payload.pull_request?.number ?? await pullRequestOfRun({ github, owner, repo, run: context.payload.workflow_run });
  if (!number) return { action: "none" };
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number: number });
  if (pr.state !== "open") return { action: "close", number };
  const run = await latestRun({ github, owner, repo, number, sha: pr.head.sha });
  const existing = findScreensComment(await comments(github, owner, repo, number));
  const data = existing ? readData(existing.body) : null;
  if (!run || (data?.runId === run.id && data?.runAttempt === run.run_attempt)) return { action: "review", number };
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, { owner, repo, run_id: run.id, filter: "latest", per_page: 100 });
  const uploaded = (await github.paginate(github.rest.actions.listWorkflowRunArtifacts, { owner, repo, run_id: run.id, per_page: 100 }))
    .map((artifact) => artifact.name);
  const files = (await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number: number, per_page: 100 }))
    .flatMap((file) => [file.filename, file.previous_filename].filter(Boolean));
  return {
    action: "publish", number,
    run: {
      id: run.id, attempt: run.run_attempt, head: pr.head.sha,
      jobs: Object.fromEntries(Object.entries(jobNames).map(([key, name]) => [key, jobs.find((job) => job.name === name)?.conclusion ?? "missing"])),
      artifacts: Object.fromEntries(Object.entries(kinds).map(([kind, { artifact }]) => [kind, uploaded.includes(artifact)])),
      expected: Object.fromEntries(Object.keys(kinds).map((kind) => [kind, files.some((file) => changePatterns[kind].test(file))])),
    },
  };
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

/** When visual-ok was last added to the pull request, as GitHub's ISO time, or null. */
async function lastLabeled({ github, owner, repo, number }) {
  const events = await github.paginate(github.rest.issues.listEvents, { owner, repo, issue_number: number, per_page: 100 });
  return events.filter((event) => event.event === "labeled" && event.label?.name === approval).map((event) => event.created_at).sort().at(-1) ?? null;
}

async function removeApproval({ github, owner, repo, number }) {
  try {
    await github.rest.issues.removeLabel({ owner, repo, issue_number: number, name: approval });
  } catch (error) {
    if (error.status !== 404) throw error;
  }
}

async function setStatus({ github, owner, repo, sha, review, url }) {
  await github.rest.repos.createCommitStatus({ owner, repo, sha, state: review.state, context: statusContext, description: review.description,
    ...(url ? { target_url: url } : {}) });
}

/** A release holds at most this many assets. */
const capacity = 1000;

/**
 * The first of this month's pre-releases for the images with room for `needed` more, `pr-previews-YYYY-MM`,
 * then `-2`, `-3` and on, created when missing, never as the latest release.
 */
async function previewRelease({ github, owner, repo, target, needed }) {
  const month = releaseTag(new Date());
  const find = async (tag) => {
    try {
      return (await github.rest.repos.getReleaseByTag({ owner, repo, tag })).data;
    } catch (error) {
      if (error.status === 404) return null;
      throw error;
    }
  };
  for (let shard = 1; shard <= 50; shard++) {
    const tag = shard === 1 ? month : `${month}-${shard}`;
    let release = await find(tag);
    if (!release) {
      try {
        release = (await github.rest.repos.createRelease({ owner, repo, tag_name: tag, target_commitish: target, name: `Pull request screens, ${tag.slice(12)}`,
          prerelease: true, make_latest: "false",
          body: "Images for the before and after screens the bot posts on pull requests. An unmerged pull request's images are deleted when it closes." })).data;
      } catch (error) {
        if (error.status !== 422) throw error;
        release = await find(tag);
      }
    }
    const assets = await github.paginate(github.rest.repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
    if (assets.length + needed <= capacity) return release;
  }
  throw new Error(`No pull request screens release of ${month} has room for ${needed} images.`);
}

/**
 * Uploads `images`, [file, PNG data] pairs, and returns each file's URL as GitHub answers it. The head's
 * images from an earlier run of it are deleted first, wherever they are.
 */
async function upload({ github, owner, repo, number, head, target, images }) {
  const urls = new Map();
  if (images.length === 0) return urls;
  await deleteAssets({ github, owner, repo, pick: (assets) => pullRequestAssets(assets, number).filter((asset) => asset.name.startsWith(assetName(number, head, ""))) });
  const release = await previewRelease({ github, owner, repo, target, needed: images.length });
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
 * Publishes a run from plan(): uploads the images of its changed screens, writes or rewrites the
 * comment, sets the status on the head, takes visual-ok off when it came before these screens, and then
 * deletes the images of the pull request's other heads. Screens the comment already showed keep the
 * time they first appeared, and so their approval.
 */
async function publish({ github, owner, repo, pr, existing, data: previous, now, labels, labeledAt, run, folders, target }) {
  const number = pr.number, head = pr.head.sha;
  const { screens, failed, files, ranScreens } = gather(run, folders);
  const drawn = { head, base: pr.base.sha, baseRef: pr.base.ref, runId: run.id, runAttempt: run.attempt };
  let review, body;
  if (!ranScreens) {
    review = reviewState({ ranScreens: false });
    const data = { ...drawn, ranScreens: false, fingerprint: null, shownAt: null, total: 0, changed: 0, failed: 0, failure: null };
    body = noScreensBody({ reason: `This pull request at ${head.slice(0, 7)} changes neither the app nor the website, so there are no screens to compare.`,
      review, data });
  } else {
    const shown = screens.filter((screen) => screen.status !== "unchanged").flatMap((screen) => Object.values(screen.images));
    const urls = await upload({ github, owner, repo, number, head, target, images: shown.map((file) => [file, files.get(file).data]) });
    const print = fingerprint({ screens, failed }, (file) => files.get(file).digest);
    const shownAt = previous?.fingerprint === print && previous.shownAt ? previous.shownAt : now;
    const counts = summary(screens, failed);
    review = reviewState({ ranScreens: true, ...counts, labels, labeledAt, shownAt });
    if (review.removeLabel) await removeApproval({ github, owner, repo, number });
    const data = { ...drawn, ranScreens: true, fingerprint: print, shownAt, ...counts };
    body = commentBody({ baseRef: pr.base.ref, base: pr.base.sha, head, screens, failed, imageURL: (file) => urls.get(file), review, data });
  }
  let comment = existing;
  if (existing) {
    comment = (await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body })).data;
  } else if (ranScreens) {
    comment = (await github.rest.issues.createComment({ owner, repo, issue_number: number, body })).data;
  }
  await setStatus({ github, owner, repo, sha: head, review, url: comment?.html_url });
  await deleteAssets({ github, owner, repo, pick: (assets) => staleAssets(assets, number, head) });
  return review;
}

/**
 * Brings the review up to date without drawing anything: the labels, when visual-ok was added, and
 * whether the pull request still has the base its screens were compared with. Sets the status when
 * the comment is for the current head; a newer head's run sets its own.
 */
async function review({ github, owner, repo, pr, existing, data, labels, labeledAt }) {
  if (!data) return null;
  const baseChanged = data.baseRef !== null && data.baseRef !== pr.base.ref;
  const result = reviewState({ ...data, labels, labeledAt, baseChanged });
  if (result.removeLabel) await removeApproval({ github, owner, repo, number: pr.number });
  const body = withReview(existing.body, result, data);
  if (body !== existing.body) await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
  if (data.head === pr.head.sha) await setStatus({ github, owner, repo, sha: data.head, review: result, url: existing.html_url });
  return result;
}

/** Deletes an unmerged, closed pull request's images from every month, says so in its comment, and counts them. */
async function closeUnmerged({ github, owner, repo, number }) {
  const deleted = await deleteAssets({ github, owner, repo, pick: (assets) => pullRequestAssets(assets, number) });
  const existing = findScreensComment(await comments(github, owner, repo, number));
  const data = existing ? readData(existing.body) : null;
  if (data) {
    const review = { state: "success", description: "Nothing to review: the pull request closed.", removeLabel: false };
    const body = noScreensBody({ reason: "This pull request closed without merging, so the images of its screens were deleted.", review, data });
    if (body !== existing.body) await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body });
  }
  return deleted;
}

/**
 * Makes the pull request's comment, images and Visual review status match where it stands now,
 * following plan(): `folders` hold the artifacts the workflow downloaded for a publication. A closed
 * pull request loses its images unless it merged; a head that moved since the plan waits for its own
 * run. Returns what it did: `{action, review}`, or `{action: "close", deleted}`.
 */
export async function apply({ github, context, plan: chosen, folders = {} }) {
  if (chosen.action === "none") return { action: "none" };
  const { owner, repo } = context.repo;
  const number = chosen.number;
  const response = await github.rest.pulls.get({ owner, repo, pull_number: number });
  const pr = response.data;
  if (pr.state !== "open") return { action: "close", deleted: pr.merged ? 0 : await closeUnmerged({ github, owner, repo, number }) };
  const existing = findScreensComment(await comments(github, owner, repo, number));
  const state = {
    github, owner, repo, pr, existing, data: existing ? readData(existing.body) : null,
    now: new Date(response.headers?.date ?? Date.now()).toISOString(),
    labels: pr.labels.map((label) => label.name), labeledAt: await lastLabeled({ github, owner, repo, number }),
  };
  if (chosen.action === "publish" && chosen.run.head === pr.head.sha) {
    return { action: "publish", review: await publish({ ...state, run: chosen.run, folders, target: context.payload.repository?.default_branch }) };
  }
  return { action: "review", review: await review(state) };
}

/** Marks an open pull request's head as errored when the bot itself fails, so a required Visual review doesn't wait forever. */
export async function failRun({ github, context, number }) {
  if (!number) return;
  const { owner, repo } = context.repo;
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number: number });
  if (pr.state !== "open") return;
  await github.rest.repos.createCommitStatus({ owner, repo, sha: pr.head.sha, state: "error", context: statusContext,
    description: "The screens bot failed: see the Screens workflow run.", target_url: `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}` });
}
