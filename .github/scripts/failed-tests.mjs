// Reads the xUnit report Swift Testing writes and the Test step's output, and says whether CI may run
// the failed tests once more on their own: { names, filter } on success, { error } otherwise. With
// --passed REPORT PLAN, says whether the retry's report shows each test of that plan passing.
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

/** Each test case in `xml`: its name, such as `aTest()` or `aTest(value:)`, and what's inside it. */
const testCases = (xml) =>
  [...xml.matchAll(/<testcase\b([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g)].flatMap(([, attributes, , body = ""]) => {
    const name = /\bname="([^"]*)"/.exec(attributes)?.[1];
    return name === undefined ? [] : [{ name: decode(name), body }];
  });

/** The names of the test cases in `xml` that recorded a failure or an error. */
export function failedTests(xml) {
  return [...new Set(testCases(xml).filter(({ body }) => /<(failure|error)\b/.test(body)).map(({ name }) => name))];
}

/** The failures and errors the suites count, against those recorded inside a test case. */
function failureCounts(xml) {
  let total = 0;
  for (const [, attributes] of xml.matchAll(/<testsuite\b([^>]*)>/g)) {
    for (const key of ["failures", "errors"]) total += Number(new RegExp(`\\b${key}="(\\d+)"`).exec(attributes)?.[1] ?? 0);
  }
  const inTests = testCases(xml).reduce((count, { body }) => count + (body.match(/<(failure|error)\b/g)?.length ?? 0), 0);
  return { total, inTests };
}

/** A `swift test --filter` pattern that matches each name as written. */
export const filterFor = (names) => names.map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");

/** Whether the failed run may be retried, from its xUnit report and its output. */
export function retryPlan(xml, output) {
  if (/Test Case '[^']*' failed/.test(output)) return { error: "An XCTest test failed. Only Swift Testing tests run again." };
  if (/unexpected signal code|Fatal error:|exited with signal/.test(output)) return { error: "The test run crashed, so no test runs again." };
  const names = failedTests(xml);
  if (names.length === 0) return { error: "The test run failed, but its report lists no failed Swift Testing test to run again." };
  const { total, inTests } = failureCounts(xml);
  if (total > inTests) return { error: `The report counts ${total} failures but names tests for only ${inTests}, so the others can't run again.` };
  if (names.length > maxRetried) return { error: `${names.length} tests failed, more than the ${maxRetried} that run again.` };
  return { names, filter: filterFor(names) };
}

/** Whether the retry's report `xml` shows each of `names` passing: run, not skipped, and without a failure. */
export function retryPassed(xml, names) {
  const cases = testCases(xml);
  const unproven = names.filter((name) => {
    const runs = cases.filter((testCase) => testCase.name === name);
    return runs.length === 0 || runs.some(({ body }) => /<(failure|error|skipped)\b/.test(body));
  });
  if (unproven.length > 0) return { error: `The retry didn't show these tests passing: ${unproven.join(", ")}.` };
  return { names };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const args = process.argv.slice(2);
  const passed = args[0] === "--passed";
  const [report, ...rest] = passed ? args.slice(1) : args;
  let xml = "";
  try {
    xml = readFileSync(report, "utf8");
  } catch {
    console.log(JSON.stringify({ error: `There's no test report at ${report}.` }));
    process.exit(0);
  }
  console.log(JSON.stringify(passed ? retryPassed(xml, JSON.parse(rest[0]).names) : retryPlan(xml, readFileSync(rest[0], "utf8"))));
}
