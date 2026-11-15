// Token paths are honored wherever the config references them; unused palette colors stay unused.
export const CONTRACT = [
  "tokens.surface", "tokens.surfaceRaised", "tokens.text", "tokens.textMuted", "tokens.accent",
  "tokens.track", "tokens.hairline", "tokens.warning", "tokens.critical",
  "defaults.foreground", "defaults.accent", "defaults.accentText", "defaults.offsetY",
  "defaults.background", "defaults.borderColor", "defaults.shadowColor", "defaults.shadowRadius",
  "defaults.fontName", "defaults.fontSize", "defaults.fontWeight", "defaults.cornerRadius",
  "defaults.paddingHorizontal", "defaults.paddingVertical", "defaults.hoverBackground",
  "defaults.borderWidth", "defaults.iconSize", "defaults.spacing",
  "bar.height", "bar.margin", "bar.style.background", "bar.style.cornerRadius",
  "bar.style.borderColor", "bar.style.borderWidth", "bar.style.borderEdges",
  "bar.inset", "bar.spacing",
  "workspaceDefaults.indicator", "workspaceDefaults.style.foreground",
  "workspaceDefaults.style.states.focused.foreground", "workspaceDefaults.style.states.focused.background",
  "workspaceDefaults.style.cornerRadius", "workspaceDefaults.indicatorStyle.width",
  "workspaceDefaults.indicatorStyle.height", "workspaceDefaults.indicatorStyle.cornerRadius",
  "workspaceDefaults.indicatorStyle.offsetY", "workspaceDefaults.indicatorStyle.background",
  "workspaceDefaults.indicatorStyle.states.visible.background",
  "popupDefaults.background", "popupDefaults.borderColor", "popupDefaults.shadowColor", "popupDefaults.cornerRadius",
  "popupDefaults.paddingHorizontal", "popupDefaults.paddingVertical", "popupDefaults.spacing", "bar.popupOffset",
  "popupDefaults.shadowRadius", "popupDefaults.fontName", "popupDefaults.fontSize", "popupDefaults.fontWeight",
  "popupDefaults.foreground", "popupDefaults.borderWidth",
];

const px = value => `${value}px`;
const color = value => typeof value === "string" ? value : "transparent";
const nonnegative = value => Math.max(0, value);
const weights = { ultralight: 100, thin: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700 };
const systemFont = '-apple-system, BlinkMacSystemFont, system-ui, sans-serif';

function font(style) {
  const family = style.fontName === "system" ? systemFont : `${JSON.stringify(style.fontName)}, ${systemFont}`;
  return `${weights[style.fontWeight] ?? 400} ${px(style.fontSize)}/${px(Math.ceil(style.fontSize * 1.2))} ${family}`;
}

function background(value) {
  if (!canDrawBackground(value)) return "transparent";
  if (!value?.gradient) return color(value);
  const { colors, locations, angle = 90 } = value.gradient;
  const stops = colors.map((value, index) => `${color(value)}${locations ? ` ${locations[index] * 100}%` : ""}`);
  return `linear-gradient(${angle}deg, ${stops.join(", ")})`;
}

// SwiftUI's oblique gradients use unit-square points, which CSS angles don't reproduce on a strip.
const canDrawBackground = value => !value?.gradient || (value.gradient.angle ?? 90) % 90 === 0;

function hasPaint(value) {
  if (!canDrawBackground(value)) return false;
  if (value?.gradient) return value.gradient.colors.some(hasPaint);
  return typeof value === "string" && value !== "transparent" && !/^#[\da-f]{6}00$/i.test(value);
}

// CSS box shadows take twice the blur standard deviation used by drop-shadow.
export const shadowBlur = radius => nonnegative(radius) * 2;
const shadow = (radius, tint) => `0 1px ${px(shadowBlur(radius))} ${color(tint)}`;

