import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  BASE_IDS, RESERVED_IDS, slug, isVersion, nextPatch, resolveTheme,
  CONTROLS, controlsFor, applyControl, fileText,
} from "../../site/creator/theme.mjs";
import {
  themeFiles, encodeLink, decodeLink, shareURL, crc32, writeZip, readZip, readmeRow, storeManifest,
} from "../../site/creator/files.mjs";
import {
  CONTRACT, cssVariables, indicatorClass, keptFromBase, shadowBlur,
} from "../../site/creator/preview.mjs";

const root = new URL("../../", import.meta.url);
const read = path => readFileSync(new URL(path, root));
const json = path => JSON.parse(read(path));
const baseIDs = ["built-in", "leman", "notch", "catppuccin", "nord", "gruvbox", "phosphor"];
const builtIn = json("Resources/themes/built-in/config.json");
const theme = id => json(`Resources/themes/${id}/config.json`);
const state = id => ({ manifest: json(`Resources/themes/${id}/package.json`), config: theme(id) });
const idsFor = (s, flags = {}) => controlsFor(s, flags).map(control => control.id);
const at = (object, path) => path.split(".").reduce((value, key) => value?.[key], object);

test("preview colors match the site's hand-checked ones", () => {
  const css = read("site/style.css").toString().replace(/\/\*[\s\S]*?\*\//g, "");
  for (const id of baseIDs) {
    for (const appearance of ["dark", "light"]) {
      const selectors = new Set(["[data-theme]", `[data-theme="${id}"]`]);
      if (appearance === "light") {
        selectors.add('[data-mode="light"] [data-theme]');
        selectors.add(`[data-mode="light"] [data-theme="${id}"]`);
      }
      const expected = {};
      const priority = {};
      for (const [, selector, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
        if (!selectors.has(selector.trim())) continue;
        const specificity = [...selector.matchAll(/\[/g)].length;
        for (const [, key, value] of body.matchAll(/(--[\w-]+):\s*([^;]+);/g)) {
          if ((priority[key] ?? 0) > specificity) continue;
          expected[key] = value.trim();
          priority[key] = specificity;
        }
      }
      const actual = cssVariables(resolveTheme(builtIn, theme(id), appearance));
      for (const key of ["--fg", "--muted", "--accent", "--accent-text", "--w-bg", "--pop-bg", "--raised", "--track"]) {
        assert.equal(actual[key], expected[key], `${id} ${appearance} ${key}`);
      }
    }
  }
});

test("preview geometry follows the theme", () => {
  const variables = id => cssVariables(resolveTheme(builtIn, theme(id), "dark"));
  const nord = variables("nord");
  assert.equal(nord["--bar-h"], "30px");
  assert.equal(nord["--ul-w"], "12px");
  assert.equal(nord["--ul-h"], "3px");
  assert.equal(nord["--ul-dy"], "4px");
  assert.equal(variables("leman")["--tile-h"], "22px");
  assert.equal(variables("leman")["--strip-m"], "6px");
  assert.equal(variables("phosphor")["--tile-h"], "27px");
  assert.equal(variables("gruvbox")["--w-dy"], "-4.5px");
  const built = variables("built-in");
  assert.equal(built["--tile-h"], "28px");
  assert.equal(shadowBlur(2), 4);
  assert.equal(built["--w-shadow-box"], `0 1px ${shadowBlur(2)}px #00000040`);
  assert.equal(indicatorClass(resolveTheme(builtIn, theme("leman"), "dark")), "preview-ws-fill");
  assert.equal(indicatorClass(resolveTheme(builtIn, theme("nord"), "dark")), "preview-ws-under");
  assert.equal(indicatorClass(resolveTheme(builtIn, theme("notch"), "dark")), "preview-ws-text");
});

test("every config control is in the contract", () => {
  assert.equal(new Set(CONTRACT).size, CONTRACT.length);
  for (const path of CONTROLS.flatMap(control => control.paths)) {
    assert.equal(CONTRACT.includes(path), !path.startsWith("manifest."), path);
  }
  for (const path of ["defaults.foreground", "defaults.accent", "defaults.offsetY"]) {
    assert.ok(CONTRACT.includes(path), path);
  }
});

test("every contract path feeds the renderer", () => {
  const edits = {
    "defaults.foreground": "#123456", "defaults.accent": "#123456", "defaults.accentText": "#123456",
    "defaults.offsetY": 3, "defaults.background": "#123456", "defaults.borderColor": "#123456",
    "defaults.shadowColor": "#123456", "defaults.shadowRadius": 7, "defaults.fontName": "Monaco",
    "defaults.fontSize": 17, "defaults.fontWeight": "bold", "defaults.cornerRadius": 5,
    "defaults.paddingHorizontal": 16, "defaults.paddingVertical": 9, "defaults.hoverBackground": "#123456",
    "defaults.borderWidth": 3, "defaults.iconSize": 17, "defaults.spacing": 9,
    "bar.height": 44, "bar.margin": 8, "bar.style.background": "#123456", "bar.style.cornerRadius": 12,
    "bar.style.borderColor": "#123456", "bar.style.borderWidth": 3, "bar.style.borderEdges": "all",
    "bar.inset": 20, "bar.spacing": 12,
    "workspaceDefaults.indicator": "none", "workspaceDefaults.style.foreground": "#123456",
    "workspaceDefaults.style.states.focused.foreground": "#123456",
    "workspaceDefaults.style.states.focused.background": "#123456", "workspaceDefaults.style.cornerRadius": 4,
    "workspaceDefaults.indicatorStyle.width": 20, "workspaceDefaults.indicatorStyle.height": 4,
    "workspaceDefaults.indicatorStyle.cornerRadius": 2, "workspaceDefaults.indicatorStyle.offsetY": 6,
    "workspaceDefaults.indicatorStyle.background": "#123456",
    "workspaceDefaults.indicatorStyle.states.visible.background": "#123456",
    "popupDefaults.background": "#123456", "popupDefaults.borderColor": "#123456",
    "popupDefaults.shadowColor": "#123456", "popupDefaults.cornerRadius": 5,
    "popupDefaults.paddingHorizontal": 20, "popupDefaults.paddingVertical": 12, "popupDefaults.spacing": 9,
    "popupDefaults.shadowRadius": 7, "popupDefaults.fontName": "Monaco", "popupDefaults.fontSize": 17,
    "popupDefaults.fontWeight": "bold",
    "popupDefaults.foreground": "#123456", "popupDefaults.accent": "#123456", "popupDefaults.borderWidth": 3,
    "bar.popupOffset": 12,
  };
  const draw = config => {
    const resolved = resolveTheme(builtIn, config, "dark");
    return { ...cssVariables(resolved, { popupSpacing: true }), indicator: indicatorClass(resolved) };
  };
  for (const path of CONTRACT) {
    const config = { bar: { style: { borderColor: "#abcdef", borderWidth: 1 } } };
    if (path.startsWith("tokens.")) {
      config.defaults = { foreground: `@token.${path.slice("tokens.".length)}` };
    } else {
      assert.ok(Object.hasOwn(edits, path), `Missing consumption check for ${path}`);
    }
    const before = draw(config);
    const keys = path.split(".");
    const last = keys.pop();
    let target = config;
    for (const key of keys) target = target[key] ??= {};
    target[last] = path.startsWith("tokens.") ? "#123456" : edits[path];
    assert.notDeepEqual(draw(config), before, path);
  }
});

test("kept keys are listed", () => {
  assert.deepEqual(keptFromBase(builtIn), ["roles"]);
  assert.deepEqual(keptFromBase(theme("gruvbox")), ["workspaceDefaults.style.states.visible"]);
  const config = {
    tokens: { custom: "#123456" }, defaults: { states: { hover: { background: "#123456" } } },
    bar: { style: { opacity: 0.5 } }, groups: [], profiles: [],
  };
  assert.deepEqual(keptFromBase(config), [
    "tokens.custom", "defaults.states", "bar.style.opacity", "groups", "profiles",
  ]);
});

test("tokens referenced by rendered properties are not marked as kept", () => {
  const probe = { tokens: { mine: "#123456" }, popupDefaults: { background: "@token.mine" } };
  assert.equal(cssVariables(resolveTheme(builtIn, probe, "dark"))["--pop-bg"], "#123456");
  assert.deepEqual(keptFromBase(probe), []);
  const config = {
    tokens: {
      day: "#123456", night: "#654321", stop: "#abcdef", alias: "@token.stop", unused: "#fedcba",
    },
    defaults: { foreground: { light: "@token.day", dark: "@token.night" } },
    bar: { style: { background: { gradient: { colors: ["@token.alias", "#ffffff"] } } } },
  };
  assert.deepEqual(keptFromBase(config), ["tokens.unused"]);
  assert.equal(cssVariables(resolveTheme(builtIn, config, "light"))["--fg"], "#123456");
  assert.equal(cssVariables(resolveTheme(builtIn, config, "dark"))["--fg"], "#654321");
  assert.equal(cssVariables(resolveTheme(builtIn, config, "dark"))["--strip-bg"],
    "linear-gradient(90deg, #abcdef, #ffffff)");
});

test("kept token analysis follows aliases once and ignores references outside the contract", () => {
  const config = {
    tokens: { a: "@token.b", b: "@token.a", onlyInRole: "#abcdef" },
    defaults: { foreground: "@token.a" }, roles: { heading: { foreground: "@token.onlyInRole" } },
  };
  assert.deepEqual(keptFromBase(config), ["tokens.onlyInRole", "roles"]);
  assert.deepEqual(keptFromBase({ tokens: { unused: "@token.missing" } }), ["tokens.unused"]);
});

test("Fern marks only its undrawn custom tokens as kept", () => {
  const referenced = { hover: "#2f3329", popup: "#1a1c16", accentText: "#1f3701", outline: "#8e9285" };
  const config = {
    tokens: referenced,
    defaults: { hoverBackground: "@token.hover", accentText: "@token.accentText" },
    popupDefaults: { background: "@token.popup" },
    workspaceDefaults: { style: { states: { visible: { borderColor: "@token.outline" } } } },
  };
  assert.deepEqual(keptFromBase(config), ["tokens.outline", "workspaceDefaults.style.states.visible"]);
});

test("popup spacing waits for its flag while tooltip padding stays compact", () => {
  const resolved = resolveTheme(builtIn, {
    popupDefaults: { paddingHorizontal: 22, paddingVertical: 18, spacing: 16 }, bar: { popupOffset: 12 },
  }, "dark");
  const before = structuredClone(resolved);
  const off = cssVariables(resolved);
  const on = cssVariables(resolved, { popupSpacing: true });
  for (const [key, fixed, configured] of [
    ["--pop-px", "10px", "22px"], ["--pop-py", "6px", "18px"],
    ["--pop-gap", "6px", "16px"], ["--pop-offset", "6px", "12px"],
  ]) {
    assert.equal(off[key], fixed, key);
    assert.equal(on[key], configured, key);
  }
  assert.deepEqual(resolved, before);
  const css = read("site/creator/preview.css").toString();
  const tooltip = css.match(/\.theme-preview \.preview-tooltip\s*\{([^}]+)\}/)[1];
  assert.match(tooltip, /padding: 6px 10px;/);
  assert.doesNotMatch(tooltip, /var\(--pop-p[xy]\)/);
});

test("tiles use box shadows and bare widgets keep their glow", () => {
  const resolved = resolveTheme(builtIn, theme("phosphor"), "dark");
  const bare = cssVariables(resolved);
  assert.equal(bare["--w-shadow-box"], "none");
  assert.equal(bare["--w-glow"], `drop-shadow(0 1px ${shadowBlur(4) / 2}px #ffb00080)`);
  const tiled = applyControl(state("phosphor"), "widgets.tiles", true, "dark");
  const variables = cssVariables(resolveTheme(builtIn, tiled.config, "dark"));
  assert.equal(variables["--w-glow"], "none");
  assert.equal(variables["--w-shadow-box"], `0 1px ${shadowBlur(4)}px #ffb00080`);
  resolved.defaults.background = "#00000000";
  resolved.defaults.borderColor = "#ffffff00";
  assert.equal(cssVariables(resolved)["--w-shadow-box"], "none");
  assert.equal(cssVariables(resolved)["--w-glow"], bare["--w-glow"]);
  resolved.defaults.borderColor = "#ffffff";
  resolved.defaults.borderWidth = 2;
  assert.equal(cssVariables(resolved)["--w-shadow-box"], "none");
  assert.equal(cssVariables(resolved)["--w-glow"], bare["--w-glow"]);
});

test("gradients use the native default angle and keep unsupported angles from the base", () => {
  const config = { bar: { style: { background: { gradient: { colors: ["#ff0000", "#0000ff"] } } } } };
  const variables = () => cssVariables(resolveTheme(builtIn, config, "dark"))["--strip-bg"];
  assert.equal(variables(), "linear-gradient(90deg, #ff0000, #0000ff)");
  config.bar.style.background.gradient.angle = 45;
  assert.equal(variables(), "linear-gradient(45deg, #ff0000, #0000ff)");
  assert.deepEqual(keptFromBase(config), ["bar.style.background"]);
});

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

test("the bundled fallback matches the built-in JSON without JSON import attributes", async () => {
  const { default: bundled } = await import("../../site/creator/built-in.mjs");
  assert.deepEqual(bundled, builtIn);
  for (const file of ["theme.mjs", "page.mjs"]) {
    assert.doesNotMatch(read(`site/creator/${file}`).toString(), /with\s*\{\s*type:\s*["']json["']/);
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

test("popup hover falls back to its own background before inherited background", () => {
  const config = {
    defaults: { background: "#111111", foreground: "#222222" },
    popupDefaults: { background: "#333333", foreground: "#444444" },
  };
  const fallback = resolveTheme({}, config, "dark");
  assert.equal(fallback.defaults.hoverBackground, "#111111");
  assert.equal(fallback.popupDefaults.hoverBackground, "#333333");
  assert.equal(fallback.popupDefaults.hoverForeground, "#444444");

  config.defaults.hoverBackground = "#555555";
  assert.equal(resolveTheme({}, config, "dark").popupDefaults.hoverBackground, "#555555");
  config.defaults.states = { hover: { background: "#666666" } };
  assert.equal(resolveTheme({}, config, "dark").popupDefaults.hoverBackground, "#666666");
  config.popupDefaults.hoverBackground = "#777777";
  assert.equal(resolveTheme({}, config, "dark").popupDefaults.hoverBackground, "#777777");
  config.popupDefaults.states = { hover: { background: "#888888" } };
  assert.equal(resolveTheme({}, config, "dark").popupDefaults.hoverBackground, "#888888");
});

test("icon size uses the app's fallback and popup inheritance", () => {
  const fallback = resolveTheme({}, {}, "light");
  assert.equal(fallback.defaults.iconSize, 13);
  assert.equal(fallback.popupDefaults.iconSize, 13);
  const config = { defaults: { iconSize: 17 } };
  assert.equal(resolveTheme({}, config, "light").popupDefaults.iconSize, 17);
  config.popupDefaults = { iconSize: 19 };
  assert.equal(resolveTheme({}, config, "light").popupDefaults.iconSize, 19);
});

test("unknown font weights fall back to regular after style inheritance", () => {
  const config = { defaults: { fontWeight: "unknown" } };
  let resolved = resolveTheme({}, config, "dark");
  assert.equal(resolved.defaults.fontWeight, "regular");
  assert.equal(resolved.popupDefaults.fontWeight, "regular");
  config.defaults.fontWeight = "bold";
  config.popupDefaults = { fontWeight: "unknown" };
  resolved = resolveTheme({}, config, "dark");
  assert.equal(resolved.defaults.fontWeight, "bold");
  assert.equal(resolved.popupDefaults.fontWeight, "regular");
  config.popupDefaults.fontWeight = "semibold";
  assert.equal(resolveTheme({}, config, "dark").popupDefaults.fontWeight, "semibold");
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

test("editing token-backed sections preserves their other properties and both appearances", () => {
  const cases = [
    ["defaults", "widgets.fontSize", { fontName: "Monaco", background: "@token.surface" },
      { fontName: "Monaco", background: builtIn.tokens.surface, fontSize: 17 }],
    ["popupDefaults", "popups.cornerRadius", { spacing: 12, background: "@token.surface" },
      { spacing: 12, background: builtIn.tokens.surface, cornerRadius: 17 }],
    ["workspaceDefaults", "workspaces.underlineWidth", {
      indicator: "underline", style: { foreground: "@token.text" }, indicatorStyle: "@token.underline",
    }, {
      indicator: "underline", style: { foreground: builtIn.tokens.text },
      indicatorStyle: { height: 3, background: builtIn.tokens.accent, width: 17 },
    }],
  ];
  for (const [section, id, value, expected] of cases) {
    const original = state("built-in");
    original.config.tokens.section = "@token.sectionStyle";
    original.config.tokens.sectionStyle = value;
    original.config.tokens.underline = { height: 3, background: "@token.accent" };
    original.config[section] = "@token.section";
    const before = structuredClone(original);
    const edited = applyControl(original, id, 17, "light");
    assert.deepEqual(edited.config[section], expected, section);
    assert.deepEqual(edited.config.tokens, before.config.tokens, section);
    assert.deepEqual(original, before, section);
  }
});

test("editing a nested token-backed style preserves the containing workspace", () => {
  const original = state("nord");
  original.config.tokens.underline = { height: 3, background: "@token.accent" };
  original.config.workspaceDefaults.indicatorStyle = "@token.underline";
  const before = structuredClone(original);
  const edited = applyControl(original, "workspaces.underlineWidth", 24, "light");
  assert.deepEqual(edited.config.workspaceDefaults, {
    ...before.config.workspaceDefaults,
    indicatorStyle: { height: 3, background: original.config.tokens.accent, width: 24 },
  });
  assert.deepEqual(edited.config.tokens, before.config.tokens);
  assert.deepEqual(original, before);
});

test("tiles preserve the other properties of token-backed defaults", () => {
  const original = state("built-in");
  const style = { fontName: "Monaco", cornerRadius: 7, shadowColor: "#123456", shadowRadius: 5 };
  original.config.tokens.widgetStyle = style;
  original.config.defaults = "@token.widgetStyle";
  const before = structuredClone(original);
  for (const enabled of [false, true]) {
    const edited = applyControl(original, "widgets.tiles", enabled, "dark");
    assert.deepEqual(edited.config.defaults, {
      ...style, background: enabled ? "@token.surface" : null,
      borderColor: enabled ? builtIn.defaults.borderColor : null,
    });
    assert.deepEqual(edited.config.tokens, before.config.tokens);
    assert.deepEqual(original, before);
  }
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
  const color = applyControl(none, "bar.background", "color", "light");
  assert.equal(color.config.bar.style.background, "@token.surface");
  const edited = applyControl(color, "bar.background", "#ff0000", "light");
  assert.deepEqual(edited.config.bar.style.background, { light: "#ff0000", dark: original.config.tokens.surface.dark });
  const restored = applyControl(edited, "bar.background", gradient, "light");
  assert.deepEqual(restored.config.bar.style.background, gradient);
  assert.deepEqual(original, state("gruvbox"));
});

test("choosing a colored strip follows the surface in both appearances", () => {
  for (const id of baseIDs) {
    for (const appearance of ["light", "dark"]) {
      const none = applyControl(state(id), "bar.background", "none", appearance);
      const color = applyControl(none, "bar.background", "color", appearance);
      for (const shown of ["light", "dark"]) {
        const resolved = resolveTheme(builtIn, color.config, shown);
        assert.equal(resolved.bar.style.background, resolved.tokens.surface, `${id}: ${appearance} → ${shown}`);
      }
      const edited = applyControl(color, "palette.surface", "#123456", appearance);
      assert.equal(resolveTheme(builtIn, edited.config, appearance).bar.style.background, "#123456");
    }
  }
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

test("select controls offer the values accepted by the app", () => {
  const { style, workspaceDefaults } = json("stablebar.schema.json").definitions;
  const properties = {
    "bar.borderEdges": style.properties.borderEdges,
    "widgets.fontWeight": style.properties.fontWeight,
    "workspaces.indicator": workspaceDefaults.properties.indicator,
  };
  for (const control of CONTROLS.filter(control => control.kind === "select")) {
    assert.deepEqual(control.options, properties[control.id].anyOf.find(option => option.enum).enum, control.id);
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

const sample = json("Tests/Fixtures/theme-link/sample.json");
const linkedFiles = {
  manifestText: read("Tests/Fixtures/linked-theme/package.json").toString(),
  configText: read("Tests/Fixtures/linked-theme/config.json").toString(),
};
const utf8 = text => new TextEncoder().encode(text);
const uncheckedLink = (config = "{}", manifest = "{}") =>
  `stablebar://theme?v=1&package=${Buffer.from(manifest).toString("base64url")}` +
  `&config=${Buffer.from(config).toString("base64url")}`;
const nestedJSON = levels => '{"x":' + "[".repeat(levels - 1) + "0" + "]".repeat(levels - 1) + "}";
const profilesJSON = count => JSON.stringify({ profiles: Array.from({ length: count }, () => ({ name: "x" })) });
const linkError = message => ({ name: "Error", message });
const rejectsFiles = (configText, error, manifestText = "{}") => {
  assert.throws(() => encodeLink({ manifestText, configText }), linkError(error));
  assert.throws(() => decodeLink(uncheckedLink(configText, manifestText)), linkError(error));
};

test("theme files build a fresh manifest and use the shared serializer", () => {
  const manifest = {
    ...theme("built-in"), ...state("built-in").manifest,
    id: "harbour-test", name: "Harbour Test", version: "1.2.3", author: "a-builder", description: "A theme",
    kind: "commands", entry: "other.json", screenshot: "preview.png", permissions: ["automation"],
  };
  const config = theme("nord");
  const original = structuredClone({ manifest, config });
  assert.deepEqual(themeFiles({ manifest, config }), {
    manifestText: fileText({
      id: "harbour-test", name: "Harbour Test", version: "1.2.3", kind: "theme", entry: "config.json",
      description: "A theme", author: "a-builder",
    }),
    configText: fileText(config),
  });
  assert.deepEqual({ manifest, config }, original);
  const optional = themeFiles({ manifest: { id: "my-theme", name: "My theme", version: "1.0.0" }, config: {} });
  assert.deepEqual(JSON.parse(optional.manifestText), {
    id: "my-theme", name: "My theme", version: "1.0.0", kind: "theme", entry: "config.json",
  });
});

test("theme files refuse empty and reserved ids with a message", () => {
  assert.throws(() => themeFiles({ manifest: { id: slug("日本") }, config: {} }), /id/i);
  for (const id of RESERVED_IDS) {
    assert.throws(() => themeFiles({ manifest: { id }, config: {} }), /id/i, id);
    assert.throws(() => writeZip(id, linkedFiles), /id/i, id);
  }
  for (const id of ["", " ", "../escape", "a/b", "a\\b"]) {
    assert.throws(() => writeZip(id, linkedFiles), /id/i, id);
  }
});

test("links match the app's fixture", () => {
  assert.equal(linkedFiles.manifestText, sample["package.json"]);
  assert.equal(linkedFiles.configText, sample["config.json"]);
  assert.equal(encodeLink(linkedFiles), sample.link);
  assert.deepEqual(decodeLink(sample.link), linkedFiles);
  assert.deepEqual(decodeLink("#" + sample.link.split("?")[1]), linkedFiles);
  assert.deepEqual(decodeLink(sample.link.replace("stablebar://theme", "STABLEBAR://THEME")), linkedFiles);
});

test("share URLs carry the exact same query in the fragment", () => {
  const base = "https://stablebar.app/create-theme.html";
  assert.equal(shareURL(base, linkedFiles), `${base}#${sample.link.split("?")[1]}`);
  assert.equal(shareURL(base + "#old", linkedFiles), shareURL(base, linkedFiles));
});

test("links accept exact padding and unknown query items", () => {
  const padded = new URL(sample.link);
  for (const name of ["package", "config"]) {
    const value = padded.searchParams.get(name);
    padded.searchParams.set(name, value + "=".repeat((4 - value.length % 4) % 4));
  }
  assert.deepEqual(decodeLink(padded.href), linkedFiles);
  assert.deepEqual(decodeLink(sample.link.replace("&config=", "==&config=")), linkedFiles);
  assert.deepEqual(decodeLink(sample.link + "&x=1&x=2"), linkedFiles);
  assert.deepEqual(decodeLink(sample.link + "&x=%"), linkedFiles);
  assert.deepEqual(decodeLink("#" + padded.search.slice(1)), linkedFiles);
  assert.deepEqual(decodeLink(sample.link.replace("//theme?", "//%74heme?")), linkedFiles);
  assert.deepEqual(decodeLink(sample.link.replace("//theme?", "//theme:?")), linkedFiles);
});

test("links refuse damaged query items and unsupported versions like the app", () => {
  const damaged = [
    "v=1&config=e30", "v=1&package=!!&config=e30", "v=1&package=e30&config=WzFd",
    "package=e30&config=e30", "v=&package=e30&config=e30", "v=0&package=e30&config=e30",
    "v=-1&package=e30&config=e30", "v=abc&package=e30&config=e30", "v=1.0&package=e30&config=e30",
    "v=01&package=e30&config=e30", "v=+1&package=e30&config=e30", "v=9223372036854775808&package=e30&config=e30",
    "v=1&package=WzFd&config=e30", "v=1&package=e30&config=!!", "v=1&package=e30&config=bnVsbA",
    "v=1&package=e30&config=ew", "v=1&package=e30", "v=1&package&config=e30",
    "v=1&v=2&package=e30&config=e30", "v=1&package=e30&package=e30&config=e30",
    "v=1&package=e30&config=e30&config=e30", "v=1&package=e30==&config=e30",
    "v=1&package=e30&config=e=30", "v=1&package=e30&config=a", "v=1&package=e30&config=e30+",
    "v=1&package=e30&config=e30/", "v=1&package=e30&config=e30%0A", "v=1&package=e30&config=e30=extra",
    "v=1&package=e30&config=e30%", "v=1&package=e30&config=e30&%76=1",
  ];
  for (const query of damaged) {
    assert.throws(() => decodeLink("stablebar://theme?" + query), linkError("damaged"), query);
  }
  for (const version of ["2", "3", "+2", "02"]) {
    assert.throws(() => decodeLink(`stablebar://theme?v=${version}&package=e30&config=e30`),
      linkError("unsupportedVersion"), version);
  }
  for (const query of ["v=2", "v=2&package=e30&package=e30&config=e30"]) {
    assert.throws(() => decodeLink("stablebar://theme?" + query), linkError("unsupportedVersion"), query);
  }
  for (const [urlChar, base64Char] of [["-", "+"], ["_", "/"]]) {
    assert.throws(() => decodeLink(sample.link.replaceAll(urlChar, base64Char)), linkError("damaged"));
  }
});

test("links refuse additional URL components", () => {
  const query = "?v=1&package=e30&config=e30";
  const links = [
    "stablebar://theme/" + query, "stablebar://theme/extra" + query,
    "stablebar://theme" + query + "#fragment", "stablebar://theme" + query + "#",
    "stablebar://user@theme" + query, "stablebar://user:password@theme" + query,
    "stablebar://@theme" + query, "stablebar://theme:123" + query,
    "https://theme" + query, "stablebar://themes" + query, "stablebar://package/nord",
  ];
  for (const link of links) assert.throws(() => decodeLink(link), linkError("damaged"), link);
});

test("links refuse what the app refuses", () => {
  const padded = size => "{" + " ".repeat(size - 2) + "}";
  rejectsFiles(padded(13_000), "tooLarge", padded(20_000));
  const maximum = { manifestText: padded(20_000), configText: padded(12_768) };
  assert.deepEqual(decodeLink(encodeLink(maximum)), maximum);
  const unicode = { manifestText: "{}", configText: JSON.stringify({ name: "é".repeat(16_381) }) };
  assert.ok(unicode.configText.length < 32_768);
  assert.throws(() => encodeLink(unicode), linkError("tooLarge"));
  const prefix = uncheckedLink() + "&x=";
  assert.deepEqual(decodeLink(prefix + "x".repeat(65_536 - prefix.length)),
    { manifestText: "{}", configText: "{}" });
  assert.throws(() => decodeLink(prefix + "x".repeat(65_537 - prefix.length)), linkError("tooLong"));
  rejectsFiles(nestedJSON(33), "tooDeep");
  rejectsFiles("{}", "tooDeep", nestedJSON(33));
  rejectsFiles(nestedJSON(5_001), "tooDeep");
  rejectsFiles('{"x":' + nestedJSON(40) + ',"x":null}', "tooDeep");
  rejectsFiles('{"x":null,"x":' + nestedJSON(40) + "}", "tooDeep");
  const boundary = { manifestText: "{}", configText: nestedJSON(32) };
  assert.deepEqual(decodeLink(encodeLink(boundary)), boundary);
  const bracesInString = { manifestText: "{}", configText: JSON.stringify({ label: '[[{{\\"'.repeat(40) }) };
  assert.deepEqual(decodeLink(encodeLink(bracesInString)), bracesInString);
  for (const invalid of ["[]", "null", "1", "true", '"text"', "", "{", '{"x":1,}', "{}{}", "{\u0000}"]) {
    rejectsFiles(invalid, "damaged");
    rejectsFiles("{}", "damaged", invalid);
  }
});

test("links count scalars and containers across both files up to 372 values", () => {
  const scalars = [null, true, false, 0, -1.25e30, 'brackets [ ], braces { }, colon : comma , quote " and slash \\'];
  const valuesJSON = count => JSON.stringify({ values: Array.from({ length: count - 2 }, (_, i) => scalars[i % scalars.length]) });
  for (const [manifestCount, configCount] of [[1, 371], [371, 1], [180, 192]]) {
    const text = count => count === 1 ? "{}" : valuesJSON(count);
    const files = { manifestText: text(manifestCount), configText: text(configCount) };
    assert.deepEqual(decodeLink(encodeLink(files)), files);
    rejectsFiles(text(configCount + 1), "tooManySettings", files.manifestText);
    rejectsFiles(files.configText, "tooManySettings", text(manifestCount + 1));
  }
  const containers = { manifestText: "{}", configText: JSON.stringify({ values: Array.from({ length: 369 }, (_, i) => i % 2 ? {} : []) }) };
  assert.deepEqual(decodeLink(encodeLink(containers)), containers);
  rejectsFiles(containers.configText.replace('"values":[', '"values":[{},'), "tooManySettings");
});

test("link value counts include duplicate values but exclude object keys", () => {
  const object = count => "{" + Array.from({ length: count }, (_, i) => `${JSON.stringify('key:' + i)}:0`).join(",") + "}";
  const duplicate = count => "{" + Array(count).fill('"same":0').join(",") + "}";
  for (const make of [object, duplicate]) {
    for (const file of ["manifestText", "configText"]) {
      const files = { manifestText: "{}", configText: "{}", [file]: make(370) };
      assert.deepEqual(decodeLink(encodeLink(files)), files);
      const manifest = file === "manifestText" ? make(371) : "{}";
      const config = file === "configText" ? make(371) : "{}";
      rejectsFiles(config, "tooManySettings", manifest);
    }
  }
});

test("the raw value cap is checked in both files before parsing either document", () => {
  const parse = JSON.parse;
  let documentParses = 0;
  JSON.parse = (text, ...args) => {
    if (/^[\t\n\r ]*\{/.test(text)) documentParses++;
    return parse(text, ...args);
  };
  try {
    const text = "{" + Array(372).fill('"same":null').join(",") + "}";
    rejectsFiles(text, "tooManySettings");
    rejectsFiles("{}", "tooManySettings", text);
    assert.equal(documentParses, 0);
  } finally { JSON.parse = parse; }
});

test("a theme over the link value cap still downloads and reopens as a zip", async () => {
  const files = { ...linkedFiles, configText: JSON.stringify({ tokens: Object.fromEntries(Array.from({ length: 372 }, (_, i) => [`t${i}`, "#112233"])) }) };
  assert.throws(() => encodeLink(files), linkError("tooManySettings"));
  assert.throws(() => shareURL("https://stablebar.app/create-theme.html", files), linkError("tooManySettings"));
  assert.deepEqual(await readZip(writeZip("many-settings", files)), files);
});

test("links accept only UTF-8 and preserve a UTF-8 BOM", () => {
  const files = { manifestText: '\ufeff{"name":"Harbour — Nord"}', configText: "\ufeff" + nestedJSON(32) };
  assert.deepEqual(decodeLink(encodeLink(files)), files);
  for (const bytes of [Buffer.from("{}", "utf16le"), Buffer.from([0xff, 0xfe, 0x7b, 0, 0x7d, 0]),
    Buffer.from([0xfe, 0xff, 0, 0x7b, 0, 0x7d]), Buffer.from([0x7b, 0, 0, 0, 0x7d, 0, 0, 0]),
    Buffer.from([0x7b, 0x22, 0x78, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d])]) {
    assert.throws(() => decodeLink(uncheckedLink(bytes)), linkError("damaged"));
    assert.throws(() => decodeLink(uncheckedLink("{}", bytes)), linkError("damaged"));
  }
  rejectsFiles("\ufeff" + nestedJSON(33), "tooDeep");
});

test("links refuse JSON strings and numbers Foundation cannot decode", () => {
  for (const invalid of ['{"n":1e9999}', '{"x":"\\ud800"}', '{"x":"\\udc00"}', '{"\\ud800":null}',
    '{"n":1e9999,"n":0}', '{"x":"\\ud800","x":"valid"}']) {
    rejectsFiles(invalid, "damaged");
    rejectsFiles("{}", "damaged", invalid);
  }
  const valid = { manifestText: "{}", configText: '{"x":"\\ud83d\\ude00","n":1e308,"small":1e-9999}' };
  assert.deepEqual(decodeLink(encodeLink(valid)), valid);
});

test("links limit profiles in raw JSON and across nested profiles", () => {
  const sixteen = { manifestText: "{}", configText: profilesJSON(16) };
  assert.deepEqual(decodeLink(encodeLink(sixteen)), sixteen);
  rejectsFiles(profilesJSON(17), "tooManyProfiles");
  for (const extraFirst of [false, true]) {
    const extra = profilesJSON(17).slice(1, -1);
    rejectsFiles("{" + (extraFirst ? extra + ',"profiles":[]' : '"profiles":[],' + extra) + "}", "tooManyProfiles");
  }
  const escaped = profilesJSON(17).replace("profiles", "pro\\u0066iles");
  rejectsFiles(escaped, "tooManyProfiles");
  const nested = count => JSON.stringify({ profiles: [{ name: "outer", configuration: JSON.parse(profilesJSON(count)) }] });
  rejectsFiles(nested(16), "tooManyProfiles");
  assert.doesNotThrow(() => encodeLink({ manifestText: "{}", configText: nested(15) }));
  const manifest = profilesJSON(17);
  assert.doesNotThrow(() => encodeLink({ manifestText: manifest, configText: "{}" }));
  const delimiters = JSON.stringify({ other: Array(17).fill(0), profiles: Array.from({ length: 16 },
    () => ({ name: 'commas, [ ] { } " \\ \\u0066' })) }).replace('"profiles"', '"pro\\u0066iles"');
  assert.doesNotThrow(() => encodeLink({ manifestText: "{}", configText: delimiters }));
});

test("linked bar properties are restricted at the root and in every profile", () => {
  const bar = {
    height: 30, margin: 0, inset: 1, spacing: 6, background: "#123456", style: { cornerRadius: 5 },
    notchWidth: 0, notchSpacing: 2, fillNotch: false, popupOffset: 3,
  };
  assert.doesNotThrow(() => encodeLink({ manifestText: "{}", configText: JSON.stringify({ bar }) }));
  for (const value of [{ position: "bottom" }, { hideMenuBar: true }, "@token.bar", "@setting.bar", null, [], 30, true]) {
    const document = { bar: value };
    rejectsFiles(JSON.stringify(document), "barProperty");
    rejectsFiles(JSON.stringify({ profiles: [{ name: "p", configuration: document }] }), "barProperty");
    rejectsFiles(JSON.stringify({ profiles: [{ name: "p", configuration: {
      profiles: [{ name: "nested", configuration: document }],
    } }] }), "barProperty");
  }
});

test("crc32", () => {
  assert.equal(crc32(utf8("hello")), 0x3610a686);
  assert.equal(crc32(new Uint8Array()), 0);
});

test("zip round trip", async () => {
  const zip = writeZip("harbour-test", linkedFiles);
  assert.ok(zip instanceof Uint8Array);
  assert.deepEqual(writeZip("harbour-test", linkedFiles), zip);
  const header = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  assert.equal(header.getUint16(8, true), 0);
  assert.equal(header.getUint16(10, true), 0);
  assert.equal(header.getUint16(12, true), 33);
  assert.deepEqual(await readZip(zip), linkedFiles);
  const padded = new Uint8Array(zip.length + 8);
  padded.set(zip, 4);
  assert.deepEqual(await readZip(padded.subarray(4, -4)), linkedFiles);
});

test("written zips pass unzip -t", t => {
  const available = spawnSync("unzip", ["-v"], { encoding: "utf8" });
  if (available.error?.code === "ENOENT") return t.skip("unzip is not installed");
  const directory = mkdtempSync(join(tmpdir(), "stablebar-creator-"));
  try {
    const file = join(directory, "theme.zip");
    writeFileSync(file, writeZip("harbour-test", linkedFiles));
    const checked = spawnSync("unzip", ["-t", file], { encoding: "utf8" });
    assert.equal(checked.status, 0, checked.stdout + checked.stderr);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("reads a zip Finder made and skips its metadata", async () => {
  const zip = read("Tests/Fixtures/theme-link/finder.zip");
  assert.ok(zip.includes(Buffer.from(".DS_Store")));
  assert.ok(zip.includes(Buffer.from("__MACOSX/")));
  assert.deepEqual(await readZip(zip), linkedFiles);
});

test("zip metadata cannot be mistaken for the theme manifest", async () => {
  for (const folder of ["__MACOSX", ".ignored"]) {
    const zip = Buffer.from(writeZip("metadata", linkedFiles));
    const before = Buffer.from("metadata/"), after = Buffer.from(`${folder}/`);
    for (let index = zip.indexOf(before); index !== -1; index = zip.indexOf(before, index + before.length)) {
      zip.set(after, index);
    }
    await assert.rejects(() => readZip(zip));
  }
});

test("a theme too large for links still downloads and reopens as a zip", async () => {
  const files = { ...linkedFiles, configText: JSON.stringify({ tokens: { large: "x".repeat(40_000) } }) };
  assert.throws(() => encodeLink(files), linkError("tooLarge"));
  assert.throws(() => shareURL("https://stablebar.app/create-theme.html", files), linkError("tooLarge"));
  assert.deepEqual(await readZip(writeZip("harbour-test", files)), files);
});

test("zip corruption and missing entries are refused", async () => {
  for (const bytes of [new Uint8Array(), utf8("not a zip"), writeZip("harbour-test", linkedFiles).slice(0, -1)]) {
    await assert.rejects(() => readZip(bytes));
  }
  const corrupt = writeZip("harbour-test", linkedFiles);
  const text = Buffer.from(corrupt.buffer);
  corrupt[text.indexOf(Buffer.from("Harbour Test"))] ^= 1;
  await assert.rejects(() => readZip(corrupt));
  const missing = { ...linkedFiles, manifestText: '{"entry":"missing.json"}' };
  await assert.rejects(() => readZip(writeZip("harbour-test", missing)));
});

test("readme row matches the Store's script", () => {
  const { manifest, row } = json("Tests/Fixtures/theme-link/readme-row.json");
  assert.equal(manifest.version, "1.2.0");
  assert.equal(readmeRow(manifest), row);
  for (const description of [undefined, null, "", "   "]) {
    assert.throws(() => readmeRow({ ...manifest, description }), /description/i);
  }
});

test("store lookup", async () => {
  const { manifest } = json("Tests/Fixtures/theme-link/readme-row.json");
  const url = "https://raw.githubusercontent.com/Seb-GRAF/stablebar-packages/main/packages/fern/package.json";
  const response = status => async requested => {
    assert.equal(requested, url);
    return new Response(JSON.stringify(manifest), { status });
  };
  assert.equal(await storeManifest("fern", response(404)), null);
  assert.deepEqual(await storeManifest("fern", response(200)), manifest);
  await assert.rejects(() => storeManifest("fern", response(500)), /storeUnavailable/);
  await assert.rejects(() => storeManifest("fern", async () => { throw new Error("offline"); }), /storeUnavailable/);
  await assert.rejects(() => storeManifest("fern", async () => new Response("not JSON")));
});

test("exports require a name and version and reserve ids without regard to case", () => {
  const manifest = { id: "custom-theme", name: "Custom theme", version: "1.0.0" };
  for (const id of ["Nord", "NORD", "Paper", "BUILT-IN"]) {
    assert.throws(() => themeFiles({ manifest: { ...manifest, id }, config: {} }), linkError("reservedID"));
  }
  for (const name of [undefined, null, "", "   "]) {
    assert.throws(() => themeFiles({ manifest: { ...manifest, name }, config: {} }), linkError("invalidName"));
  }
  for (const version of [undefined, "", "1.0", "1.0.0-beta"]) {
    assert.throws(() => themeFiles({ manifest: { ...manifest, version }, config: {} }), linkError("invalidVersion"));
  }
});

test("links refuse includes and malformed profile declarations at every level", () => {
  const rejected = [
    [{ includes: [] }, "extraFiles"],
    [{ profiles: [{ name: "x", configuration: { includes: [] } }] }, "extraFiles"],
    [{ profiles: null }, "damaged"],
    [{ profiles: {} }, "damaged"],
    [{ profiles: [{}] }, "damaged"],
    [{ profiles: [{ name: 7 }] }, "damaged"],
    [{ profiles: [{ name: "x", mystery: true }] }, "damaged"],
    [{ profiles: [{ name: "x", configuration: null }] }, "damaged"],
    [{ profiles: [{ name: "x", configuration: { profiles: null } }] }, "damaged"],
  ];
  for (const [config, code] of rejected) rejectsFiles(fileText(config), code);
});

test("zip errors have a single code and oversized entries are refused before inflation", async () => {
  for (const size of [0, 1, 21, 22]) {
    await assert.rejects(() => readZip(new Uint8Array(size)), linkError("damagedZip"));
  }
  const zip = writeZip("harbour-test", linkedFiles);
  const directory = Buffer.from(zip).indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  const invalidName = zip.slice();
  invalidName[directory + 46] = 0xff;
  await assert.rejects(() => readZip(invalidName), linkError("damagedZip"));

  const view = new DataView(zip.buffer);
  view.setUint16(8, 8, true);
  view.setUint16(directory + 10, 8, true);
  view.setUint32(directory + 24, 0x7fffffff, true);
  const original = globalThis.DecompressionStream;
  let inflated = false;
  globalThis.DecompressionStream = class {
    constructor() { inflated = true; throw new Error("Must not inflate an oversized entry"); }
  };
  try {
    await assert.rejects(() => readZip(zip), linkError("damagedZip"));
    assert.equal(inflated, false);
  } finally { globalThis.DecompressionStream = original; }
});

test("zip inflation cancels when a chunk exceeds the declared entry size", async () => {
  const zip = writeZip("harbour-test", linkedFiles);
  const directory = Buffer.from(zip).indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  const view = new DataView(zip.buffer);
  view.setUint16(8, 8, true);
  view.setUint16(directory + 10, 8, true);
  view.setUint32(directory + 24, 8, true);
  const original = globalThis.DecompressionStream;
  let cancelled = false;
  globalThis.DecompressionStream = class {
    constructor() {
      return {
        readable: new ReadableStream({
          start(controller) {
            controller.enqueue(new Uint8Array(9));
            controller.enqueue(new Uint8Array(100));
            controller.close();
          },
          cancel() { cancelled = true; },
        }),
        writable: new WritableStream(),
      };
    }
  };
  try {
    await assert.rejects(() => readZip(zip), linkError("damagedZip"));
    assert.equal(cancelled, true);
  } finally { globalThis.DecompressionStream = original; }
});

test("Store failures and missing descriptions use page error codes", async () => {
  assert.throws(() => readmeRow({}), linkError("descriptionRequired"));
  for (const response of [
    async () => { throw new Error("offline"); },
    async () => new Response("{}", { status: 500 }),
    async () => new Response("not JSON"),
    async () => new Response("{}"),
  ]) await assert.rejects(() => storeManifest("custom-theme", response), linkError("storeUnavailable"));
});

test("popup accent and line metrics belong to the popup style", () => {
  const config = { defaults: { fontName: "Monaco" }, popupDefaults: { accent: "#123456", fontName: "Avenir Next" } };
  const resolved = resolveTheme(builtIn, config, "dark");
  const css = cssVariables(resolved);
  assert.equal(css["--pop-accent"], "#123456");
  assert.match(css["--pop-font"], /13px\/16px/);
  assert.ok(!keptFromBase(config).includes("popupDefaults.accent"));
  const style = read("site/creator/preview.css").toString();
  assert.doesNotMatch(style, /filter: drop-shadow\(0 8px/);
  assert.match(style, /var\(--pop-shadow\), 0 8px 36px #00000047/);
});
