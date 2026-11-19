import builtIn from "./built-in.mjs";
import { BASE_IDS, RESERVED_IDS, MAC_FONTS, slug, isVersion, isColor, nextPatch, controlsFor, applyControl, resolveTheme, differsFromBase, resetControl } from "./theme.mjs";
import { ID_PATTERN, themeFiles, parseTheme, folderFiles, writeZip, readZip, encodeLink, decodeLink, shareURL, readmeRow, storeManifest } from "./files.mjs";
import { cssVariables, indicatorClass, keptFromBase, affectedVariables, PREVIEW_TARGETS, fontFamily } from "./preview.mjs";
import { parseNumber, formatNumber, clampNumber, scrubValue, nudgeValue } from "./number-field.mjs";
import { hsvFromHex, hexFromHSV, addRecentColor } from "./color-field.mjs";

const TRY_LINK_MIN_VERSION = "0.16.0";
const names = { palette: "Colors", bar: "Bar", widgets: "Widgets", workspaces: "Workspaces", popups: "Popups", about: "About" };
const baseNames = new Map();
const baseDescriptions = { "built-in": "Separate, rounded tiles", leman: "A quiet, floating strip", notch: "A dark, simple strip", catppuccin: "Soft colors and tiles", nord: "Cool colors and an underline", gruvbox: "Warm colors and stripes", phosphor: "Amber text with a glow" };
const groupCopy = {
  palette: "Each color has a light and a dark value. Edit the appearance shown in the preview.",
  bar: "Change the strip behind your widgets. Tiles have their own controls below.",
  widgets: "Change the tiles, type and spacing. Turn tiles off to keep just the text and any glow.",
  workspaces: "Choose a background, an underline or text alone. Only the settings it uses are shown.",
  popups: "Change the popup colors, corners, padding, spacing and gap. Tooltips stay compact.",
  about: "Give your theme a name. Add your GitHub username if you plan to share it in the Store.",
};
const messages = {
  invalidID: "Add a name with at least one ASCII letter or number to give the folder an id.",
  reservedID: "That id belongs to a theme that comes with StableBar. Choose another name.",
  invalidName: "Give your theme a name.",
  invalidVersion: "Use a version with three numbers, such as 1.0.0.",
  invalidMinimumVersion: "Use text for the minimum StableBar version.",
  invalidRepository: "Use an https URL for the theme repository.",
  descriptionRequired: "Add a description in About before copying the Store README row.",
  invalidStoreText: "The Store's table can't show a | or a line break in the name or description. Remove it to submit.",
  storeUnavailable: "Store couldn't be checked. Check the id and version in the Store before submitting.",
  damaged: "This theme could not be read. Open a theme zip, its folder or a complete share link.",
  damagedZip: "This zip could not be read. Choose the original theme zip or its unzipped folder.",
  tooLarge: "The two files are over 32 KB. Download the zip; they are too large for a link.",
  tooLong: "This theme makes a link longer than 65,536 bytes. Download it as a zip instead.",
  tooDeep: "This theme nests more than 32 levels deep. Download it as a zip instead.",
  tooManyProfiles: "This theme has more than 16 profiles. Download it as a zip instead.",
  tooManySettings: "This theme has more settings than a link can carry. Download it as a zip instead.",
  barProperty: "This theme has bar settings a link cannot carry. Download it as a zip instead.",
  extraFiles: "This theme needs other files. Open a theme with no includes.",
  unsupportedVersion: "This link uses a newer theme format. Open it with a newer creator page.",
  zipTooLarge: "This theme is too large for a zip.",
  notTheme: "Choose a theme package, with kind set to theme and only theme settings.",
  sameID: "Choose a different name so this theme gets a new id.",
  takenID: "That id is already used in the Store. Choose another name, or reopen your own theme to update it.",
  importTooLarge: "This file is too large to reopen here. Choose a theme with JSON files under 16 MB each.",
  copyFailed: "Copy is unavailable in this browser. Allow clipboard access and try again.",
};
const message = error => Object.hasOwn(messages, error?.message) ? messages[error.message] :
  (error instanceof Error && !(error instanceof DOMException) && error.message.endsWith(".") ? error.message : messages.damaged);
const fail = code => { throw new Error(code); };
const e = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const at = (object, path) => path.split(".").reduce((value, key) => value?.[key], object);
const isReserved = id => RESERVED_IDS.has(id.toLowerCase());
const root = document.querySelector("#creator");
const dialog = document.querySelector("#theme-dialog");
const bases = new Map();
const fieldErrors = new Map();
const storeCache = new Map();
let state, baseID = "built-in", baseGradient, mode = "new", sourceID;
let appearance = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
let jsonFile = "config", activePaths = [], store = { status: "unchecked" }, storeTimer, storeRequest = 0;
let pendingTheme, importRequest = 0;
let numberDrag, hoveredControl, focusedControl;
const cueResizeObserver = typeof ResizeObserver === "function" ? new ResizeObserver(updateCue) : null;
const resolved = () => resolveTheme(builtIn, state.config, appearance);

function colorInput(control, value, suffix = "") {
  const helpID = `c-${control.id.replaceAll(".", "-")}`;
  const id = helpID + suffix;
  const color = typeof value === "string" && /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value) ? value : "#00000000";
  return `<div class="color-picker"><div class="color-input"><button type="button" class="color-swatch" id="${id}" data-control="${control.id}" data-color-button aria-label="${e(control.label)} color" aria-describedby="${helpID}-help" aria-haspopup="dialog" aria-expanded="false" style="--swatch: ${color}"></button><input type="text" id="${id}-hex" data-control="${control.id}" data-color-text aria-label="${e(control.label)} hex value" aria-describedby="${helpID}-help ${helpID}-error" value="${e(color)}" spellcheck="false" autocomplete="off"></div></div>`;
}

function controlValue(control, r) {
  if (control.group === "about") return state.manifest[control.id.split(".")[1]] ?? "";
  const fallbacks = { "bar.height": 40, "bar.margin": 0, "bar.cornerRadius": 0, "bar.borderWidth": 0,
    "bar.borderEdges": "bottom", "workspaces.appIconSize": 14, "workspaces.underlineOffsetY": 0, "popups.gap": 6 };
  const value = at(r, control.paths[0]) ?? fallbacks[control.id];
  if (control.kind === "number") {
    if (typeof value === "number") return Number.isFinite(value) ? value : null;
    return typeof value === "string" ? parseNumber(value) : null;
  }
  const colors = value?.gradient?.colors;
  if (colors && (control.kind === "color" || colors.every(color => color === colors[0]))) return colors[0];
  return value;
}

