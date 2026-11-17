// Decides whether a pull request gets the deep-review label, which starts a CodeRabbit review.
// .github/workflows/deep-review.yml runs the default branch's copy of this module, so a pull request
// never runs its own.
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";

export const deepReviewPaths = readFileSync(new URL("../deep-review-paths", import.meta.url), "utf8").trim().split("\n");

export function needsDeepReview(files, changedLines) {
  return changedLines > 400 || files.some((file) => deepReviewPaths.some((path) => matchesGlob(file, path)));
}

// Whether to add the label anew, which asks CodeRabbit again: it hasn't reviewed the head commit, and
// its summary comment says it hit the review limit, or it never answered. CodeRabbit doesn't retry by
// itself. A pull request updated in the last 30 minutes may still have a review on the way.
export function needsRetry({ headSha, updatedAt, reviews, comments, now }) {
  const fromCodeRabbit = (item) => item.user.login === "coderabbitai[bot]";
  if (now - Date.parse(updatedAt) < 30 * 60 * 1000) return false;
  if (reviews.some((review) => fromCodeRabbit(review) && review.commit_id === headSha)) return false;
  const answers = comments.filter(fromCodeRabbit);
  return answers.length === 0 || answers.some((comment) => comment.body.includes("rate limited by coderabbit.ai"));
}
