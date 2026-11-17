// Decides whether a pull request gets the deep-review label, which starts a CodeRabbit review.
// .github/workflows/deep-review.yml runs the default branch's copy of this module, so a pull request
// never runs its own.
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";

export const deepReviewPaths = readFileSync(new URL("../deep-review-paths", import.meta.url), "utf8").trim().split("\n");

export function needsDeepReview(files, changedLines) {
  return changedLines > 400 || files.some((file) => deepReviewPaths.some((path) => matchesGlob(file, path)));
}

// Whether to add the label anew, which asks CodeRabbit again: at least 30 minutes ago, its summary
// comment said it hit the review limit on the head commit. CodeRabbit doesn't retry by itself, and
// drops the notice once it reviews.
export function needsRetry({ headSha, comments, now }) {
  return comments.some((comment) => comment.user.login === "coderabbitai[bot]"
    && comment.body.includes("rate limited by coderabbit.ai") && comment.body.includes(headSha)
    && now - Date.parse(comment.updated_at) >= 30 * 60 * 1000);
}