function controlHTML(control, r) {
  const id = `c-${control.id.replaceAll(".", "-")}`;
  const value = controlValue(control, r);
  const attr = `id="${id}" data-control="${control.id}" aria-describedby="${id}-help ${id}-error"`;
  let input;
  if (control.kind === "color") input = colorInput(control, value);
  else if (control.kind === "toggle") {
    const on = r.defaults.background != null && r.defaults.background !== "transparent";
    input = `<div class="toggle"><span>${on ? "On" : "Off"}</span><input type="checkbox" ${attr} ${on ? "checked" : ""}></div>`;
  } else if (control.kind === "select") {
    input = `<select ${attr}>${control.options.map(option => `<option value="${option}" ${option === value ? "selected" : ""}>${option[0].toUpperCase() + option.slice(1)}</option>`).join("")}</select>`;
  } else if (control.kind === "font") {
    const name = value ?? "system";
    const label = font => font === "system" ? "System" : font;
    const fonts = ["system", ...(name === "system" || MAC_FONTS.includes(name) ? [] : [name])];
    const option = (font, index) => `<li role="option" id="${id}-font-${index}" data-value="${e(font)}" aria-selected="${font === name}" style="font-family: ${e(fontFamily(font))}">${e(label(font))}</li>`;
    input = `<div class="font-picker"><button type="button" ${attr} data-font-select value="${e(name)}" aria-haspopup="listbox" aria-expanded="false" aria-controls="${id}-list" style="font-family: ${e(fontFamily(name))}">${e(label(name))}</button>`
      + `<ul class="font-list" id="${id}-list" role="listbox" aria-label="${e(control.label)}" tabindex="-1" hidden>${fonts.map(option).join("")}`
      + `<li role="presentation" class="font-group">On every Mac</li>${MAC_FONTS.map((font, index) => option(font, fonts.length + index)).join("")}`
      + `<li role="option" id="${id}-other" data-value="" data-other aria-selected="false">Other font…</li></ul></div>`
      + `<input type="text" class="font-other" data-control="${control.id}" aria-label="Font name" placeholder="Name of a font you installed" autocomplete="off" spellcheck="false" value="${e(name === "system" ? "" : name)}" hidden>`;
  } else if (control.kind === "background") {
    const selected = value?.gradient ? "gradient" : value ? "color" : "none";
    input = `<select ${attr}>${[["none", "None"], ["color", "A color"], ...(baseGradient ? [["gradient", "Keep the base gradient"]] : [])].map(([key, label]) => `<option value="${key}" ${selected === key ? "selected" : ""}>${label}</option>`).join("")}</select>`;
    if (selected === "color") input += `<div class="background-color">${colorInput(control, value, "-color")}</div>`;
  } else if (control.kind === "number") {
    const [min, max] = control.range, text = value == null ? "" : formatNumber(value);
    const slider = control.slider ? `<input type="range" min="${min}" max="${max}" step="${control.step}" aria-label="${e(control.label)}" data-slider-for="${control.id}" value="${e(text)}">` : "";
    input = `<div class="number-control">${slider}<div class="number-field"><span class="scrub-handle" aria-hidden="true" title="Drag to change. Hold Shift for steps of 10."><svg viewBox="0 0 16 8" width="16" height="8" focusable="false"><path d="M4 1 1 4l3 3M12 1l3 3-3 3M1.5 4h13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></span><input ${attr} type="text" ${min < 0 ? "" : 'inputmode="decimal" '}value="${e(text)}" autocomplete="off" spellcheck="false"><span class="number-unit">${e(control.unit)}</span></div></div>`;
  } else input = `<input ${attr} type="text" value="${e(value ?? "")}" autocomplete="off">`;
  const paths = control.paths.map(path => path.replace(/^manifest\./, "package.json · "));
  const helpText = control.help.slice(control.help.indexOf(": ") + 2);
  const reset = control.group === "about" ? "" : `<button type="button" class="reset" data-action="reset" data-reset="${control.id}" aria-label="Reset ${e(control.label)}" title="Use the base theme's value" hidden>Reset</button>`;
  return `<div class="control ${["about.name", "about.description"].includes(control.id) ? "wide" : ""}"><div class="control-head"><label for="${id}">${e(control.label)}</label>${reset}</div>${input}<span class="help" id="${id}-help">${e(helpText)} <a href="${control.docs}"><code>${e(paths.join(", "))}</code></a></span><p class="control-error" id="${id}-error"></p>${control.id === "about.name" ? '<span class="base-help" data-theme-id></span>' : ""}</div>`;
}

function renderControls() {
  const focused = document.activeElement;
  const focusedID = focused?.id;
  const selection = focused?.type === "text" ? [focused.selectionStart, focused.selectionEnd] : null;
  const drafts = new Map([...fieldErrors.keys()].map(id => [id, (root.querySelector(`[data-control="${id}"][data-color-text]`) ?? root.querySelector(`[data-control="${id}"]`))?.value]));
  const r = resolved(), controls = controlsFor(state);
  for (const key of fieldErrors.keys()) if (!controls.some(control => control.id === key)) fieldErrors.delete(key);
  for (const group of Object.keys(names)) {
    root.querySelector(`[data-group="${group}"]`).innerHTML = controls.filter(control => control.group === group).map(control => controlHTML(control, r)).join("");
  }
  for (const [id, value] of drafts) {
    const input = root.querySelector(`[data-control="${id}"][data-color-text]`) ?? root.querySelector(`[data-control="${id}"]`);
    if (input && value !== undefined) input.value = value;
  }
  if (focusedID) {
    const replacement = document.getElementById(focusedID);
    replacement?.focus({ preventScroll: true });
    if (selection && replacement?.type === "text") replacement.setSelectionRange(...selection);
  }
  hoveredControl = document.activeElement?.closest(".control") ? undefined : cueControlID(root.querySelector(".control:hover"));
  for (const row of root.querySelectorAll(".control")) {
    row.addEventListener("pointerenter", () => { hoveredControl = cueControlID(row); updateCue(); });
    row.addEventListener("pointerleave", () => { hoveredControl = undefined; updateCue(); });
  }
  updateCue();
}

function cueControlID(element) {
  return element?.dataset?.control ?? element?.dataset?.sliderFor
    ?? element?.closest?.(".control")?.querySelector("[data-control]")?.dataset.control;
}

function updateCue() {
  const layer = root.querySelector(".preview-cue");
  if (!layer || !state) return;
  const id = numberDrag?.control.id ?? hoveredControl ?? focusedControl;
  const control = controlsFor(state).find(control => control.id === id);
  layer.innerHTML = "";
  delete layer.dataset.cueControl;
  if (!control) return;
  const preview = root.querySelector(".theme-preview"), targets = new Map();
  for (const variable of affectedVariables(state, id, appearance)) {
    const target = PREVIEW_TARGETS[variable];
    if (!target?.selector) continue;
    for (const element of preview.querySelectorAll(target.selector)) {
      if (!element.getClientRects().length) continue;
      if (!targets.has(element)) targets.set(element, []);
      targets.get(element).push({ variable, measure: target.measure });
    }
  }
  if (!targets.size) return;
  const stage = root.querySelector(".preview-stage").getBoundingClientRect(), parts = [];
  const rectFor = element => {
    const rect = element.getBoundingClientRect();
    return { x: rect.left - stage.left, y: rect.top - stage.top, width: rect.width, height: rect.height };
  };
  function box(kind, { x, y, width, height }) {
    if (width <= 0 || height <= 0) return;
    parts.push(`<span class="preview-cue-${kind}" style="left:${x}px;top:${y}px;width:${width}px;height:${height}px"></span>`);
  }
  function ruler(rect, from, to) {
    box("ruler", { x: Math.max(2, rect.x - 8), y: Math.min(from, to), width: 6, height: Math.max(1, Math.abs(to - from)) });
  }
  function measure(element, rect, { variable, measure }) {
    const style = getComputedStyle(element);
    if (measure === "padding-x") {
      const left = Math.min(rect.width / 2, parseFloat(style.paddingLeft)), right = Math.min(rect.width / 2, parseFloat(style.paddingRight));
      box("band", { ...rect, width: left });
      box("band", { ...rect, x: rect.x + rect.width - right, width: right });
    } else if (measure === "padding-y") {
      const top = Math.min(rect.height / 2, parseFloat(style.paddingTop)), bottom = Math.min(rect.height / 2, parseFloat(style.paddingBottom));
      box("band", { ...rect, height: top });
      box("band", { ...rect, y: rect.y + rect.height - bottom, height: bottom });
    } else if (measure === "gap") {
      const children = [...element.children].filter(child => child.getClientRects().length).map(rectFor);
      const vertical = style.display.includes("grid") || style.flexDirection.startsWith("column");
      for (let index = 1; index < children.length; index++) {
        const before = children[index - 1], after = children[index];
        if (vertical) box("band", { x: rect.x, y: before.y + before.height, width: rect.width, height: after.y - before.y - before.height });
        else box("band", { x: before.x + before.width, y: rect.y, width: after.x - before.x - before.width, height: rect.height });
      }
    } else if (measure === "height") {
      ruler(rect, rect.y, rect.y + rect.height);
    } else if (measure === "offset") {
      if (variable === "--strip-m") ruler(rect, rectFor(element.closest(".preview-bar")).y, rect.y);
      else if (variable === "--ul-dy") {
        const parent = rectFor(element.parentElement);
        ruler(rect, parent.y + parent.height - parseFloat(getComputedStyle(element.parentElement).paddingBottom), rect.y + rect.height);
      } else {
        const offset = parseFloat(preview.style.getPropertyValue(variable)) || 0;
        ruler(rect, rect.y - offset, rect.y);
      }
    }
  }
  let labelRect;
  for (const [element, measurements] of targets) {
    const rect = rectFor(element);
    if (!rect.width || !rect.height) continue;
    box("outline", rect);
    for (const target of measurements) if (target.measure) measure(element, rect, target);
    labelRect ??= rect;
  }
  if (control.kind === "number" && labelRect) {
    const value = controlValue(control, resolved());
    const label = value == null ? "Auto" : `${formatNumber(value)} ${control.unit}`;
    const x = Math.max(4, Math.min(stage.width - 104, labelRect.x + 4));
    const y = Math.max(4, Math.min(stage.height - 24, labelRect.y + labelRect.height + 4));
    parts.push(`<span class="preview-cue-label" style="left:${x}px;top:${y}px">${e(label)}</span>`);
  }
  layer.dataset.cueControl = id;
  layer.innerHTML = parts.join("");
}

