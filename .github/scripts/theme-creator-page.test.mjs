import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import builtIn from "../../site/creator/built-in.mjs";
import * as theme from "../../site/creator/theme.mjs";
import * as files from "../../site/creator/files.mjs";
import * as preview from "../../site/creator/preview.mjs";
import * as numbers from "../../site/creator/number-field.mjs";
import * as colors from "../../site/creator/color-field.mjs";

const source = readFileSync(new URL("../../site/creator/page.mjs", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "").replace(/\nstart\(\)\.catch\([^\n]+\);\s*$/, "");

function pageHarness() {
  const events = new Map(), dialogEvents = new Map(), fields = new Map();
  const element = () => {
    const children = new Map(), classes = new Set();
    return {
      value: "", type: "text", tagName: "INPUT", disabled: false, textContent: "", dataset: {},
      validity: { valid: true }, focus() {}, setAttribute() {}, hasAttribute: () => false,
      matches: () => false, closest: () => null, style: { setProperty() {} },
      dispatchEvent(event) { events.get(event.type)?.({ target: this }); return true; },
      classList: { add: name => classes.add(name), remove: name => classes.delete(name),
        contains: name => classes.has(name) }, querySelectorAll: () => [],
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
    ...theme, ...files, ...preview, ...numbers, ...colors, builtIn, structuredClone, Event,
    navigator: { platform: "MacIntel", userAgent: "Mac", maxTouchPoints: 0 },
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

function numberPage(id, config = {}) {
  const page = storePage();
  page.context.numberConfig = config;
  page.run("state.config = numberConfig");
  const input = page.root.querySelector(`[data-control="${id}"]`);
  input.dataset.control = id;
  input.value = String(page.run(`controlValue(CONTROLS.find(control => control.id === '${id}'), resolved())`) ?? "");
  return {
    ...page, input,
    type(value) { input.value = value; page.events.get("input")({ target: input }); },
    commit() { page.events.get("change")({ target: input }); },
    error: () => page.run(`fieldErrors.get('${id}')`),
    key(key, shiftKey = false) {
      let prevented = false;
      page.events.get("keydown")({ target: input, key, shiftKey, preventDefault() { prevented = true; } });
      return prevented;
    },
  };
}

test("number controls render imported text and boolean values and nudge numerically", () => {
  const page = numberPage("bar.height", { bar: { height: "40" }, defaults: { fontSize: true } });
  assert.doesNotThrow(() => page.run("renderControls()"));
  assert.equal(page.run("controlValue(CONTROLS.find(c => c.id === 'widgets.fontSize'), resolved())"), null);
  assert.equal(page.key("ArrowUp"), true);
  assert.equal(page.run("state.config.bar.height"), 41);
  assert.equal(page.input.value, "41");
});

test("number controls accept numeric tokens and reject nonfinite or nonnumeric values", () => {
  for (const [value, expected] of [
    ["24", 24], ["1,5", 1.5], [24, 24], [true, null], [false, null],
    ["invalid", null], ["Infinity", null], [Infinity, null], [NaN, null], [{}, null],
  ]) {
    const page = numberPage("widgets.paddingHorizontal", {
      tokens: { size: value }, defaults: { paddingHorizontal: "@token.size" },
    });
    assert.equal(page.run("controlValue(CONTROLS.find(c => c.id === 'widgets.paddingHorizontal'), resolved())"), expected);
    assert.doesNotThrow(() => page.run("renderControls()"));
  }
  const page = numberPage("widgets.paddingHorizontal", {
    tokens: { size: "10" }, defaults: { paddingHorizontal: "@token.size" },
  });
  page.key("ArrowUp");
  assert.equal(page.run("resolved().defaults.paddingHorizontal"), 11);
});

test("typing, nudging and committing a number clear a resting hover", () => {
  for (const action of ["type", "nudge", "commit"]) {
    const page = numberPage("widgets.paddingHorizontal");
    page.run("focusedControl = 'widgets.paddingHorizontal'; hoveredControl = 'widgets.paddingVertical'");
    if (action === "type") page.type("22");
    else if (action === "nudge") page.key("ArrowUp");
    else { page.input.value = "-"; page.key("Enter"); }
    assert.equal(page.run("hoveredControl"), undefined, action);
    assert.equal(page.run("focusedControl"), "widgets.paddingHorizontal", action);
  }
});

test("moving focus to a control clears a resting hover", () => {
  const page = numberPage("widgets.paddingHorizontal");
  page.input.closest = selector => selector === ".control" ? {} : null;
  page.run("hoveredControl = 'widgets.cornerRadius'");
  page.events.get("focusin")({ target: page.input });
  assert.equal(page.run("hoveredControl"), undefined);
  assert.equal(page.run("focusedControl"), "widgets.paddingHorizontal");
});

test("rendering controls preserves restored focus until another row is entered", () => {
  const page = numberPage("widgets.paddingHorizontal");
  const rowEvents = new Map();
  const row = {
    querySelector: () => ({ dataset: { control: "widgets.paddingVertical" } }),
    addEventListener: (type, handler) => rowEvents.set(type, handler),
    closest: () => row,
  };
  const query = page.root.querySelector;
  page.root.querySelector = selector => selector === ".control:hover" ? row : query(selector);
  page.root.querySelectorAll = selector => selector === ".control" ? [row] : [];
  page.input.id = "c-widgets-paddingHorizontal";
  page.input.closest = selector => selector === ".control" ? {} : null;
  page.input.setSelectionRange = () => {};
  page.input.focus = () => {
    page.context.document.activeElement = page.input;
    page.events.get("focusin")({ target: page.input });
  };
  page.context.document.getElementById = id => id === page.input.id ? page.input : null;
  page.input.focus();
  page.run("renderControls()");
  assert.equal(page.run("hoveredControl"), undefined);
  assert.equal(page.run("focusedControl"), "widgets.paddingHorizontal");
  rowEvents.get("pointerenter")();
  assert.equal(page.run("hoveredControl"), "widgets.paddingVertical");
  rowEvents.get("pointerleave")();
  assert.equal(page.run("hoveredControl"), undefined);
  page.context.document.activeElement = null;
  page.run("renderControls()");
  assert.equal(page.run("hoveredControl"), "widgets.paddingVertical");
});

test("number markup allows a minus sign for negative ranges and labels the three sliders", () => {
  const page = storePage();
  page.run("state.config = { workspaceDefaults: { indicator: 'underline' } }; renderControls()");
  const markup = group => page.root.querySelector(`[data-group="${group}"]`).innerHTML;
  const input = (group, id) => markup(group).match(new RegExp(`<input [^>]*data-control="${id}"[^>]*>`))[0];
  assert.doesNotMatch(input("workspaces", "workspaces.underlineOffsetY"), /inputmode="(?:decimal|numeric)"/);
  assert.match(input("bar", "bar.height"), /inputmode="decimal"/);
  const html = Object.keys(page.run("names")).map(markup).join("");
  const sliders = [...html.matchAll(/<input type="range"[^>]*>/g)].map(match => match[0]);
  assert.equal(sliders.length, 3);
  for (const [id, label] of [["bar.height", "Height"], ["bar.cornerRadius", "Strip corners"], ["widgets.fontSize", "Font size"]]) {
    assert.ok(sliders.some(slider => slider.includes(`data-slider-for="${id}"`) && slider.includes(`aria-label="${label}"`)), id);
  }
  const handles = [...html.matchAll(/<span class="scrub-handle"[^>]*>/g)].map(match => match[0]);
  assert.ok(handles.length > 3);
  for (const handle of handles) {
    assert.match(handle, /aria-hidden="true"/);
    assert.match(handle, /title="Drag to change\. Hold Shift for steps of 10\."/);
  }
});

test("the Popups intro names padding, spacing and gap", () => {
  const page = storePage();
  assert.equal(page.run("groupCopy.popups"),
    "Change the popup colors, corners, padding, spacing and gap. Tooltips stay compact.");
});

test("number typing accepts unfinished decimals and commas without errors", () => {
  const page = numberPage("widgets.paddingHorizontal");
  page.type("1.");
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 1);
  assert.equal(page.input.value, "1.");
  page.type("1,5");
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 1.5);
  assert.equal(page.error(), undefined);
  page.type("-");
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 1.5);
  assert.equal(page.error(), undefined);
});

test("out-of-range number typing stays quiet and clamps on blur", () => {
  const page = numberPage("widgets.paddingHorizontal", { defaults: { paddingHorizontal: 12 } });
  page.type("55");
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 12);
  assert.equal(page.input.value, "55");
  assert.equal(page.error(), undefined);
  page.commit();
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 40);
  assert.equal(page.input.value, "40");
  assert.equal(page.error(), undefined);
});

