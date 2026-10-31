import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodePNG } from "./png.mjs";
import { main as compare } from "./compare-screens.mjs";
import { readData, releaseTag } from "./screens-comment.mjs";
import { deleteScreens, failRun, findRun, publishRun, updateReview } from "./screens-bot.mjs";

const head = "a".repeat(40), oldHead = "c".repeat(40), base = "b".repeat(40);
const repo = { owner: "Seb-GRAF", repo: "StableBar" };
const bot = { login: "github-actions[bot]", type: "Bot" };
const notFound = () => Object.assign(new Error("Not Found"), { status: 404 });

function image(color) {
  const rgba = new Uint8Array(40 * 20 * 4);
  for (let index = 0; index < 40 * 20; index++) rgba.set([40, 40, 40, 255], index * 4);
  for (let y = 5; y < 10; y++) for (let x = 10; x < 15; x++) rgba.set(color, (y * 40 + x) * 4);
  return { width: 40, height: 20, rgba };
}

/** An artifact folder as the Draw screens job uploads it: docs/hero-dark drawn in `color` after, docs/same-dark unchanged. */
function artifact(color = [255, 255, 255, 255]) {
  const root = mkdtempSync(join(tmpdir(), "artifact-"));
  const before = join(root, "before"), after = join(root, "after"), out = join(root, "out");
  mkdirSync(before);
  mkdirSync(after);
  for (const folder of [before, after]) writeFileSync(join(folder, "same-dark.png"), encodePNG(image([40, 40, 40, 255])));
  writeFileSync(join(before, "hero-dark.png"), encodePNG(image([40, 40, 40, 255])));
  writeFileSync(join(after, "hero-dark.png"), encodePNG(image(color)));
  const log = console.log;
  console.log = () => {};
  try {
    compare([before, after, out, "--prefix", "docs"]);
  } finally {
    console.log = log;
  }
  return out;
}

/** The parts of Octokit the bot uses, over a little state. Uploads get GitHub's renaming of special characters. */
function fakeGitHub({ pulls = [], comments = [], labels = [], releases = [], jobs = [], artifacts = [] } = {}) {
  const state = { comments, labels, releases, statuses: [], uploads: [], deleted: [], next: 1000 };
  const rest = {
    pulls: {
      get: async ({ pull_number }) => {
        const pr = pulls.find((entry) => entry.number === pull_number);
        if (!pr) throw notFound();
        return { data: pr };
      },
      list: async ({ head: filter, state: wanted }) =>
        ({ data: pulls.filter((pr) => pr.state === wanted && `${pr.head.repo.owner.login}:${pr.head.ref}` === filter) }),
    },
    issues: {
      listComments: async () => ({ data: state.comments }),
      createComment: async ({ body }) => {
        const comment = { id: state.next++, user: bot, body, html_url: `https://example.test/comment/${state.next}` };
        state.comments.push(comment);
        return { data: comment };
      },
      updateComment: async ({ comment_id, body }) => {
        const comment = state.comments.find((entry) => entry.id === comment_id);
        comment.body = body;
        return { data: comment };
      },
      listLabelsOnIssue: async () => ({ data: state.labels.map((name) => ({ name })) }),
      removeLabel: async ({ name }) => {
        if (!state.labels.includes(name)) throw notFound();
        state.labels = state.labels.filter((entry) => entry !== name);
        return { data: [] };
      },
    },
    repos: {
      createCommitStatus: async (status) => {
        state.statuses.push(status);
        return { data: status };
      },
      getReleaseByTag: async ({ tag }) => {
        const release = state.releases.find((entry) => entry.tag_name === tag);
        if (!release) throw notFound();
        return { data: release };
      },
      createRelease: async (params) => {
        const release = { id: state.next++, ...params, assets: [] };
        state.releases.push(release);
        return { data: release };
      },
      listReleases: async () => ({ data: state.releases }),
      listReleaseAssets: async ({ release_id }) => ({ data: state.releases.find((release) => release.id === release_id).assets }),
      uploadReleaseAsset: async ({ release_id, name, data, headers }) => {
        const renamed = name.replaceAll("~", ".");
        const asset = { id: state.next++, name: renamed, browser_download_url: `https://example.test/download/${renamed}` };
        state.releases.find((release) => release.id === release_id).assets.push(asset);
        state.uploads.push({ name, size: data.length, type: headers["content-type"] });
        return { data: asset };
      },
      deleteReleaseAsset: async ({ asset_id }) => {
        for (const release of state.releases) {
          const index = release.assets.findIndex((asset) => asset.id === asset_id);
          if (index >= 0) state.deleted.push(...release.assets.splice(index, 1).map((asset) => asset.name));
        }
      },
    },
    actions: {
      listJobsForWorkflowRun: async () => ({ data: { total_count: jobs.length, jobs } }),
      listWorkflowRunArtifacts: async () => ({ data: { total_count: artifacts.length, artifacts } }),
    },
  };
  const paginate = async (method, params) => {
    const { data } = await method(params);
    return Array.isArray(data) ? data : data.jobs ?? data.artifacts;
  };
  return { github: { rest, paginate }, state };
}