function previewHTML() {
  return `<section class="preview-card" aria-label="Live theme preview">
    <div class="panel-heading">
    <h2>Your theme</h2>
    <div class="segmented" role="group" aria-label="Preview appearance">
    <button data-appearance="light" aria-pressed="false">Light</button>
    <button data-appearance="dark" aria-pressed="false">Dark</button>
    </div>
    </div>
    <div class="preview-stage">
    <div class="theme-preview">
    <div class="preview-bar" aria-hidden="true">
    <div class="preview-strip">
    <div class="preview-group">
    <div class="preview-tile preview-workspaces">
    <span class="preview-workspace">1</span>
    <span class="preview-workspace is-focused">2<img class="preview-app-icon" src="images/apps/finder.svg" alt=""><span class="preview-underline"></span></span>
    <span class="preview-workspace is-visible">3<img class="preview-app-icon" src="images/apps/ghostty.webp" alt=""><span class="preview-underline is-visible"></span></span>
    </div>
    <div class="preview-tile preview-app-menus">
    <span class="preview-app-name">Finder</span>${["File", "Edit", "View", "Go", "Window", "Help"].map(text => `<span class="preview-menu-entry">${text}</span>`).join("")}</div>
    </div>
    <div class="preview-spacer"></div>
    <div class="preview-group">
    <div class="preview-tile">
    <svg class="preview-battery" viewBox="0 0 28 14" aria-hidden="true">
    <rect x="1" y="1" width="23" height="12" rx="2" fill="none" stroke="currentColor"/>
    <rect x="3" y="3" width="17" height="8" rx="1" fill="currentColor"/>
    <path d="M26 5v4" stroke="currentColor" stroke-width="2"/>
    </svg>
    <span>82%</span>
    </div>
    <div class="preview-tile">09:41</div>
    </div>
    </div>
    </div>
    <div class="preview-below">
    <div class="tooltip-example" aria-hidden="true">
    <div class="preview-tooltip">Battery at 82%</div>
    </div>
    <div class="preview-popup" aria-hidden="true">
    <h3 class="preview-heading">Battery</h3>
    <div class="preview-row">
    <span class="preview-key">Charge</span>
    <span class="preview-value">82%</span>
    </div>
    <div class="preview-meter">
    <span class="preview-meter-fill">
    </span>
    </div>
    <div class="preview-row">
    <span class="preview-key">Power source</span>
    <span class="preview-value">Battery</span>
    </div>
    </div>
    </div>
    </div>
    <div class="preview-cue" aria-hidden="true"></div>
    <p class="preview-caption">Bar, popup and tooltip</p>
    </div>
    <p class="font-note" hidden>macOS fonts show only on a Mac. Other systems use a fallback.</p>
    </section>`;
}

function render() {
  root.innerHTML = `<div class="split">
    <div class="editor-column">
    <div class="base-block">
    <label class="base-label" for="base-theme">Base theme</label>
    <select class="base-select" id="base-theme">${BASE_IDS.map(id => `<option value="${id}">${e(baseNames.get(id))}</option>`).join("")}</select>
    <p class="base-help">Choose a starting point. Changing it replaces your color and shape edits.</p>
    <p class="base-meta"></p>
    </div>${Object.entries(names).map(([group, name], index) => `<details class="group" data-control-section="${group}" ${group === "palette" ? "open" : ""}>
    <summary>
    <span class="section-no">${String(index + 1).padStart(2, "0")}</span>
    <h2>${name}</h2>${group === "palette" ? '<span class="summary-note">Light and dark</span>' : ""}</summary>
    <p class="group-intro">${groupCopy[group]}</p>
    <div class="control-grid" data-group="${group}"></div>
    </details>`).join("")}</div>
    <aside class="sticky">${previewHTML()}<section class="json-panel" aria-label="Read-only theme files">
    <div class="json-heading">
    <div class="file-tabs" role="tablist" aria-label="Theme files">
    <button id="tab-config" role="tab" data-json="config" aria-controls="json-content">config.json</button>
    <button id="tab-package" role="tab" data-json="package" aria-controls="json-content">package.json</button>
    </div>
    <span class="read-only">Read only</span>
    </div>
    <pre class="json-content" id="json-content" tabindex="0" role="tabpanel"><code>
    </code></pre>
    <p class="active-path"></p>
    <div class="kept"></div>
    </section>
    <section class="outputs" aria-label="Download and share">
    <div class="output-buttons">
    <button class="btn primary" data-action="download">Download zip</button>
    <button class="btn" data-action="try" hidden>Try in StableBar</button>
    </div>
    <p class="version-note" hidden></p>
    <div class="output-secondary">
    <button class="btn text" data-action="share">Copy share link</button>
    <button class="btn text" data-action="store">Submit to the Store</button>
    </div>
    <p class="output-note" id="output-note" role="status"></p>
    <p class="store-note small" role="status"></p>
    <p class="file-note">The zip and link carry the same two files.</p>
    <p class="file-note" data-screenshot-note hidden>The original screenshot is omitted because this zip has no preview image.</p>
    <p class="feedback" role="status"></p>
    </section>
    </aside>
    </div>`;
  renderControls();
  refresh();
  cueResizeObserver?.disconnect();
  cueResizeObserver?.observe(root.querySelector(".preview-stage"));
}

