import builtIn from "./built-in.mjs";

export const BASE_IDS = ["built-in", "leman", "notch", "catppuccin", "nord", "gruvbox", "phosphor"];

export const RESERVED_IDS = new Set([
  ...BASE_IDS,
  "graphite", "island", "menu-bar", "minimal", "paper", "slate", "terminal",
  "blueprint", "broadsheet", "brutalist", "everforest", "handheld", "kanagawa", "platinum", "rose-pine", "synthwave",
]);

export function slug(name) {
  return name.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase()
    .split(/[^a-z0-9]+/).filter(Boolean).join("-");
}

export function isVersion(value) {
  return typeof value === "string" && /^\d+\.\d+\.\d+$/.test(value);
}

export function nextPatch(version) {
  if (!isVersion(version)) throw new Error("Use an x.y.z version.");
  const [major, minor, patch] = version.split(".");
  return `${major}.${minor}.${BigInt(patch) + 1n}`;
}

export function fileText(object) {
  return JSON.stringify(object, null, 2) + "\n";
}

const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const isGradient = value => isObject(value?.gradient) && Object.hasOwn(value.gradient, "colors");

function overriding(earlier, next) {
  if (!isObject(earlier) || !isObject(next) || isGradient(earlier) || isGradient(next)) {
    return structuredClone(next);
  }
  return Object.fromEntries(Object.keys({ ...earlier, ...next }).map(key => [key,
    Object.hasOwn(next, key) ? overriding(earlier[key], next[key]) : structuredClone(earlier[key]),
  ]));
}

function substituteTokens(document, tokens = document.tokens ?? {}) {
  const path = new Set();
  const encoder = new TextEncoder();
  let remaining = 100_000;

  function visit(value, depth = 0) {
    const reference = typeof value === "string" && value.startsWith("@token.");
    if (path.size > 0) {
      remaining--;
      if (isObject(value) || Array.isArray(value) || reference) depth++;
      if (depth > 64) throw new Error("Configuration references nest more than 64 levels deep.");
    }
    if (reference) {
      const name = value.slice("@token.".length);
      if (path.has(name)) throw new Error(`Configuration reference cycle: ${[...path, name].join(" → ")}.`);
      if (!Object.hasOwn(tokens, name)) throw new Error(`Unknown configuration reference: ${value}.`);
      remaining -= Math.floor(encoder.encode(name).length / 256);
      if (remaining < 0) throw new Error("Configuration references expand to more than 100,000 values.");
      path.add(name);
      try { return visit(tokens[name], depth); }
      finally { path.delete(name); }
    }
    if (remaining < 0) throw new Error("Configuration references expand to more than 100,000 values.");
    if (Array.isArray(value)) return value.map(child => visit(child, depth));
    if (isObject(value)) return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, visit(child, depth)]));
    return value;
  }

  return visit(document);
}

function forAppearance(value, appearance) {
  if (Array.isArray(value)) return value.map(child => forAppearance(child, appearance));
  if (!isObject(value)) return value;
  if (Object.hasOwn(value, "light") && Object.hasOwn(value, "dark")) {
    return forAppearance(value[appearance], appearance);
  }
  return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, forAppearance(child, appearance)]));
}

const fontWeights = ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold"];

const appearanceDefaults = {
  accent: "#f7821b", accentText: "#ffffff", borderWidth: 1, cornerRadius: 14,
  paddingHorizontal: 10, paddingVertical: 6, spacing: 6, shadowRadius: 2,
  fontSize: 13, fontName: "system", fontWeight: "regular", iconSize: 13,
};

function inheriting(own, defaults) {
  return Object.fromEntries(Object.keys({ ...defaults, ...own }).map(key => {
    const value = own[key] ?? defaults[key] ?? null;
    if (key === "states" && isObject(value)) {
      return [key, Object.fromEntries(Object.keys({ ...defaults.states, ...own.states }).map(state =>
        [state, inheriting(own.states?.[state] ?? {}, defaults.states?.[state] ?? {})]))];
    }
    return [key, structuredClone(value)];
  }));
}