test("an invalid number reports its range on blur and clears the error on input", () => {
  const page = numberPage("widgets.paddingHorizontal");
  page.type("abc");
  assert.equal(page.error(), undefined);
  page.commit();
  assert.equal(page.error(), "Enter a number from 0 to 40.");
  page.type("-");
  assert.equal(page.error(), undefined);
});

test("empty underline width stores null and ArrowUp starts one step above the minimum", () => {
  const page = numberPage("workspaces.underlineWidth", {
    workspaceDefaults: { indicator: "underline", indicatorStyle: { width: 12 } },
  });
  page.type("");
  assert.equal(page.run("state.config.workspaceDefaults.indicatorStyle.width"), null);
  page.commit();
  assert.equal(page.error(), undefined);
  assert.equal(page.key("ArrowUp"), true);
  assert.equal(page.run("state.config.workspaceDefaults.indicatorStyle.width"), 1);
  assert.equal(page.input.value, "1");
});

test("Shift ArrowUp nudges height by ten points through the input handler", () => {
  const page = numberPage("bar.height", { bar: { height: 40 } });
  assert.equal(page.key("ArrowUp", true), true);
  assert.equal(page.run("state.config.bar.height"), 50);
  assert.equal(page.input.value, "50");
});

test("Enter commits and formats a number without requiring blur", () => {
  const page = numberPage("widgets.paddingHorizontal");
  page.type("55");
  assert.equal(page.key("Enter"), true);
  assert.equal(page.run("state.config.defaults.paddingHorizontal"), 40);
  assert.equal(page.input.value, "40");
});