function updateJSON() {
  const kept = keptFromBase(state.config), manifest = jsonFile === "package";
  const object = manifest ? JSON.parse(themeFiles(state, { validate: false }).manifestText) : state.config;
  const paths = activePaths.filter(path => manifest === path.startsWith("manifest.")).map(path => path.replace(/^manifest\./, ""));
  const lines = [];
  function line(text, path, key) {
    const focused = paths.some(control => path === control || path.startsWith(control + "."));
    let html = e(text);
    if (key !== null) html = html.replace(e(JSON.stringify(key)), () => `<span class="json-key">${e(JSON.stringify(key))}</span>`);
    lines.push(`<span class="json-line${focused ? " is-focused" : ""}${!manifest && key !== null && kept.includes(path) ? " is-kept" : ""}" data-json-path="${e(path)}">${html}</span>`);
  }
  function visit(value, path = "", depth = 0, key = null, comma = false) {
    const indent = "  ".repeat(depth), prefix = indent + (key === null ? "" : JSON.stringify(key) + ": ");
    if (value && typeof value === "object") {
      const array = Array.isArray(value), entries = Object.entries(value);
      if (!entries.length) line(prefix + (array ? "[]" : "{}") + (comma ? "," : ""), path, key);
      else {
        line(prefix + (array ? "[" : "{"), path, key);
        entries.forEach(([key, child], index) => visit(child, path ? `${path}.${key}` : key, depth + 1, array ? null : key, index < entries.length - 1));
        line(indent + (array ? "]" : "}") + (comma ? "," : ""), path, null);
      }
    } else line(prefix + JSON.stringify(value) + (comma ? "," : ""), path, key);
  }
  visit(object);
  root.querySelector(".json-content code").innerHTML = lines.join("\n") + "\n";
  root.querySelector(".json-content").setAttribute("aria-labelledby", `tab-${jsonFile}`);
  root.querySelectorAll("[data-json]").forEach(button => {
    const selected = button.dataset.json === jsonFile;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  root.querySelector(".active-path").textContent = activePaths.length ? `Control in focus: ${activePaths.join(", ")}` : "Focus a control to find its key here.";
  root.querySelector(".kept").innerHTML = `<strong>Kept from the base theme</strong>${kept.length ? `<details><summary>${kept.length} ${kept.length === 1 ? "setting stays" : "settings stay"} in your files. This preview does not show ${kept.length === 1 ? "it" : "them"} exactly.</summary><ul>${kept.map(path => `<li><code>${e(path)}</code></li>`).join("")}</ul></details>` : "No extra settings in this base theme."}`;
}

function exportProblem({ waitForStore = true } = {}) {
  if (fieldErrors.size) return [...fieldErrors.values()][0];
  try { themeFiles(state); } catch (error) { return message(error); }
  if (mode === "new" && sourceID?.toLowerCase() === state.manifest.id.toLowerCase()) return messages.sameID;
  if (mode === "new" && store.status === "found") return messages.takenID;
  if (waitForStore && store.status === "checking") return "Checking the id in the Store…";
  return "";
}

function higherVersion(left, right) {
  const a = left.split(".").map(BigInt), b = right.split(".").map(BigInt);
  for (let index = 0; index < 3; index++) if (a[index] !== b[index]) return a[index] > b[index];
  return false;
}

function updateOutputs() {
  const problem = exportProblem(), downloadProblem = exportProblem({ waitForStore: false });
  let linkProblem = "";
  try { encodeLink(themeFiles(state)); } catch (error) { linkProblem = message(error); }
  for (const action of ["download", "share", "try"]) {
    const button = root.querySelector(`[data-action="${action}"]`);
    button.disabled = action === "download" ? !!downloadProblem : !!problem || !!linkProblem;
    button.setAttribute("aria-describedby", "output-note");
  }
  root.querySelector("[data-action=try]").hidden = TRY_LINK_MIN_VERSION === null;
  const versionNote = root.querySelector(".version-note");
  versionNote.hidden = TRY_LINK_MIN_VERSION === null;
  versionNote.textContent = TRY_LINK_MIN_VERSION ? `Needs StableBar ${TRY_LINK_MIN_VERSION} or later.` : "";
  root.querySelector(".output-note").textContent = problem || linkProblem;
  const updateWarning = mode === "update" && store.status === "found" && isVersion(state.manifest.version) && !higherVersion(state.manifest.version, store.manifest.version);
  root.querySelector(".store-note").textContent = store.status === "unavailable" ? messages.storeUnavailable : updateWarning ? `The Store has ${store.manifest.version}. Raise your version above it before submitting.` : "";
  for (const control of controlsFor(state)) {
    const error = root.querySelector(`#c-${control.id.replaceAll(".", "-")}-error`);
    let reason = fieldErrors.get(control.id) ?? "";
    if (control.id === "about.name") {
      if (!state.manifest.name.trim()) reason = messages.invalidName;
      else if (!state.manifest.id) reason = messages.invalidID;
      else if (isReserved(state.manifest.id)) reason = messages.reservedID;
      else if (mode === "new" && store.status === "found") reason = messages.takenID;
    }
    if (control.id === "about.version" && !isVersion(state.manifest.version)) reason = messages.invalidVersion;
    if (error) error.textContent = reason;
    root.querySelectorAll(`[data-control="${control.id}"]`).forEach(input => input.setAttribute("aria-invalid", String(!!reason)));
  }
  updateStoreGuide();
}

function refresh() {
  const r = resolved(), preview = root.querySelector(".theme-preview");
  preview.className = "theme-preview " + indicatorClass(r);
  for (const [key, value] of Object.entries(cssVariables(r))) preview.style.setProperty(key, value);
  root.querySelectorAll(".preview-stage, .json-panel").forEach(element => element.dataset.appearance = appearance);
  root.querySelectorAll("[data-appearance]").forEach(button => {
    if (button.tagName === "BUTTON") button.setAttribute("aria-pressed", String(button.dataset.appearance === appearance));
  });
  const mac = /Mac|iPhone|iPad|iPod/.test(navigator.platform) && !/iPhone|iPad|iPod/.test(navigator.userAgent) && navigator.maxTouchPoints < 2;
  root.querySelector(".font-note").hidden = mac || ![r.defaults.fontName, r.popupDefaults.fontName].some(font => font && font !== "system");
  root.querySelector(".base-meta").textContent = baseDescriptions[baseID] ?? "Settings from the theme you opened";
  root.querySelector("[data-screenshot-note]").hidden = !state.manifest.screenshot;
  root.querySelector("[data-theme-id]").innerHTML = `Folder id: <code>${e(state.manifest.id)}</code>${mode === "update" ? " · Kept for this update" : ""}`;
  root.querySelectorAll("[data-reset]").forEach(button => button.hidden = !differsFromBase(state, button.dataset.reset, bases.get(baseID)));
  updateJSON();
  updateOutputs();
  updateCue();
}

async function lookupStore(id) {
  if (!storeCache.has(id)) {
    storeCache.set(id, storeManifest(id, url => fetch(url, { signal: AbortSignal.timeout(8000) }))
      .then(manifest => manifest ? { status: "found", manifest } : { status: "free" })
      .catch(() => ({ status: "unavailable" })));
  }
  return storeCache.get(id);
}

function resetStoreCheck() {
  clearTimeout(storeTimer);
  storeRequest++;
  store = { status: "unchecked" };
}

function canCheckStore() {
  const id = state.manifest.id;
  return ID_PATTERN.test(id) && !isReserved(id);
}

async function checkStore(id, request) {
  const result = await lookupStore(id);
  if (request !== storeRequest) return;
  store = result;
  updateOutputs();
}

function scheduleStoreCheck() {
  resetStoreCheck();
  if (!canCheckStore()) return;
  store = { status: "checking" };
  const request = storeRequest, id = state.manifest.id;
  storeTimer = setTimeout(() => checkStore(id, request), 300);
}

function requestStoreCheck() {
  if (!canCheckStore() || !["unchecked", "checking"].includes(store.status)) return Promise.resolve();
  clearTimeout(storeTimer);
  store = { status: "checking" };
  const request = ++storeRequest;
  updateOutputs();
  return checkStore(state.manifest.id, request);
}

function numberControl(input) {
  if (!input?.dataset.control) return;
  return controlsFor(state).find(control => control.id === input.dataset.control && control.kind === "number");
}

function writeNumber(input, value) {
  input.value = formatNumber(value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function commitNumber(input, control) {
  const value = parseNumber(input.value);
  if (value === null) {
    if (!input.value.trim() && control.id === "workspaces.underlineWidth") {
      input.value = "";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    } else {
      const [min, max] = control.range;
      fieldErrors.set(control.id, `Enter a number from ${min} to ${max}.`);
      updateOutputs();
    }
  } else writeNumber(input, clampNumber(value, control));
}

function updateNumberSlider(id, value) {
  const slider = root.querySelector(`[data-slider-for="${id}"]`);
  if (slider && value != null) slider.value = formatNumber(value);
}

function changeControl(input) {
  const control = controlsFor(state).find(control => control.id === input.dataset.control);
  if (!control) return;
  let value = input.type === "checkbox" ? input.checked : input.value;
  if (control.kind === "font") {
    value = value.trim();
    if (!value) return;
  }
  const color = control.kind === "color" || (control.kind === "background" && input.tagName !== "SELECT");
  if (color) {
    if (!/^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value)) {
      fieldErrors.set(control.id, "Use #RRGGBB or #RRGGBBAA for this color."); updateOutputs(); return;
    }
  } else if (control.kind === "number") {
    value = parseNumber(input.value);
    fieldErrors.delete(control.id);
    const emptyWidth = !input.value.trim() && control.id === "workspaces.underlineWidth";
    if (!emptyWidth && (value === null || value < control.range[0] || value > control.range[1])) {
      updateOutputs(); return;
    }
  }
  fieldErrors.delete(control.id);
  if (control.id === "bar.background" && value === "gradient") value = baseGradient;
  const oldID = state.manifest.id;
  try {
    const next = applyControl(state, control.id, value, appearance);
    if (control.id === "about.name" && mode === "update") next.manifest.id = oldID;
    resolveTheme(builtIn, next.config, appearance);
    state = next;
  } catch (error) { fieldErrors.set(control.id, message(error)); updateOutputs(); return; }
  if (control.id === "about.name") scheduleStoreCheck();
  activePaths = control.paths;
  jsonFile = control.group === "about" ? "package" : "config";
  // Keep the input being typed into in place; token edits can change the other controls' resolved values.
  const r = resolved();
  if (control.kind === "number") updateNumberSlider(control.id, value);
  for (const other of controlsFor(state)) {
    if (other.id === control.id || fieldErrors.has(other.id)) continue;
    const value = controlValue(other, r);
    root.querySelectorAll(`[data-control="${other.id}"]`).forEach(element => {
      // Only the font control changes the font; its menu may rest on Other font… while a typed name applies.
      if ("fontSelect" in element.dataset) return;
      if ("colorButton" in element.dataset) element.style.setProperty("--swatch", typeof value === "string" && value.startsWith("#") ? value : "#00000000");
      else if (element.hasAttribute("data-color-text")) element.value = value ?? "#00000000";
      else if (other.kind === "number") element.value = value == null ? "" : formatNumber(value);
      else if (other.kind !== "toggle" && other.kind !== "background") element.value = value ?? "";
    });
    if (other.kind === "number") updateNumberSlider(other.id, value);
  }
  if (color) {
    input.parentElement.querySelector("[data-color-text]").value = value;
    input.parentElement.querySelector("[data-color-button]").style.setProperty("--swatch", value);
  }
  if (input.type === "checkbox") input.closest(".toggle").querySelector("span").textContent = input.checked ? "On" : "Off";
  if (control.id === "workspaces.indicator" || (control.id === "bar.background" && input.tagName === "SELECT")) renderControls();
  refresh();
}

function resetToBase(id) {
  state = resetControl(state, id, bases.get(baseID));
  fieldErrors.delete(id);
  renderControls();
  refresh();
  root.querySelector(`#c-${id.replaceAll(".", "-")}`).focus();
}

function showDialog(html) {
  dialog.innerHTML = html;
  if (!dialog.open) dialog.showModal();
  dialog.querySelector("button, input")?.focus({ preventScroll: true });
  dialog.scrollTop = 0;
}
const dialogHead = (title, eyebrow = "") => `<div class="dialog-head"><div>${eyebrow ? `<p class="eyebrow">${e(eyebrow)}</p>` : ""}<h2 id="dialog-title">${title}</h2></div><button class="btn icon" data-action="close" aria-label="Close">×</button></div>`;

function openFiles() {
  showDialog(`${dialogHead("Open a theme")}<p class="dialog-intro">Reopen a zip or folder. A shared link opens here when you visit it.</p><div class="drop-zone"><p>Drop a theme zip or folder here.</p><div class="file-inputs"><label class="btn">Choose zip<input type="file" accept=".zip,application/zip" data-open-zip></label><label class="btn">Choose folder<input type="file" webkitdirectory multiple data-open-folder></label></div></div><p class="field-error" data-import-error role="status"></p><div class="dialog-actions"><button class="btn" data-action="close">Cancel</button></div>`);
}

function offerReopen(files) {
  pendingTheme = parseTheme(files);
  cssVariables(resolveTheme(builtIn, pendingTheme.config, "light"));
  cssVariables(resolveTheme(builtIn, pendingTheme.config, "dark"));
  document.querySelector("#page-message").textContent = "";
  const { name, version, id } = pendingTheme.manifest;
  showDialog(`${dialogHead("Update it or make a new theme?", `${name} · ${version}`)}<p class="dialog-intro">You opened ${e(name)}. Is it your theme, or a starting point for a new one?</p>
    <label class="choice">
    <span class="choice-title">
    <input type="radio" name="reopen" value="update" ${isReserved(id) ? "disabled" : ""}>Update it</span>
    <p>For your own theme. Keep the id and author. Raise the version to ${e(nextPatch(version))}.${isReserved(id) ? " This id belongs to a theme that comes with StableBar; give your copy a new name." : ""}</p>
    </label>
    <label class="choice">
    <span class="choice-title">
    <input type="radio" name="reopen" value="remix">Make a new theme from it</span>
    <p>Choose a new name and id. Clear the author and start at 1.0.0.</p>
    </label>
    <div class="control remix-name" hidden>
    <label for="new-theme-name">New theme name</label>
    <input type="text" id="new-theme-name" autocomplete="off" placeholder="For example, Harbour light">
    <p class="help">The name gives your theme a new folder id.</p>
    </div>
    <p class="field-error" data-reopen-error role="status"></p>
    <div class="dialog-actions">
    <button class="btn" data-action="close">Cancel</button>
    <button class="btn primary" data-action="continue" disabled>Continue</button>
    </div>`);
}

function checkReopen() {
  const choice = dialog.querySelector('[name="reopen"]:checked')?.value;
  const field = dialog.querySelector("#new-theme-name");
  let reason = "";
  if (choice === "remix") {
    const id = slug(field.value);
    if (!id) reason = messages.invalidID;
    else if (isReserved(id)) reason = messages.reservedID;
    else if (id.toLowerCase() === pendingTheme.manifest.id.toLowerCase()) reason = messages.sameID;
  }
  field.setAttribute("aria-invalid", String(!!reason));
  dialog.querySelector("[data-reopen-error]").textContent = reason;
  dialog.querySelector('[data-action="continue"]').disabled = !choice || !!reason;
}

function continueReopen() {
  checkReopen();
  if (dialog.querySelector('[data-action="continue"]').disabled) return;
  const choice = dialog.querySelector('[name="reopen"]:checked').value;
  state = structuredClone(pendingTheme);
  sourceID = state.manifest.id;
  mode = choice === "update" ? "update" : "new";
  if (mode === "update") state.manifest.version = nextPatch(state.manifest.version);
  else {
    state.manifest.name = dialog.querySelector("#new-theme-name").value;
    state.manifest.id = slug(state.manifest.name);
    state.manifest.version = "1.0.0";
    delete state.manifest.author;
    delete state.manifest.repository;
  }
  baseGradient = at(state.config, "bar.style.background")?.gradient ? structuredClone(state.config.bar.style.background) : undefined;
  baseID = "opened";
  bases.set(baseID, structuredClone(state.config));
  fieldErrors.clear();
  resetStoreCheck();
  if (mode === "new") scheduleStoreCheck();
  dialog.close();
  renderControls();
  const baseSelect = root.querySelector("#base-theme");
  if (!baseSelect.querySelector('[value="opened"]')) baseSelect.add(new Option("Opened theme", "opened"));
  baseSelect.value = "opened";
  refresh();
  root.querySelector('[data-control-section="about"]').open = true;
  root.querySelector('#c-about-name').focus();
  notify(mode === "update" ? `Ready to edit version ${state.manifest.version}.` : `Ready to edit ${state.manifest.name}.`);
}

async function openSelection(files, request = ++importRequest) {
  if (!dialog.open || !dialog.querySelector(".drop-zone")) openFiles();
  dialog.querySelector("[data-import-error]").textContent = "Opening theme…";
  try {
    const zip = files.length === 1 && /\.zip$/i.test(files[0].name);
    if (zip && files[0].file.size > 32 * 1024 * 1024) fail("importTooLarge");
    const content = zip ? await readZip(new Uint8Array(await files[0].file.arrayBuffer())) : await folderFiles(files);
    if (request !== importRequest || !dialog.open) return;
    offerReopen(content);
  } catch (error) {
    if (request === importRequest && dialog.open) dialog.querySelector("[data-import-error]").textContent = message(error);
  }
}

async function droppedFiles(transfer) {
  const entries = [...transfer.items].map(item => item.webkitGetAsEntry?.()).filter(Boolean);
  if (!entries.length) return [...transfer.files].map(file => ({ name: file.webkitRelativePath || file.name, file }));
  const files = [];
  async function visit(entry, parent = "") {
    const name = parent + entry.name;
    if (entry.name.startsWith(".") || entry.name === "__MACOSX") return;
    if (entry.isFile) files.push({ name, file: await new Promise((resolve, reject) => entry.file(resolve, reject)) });
    else if (entry.isDirectory) {
      const reader = entry.createReader();
      while (true) {
        const children = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
        if (!children.length) break;
        for (const child of children) await visit(child, name + "/");
      }
    }
  }
  for (const entry of entries) await visit(entry);
  return files;
}

function invalidStoreTextField() {
  return ["name", "description"].find(field => /[|\r\n\u2028\u2029]/.test(state.manifest[field] ?? ""));
}

function updateStoreGuide() {
  const rowSection = dialog.querySelector("[data-store-row]");
  if (!dialog.open || !rowSection) return;
  let row = "", reason = exportProblem(), control;
  if ([messages.invalidID, messages.reservedID, messages.invalidName, messages.sameID, messages.takenID].includes(reason)) control = "name";
  else if (reason === messages.invalidVersion) control = "version";
  if (!reason) {
    control = invalidStoreTextField();
    if (control) reason = messages.invalidStoreText;
  }
  if (!reason) {
    try { row = readmeRow(JSON.parse(themeFiles(state).manifestText)); }
    catch (error) {
      reason = message(error);
      if (reason === messages.descriptionRequired) control = "description";
    }
  }
  rowSection.querySelector("[data-store-error]").textContent = reason;
  const editAbout = rowSection.querySelector('[data-action="about"]');
  editAbout.hidden = !control || store.status === "checking";
  editAbout.dataset.aboutField = control ?? "";
  rowSection.querySelector(".readme-box").hidden = !!reason;
  const preview = rowSection.querySelector("pre");
  if (preview.textContent !== row) preview.textContent = row;
  dialog.querySelector('[data-action="download"]').disabled = !!exportProblem({ waitForStore: false });
}

function storeGuide() {
  void requestStoreCheck();
  showDialog(`${dialogHead("Submit to the Store", "Share your theme")}<div class="dialog-intro">
    <p class="small muted">Download and unzip your theme first. The rest happens in your browser.</p>
    <ol class="guide-steps">
    <li>
    <strong>Fork <a href="https://github.com/stablebox/stablebar-packages/fork">stablebar-packages</a>.</strong>
    <p>Make your own copy on GitHub.</p>
    </li>
    <li>
    <strong>Upload your theme folder into <code>packages/</code>.</strong>
    <p>Use GitHub’s Upload files button. Keep the folder named <code>${e(state.manifest.id)}</code>.</p>
    </li>
    <li>
    <strong>Add your theme to <code>README.md</code>.</strong>
    <p>Edit it in the browser. Paste this row in order by folder name.</p>
    <div data-store-row>
    <p class="field-error" role="status" data-store-error></p>
    <button class="btn" data-action="about" hidden>Edit About</button>
    <div class="readme-box" hidden>
    <pre tabindex="0" aria-label="Row for the Store README"></pre>
    <button class="btn" data-action="row">Copy table row</button>
    </div></div></li>
    <li>
    <strong>Open a pull request.</strong>
    <p>Send your changes back to stablebar-packages.</p>
    </li>
    </ol>
    <p class="guide-foot">Use your GitHub username as the author. <a class="guide-link" href="https://github.com/stablebox/stablebar-packages/blob/main/CONTRIBUTING.md">Read the Store guide</a>.</p>
    </div>
    <p class="feedback" role="status"></p>
    <div class="dialog-actions">
    <button class="btn" data-action="close">Done</button>
    <button class="btn primary" data-action="download">Download zip</button>
    </div>`);
  updateStoreGuide();
}

function notify(text) {
  root.querySelector(".feedback").textContent = text;
  const feedback = dialog.querySelector(".feedback");
  if (feedback) feedback.textContent = text;
}

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); }
  catch { fail("copyFailed"); }
}