function withHover(style) {
  const result = structuredClone(style ?? {});
  const aliases = {};
  if (result.hoverBackground != null) aliases.background = result.hoverBackground;
  if (result.hoverForeground != null) aliases.foreground = result.hoverForeground;
  if (Object.keys(aliases).length) {
    result.states = { ...result.states, hover: inheriting(result.states?.hover ?? {}, aliases) };
  }
  return result;
}

function resolvedStyle(style, defaults) {
  const resolved = inheriting(inheriting(withHover(style), withHover(defaults)), appearanceDefaults);
  resolved.hoverBackground = resolved.states?.hover?.background ?? resolved.hoverBackground ?? resolved.background;
  resolved.hoverForeground = resolved.states?.hover?.foreground ?? resolved.hoverForeground ?? resolved.foreground;
  if (!fontWeights.includes(resolved.fontWeight)) resolved.fontWeight = "regular";
  return resolved;
}

export function resolveTheme(base, config, appearance) {
  const resolved = forAppearance(substituteTokens(overriding(base, config)), appearance);
  const defaults = resolved.defaults;
  resolved.defaults = resolvedStyle(defaults);
  resolved.popupDefaults = resolvedStyle(resolved.popupDefaults, defaults);
  resolved.bar ??= {};

  const workspace = resolved.workspaceDefaults ?? {};
  const style = withHover(workspace.style);
  const indicator = workspace.indicator ?? "background";
  const focusedForeground = style.states?.focused?.foreground ?? style.foreground ?? resolved.defaults.accentText;
  style.cornerRadius ??= Math.max(resolved.defaults.cornerRadius - 4, 0);
  style.foreground ??= resolved.defaults.foreground;
  style.states ??= {};
  style.states.focused = {
    ...style.states.focused,
    background: style.states.focused?.background ?? style.background ?? resolved.defaults.accent,
    foreground: focusedForeground,
  };
  workspace.indicator = indicator;
  workspace.style = style;
  workspace.indicatorStyle = inheriting(withHover(workspace.indicatorStyle), {
    height: 2, cornerRadius: 0, background: resolved.defaults.accent,
  });
  workspace.indicatorStyle.states ??= {};
  workspace.indicatorStyle.states.visible = {
    ...workspace.indicatorStyle.states.visible,
    background: workspace.indicatorStyle.states.visible?.background ?? workspace.indicatorStyle.background,
  };
  resolved.workspaceDefaults = workspace;
  return resolved;
}

const docs = "https://github.com/Seb-GRAF/StableBar/blob/main/docs/";
const indicatorIs = indicator => state => (state.config.workspaceDefaults?.indicator ?? "background") === indicator;
const popupSpacing = (_state, flags) => flags.popupSpacing === true;

function control(id, label, kind, paths, help, guide, appliesWhen) {
  return {
    id, group: id.split(".")[0], label, kind, paths,
    help: `${paths.join(", ")}: ${help}`, docs: docs + guide,
    ...(appliesWhen ? { appliesWhen } : {}),
  };
}

function select(id, label, paths, help, guide, options) {
  return { ...control(id, label, "select", paths, help, guide), options };
}