test("slider and field changes keep each other in sync through field input events", () => {
  const page = numberPage("bar.height", { bar: { height: 40 } });
  const slider = page.root.querySelector('[data-slider-for="bar.height"]');
  slider.dataset.sliderFor = "bar.height";
  slider.value = "63";
  let fieldInputs = 0;
  const onInput = page.events.get("input");
  page.events.set("input", event => { if (event.target === page.input) fieldInputs++; onInput(event); });
  page.events.get("input")({ target: slider });
  assert.equal(fieldInputs, 1);
  assert.equal(page.input.value, "63");
  assert.equal(page.run("state.config.bar.height"), 63);
  page.type("70");
  assert.equal(slider.value, "70");
  page.key("ArrowDown", true);
  assert.equal(slider.value, "60");
  assert.equal(fieldInputs, 3);
  page.type("120");
  assert.equal(slider.value, "60");
  page.commit();
  assert.equal(slider.value, "100");
  assert.equal(fieldInputs, 5);
});

test("scrubbing captures the pointer, emits changed values and ends on release or cancellation", () => {
  for (const end of ["pointerup", "pointercancel", "lostpointercapture"]) {
    const page = numberPage("widgets.paddingHorizontal", { defaults: { paddingHorizontal: 10 } });
    const captured = new Set();
    const handle = {
      parentElement: { querySelector: () => page.input },
      setPointerCapture: id => captured.add(id), hasPointerCapture: id => captured.has(id),
      releasePointerCapture: id => captured.delete(id),
    };
    let prevented = false, fieldInputs = 0;
    const onInput = page.events.get("input");
    page.events.set("input", event => { if (event.target === page.input) fieldInputs++; onInput(event); });
    const pointer = (type, clientX, shiftKey = false, pointerId = 7) => page.events.get(type)({
      target: { closest: () => handle }, button: 0, isPrimary: true, pointerId, clientX, shiftKey,
      preventDefault() { prevented = true; },
    });
    pointer("pointerdown", 100);
    assert.equal(prevented, true);
    assert.equal(captured.has(7), true);
    assert.equal(page.root.classList.contains("is-scrubbing"), true);
    pointer("pointermove", 101);
    assert.equal(fieldInputs, 0);
    pointer("pointermove", 130);
    assert.equal(page.run("state.config.defaults.paddingHorizontal"), 20);
    assert.equal(fieldInputs, 1);
    pointer("pointermove", 130);
    assert.equal(fieldInputs, 1);
    pointer("pointermove", 106, true);
    assert.equal(page.run("state.config.defaults.paddingHorizontal"), 30);
    assert.equal(fieldInputs, 2);
    pointer("pointermove", 160, false, 8);
    pointer(end, 106, false, 8);
    assert.equal(captured.has(7), true);
    pointer(end, 106);
    assert.equal(captured.has(7), false);
    assert.equal(page.root.classList.contains("is-scrubbing"), false);
    pointer("pointermove", 160);
    assert.equal(fieldInputs, 2);
    pointer("pointerdown", 100);
    pointer("pointermove", 103);
    assert.equal(page.run("state.config.defaults.paddingHorizontal"), 31);
    pointer("pointerup", 103);
  }
});

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

