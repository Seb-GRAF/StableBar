// Decides whether a pull request gets the deep-review label, which starts a CodeRabbit review.
// .github/workflows/deep-review.yml runs the default branch's copy of this module, so a pull request
// never runs its own.
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";

export const deepReviewPaths = readFileSync(new URL("../deep-review-paths", import.meta.url), "utf8").trim().split("\n");

export function needsDeepReview(files, changedLines) {
  return changedLines > 400 || files.some((file) => deepReviewPaths.some((path) => matchesGlob(file, path)));
}

// Whether to add the label anew, which asks CodeRabbit again: since the head commit, CodeRabbit either
// hasn't answered or answered that it hit its review limit. It rewrites its summary comment on each
// attempt, and doesn't retry by itself. A pull request updated in the last 30 minutes may still have
// a review on the way.
export function needsRetry({ headDate, updatedAt, comments, now }) {
  if (now - Date.parse(updatedAt) < 30 * 60 * 1000) return false;
  const answers = comments.filter((comment) =>
    comment.user.login === "coderabbitai[bot]" && Date.parse(comment.updated_at) >= Date.parse(headDate));
  return answers.length === 0 || answers.some((comment) => comment.body.includes("rate limited by coderabbit.ai"));
}
