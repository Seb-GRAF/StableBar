import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import zlib from "node:zlib";
import { decodePNG, encodePNG } from "./png.mjs";
import { main as compare } from "./compare-screens.mjs";
import { readData, releaseTag } from "./screens-comment.mjs";
import { apply, changePatterns, failRun, plan } from "./screens-bot.mjs";

const head = "a".repeat(40), oldHead = "c".repeat(40), base = "b".repeat(40);
const repo = { owner: "Seb-GRAF", repo: "StableBar" };
const bot = { login: "github-actions[bot]", type: "Bot" };
const notFound = () => Object.assign(new Error("Not Found"), { status: 404 });
const conclusions = { "Check revision": "success", "Build release": "success", "Draw screens": "success", "Draw website screens": "skipped" };
const jobsOf = (entries) => Object.entries(entries).map(([name, conclusion]) => ({ name, conclusion }));

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

/**
 * The parts of Octokit the bot uses, over a little state with its own clock, which answers in the Date
 * header. Uploads get GitHub's renaming of special characters.
 */
function fakeGitHub({ pull = {}, comments = [], labels = [], releases = [], files = ["Sources/StableBar/BarView.swift"] } = {}) {
  const state = {
    now: new Date("2026-10-31T10:00:00Z"), comments, labels, releases, files, events: [], statuses: [], uploads: [], deleted: [], next: 1000,
    pr: { number: 7, state: "open", merged: false, head: { sha: head, ref: "feat/x", repo: { owner: { login: "someone" } } }, base: { sha: base, ref: "main" }, ...pull },
    runs: [{ id: 99, run_number: 50, run_attempt: 1, head_sha: head, path: ".github/workflows/ci.yml", pull_requests: [] }],
    jobs: { 99: jobsOf(conclusions) }, artifacts: { 99: [{ name: "screens-app" }] },
  };
  const at = () => state.now.toISOString();
  const rest = {
    pulls: {
      get: async ({ pull_number }) => {
        if (pull_number !== state.pr.number) throw notFound();
        return { data: { ...state.pr, labels: state.labels.map((name) => ({ name })) }, headers: { date: state.now.toUTCString() } };
      },
      list: async ({ head: filter, state: wanted }) => ({ data: [state.pr].filter((pr) => pr.state === wanted && `${pr.head.repo.owner.login}:${pr.head.ref}` === filter) }),
      listFiles: async () => ({ data: state.files.map((filename) => ({ filename })) }),
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
      listEvents: async () => ({ data: state.events }),
      removeLabel: async ({ name }) => {
        if (!state.labels.includes(name)) throw notFound();
        state.labels = state.labels.filter((entry) => entry !== name);
        state.events.push({ event: "unlabeled", label: { name }, created_at: at() });
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
        state.uploads.push({ name, size: data.length, type: headers["content-type"], data: Buffer.from(data) });
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
      listWorkflowRuns: async ({ head_sha }) => ({ data: { workflow_runs: state.runs.filter((run) => run.head_sha === head_sha) } }),
      listJobsForWorkflowRun: async ({ run_id }) => ({ data: { jobs: state.jobs[run_id] ?? [] } }),
      listWorkflowRunArtifacts: async ({ run_id }) => ({ data: { artifacts: state.artifacts[run_id] ?? [] } }),
    },
  };
  const paginate = async (method, params) => {
    const { data } = await method(params);
    return Array.isArray(data) ? data : data.jobs ?? data.artifacts ?? data.workflow_runs;
  };
  /** Time passes; then a maintainer adds a label. */
  const label = (name = "visual-ok") => {
    state.now = new Date(state.now.getTime() + 60_000);
    state.labels.push(name);
    state.events.push({ event: "labeled", label: { name }, created_at: at() });
  };
  /** A push or a rerun: a new finished CI run for `sha`, with these jobs and artifacts. */
  const run = ({ sha = head, jobs = conclusions, artifacts = ["screens-app"] } = {}) => {
    state.now = new Date(state.now.getTime() + 60_000);
    const id = state.next++;
    state.runs.push({ id, run_number: id, run_attempt: 1, head_sha: sha, path: ".github/workflows/ci.yml", pull_requests: [] });
    state.jobs[id] = jobsOf(jobs);
    state.artifacts[id] = artifacts.map((name) => ({ name }));
    return id;
  };
  return { github: { rest, paginate }, state, label, run };
}

const runEvent = (extra = {}) => ({ repo, serverUrl: "https://github.com", runId: 5, payload: {
  repository: { default_branch: "main" },
  workflow_run: { id: 99, event: "pull_request", path: ".github/workflows/ci.yml", head_sha: head, head_branch: "feat/x",
    head_repository: { owner: { login: "someone" } }, pull_requests: [], ...extra } } });
const prEvent = (action, extra = {}) => ({ repo, serverUrl: "https://github.com", runId: 6, payload: {
  repository: { default_branch: "main" }, action, label: { name: "visual-ok" }, pull_request: { number: 7 }, ...extra } });
/** What screens.yml does for one event: plan, download the run's artifacts, apply. */
const reconcile = async (github, context, folders = {}) => apply({ github, context, plan: await plan({ github, context }), folders });
const comment = (state) => state.comments.find((entry) => entry.user.login === bot.login);

test("plan finds a fork's pull request, and the newest finished CI run for its head", async () => {
  const { github, state, run } = fakeGitHub({ files: ["Sources/StableBar/BarView.swift", "README.md"] });
  assert.deepEqual(await plan({ github, context: runEvent() }), { action: "publish", number: 7, run: { id: 99, attempt: 1, head,
    jobs: { current: "success", build: "success", app: "success", site: "skipped" }, artifacts: { app: true, site: false }, expected: { app: true, site: false } } });
  // A newer run for the head, a rerun or a run another event started, is the one to publish.
  const newer = run({ jobs: { "Check revision": "success" }, artifacts: [] });
  const chosen = await plan({ github, context: prEvent("labeled") });
  assert.deepEqual([chosen.run.id, chosen.run.jobs], [newer, { current: "success", build: "missing", app: "missing", site: "missing" }]);
  assert.equal(state.uploads.length, 0);
});

test("plan takes only CI's pull request runs, and leaves a run already shown to review", async () => {
  const { github } = fakeGitHub();
  assert.deepEqual(await plan({ github, context: runEvent({ path: ".github/workflows/other.yml" }) }), { action: "none" });
  assert.deepEqual(await plan({ github, context: runEvent({ event: "push" }) }), { action: "none" });
  await reconcile(github, runEvent(), { app: artifact() });
  assert.deepEqual(await plan({ github, context: runEvent() }), { action: "review", number: 7 });
});

test("a publication uploads the changed screens, comments, sets the status and drops older heads' images", async () => {
  const old = { id: 1, name: `pr7-${oldHead.slice(0, 7)}-docs.hero-dark-after.png` }, other = { id: 2, name: "pr8-1234567-docs.a-after.png" };
  const { github, state } = fakeGitHub({ releases: [{ id: 3, tag_name: "pr-previews-2026-09", assets: [old, other] }] });
  const { review } = await reconcile(github, runEvent(), { app: artifact() });
  assert.deepEqual(review, { state: "pending", description: "1 screen changed: a maintainer adds visual-ok after looking.", removeLabel: false });
  const release = state.releases.find((entry) => entry.tag_name === releaseTag(new Date()));
  assert.deepEqual([release.prerelease, release.make_latest, release.target_commitish], [true, "false", "main"]);
  assert.deepEqual(state.uploads.map((upload) => [upload.name, upload.type]).sort(),
    ["after", "before", "diff"].map((kind) => [`pr7-aaaaaaa-docs~hero-dark-${kind}.png`, "image/png"]));
  assert.match(comment(state).body, /src="https:\/\/example\.test\/download\/pr7-aaaaaaa-docs\.hero-dark-after\.png"/);
  const data = readData(comment(state).body);
  assert.deepEqual([data.head, data.base, data.baseRef, data.runId, data.runAttempt, data.total, data.changed, data.shownAt],
    [head, base, "main", 99, 1, 2, 1, "2026-10-31T10:00:00.000Z"]);
  assert.deepEqual(state.statuses, [{ ...repo, sha: head, state: "pending", context: "Visual review", description: review.description,
    target_url: comment(state).html_url }]);
  assert.deepEqual(state.deleted, [old.name]);
  // Reconciling again uploads nothing new.
  await reconcile(github, runEvent(), { app: artifact() });
  assert.equal(state.uploads.length, 3);
});

test("visual-ok approves the screens shown before it, survives a rerun of them, and comes off for others", async () => {
  const { github, state, label, run } = fakeGitHub();
  await reconcile(github, runEvent(), { app: artifact() });
  label();
  assert.deepEqual((await reconcile(github, prEvent("labeled"))).review, { state: "success", description: "1 changed screen approved.", removeLabel: false });
  assert.equal(state.statuses.at(-1).state, "success");
  run();
  assert.deepEqual([(await reconcile(github, runEvent(), { app: artifact() })).review.state, state.labels], ["success", ["visual-ok"]]);
  run();
  const changed = (await reconcile(github, runEvent(), { app: artifact([255, 0, 0, 255]) })).review;
  assert.deepEqual([changed.state, state.labels], ["pending", []]);
  assert.match(comment(state).body, /`visual-ok` was taken off/);
  assert.equal(state.comments.length, 1);
  assert.equal(state.statuses.at(-1).state, "pending");
});

test("an approval holds even when the event of its label never ran", async () => {
  const { github, state, label, run } = fakeGitHub();
  await reconcile(github, runEvent(), { app: artifact() });
  label();
  // GitHub dropped the label's reconcile; the next run's reconcile still sees the label came after the screens.
  run();
  assert.equal((await reconcile(github, runEvent(), { app: artifact() })).review.state, "success");
  assert.deepEqual(state.labels, ["visual-ok"]);
});

test("visual-ok added before the screens appeared comes off, and removing it sends the review back to pending", async () => {
  const { github, state, label } = fakeGitHub();
  label();
  assert.equal((await reconcile(github, runEvent(), { app: artifact() })).review.state, "pending");
  assert.deepEqual(state.labels, []);
  label();
  assert.equal((await reconcile(github, prEvent("labeled"))).review.state, "success");
  state.labels = [];
  assert.equal((await reconcile(github, prEvent("unlabeled"))).review.state, "pending");
});

test("a label added while a newer head is drawn leaves the status to that head's run", async () => {
  const { github, state, label } = fakeGitHub();
  await reconcile(github, runEvent(), { app: artifact() });
  state.pr.head = { ...state.pr.head, sha: oldHead };
  label();
  const statuses = state.statuses.length;
  assert.equal((await reconcile(github, prEvent("labeled"))).action, "review");
  assert.equal(state.statuses.length, statuses);
});

test("a changed base sends the review back to pending until a new run", async () => {
  const { github, state, label } = fakeGitHub();
  await reconcile(github, runEvent(), { app: artifact() });
  label();
  await reconcile(github, prEvent("labeled"));
  state.pr.base = { sha: "d".repeat(40), ref: "develop" };
  const { review } = await reconcile(github, prEvent("edited", { changes: { base: { ref: { from: "main" } } } }));
  assert.deepEqual(review, { state: "pending", description: "The base changed: push a commit to compare the screens with it.", removeLabel: false });
  assert.match(comment(state).body, /\*\*Visual review:\*\* The base changed/);
});

test("lookalike comments are ignored", async () => {
  const lookalike = { id: 1, user: { login: "someone" }, body: `<!-- stablebar-screens -->\n<!-- stablebar-screens-data ${JSON.stringify({
    head, base, baseRef: "main", runId: 99, runAttempt: 1, ranScreens: true, fingerprint: "f".repeat(64), shownAt: "2000-01-01T00:00:00Z",
    total: 1, changed: 1, failed: 0, failure: null })} -->` };
  const { github, state, label } = fakeGitHub({ comments: [lookalike] });
  label();
  assert.equal((await reconcile(github, prEvent("labeled"))).action, "publish");
  assert.equal(state.comments.length, 2);
  assert.equal(state.statuses.at(-1).state, "failure");
});

test("a run that drew no screens passes without a comment, or rewrites the one an earlier head left", async () => {
  const { github, state, run } = fakeGitHub();
  state.jobs[99] = jobsOf({ "Check revision": "success", "Build release": "skipped", "Draw screens": "skipped", "Draw website screens": "skipped" });
  state.artifacts[99] = [];
  state.files = ["docs/README.md"];
  assert.deepEqual((await reconcile(github, runEvent())).review, { state: "success", description: "No screens to compare.", removeLabel: false });
  assert.deepEqual([state.comments.length, state.statuses[0].state], [0, "success"]);
  state.files = ["Sources/StableBar/BarView.swift"];
  run();
  await reconcile(github, runEvent(), { app: artifact() });
  run({ jobs: { "Check revision": "success", "Build release": "skipped", "Draw screens": "skipped", "Draw website screens": "skipped" }, artifacts: [] });
  state.files = ["docs/README.md"];
  await reconcile(github, runEvent());
  assert.match(comment(state).body, /changes neither the app nor the website/);
  assert.equal(readData(comment(state).body).ranScreens, false);
});

test("failed and missing jobs, and screens the changed files call for, fail the review", async () => {
  const cases = [
    [{ "Check revision": "success", "Build release": "failure", "Draw screens": "skipped", "Draw website screens": "skipped" }, [],
      "Build release ended with failure, so Draw screens didn't run."],
    [{ "Check revision": "success", "Build release": "success", "Draw website screens": "skipped" }, [], "Draw screens is missing from this CI run."],
    [{ "Check revision": "success", "Build release": "success", "Draw screens": "skipped", "Draw website screens": "skipped" }, [],
      "Draw screens was skipped, but this pull request changes what it draws."],
    [{ ...conclusions, "Draw screens": "cancelled" }, [], "Draw screens ended with cancelled."],
  ];
  for (const [jobs, artifacts, error] of cases) {
    const { github, state } = fakeGitHub();
    state.jobs[99] = jobsOf(jobs);
    state.artifacts[99] = artifacts;
    assert.equal((await reconcile(github, runEvent())).review.state, "failure", error);
    assert.ok(comment(state).body.includes(`- \`app\`: \`${error}\``), error);
  }
});

test("unusable artifacts are refused whole", async () => {
  const refused = async (folder, expected, kind = "app") => {
    const { github, state } = fakeGitHub();
    if (kind === "site") {
      state.jobs[99] = jobsOf({ "Check revision": "success", "Build release": "skipped", "Draw screens": "skipped", "Draw website screens": "success" });
      state.artifacts[99] = [{ name: "screens-site" }];
      state.files = ["site/index.html"];
    }
    assert.equal((await reconcile(github, runEvent(), { [kind]: folder })).review.state, "failure");
    assert.match(comment(state).body, expected);
    assert.equal(state.uploads.length, 0);
  };
  const linked = artifact();
  symlinkSync("/etc/hosts", join(linked, "hosts.png"));
  await refused(linked, /The screens-app artifact can't be used: 'hosts\.png': not a regular file\./);
  await refused(artifact(), /its id isn't site\/ followed by a plain name/, "site");
  const unreadable = artifact();
  writeFileSync(join(unreadable, "docs~hero-dark-diff.png"), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  await refused(unreadable, /'docs~hero-dark-diff\.png' isn't a PNG the bot can read/);
  const empty = mkdtempSync(join(tmpdir(), "artifact-"));
  writeFileSync(join(empty, "manifest.json"), JSON.stringify({ screens: [], failed: [] }));
  await refused(empty, /The screens-app artifact can't be used: It holds no screens\./);
  const scenes = mkdtempSync(join(tmpdir(), "artifact-"));
  writeFileSync(join(scenes, "manifest.json"), JSON.stringify({ screens: [{ id: "scenes/bar-dark", status: "unchanged", changedPixels: 0,
    region: null, images: {} }], failed: [] }));
  await refused(scenes, /It holds no docs images\./);
});

/** `file` with a text chunk after its header: other bytes, the same pixels. */
function withText(file) {
  const png = readFileSync(file);
  const body = Buffer.concat([Buffer.from("tEXt", "latin1"), Buffer.from("Comment\0from a pull request", "latin1")]);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(body.length - 4);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body));
  writeFileSync(file, Buffer.concat([png.subarray(0, 33), length, body, crc, png.subarray(33)]));
}

test("a publication uploads its own encoding of the pixels, and fingerprints the pixels", async () => {
  const { github, state, run } = fakeGitHub();
  const plain = artifact();
  await reconcile(github, runEvent(), { app: plain });
  const first = readData(comment(state).body).fingerprint;
  const uploaded = state.uploads.find((upload) => upload.name.endsWith("after.png"));
  assert.deepEqual(uploaded.data, encodePNG(decodePNG(readFileSync(join(plain, "docs~hero-dark-after.png")))));
  const texted = artifact();
  for (const kind of ["before", "after", "diff"]) withText(join(texted, `docs~hero-dark-${kind}.png`));
  run();
  await reconcile(github, runEvent(), { app: texted });
  assert.equal(readData(comment(state).body).fingerprint, first);
  assert.ok(!state.uploads.at(-1).data.includes("from a pull request"));
});

test("a publication moves on to the month's next release when one is full", async () => {
  const month = releaseTag(new Date());
  const full = { id: 3, tag_name: month, assets: Array.from({ length: 999 }, (_, index) => ({ id: 10000 + index, name: `pr1-1234567-${index}.png` })) };
  const { github, state } = fakeGitHub({ releases: [full] });
  await reconcile(github, runEvent(), { app: artifact() });
  const next = state.releases.find((release) => release.tag_name === `${month}-2`);
  assert.deepEqual([full.assets.length, next?.assets.length, next?.prerelease], [999, 3, true]);
  assert.match(comment(state).body, /download\/pr7-aaaaaaa-docs\.hero-dark-after\.png/);
});

test("closing unmerged deletes the images from every month; merging keeps them; a closed pull request publishes nothing", async () => {
  const { github, state } = fakeGitHub({ releases: [
    { id: 1, tag_name: "pr-previews-2026-09", assets: [{ id: 11, name: "pr8-aaaaaaa-a.png" }] },
    { id: 2, tag_name: "pr-previews-2026-10", assets: [{ id: 21, name: "pr7-bbbbbbb-b.png" }] },
    { id: 3, tag_name: "v1.0.0", assets: [{ id: 31, name: "pr7-ccccccc-StableBar.dmg" }] }] });
  await reconcile(github, runEvent(), { app: artifact() });
  state.pr.state = "closed";
  assert.deepEqual(await reconcile(github, prEvent("closed")), { action: "close", deleted: 3 });
  assert.deepEqual(state.releases.slice(0, 3).map((release) => [release.tag_name, release.assets.map((asset) => asset.name)]),
    [["pr-previews-2026-09", ["pr8-aaaaaaa-a.png"]], ["pr-previews-2026-10", []], ["v1.0.0", ["pr7-ccccccc-StableBar.dmg"]]]);
  assert.match(comment(state).body, /closed without merging, so the images of its screens were deleted/);
  assert.deepEqual(await reconcile(github, runEvent(), { app: artifact() }), { action: "none" });
  assert.equal(state.uploads.length, 3);
  const merged = fakeGitHub();
  await reconcile(merged.github, runEvent(), { app: artifact() });
  Object.assign(merged.state.pr, { state: "closed", merged: true });
  assert.deepEqual(await reconcile(merged.github, prEvent("closed")), { action: "close", deleted: 0 });
  assert.equal(merged.state.deleted.length, 0);
});

test("failRun marks an open pull request's head when the bot itself fails", async () => {
  const { github, state } = fakeGitHub();
  await failRun({ github, context: runEvent(), number: 7 });
  assert.deepEqual(state.statuses, [{ ...repo, sha: head, state: "error", context: "Visual review",
    description: "The screens bot failed: see the Screens workflow run.", target_url: "https://github.com/Seb-GRAF/StableBar/actions/runs/5" }]);
  await failRun({ github, context: runEvent(), number: undefined });
  assert.equal(state.statuses.length, 1);
});

test("changePatterns call for screens when the files the scenes read change", () => {
  for (const file of ["Sources/StableBar/BarView.swift", "Resources/config.json", "scenes/starter-bar.json", "examples/essentials.json"]) {
    assert.equal(changePatterns.app.test(file), true, file);
  }
  assert.equal(changePatterns.app.test("docs/README.md"), false);
  assert.equal(changePatterns.site.test("site/index.html"), true);
});

test("changePatterns match the files CI's Check revision job draws screens for", () => {
  const workflow = readFileSync(new URL("../workflows/ci.yml", import.meta.url), "utf8");
  const found = Object.fromEntries([...workflow.matchAll(/grep -qE '([^']+)' <<< "\$changed"; then\n\s+echo "(\w+)=true"/g)]
    .map(([, pattern, output]) => [output, pattern]));
  // A JavaScript pattern's source writes "/" as "\/".
  const grep = (pattern) => pattern.source.replaceAll("\\/", "/");
  assert.deepEqual({ app: grep(changePatterns.app), site: grep(changePatterns.site) }, { app: found.screens, site: found.site });
});