async function output(action) {
  // Clipboard writes must stay inside the click in Safari, so only Try waits for the Store check.
  const id = state.manifest.id, check = requestStoreCheck(), waits = action === "try";
  if (waits) await check;
  if (id !== state.manifest.id) return;
  if (exportProblem({ waitForStore: waits })) { updateOutputs(); return; }
  const files = themeFiles(state);
  if (action === "download") {
    const url = URL.createObjectURL(new Blob([writeZip(state.manifest.id, files)], { type: "application/zip" }));
    const anchor = document.createElement("a");
    anchor.href = url; anchor.download = `${state.manifest.id}.zip`;
    document.body.append(anchor); anchor.click(); anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    notify(`Downloaded ${state.manifest.id}.zip.`);
  } else if (action === "share") {
    await copyText(shareURL(location.href, files));
    notify("Theme link copied.");
  } else if (action === "try" && TRY_LINK_MIN_VERSION !== null) location.href = encodeLink(files);
  else if (action === "row") {
    if (invalidStoreTextField()) fail("invalidStoreText");
    await copyText(readmeRow(JSON.parse(files.manifestText)));
    notify("Table row copied.");
  }
}

function loadHash() {
  if (!location.hash || location.hash === "#main") return;
  try { offerReopen(decodeLink(location.hash)); }
  catch (error) { document.querySelector("#page-message").textContent = message(error); }
}