export const CONTROLS = [
  control("about.name", "Name", "text", ["manifest.name", "manifest.id"],
    "Name your theme; its name also gives its folder id.", "themes.md"),
  control("about.description", "Description", "text", ["manifest.description"],
    "Describe the theme in one line.", "themes.md"),
  control("about.author", "Author", "text", ["manifest.author"],
    "Use your GitHub username when submitting to the Store.", "packages.md"),
  control("about.version", "Version", "text", ["manifest.version"],
    "Use an x.y.z version, starting at 1.0.0.", "packages.md"),
  ...[
    ["surface", "Surface"], ["surfaceRaised", "Raised surface"], ["text", "Text"], ["textMuted", "Muted text"],
    ["accent", "Accent"], ["track", "Track"], ["hairline", "Hairline"], ["warning", "Warning"], ["critical", "Critical"],
  ].map(([name, label]) => control(`palette.${name}`, label, "color", [`tokens.${name}`],
    "Edit this palette color for the appearance shown.", "themes.md")),
  control("palette.accentText", "Text on accent", "color", ["defaults.accentText"],
    "Set text drawn on the accent color.", "styling.md#widget-styles"),
  control("bar.height", "Height", "number", ["bar.height"],
    "Set the bar height in points.", "layout.md"),
  control("bar.margin", "Floating margin", "number", ["bar.margin"],
    "Inset the strip from the screen edges.", "layout.md"),
  control("bar.background", "Strip background", "background", ["bar.style.background"],
    "Choose no strip, a color, or keep the base theme's gradient.", "layout.md"),
  control("bar.cornerRadius", "Strip corners", "number", ["bar.style.cornerRadius"],
    "Round the strip's corners in points.", "layout.md"),
  control("bar.borderColor", "Strip border", "color", ["bar.style.borderColor"],
    "Set the strip's border color.", "layout.md"),
  control("bar.borderWidth", "Border width", "number", ["bar.style.borderWidth"],
    "Set the strip's border width in points.", "layout.md"),
  select("bar.borderEdges", "Border edges", ["bar.style.borderEdges"],
    "Choose which strip edges have a border.", "layout.md", ["bottom", "all"]),
  control("widgets.tiles", "Tiles", "toggle", ["defaults.background", "defaults.borderColor", "defaults.shadowColor"],
    "Turn widget tiles on or off, keeping any existing shadow or glow.", "themes.md"),
  control("widgets.fontName", "Font", "text", ["defaults.fontName"],
    "Use system or the name of a font installed on your Mac.", "styling.md#widget-styles"),
  control("widgets.fontSize", "Font size", "number", ["defaults.fontSize"],
    "Set the widget font size in points.", "styling.md#widget-styles"),
  select("widgets.fontWeight", "Font weight", ["defaults.fontWeight"],
    "Choose the widget font weight.", "styling.md#widget-styles", fontWeights),
  control("widgets.cornerRadius", "Tile corners", "number", ["defaults.cornerRadius"],
    "Round widget tile corners in points.", "styling.md#widget-styles"),
  control("widgets.paddingHorizontal", "Horizontal padding", "number", ["defaults.paddingHorizontal"],
    "Set padding beside each widget's content.", "styling.md#widget-styles"),
  control("widgets.paddingVertical", "Vertical padding", "number", ["defaults.paddingVertical"],
    "Set padding above and below each widget's content.", "styling.md#widget-styles"),
  control("widgets.hoverBackground", "Hover color", "color", ["defaults.hoverBackground"],
    "Set the color shown while hovering a widget.", "styling.md#states"),
  control("widgets.shadowColor", "Shadow or glow", "color", ["defaults.shadowColor"],
    "Set the widget shadow or, without tiles, its glow.", "styling.md#widget-styles"),
  control("widgets.shadowRadius", "Shadow radius", "number", ["defaults.shadowRadius"],
    "Set the shadow or glow radius in points.", "styling.md#widget-styles"),
  select("workspaces.indicator", "Indicator", ["workspaceDefaults.indicator"],
    "Choose background, underline or none.", "widgets.md#workspace-appearance", ["background", "underline", "none"]),
  control("workspaces.foreground", "Unfocused text", "color", ["workspaceDefaults.style.foreground"],
    "Set the text color of unfocused workspaces.", "widgets.md#workspace-appearance"),
  control("workspaces.focusedForeground", "Focused text", "color", ["workspaceDefaults.style.states.focused.foreground"],
    "Set the text color of the focused workspace.", "widgets.md#workspace-appearance"),
  control("workspaces.focusedFill", "Focused fill", "color", ["workspaceDefaults.style.states.focused.background"],
    "Set the focused workspace's background.", "widgets.md#workspace-appearance", indicatorIs("background")),
  control("workspaces.cornerRadius", "Indicator corners", "number", ["workspaceDefaults.style.cornerRadius"],
    "Round the background indicator's corners.", "widgets.md#workspace-appearance", indicatorIs("background")),
  ...[
    ["Width", "width", "Underline width"], ["Height", "height", "Underline height"],
    ["CornerRadius", "cornerRadius", "Underline corners"], ["OffsetY", "offsetY", "Underline position"],
  ].map(([name, key, label]) => control(`workspaces.underline${name}`, label, "number",
    [`workspaceDefaults.indicatorStyle.${key}`], "Set the underline's geometry in points.",
    "widgets.md#workspace-appearance", indicatorIs("underline"))),
  control("workspaces.underlineBackground", "Underline color", "color", ["workspaceDefaults.indicatorStyle.background"],
    "Set the focused workspace's underline color.", "widgets.md#workspace-appearance", indicatorIs("underline")),
  control("workspaces.underlineVisibleBackground", "Visible underline", "color",
    ["workspaceDefaults.indicatorStyle.states.visible.background"],
    "Set the underline color for a workspace visible on another screen.",
    "widgets.md#workspace-appearance", indicatorIs("underline")),
  ...[
    ["background", "Background"], ["borderColor", "Border"], ["shadowColor", "Shadow"],
  ].map(([key, label]) => control(`popups.${key}`, label, "color", [`popupDefaults.${key}`],
    "Set this popup color for the appearance shown.", "styling.md#widget-styles")),
  control("popups.cornerRadius", "Popup corners", "number", ["popupDefaults.cornerRadius"],
    "Round popup corners in points.", "styling.md#widget-styles"),
  ...[
    ["paddingHorizontal", "Horizontal padding"], ["paddingVertical", "Vertical padding"], ["spacing", "Spacing"],
  ].map(([key, label]) => control(`popups.${key}`, label, "number", [`popupDefaults.${key}`],
    "Tooltips, hover controls and More stay compact; app menus and a popup's own padding take precedence.",
    "popups.md", popupSpacing)),
  control("popups.gap", "Gap below bar", "number", ["bar.popupOffset"],
    "Set the gap below the bar; tooltips, hover controls, More and app menus keep their own spacing.",
    "popups.md", popupSpacing),
];