const pr = (extra = {}) => ({ number: 7, state: "open", head: { sha: head, ref: "feat/x", repo: { owner: { login: "someone" } } },
  base: { sha: base, ref: "main" }, ...extra });
const runContext = (extra = {}) => ({ ...repo, repo, serverUrl: "https://github.com", runId: 5, payload: {
  repository: { default_branch: "main" },
  workflow_run: { id: 99, event: "pull_request", head_sha: head, head_branch: "feat/x",
    head_repository: { owner: { login: "someone" } }, pull_requests: [], ...extra } } });
const labelContext = (action, sha = head) => ({ repo, payload: { action, label: { name: "visual-ok" }, pull_request: pr({ head: { ...pr().head, sha } }) } });
const ran = (extra = {}) => ({ number: 7, head, runId: 99, jobs: { current: "success", build: "success", app: "success", site: "skipped" },
  artifacts: { app: true, site: false }, ...extra });
const jobsOf = (conclusions) => Object.entries(conclusions).map(([name, conclusion]) => ({ name, conclusion }));

test("findRun finds a fork's pull request by its branch and head, with what its jobs did", async () => {
  const { github } = fakeGitHub({ pulls: [pr()], artifacts: [{ name: "screens-app" }, { name: "release-build" }],
    jobs: jobsOf({ "Check revision": "success", "Build release": "success", "Draw screens": "success", "Test": "success" }) });
  assert.deepEqual(await findRun({ github, context: runContext() }),
    { number: 7, head, runId: 99, jobs: { current: "success", build: "success", app: "success", site: "skipped" }, artifacts: { app: true, site: false } });
});

test("findRun skips runs that aren't for an open pull request's current head", async () => {
  const { github } = fakeGitHub({ pulls: [pr({ head: { ...pr().head, sha: oldHead } })] });
  assert.equal(await findRun({ github, context: runContext() }), null);
  assert.equal(await findRun({ github, context: runContext({ event: "push" }) }), null);
  const { github: closed } = fakeGitHub({ pulls: [pr({ state: "closed" })] });
  assert.equal(await findRun({ github: closed, context: runContext({ pull_requests: [{ number: 7 }] }) }), null);
});

