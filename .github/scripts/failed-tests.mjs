// Reads the xUnit report Swift Testing writes and the Test step's output, and says whether CI may run
// the failed tests once more on their own: { names, filter } on success, { error } otherwise.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/** More failures than this point to a real breakage, not to a busy runner. */
export const maxRetried = 5;

const entities = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
const decode = (text) =>
  text.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (whole, entity) =>
    entity[0] === "#"
      ? String.fromCodePoint(entity[1].toLowerCase() === "x" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10))
      : entities[entity] ?? whole);

/** The names of the test cases in `xml` that recorded a failure or an error, such as `aTest()` or `aTest(value:)`. */
export function failedTests(xml) {
  const names = new Set();
  for (const [, attributes, , body = ""] of xml.matchAll(/<testcase\b([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g)) {
    if (!/<(failure|error)\b/.test(body)) continue;
    const name = /\bname="([^"]*)"/.exec(attributes)?.[1];
    if (name) names.add(decode(name));
  }
  return [...names];
}

/** A `swift test --filter` pattern that matches each name as written. */
export const filterFor = (names) => names.map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");

/** Whether the failed run may be retried, from its xUnit report and its output. */
export function retryPlan(xml, output) {
  if (/Test Case '[^']*' failed/.test(output)) return { error: "An XCTest test failed. Only Swift Testing tests run again." };
  if (/unexpected signal code|Fatal error:|exited with signal/.test(output)) return { error: "The test run crashed, so no test runs again." };
  const names = failedTests(xml);
  if (names.length === 0) return { error: "The test run failed, but its report lists no failed Swift Testing test to run again." };
  if (names.length > maxRetried) return { error: `${names.length} tests failed, more than the ${maxRetried} that run again.` };
  return { names, filter: filterFor(names) };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const [report, output] = process.argv.slice(2);
  let xml = "";
  try {
    xml = readFileSync(report, "utf8");
  } catch {
    console.log(JSON.stringify({ error: `There's no test report at ${report}.` }));
    process.exit(0);
  }
  console.log(JSON.stringify(retryPlan(xml, readFileSync(output, "utf8"))));
}
