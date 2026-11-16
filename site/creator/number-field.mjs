export function parseNumber(text) {
  const trimmed = text.trim();
  if (!trimmed) return null;
  const value = Number(trimmed.replace(",", "."));
  return Number.isFinite(value) ? value : null;
}

export function formatNumber(value) {
  return String(Number(value.toFixed(2)));
}

export function clampNumber(value, { range: [min, max] }) {
  return Math.min(Math.max(value, min), max);
}

export function scrubValue(origin, deltaX, options, shift = false) {
  return clampNumber(origin + Math.round(deltaX / 3) * options.step * (shift ? 10 : 1), options);
}

export function nudgeValue(value, direction, options, shift = false) {
  return clampNumber(value + direction * options.step * (shift ? 10 : 1), options);
}
