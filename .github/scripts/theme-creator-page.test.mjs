import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import builtIn from "../../site/creator/built-in.mjs";
import * as theme from "../../site/creator/theme.mjs";
import * as files from "../../site/creator/files.mjs";
import * as preview from "../../site/creator/preview.mjs";

const source = readFileSync(new URL("../../site/creator/page.mjs", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "").replace(/\nstart\(\)\.catch\([^\n]+\);\s*$/, "");

function pageHarness() {
  const events = new Map(), dialogEvents = new Map(), fields = new Map();
  const element = () => {
    const children = new Map();
    return {
      value: "", disabled: false, textContent: "", dataset: {}, focus() {}, setAttribute() {},
      classList: { add() {}, remove() {} }, querySelectorAll: () => [],
      querySelector(selector) {
        if (!children.has(selector)) children.set(selector, element());
        return children.get(selector);
      },
    };
  };
  const root = element();
  const dialog = {
    open: false, innerHTML: "", showModal() { this.open = true; }, close() { this.open = false; },
    querySelector(selector) {
      if (!fields.has(selector)) fields.set(selector, element());
      return fields.get(selector);
    },
    addEventListener: (type, handler) => dialogEvents.set(type, handler),
  };
  const context = {
    ...theme, ...files, ...preview, builtIn, structuredClone,
    matchMedia: () => ({ matches: false }),
    document: {
      querySelector: selector => selector === "#creator" ? root : selector === "#theme-dialog" ? dialog : element(),
      addEventListener: (type, handler) => events.set(type, handler),
    },
    window: { addEventListener() {} },
  };
  runInNewContext(source, context);
  const run = code => runInNewContext(code, context);
  const close = () => events.get("click")({ target: {
    closest: () => ({ disabled: false, dataset: { action: "close" } }),
  } });
  return { events, dialogEvents, fields, root, dialog, context, run, close };
}

function storePage(patch = {}) {
  const page = pageHarness();
  page.context.themeState = {
    manifest: { id: "ocean-night", name: "Ocean night", description: "Blue and grey", version: "1.0.0", ...patch },
    config: {},
  };
  page.run("state = themeState; store = { status: 'free' }");
  page.dialog.open = true;
  return page;
}

test("the kept-settings note uses singular and plural wording", () => {
  for (const [config, expected] of [
    [{ roles: { time: { foreground: "#ffffff" } } },
      "1 setting stays in your files. This preview does not show it exactly."],
    [{ roles: { time: { foreground: "#ffffff" } }, groups: [] },
      "2 settings stay in your files. This preview does not show them exactly."],
  ]) {
    const page = storePage();
    page.context.keptConfig = config;
    page.run("state.config = keptConfig; updateJSON()");
    const html = page.root.querySelector(".kept").innerHTML;
    assert.equal(html.match(/<summary>(.*?)<\/summary>/)[1], expected);
  }
});

test("popup spacing controls display the effective defaults", () => {
  const page = storePage();
  for (const [id, expected] of [
    ["popups.paddingHorizontal", 16], ["popups.paddingVertical", 16], ["popups.spacing", 12], ["popups.gap", 6],
  ]) {
    const actual = page.run(`controlValue(CONTROLS.find(control => control.id === '${id}'), resolved())`);
    assert.equal(actual, expected, id);
  }
});

test("the Store guide refuses pipes and line breaks in either text field without blocking download or share", async () => {
  const reason = "The Store's table can't show a | or a line break in the name or description. Remove it to submit.";
  for (const field of ["name", "description"]) {
    for (const separator of ["|", "\n", "\r", "\r\n", "\u2028", "\u2029"]) {
      const page = storePage({ [field]: `Ocean${separator}night` });
      page.run("updateOutputs()");
      const section = page.dialog.querySelector("[data-store-row]");
      assert.equal(section.querySelector("[data-store-error]").textContent, reason, `${field}: ${JSON.stringify(separator)}`);
      assert.equal(section.querySelector(".readme-box").hidden, true);
      assert.equal(section.querySelector("pre").textContent, "");
      const edit = section.querySelector('[data-action="about"]');
      assert.equal(edit.hidden, false);
      assert.equal(edit.dataset.aboutField, field);
      assert.equal(page.root.querySelector('[data-action="download"]').disabled, false);
      assert.equal(page.dialog.querySelector('[data-action="download"]').disabled, false);
      assert.equal(page.root.querySelector('[data-action="share"]').disabled, false);
      assert.equal(page.run("exportProblem()"), "");
      const themeState = page.run("state"), exported = files.themeFiles(themeState);
      assert.deepEqual(await files.readZip(files.writeZip(themeState.manifest.id, exported)), exported);
      const copied = [];
      page.context.navigator = { clipboard: { writeText: async text => copied.push(text) } };
      page.context.location = { href: "https://stablebar.app/create-theme.html" };
      await page.run("output('share')");
      assert.equal(copied.length, 1);
      assert.deepEqual(files.decodeLink(new URL(copied[0]).hash), exported);
      await assert.rejects(page.run("output('row')"), /invalidStoreText/);
      assert.equal(copied.length, 1);
    }
  }
});

test("the Store guide restores the exact row after correcting text and allows literal backslashes", async () => {
  const page = storePage({ name: "Ocean|night" });
  page.run("updateStoreGuide()");
  page.run("state.manifest.name = 'Ocean \\\\ night'; state.manifest.description = 'Blue \\\\ grey'; updateStoreGuide()");
  const section = page.dialog.querySelector("[data-store-row]");
  const expected = files.readmeRow(page.run("state.manifest"));
  assert.equal(expected, "|  | **[Ocean \\ night](packages/ocean-night)**<br>Blue \\ grey | No commands |");
  assert.equal(section.querySelector("[data-store-error]").textContent, "");
  assert.equal(section.querySelector(".readme-box").hidden, false);
  assert.equal(section.querySelector("pre").textContent, expected);
  assert.equal(section.querySelector('[data-action="about"]').hidden, true);
  const copied = [];
  page.context.navigator = { clipboard: { writeText: async text => copied.push(text) } };
  await page.run("output('row')");
  assert.deepEqual(copied, [expected]);
});

test("remixing keeps compatibility while dropping ownership and resetting the version", () => {
  const page = pageHarness();
  page.context.imported = {
    manifest: { id: "original", name: "Original", version: "2.3.4", author: "original-author",
      minimumVersion: "0.15.0", repository: "https://github.com/example/original" },
    config: { defaults: { fontSize: 15 } },
  };
  page.run("pendingTheme = imported; renderControls = refresh = resetStoreCheck = scheduleStoreCheck = notify = () => {};");
  page.dialog.querySelector('[name="reopen"]:checked').value = "remix";
  page.dialog.querySelector("#new-theme-name").value = "Ocean night";
  page.run("continueReopen()");
  const output = JSON.parse(files.themeFiles(page.run("state")).manifestText);
  assert.equal(output.minimumVersion, "0.15.0");
  assert.equal(output.id, "ocean-night");
  assert.equal(output.name, "Ocean night");
  assert.equal(output.version, "1.0.0");
  assert.equal(Object.hasOwn(output, "author"), false);
  assert.equal(Object.hasOwn(output, "repository"), false);
  assert.deepEqual(page.run("state.config"), page.context.imported.config);
});

test("gradient color edits show the edited color and keep the other appearance's gradient selector", () => {
  const page = pageHarness();
  const config = { bar: { style: { background: { gradient: {
    colors: ["#123456", "#abcdef"], angle: 180, locations: [0, 1],
  } } } } };
  page.context.edited = theme.applyControl({ config }, "bar.background", "#ff0000", "light");
  page.run("state = edited");
  const value = appearance => page.run(`controlValue(CONTROLS.find(c => c.id === 'bar.background'),
    resolveTheme(builtIn, state.config, '${appearance}'))`);
  assert.equal(value("light"), "#ff0000");
  assert.deepEqual(value("dark"), config.bar.style.background);
});

function delayedFolder(id) {
  let resolveEntries, rejectEntries, enumerated = false;
  const manifest = { id, name: id, version: "1.0.0", kind: "theme", entry: "config.json" };
  const entries = Object.entries({ "package.json": manifest, "config.json": {} }).map(([name, value]) => ({
    name, isFile: true, file: resolve => resolve({ size: 100, text: async () => JSON.stringify(value) }),
  }));
  const transfer = {
    types: ["Files"], items: [{ webkitGetAsEntry: () => ({
      name: id, isDirectory: true, createReader: () => ({ readEntries(resolve, reject) {
        if (enumerated) resolve([]);
        else { enumerated = true; resolveEntries = resolve; rejectEntries = reject; }
      } }),
    }) }],
  };
  return { transfer, release: () => resolveEntries(entries), reject: () => rejectEntries(new Error("Folder read failed.")) };
}

const drop = (page, folder) => page.events.get("drop")({ dataTransfer: folder.transfer, preventDefault() {} });

test("closing during folder enumeration cancels the import before it can reopen the dialog", async () => {
  for (const reject of [false, true]) {
    const page = pageHarness(), folder = delayedFolder("cancelled-theme");
    const pending = drop(page, folder);
    assert.equal(page.dialog.open, true);
    await page.close();
    reject ? folder.reject() : folder.release();
    await pending;
    assert.equal(page.dialog.open, false);
    assert.equal(page.run("pendingTheme"), undefined);
    assert.equal(page.dialog.querySelector("[data-import-error]").textContent, "");
  }
});

test("a folder drop cannot supersede a newer import after slow enumeration", async () => {
  for (const reject of [false, true]) {
    const page = pageHarness(), old = delayedFolder("old-theme"), latest = delayedFolder("latest-theme");
    const first = drop(page, old), second = drop(page, latest);
    latest.release();
    await second;
    assert.equal(page.run("pendingTheme.manifest.id"), "latest-theme");
    const dialog = page.dialog.innerHTML;
    reject ? old.reject() : old.release();
    await first;
    assert.equal(page.run("pendingTheme.manifest.id"), "latest-theme");
    assert.equal(page.dialog.innerHTML, dialog);
    assert.equal(page.dialog.querySelector("[data-import-error]").textContent, "Opening theme…");
  }
});
