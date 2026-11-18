import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { failedTests, filterFor, maxRetried, retryPassed, retryPlan } from "./failed-tests.mjs";

/**
 * A report as Swift Testing writes it: `cases` maps each test's name to its failure message, "skipped", or null when
 * it passed. The suite counts one failure per failed test, plus `unnamed` failures recorded outside any test.
 */
const report = (cases, unnamed = 0) => `<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="${Object.keys(cases).length}" failures="${Object.values(cases).filter((value) => value !== null && value !== "skipped").length + unnamed}" skipped="0" time="9.5">
${Object.entries(cases).map(([name, failure]) => failure === null
    ? `    <testcase classname="StableBarTests" name="${name}" time="0.1" />`
    : failure === "skipped"
      ? `    <testcase classname="StableBarTests" name="${name}" time="0" >\n      <skipped />\n    </testcase>`
      : `    <testcase classname="StableBarTests" name="${name}" time="74.9" >\n      <failure message="${failure}" />\n    </testcase>`).join("\n")}
  </testsuite>
</testsuites>
`;

const output = "✘ Test aTest() failed after 74.942 seconds with 1 issue.\n✘ Test run with 3 tests in 0 suites failed after 9.5 seconds with 1 issue.\n";

test("failedTests lists the test cases that recorded a failure, by their names as written", () => {
  const xml = report({
    "passes()": null,
    "timesOut()": "Expectation failed: (store.actionErrors &#8594; [&quot;replace&quot;: &quot;timed out&quot;]).isEmpty",
    "rejects(json:)": "Expectation failed",
    "a&amp;b()": "Expectation failed",
  });
  assert.deepEqual(failedTests(xml), ["timesOut()", "rejects(json:)", "a&b()"]);
  assert.deepEqual(failedTests(report({ "passes()": null })), []);
});

test("filterFor matches each name literally", () => {
  const filter = filterFor(["timesOut()", "rejects(json:)", "odd.name[1]*()"]);
  assert.equal(filter, String.raw`timesOut\(\)|rejects\(json:\)|odd\.name\[1\]\*\(\)`);
  const pattern = new RegExp(filter);
  assert.ok(pattern.test("StableBarTests/timesOut()"));
  assert.ok(pattern.test("rejects(json:)"));
  assert.ok(!pattern.test("timesOutLater()"));
});

test("retryPlan runs a few failed Swift Testing tests again, and nothing after XCTest failures, crashes or many failures", () => {
  assert.deepEqual(retryPlan(report({ "aTest()": "Expectation failed", "other()": null }), output),
    { names: ["aTest()"], filter: String.raw`aTest\(\)` });
  assert.match(retryPlan(report({ "aTest()": "Expectation failed" }),
    `${output}Test Case '-[StableBarTests.PackagesViewTests testReview]' failed (1.2 seconds).\n`).error, /XCTest/);
  assert.match(retryPlan(report({ "aTest()": "Expectation failed" }), `${output}error: Exited with unexpected signal code 6\n`).error, /crashed/);
  assert.match(retryPlan(report({ "passes()": null }), output).error, /lists no failed/);
  assert.match(retryPlan(report({ "aTest()": "Expectation failed" }, 1), output).error, /counts 2 failures but names tests for only 1/);
  const many = Object.fromEntries(Array.from({ length: maxRetried + 1 }, (_, index) => [`test${index}()`, "failed"]));
  assert.match(retryPlan(report(many), output).error, new RegExp(`${maxRetried + 1} tests failed`));
  const few = Object.fromEntries(Array.from({ length: maxRetried }, (_, index) => [`test${index}()`, "failed"]));
  assert.equal(retryPlan(report(few), output).names.length, maxRetried);
});

test("retryPassed needs each retried test to have run and passed", () => {
  const names = ["aTest()", "rejects(json:)"];
  assert.deepEqual(retryPassed(report({ "aTest()": null, "rejects(json:)": null }), names), { names });
  assert.match(retryPassed(report({ "aTest()": null }), names).error, /rejects\(json:\)/);
  assert.match(retryPassed(report({ "aTest()": null, "rejects(json:)": "skipped" }), names).error, /rejects\(json:\)/);
  assert.match(retryPassed(report({ "aTest()": "Expectation failed", "rejects(json:)": null }), names).error, /aTest\(\)/);
});

test("the command prints the plan as JSON, and an error when the report is missing", () => {
  const folder = mkdtempSync(join(tmpdir(), "failed-tests-"));
  writeFileSync(join(folder, "results-swift-testing.xml"), report({ "aTest()": "Expectation failed" }));
  writeFileSync(join(folder, "output.txt"), output);
  const run = (...files) => JSON.parse(execFileSync(process.execPath, [new URL("./failed-tests.mjs", import.meta.url).pathname, ...files], { encoding: "utf8" }));
  assert.deepEqual(run(join(folder, "results-swift-testing.xml"), join(folder, "output.txt")), { names: ["aTest()"], filter: String.raw`aTest\(\)` });
  assert.match(run(join(folder, "missing.xml"), join(folder, "output.txt")).error, /no test report/);
  writeFileSync(join(folder, "retry-swift-testing.xml"), report({ "aTest()": null }));
  const plan = JSON.stringify({ names: ["aTest()"], filter: String.raw`aTest\(\)` });
  assert.deepEqual(run("--passed", join(folder, "retry-swift-testing.xml"), plan), { names: ["aTest()"] });
  assert.match(run("--passed", join(folder, "results-swift-testing.xml"), plan).error, /aTest\(\)/);
});
