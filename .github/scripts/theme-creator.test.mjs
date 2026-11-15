import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import {
  BASE_IDS, RESERVED_IDS, slug, isVersion, nextPatch, resolveTheme,
  CONTROLS, controlsFor, applyControl, fileText,
} from "../../site/creator/theme.mjs";

const root = new URL("../../", import.meta.url);
const read = path => readFileSync(new URL(path, root));
const json = path => JSON.parse(read(path));
const baseIDs = ["built-in", "leman", "notch", "catppuccin", "nord", "gruvbox", "phosphor"];
const builtIn = json("Resources/themes/built-in/config.json");
const theme = id => json(`Resources/themes/${id}/config.json`);
const state = id => ({ manifest: json(`Resources/themes/${id}/package.json`), config: theme(id) });
const idsFor = (s, flags = {}) => controlsFor(s, flags).map(control => control.id);
const at = (object, path) => path.split(".").reduce((value, key) => value?.[key], object);

test("slug matches the app", () => {
  for (const { name, id } of json("Tests/Fixtures/theme-link/slugs.json")) {
    assert.equal(slug(name), id, name);
  }
});

test("reserved ids are the app's", () => {
  const folders = readdirSync(new URL("Resources/themes/", root), { withFileTypes: true })
    .filter(entry => entry.isDirectory()).map(entry => entry.name);
  const catalog = read("Sources/StableBar/ThemeCatalog.swift").toString();
  const legacy = catalog.match(/let legacyThemeIDs: Set<String> = \[([^\]]+)\]/)[1];
  const legacyIDs = [...legacy.matchAll(/"([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(BASE_IDS, baseIDs);
  assert.deepEqual(RESERVED_IDS, new Set([...folders, ...legacyIDs]));
});

test("site theme copies equal Resources", () => {
  for (const id of baseIDs) {
    for (const file of ["package.json", "config.json"]) {
      assert.deepEqual(read(`site/creator/themes/${id}/${file}`), read(`Resources/themes/${id}/${file}`));
    }
  }
});

test("resolve applies the app's fallbacks", () => {
  const resolved = resolveTheme(builtIn, builtIn, "dark");
  assert.equal(resolved.defaults.cornerRadius, 14);
  assert.equal(resolved.defaults.paddingHorizontal, 10);
  assert.equal(resolved.defaults.paddingVertical, 6);
  assert.equal(resolved.defaults.spacing, 6);
  assert.equal(resolved.defaults.shadowRadius, 2);
  assert.equal(resolved.defaults.fontSize, 13);
  assert.equal(resolved.defaults.fontName, "system");
  assert.equal(resolved.defaults.fontWeight, "regular");
  assert.equal(resolved.defaults.background, "#242629ee");
  assert.equal(resolved.defaults.accentText, "#ffffff");
  assert.equal(resolved.defaults.borderWidth, 1);
  assert.equal(resolved.popupDefaults.background, "#242629ee");
  assert.equal(resolveTheme(builtIn, theme("leman"), "dark").defaults.paddingVertical, 3);
  const nord = resolveTheme(builtIn, theme("nord"), "dark");
  assert.equal(nord.bar.height, 30);
  assert.equal(nord.defaults.background, null);
  assert.equal(resolveTheme({}, {}, "light").defaults.accent, "#f7821b");
});

test("popup defaults inherit widget defaults like the app", () => {
  const resolved = resolveTheme(builtIn, {
    defaults: { cornerRadius: 9, shadowRadius: 4, fontName: "Monaco" },
    popupDefaults: { cornerRadius: null, background: "#123456", paddingVertical: 12 },
  }, "dark");
  assert.equal(resolved.popupDefaults.cornerRadius, 9);
  assert.equal(resolved.popupDefaults.shadowRadius, 4);
  assert.equal(resolved.popupDefaults.fontName, "Monaco");
  assert.equal(resolved.popupDefaults.background, "#123456");
  assert.equal(resolved.popupDefaults.paddingVertical, 12);
});

test("resolution merges objects, replaces arrays and gradients, and preserves null clears", () => {
  const original = {
    tokens: { accent: { light: "#123456", dark: "#abcdef" }, alias: "@token.accent" },
    defaults: { foreground: "@token.alias", background: "#123456" },
    bar: { style: { background: { gradient: { colors: ["#111111", "#222222"], angle: 90 } } } },
    groups: [{ id: "old" }],
  };
  const edits = {
    tokens: { accent: { light: "#654321" } }, defaults: { background: null },
    bar: { style: { background: { gradient: { colors: ["#333333", "#444444"] } } } },
    groups: [{ id: "new" }],
  };
  const before = structuredClone({ original, edits });
  const resolved = resolveTheme(original, edits, "dark");
  assert.equal(resolved.defaults.foreground, "#abcdef");
  assert.equal(resolved.defaults.background, null);
  assert.deepEqual(resolved.groups, [{ id: "new" }]);
  assert.deepEqual(resolved.bar.style.background, { gradient: { colors: ["#333333", "#444444"] } });
  assert.deepEqual({ original, edits }, before);
});

test("workspace resolution supplies indicator fallbacks without losing states", () => {
  const resolved = resolveTheme(builtIn, {}, "dark");
  assert.equal(resolved.workspaceDefaults.indicator, "background");
  assert.equal(resolved.workspaceDefaults.indicatorStyle.height, 2);
  assert.equal(resolved.workspaceDefaults.indicatorStyle.cornerRadius, 0);
  assert.equal(resolved.workspaceDefaults.indicatorStyle.background, "#0a84ff");
  assert.equal(resolved.workspaceDefaults.style.cornerRadius, 10);
  assert.equal(resolved.workspaceDefaults.style.states.focused.background, "#0a84ff");
  const leman = resolveTheme(builtIn, theme("leman"), "dark");
  assert.equal(leman.workspaceDefaults.style.cornerRadius, 7);
  assert.equal(leman.workspaceDefaults.style.states.focused.background, "#5cc5b829");
  const small = resolveTheme(builtIn, { defaults: { cornerRadius: 2 } }, "dark");
  assert.equal(small.workspaceDefaults.style.cornerRadius, 0);
  assert.deepEqual(resolveTheme(builtIn, theme("gruvbox"), "dark").workspaceDefaults.style.states.visible,
    { borderColor: "#504945", foreground: "#ebdbb2" });
});

test("token substitution rejects missing tokens and cycles", () => {
  assert.throws(() => resolveTheme({}, { defaults: { background: "@token.missing" } }, "dark"), /Unknown.*missing/);
  assert.throws(() => resolveTheme({}, { tokens: { a: "@token.b", b: "@token.a" } }, "dark"), /cycle/i);
});

test("token substitution bounds expansion across references", () => {
  const tokens = { a0: "#123456" };
  for (let i = 1; i < 20; i++) tokens[`a${i}`] = [`@token.a${i - 1}`, `@token.a${i - 1}`];
  assert.throws(() => resolveTheme({}, { tokens }, "dark"), /100,000/);
  const chain = { a0: "#123456" };
  for (let i = 1; i < 70; i++) chain[`a${i}`] = `@token.a${i - 1}`;
  assert.throws(() => resolveTheme({}, { tokens: chain }, "dark"), /64/);
});

test("the token expansion budget counts introduced values and is shared by uses", () => {
  const document = { tokens: { list: Array(99_999).fill(0) }, groups: "@token.list" };
  assert.equal(resolveTheme({}, document, "dark").groups.length, 99_999);
  document.tokens.list.push(0);
  assert.throws(() => resolveTheme({}, document, "dark"), /100,000/);
  assert.throws(() => resolveTheme({}, {
    tokens: { list: Array(50_000).fill(0) }, groups: ["@token.list", "@token.list"],
  }, "dark"), /100,000/);
});

test("editing light leaves dark alone", () => {
  const original = state("nord");
  const next = applyControl(original, "palette.accent", "#ff0000", "light");
  assert.deepEqual(next.config.tokens.accent, { light: "#ff0000", dark: "#88c0d0" });
  assert.deepEqual(original, state("nord"));
});

test("color edits preserve the other appearance of token references and single colors", () => {
  const popup = applyControl(state("nord"), "popups.background", "#ff0000", "light");
  assert.deepEqual(popup.config.popupDefaults.background, { light: "#ff0000", dark: "#2e3440ee" });
  const single = state("nord");
  single.config.popupDefaults.background = "#123456";
  const next = applyControl(single, "popups.background", "#ff0000", "light");
  assert.deepEqual(next.config.popupDefaults.background, { light: "#ff0000", dark: "#123456" });
  const dark = applyControl(state("nord"), "popups.background", "#00ff00", "dark");
  assert.deepEqual(dark.config.popupDefaults.background, { light: "#eceff4ee", dark: "#00ff00" });
});

test("color edits use inherited popup and workspace colors", () => {
  const popup = applyControl(state("built-in"), "popups.background", "#ff0000", "light");
  assert.deepEqual(popup.config.popupDefaults.background, { light: "#ff0000", dark: "#242629ee" });
  const workspace = applyControl(state("built-in"), "workspaces.focusedFill", "#ff0000", "light");
  assert.deepEqual(workspace.config.workspaceDefaults.style.states.focused.background,
    { light: "#ff0000", dark: "#0a84ff" });
  const underline = applyControl(state("built-in"), "workspaces.underlineVisibleBackground", "#ff0000", "light");
  assert.deepEqual(underline.config.workspaceDefaults.indicatorStyle.states.visible.background,
    { light: "#ff0000", dark: "#0a84ff" });
});

test("focused workspace text inherits the cell's color before its accent-text fallback", () => {
  for (const indicator of ["background", "underline", "none"]) {
    const config = { workspaceDefaults: { indicator, style: { foreground: "#123456" } } };
    assert.equal(resolveTheme(builtIn, config, "dark").workspaceDefaults.style.states.focused.foreground, "#123456");
    delete config.workspaceDefaults.style.foreground;
    assert.equal(resolveTheme(builtIn, config, "dark").workspaceDefaults.style.states.focused.foreground, "#ffffff");
  }
});

test("controls leave the base's other keys alone", () => {
  for (const id of ["gruvbox", "built-in"]) {
    const original = state(id);
    original.config.groups = [{ id: "kept", style: { background: "@token.surface" } }];
    original.config.profiles = [{ name: "kept", configuration: { tokens: { accent: "#123456" } } }];
    let edited = original;
    for (const control of CONTROLS.filter(control => control.kind === "color")) {
      edited = applyControl(edited, control.id, "#ff0000", "light");
    }
    assert.deepEqual(edited.config.bar?.style?.background, original.config.bar?.style?.background);
    assert.deepEqual(edited.config.roles, original.config.roles);
    assert.deepEqual(edited.config.groups, original.config.groups);
    assert.deepEqual(edited.config.profiles, original.config.profiles);
    assert.deepEqual(edited.config.workspaceDefaults?.style?.states?.visible,
      original.config.workspaceDefaults?.style?.states?.visible);
  }
});

test("tiles and glow are independent", () => {
  const original = state("phosphor");
  for (const enabled of [false, true]) {
    const edited = applyControl(original, "widgets.tiles", enabled, "dark");
    assert.deepEqual(edited.config.defaults.shadowColor, original.config.defaults.shadowColor);
    assert.equal(edited.config.defaults.shadowRadius, original.config.defaults.shadowRadius);
    assert.deepEqual(edited.config.defaults.background, enabled ? "@token.surface" : null);
    assert.deepEqual(edited.config.defaults.borderColor, enabled ? builtIn.defaults.borderColor : null);
  }
});

test("tiles restore Built-in borders and a cleared shadow", () => {
  const on = applyControl(state("nord"), "widgets.tiles", true, "light");
  assert.equal(on.config.defaults.background, "@token.surface");
  assert.deepEqual(on.config.defaults.borderColor, builtIn.defaults.borderColor);
  assert.deepEqual(on.config.defaults.shadowColor, builtIn.defaults.shadowColor);
  const off = applyControl(on, "widgets.tiles", false, "light");
  assert.equal(off.config.defaults.background, null);
  assert.equal(off.config.defaults.borderColor, null);
  assert.deepEqual(off.config.defaults.shadowColor, builtIn.defaults.shadowColor);
});

test("workspace controls follow the indicator", () => {
  for (const [id, underline, fill] of [["nord", true, false], ["leman", false, true], ["notch", false, false]]) {
    const ids = idsFor(state(id));
    assert.equal(ids.includes("workspaces.underlineWidth"), underline, id);
    assert.equal(ids.includes("workspaces.focusedFill"), fill, id);
    assert.ok(ids.includes("workspaces.indicator"));
    assert.ok(ids.includes("workspaces.foreground"));
    assert.ok(ids.includes("workspaces.focusedForeground"));
  }
  const referenced = state("nord");
  referenced.config.tokens.indicator = "underline";
  referenced.config.workspaceDefaults.indicator = "@token.indicator";
  assert.ok(idsFor(referenced).includes("workspaces.underlineWidth"));
});

test("workspace indicator and its controls write the app's paths", () => {
  let edited = applyControl(state("notch"), "workspaces.indicator", "underline", "dark");
  assert.equal(edited.config.workspaceDefaults.indicator, "underline");
  assert.ok(idsFor(edited).includes("workspaces.underlineWidth"));
  edited = applyControl(edited, "workspaces.underlineWidth", 20, "dark");
  assert.equal(edited.config.workspaceDefaults.indicatorStyle.width, 20);
  edited = applyControl(edited, "workspaces.indicator", "background", "dark");
  edited = applyControl(edited, "workspaces.cornerRadius", 12, "dark");
  assert.equal(edited.config.workspaceDefaults.style.cornerRadius, 12);
  assert.ok(idsFor(edited).includes("workspaces.focusedFill"));
  assert.ok(!idsFor(edited).includes("workspaces.underlineWidth"));
});

test("popup spacing waits for its flag", () => {
  const spacing = ["popups.paddingHorizontal", "popups.paddingVertical", "popups.spacing", "popups.gap"];
  for (const flags of [{}, { popupSpacing: false }]) {
    assert.ok(spacing.every(id => !idsFor(state("built-in"), flags).includes(id)));
  }
  assert.ok(spacing.every(id => idsFor(state("built-in"), { popupSpacing: true }).includes(id)));
  const edited = applyControl(state("built-in"), "popups.gap", 8, "dark");
  assert.equal(edited.config.bar.popupOffset, 8);
});

test("strip background can be removed, colored, or restored from the base gradient", () => {
  const original = state("gruvbox");
  const gradient = original.config.bar.style.background;
  const none = applyControl(original, "bar.background", "none", "dark");
  assert.ok(!Object.hasOwn(none.config.bar.style, "background"));
  const color = applyControl(none, "bar.background", "#ff0000", "light");
  assert.deepEqual(color.config.bar.style.background, { light: "#ff0000", dark: "#00000000" });
  const restored = applyControl(color, "bar.background", gradient, "light");
  assert.deepEqual(restored.config.bar.style.background, gradient);
  assert.deepEqual(original, state("gruvbox"));
});

test("about controls edit only the manifest and derive the id from the name", () => {
  let edited = applyControl(state("built-in"), "about.name", "My Léman", "light");
  assert.equal(edited.manifest.id, "my-leman");
  assert.equal(edited.manifest.name, "My Léman");
  edited = applyControl(edited, "about.author", "a-builder", "light");
  edited = applyControl(edited, "about.description", "A lake theme", "light");
  edited = applyControl(edited, "about.version", "1.2.3", "light");
  assert.equal(edited.manifest.author, "a-builder");
  assert.equal(edited.manifest.description, "A lake theme");
  assert.equal(edited.manifest.version, "1.2.3");
  edited = applyControl(edited, "about.author", "", "light");
  assert.ok(!Object.hasOwn(edited.manifest, "author"));
  assert.deepEqual(edited.config, builtIn);
});

test("controls describe their keys and documentation", () => {
  assert.deepEqual(new Set(CONTROLS.map(control => control.group)),
    new Set(["about", "palette", "bar", "widgets", "workspaces", "popups"]));
  assert.equal(new Set(CONTROLS.map(control => control.id)).size, CONTROLS.length);
  for (const control of CONTROLS) {
    assert.ok(control.id.startsWith(`${control.group}.`));
    assert.ok(control.label && control.kind && control.help && control.docs, control.id);
    assert.ok(Array.isArray(control.paths) && control.paths.length > 0, control.id);
    assert.ok(control.paths.every(path => control.help.includes(path)), control.id);
    assert.ok(control.docs.startsWith("https://"), control.id);
  }
});

test("ordinary controls write their declared paths and leave inputs unchanged", () => {
  const values = {
    "bar.height": 44, "bar.margin": 8, "bar.cornerRadius": 12,
    "bar.borderWidth": 2, "bar.borderEdges": "bottom", "widgets.fontName": "Monaco",
    "widgets.fontSize": 12, "widgets.fontWeight": "medium", "widgets.cornerRadius": 10,
    "widgets.paddingHorizontal": 8, "widgets.paddingVertical": 4, "widgets.shadowRadius": 6,
    "workspaces.underlineHeight": 4, "workspaces.underlineCornerRadius": 2, "workspaces.underlineOffsetY": 6,
    "popups.cornerRadius": 8, "popups.paddingHorizontal": 16, "popups.paddingVertical": 12, "popups.spacing": 8,
  };
  for (const [id, value] of Object.entries(values)) {
    const original = state("built-in");
    const edited = applyControl(original, id, value, "dark");
    const path = CONTROLS.find(control => control.id === id).paths[0];
    assert.equal(at(edited.config, path), value, id);
    assert.deepEqual(original, state("built-in"), id);
  }
  assert.throws(() => applyControl(state("built-in"), "missing.control", 1, "dark"), /control/i);
});

test("versions", () => {
  assert.ok(isVersion("1.0.0"));
  for (const invalid of ["1.0", "v1.0.0", "1.0.0-beta", "-1.0.0", null]) {
    assert.equal(isVersion(invalid), false);
  }
  assert.equal(nextPatch("1.0.9"), "1.0.10");
  assert.equal(nextPatch("1.2.99999999999999999999"), "1.2.100000000000000000000");
  assert.throws(() => nextPatch("1.0"), /version/i);
});

test("fileText is the shared file serializer", () => {
  assert.equal(fileText({ name: "Léman", value: null }), '{\n  "name": "Léman",\n  "value": null\n}\n');
});