export function cssVariables(resolved, { popupSpacing = false } = {}) {
  const { defaults: widget, popupDefaults: popup, tokens = {}, bar, workspaceDefaults: workspace } = resolved;
  const strip = bar.style ?? {};
  const focused = workspace.style.states.focused;
  const underline = workspace.indicatorStyle;
  const shadowRadius = shadowBlur(widget.shadowRadius);
  const tiled = hasPaint(widget.background) || (widget.borderWidth > 0 && hasPaint(widget.borderColor));
  const borderWidth = nonnegative(strip.borderWidth ?? 0);
  const batteryHeight = Math.round(nonnegative(widget.iconSize) * 0.8);
  return {
    "--bar-h": px(nonnegative(bar.height ?? 40)),
    "--strip-bg": background(strip.background),
    "--strip-edge": strip.borderEdges === "all"
      ? `inset 0 0 0 ${px(borderWidth)} ${color(strip.borderColor)}`
      : `inset 0 ${px(-borderWidth)} 0 0 ${color(strip.borderColor)}`,
    "--strip-radius": px(nonnegative(strip.cornerRadius ?? 0)),
    "--strip-m": px(nonnegative(bar.margin ?? 0)),
    "--bar-inset": px(bar.inset ?? 12),
    "--bar-gap": px(bar.spacing ?? 8),
    "--w-bg": background(widget.background),
    "--w-border": color(widget.borderColor),
    "--w-border-w": px(nonnegative(widget.borderWidth)),
    "--w-radius": px(nonnegative(widget.cornerRadius)),
    "--w-px": px(widget.paddingHorizontal),
    "--w-py": px(widget.paddingVertical),
    "--w-hover": background(widget.hoverBackground),
    "--w-gap": px(widget.spacing),
    "--battery-h": px(batteryHeight),
    "--battery-w": px(Math.round(batteryHeight * 2.1) + 0.5 + Math.max(1.5, batteryHeight * 0.15)),
    "--w-shadow-box": tiled ? shadow(widget.shadowRadius, widget.shadowColor) : "none",
    "--w-glow": !tiled && widget.shadowColor != null
      ? `drop-shadow(0 1px ${px(shadowRadius / 2)} ${color(widget.shadowColor)})` : "none",
    "--w-dy": px(widget.offsetY ?? 0),
    "--tile-h": px(Math.ceil(widget.fontSize * 1.2) + 2 * widget.paddingVertical),
    "--fg": color(widget.foreground),
    "--muted": color(tokens.textMuted),
    "--accent": color(widget.accent),
    "--accent-text": color(widget.accentText),
    "--raised": color(tokens.surfaceRaised),
    "--track": color(tokens.track),
    "--ws-off": color(workspace.style.foreground),
    "--ws-on": color(focused.foreground),
    "--ws-ind": background(workspace.indicator === "underline" ? underline.background : focused.background),
    "--ws-r": px(nonnegative(workspace.style.cornerRadius)),
    "--ul-w": underline.width == null ? "100%" : px(nonnegative(underline.width)),
    "--ul-h": px(nonnegative(underline.height)),
    "--ul-r": px(nonnegative(underline.cornerRadius)),
    "--ul-dy": px(underline.offsetY ?? 0),
    "--ul-visible": background(underline.states.visible.background),
    "--pop-bg": background(popup.background),
    "--pop-fg": color(popup.foreground),
    "--pop-border": color(popup.borderColor),
    "--pop-border-w": px(nonnegative(popup.borderWidth)),
    "--pop-radius": px(nonnegative(popup.cornerRadius)),
    "--pop-shadow": shadow(popup.shadowRadius, popup.shadowColor),
    "--pop-px": px(popupSpacing ? popup.paddingHorizontal : 10),
    "--pop-py": px(popupSpacing ? popup.paddingVertical : 6),
    "--pop-gap": px(popupSpacing ? popup.spacing : 6),
    "--pop-offset": px(popupSpacing ? bar.popupOffset ?? 4 : 4),
    "--bar-font": font(widget),
    "--pop-font": font(popup),
  };
}

export function indicatorClass(resolved) {
  return { background: "ws-fill", underline: "ws-under", none: "ws-text" }[resolved.workspaceDefaults.indicator] ?? "ws-fill";
}

export function keptFromBase(config) {
  const kept = [];
  function visit(value, path) {
    if (CONTRACT.includes(path)) {
      if (!canDrawBackground(value)) kept.push(path);
      return;
    }
    if (path && !CONTRACT.some(key => key.startsWith(path + "."))) {
      kept.push(path);
    } else if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [key, child] of Object.entries(value)) visit(child, path ? `${path}.${key}` : key);
    } else if (path) {
      kept.push(path);
    }
  }
  visit(config, "");
  return kept;
}