test("publishRun uploads the changed screens, comments, sets the status and drops older heads' images", async () => {
  const old = { id: 1, name: `pr7-${oldHead.slice(0, 7)}-docs.hero-dark-after.png` }, other = { id: 2, name: "pr8-1234567-docs.a-after.png" };
  const { github, state } = fakeGitHub({ pulls: [pr()], releases: [{ id: 3, tag_name: "pr-previews-2026-09", assets: [old, other] }] });
  const review = await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  assert.deepEqual(review, { state: "pending", description: "1 screen changed: a maintainer adds visual-ok after looking.", removeLabel: false });
  const release = state.releases.find((entry) => entry.tag_name === releaseTag(new Date()));
  assert.deepEqual([release.prerelease, release.make_latest, release.target_commitish], [true, "false", "main"]);
  assert.deepEqual(state.uploads.map((upload) => [upload.name, upload.type]).sort(),
    ["after", "before", "diff"].map((kind) => [`pr7-aaaaaaa-docs~hero-dark-${kind}.png`, "image/png"]));
  const [comment] = state.comments;
  assert.match(comment.body, /src="https:\/\/example\.test\/download\/pr7-aaaaaaa-docs\.hero-dark-after\.png"/);
  const data = readData(comment.body);
  assert.deepEqual([data.head, data.base, data.ranScreens, data.total, data.changed, data.approved], [head, base, true, 2, 1, null]);
  assert.deepEqual(state.statuses, [{ ...repo, sha: head, state: "pending", context: "Visual review", description: review.description,
    target_url: comment.html_url }]);
  assert.deepEqual(state.deleted, [old.name]);
});

test("visual-ok approves the screens shown, survives a rerun of them and comes off for others", async () => {
  const { github, state } = fakeGitHub({ pulls: [pr()] });
  await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  const shown = readData(state.comments[0].body).fingerprint;
  state.labels = ["visual-ok"];
  assert.deepEqual(await updateReview({ github, context: labelContext("labeled") }),
    { state: "success", description: "1 changed screen approved.", removeLabel: false });
  assert.equal(readData(state.comments[0].body).approved, shown);
  assert.equal(state.statuses.at(-1).state, "success");
  const rerun = await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  assert.deepEqual([rerun.state, state.labels], ["success", ["visual-ok"]]);
  const changed = await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact([255, 0, 0, 255]) } });
  assert.deepEqual([changed.state, state.labels, readData(state.comments[0].body).approved], ["pending", [], null]);
  assert.match(state.comments[0].body, /`visual-ok` was taken off/);
  assert.equal(state.comments.length, 1);
  assert.equal(state.statuses.at(-1).state, "pending");
});

test("removing visual-ok sends the review back to pending", async () => {
  const { github, state } = fakeGitHub({ pulls: [pr()], labels: ["visual-ok"] });
  await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  await updateReview({ github, context: labelContext("labeled") });
  state.labels = [];
  const review = await updateReview({ github, context: labelContext("unlabeled") });
  assert.equal(review.state, "pending");
  assert.equal(readData(state.comments[0].body).approved, null);
});

test("updateReview ignores lookalike comments, and leaves a newer head's status to its run", async () => {
  const lookalike = { id: 1, user: { login: "someone" }, body: `<!-- stablebar-screens -->\n<!-- stablebar-screens-data ${JSON.stringify({
    head, base, ranScreens: true, fingerprint: "f".repeat(64), approved: "f".repeat(64), total: 1, changed: 1, failed: 0, failure: null })} -->` };
  const { github, state } = fakeGitHub({ pulls: [pr()], comments: [lookalike], labels: ["visual-ok"] });
  assert.equal(await updateReview({ github, context: labelContext("labeled") }), null);
  assert.equal(state.statuses.length, 0);
  await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  // The label came before any screens were drawn, so it approved none, and comes off.
  assert.deepEqual(state.labels, []);
  state.labels = ["visual-ok"];
  const statuses = state.statuses.length;
  await updateReview({ github, context: labelContext("labeled", oldHead) });
  assert.equal(state.statuses.length, statuses);
  assert.equal(readData(state.comments[1].body).approved, readData(state.comments[1].body).fingerprint);
});