async function start() {
  await Promise.all(BASE_IDS.map(async id => {
    const [config, manifest] = await Promise.all(["config.json", "package.json"].map(async file => {
      const response = await fetch(`creator/themes/${id}/${file}`);
      if (!response.ok) throw new Error(`Could not load ${id}. Reload the page to try again.`);
      return response.json();
    }));
    bases.set(id, config);
    baseNames.set(id, manifest.name);
  }));
  state = { manifest: { id: "my-theme", name: "My theme", version: "1.0.0" }, config: structuredClone(builtIn) };
  render();
  document.querySelector('[data-action="open"]').disabled = false;
  loadHash();
}

let picker;
const clampUnit = value => Math.min(1, Math.max(0, value));
const recentColors = () => JSON.parse(localStorage.getItem("recent-colors") ?? "[]");
const swatchHTML = (color, label) => `<button type="button" class="color-swatch" data-swatch="${color}" aria-label="${label} ${color}" title="${color}" style="--swatch: ${color}"></button>`;

function openColorPicker(button) {
  const control = controlsFor(state).find(control => control.id === button.dataset.control);
  const value = controlValue(control, resolved());
  const base = controlValue(control, resolveTheme(builtIn, bases.get(baseID), appearance));
  const recent = recentColors();
  const wrapper = button.closest(".color-picker");
  wrapper.insertAdjacentHTML("beforeend", `<div class="color-popover" role="dialog" aria-label="${e(control.label)} color">
    <div class="color-area" role="slider" tabindex="0" aria-label="Saturation and brightness"><span class="color-area-thumb"></span></div>
    <input type="range" class="color-hue" data-channel="h" min="0" max="360" aria-label="Hue">
    <input type="range" class="color-alpha" data-channel="a" min="0" max="255" aria-label="Opacity">
    ${isColor(base) ? `<p class="color-heading">Base theme</p><div class="color-swatches">${swatchHTML(base, "Base theme color")}<code>${base}</code></div>` : ""}
    <p class="color-heading">Recent</p>
    ${recent.length ? `<div class="color-swatches">${recent.map(color => swatchHTML(color, "Recent color")).join("")}</div>` : '<p class="color-empty">Colors you pick show here.</p>'}
    </div>`);
  picker = { button, popover: wrapper.lastElementChild, text: button.nextElementSibling, color: hsvFromHex(isColor(value) ? value : "#00000000") };
  button.setAttribute("aria-expanded", "true");
  if (picker.popover.getBoundingClientRect().right > document.documentElement.clientWidth) picker.popover.classList.add("is-end");
  paintColorPicker();
  picker.popover.querySelector(".color-area").focus();
}