export function controlsFor(state, flags = {}) {
  const resolvedState = { ...state, config: resolveTheme(builtIn, state.config, "light") };
  return CONTROLS.filter(control => !control.appliesWhen || control.appliesWhen(resolvedState, flags));
}

function writePath(object, path, value) {
  const keys = path.split(".");
  const last = keys.pop();
  let target = object;
  for (const key of keys) {
    if (typeof target[key] === "string" && target[key].startsWith("@token.")) {
      target[key] = substituteTokens(target[key], object.tokens ?? {});
    }
    if (!isObject(target[key])) target[key] = {};
    target = target[key];
  }
  target[last] = structuredClone(value);
}

function colorValue(value) {
  if (isGradient(value)) return colorValue(value.gradient.colors[0]);
  return value ?? "#00000000";
}

function editedColor(config, path, value, appearance) {
  const other = appearance === "light" ? "dark" : "light";
  const resolved = resolveTheme(builtIn, config, other);
  const old = path.split(".").reduce((object, key) => object?.[key], resolved);
  return appearance === "light"
    ? { light: value, dark: colorValue(old) }
    : { light: colorValue(old), dark: value };
}

export function applyControl(state, id, value, appearance) {
  const control = CONTROLS.find(control => control.id === id);
  if (!control) throw new Error(`Unknown theme control: ${id}.`);
  const next = structuredClone(state);
  if (control.group === "about") {
    const key = id.slice("about.".length);
    if ((key === "author" || key === "description") && !value) delete next.manifest[key];
    else next.manifest[key] = value;
    if (key === "name") next.manifest.id = slug(value);
  } else if (id === "widgets.tiles") {
    writePath(next.config, "defaults.background", value ? "@token.surface" : null);
    writePath(next.config, "defaults.borderColor", value ? builtIn.defaults.borderColor : null);
    if (value && next.config.defaults.shadowColor === null) {
      next.config.defaults.shadowColor = structuredClone(builtIn.defaults.shadowColor);
    }
  } else if (id === "bar.background") {
    if (value === "none") {
      if (isObject(next.config.bar?.style)) delete next.config.bar.style.background;
    } else if (isGradient(value)) {
      // The page keeps the original base gradient and passes it back for the base-gradient choice.
      writePath(next.config, control.paths[0], value);
    } else if (value === "color") {
      writePath(next.config, control.paths[0], "@token.surface");
    } else {
      writePath(next.config, control.paths[0], editedColor(state.config, control.paths[0], value, appearance));
    }
  } else {
    const path = control.paths[0];
    writePath(next.config, path, control.kind === "color" ? editedColor(state.config, path, value, appearance) : value);
  }
  return next;
}