test("publishRun answers a run that drew no screens", async () => {
  const skipped = ran({ jobs: { current: "success", build: "skipped", app: "skipped", site: "skipped" }, artifacts: { app: false, site: false } });
  const { github, state } = fakeGitHub({ pulls: [pr()] });
  assert.deepEqual(await publishRun({ github, context: runContext(), run: skipped, folders: {} }),
    { state: "success", description: "No screens to compare.", removeLabel: false });
  assert.deepEqual([state.comments.length, state.statuses[0].state], [0, "success"]);
  await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  await publishRun({ github, context: runContext(), run: skipped, folders: {} });
  assert.match(state.comments[0].body, /changes neither the app nor the website/);
  assert.equal(readData(state.comments[0].body).ranScreens, false);
});

test("publishRun reports failed jobs and refuses unusable artifacts", async () => {
  const { github, state } = fakeGitHub({ pulls: [pr()] });
  const blocked = await publishRun({ github, context: runContext(), folders: {},
    run: ran({ jobs: { current: "success", build: "failure", app: "skipped", site: "skipped" }, artifacts: { app: false, site: false } }) });
  assert.equal(blocked.state, "failure");
  assert.match(state.comments[0].body, /- `app`: `Build release ended with failure, so Draw screens didn't run\.`/);
  const folder = artifact();
  symlinkSync("/etc/hosts", join(folder, "hosts.png"));
  const refused = await publishRun({ github, context: runContext(), run: ran(), folders: { app: folder } });
  assert.equal(refused.state, "failure");
  assert.match(state.comments[0].body, /The screens-app artifact can't be used: 'hosts\.png': not a regular file\./);
  const site = await publishRun({ github, context: runContext(), folders: { site: artifact() },
    run: ran({ jobs: { current: "success", build: "skipped", app: "skipped", site: "success" }, artifacts: { app: false, site: true } }) });
  assert.equal(site.state, "failure");
  assert.match(state.comments[0].body, /its id isn't site\/ followed by a plain name/);
  assert.equal(state.uploads.length, 0);
});

test("failRun marks the head when the bot itself fails", async () => {
  const { github, state } = fakeGitHub();
  await failRun({ github, context: runContext(), run: ran() });
  assert.deepEqual(state.statuses, [{ ...repo, sha: head, state: "error", context: "Visual review",
    description: "The screens bot failed: see the Screens workflow run.", target_url: "https://github.com/Seb-GRAF/StableBar/actions/runs/5" }]);
});

test("deleteScreens deletes an unmerged pull request's images from every month", async () => {
  const { github, state } = fakeGitHub({ pulls: [pr()], releases: [
    { id: 1, tag_name: "pr-previews-2026-09", assets: [{ id: 11, name: "pr7-aaaaaaa-a.png" }, { id: 12, name: "pr8-aaaaaaa-a.png" }] },
    { id: 2, tag_name: "pr-previews-2026-10", assets: [{ id: 21, name: "pr7-bbbbbbb-b.png" }] },
    { id: 3, tag_name: "v1.0.0", assets: [{ id: 31, name: "pr7-ccccccc-StableBar.dmg" }] }] });
  await publishRun({ github, context: runContext(), run: ran(), folders: { app: artifact() } });
  const close = { repo, payload: { action: "closed", pull_request: pr({ state: "closed", merged: false }) } };
  // Publishing already dropped the other head's image; closing takes this head's three and the stray one.
  assert.equal(await deleteScreens({ github, context: close }), 4);
  assert.deepEqual(state.releases.map((release) => [release.tag_name, release.assets.map((asset) => asset.name)]).slice(0, 3),
    [["pr-previews-2026-09", ["pr8-aaaaaaa-a.png"]], ["pr-previews-2026-10", []], ["v1.0.0", ["pr7-ccccccc-StableBar.dmg"]]]);
  assert.match(state.comments[0].body, /closed without merging, so the images of its screens were deleted/);
  assert.notEqual(readData(state.comments[0].body), null);
});