function paintColorPicker() {
  const { popover, color } = picker;
  const area = popover.querySelector(".color-area"), alpha = popover.querySelector(".color-alpha");
  area.style.setProperty("--hue", color.h);
  area.style.setProperty("--s", color.s);
  area.style.setProperty("--v", color.v);
  area.setAttribute("aria-valuetext", `Saturation ${Math.round(color.s * 100)}%, brightness ${Math.round(color.v * 100)}%`);
  popover.querySelector(".color-hue").value = color.h;
  alpha.value = color.a;
  alpha.setAttribute("aria-valuetext", `${Math.round(color.a / 2.55)}%`);
  alpha.style.setProperty("--opaque", hexFromHSV({ ...color, a: 255 }));
}

function pickColor(color) {
  picker.color = color;
  picker.picked = hexFromHSV(color);
  picker.text.value = picker.picked;
  changeControl(picker.text);
  paintColorPicker();
}

function pickFromArea(area, event) {
  const rect = area.getBoundingClientRect();
  pickColor({ ...picker.color, s: clampUnit((event.clientX - rect.left) / rect.width),
    v: clampUnit(1 - (event.clientY - rect.top) / rect.height), a: picker.color.a || 255 });
}

function saveRecentColor(color) {
  localStorage.setItem("recent-colors", JSON.stringify(addRecentColor(recentColors(), color)));
}

function closeColorPicker(focusButton) {
  const { button, popover, picked } = picker;
  picker = undefined;
  popover.remove();
  button.setAttribute("aria-expanded", "false");
  if (picked) saveRecentColor(picked);
  if (focusButton) button.focus();
}

document.addEventListener("click", event => {
  const swatch = event.target.closest("[data-swatch]"), button = event.target.closest("[data-color-button]");
  if (swatch) pickColor(hsvFromHex(swatch.dataset.swatch));
  else if (button && picker?.button === button) closeColorPicker(true);
  else if (button) openColorPicker(button);
});
document.addEventListener("input", event => {
  if (!picker?.popover.contains(event.target)) return;
  const value = Number(event.target.value);
  pickColor(event.target.dataset.channel === "h" ? { ...picker.color, h: value, a: picker.color.a || 255 } : { ...picker.color, a: value });
});
document.addEventListener("keydown", event => {
  if (!picker?.popover.contains(event.target)) return;
  if (event.key === "Escape") closeColorPicker(true);
  else if (event.target.matches(".color-area") && event.key.startsWith("Arrow")) {
    const step = event.shiftKey ? 0.1 : 0.01, { s, v, a } = picker.color;
    const [nextS, nextV] = { ArrowLeft: [s - step, v], ArrowRight: [s + step, v], ArrowDown: [s, v - step], ArrowUp: [s, v + step] }[event.key];
    pickColor({ ...picker.color, s: clampUnit(nextS), v: clampUnit(nextV), a: a || 255 });
  } else return;
  event.preventDefault();
});
document.addEventListener("pointerdown", event => {
  if (picker && !picker.button.closest(".color-picker").contains(event.target)) closeColorPicker(false);
  const area = event.target.closest(".color-area");
  if (!area || event.button !== 0) return;
  area.setPointerCapture(event.pointerId);
  pickFromArea(area, event);
});
document.addEventListener("pointermove", event => {
  if (event.target.matches(".color-area") && event.target.hasPointerCapture(event.pointerId)) pickFromArea(event.target, event);
});

document.addEventListener("input", event => {
  if (event.target.dataset.control || event.target.dataset.sliderFor) hoveredControl = undefined;
  if (event.target.dataset.sliderFor) {
    const input = root.querySelector(`[data-control="${event.target.dataset.sliderFor}"]`);
    writeNumber(input, Number(event.target.value));
    return;
  }
  if (event.target.dataset.control && !["checkbox", "select-one"].includes(event.target.type)) changeControl(event.target);
  if (event.target.dataset.control) updateCue();
  if (event.target.id === "new-theme-name") checkReopen();
});
document.addEventListener("change", event => {
  const input = event.target;
  const control = numberControl(input);
  if (control) commitNumber(input, control);
  else if (input.dataset.control && ["checkbox", "select-one"].includes(input.type)) changeControl(input);
  else if (input.hasAttribute("data-color-text") && !fieldErrors.has(input.dataset.control)) saveRecentColor(input.value);
  if (input.id === "base-theme") {
    if (!bases.has(input.value)) return;
    baseID = input.value;
    state.config = structuredClone(bases.get(baseID));
    baseGradient = state.config.bar?.style?.background?.gradient ? structuredClone(state.config.bar.style.background) : undefined;
    for (const key of fieldErrors.keys()) if (!key.startsWith("about.")) fieldErrors.delete(key);
    renderControls(); refresh();
  }
  if (input.name === "reopen") {
    dialog.querySelector(".remix-name").hidden = input.value !== "remix";
    if (input.value === "remix") dialog.querySelector("#new-theme-name").focus();
    checkReopen();
  }
  if (input.matches("[data-open-zip], [data-open-folder]")) openSelection([...input.files].map(file => ({ name: file.webkitRelativePath || file.name, file })));
});
document.addEventListener("focusin", event => {
  if (picker && !picker.popover.contains(event.target) && event.target !== picker.button) closeColorPicker(false);
  focusedControl = cueControlID(event.target);
  if (event.target.closest(".control")) hoveredControl = undefined;
  updateCue();
  if (!event.target.dataset.control) return;
  const control = controlsFor(state).find(control => control.id === event.target.dataset.control);
  if (!control) return;
  activePaths = control.paths; jsonFile = control.group === "about" ? "package" : "config";
  updateJSON();
  const pre = root.querySelector(".json-content"), mark = pre.querySelector(".is-focused");
  if (mark) pre.scrollTop = mark.offsetTop - 40;
});
document.addEventListener("focusout", event => {
  focusedControl = cueControlID(event.relatedTarget);
  updateCue();
});
window.addEventListener("resize", updateCue);
// The font menu is a listbox, not a <select>: macOS draws select menus natively and ignores option fonts.
const fontOptions = list => [...list.querySelectorAll('[role="option"]')];

function setActiveFont(list, option) {
  for (const other of fontOptions(list)) other.classList.toggle("is-active", other === option);
  list.setAttribute("aria-activedescendant", option.id);
  option.scrollIntoView({ block: "nearest" });
}

function openFontList(button) {
  const list = root.querySelector(`#${button.getAttribute("aria-controls")}`);
  list.hidden = false;
  button.setAttribute("aria-expanded", "true");
  setActiveFont(list, fontOptions(list).find(option => option.dataset.value === button.value) ?? fontOptions(list)[0]);
  list.focus();
}