test("the font menu shows each font in its face, keeps a custom one and offers another", () => {
  const page = storePage();
  const html = config => {
    page.context.fontConfig = config;
    page.run("state.config = fontConfig");
    return page.run("controlHTML(CONTROLS.find(control => control.id === 'widgets.fontName'), resolved())");
  };
  const monaco = html({ defaults: { fontName: "Monaco" } });
  assert.match(monaco, /data-value="Monaco" aria-selected="true" style="font-family: &quot;Monaco&quot;, /);
  assert.match(monaco, /aria-haspopup="listbox"[^>]*>Monaco<\/button>/);
  assert.match(monaco, /<input [^>]*class="font-other"[^>]*hidden/);
  assert.match(monaco, /data-other aria-selected="false">Other font…<\/li>/);
  assert.equal((monaco.match(/aria-selected="true"/g) ?? []).length, 1);
  assert.match(html({ defaults: { fontName: "JetBrains Mono" } }), /data-value="JetBrains Mono" aria-selected="true"/);
  assert.match(html({ defaults: { fontName: "system" } }), /data-value="system" aria-selected="true" style="font-family: -apple-system[^"]*">System<\/li>/);
});

test("choosing from the font menu applies a font or opens the field for another", () => {
  const page = storePage();
  const list = "c-widgets-fontName-list";
  const button = Object.assign(page.root.querySelector(`[aria-controls="${list}"]`), {
    dataset: { control: "widgets.fontName", fontSelect: "" }, type: "button", tagName: "BUTTON", style: {},
    getAttribute: () => list,
  });
  const other = page.root.querySelector('.font-other[data-control="widgets.fontName"]');
  const option = (value, active = false) => ({
    id: value, dataset: { value }, textContent: value === "system" ? "System" : value || "Other font…",
    setAttribute() {}, scrollIntoView() {},
    classList: { active, toggle(_name, on) { this.active = on; }, contains() { return this.active; } },
  });
  const options = [option("system", true), option("Menlo"), option("Monaco"), option("")];
  Object.assign(page.root.querySelector(`#${list}`), { id: list, querySelectorAll: () => options, setAttribute() {} });
  page.context.fontList = page.root.querySelector(`#${list}`);
  const key = name => page.run(`fontListKey(fontList, { key: ${JSON.stringify(name)}, preventDefault() {} })`);

  key("ArrowDown");
  assert.equal(options[1].classList.active, true);
  key("End");
  assert.equal(options[3].classList.active, true);
  key("m"); key("o");
  assert.equal(options[2].classList.active, true);
  key("Enter");
  assert.equal(page.run("state.config.defaults.fontName"), "Monaco");
  assert.equal(button.textContent, "Monaco");
  assert.match(button.style.fontFamily, /^"Monaco", /);

  other.hidden = true;
  page.run(`chooseFont(root.querySelector('[aria-controls="${list}"]'), "")`);
  assert.equal(page.run("state.config.defaults.fontName"), "Monaco");
  assert.equal(other.hidden, false);

  const type = value => page.events.get("input")({ target: { dataset: { control: "widgets.fontName" }, type: "text", value } });
  type("  JetBrains Mono ");
  assert.equal(page.run("state.config.defaults.fontName"), "JetBrains Mono");
  type("   ");
  assert.equal(page.run("state.config.defaults.fontName"), "JetBrains Mono");
});

test("Try in StableBar shows with the first version that opens theme links", () => {
  const page = storePage();
  page.run("updateOutputs()");
  assert.equal(page.root.querySelector("[data-action=try]").hidden, false);
  assert.equal(page.root.querySelector(".version-note").textContent, "Needs StableBar 0.16.0 or later.");
});
