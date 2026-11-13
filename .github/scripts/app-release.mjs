import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { analyzeCommits as analyze } from "@semantic-release/commit-analyzer";
import { generateNotes as writeNotes } from "@semantic-release/release-notes-generator";

const appPaths = readFileSync(new URL("../app-paths", import.meta.url), "utf8").trim().split("\n");
const releases = { feat: "minor", fix: "patch", perf: "patch", refactor: "patch" };

export async function analyzeCommits(_config, context) {
  const git = (...args) => execFileSync("git", args, { cwd: context.cwd, encoding: "utf8" }).trim();
  const commits = context.commits.filter(({ hash, message }) => {
    const header = message.match(/^(\w+)(\([^)]*\))?!?: /);
    return header && Object.hasOwn(releases, header[1]) &&
      git("diff-tree", "--root", "--diff-merges=first-parent", "--no-commit-id", "--name-only", "-r", hash, "--", ...appPaths) !== "";
  });
  const options = {
    preset: "conventionalcommits",
    releaseRules: [
      { breaking: true, release: "major" },
      ...Object.entries(releases).map(([type, release]) => ({ type, release })),
    ],
  };

  if (context.env.STABLEBAR_RELEASE_CHANNEL === "beta") {
    const previous = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "--always");
    if (previous.startsWith("v")) {
      const pending = new Set(git("rev-list", `${previous}..HEAD`).split("\n"));
      const release = await analyze(options, { ...context, commits: commits.filter(({ hash }) => pending.has(hash)) });
      if (!release) {
        context.logger.log("No beta: no qualifying app changes since %s.", previous);
        return null;
      }
    }
  }

  return analyze(options, { ...context, commits });
}

export async function generateNotes(config, context) {
  const commits = await Promise.all(context.commits.map(async commit => {
    const { author } = await fetch(`https://api.github.com/repos/${context.env.GITHUB_REPOSITORY}/commits/${commit.hash}`,
      { headers: { Authorization: `Bearer ${context.env.GITHUB_TOKEN}` } })
      .then(response => response.json())
      .catch(() => ({}));
    return author ? { ...commit, message: commit.message.replace(/^.*/, `$& by @${author.login}`) } : commit;
  }));
  return writeNotes(config, { ...context, commits });
}
