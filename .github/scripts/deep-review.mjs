// Decides whether a pull request gets the deep-review label, which starts a CodeRabbit review.
// .github/workflows/deep-review.yml runs the default branch's copy of this module, so a pull request
// never runs its own.
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";

export const deepReviewPaths = readFileSync(new URL("../deep-review-paths", import.meta.url), "utf8").trim().split("\n");

export function needsDeepReview(files, changedLines) {
  return changedLines > 400 || files.some((file) => deepReviewPaths.some((path) => matchesGlob(file, path)));
}
