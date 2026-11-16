export function hsvFromHex(hex) {
  const [r, g, b, a = 255] = hex.slice(1).match(/../g).map(pair => parseInt(pair, 16));
  const max = Math.max(r, g, b), range = max - Math.min(r, g, b);
  let h = 0;
  if (range && max === r) h = ((g - b) / range + 6) % 6;
  else if (range && max === g) h = (b - r) / range + 2;
  else if (range) h = (r - g) / range + 4;
  return { h: h * 60, s: max ? range / max : 0, v: max / 255, a };
}

export function hexFromHSV({ h, s, v, a }) {
  const channel = n => {
    const k = (n + h / 60) % 6;
    return Math.round(255 * (v - v * s * Math.max(0, Math.min(k, 4 - k, 1))));
  };
  const channels = [channel(5), channel(3), channel(1)];
  if (a !== 255) channels.push(a);
  return "#" + channels.map(value => value.toString(16).padStart(2, "0")).join("");
}

export function addRecentColor(colors, color) {
  const recent = color.toLowerCase();
  return [recent, ...colors.filter(other => other !== recent)].slice(0, 8);
}