function closeFontList(list, focusButton) {
  if (list.hidden) return;
  list.hidden = true;
  const button = root.querySelector(`[aria-controls="${list.id}"]`);
  button.setAttribute("aria-expanded", "false");
  if (focusButton) button.focus();
}

function chooseFont(button, value) {
  const other = root.querySelector(`.font-other[data-control="${button.dataset.control}"]`);
  other.hidden = value !== "";
  if (value === "") { other.focus(); return; }
  button.value = value;
  button.textContent = value === "system" ? "System" : value;
  button.style.fontFamily = fontFamily(value);
  const list = root.querySelector(`#${button.getAttribute("aria-controls")}`);
  for (const option of fontOptions(list)) option.setAttribute("aria-selected", String(option.dataset.value === value));
  changeControl(button);
}

function fontListKey(list, event) {
  const options = fontOptions(list);
  const index = Math.max(0, options.findIndex(option => option.classList.contains("is-active")));
  const button = root.querySelector(`[aria-controls="${list.id}"]`);
  const keys = { ArrowDown: index + 1, ArrowUp: index - 1, Home: 0, End: options.length - 1, PageDown: index + 8, PageUp: index - 8 };
  if (event.key in keys) setActiveFont(list, options[Math.min(options.length - 1, Math.max(0, keys[event.key]))]);
  else if (event.key === "Enter" || event.key === " ") {
    closeFontList(list, true);
    chooseFont(button, options[index].dataset.value);
  } else if (event.key === "Escape") closeFontList(list, true);
  else if (event.key === "Tab") { closeFontList(list, false); return; }
  else if (event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
    fontTyped = Date.now() - fontTypedAt < 600 ? fontTyped + event.key.toLowerCase() : event.key.toLowerCase();
    fontTypedAt = Date.now();
    const match = options.find(option => option.textContent.toLowerCase().startsWith(fontTyped));
    if (match) setActiveFont(list, match);
  } else return;
  event.preventDefault();
}
let fontTyped = "", fontTypedAt = 0;

document.addEventListener("click", event => {
  const option = event.target.closest?.('.font-list [role="option"]');
  const button = event.target.closest?.("[data-font-select]");
  for (const list of root.querySelectorAll(".font-list:not([hidden])")) {
    if (!list.contains(event.target) && list.id !== button?.getAttribute("aria-controls")) closeFontList(list, false);
  }
  if (option) {
    const list = option.closest(".font-list");
    closeFontList(list, true);
    chooseFont(root.querySelector(`[aria-controls="${list.id}"]`), option.dataset.value);
  } else if (button) {
    const list = root.querySelector(`#${button.getAttribute("aria-controls")}`);
    if (list.hidden) openFontList(button);
    else closeFontList(list, true);
  }
});

document.addEventListener("click", async event => {
  const button = event.target.closest("button");
  if (!button || button.disabled) return;
  if (button.dataset.appearance) {
    appearance = button.dataset.appearance;
    fieldErrors.forEach((_value, key) => { if (["color", "background"].includes(controlsFor(state).find(control => control.id === key)?.kind)) fieldErrors.delete(key); });
    renderControls(); refresh();
  }
  if (button.dataset.json) { jsonFile = button.dataset.json; updateJSON(); }
  try {
    const action = button.dataset.action;
    if (action === "open") openFiles();
    else if (action === "close") { importRequest++; dialog.close(); }
    else if (action === "continue") continueReopen();
    else if (action === "reset") resetToBase(button.dataset.reset);
    else if (action === "store") storeGuide();
    else if (action === "about") {
      dialog.close(); root.querySelector('[data-control-section="about"]').open = true;
      root.querySelector(`#c-about-${button.dataset.aboutField}`).focus();
    } else if (["download", "share", "try", "row"].includes(action)) await output(action);
  } catch (error) { notify(message(error)); }
});
document.addEventListener("keydown", event => {
  if (event.target.matches?.(".font-list")) { fontListKey(event.target, event); return; }
  if (event.target.matches?.("[data-font-select]") && ["ArrowDown", "ArrowUp", "Enter", " "].includes(event.key)) {
    event.preventDefault();
    openFontList(event.target);
    return;
  }
  const control = numberControl(event.target);
  if (control && ["ArrowUp", "ArrowDown", "Enter"].includes(event.key)) {
    event.preventDefault();
    hoveredControl = undefined;
    if (event.key === "Enter") commitNumber(event.target, control);
    else {
      const value = controlValue(control, resolved()) ?? control.range[0];
      writeNumber(event.target, nudgeValue(value, event.key === "ArrowUp" ? 1 : -1, control, event.shiftKey));
    }
    updateCue();
    return;
  }
  const tab = event.target.closest('[role="tab"]');
  if (!tab || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  const tabs = [...tab.parentElement.querySelectorAll('[role="tab"]')];
  const index = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (tabs.indexOf(tab) + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
  tabs[index].click(); tabs[index].focus();
});
document.addEventListener("pointerdown", event => {
  const handle = event.target.closest(".scrub-handle");
  if (!handle || event.button !== 0 || event.isPrimary === false || numberDrag) return;
  const input = handle.parentElement.querySelector("[data-control]"), control = numberControl(input);
  if (!control) return;
  event.preventDefault();
  numberDrag = { handle, input, control, origin: controlValue(control, resolved()) ?? control.range[0],
    x: event.clientX, pointerID: event.pointerId };
  handle.setPointerCapture(event.pointerId);
  root.classList.add("is-scrubbing");
  updateCue();
});
document.addEventListener("pointermove", event => {
  if (!numberDrag || event.pointerId !== numberDrag.pointerID) return;
  const { input, control, origin, x } = numberDrag;
  const value = scrubValue(origin, event.clientX - x, control, event.shiftKey);
  if (value !== parseNumber(input.value)) writeNumber(input, value);
});
function endNumberDrag(event) {
  if (!numberDrag || event.pointerId !== numberDrag.pointerID) return;
  const { handle, pointerID } = numberDrag;
  numberDrag = null;
  if (handle.hasPointerCapture(pointerID)) handle.releasePointerCapture(pointerID);
  root.classList.remove("is-scrubbing");
  hoveredControl = cueControlID(root.querySelector(".control:hover"));
  updateCue();
}
document.addEventListener("pointerup", endNumberDrag);
document.addEventListener("pointercancel", endNumberDrag);
document.addEventListener("lostpointercapture", endNumberDrag);
dialog.addEventListener("close", () => {
  // A queued close event can arrive after another import has opened the dialog again.
  if (dialog.open) return;
  pendingTheme = null;
  importRequest++;
});
dialog.addEventListener("cancel", () => { importRequest++; });
document.addEventListener("dragover", event => {
  if (![...event.dataTransfer.types].includes("Files")) return;
  event.preventDefault(); event.dataTransfer.dropEffect = "copy";
  dialog.querySelector(".drop-zone")?.classList.add("is-over");
});
document.addEventListener("dragleave", event => {
  if (!event.relatedTarget || !dialog.contains(event.relatedTarget)) dialog.querySelector(".drop-zone")?.classList.remove("is-over");
});
document.addEventListener("drop", async event => {
  if (![...event.dataTransfer.types].includes("Files")) return;
  event.preventDefault();
  const request = ++importRequest;
  if (!dialog.querySelector(".drop-zone") || !dialog.open) openFiles();
  try {
    const files = await droppedFiles(event.dataTransfer);
    if (request !== importRequest || !dialog.open) return;
    await openSelection(files, request);
  } catch (error) {
    if (request === importRequest && dialog.open) dialog.querySelector("[data-import-error]").textContent = message(error);
  }
  if (request === importRequest) dialog.querySelector(".drop-zone")?.classList.remove("is-over");
});
window.addEventListener("hashchange", loadHash);
start().catch(() => { root.textContent = "The themes could not be loaded. Reload the page to try again."; });
