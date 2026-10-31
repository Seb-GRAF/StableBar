/* Lighthouse Hill, in absurd ink: the scene behind stablebar.app.
   A one-eyed lighthouse in a pom-pom hat on a hill above the sea, drawn in Canvas 2D by one
   felt-pen hand: tapered ink ribbons that boil a little, and flat colours printed slightly off
   the line. main.js creates one scene and forwards input to it (the API is at the end). */
(() => {
'use strict';

/* ---------- small maths ---------- */
const TAU = Math.PI * 2;
const clamp = (v, a = 0, b = 1) => (v < a ? a : v > b ? b : v);
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); };
const easeOut = t => t * (2 - t);
const hash = n => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
const noise = x => { const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return lerp(hash(i), hash(i + 1), u) * 2 - 1; };
const rng = seed => { let a = (seed >>> 0) || 1; return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; };
const hex = h => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
const mix = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
const mul = (a, b) => [a[0] * b[0] / 255, a[1] * b[1] / 255, a[2] * b[2] / 255];
const rgba = (c, a = 1) => { if (TINT) c = TINT(c); return `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`; };
const angDiff = (a, b) => { let d = (a - b) % TAU; if (d > Math.PI) d -= TAU; if (d < -Math.PI) d += TAU; return d; };
// the light's turn that faces you (its rotation at a quarter turn), nearest to where it is
const facing = phi => Math.PI / 2 + TAU * Math.round((phi - Math.PI / 2) / TAU);
const stops = list => list.map(([d, p]) => [d, Object.fromEntries(Object.entries(p).map(([k, v]) => [k, hex(v)]))]);
function palAt(list, d) {
  let i = 0;
  while (i < list.length - 2 && d > list[i + 1][0]) i++;
  const [d0, p0] = list[i], [d1, p1] = list[i + 1], t = clamp((d - d0) / (d1 - d0));
  const out = {};
  for (const k in p0) out[k] = mix(p0[k], p1[k], t);
  return out;
}
/* Catmull-Rom through control points, then evenly spaced points every `step` px */
function curve(ctrl, step, closed = false) {
  const p = closed ? [ctrl[ctrl.length - 1], ...ctrl, ctrl[0], ctrl[1]] : [ctrl[0], ...ctrl, ctrl[ctrl.length - 1]];
  const raw = [];
  for (let i = 1; i < p.length - 2; i++) {
    const p0 = p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = p[i + 2];
    for (let s = 0; s < 8; s++) {
      const t = s / 8, t2 = t * t, t3 = t2 * t;
      const f = k => 0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3);
      raw.push([f(0), f(1)]);
    }
  }
  if (!closed) raw.push(ctrl[ctrl.length - 1].slice());
  return dens(raw, step, closed);
}
/* Points every `step` px along a polyline */
function dens(pts, step, closed = false) {
  const out = [], src = closed ? [...pts, pts[0]] : pts;
  for (let i = 0; i < src.length - 1; i++) {
    const [x0, y0] = src[i], [x1, y1] = src[i + 1];
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / step));
    for (let k = 0; k < n; k++) out.push([lerp(x0, x1, k / n), lerp(y0, y1, k / n)]);
  }
  if (!closed) out.push(src[src.length - 1].slice());
  return out;
}
const ellipse = (cx, cy, rx, ry, n = 32, a0 = 0, a1 = TAU, rot = 0) => {
  const out = [], c = Math.cos(rot), s = Math.sin(rot);
  for (let i = 0; i < n; i++) {
    const a = lerp(a0, a1, i / (a1 - a0 >= TAU - 1e-6 ? n : n - 1)), x = Math.cos(a) * rx, y = Math.sin(a) * ry;
    out.push([cx + x * c - y * s, cy + x * s + y * c]);
  }
  return out;
};
function poly(c, pts, close = true, dx = 0, dy = 0) {
  c.beginPath();
  for (let i = 0; i < pts.length; i++) i ? c.lineTo(pts[i][0] + dx, pts[i][1] + dy) : c.moveTo(pts[i][0] + dx, pts[i][1] + dy);
  if (close) c.closePath();
}
function inPoly(pts, x, y) {
  let ins = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / ((yj - yi) || 1e-9) + xi) ins = !ins;
  }
  return ins;
}
/* A cumulus: the upper envelope of a few bumps over a flat base */
function cloudPts(cx, cy, w, seed) {
  const R = rng(seed), n = 4 + ((R() * 2) | 0), bumps = [];
  for (let i = 0; i < n; i++) {
    const fx = (i + 0.5) / n;
    bumps.push([cx - w / 2 + fx * w + (R() - 0.5) * w * 0.06, w * (0.14 + R() * 0.1) * (1.3 - Math.abs(fx - 0.5))]);
  }
  const x0 = cx - w / 2 - w * 0.05, x1 = cx + w / 2 + w * 0.05, top = [];
  for (let i = 0; i <= 64; i++) {
    const x = lerp(x0, x1, i / 64);
    let y = cy;
    for (const [bx, r] of bumps) { const dx = x - bx; if (Math.abs(dx) < r) y = Math.min(y, cy - Math.sqrt(r * r - dx * dx) * 0.92); }
    top.push([x, y]);
  }
  return top.filter((p, i) => p[1] < cy - 0.3 || i === 0 || i === top.length - 1);
}

/* ---------- colours ---------- */
/* Five hours of the day. The felt pen stays black; only the printed colours move. */
const PAL = stops([
  [0,    { sky: '#86CBF2', sky2: '#B8E2F8', sea: '#2E58D8', sea2: '#8DB0FF', foam: '#FFFFFF', hill: '#83CF5F', hill2: '#66B24C', ink: '#111111', paper: '#FFFFFF', beam: '#FFE04A', cloud: '#FFFFFF', far: '#A2C9EC', glass: '#B8E2F8' }],
  [0.2,  { sky: '#A6B6F4', sky2: '#E6C4EE', sea: '#2E50CC', sea2: '#93AAFF', foam: '#FFFFFF', hill: '#7CC95E', hill2: '#5FA84B', ink: '#111111', paper: '#FFFBF4', beam: '#FFE04A', cloud: '#FFFFFF', far: '#B9B4E6', glass: '#E6C4EE' }],
  [0.44, { sky: '#FF8F73', sky2: '#FFC07F', sea: '#3043B8', sea2: '#9EA3FF', foam: '#FFF1E6', hill: '#6DB65A', hill2: '#539A4A', ink: '#111111', paper: '#FFF7EC', beam: '#FFE04A', cloud: '#FFE1CF', far: '#D88BA0', glass: '#FFC07F' }],
  [0.7,  { sky: '#6A4CC4', sky2: '#B0609C', sea: '#22287A', sea2: '#6E77D8', foam: '#D9CCFF', hill: '#3E7D56', hill2: '#2F6447', ink: '#111111', paper: '#F0E6FF', beam: '#FFE24E', cloud: '#C3B2EE', far: '#5E4B9A', glass: '#FFD86A' }],
  [1,    { sky: '#232662', sky2: '#30357E', sea: '#14184A', sea2: '#4A54B4', foam: '#9EA6E8', hill: '#244F3E', hill2: '#1B3F31', ink: '#0B0B14', paper: '#E8E2FF', beam: '#FFE65C', cloud: '#565C9E', far: '#2E3270', glass: '#FFE65C' }],
]);
const STEPS = 48; // palette steps that the cached layers are keyed on

/* The lighthouse's pyjamas, one per StableBar theme: stripes and hat */
const THEMES = {
  'built-in': { stripes: ['#FF4A36'], hat: '#FF4A36' },
  catppuccin: { stripes: ['#CBA6F7'], hat: '#CBA6F7' },
  gruvbox: { stripes: ['#FABD2F', '#FE8019', '#FB4934'], hat: '#FE8019' },
  leman: { stripes: ['#5CC5B8'], hat: '#5CC5B8' },
  nord: { stripes: ['#88C0D0'], hat: '#88C0D0' },
  notch: { stripes: ['#111111'], hat: '#111111' },
  phosphor: { stripes: ['#FFB000'], hat: '#FFB000' },
};
const STATES = ['hero', 'edit', 'themes', 'widgets', 'tiling', 'install'];
const KINDS = ['sheep', 'cow', 'duck', 'monster', 'gull'];
let C = {
  wool: hex('#FFFFFF'), yolk: hex('#FFC21A'), duck: hex('#FFD21F'), beak: hex('#FF7A1A'), pink: hex('#FF9CB0'),
  monster: hex('#FF8FC0'), chimney: hex('#E8452F'), roof: hex('#2B2B36'), door: hex('#2E58D8'), skin: hex('#F6C9A6'),
  navy: hex('#25305E'), wood: hex('#C98B4A'), steel: hex('#D8DCE6'), moon: hex('#FFE89A'), tile: hex('#1D1D24'), iris: hex('#FFB52E'), lamp: hex('#FFD45C'),
  huts: ['#FF4A36', '#2E58D8', '#FFC21A', '#36A852'].map(hex),
  kraft: hex('#CC9A5E'), kraftLit: hex('#E2B983'), kraftDark: hex('#A87442'), tape: hex('#FFE04A'), sprout: hex('#2E9B3B'),
};
// animals that live on the hill (not riding a cloud): they wander and graze
const grazer = o => (o.kind === 'sheep' || o.kind === 'cow') && !o.ride;
/* The sheep's box, in its own units (times boxK): the front face's half size, the depth seen past it, and
   three air holes punched in the front, the first two with eyes behind them */
const BOX = { hw: 21, hh: 13, dx: 9, dy: -7, holes: [[-11, -1.5], [0.5, -3.5], [11.5, -0.5]] };
// a rect [x0, y0, x1, y1] against a rect, or a disc [x, y, r]
const overlaps = (a, q) => q.length === 3
  ? Math.hypot(clamp(q[0], a[0], a[2]) - q[0], clamp(q[1], a[1], a[3]) - q[1]) < q[2]
  : a[0] < q[2] && a[2] > q[0] && a[1] < q[3] && a[3] > q[1];
const boxK = s => Math.max(s.g.u, 0.72) * 1.12;
let HAND = '"Shantell Sans Hand", "Shantell Sans", "Chalkboard SE", sans-serif', WEIGHT = 400, CAPS = false;

/* ---------- the pen ----------
   One felt pen in three weights. Every stroke is a filled ribbon whose width follows the pen's
   pressure: thin where it lands and lifts, a little uneven along the way. The line boils between
   three states; the printed fills don't boil and sit one constant vector off the line. These are the felt pen's;
   the pen, the fills, the colours and the font in use are the style's being drawn (see STYLES). */
let BOIL = 0, PW = 1, INK = '#111', REGX = 2.6, REGY = 1.9, NAP = false, TINT = null, ribbon = feltRibbon, print = feltPrint;
const SIL = 3.2, DET = 2.1, TEX = 1.35;

function feltRibbon(c, pts, w, sd = 0, o = {}) {
  const n = pts.length;
  if (n < 2) return;
  const len = new Float64Array(n);
  for (let i = 1; i < n; i++) len[i] = len[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
  const total = len[n - 1] || 1, bo = BOIL * 7.13 + sd * 3.71;
  const amp = (o.amp ?? 0.85) * PW, tin = Math.min(total * 0.4, (o.tin ?? 9) * PW), tout = Math.min(total * 0.5, (o.tout ?? 15) * PW);
  const w0 = o.w0 ?? 0.4, w1 = o.w1 ?? 0.22, hw0 = w * PW * 0.5;
  const lx = new Float64Array(n), ly = new Float64Array(n), rx = new Float64Array(n), ry = new Float64Array(n);
  let ex = 0, ey = 0, etx = 0, ety = 0, ehw = 0, sx = 0, sy = 0, stx = 0, sty = 0, shw = 0;
  for (let i = 0; i < n; i++) {
    const a = pts[i > 0 ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : n - 1];
    let tx = b[0] - a[0], ty = b[1] - a[1];
    const tl = Math.hypot(tx, ty) || 1; tx /= tl; ty /= tl;
    const s = len[i], off = amp * (noise(s / 70 + bo) * 0.9 + noise(s / 19 + bo * 1.7 + 5) * 0.28);
    const x = pts[i][0] - ty * off, y = pts[i][1] + tx * off;
    const p = lerp(w0, 1, easeOut(clamp(s / tin))) * lerp(w1, 1, easeOut(clamp((total - s) / tout))) * (1 + 0.15 * noise(s / 43 + bo * 0.6 + 17));
    const hw = hw0 * p;
    lx[i] = x - ty * hw; ly[i] = y + tx * hw; rx[i] = x + ty * hw; ry[i] = y - tx * hw;
    if (i === 0) { sx = x; sy = y; stx = tx; sty = ty; shw = hw; }
    if (i === n - 1) { ex = x; ey = y; etx = tx; ety = ty; ehw = hw; }
  }
  c.moveTo(lx[0], ly[0]);
  for (let i = 1; i < n; i++) c.lineTo(lx[i], ly[i]);
  for (let k = 1; k < 5; k++) { const th = k / 5 * Math.PI, co = Math.cos(th), si = Math.sin(th); c.lineTo(ex + ehw * (-ety * co + etx * si), ey + ehw * (etx * co + ety * si)); }
  for (let i = n - 1; i >= 0; i--) c.lineTo(rx[i], ry[i]);
  for (let k = 1; k < 5; k++) { const th = k / 5 * Math.PI, co = Math.cos(th), si = Math.sin(th); c.lineTo(sx + shw * (sty * co - stx * si), sy + shw * (-stx * co - sty * si)); }
  c.closePath();
}
/* A single stroke in ink */
function ink(c, pts, w, sd, o) { c.beginPath(); ribbon(c, pts, w, sd, o); c.fillStyle = o?.color || INK; c.fill(); }
/* A closed contour drawn in one go, ending a little past where it started */
function loop(c, pts, w, sd = 0, o = {}) {
  const n = pts.length, k = Math.abs(Math.round(sd * 7919)) % n, over = Math.max(2, Math.round(n * (o.over ?? 0.08)));
  let cx = 0, cy = 0;
  for (const p of pts) { cx += p[0]; cy += p[1]; }
  cx /= n; cy /= n;
  const out = [];
  for (let i = 0; i <= n + over; i++) {
    const p = pts[(k + i) % n];
    if (i <= n) out.push(p);
    else { const f = (i - n) / over * 1.6 * PW, dx = p[0] - cx, dy = p[1] - cy, dl = Math.hypot(dx, dy) || 1; out.push([p[0] + dx / dl * f, p[1] + dy / dl * f]); }
  }
  ribbon(c, out, w, sd, { tin: 5, tout: 12, w0: 0.55, w1: 0.12, ...o, outline: true });
}
/* Straight edges, each its own stroke running a little past the corners */
function edges(c, corners, w, sd = 0, closed = true, o = {}) {
  const m = corners.length, ov = (o.ov ?? 2.6) * PW;
  for (let i = 0; i < (closed ? m : m - 1); i++) {
    const [x0, y0] = corners[i], [x1, y1] = corners[(i + 1) % m], l = Math.hypot(x1 - x0, y1 - y0) || 1, ux = (x1 - x0) / l, uy = (y1 - y0) / l;
    const a = hash(sd * 3.1 + i) * ov, b = hash(sd * 5.7 + i + 0.5) * ov;
    ribbon(c, dens([[x0 - ux * a, y0 - uy * a], [x1 + ux * b, y1 + uy * b]], 5), w, sd + i * 1.7, { tin: 4, tout: 6, w0: 0.6, w1: 0.45, ...o, outline: true });
  }
}
/* A printed fill, off the line by the register vector */
function feltPrint(c, pts, col) { poly(c, pts, true, REGX, REGY); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill(); }
function shape(c, pts, col, w = DET, sd = 0, o) { print(c, pts, col); c.beginPath(); loop(c, pts, w, sd, o); c.fillStyle = INK; c.fill(); }
function dot(c, x, y, r, col) { c.beginPath(); c.arc(x, y, r, 0, TAU); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill(); }
function label(c, text, x, y, size, col, align = 'left', rot = -0.035) {
  c.save(); c.translate(x, y); c.rotate(rot);
  c.font = `${WEIGHT} ${size}px ${HAND}`; c.textAlign = align; c.textBaseline = 'middle'; c.fillStyle = col;
  c.fillText(CAPS ? text.toUpperCase() : text, 0, 0); c.restore();
}

/* ---------- the scene: geometry, state, input and time ---------- */
const IDLE_AFTER = 4000, IDLE_FPS = 14, BOIL_FPS = 7, MAX_OBJS = 36;
// a new style comes in as the light turns once round, in this many seconds (see setTheme)
const SWAP = 1.2;
// out at sea, the page's theme follows the islands, each coming in over this many seconds (see update)
const WIPE = 0.9;
// the opening's wake-up, in seconds. At night, from when its eye starts to open: it opens halfway (to `lids.mid` shut)
// by `lids.half`, stays a moment, droops a little (to `lids.heavy`) by `lids.sag`, then opens all the way by `open`,
// easing out. Then it strains to light its lamp, squeezing its eye shut for each of `pushes` ([when, how long, how
// hard]), and from `dim` its light finds the card's bar, weak and unsteady (nearly out in each of `dips`), and crosses
// it (`scan`: [when, how long]; both counted from `dim`). When the day comes (from the page's rising): it blinks its
// light out over `out`, strains again (`again`), and its light comes on for good at `on`, on the headline's first
// word; it reads the headline from `read` for `dur`, and at `end` it sweeps the bar
const WAKE = {
  open: 1.45, lids: { half: 0.5, hold: 0.6, sag: 0.85, mid: 0.62, heavy: 0.84 },
  pushes: [[1.55, 0.26, 0.75], [1.93, 0.32, 0.9]], dim: 2.29, scan: [0.25, 0.9],
  dips: [[0.22, 0.27], [0.52, 0.58], [0.63, 0.67], [0.88, 0.93], [1.14, 1.19]],
  out: 0.14, again: [[0.24, 0.28, 0.85], [0.62, 0.36, 1]], on: 0.98, read: 1.22, dur: 1.1, end: 2.45,
};
// a visit at the cottage's door, in seconds from the third knock in a row: it opens over `open`, the keeper is in the doorway from
// `keeper`[0] to [1], looking out to the left and from `right` to the right; he wonders (`huh`), turns his back at `turn`
// and walks back in; it shuts over `shut`, and it's over at `end` (`away`, when he's out on the ridge and nobody comes)
const VISIT = { open: [0.55, 0.8], keeper: [0.7, 2.95], right: 1.6, huh: 2.2, turn: 2.4, shut: [2.97, 3.22], end: 3.3, away: 1.6 };
// the grass on the hill: at most this many tufts (fewer on phones), a new one every 3 to 6 s while there are fewer
const MEADOW_MAX = 14, MEADOW_PHONE = 8, SPROUT_MIN = 3, SPROUT_MAX = 6;
/* The dive past the end of the page: you go straight on toward the middle of the horizon, past islands that stand
   one after another, DIVE_GAP times the nearest one's distance apart, off to one side and then the other. They come
   round in this order (the first one is the page's far island); each is a ridge and a shore, as fractions of the width
   and, up from the horizon, of the sky or, down from it, of the sea. `lx` is the lighthouse, `cx` the cottage. Each
   wears one of the other themes: its lighthouse's pyjamas, and its ground by day (lit and shady), darker with the hour
   like the page's green. */
// (an island seen at its own size stands this far down the sea, as a part of it: it's as far off as the sea there)
const DIVE_GAP = 7, SHORE = 0.27;
const ISLANDS = [
  // on the right, a snowy peak: the lighthouse on its shoulder, the cottage on a ledge above it
  { theme: 'nord', ground: ['#E8EDF4', '#BFCBDB'],
    ridge: [[0.52, 0.12], [0.56, 0.02], [0.6, -0.08], [0.65, -0.1], [0.69, -0.13], [0.74, -0.24], [0.79, -0.38], [0.82, -0.42], [0.85, -0.37], [0.9, -0.24], [0.95, -0.1], [0.99, 0.12]],
    shore: [[0.52, 0.12], [0.6, 0.21], [0.72, 0.26], [0.86, 0.27], [0.95, 0.22], [0.99, 0.12]], lx: 0.63, cx: 0.71 },
  // on the left, a table mountain: steep all round, flat on top
  { theme: 'gruvbox', ground: ['#B8BB26', '#98971A'],
    ridge: [[0.02, 0.12], [0.04, 0], [0.06, -0.12], [0.08, -0.17], [0.13, -0.18], [0.2, -0.18], [0.27, -0.17], [0.33, -0.16], [0.36, -0.11], [0.38, -0.02], [0.4, 0.12]],
    shore: [[0.02, 0.12], [0.08, 0.22], [0.2, 0.26], [0.32, 0.23], [0.4, 0.12]], lx: 0.3, cx: 0.17 },
  // on the right, two round hills: the cottage in the dip between them, the lighthouse on the far one
  { theme: 'catppuccin', ground: ['#F5C2E7', '#DDA3CF'],
    ridge: [[0.53, 0.12], [0.56, 0], [0.6, -0.1], [0.64, -0.15], [0.68, -0.13], [0.72, -0.07], [0.76, -0.06], [0.8, -0.11], [0.85, -0.19], [0.9, -0.2], [0.95, -0.12], [0.99, 0.12]],
    shore: [[0.53, 0.12], [0.6, 0.22], [0.72, 0.26], [0.85, 0.27], [0.95, 0.22], [0.99, 0.12]], lx: 0.88, cx: 0.74 },
  // on the left, a long slope up from a beach to a cliff over the middle, the lighthouse on its edge
  { theme: 'leman', ground: ['#7CCDB4', '#5AB198'],
    ridge: [[0, 0.12], [0.04, 0.06], [0.1, 0], [0.17, -0.05], [0.24, -0.1], [0.3, -0.15], [0.35, -0.19], [0.38, -0.2], [0.4, -0.14], [0.41, -0.02], [0.42, 0.12]],
    shore: [[0, 0.12], [0.08, 0.2], [0.2, 0.24], [0.33, 0.24], [0.42, 0.12]], lx: 0.355, cx: 0.18 },
  // on the right, a small dark crag: the lighthouse on top, the cottage at its foot
  { theme: 'notch', ground: ['#4A4B55', '#36373F'],
    ridge: [[0.6, 0.12], [0.62, 0.04], [0.66, 0], [0.7, -0.02], [0.73, -0.12], [0.75, -0.26], [0.78, -0.32], [0.82, -0.31], [0.85, -0.22], [0.88, -0.08], [0.91, 0.12]],
    shore: [[0.6, 0.12], [0.66, 0.2], [0.76, 0.24], [0.86, 0.22], [0.91, 0.12]], lx: 0.8, cx: 0.67 },
  // on the left, wide and low, sand dunes
  { theme: 'phosphor', ground: ['#F2C46A', '#D9A548'],
    ridge: [[0, 0.12], [0.03, 0.02], [0.08, -0.05], [0.13, -0.07], [0.18, -0.04], [0.23, -0.06], [0.28, -0.11], [0.33, -0.12], [0.38, -0.08], [0.43, -0.02], [0.46, 0.04], [0.48, 0.12]],
    shore: [[0, 0.12], [0.07, 0.22], [0.2, 0.27], [0.36, 0.25], [0.45, 0.19], [0.48, 0.12]], lx: 0.31, cx: 0.13 },
];
/* What each island has of its own: its light, its animals, grass and box, its games with the bar (the page's
   only). One island's state at a time lives on the scene (see enter); the others wait in their world objects. */
const islandState = () => ({
  beam: { a: Math.PI * 0.96, len: 1, flash: 0, phi: Math.PI * 0.96, steer: 0, sa: Math.PI * 0.96 },
  wakePath: null, gaze: null, restAt: -99,
  ripples: [], objs: [],
  // the ball game and the bored trick (see "the lighthouse plays with the bar")
  bar: [], ball: null, bore: null, look: null, sweep: null,
  doodles: [], splashes: [],
  hatKick: -9, regrowAt: -9,
  // someone at the cottage's door (see knock)
  visit: null, knocks: { n: 0, at: -9 },
  // a lived-in hill: the animals already there, the grass they eat, and a sheep in a box up in the sky
  flocked: false, meadow: [], sproutAt: 0,
  box: { v: null, gx: null, gy: null, side: null, lastSide: null, la: 0, seenAt: -9, hop: -9, wob: -9, nextWob: 0, peek: -9, lit: 0, open: false, openAt: -9, blinkAt: -9, nextBlink: 0, knocks: 0, knockAt: -9, hopK: 1, out: null, burst: 0, lid: 0, sheep: null },
});
const ISLAND = ['g', ...Object.keys(islandState())];
// the islands are drawn between these sizes: from far off, where they come out of the haze (by then the next island is
// all there is to see, the one after it comes as you go), to going past, off the screen
const FAR = 0.07, PAST = 30;
// the far island seen from the page is in the page's style; it changes into its own theme's over this much of the
// dive's first lap (see drawScene)
const OWN = 0.1;
// the lighthouse standing on `base` at x, h tall to its gallery, the eye in its lamp er across: its lamp and hat
function tower(g, x, base, h, er) {
  const T = g.lh = { x, base, h, er, gal: er * 0.62, top: base - h, wT: er * 1.62, wB: er * 2.6 };
  g.lamp = { x, y: T.top - T.gal - er * 1.02 };
  T.hatTop = g.lamp.y - er * 3.6;
}

/* ---------- styles ----------
   Each theme draws the whole scene in its own medium: the same hill, animals, gags and hours, another hand. The felt
   pen is the built-in theme's. Each of the others has a file in styles/ that registers its style, after this file and
   before the page makes the scene:

     Hill.style('nord', { pal, C, tint, ribbon, pen, boil, print, reg, hand, weight, caps, fps, before, after, cached, draw });

   Every lever is optional; what a style leaves out is the felt pen's (Hill.felt).
     pal     the hours: stops like PAL's, made with Hill.stops, with the same keys. `ink` is the line's colour. The
             islands' ground darkens with the hour as `hill` and `hill2` do from the first stop, so neither may
             have a channel at 0 there.
     C       the colour constants it changes, made with Hill.hex; the others stay.
     tint    a colour [r, g, b] in, a colour out, wherever a colour is written out (rgba): every fill and stroke,
             cached ones too, but not the few glints written as '#FFFFFF'. For greys, or all in one colour.
     ribbon  the line: (c, pts, w, sd, o) adds a stroke along the points, w wide (times PW), to the path, and the
             caller fills it, mostly in INK. ink, loop, edges, shape and most drawings go through it. sd seeds its
             wobble; o holds the felt pen's taper and wobble (tin, tout, w0, w1, amp), which another line may
             ignore, and says what the stroke is: o.outline goes round a shape the caller fills (loop's and edges',
             so shape's too, and a few drawn on their own), o.hatch is shading. An empty one draws no lines at all.
     pen     the line's weight, times the felt pen's (1).
     boil    how many times a second the line moves on, between three states (7); 0 holds it still. The cached
             layers are drawn once for each state.
     print   the fill: (c, pts, col) fills the polygon REGX, REGY off the line, col a colour or a CSS string.
     reg     that offset, [x, y] in pen units ([2.6, 1.9]); [0, 0] prints the fills on the line.
     hand    the font of the labels and doodles, a CSS font family list. For a web font, add its FontFace to
             document.fonts: the first text drawn in it fetches it, and when it's in, the scene draws again and
             redraws its cached layers (they're keyed on fontsV).
     weight  the labels' and doodles' font weight (400).
     caps    true sets the labels and doodles in capitals, and measures them so where they're placed.
     fps     draws at this many frames a second: the drawing's time (s.t) is stepped, the world's isn't (s.clock),
             so things still go where they go between the steps.
     before  (s, c) at the start of each frame, after the levers are on; after (s, c) at its end, over everything
             (grain, scanlines, fibre). Both in the scene's CSS pixels.
     cached  (s, c) once a cached layer or sprite is drawn, on its own canvas, before it's kept: what it adds there
             costs nothing per frame (a glow).
     draw    { name(base, ...args) }: any of the drawings named in Hill.felt.draw, in place of the felt pen's, which comes
             as base to call or not. The drawings call each other through DRAW, so an override is used wherever
             its drawing is, by the felt ones too.
   A drawing gets the scene s and the canvas c (the animals get c, u, their colour, o and t, and obj gets s): s.g the
   geometry (W, H, u, pw, top, horizon, ridge, shore, hillPoly, hillClip, lh the tower, lamp, cot the cottage,
   clouds, sheepCloud, stars, tufts), s.P the palette now, s.t the time, s.d the hour (0 day, 1 night), s.style the
   style on, s.theme the visitor's theme, s.beam, s.pres how far in each section's scene is, s.reduced. Lengths are CSS
   pixels of the scene; sizes go in u (g.u, 1 on a window of about 1138 by 1138) and pens in pw. The islands of the
   dive use the same drawings in their own s.g, on a canvas scaled by view, each in its own theme's style (but the
   far one seen from the page, in the visitor's), while the sky, the sea and the clouds are in the page's: the
   visitor's, and out at sea the theme of the island you're heading to (s.shows). That one comes in as a circle
   opening out from the middle of the horizon (s.wipe): meanwhile the sky, the sea, the clouds, before and after are
   drawn in both styles, the old one's outside the circle and the new one's inside it. The band behind the horizon
   (one for each theme the page is in) and the hill with its cottage and tower are cached layers, the sun, the moon
   and the clouds sprites: those drawings run only when the hour's step, the boil state, the style, the size or the
   fonts change, so they can't move on their own. Drawings leave the scene as they found it, save the cottage, which
   puts its door in g.cot.door for the visit and the doorway: one drawn without base must too. Every style keeps the
   lighthouse's pyjamas: THEMES[g.theme || s.theme]. */
const FELT = {
  id: 'built-in', pal: PAL, C, ribbon: feltRibbon, print: feltPrint, pen: 1, boil: BOIL_FPS, reg: [2.6, 1.9], hand: HAND, weight: 400, caps: false,
  draw: {
    scene: drawScene, sky: drawSky, band: drawBand, stars: drawStars, waves: drawWaves, ripples: drawRipples, sun: drawSun,
    moon: drawMoon, halo: drawHalo, beam: drawBeam, cloud: drawCloud, land: drawLand, front: drawFront, hill: drawHill,
    cottage: drawCottage, tower: drawTower, hillLight: drawHillLight, tufts: drawTufts, visit: drawVisit, smoke: drawSmoke,
    eye: drawEye, hat: drawHat, box: drawBox, leap: drawLeap, meadow: drawMeadow, obj: drawObj, sheep: drawSheep,
    cow: drawCow, gull: drawGull, duck: drawDuck, monster: drawMonster, states: drawStates, washing: drawWashing,
    huts: drawHuts, desk: drawDesk, doorway: drawDoorway, editKeeper: drawEditKeeper, keeper: drawKeeper, tile: drawTile,
    labels: drawLabels, splashes: drawSplashes, ball: drawBall, doodles: drawDoodles,
  },
};
const STYLES = { 'built-in': FELT };
let DRAW = FELT.draw;
function style(id, st) {
  const own = st.draw || {};
  STYLES[id] = { ...FELT, ...st, id, C: { ...FELT.C, ...st.C }, draw: Object.fromEntries(Object.entries(FELT.draw).map(([k, f]) => [k, own[k] ? (...a) => own[k](f, ...a) : f])) };
}

class Scene {
  constructor(host, opts = {}) {
    this.o = Object.assign({ topInset: 0, dusk: 0, seed: 11 }, opts);
    this.host = host;
    const cv = this.canvas = document.createElement('canvas');
    cv.setAttribute('aria-hidden', 'true');
    cv.style.cssText = 'position:absolute;left:0;top:0;display:block;pointer-events:none';
    host.appendChild(cv);
    this.ctx = cv.getContext('2d');
    this.fade = document.createElement('canvas').getContext('2d');
    this.top = Math.max(0, +this.o.topInset || 0);
    this.t = 0; this.d = this.dTarget = clamp(+this.o.dusk || 0); this.dTween = null; this.labelsAt = -9;
    // the visitor's theme, and the one the page's sky, sea and clouds are in: out at sea, the next island's (see update)
    this.state = 'hero'; this.theme = this.shows = 'built-in'; this.ws = 1;
    this.pres = Object.fromEntries(STATES.map(k => [k, k === 'hero' ? 1 : 0]));
    this.since = Object.fromEntries(STATES.map(k => [k, 0]));
    // the pointer in client coordinates less the scene's offset; each island sees it as this.ptr, in its own (see enter)
    this.cursor = { x: 0, y: 0, on: false, last: -1e9, kind: 'mouse' };
    this.vel = { x: 0, y: 0 };
    this.wind = 0; this.windAmb = 0.3; this.windTotal = 0.3; this.drift = 0;
    this.blink = { next: 2.5, at: -9, wink: -9 };
    this.layers = {};
    this.sprites = new Map();
    this.fontsV = 0; this.layoutV = 0; this.rebuilds = 0;
    this.onFrame = null;
    this.onBar = null;
    this.held = !!this.o.held;
    this.dozing = false; this.wokeAt = -9; this.waking = false; this.nightPath = this.riseAt = null; this.popped = false; this.frozen = false;
    // the islands, by how far into the dive they are: 0 is the page's hill, whose state is on the scene to begin with
    Object.assign(this, islandState());
    this.dive = 0; this.turn = 0;
    this.cur = this.w0 = { view: { s: 1, x: 0, y: 0 } };
    this.worlds = new Map([[0, this.w0]]);
    this.times = [];
    this.awake = 0; this.kick = 0; this.raf = 0; this.timer = 0; this.last = null;
    this.mq = matchMedia('(prefers-reduced-motion: reduce)');
    this.reduced = this.o.reduced ?? this.mq.matches;
    this.onMQ = () => { if (this.o.reduced == null) { this.reduced = this.mq.matches; if (this.reduced) { this.still(); this.awake = 0; } this.wake(); } };
    this.mq.addEventListener?.('change', this.onMQ);
    this.frame = this.frame.bind(this);
    this.measure(true);
    this.ro = new ResizeObserver(() => { if (this.measure()) this.wake(); });
    this.ro.observe(host);
    this.onVis = () => { if (document.hidden) { this.endBall(); this.endBore(); this.sleep(); } else { this.last = null; this.wake(); } };
    document.addEventListener('visibilitychange', this.onVis);
    const fontsIn = () => { this.fontsV++; this.wake(); };
    if (document.fonts) {
      document.fonts.load(`400 16px ${HAND}`).then(fontsIn, () => {});
      document.fonts.addEventListener?.('loadingdone', fontsIn);
    }
    this.wake();
  }

  /* ----- page state ----- */
  // with a duration (the opening's sunrise), an even change over that time instead of the usual quick ease
  setDusk(d, dur = 0) {
    d = clamp(+d || 0);
    if (dur > 0 && !this.reduced) this.dTween = { from: this.d, a: 0, dur };
    else if (d !== this.dTarget) this.dTween = null;
    this.dTarget = d; if (this.reduced) this.d = d; this.wake();
  }
  setState(name) {
    if (!STATES.includes(name)) return;
    if (name !== this.state) {
      this.state = name; this.since[name] = this.t;
      // a new little scene may stand where an animal rests: resting ones look around again shortly
      for (const o of this.objs) if (grazer(o) && o.act === 'idle') o.until = Math.min(o.until, this.t + 0.6 + Math.random() * 1.2);
    }
    this.wake();
  }
  // once the scene is up, the new style comes in with the light: the last frame, in the old one, stays where the light
  // hasn't been yet (see swap); without motion, at once; out at sea, the page has it when you're back (see update)
  setTheme(id) {
    if (!THEMES[id]) return;
    if (id !== this.theme && this.t > 0.5 && !this.reduced && !this.dive) {
      const x = this.was ||= document.createElement('canvas').getContext('2d');
      x.canvas.width = this.canvas.width; x.canvas.height = this.canvas.height;
      x.drawImage(this.canvas, 0, 0);
      this.swap = { t0: this.t, a0: this.beam.a, a: this.beam.a, L: this.g.lamp };
    }
    this.theme = id;
    if (!this.dive && id !== this.shows) this.show(id);
    this.wake();
  }
  // the page's sky, sea and clouds in another theme from now on; the band cached in the one before goes
  show(id) { delete this.layers['back' + this.shows]; this.shows = id; }
  setWorkspace(n) { this.ws = clamp(Math.round(+n || 1), 1, 4); this.wake(); }
  setTopInset(px) { const v = Math.max(0, +px || 0); if (v !== this.top) { this.top = v; this.layout(); } this.wake(); }
  // how far past the end of the page, in laps, one island a lap.
  // `back`: the page stepped back that many laps (a round of ISLANDS, or, going back up, to put its own hill just
  // behind you), and the islands ahead are renumbered to match, the round going on as it was (see turn)
  setDive(laps, back = 0) {
    if (back) {
      const was = this.worlds;
      this.worlds = new Map([[0, this.w0]]);
      for (const [n, w] of was) if (n > back) this.worlds.set(n - back, w);
      this.turn = (this.turn + back) % ISLANDS.length;
    }
    if (laps === this.dive) return;
    this.dive = laps;
    this.wake();
  }

  /* ----- the islands of the dive ----- */
  world(n) {
    let w = this.worlds.get(n);
    if (!w) {
      const g = this.island(ISLANDS[(n - 1 + this.turn) % ISLANDS.length]);
      w = { g, ...islandState() };
      this.worlds.set(n, w);
    }
    return w;
  }
  // the islands in sight, the farthest first, each with where it is on the screen (screen = s * point + (x, y)): seen
  // from its distance, around the middle of the horizon, from the one going past to the ones far off
  shown() {
    const m = Math.floor(this.dive), x = this.back.W / 2, y = this.back.horizon, out = [];
    for (let n = m + 6; n >= m; n--) {
      const s = 1 / (1 + (n - this.dive) * DIVE_GAP);
      if (s > FAR && s < PAST) out.push(Object.assign(this.world(n), { view: { s, x: x * (1 - s), y: y * (1 - s) } }));
    }
    return out;
  }
  // how many laps the page can step back to have its own hill as the island just behind you: all of them but the
  // one still going past, if there is one
  behind() {
    const m = Math.floor(this.dive), s = 1 / (1 - (this.dive - m) * DIVE_GAP);
    return Math.max(0, s > 0 && s < PAST ? m - 1 : m);
  }
  // the island being looked at, the nearest that isn't going past: input goes to it
  focus() { return this.shown().findLast(w => w.view.s <= 1.6); }
  // puts an island's state on the scene, and the pointer in its coordinates (an island far off doesn't see it yet)
  enter(w) {
    if (w !== this.cur) {
      for (const k of ISLAND) { this.cur[k] = this[k]; this[k] = w[k]; }
      this.cur = w;
    }
    const v = w.view, p = this.cursor;
    this.ptr = { ...p, x: (p.x - v.x) / v.s, y: (p.y - v.y) / v.s, on: p.on && v.s > 0.45 };
  }
  // an island of the dive, on the page's sky and sea (see ISLANDS)
  island(I) {
    const b = this.back, { W, u, top, horizon: hz } = b, sky = hz - top, sea = b.H - hz, was = this.g;
    const at = ([fx, fy]) => [fx * W, hz + fy * (fy < 0 ? sky : sea)];
    const g = this.g = { ...b, isle: true, theme: I.theme, ground: I.ground.map(hex), ridge: curve(I.ridge.map(at), 6), shore: curve(I.shore.map(at), 6), note: { x0: 0, x1: 0, y0: 0, y1: 0 }, key: null };
    const lx = I.lx * W, h = sky * 0.5, er = clamp(h * 0.062, 11.5, 22), cx = I.cx * W, cw = Math.min(h * 0.3, W * 0.13);
    // the lighthouse and the cottage stand on level ground, cut into the slope
    for (const [x, w] of [[lx, er * 2.6], [cx, cw]]) {
      const y = this.ridgeY(x);
      g.ridge = g.ridge.map(([px, py]) => [px, lerp(y, py, smooth(w * 0.55, w * 1.2, Math.abs(px - x)))]);
    }
    const ins = 2.6 * g.pw;
    g.hillPoly = [...g.ridge, ...[...g.shore].reverse()];
    g.hillClip = [...g.ridge.map(([x, y]) => [x, y + ins]), ...g.shore.slice().reverse().map(([x, y]) => [x, y - ins])];
    g.land = [g.ridge[0][0] + 20 * u, g.ridge.at(-1)[0] - 20 * u, (I.lx + I.cx) / 2 * W];
    tower(g, lx, this.ridgeY(lx) + 2 * u, h, er);
    g.cot ={ x: cx, base: this.ridgeY(cx) + 3 * u, w: cw, h: cw * 0.62 };
    g.tufts = this.tufts(rng(this.o.seed + cx));
    this.g = was;
    return g;
  }
  destroy() {
    this.dead = true; this.sleep(); this.ro.disconnect();
    this.mq.removeEventListener?.('change', this.onMQ);
    document.removeEventListener('visibilitychange', this.onVis);
    this.canvas.remove();
  }

  /* ----- what the page reads after every frame ----- */
  inBeam(x, y) {
    x -= this.ox; y -= this.oy;
    const b = this.beam, L = this.g.lamp, dx = x - L.x, dy = y - L.y, dist = Math.hypot(dx, dy);
    if (dist < 6 || dist > b.len * this.diag || b.len < 0.08) return 0;
    const w = this.g.beamHalf + 10 * this.g.u / dist;
    return 1 - smooth(w * 0.7, w * 1.2, Math.abs(angDiff(Math.atan2(dy, dx), b.a)));
  }
  beamI() { return Math.max(0.3 + 0.7 * smooth(0.22, 0.72, this.d), this.pres.install); }
  lamp() { return { x: this.g.lamp.x + this.ox, y: this.g.lamp.y + this.oy }; }
  // the colour of the sky at the top of the drawing right now, as #rrggbb
  sky() { const c = this.P && (TINT ? TINT(this.P.sky) : this.P.sky); return c ? '#' + c.map(v => Math.round(v).toString(16).padStart(2, '0')).join('') : null; }

  /* ----- input, in client coordinates ----- */
  pointer(x, y, kind = 'mouse') {
    x -= this.ox; y -= this.oy;
    const now = performance.now() / 1000, p = this.cursor;
    if (p.on && now - p.last < 0.25) {
      const dt = Math.max(0.008, now - p.last);
      this.vel.x = lerp(this.vel.x, (x - p.x) / dt, 0.35);
      this.vel.y = lerp(this.vel.y, (y - p.y) / dt, 0.35);
    }
    Object.assign(p, { x, y, on: true, last: now, kind: kind || 'mouse' });
    this.enter(this.cur);
    ({ x, y } = this.ptr);
    const sp = Math.hypot(this.vel.x, this.vel.y);
    if (!this.reduced && sp > 650 && this.isSea(x, y) && now - (this.lastRip || 0) > 0.11) {
      this.lastRip = now;
      this.ripples.push({ x, y, t0: this.t, a: Math.min(1, sp / 2400) * 0.9 });
    }
    if (this.reduced) this.aim(x, y);
    this.poke();
    this.wake();
  }
  release() { this.cursor.on = this.ptr.on = false; this.wake(); }
  // to the island under it, the nearest first, or else to the one being looked at
  tap(x, y) {
    Object.assign(this.cursor, { x: x - this.ox, y: y - this.oy });
    const w = this.shown().reverse().find(w => { this.enter(w); const p = this.ptr; return this.isLand(p.x, p.y) || this.onTower(p.x, p.y) || this.boxHit(p.x, p.y); }) || this.focus();
    this.enter(w);
    const hit = this.tapAt(this.ptr.x, this.ptr.y);
    this.enter(this.focus());
    return hit;
  }
  onTower(x, y) { const T = this.g.lh; return y >= this.top && Math.abs(x - T.x) < T.wB * 0.75 && y > T.hatTop - T.er * 1.6 && y < T.base; }
  tapAt(x, y) {
    this.poke();
    // the lighthouse plays ball instead of catching things (and winks when it can't)
    if (this.onTower(x, y)) {
      if (!this.play()) this.blink.wink = this.t;
      this.wake();
      return false;
    }
    // the sheep in its box says baa (and the light turns to see who's there); nothing drops
    if (this.boxHit(x, y)) {
      this.aim(x, y);
      this.baa();
      this.wake();
      return false;
    }
    // the cottage's door: knock knock, and the keeper comes to see who's there; nothing drops
    if (this.doorHit(x, y)) {
      this.aim(x, y);
      this.knock();
      this.wake();
      return false;
    }
    this.aim(x, y);
    this.wake();
    if (y < this.top) return false;
    this.spawn(x, y);
    return true;
  }
  surprise(kind) {
    if (!KINDS.includes(kind)) return;
    const p = this.spot(kind);
    const o = p.cloud ? this.ride(kind, p.cloud) : this.spawn(p.x, p.y, kind, false, p.fromSky);
    if (o.kind === 'gull' && !this.reduced) { o.vx *= 0.5; o.calm = 1.6; }
    this.wake();
  }
  aim(x, y) {
    const L = this.g.lamp;
    Object.assign(this.ptr, { x, y, on: true, last: performance.now() / 1000 });
    this.beam.sa = this.clampAim(Math.atan2(y - L.y, x - L.x));
    if (this.reduced) this.beam.steer = 1;
  }
  clampAim(a) {
    // keep the light off the lighthouse's own feet: never closer than this to straight down
    const lim = 0.14, down = Math.PI / 2;
    if (a > down - lim && a <= down) return down - lim;
    if (a > down && a < down + lim) return down + lim;
    return a;
  }

  /* ----- the lighthouse plays with the bar -----
     Keepy-uppy: the pom-pom leaves the hat, bounces off the line under a widget, comes back and is
     headed up again, three to six times, then misses and drops into the sea. The bored trick: once,
     when nobody has done anything for a while (the page decides), the beam shoves a widget aside.
     The page sends the bar's widgets, animates them on onBar(event, key, info) and reads s.playing. */
  get playing() { return Boolean(this.ball); }
  // the bar's visible widgets, in client coordinates: { key, x0, x1, y }, y the line the ball bounces on.
  // Only the page's lighthouse plays with them: the islands of the dive have no bar.
  setBar(list) {
    const was = this.cur;
    this.enter(this.w0);
    this.bar = (Array.isArray(list) ? list : []).filter(t => t && t.x1 > t.x0)
      .map(t => ({ key: String(t.key), x0: t.x0 - this.ox, x1: t.x1 - this.ox, y: t.y - this.oy }));
    if (!this.bar.length) { this.endBall(); this.endBore(); }
    this.enter(was);
    this.wake();
  }
  // the landing: until the camera has come down, the flock and the grass wait (they're placed where they're seen)
  hold(on) { this.held = !!on; if (!on) this.measure(); this.wake(); }
  // the opening's wake-up (see WAKE), at night: the card's bar its weak light finds and crosses, from one end to the
  // other (viewport coordinates)
  lightBar(x0, y0, x1, y1) {
    if (!this.showing()) return false;
    const L = this.g.lamp, at = (x, y) => Math.atan2(y - this.oy - L.y, x - this.ox - L.x);
    this.nightPath = { a0: at(x0, y0), a1: at(x1, y1), p0: [x0 - this.ox, y0 - this.oy], p1: [x1 - this.ox, y1 - this.oy] };
    this.wake();
    return true;
  }
  // how far across the card's bar its weak light has come (0 to 1)
  scanK() { const s0 = WAKE.dim + WAKE.scan[0]; return smooth(s0, s0 + WAKE.scan[1], this.t - this.wokeAt); }
  // how far its light reaches, as part of its full length: at night, in the show, only just past the card's bar,
  // as if the bar caught it; else all the way
  reach() {
    const np = this.nightPath;
    if (!np || !this.showing() || (this.riseAt != null && this.t - this.riseAt >= WAKE.out)) return 1;
    // where the light meets the bar's line, along where it points now
    const L = this.g.lamp, [x0, y0] = np.p0, vx = np.p1[0] - x0, vy = np.p1[1] - y0, ux = Math.cos(this.beam.a), uy = Math.sin(this.beam.a);
    const den = ux * vy - uy * vx, d = Math.abs(den) < 1e-6 ? Math.hypot(x0 - L.x, y0 - L.y) : ((x0 - L.x) * vy - (y0 - L.y) * vx) / den;
    return clamp((Math.max(0, d) + 50 * this.g.u) / (this.diag * 1.05));
  }
  // then the day comes: it blinks its light out and strains again, and its light comes on for good on the headline,
  // from one point to the other, and reads it; then it sweeps the bar and looks at you (with no headline, it only
  // lights up)
  rising(x0, y0, x1, y1) {
    if (!this.showing() || this.riseAt != null) return false;
    const L = this.g.lamp, at = (x, y) => Math.atan2(y - this.oy - L.y, x - this.ox - L.x);
    this.riseAt = this.blink.at = this.t;
    this.wakePath = x0 == null ? null : { t0: this.t, a0: at(x0, y0), a1: at(x1, y1) };
    this.wake();
    return true;
  }
  // reading the headline: the words it has lit stay lit until it has swept the bar too
  readingWords() { return !!this.wakePath || this.sweepingBar(); }
  // sweeping the bar: the page lights the widgets it passes
  sweepingBar() { return !!this.sweep?.bar; }
  // the opening: asleep, its eye shut and its lamp out, until the page wakes it for the show (see WAKE), or at once
  // (now), its light coming on as the eye opens. Woken at once during the show, it gives it up and its light comes on.
  doze(on, now) {
    if (on) this.dozing = true;
    else if (this.dozing) {
      this.dozing = false; this.wokeAt = this.t; this.restAt = this.t; this.waking = !now && !this.reduced;
      this.nightPath = this.riseAt = null; this.popped = false;
      this.blink.next = this.t + (this.waking ? 12 : 4); // its own blinks once it's done (sooner if it looks at you)
    } else if (now && this.showing()) { this.waking = false; this.wakePath = null; this.blink.next = this.t + 2; }
    this.wake();
  }
  // 1 while asleep, easing to 0 as the eye opens: in the show halfway, a little heavier again, then all the way (see
  // WAKE); quickly when woken at once
  drowsy() {
    if (this.dozing) return 1;
    const a = this.t - this.wokeAt, out = k => Math.sin(clamp(k) * Math.PI / 2), W = WAKE.lids;
    if (!this.waking) return 1 - out(a / 0.45);
    if (a < W.half) return lerp(1, W.mid, out(a / W.half));
    if (a < W.hold) return W.mid;
    if (a < W.sag) return lerp(W.mid, W.heavy, smooth(W.hold, W.sag, a));
    return lerp(W.heavy, 0, out((a - W.sag) / (WAKE.open - W.sag)));
  }
  // the opening's show is on: from waking up until its light comes on for good
  showing() { return this.waking && !(this.riseAt != null && this.t - this.riseAt >= WAKE.on); }
  // how hard it squeezes its eye shut right now, straining to light its lamp (0 to 1)
  squeeze() {
    if (!this.showing() || this.reduced) return 0;
    const night = this.riseAt == null, a = this.t - (night ? this.wokeAt : this.riseAt);
    for (const [p, d, k] of night ? WAKE.pushes : WAKE.again) if (a >= p && a < p + d) return k * smooth(p, p + 0.06, a) * (1 - smooth(p + d - 0.07, p + d, a));
    return 0;
  }
  // how far its light reaches (0 to 1): out while asleep; in the show, from `dim` at night until the day's `out`, then
  // from `on`; else on once the eye is half open
  lampOn() {
    if (this.dozing) return 0;
    if (!this.waking) return 1 - smooth(0, 0.6, this.drowsy());
    const dim = smooth(WAKE.dim, WAKE.dim + 0.15, this.t - this.wokeAt), b = this.t - this.riseAt;
    return this.riseAt == null ? dim : b < WAKE.out ? dim : smooth(WAKE.on, WAKE.on + 0.12, b);
  }
  // how bright its light is (0 to 1): in the show, at night, weak and unsteady, nearly out now and then, and going out
  // as the day comes; else full
  lampPower() {
    if (!this.waking || (this.riseAt != null && this.t - this.riseAt >= WAKE.on)) return 1;
    const f = this.t - this.wokeAt - WAKE.dim;
    const weak = WAKE.dips.some(([d0, d1]) => f >= d0 && f < d1) ? 0.1 : 0.5 + 0.1 * Math.sin(f * 31) * Math.sin(f * 13 + 1);
    return this.riseAt == null ? weak : weak * (1 - smooth(0, WAKE.out, this.t - this.riseAt));
  }
  // the opening's still night: nothing moves until the visitor does (the page draws the sleeper's z's)
  freeze(on) { this.frozen = !!on; if (!on) this.last = null; this.wake(); }
  // where the lamp is in the window, and the eye's size: the page puts the z's there
  lampAt() { const L = this.g.lamp; return { x: this.ox + L.x, y: this.oy + L.y, r: this.g.lh.er }; }
  // the drawing's own labels ("a lighthouse (stable)" and the others), off while the page's title card is up
  labels(on) { if (on && this.noLabels) this.labelsAt = this.t; this.noLabels = !on; this.wake(); }
  // how far the labels have come back in (they fade in)
  labelsK() { return this.noLabels ? 0 : this.reduced ? 1 : smooth(0, 0.6, this.t - this.labelsAt); }
  // the landing's last beat: the light swings to the bar's left end and sweeps along it to the right, once
  sweepBar(dur = 1) {
    const L = this.g.lamp, ts = this.bar;
    if (this.reduced || !ts.length || document.hidden) return false;
    const y = Math.min(...ts.map(t => t.y)) - 12 * this.g.u, x0 = Math.min(...ts.map(t => (t.x0 + t.x1) / 2)), x1 = Math.max(...ts.map(t => (t.x0 + t.x1) / 2));
    this.beam.sa = this.beam.a; this.beam.steer = 1;
    this.sweep = { t0: this.t, lead: 0.5, dur, tail: 0.25, bar: true, gaze: true, from: this.beam.a, a0: Math.atan2(y - L.y, x0 - L.x), a1: Math.atan2(y - L.y, x1 - L.x) };
    this.wake();
    return true;
  }
  play() {
    if (this.reduced || this.ball || document.hidden || this.showing()) return false;
    const h = hatGeom(this), pr = h.pr;
    if (!this.bar.some(t => t.y + pr < h.bob[1] - pr) || !this.seen(this.g.lamp.x, this.g.lamp.y)) return false;
    this.endBore();
    this.ball = { x: h.bob[0], y: h.bob[1], vx: 0, vy: 0, n: 0, max: 3 + Math.floor(Math.random() * 4), key: null, last: null, spin: 0, sq: -9 };
    this.regrowAt = -9;
    this.serve();
    this.wake();
    return !!this.ball;
  }
  // any input: catches the bored trick in the act
  poke() {
    const b = this.bore;
    if (!b || (b.phase !== 'look' && b.phase !== 'push')) return;
    if (b.phase === 'push') this.emit('release', b.key, { caught: true });
    b.phase = 'caught'; b.at = this.t; b.notes = 0;
    this.wake();
  }
  // the bored trick, now (the page calls it after a quiet spell; also a hook for testing). True if it started.
  bored() {
    // (not while its light is busy, nor in the first 40 s after the opening, counted from the end of its look at
    // you, or from waking up when the opening was skipped: it has only just performed)
    if (this.reduced || this.ball || this.bore || this.sweep || this.wakePath || this.gaze || this.t - this.restAt < 40 || document.hidden) return false;
    const L = this.g.lamp, mid = t => (t.x0 + t.x1) / 2;
    const near = this.bar.filter(t => /^(clock|meeting|battery)$/.test(t.key)).sort((a, b) => Math.abs(mid(a) - L.x) - Math.abs(mid(b) - L.x))[0];
    if (!near || !this.seen(L.x, L.y)) return false;
    const x = mid(near);
    this.bore = { key: near.key, x, y: Math.max(4, this.top * 0.5), side: x < L.x ? -1 : 1, phase: 'look', at: this.t, notes: 0 };
    this.wake();
    return true;
  }
  emit(event, key, info = {}) {
    try { this.onBar?.(event, key, info); } catch (err) { if (!this.onBarFailed) { this.onBarFailed = true; console.warn('onBar failed:', err); } }
  }
  // the next widget: the one nearest the pointer when it's up near the bar, otherwise another one, never the same twice
  pick() {
    const b = this.ball, g = this.g, h = hatGeom(this), L = g.lamp, mid = t => (t.x0 + t.x1) / 2;
    const reach = this.bar.filter(t => t.y + h.pr < h.bob[1] - h.pr && t.x1 > 0 && t.x0 < g.W);
    if (!reach.length) return null;
    if (this.ptr.on && this.ptr.y < Math.max(g.top + 60 * g.u, g.H * 0.34)) {
      const px = this.ptr.x, gap = t => px < t.x0 ? t.x0 - px : px > t.x1 ? px - t.x1 : 0;
      return reach.slice().sort((p, q) => gap(p) - gap(q) || Math.abs(mid(p) - px) - Math.abs(mid(q) - px))[0];
    }
    const other = reach.filter(t => t.key !== b.last);
    const list = other.length ? other : reach, w = list.map(t => 1 / (1 + Math.abs(mid(t) - L.x) / (500 * g.u + 200)));
    let r = Math.random() * w.reduce((a, v) => a + v, 0);
    for (let i = 0; i < list.length; i++) if ((r -= w[i]) <= 0) return list[i];
    return list[list.length - 1];
  }
  // up from the hat to the next widget
  serve() {
    const b = this.ball, tg = this.pick();
    if (!tg) return this.endBall();
    const pr = this.g.lh.er * 0.66, span = tg.x1 - tg.x0;
    b.key = tg.key;
    this.leg('up', clamp((tg.x0 + tg.x1) / 2 + (Math.random() - 0.5) * span * 0.36, pr, this.g.W - pr), tg.y + pr);
  }
  /* One flight, along a parabola: 'up' slows down and still rises when it arrives (the bounce),
     'down' and 'miss' speed up as they fall back, 'fall' drops freely into the sea */
  leg(kind, bx, by, v0) {
    const b = this.ball, R = by - b.y, T = clamp(0.4 + Math.abs(bx - b.x) / 1600, 0.42, 1);
    const L = { kind, t0: this.t, ax: b.x, ay: b.y, bx, by, T };
    if (kind === 'up') { const k = 0.3; L.v0 = 2 * R / (T * (1 + k)); L.g = (k - 1) * L.v0 / T; }
    else if (kind === 'fall') {
      const g = 1300 * this.g.u, v = Math.max(0, v0 || 0);
      L.v0 = v; L.g = g; L.T = (-v + Math.sqrt(v * v + 2 * g * Math.max(1, R))) / g;
    } else { L.v0 = 0.3 * R / T; L.g = 2 * (R - L.v0 * T) / (T * T); }
    b.leg = L;
  }
  legAt(L, k) { return [L.ax + (L.bx - L.ax) * k / L.T, L.ay + L.v0 * k + 0.5 * L.g * k * k]; }
  updateBall(dt) {
    const b = this.ball;
    if (!b) return;
    const L = b.leg, k = Math.min(this.t - L.t0, L.T);
    [b.x, b.y] = this.legAt(L, k);
    b.vx = (L.bx - L.ax) / L.T; b.vy = L.v0 + L.g * k;
    b.spin += dt * b.vx / (this.g.lh.er * 0.66) * 0.5;
    if (this.t - L.t0 < L.T) return;
    if (L.kind === 'up') this.hit();
    else if (L.kind === 'down') this.header();
    else if (L.kind === 'miss') this.fall();
    else this.splash();
  }
  // the ball meets the line under a widget: the widget hops, "boink!"
  hit() {
    const b = this.ball, g = this.g, u = g.u, pr = g.lh.er * 0.66;
    const tg = this.bar.find(t => t.key === b.key && b.x > t.x0 - pr && b.x < t.x1 + pr) || this.bar.find(t => b.x > t.x0 - 2 && b.x < t.x1 + 2);
    b.sq = this.t; b.n++;
    if (tg) {
      b.last = tg.key;
      this.emit('bump', tg.key);
      // "boink!" beside it on the far side from the lighthouse, out of the way of the ball coming back;
      // against the window's edge, under it instead
      const side = b.x < g.lamp.x ? -1 : 1;
      if (side < 0 ? b.x < 90 * u + 20 : b.x > g.W - 90 * u - 20) this.doodle('boink', clamp(b.x, 34 * u + 12, g.W - 34 * u - 12), b.y + pr + 14 * u + 4);
      else this.doodle('boink', b.x + side * (pr + 4 * u), b.y + pr * 0.15, { align: side < 0 ? 'right' : 'left' });
    }
    const h = hatGeom(this);
    // the last one comes back just wide of the hat, on the sea side, clear of the gallery, and keeps going
    if (b.n >= b.max) this.leg('miss', Math.min(h.bob[0] - h.pr * 2.7, g.lamp.x - g.lh.er * 1.7 - h.pr), h.bob[1] + h.pr * 0.9);
    else this.leg('down', h.bob[0], h.bob[1]);
  }
  // back on the hat: a header, "pok", and up again
  header() {
    const b = this.ball, u = this.g.u, pr = this.g.lh.er * 0.66, from = b.vx > 0 ? -1 : 1;
    if (!this.seen(this.g.lamp.x, this.g.lamp.y)) return this.endBall();
    this.hatKick = this.t; b.sq = this.t;
    this.doodle('pok', b.x + from * (pr + 3 * u), b.y + pr * 0.3, { align: from < 0 ? 'right' : 'left', life: 0.7 });
    this.serve();
  }
  // missed: the hat lunges too late, and the ball falls past the lighthouse into the sea
  fall() {
    const b = this.ball;
    this.hatKick = this.t;
    const S = b.splash = this.splashSpot();
    this.leg('fall', S.x, S.y, b.vy);
    // when the sea there is under the page, "plop" where the ball was last seen
    if (!S.seen) {
      let last = null;
      for (let i = 1; i <= 14; i++) { const p = this.legAt(b.leg, b.leg.T * i / 14); if (!this.seen(p[0], p[1])) break; last = p; }
      S.edge = last;
    }
  }
  splash() {
    const b = this.ball, S = b.splash, u = this.g.u;
    if (S.seen) {
      this.ripples.push({ x: S.x, y: S.y, t0: this.t, a: 1 });
      this.splashes.push({ x: S.x, y: S.y, t0: this.t });
      this.doodle('plop', S.x + 12 * u, S.y - 26 * u, { life: 1.1 });
    } else if (S.edge) this.doodle('plop', S.edge[0] + 8 * u, S.edge[1] - 6 * u, { life: 1.1 });
    this.look = { x: S.edge ? S.edge[0] : S.x, y: S.edge ? S.edge[1] : S.y, until: this.t + 1.2 };
    this.ball = null;
    this.regrowAt = this.t + 0.6;
  }
  // a spot in the sea near the lighthouse, on its sea side, that can be seen (a few DOM checks, once a game)
  splashSpot() {
    const g = this.g, u = g.u, L = g.lamp, near = g.horizon + (g.H - g.horizon) * 0.24, out = [];
    // and clear of "the sea (wet)" while the hero's labels show
    const lab = this.pres.hero > 0.01 && seaLabelSpot(this);
    const onLabel = (x, y) => lab && x > lab.x - 40 * u && x < lab.x + 170 * u && y > lab.y - 50 * u && y < lab.y + 45 * u;
    // not right on the horizon, where a splash is too small to read: a little way out, close to the hill
    for (const fy of [0.12, 0.2, 0.3, 0.42, 0.55, 0.72, 0.88]) {
      const y = g.horizon + (g.H - g.horizon) * fy;
      for (const [a, z] of this.seaSpans(y))
        for (let x = Math.min(z, g.W) - 30 * u; x > Math.max(a, 0) + 18 * u; x -= 34 * u)
          if (x < L.x - g.lh.wB * 1.6 && !onLabel(x, y)) out.push({ x, y, d: Math.hypot(x - g.lh.x, (y - near) * 0.8) });
    }
    out.sort((p, q) => p.d - q.d);
    let tries = 0;
    for (const p of out) {
      if (tries++ > 14) break;
      if (this.seen(p.x, p.y) && this.seen(p.x, p.y - 30 * u)) return { x: p.x, y: p.y, seen: true };
    }
    const p = out[0] || { x: L.x - 160 * u, y: g.H - 12 };
    return { x: p.x, y: p.y, seen: false };
  }
  // the game ends quietly (editing, the page hidden, the lighthouse covered): the pom-pom is simply back
  endBall() {
    if (!this.ball) return;
    this.ball = null;
    this.regrowAt = this.reduced || document.hidden ? -9 : this.t;
  }
  endBore() {
    const b = this.bore;
    if (!b) return;
    if (b.phase === 'push') this.emit('release', b.key, { caught: true });
    this.bore = null;
  }
  updateBore() {
    const b = this.bore;
    if (!b) return;
    const a = this.t - b.at, g = this.g, u = g.u, L = g.lamp, er = g.lh.er;
    if (b.phase === 'look' && a > 1.3) {
      b.phase = 'push'; b.at = this.t;
      this.emit('nudge', b.key, { dx: b.side * 14 });
      this.doodle('hehe', L.x - b.side * (er * 1.32 + 12 * u + 3), L.y + er * 0.25, { align: b.side > 0 ? 'right' : 'left', life: 2.4 });
    } else if (b.phase === 'push' && a > 6) {
      b.phase = 'back'; b.at = this.t;
      this.emit('release', b.key, { caught: false });
    } else if (b.phase === 'caught') {
      // whistling innocently, the notes rising on the side it looks away to
      if (b.notes < 3 && a > 0.45 + b.notes * 0.48) {
        this.doodle('note', L.x - b.side * (er * 1.5 + (4 + b.notes * 3) * u), L.y - er * (0.9 + b.notes * 0.15), { life: 1.5, flip: b.notes % 2 });
        b.notes++;
      }
      if (a > 2.5) this.bore = null;
    } else if (b.phase === 'back' && a > 1.6) this.bore = null;
  }
  // the bored trick holds the light on its widget
  beamLock() {
    const w = this.sweep;
    if (w) {
      const a = this.t - w.t0;
      if (a < w.lead + w.dur + w.tail) return a < w.lead ? w.from + angDiff(w.a0, w.from) * smooth(0, 1, a / w.lead) : w.a0 + angDiff(w.a1, w.a0) * smooth(0, 1, (a - w.lead) / w.dur);
      this.sweep = null;
      // having lit the whole bar, it turns to look straight at you for a moment, and blinks
      if (w.gaze) { this.gaze = { phi: facing(this.beam.phi), until: this.t + 3.2 }; this.blink.next = this.t + 1.1; }
    }
    const b = this.bore;
    if (!b || !((b.phase === 'look' && this.t - b.at > 0.35) || b.phase === 'push')) return null;
    return Math.atan2(b.y - this.g.lamp.y, b.x - this.g.lamp.x);
  }
  /* What the eye is up to: where it looks (a, m), and squint, wide, a heavier lid, a happy shut eye or a straining
     squeeze */
  mood() {
    const L = this.g.lamp, b = this.bore;
    if (this.showing()) {
      // waking up: it squeezes its eye shut, straining to light its lamp, and looks where the light is to go (the
      // card's bar, then the headline), or along it once it's on
      const k = this.squeeze(), aim = this.wakePath ? this.wakePath.a0 : this.nightPath?.a0, md = { shut: Math.min(1, k * 1.5), strain: k };
      if (this.lampOn() > 0.05) return { ...md, a: this.beam.a, m: 1 };
      return aim == null ? md : { ...md, a: aim, m: smooth(WAKE.open * 0.4, WAKE.open + 0.2, this.t - this.wokeAt) };
    }
    if (this.ball) return { a: Math.atan2(this.ball.y - L.y, this.ball.x - L.x), m: 1 };
    if (this.look && this.t < this.look.until) return { a: Math.atan2(this.look.y - L.y, this.look.x - L.x), m: 1 };
    if (!b) return null;
    const a = this.t - b.at, up = Math.atan2(b.y - L.y, b.x - L.x);
    if (b.phase === 'look') return { a: up, m: smooth(0, 0.45, a), squint: smooth(0.3, 0.85, a) };
    if (b.phase === 'push') return { a: up, m: 1, squint: 1 };
    if (b.phase === 'caught') {
      if (a < 0.4) return { a: up, m: 1, wide: smooth(0, 0.07, a) };
      return { a: -Math.PI / 2 - b.side * 0.9, m: 0.85, shut: 0.36 * smooth(0.4, 0.7, a), wide: 1 - smooth(0.4, 0.62, a) };
    }
    return { a: up, m: 1 - smooth(0, 0.5, a), squint: 1 - smooth(0, 0.3, a), happy: a > 0.25 && a < 1.05 ? 1 : 0 };
  }
  // 0 while the pom-pom is in play, growing back after it
  bobbleK() { return this.ball || this.t < this.regrowAt ? 0 : pop((this.t - this.regrowAt) / 0.5); }
  // a word or a note drawn by the pen for a moment; light over the sea, dark over the sky by day
  doodle(kind, x, y, o = {}) {
    this.doodles.push({ kind, x, y, t0: this.t, life: o.life ?? 0.95, align: o.align ?? 'center', sea: this.isSea(x, y + 4 * this.g.u), flip: o.flip ? -1 : 1, seed: Math.random() * 10, text: o.text, calm: Boolean(o.calm) });
  }

  /* ----- size and layout ----- */
  measure(first) {
    const r = this.host.getBoundingClientRect();
    this.ox = r.left; this.oy = r.top;
    let W = Math.max(2, Math.round(r.width)), H = Math.max(2, Math.round(r.height));
    // phones: the browser's toolbars change the height while scrolling; keep the larger one
    if (!first && W === this.W && this.g.portrait && H < this.H && H > this.H * 0.7) H = this.H;
    if (W === this.W && H === this.H) return false;
    this.W = W; this.H = H; this.diag = Math.hypot(W, H);
    const budget = 9.4e6; // device pixels for one full canvas
    this.dpr = Math.min(2, window.devicePixelRatio || 1, Math.sqrt(budget / (W * H)));
    this.canvas.width = this.fade.canvas.width = Math.round(W * this.dpr); this.canvas.height = this.fade.canvas.height = Math.round(H * this.dpr);
    this.canvas.style.width = W + 'px'; this.canvas.style.height = H + 'px';
    this.layout();
    return true;
  }

  layout() {
    this.enter(this.w0);
    const { W, H } = this, top = this.top, Hs = H - top;
    const portrait = W < 700 || H > W * 1.1;
    const u = clamp(Math.sqrt(W * H) / 1138, 0.42, 1.35);
    const was = this.g ? [...this.g.clouds, this.g.sheepCloud] : [];
    const g = this.g = { W, H, u, portrait, top };
    g.pw = clamp(0.55 + 0.45 * u, 0.74, 1.15);
    const at = (fx, fy) => [fx * W, top + fy * Hs];
    let ridgeCtl, shoreCtl;
    if (portrait) {
      // a headland in the upper right, the sea to the left and below
      g.horizon = top + Hs * 0.375;
      ridgeCtl = [at(0.165, 0.398), at(0.2, 0.384), at(0.3, 0.366), at(0.42, 0.343), at(0.55, 0.322), at(0.65, 0.312), at(0.72, 0.31), at(0.8, 0.312), at(0.9, 0.318), at(1.06, 0.33)];
      shoreCtl = [at(0.165, 0.398), at(0.2, 0.414), at(0.3, 0.432), at(0.44, 0.466), at(0.6, 0.5), at(0.78, 0.53), at(0.92, 0.545), at(1.06, 0.552)];
    } else {
      g.horizon = top + Hs * 0.6;
      ridgeCtl = [[0.43, 1.04], [0.5, 0.915], [0.56, 0.81], [0.605, 0.71], [0.64, 0.636], [0.678, 0.58], [0.727, 0.549], [0.775, 0.539], [0.84, 0.547], [0.92, 0.575], [1.05, 0.615]].map(([x, y]) => at(x, y));
      shoreCtl = null;
    }
    g.ridge = curve(ridgeCtl, 6);
    g.shore = shoreCtl ? curve(shoreCtl, 6) : null;
    g.hillPoly = g.shore ? [...g.ridge, ...[...g.shore].reverse()] : [...g.ridge, [W + 40, H + 40], [g.ridge[0][0] - 40, H + 40]];
    g.beamHalf = 0.1;
    const ins = 2.6 * g.pw;
    g.hillClip = g.shore ? [...g.ridge.map(([x, y]) => [x, y + ins]), ...g.shore.slice().reverse().map(([x, y]) => [x, y - ins])] : [...g.ridge.map(([x, y]) => [x, y + ins]), [W + 40, H + 40], [g.ridge[0][0] - 40, H + 40]];

    // the lighthouse: lamp, eye, gallery, tower and hat
    const lx = W * (portrait ? 0.72 : 0.775);
    if (portrait) {
      const base = top + Hs * 0.31 + 2 * u, er = clamp(W * 0.036, 11.5, 22), lampY = top + H * 0.1;
      tower(g, lx, base, base - (lampY + er * 1.02 + er * 0.62), er);
    } else {
      const h = Math.min(Hs * 0.27 * 1.32, W * 0.3);
      tower(g, lx, this.ridgeY(lx) + 2 * u, h, h * 0.062);
    }
    const T = g.lh;
    // the keeper's cottage, to the right of the lighthouse
    const cx = portrait ? lx + T.wB * 0.5 + T.h * 0.4 : lx + T.wB * 0.5 + T.h * 0.3;
    const cw = portrait ? Math.min(T.h * 0.34, W * 0.13) : T.h * 0.3;
    g.cot = { x: cx, base: this.ridgeY(cx) + 3 * u, w: cw, h: cw * 0.62 };

    const R = rng(this.o.seed);
    const sky = g.horizon - top;
    // clouds; the third one has legs and may be a sheep. It wanders where it can be seen.
    g.clouds = (portrait ? [0.08, 0.55, 0.9] : [0.06, 0.3, 0.7, 0.93]).map((x, i) => ({
      x0: x * (W + 360 * u), y: top + sky * (portrait ? 0.08 + R() * 0.3 : 0.1 + R() * 0.38), w: (110 + R() * 80) * u * (portrait ? 0.95 : 1),
      sp: 5 + R() * 8, seed: 31 * i + this.o.seed, ox: 0, oy: 0,
    }));
    g.sheepCloud = portrait
      ? { x0: 0.1 * W, x1: 0.16 * W, y: top + H * 0.058, w: 84 * u + 22, seed: 77, ox: 0, oy: 0 }
      : { x0: 0.5 * W, x1: 0.585 * W, y: top + sky * 0.13, w: 128 * u, seed: 77, ox: 0, oy: 0 };
    g.sheepCloud.x = lerp(g.sheepCloud.x0, g.sheepCloud.x1, 0.3); g.sheepCloud.dir = 1;
    // animals riding a cloud move to the same cloud in the new layout
    for (const o of this.objs) if (o.ride) {
      const i = was.indexOf(o.ride), cl = i === was.length - 1 ? g.sheepCloud : g.clouds[i] || g.sheepCloud;
      o.dx *= cl.w / (o.ride.w || cl.w); o.ride = cl;
    }
    const n = clamp(Math.round(W * sky / 6500), 26, 180);
    g.stars = Array.from({ length: n }, () => ({ x: R() * W, y: top + 8 + R() * (sky - 24), s: 0.55 + R() * R() * 1.6, p: R() * TAU }))
      .filter(s => Math.hypot(s.x - g.lamp.x, s.y - g.lamp.y) > T.er * 4);
    // where animals and grass go on the hill, and the middle of the pasture
    g.land = portrait ? [0.3 * W, 0.97 * W, 0.7 * W] : [0.5 * W, 0.97 * W, 0.79 * W];
    g.sun = portrait ? { x: 0.3 * W, y0: top + H * 0.115 } : { x: 0.57 * W, y0: top + sky * 0.3 };
    // (as high as the sun: lower, it would sit on the opening's title)
    g.moon = portrait ? { x: 0.08 * W + 6, y1: top + H * 0.15 } : { x: 0.6 * W, y1: top + sky * 0.3 };

    // the sea: how many rows of scallops down to the bottom on the page (see waveScallops)
    g.rows = portrait ? Math.round(clamp((H - g.horizon) / 11, 26, 60)) : Math.round(18 + 14 * Math.min(1, u));
    g.tufts = this.tufts(R);
    // where the page's notes sit (a guess, for placing labels and surprises)
    g.note = portrait ? { x0: 0, x1: W, y0: top + Hs * 0.24, y1: H } : { x0: 0, x1: W * 0.05 + Math.min(W * 0.46, 620) + 12, y0: top, y1: H * 0.84 };
    g.key = portrait ? null : { x0: 0, x1: W * 0.05 + Math.min(W * 0.46, 562) + 12, y0: H - 160, y1: H };
    // the islands of the dive stand on this sky and sea; they're made again for the new size
    this.back = g;
    this.worlds = new Map([[0, this.w0]]);
    this.layoutV++;
    for (const o of this.objs) this.settle(o);
    // the grass stays on the ground at the same depth, or goes; meals and walks start over
    for (const m of this.meadow) {
      const ry = this.ridgeY(m.x);
      if (ry == null || ry + m.depth > Math.min(this.shoreY(m.x) - 10 * u, H - 12 * u)) m.gone = true;
      else m.y = ry + m.depth;
      m.by = null;
    }
    this.meadow = this.meadow.filter(m => !m.gone);
    for (const o of this.objs) if (grazer(o) && o.act) { o.tuft = null; o.act = 'idle'; o.until = this.t + 1; }
    // the bar's widgets moved with it: a game or a trick in progress ends quietly
    this.endBall(); this.endBore();
  }
  // grass tufts along the ridge, close together
  tufts(R) {
    const g = this.g, { W, H, u } = g, T = g.lh, out = [];
    for (let x = g.ridge[0][0] + 14 * u; x < W; x += (13 + R() * 15) * u) {
      const y = this.ridgeY(x);
      if (y == null || y > H + 4 || Math.abs(x - T.x) < T.wB * 0.7 || (x > g.cot.x - g.cot.w * 0.55 && x < g.cot.x + g.cot.w * 0.5)) continue;
      out.push({ x, y, l: (8 + R() * 7) * Math.max(u, 0.62), p: R() * TAU, n: 3 + ((R() * 2.2) | 0) });
    }
    return out;
  }
  seaSpans(y) {
    const spans = [], W = this.W;
    let x0 = null;
    for (let x = -8; x <= W + 8; x += 4) {
      const sea = !this.inHill(x, y);
      if (sea && x0 == null) x0 = x;
      if ((!sea || x > W + 4) && x0 != null) { spans.push([x0, x - 4]); x0 = null; }
    }
    return spans;
  }
  ridgeY(x) {
    const r = this.g.ridge;
    if (x < r[0][0] || x > r[r.length - 1][0]) return null;
    let lo = 0, hi = r.length - 1;
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (r[m][0] <= x) lo = m; else hi = m; }
    const [x0, y0] = r[lo], [x1, y1] = r[hi];
    return lerp(y0, y1, (x - x0) / ((x1 - x0) || 1));
  }
  shoreY(x) {
    const s = this.g.shore;
    if (!s) return this.H + 40;
    if (x < s[0][0]) return s[0][1];
    for (let i = 1; i < s.length; i++) if (s[i][0] >= x) return lerp(s[i - 1][1], s[i][1], (x - s[i - 1][0]) / ((s[i][0] - s[i - 1][0]) || 1));
    return s[s.length - 1][1];
  }
  inHill(x, y) { return inPoly(this.g.hillPoly, x, y); }
  isSea(x, y) { return y > this.g.horizon && !this.inHill(x, y); }
  isLand(x, y) { const ry = this.ridgeY(x); return ry != null && y >= ry - 1 && y <= this.shoreY(x); }
  depthScale(y) { const g = this.g; return clamp(0.8 + (y - g.horizon) / (g.H - g.horizon) * 1.0, 0.7, 1.9) * (g.portrait ? 1.15 : 1.1); }

  /* ----- where things go ----- */
  // Is a point of the scene visible, or covered by page content? A guess from the DOM.
  seen(x, y) {
    // (the islands of the dive are placed for when they come close, whatever covers them now)
    if (this.cur !== this.w0) return true;
    const els = document.elementsFromPoint?.(x + this.ox, y + this.oy);
    if (!els) return true;
    for (const el of els) {
      if (el === this.canvas || el === this.host) return true;
      if (el === document.body || el === document.documentElement) return true;
      if (/^(IMG|SVG|VIDEO|BUTTON|INPUT|TEXTAREA|SELECT|CANVAS|svg)$/.test(el.tagName)) return false;
      for (const pseudo of [null, '::before', '::after']) {
        const cs = getComputedStyle(el, pseudo);
        if (pseudo && cs.content === 'none') continue;
        const bg = cs.backgroundColor.match(/[\d.]+/g);
        if ((bg && bg.length === 4 ? +bg[3] > 0.15 : bg && bg.length === 3) || (cs.backgroundImage && cs.backgroundImage !== 'none')) return false;
      }
    }
    return true;
  }
  spot(kind) {
    const g = this.g, u = g.u, R = Math.random, T = g.lh, W = g.W, H = g.H;
    const free = (x, y) => !(g.key && x > g.key.x0 && x < g.key.x1 && y > g.key.y0) && Math.abs(x - T.x) > T.wB + 26 * u;
    const tries = [];
    for (let i = 0; i < 40; i++) {
      let x, y;
      if (kind === 'gull') {
        x = g.portrait ? lerp(0.08, 0.6, R()) * W : lerp(0.48, 0.68, R()) * W;
        y = g.portrait ? g.top + lerp(0.04, 0.17, R()) * H : lerp(g.top + 40 * u, g.horizon - 70 * u, R());
      } else if (kind === 'duck' || kind === 'monster') {
        y = lerp(g.horizon + 18 * u, H - 24 * u, R() ** (g.portrait ? 1 : 0.8));
        const sp = this.seaSpans(y), span = sp[(R() * sp.length) | 0];
        if (!span) continue;
        x = lerp(Math.max(span[0], 0) + 22 + 20 * u, Math.min(span[1], W) - 10 - (kind === 'monster' ? 60 : 24) * u, R());
        if (!g.portrait && i < 30) x = lerp(Math.max(g.note.x1 + 30 * u, span[0] + 30 * u), span[1] - (kind === 'monster' ? 60 : 24) * u, R());
      } else {
        x = lerp(g.land[0], g.land[1], R());
        const ry = this.ridgeY(x);
        if (ry == null) continue;
        y = ry + lerp(8 * u, Math.min(this.shoreY(x) - ry - 20 * u, H * 0.32), R());
        if (y > H - 20 * u) continue;
      }
      if (!free(x, y)) continue;
      if (i < 32 && this.objs.some(o => o.dying == null && Math.abs(o.x - x) < 56 * u && Math.abs((o.ty ?? o.y) - y) < 30 * u)) continue;
      tries.push({ x, y });
      if (this.seen(x, y) && this.seen(x, y - 20 * u)) return { x, y };
    }
    // no land in sight (a phone, with the notes over the hill): it lands on a cloud
    if (kind === 'sheep' || kind === 'cow') {
      const cl = this.cloudSpot();
      if (cl) { const p = this.cloudXY(cl); return { x: p.x, y: p.y, cloud: cl }; }
    }
    // nothing visible: drop it where it belongs anyway, falling from the sky
    const p = tries[0] || { x: W * 0.8, y: H * 0.8 };
    return { ...p, fromSky: true };
  }
  // a cloud that shows, the one with the fewest riders first, for a sheep or a cow with no land in sight
  cloudSpot() {
    const g = this.g, u = g.u, R = Math.random, T = g.lh;
    const riders = cl => this.objs.filter(o => o.ride === cl && o.dying == null).length + R() * 0.5;
    for (const cl of [...g.clouds, g.sheepCloud].sort((a, b) => riders(a) - riders(b))) {
      const p = this.cloudXY(cl);
      if (p.x > 40 * u && p.x < g.W - 40 * u && Math.hypot(p.x - g.lamp.x, p.y - g.lamp.y) > T.er * 5 && this.seen(p.x, p.y - cl.w * 0.2)) return cl;
    }
    return null;
  }

  spawn(x, y, kind, settled, fromSky) {
    const g = this.g, u = g.u, R = Math.random;
    const land = this.isLand(x, y), sea = this.isSea(x, y);
    const o = { x, y, vx: 0, vy: 0, t0: this.t, flip: R() < 0.5, seed: (R() * 1e4) | 0, lit: 0, kind };
    if (!o.kind) {
      if (land) o.kind = R() < 0.6 ? 'sheep' : 'cow';
      else if (sea) o.kind = R() < 0.55 ? 'duck' : 'monster';
      else if (y < lerp(g.top, g.horizon, 0.55) && R() < 0.45) o.kind = 'gull';
      else o.kind = this.ridgeY(x) != null && y < this.shoreY(x) && x > (g.shore ? 0 : this.hillLeftX(g.horizon) - 20 * u) ? (R() < 0.6 ? 'sheep' : 'cow') : 'duck'; // from the sky, only ducks: monsters surface where the water is clicked
    }
    const still = settled || this.reduced;
    if (o.kind === 'gull') {
      o.state = 'fly'; o.vx = (o.flip ? -1 : 1) * (60 + R() * 60) * u; o.vy = -(6 + R() * 18) * u; o.sc = 1.15;
      if (this.reduced) { o.vx = 0; o.vy = 0; o.state = 'hover'; }
    } else if (o.kind === 'sheep' || o.kind === 'cow') {
      let ry = this.ridgeY(x);
      if (ry == null) { o.x = x = clamp(x, g.ridge[0][0] + 20 * u, Math.min(g.W, g.ridge.at(-1)[0]) - 14 * u); ry = this.ridgeY(x); }
      const room = this.shoreY(x) - ry - 14 * u;
      o.depth = land ? clamp(y - ry, 3 * u, Math.min(room, g.H - ry - 24 * u)) : clamp((6 + R() * 40) * u, 3 * u, room);
      o.ty = ry + o.depth;
      if (still || land && !fromSky) { o.state = 'land'; o.y = o.ty; o.land = still ? -9 : this.t; }
      else { o.state = 'fall'; if (fromSky) o.y = Math.min(o.ty - 120 * u, g.top - 20); }
      o.sc = this.depthScale(o.ty);
    } else {
      o.ty = sea ? y : g.horizon + (g.H - g.horizon) * (0.16 + R() * 0.55);
      if (!sea) { const sp = this.seaSpans(o.ty); const s = sp.find(q => q[0] <= x && x <= q[1]) || sp[0]; if (s) o.x = clamp(x, s[0] + 24 * u, s[1] - 30 * u); }
      if (o.kind === 'monster' || still || sea && !fromSky) { o.y = o.ty; o.state = o.kind === 'monster' ? 'swim' : 'float'; if (!this.reduced && !settled) this.ripples.push({ x: o.x, y: o.ty, t0: this.t, a: 0.8 }); }
      else { o.state = 'fall'; if (fromSky) o.y = Math.min(o.ty - 120 * u, g.top - 20); }
      o.sc = this.depthScale(o.ty);
    }
    this.objs.push(o);
    const live = this.objs.filter(q => q.dying == null);
    if (live.length > MAX_OBJS) live[0].dying = this.t;
    return o;
  }
  ride(kind, cl, settled) {
    const g = this.g, R = Math.random, p = this.cloudXY(cl);
    const o = { kind, ride: cl, dx: (R() - 0.5) * cl.w * 0.3, x: p.x, y: 0, vx: 0, vy: 0, t0: this.t, flip: R() < 0.5, seed: (R() * 1e4) | 0, lit: 0, sc: 0.85 * (g.portrait ? 1.1 : 1) };
    o.x = p.x + o.dx; o.ty = this.rideY(o);
    if (this.reduced || settled) { o.state = 'ride'; o.y = o.ty; o.land = -9; } else { o.state = 'fall'; o.y = g.top - 30; }
    this.objs.push(o);
    const live = this.objs.filter(q => q.dying == null);
    if (live.length > MAX_OBJS) live[0].dying = this.t;
    return o;
  }
  rideY(o) { const p = this.cloudXY(o.ride); return p.y - o.ride.w * 0.17; }
  // reduced motion switched on: whatever is moving stops where it is
  still() {
    for (const o of this.objs) {
      if (o.state === 'leap') this.endLeap(o);
      if (o.state === 'fly') { o.state = 'hover'; o.vx = o.vy = 0; }
      else if (o.state === 'fall') { o.y = o.ty; o.vy = 0; o.state = o.ride ? 'ride' : o.kind === 'duck' ? 'float' : 'land'; }
      o.land = -9;
      if (o.dying != null) o.dead = true;
      // no one eats: heads up, meals over
      if (grazer(o)) { this.letGo(o); o.act = 'idle'; o.head = 0; o.vx = o.vd = 0; o.joy = null; }
    }
    this.objs = this.objs.filter(o => !o.dead);
    // the grass stands still: grown, with whatever is left of it
    for (const m of this.meadow) { m.t0 = -99; m.blades = m.blades.filter(b => b.cut == null); m.left = m.blades.length; }
    this.meadow = this.meadow.filter(m => m.left > 0);
    this.box.hop = this.box.peek = -9;
    this.ripples = [];
    this.endBall(); this.endBore();
    this.wakePath = this.gaze = this.visit = null; this.waking = false;
    this.regrowAt = this.hatKick = -9;
    this.doodles = []; this.splashes = []; this.look = null;
  }
  settle(o) {
    // after a resize, put land animals back on the ground and sea animals back in the water
    if (o.ride) return;
    if (o.kind === 'sheep' || o.kind === 'cow') { const ry = this.ridgeY(clamp(o.x, this.g.ridge[0][0], this.W - 10)); if (ry != null) { o.ty = ry + Math.min(o.depth, this.shoreY(o.x) - ry - 14); if (o.state !== 'fall') o.y = o.ty; } }
    else if (o.kind !== 'gull' && !this.isSea(o.x, o.ty)) o.dying ??= this.t;
  }
  hillLeftX(y) {
    const r = this.g.ridge;
    for (let i = 1; i < r.length; i++) if (r[i][1] <= y) { const [x0, y0] = r[i - 1], [x1, y1] = r[i]; return lerp(x0, x1, (y - y0) / ((y1 - y0) || 1)); }
    return this.W;
  }

  /* ----- time ----- */
  wake() {
    this.awake = Math.max(this.awake, performance.now() + (this.reduced ? 300 : IDLE_AFTER));
    this.kick = 3; // at least a few frames, however late the first one comes
    if (this.timer) { clearTimeout(this.timer); this.timer = 0; }
    this.schedule();
  }
  sleep() { cancelAnimationFrame(this.raf); clearTimeout(this.timer); this.raf = this.timer = 0; }
  schedule() {
    if (this.raf || this.timer || this.dead || document.hidden) return;
    // frozen: a frame only when one is asked for (a resize, a new theme) or while the hour changes, none in between
    if (this.frozen) { if (this.kick > 0 || this.d !== (this.dEff ?? this.dTarget)) this.raf = requestAnimationFrame(this.frame); return; }
    const active = this.kick > 0 || performance.now() < this.awake || this.busy();
    if (active) this.raf = requestAnimationFrame(this.frame);
    else if (!this.reduced) this.timer = setTimeout(() => { this.timer = 0; this.raf = requestAnimationFrame(this.frame); }, 1000 / IDLE_FPS - 6);
    // reduced motion and nothing moving: the scene sleeps until the next call or input
  }
  busy() {
    if (this.swap || this.wipe || this.sweep || this.wakePath || this.gaze || this.visit || this.t - this.knocks.at < 0.5 || this.showing() || this.t - this.wokeAt < WAKE.open + 0.2 || this.t - this.labelsAt < 0.6) return true;
    if (Math.abs(this.box.lid - (this.boxEmpty() ? 1 : 0)) > 0.01) return true;
    if (this.d !== (this.dEff ?? this.dTarget) || (this.state === 'install') !== (this.pres.install > 0.999)) return true;
    for (const k of STATES) { const p = this.pres[k]; if (p > 0.001 && p < 0.999) return true; }
    if (this.ripples.length) return true;
    // (the grazing and its "nom"s are slow: they carry on at the idle rate)
    if (this.ball || this.bore || this.doodles.some(d => !d.calm) || this.splashes.length || this.t - this.hatKick < 0.7 || this.t - this.regrowAt < 0.9 || this.t - this.box.hop < 0.8 || this.t - this.box.wob < 0.5) return true;
    for (const o of this.objs) if (o.state === 'fall' || o.state === 'leap' || (o.state === 'fly' && !this.reduced) || o.dying != null || (o.land > 0 && this.t - o.land < 0.4)) return true;
    return this.beam.steer > 0.01 && this.beam.steer < 0.99 && !this.reduced;
  }
  frame(now) {
    this.raf = 0;
    if (this.dead || document.hidden) return;
    this.kick--;
    const dt = this.last == null ? 1 / 60 : Math.min(0.1, Math.max(0, (now - this.last) / 1000));
    this.last = now;
    // frozen, only the very first frame moves anything (it puts everyone in their place); after it only the hour does
    if (!this.frozen || this.t === 0) this.update(dt);
    else this.stepDusk(dt);
    const t0 = performance.now();
    this.render();
    this.times.push(performance.now() - t0);
    if (this.times.length > 240) this.times.shift();
    this.onFrame?.(this);
    this.schedule();
  }
  // the hour: toward the one asked for, quickly, or evenly over the time given (see setDusk)
  stepDusk(dt) {
    const rm = this.reduced, tw = this.dTween;
    // the install state brings the night with it
    const dTarget = this.dEff = Math.max(this.dTarget, this.pres.install > 0 ? lerp(this.dTarget, 1, this.pres.install) : 0);
    if (tw && !rm) { tw.a += dt; const k = smooth(0, 1, tw.a / tw.dur); this.d = lerp(tw.from, dTarget, k); if (k >= 1) this.dTween = null; }
    else this.d = rm ? dTarget : this.d + (dTarget - this.d) * Math.min(1, dt * 2.4);
    if (Math.abs(dTarget - this.d) < 0.0005) this.d = dTarget;
  }
  update(dt) {
    const g = this.g, u = g.u, rm = this.reduced;
    this.t += dt;
    for (const k of STATES) {
      const want = k === this.state ? 1 : 0;
      this.pres[k] = rm ? want : clamp(this.pres[k] + Math.sign(want - this.pres[k]) * dt * 1.8);
    }
    this.stepDusk(dt);
    if (this.swap && this.t - this.swap.t0 > SWAP) this.swap = null;
    // out at sea, the page goes over to the theme of the island you're heading to as the one before it goes past (the
    // far island's as soon as the dive begins), and back on the page to the visitor's: the new theme opens out in a
    // circle from the middle of the horizon, and the bar goes over as the circle reaches it. When that changes again
    // before the circle covers the screen, it's over at once and the next one starts
    const to = this.dive ? this.world(Math.max(1, Math.floor(this.dive + 0.95))).g.theme : this.theme, wp = this.wipe;
    if (wp && (to !== wp.to || this.t - wp.t0 > WIPE)) {
      if (!wp.bar) this.emit('theme', wp.to);
      this.show(wp.to);
      this.wipe = null;
    }
    if (!this.wipe && to !== this.shows) this.wipe = { to, t0: this.t };
    if (this.wipe) {
      const w = this.wipe, B = this.back, y = B.horizon;
      w.r = Math.hypot(B.W / 2, Math.max(y, B.H - y)) * smooth(0, WIPE, this.t - w.t0);
      if (!w.bar && w.r > y - B.top / 2) { w.bar = true; this.emit('theme', w.to); }
    }
    this.vel.x *= Math.exp(-dt * 2.5); this.vel.y *= Math.exp(-dt * 2.5);
    this.windAmb = rm ? 0.2 : 0.28 + 0.22 * noise(this.t * 0.13 + 3);
    this.wind = lerp(this.wind, clamp(this.vel.x / 1300, -1.5, 1.5), Math.min(1, dt * 1.8));
    this.windTotal = this.windAmb + this.wind;
    if (!rm) this.drift += dt * (1 + this.windTotal * 2.4);
    // clouds lean away from the pointer
    for (const cl of [...g.clouds, g.sheepCloud]) {
      let tx = 0, ty = 0;
      if (this.cursor.on && !rm) {
        const p = this.cloudXY(cl, true), dx = p.x - this.cursor.x, dy = p.y - this.cursor.y, r = 170 * u, dd = Math.hypot(dx, dy);
        if (dd < r) { const k = (1 - dd / r) ** 2 * 48 * u / (dd || 1); tx = dx * k; ty = dy * k; }
      }
      const k = rm ? 1 : Math.min(1, dt * 3);
      cl.ox = lerp(cl.ox, tx, k); cl.oy = lerp(cl.oy, ty, k);
    }
    // the cloud with legs wanders to and fro, against the wind if it likes
    const sc = g.sheepCloud;
    if (!rm) {
      sc.x += sc.dir * 7 * u * dt;
      if (sc.x > sc.x1) sc.dir = -1; else if (sc.x < sc.x0) sc.dir = 1;
    }
    // the eye blinks now and then
    if (!rm && this.t > this.blink.next) { this.blink.at = this.t; this.blink.next = this.t + 3 + Math.random() * 5; }
    // its lamp lit for good, after all that straining: the hat jumps
    if (this.waking && !this.popped && this.riseAt != null && this.t - this.riseAt >= WAKE.on) { this.popped = true; this.hatKick = this.t; }
    for (const w of this.shown()) { this.enter(w); this.updateIsland(dt); }
    this.enter(this.focus());
  }
  // what moves on an island: its light, the ripples round it, its animals, grass and box, its games with the bar
  updateIsland(dt) {
    const g = this.g, u = g.u;
    // at the cottage's door: the keeper wonders who knocked (or nobody comes), and it's over
    const v = this.visit;
    if (v) {
      const a = this.t - v.t0, k = g.cot, d = k.door;
      if (!v.huh && d && a >= (v.away ? 0.9 : VISIT.huh)) {
        // (by the cottage, where the knock was: over its roof, the pen wouldn't show)
        v.huh = true;
        if (v.away) this.doodle('huh', d.x + d.w / 2, d.y - 8 * u, { text: '…', life: 1.1 });
        else this.doodle('huh', k.x + k.w * 0.66, d.y + d.h * 0.15, { text: '?', align: 'left', life: 1 });
      }
      if (a > (v.away ? VISIT.away : VISIT.end)) this.visit = null;
    }
    this.updateBeam(dt);
    this.ripples = this.ripples.filter(r => this.t - r.t0 < 2.2);
    if (!this.flocked && !this.held) this.flock();
    this.updateObjs(dt);
    this.updateMeadow();
    this.updateBox(dt);
    this.updateBall(dt);
    this.updateBore();
    this.doodles = this.doodles.filter(d => this.t - d.t0 < d.life);
    this.splashes = this.splashes.filter(p => this.t - p.t0 < 0.7);
  }
  updateBeam(dt) {
    const b = this.beam, L = this.g.lamp, now = performance.now() / 1000, rm = this.reduced, wp = this.wakePath, sw = this.swap;
    if (sw && this.cur === this.w0) {
      // a new style coming in: the page's light turns once round from where it was, all the way out (see setTheme)
      b.a = sw.a = sw.a0 + TAU * smooth(0, SWAP, this.t - sw.t0); b.len = 1; b.flash = 0;
      return;
    }
    if (wp && (this.ball || this.t - wp.t0 > WAKE.end)) {
      this.wakePath = null;
      // done reading: on to the bar
      if (!this.ball) this.sweepBar(1.3);
    }
    if (this.gaze && (this.ball || this.sweep || this.wakePath || this.t > this.gaze.until)) { this.gaze = null; this.restAt = this.t; }
    // (asked first: when the sweep ends here, the look at you starts this very frame, before the pointer can pull
    // the light)
    const lock = this.wakePath || this.gaze || this.showing() ? null : this.beamLock();
    if (this.wakePath) {
      // the day comes (see rising): its weak light goes out on the title, and its light for good comes on at the
      // headline's first word and reads across to the last
      const w = this.t - wp.t0;
      b.steer = 1;
      if (w >= WAKE.out) b.sa = wp.a0 + angDiff(wp.a1, wp.a0) * smooth(WAKE.read, WAKE.read + WAKE.dur, w);
    } else if (this.showing()) {
      // at night (see lightBar): its weak light comes on at one end of the card's bar and crosses it, a little unsteady
      const np = this.nightPath;
      b.steer = 1;
      if (np) b.sa = np.a0 + angDiff(np.a1, np.a0) * this.scanK() + (rm ? 0 : 0.02 * Math.sin(this.t * 2.1));
    } else if (this.gaze) {
      // looking at you: the light comes round to face you and stays there a moment (the pointer can wait)
      b.phi = this.gaze.phi;
      b.steer = lerp(b.steer, 0, Math.min(1, dt * 3));
    } else {
      const quiet = this.ptr.kind === 'touch' ? 3.2 : 5;
      const steering = lock != null || (this.ptr.on && now - this.ptr.last < quiet);
      b.steer = rm ? (steering || b.steer > 0.5 ? 1 : 0) : lerp(b.steer, steering ? 1 : 0, Math.min(1, dt * (steering ? 4 : 0.7)));
      if (!rm) b.phi += dt * TAU / 15;
      if (lock != null) b.sa += angDiff(lock, b.sa) * Math.min(1, dt * (this.sweep ? 9 : 3.2));
      else if (this.ptr.on && steering) {
        const want = this.clampAim(Math.atan2(this.ptr.y - L.y, this.ptr.x - L.x));
        b.sa = rm ? want : b.sa + angDiff(want, b.sa) * Math.min(1, dt * 5);
      }
    }
    const c = Math.cos(b.phi), sn = Math.sin(b.phi);
    const vx = lerp(c, Math.cos(b.sa), b.steer), vy = lerp(0.03 * Math.abs(c), Math.sin(b.sa), b.steer);
    b.a = Math.atan2(vy, vx);
    b.len = clamp(Math.hypot(vx, vy)) * this.lampOn() * this.reach();
    b.flash = Math.pow(Math.max(0, sn), 14) * (1 - b.steer) * this.lampOn();
  }
  updateObjs(dt) {
    const g = this.g, u = g.u, G = 1500 * u, rm = this.reduced;
    for (const o of this.objs) {
      if (o.ride) {
        // riding a cloud: follow it, landing first if still falling
        const p = this.cloudXY(o.ride);
        o.x = p.x + o.dx; o.ty = this.rideY(o);
        if (o.state === 'fall') { o.vy += G * dt; o.y += o.vy * dt; if (o.y >= o.ty) { o.y = o.ty; o.state = 'ride'; o.land = this.t; } }
        else o.y = o.ty;
        o.lit = lerp(o.lit, this.inBeam(o.x + this.ox, o.y - 12 * u * o.sc + this.oy), rm ? 1 : Math.min(1, dt * 8));
        if (o.dying != null && (rm || this.t - o.dying > 0.7)) o.dead = true;
        continue;
      }
      if (o.state === 'leap') {
        // out of the box onto the grass, or back in: a hop along an arc (out, it rises before it goes sideways)
        const L = o.leap, f = clamp((this.t - L.t0) / L.dur);
        o.x = lerp(L.x0, L.x1, L.in ? smooth(0, 0.85, f) : smooth(0.15, 1, f));
        o.y = lerp(L.y0, L.y1, f) - 4 * L.h * f * (1 - f);
        if (f >= 1) this.endLeap(o);
      } else if (o.state === 'fall') {
        o.vy += G * dt; o.y += o.vy * dt;
        if (o.y >= o.ty) {
          o.y = o.ty; o.vy = 0; o.land = this.t;
          o.state = o.kind === 'duck' ? 'float' : 'land';
          if (o.kind === 'duck') this.ripples.push({ x: o.x, y: o.ty, t0: this.t, a: 1 });
        }
      } else if (rm) {
        // reduced motion: everything holds still where it appeared
      } else if (o.state === 'land') {
        this.live(o, dt);
      } else if (o.state === 'float') {
        o.x += this.windTotal * 6 * u * dt;
        o.y = o.ty + Math.sin(this.t * 2.2 + o.seed) * 1.8 * u;
        if (!this.isSea(o.x + 16 * u, o.ty - 1) || o.x > g.W - 10) o.x -= this.windTotal * 6 * u * dt + 0.5;
      } else if (o.state === 'swim') {
        o.x += (o.flip ? -1 : 1) * 16 * u * o.sc * dt;
        if (!this.isSea(o.x + (o.flip ? -40 : 64) * u * o.sc, o.ty - 1) || o.x < 50 * u || o.x > g.W - 60 * u) o.flip = !o.flip;
      } else if (o.state === 'fly') {
        if (o.calm > 0) { o.calm -= dt; o.x += o.vx * 0.15 * dt; o.y += Math.sin(this.t * 2 + o.seed) * 10 * u * dt; }
        else { o.x += o.vx * dt; o.y += (o.vy + Math.sin(this.t * 2 + o.seed) * 14 * u) * dt; o.vy *= 1 - dt * 0.4; }
        if (o.x < -100 || o.x > g.W + 100 || o.y < -100) o.dead = true;
      }
      o.lit = rm ? this.inBeam(o.x + this.ox, o.y - 12 * u * o.sc + this.oy) : lerp(o.lit, this.inBeam(o.x + this.ox, o.y - 12 * u * o.sc + this.oy), Math.min(1, dt * 8));
      if (o.dying != null && (rm || this.t - o.dying > 0.7)) o.dead = true;
    }
    for (const o of this.objs) if (o.dead || o.dying != null) this.letGo(o);
    this.objs = this.objs.filter(o => !o.dead);
  }

  /* ----- a lived-in hill -----
     A small flock is there from the start, settled where it's seen. Tufts of grass sprout here and there on
     the visible hill; a sheep or a cow that isn't busy walks over to the nearest free one (across the slope as
     much as along it), lowers its head and eats it blade by blade, looks pleased, and goes back to idling and
     wandering. Sheep still run from the pointer, mid-meal or not. All of it is slow, so it runs at the idle rate. */
  flock() {
    this.flocked = true;
    const g = this.g, u = g.u, R = Math.random;
    if (g.portrait) {
      // phones: one or two, on whatever land or cloud shows in the first screen
      for (const kind of ['sheep', R() < 0.4 ? 'cow' : 'sheep']) {
        const p = this.landSpot({ gap: 50 * u });
        if (p) this.spawn(p.x, p.y, kind, true);
        else { const cl = this.cloudSpot(); if (cl && !this.objs.some(o => o.ride === cl)) this.ride(kind, cl, true); }
      }
    } else {
      for (const kind of g.W >= 1200 ? ['sheep', 'cow', 'sheep', 'sheep'] : ['sheep', 'cow', 'sheep']) {
        const p = this.landSpot({ gap: 64 * u, spread: true, check: 4, snug: true });
        if (p) this.spawn(p.x, p.y, kind, true);
      }
      const d = this.seaSpot();
      if (d) this.spawn(d.x, d.y, 'duck', true);
    }
    // grass already there: one a short walk from somebody (the first meal comes soon), the rest spread out
    const first = this.objs.find(grazer);
    for (let i = 0, n = (g.portrait ? 5 : 9) + (R() < 0.5 ? 1 : 0); i < n; i++) this.sprout(true, i === 0 && first && !this.reduced ? first : null);
    this.sproutAt = this.t + 4 + R() * 4;
    // not everyone is hungry at once: the one nearest some grass first, soon, and the others in turn
    const near = o => Math.min(1e9, ...this.meadow.map(m => Math.hypot(m.x - o.x, (m.y - o.y) * 1.5)));
    this.objs.filter(grazer).sort((a, b) => near(a) - near(b)).forEach((o, k) => {
      o.hungry = this.t + (k ? 6 + k * (6 + R() * 5) : 0); o.act = 'idle'; o.until = this.t + (k ? 1 + R() * 3 : 1); o.head = 0; o.vd = 0;
    });
  }
  /* A visible spot on the hill for an animal or a tuft, clear of the lighthouse, the cottage, the key and the
     section's props, at least `gap` from the others (the farthest of a few when `spread`), or near `near`.
     A few DOM checks at most; null when none shows. */
  landSpot({ gap = 0, spread = false, near = null, reach = 0, min = 0, check = 3, snug = false, clear = false } = {}) {
    const g = this.g, u = g.u, R = Math.random, W = g.W, H = g.H, out = [];
    const others = [...this.objs.filter(o => grazer(o) && o.dying == null && o !== near), ...this.meadow];
    for (let i = 0; i < 40; i++) {
      const x = near ? near.x + (R() * 2 - 1) * reach : lerp(g.land[0], g.land[1], R());
      const ry = this.ridgeY(x);
      if (ry == null || x > W - 22 * u) continue;
      const room = Math.min(this.shoreY(x) - 16 * u, H - 24 * u, ry + H * 0.36) - ry;
      if (room < 12 * u) continue;
      const y = near ? clamp(near.y + (R() * 2 - 1) * reach * 0.45, ry + 6 * u, ry + room) : ry + lerp(8 * u, room, R() ** 0.85);
      if (near && Math.hypot(x - near.x, y - near.y) < min) continue;
      // snug: well inside the hill, not on its steep edge over the sea or down at the window's bottom
      if (snug && (y > H - 84 * u || !this.isLand(x - 46 * u, y) || !this.isLand(x - 46 * u, y + 16 * u))) continue;
      if (!this.open(x, y)) continue;
      // clear: not hidden behind an animal's body, nor under its feet
      if (clear && others.some(o => !o.blades && Math.abs(o.x - x) < 32 * u * o.sc && y > o.y - 36 * u * o.sc && y < o.y + 12 * u)) continue;
      let d = 1e9;
      for (const o of others) d = Math.min(d, Math.hypot(o.x - x, (o.y - y) * 1.6));
      if (d < gap) continue;
      out.push({ x, y, d });
    }
    // spread out, but not into the corners: far enough from the others, then near the middle of the pasture
    if (spread) { const mid = g.land[2], sc = p => Math.min(p.d, 170 * u) - Math.abs(p.x - mid) * 0.3; out.sort((a, b) => sc(b) - sc(a)); }
    // seen: its middle, and its ends too unless it's only a walk's goal
    for (let i = 0; i < Math.min(check, out.length); i++) {
      const p = out[i];
      if (this.seen(p.x, p.y - 6 * u) && this.seen(p.x, p.y - 24 * u) && (near || (this.seen(p.x - 20 * u, p.y - 8 * u) && this.seen(p.x + 20 * u, p.y - 8 * u)))) return p;
    }
    return null;
  }
  // nothing of the scene's own in the way: the lighthouse, the cottage, the key, the huts, the desk
  open(x, y) {
    const g = this.g, u = g.u, T = g.lh, k = g.cot, bx = this.box;
    if (bx.gx != null && Math.abs(x - bx.gx) < 44 * u && y > bx.gy - 46 * u && y < bx.gy + 18 * u) return false;
    if (g.key && x > g.key.x0 && x < g.key.x1 && y > g.key.y0 - 30 * u) return false;
    if (Math.abs(x - T.x) < T.wB * 0.9 + 20 * u && y < T.base + 42 * u) return false;
    if (Math.abs(x - k.x) < k.w * 0.8 + 18 * u && y < k.base + 32 * u) return false;
    if (this.state === 'tiling' || this.pres.tiling > 0.01) for (const q of hutSpots(this)) if (Math.abs(x - q.x) < 42 * u && y > q.y - 74 * u && y < q.y + 24 * u) return false;
    if (this.state === 'widgets' || this.pres.widgets > 0.01) { const d = deskSpot(this); if (Math.abs(x - d.x) < 66 * u && y > d.y - 110 * u && y < d.y + 24 * u) return false; }
    return true;
  }
  // a visible spot on the sea for the duck, clear of "the sea (wet)"
  seaSpot() {
    const u = this.g.u, lab = seaLabelSpot(this);
    for (let i = 0; i < 4; i++) {
      const p = this.spot('duck');
      if (p.fromSky) return null;
      if (!lab || !(p.x > lab.x - 46 * u && p.x < lab.x + 160 * u && p.y > lab.y - 34 * u && p.y < lab.y + 54 * u)) return p;
    }
    return null;
  }
  // a tuft of grass where it's seen (near `near` if it can); `grown` for the ones already there when the page opens
  sprout(grown, near) {
    const u = this.g.u, R = Math.random;
    const p = (near && this.landSpot({ near, reach: 110 * u, min: 55 * u, gap: 30 * u, snug: true, clear: true, check: 3 }))
      || this.landSpot({ gap: 30 * u, snug: true, clear: true, spread: grown });
    if (!p) return null;
    const sc = this.depthScale(p.y) * 0.85, n = 6 + ((R() * 4) | 0), blades = [];
    for (let i = 0; i < n; i++) {
      const f = i / (n - 1) - 0.5;
      blades.push({
        dx: (f * 15 + (R() - 0.5) * 1.8) * u * sc, a: f * 1.05 + (R() - 0.5) * 0.22, flex: 0.7 + R() * 0.5,
        l: (14 + R() * 7) * (1 - Math.abs(f) * 0.5) * u * sc, d: Math.abs(f) * 1.1 + R() * 0.3, cut: null,
      });
    }
    const m = { x: p.x, y: p.y, depth: p.y - this.ridgeY(p.x), sc, blades, left: n, lastCut: -9, by: null, t0: grown || this.reduced ? -99 : this.t, ph: R() * TAU };
    this.meadow.push(m);
    return m;
  }
  updateMeadow() {
    if (!this.flocked) return;
    const t = this.t, R = Math.random;
    // the last blade gone: the tuft goes, and whoever ate it looks pleased
    for (const m of this.meadow) {
      if (m.left > 0 || t - m.lastCut < 0.45) continue;
      m.gone = true;
      const o = m.by;
      if (o) { o.tuft = null; o.act = 'happy'; o.joy = t; o.until = t + 1.3; o.hungry = t + 30 + R() * 30; }
    }
    this.meadow = this.meadow.filter(m => !m.gone);
    // a new one now and then, only while the page shows (the scene's time stands still while it's hidden)
    if (this.reduced || t < this.sproutAt) return;
    const max = this.g.portrait ? MEADOW_PHONE : MEADOW_MAX, m = this.meadow.length < max ? this.sprout(false) : null;
    this.sproutAt = t + (m || this.meadow.length >= max ? lerp(SPROUT_MIN, SPROUT_MAX, R()) : 3);
  }
  letGo(o) { if (o.tuft) { if (o.tuft.by === o) o.tuft.by = null; o.tuft = null; } }
  // one animal's day: idle, wander, walk to a tuft and eat it, look pleased; run from the pointer (sheep)
  live(o, dt) {
    const g = this.g, u = g.u, t = this.t, R = Math.random, cow = o.kind === 'cow';
    if (o.act == null) { o.act = 'idle'; o.until = t + 0.5 + R() * 2.5; o.hungry ??= t + 3 + R() * 10; o.head = 0; o.vd = 0; o.bites = 0; }
    o.vd ??= 0;
    const dx = o.x - this.ptr.x, dy = o.y - this.ptr.y;
    const scared = this.ptr.on && !cow && o.dying == null && o.act !== 'home' && dx * dx + dy * dy < (110 * u) ** 2;
    let wx = 0, wd = 0, head = 0;
    if (scared) {
      this.letGo(o);
      o.act = 'flee'; o.until = t + 0.5 + R() * 0.8;
      wx = Math.sign(dx || 1) * 70 * u; wd = clamp(dy / (110 * u), -1, 1) * 26 * u;
    } else {
      if ((o.act === 'flee' || o.act === 'happy') && t > o.until) { o.act = 'idle'; o.until = t + 1.5 + R() * 3.5; }
      if (o.act === 'idle' && t > o.until) this.decide(o);
      if (o.act === 'home') {
        // called home: to the box's side, then a hop in (from wherever it got to, if that takes too long)
        const h = this.homeSpot(o);
        if (!h || t > o.until) return this.hopIn(o);
        o.tx = h.x; o.td = h.d;
      }
      if (o.act === 'walk' || o.act === 'go' || o.act === 'home') {
        const ex = o.tx - o.x, ed = o.td - o.depth, dist = Math.hypot(ex, ed);
        if (o.act === 'home' && dist < 3 * u) return this.hopIn(o);
        if (o.act === 'go' && dist < 2.5 * u && o.tuft) { o.act = 'eat'; o.bite = t + 0.8; o.flip = o.tuft.x < o.x; }
        else if (o.act !== 'home' && (dist < 2.5 * u || t > o.until || (o.act === 'go' && !o.tuft))) { this.letGo(o); o.act = 'idle'; o.until = t + 2 + R() * 4; }
        else {
          const v = (o.act === 'home' ? 30 : o.act === 'go' ? 19 : 13) * u * (cow ? 0.65 : 1) * Math.min(1, dist / (6 * u));
          wx = ex / dist * v; wd = ed / dist * v;
        }
      }
      if (o.act === 'eat') {
        const m = o.tuft;
        if (!m) { o.act = 'idle'; o.until = t + 1 + R() * 2; }
        else {
          head = 1;
          o.flip = m.x < o.x;
          if (m.left > 0 && t > o.bite && o.head > 0.85) this.bite(o, m);
        }
      }
    }
    o.head = lerp(o.head || 0, head, Math.min(1, dt * 4));
    // walk, in x and in depth (across the slope), as far as the hill allows
    const k = Math.min(1, dt * 3);
    o.vx = lerp(o.vx, wx, k); o.vd = lerp(o.vd, wd, k);
    if (o.act !== 'eat' && Math.abs(o.vx) > 2.5 * u) o.flip = o.vx < 0;
    const roomAt = (x, ry) => Math.min(g.H - 10 * u, this.shoreY(x) - 12 * u) - ry;
    const nx = o.x + o.vx * dt, ny = this.ridgeY(nx);
    if (ny == null || roomAt(nx, ny) < 3 * u || nx > g.W - 12 * u || (Math.abs(nx - g.lh.x) < g.lh.wB * 0.6 && o.depth < 30 * u)) o.vx = 0;
    else o.x = nx;
    const ry = this.ridgeY(o.x);
    if (ry == null) return;
    o.depth = clamp(o.depth + o.vd * dt, 3 * u, Math.max(3 * u, roomAt(o.x, ry)));
    o.y = o.ty = ry + o.depth;
    o.sc = this.depthScale(o.y);
  }
  // what next: grass if hungry and there's some free nearby, otherwise a short walk or a rest
  decide(o) {
    const t = this.t, R = Math.random, u = this.g.u;
    // standing where one of the section's little scenes now shows: out of its way first
    if (!this.open(o.x, o.y - 6 * u)) {
      const p = this.landSpot({ near: o, reach: 170 * u, min: 40 * u, gap: 34 * u, check: 1 });
      if (p) { o.act = 'walk'; o.tx = p.x; o.td = p.y - this.ridgeY(p.x); o.until = t + 14; return; }
    }
    if (t > o.hungry && this.feed(o)) return;
    if (R() < 0.5) {
      const p = this.landSpot({ near: o, reach: 100 * u, min: 30 * u, gap: 34 * u, check: 1 });
      if (p) { o.act = 'walk'; o.tx = p.x; o.td = p.y - this.ridgeY(p.x); o.until = t + 14; return; }
    }
    o.act = 'idle'; o.until = t + 2.5 + R() * 4.5;
    if (t > o.hungry) o.hungry = t + 3 + R() * 4; // nothing to eat in reach: look again in a bit
  }
  // the nearest free tuft in reach (grown, nobody else at it): walk over to stand with the mouth at it
  feed(o) {
    const g = this.g, u = g.u, reach = (o.kind === 'cow' ? 21 : 19) * u;
    // they graze in turns: a few at the grass at once, at most, so the hill stays calm
    const herd = this.objs.filter(q => grazer(q) && q.dying == null), busy = herd.filter(q => q.tuft).length;
    if (busy >= Math.min(3, Math.max(1, Math.round(herd.length * 0.4)))) return false;
    let best = null, bd = 320 * u;
    for (const m of this.meadow) {
      if (m.by || m.left <= 0 || this.t - m.t0 < 2.2) continue;
      const d = Math.hypot(m.x - o.x, (m.y - o.y) * 1.5);
      if (d < bd) { bd = d; best = m; }
    }
    if (!best) return false;
    const sc = this.depthScale(best.y);
    for (const f of best.x >= o.x ? [1, -1] : [-1, 1]) {
      const x = best.x - f * reach * sc, ry = this.ridgeY(x);
      if (ry == null || x > g.W - 14 * u) continue;
      const d = best.y - ry, room = Math.min(g.H - 10 * u, this.shoreY(x) - 12 * u) - ry;
      if (d < 3 * u || d > room || (Math.abs(x - g.lh.x) < g.lh.wB * 0.6 && d < 30 * u)) continue;
      // not where another animal already stands
      if (this.objs.some(q => q !== o && grazer(q) && Math.abs(q.x - x) < 30 * u * sc && Math.abs(q.y - best.y) < 14 * u * sc)) continue;
      best.by = o; o.tuft = best; o.act = 'go'; o.tx = x; o.td = d; o.until = this.t + 45;
      return true;
    }
    return false;
  }
  // a blade gone, the one nearest the mouth; every other bite, a "nom"
  bite(o, m) {
    const t = this.t, u = this.g.u, f = o.flip ? -1 : 1, mx = o.x + f * 20 * u * o.sc;
    let pick = null;
    for (const b of m.blades) if (b.cut == null && (!pick || Math.abs(m.x + b.dx - mx) < Math.abs(m.x + pick.dx - mx))) pick = b;
    if (pick) { pick.cut = t; m.left--; m.lastCut = t; }
    o.bite = t + (o.kind === 'cow' ? 1.3 : 1) + Math.random() * 0.35;
    if ((o.bites = (o.bites || 0) + 1) % 2 === 1) {
      const words = o.kind === 'cow' ? ['crunch', 'munch', 'crunch'] : ['nom', 'nom nom', 'munch'];
      this.doodle('munch', o.x + f * 23 * u * o.sc, o.y - 31 * u * o.sc, { text: words[((o.bites - 1) / 2 | 0) % 3], align: f > 0 ? 'left' : 'right', life: 1.15, calm: true });
    }
  }

  /* ----- the sheep in a box -----
     A cardboard box with three air holes sits on the grass where it's seen, clear of the lighthouse, the cottage,
     the little scenes and the animals. Now and then the sheep inside shifts and the box wobbles. When the light
     finds it, two eyes look out through the holes (glinting at night); a click or a tap makes it hop and say baa,
     louder each time, and the fifth in a row lets the sheep out: the flaps burst open, it jumps onto the grass and
     joins the others, and the box is empty. Knocking on the empty box calls the sheep home: it trots back and hops
     in. It isn't a surprise: clicking it drops nothing. Its label shows in the first screen while it's in view. */
  placeBox() {
    const g = this.g, u = g.u, W = g.W, b = this.box, T = g.lh, ck = g.cot;
    b.v = `${this.layoutV}|${this.fontsV}`;
    b.size = Math.max(13, 17 * u); b.tw = textW(this, 'a sheep (in a box)', b.size);
    // where its label mustn't go: the bar, the notes (a guess; the DOM has the last word), the key, the
    // lighthouse and its label, the cottage
    const noteX = W < 1024 ? W * 0.05 + Math.min(W * 0.58, 620) + 16 : g.note.x1 + 4;
    b.hard = [
      [0, 0, W, g.top + 8], g.portrait ? [0, g.note.y0 - 10, W, g.H] : [0, 0, noteX, g.H],
      [T.x - T.wB * 0.9, T.hatTop, T.x + T.wB * 0.9, T.base + 4 * u], [ck.x - ck.w * 0.7, ck.base - ck.h * 3, ck.x + ck.w * 0.7, ck.base + 4 * u],
      ...lighthouseLabelRects(this, textW(this, 'a lighthouse (stable)', b.size), b.size),
      ...(g.key ? [[g.key.x0, g.key.y0, g.key.x1, g.key.y1]] : []),
    ];
    // a spot on the grass where it's seen, away from the animals, the tufts and the window's edges, with room
    // for its label on the grass beside it
    b.gx = b.gy = null;
    const k = boxK(this);
    let first = null, pick = null;
    for (let i = 0; i < 14 && !pick; i++) {
      const p = this.landSpot({ gap: 56 * u, spread: i < 7, check: 3, snug: true, clear: true });
      if (!p) break;
      first ||= p;
      if (!g.portrait && (p.x < noteX + 60 * u || p.x > W * 0.9)) continue;
      if (this.boxSide({ x: p.x, y: p.y - BOX.hh * k, k })) pick = p;
    }
    if (pick ||= first) { b.gx = pick.x; b.gy = pick.y; }
    b.seenAt = -9; b.nextWob = this.t + 4 + Math.random() * 6;
  }
  // the box right now: standing on the grass, its wobble, and (unless `still`, as for its label) the hop with its squash
  boxAt(still) {
    const b = this.box, k = boxK(this), rm = this.reduced, t = this.t;
    let y = b.gy - BOX.hh * k, rot = 0, sq = 0;
    const w = t - b.wob;
    if (!rm && w >= 0 && w < 0.5) rot = Math.sin(w / 0.5 * Math.PI * 3) * 0.05 * (1 - w / 0.5);
    const a = still ? -1 : t - b.hop;
    const pa = t - b.burst;
    if (!rm && b.out != null && pa >= 0 && pa < 0.25) sq += Math.sin(pa / 0.25 * Math.PI) * 0.12;
    if (!rm && a >= 0 && a < 0.75) {
      if (a < 0.08) sq = Math.sin(a / 0.08 * Math.PI) * 0.1;
      else if (a < 0.52) { const f = (a - 0.08) / 0.44; y -= Math.sin(f * Math.PI) * 18 * k * b.hopK; rot -= Math.sin(f * Math.PI) * 0.14 * b.hopK; }
      else sq = Math.sin((a - 0.52) / 0.23 * Math.PI) * 0.14;
    }
    return { x: b.gx, y, rot, sq, k };
  }
  boxHit(x, y) {
    if (this.box.gx == null) return false;
    const p = this.boxAt(), k = p.k, pad = this.ptr.kind === 'touch' ? 14 : 7;
    return x > p.x - BOX.hw * k - pad && x < p.x + (BOX.hw + BOX.dx) * k + pad && y > p.y + (BOX.dy - BOX.hh) * k - pad && y < p.y + BOX.hh * k + pad;
  }
  // the cottage's door, with a little room round it
  doorHit(x, y) {
    const d = this.g.cot.door, pad = this.ptr.kind === 'touch' ? 10 : 5;
    return !!d && x > d.x - pad && x < d.x + d.w + pad && y > d.y - pad && y < d.y + d.h + pad;
  }
  // a knock: the door jumps and says so, a little more with each knock in a row; at the third the keeper comes to the
  // door (see VISIT and drawVisit), unless he's out on the ridge with his tile (nobody comes) or already at the open
  // door at night
  knock() {
    const k = this.g.cot, d = k.door, kn = this.knocks;
    if (this.visit) return;
    kn.n = this.t - kn.at < 2.5 ? kn.n + 1 : 1;
    kn.at = this.t;
    this.doodles = this.doodles.filter(o => o.kind !== 'knock');
    this.doodle('knock', k.x + k.w * 0.62, d.y + d.h * 0.3, { text: ['knock', 'knock knock', 'knock knock knock'][Math.min(kn.n, 3) - 1], align: 'left', life: 1.3 });
    if (kn.n < 3 || this.pres.install > 0.01) return;
    kn.n = 0;
    this.visit = { t0: this.t, away: this.pres.edit > 0.01, huh: false };
  }
  // a click or a tap: it hops (not without motion) and says so, higher and louder with each knock in a row
  baa() {
    const b = this.box;
    if (b.out != null) return this.callHome();
    b.knocks = this.t - b.knockAt < 2.5 ? b.knocks + 1 : 1;
    b.knockAt = this.t;
    if (b.knocks >= 5) return this.letOut();
    // it hops, unless it's still in the air from the knock before (a new hop there would drop it to the ground)
    if (!this.reduced && !this.boxUp()) { b.hop = this.t; b.hopK = 1 + 0.2 * (b.knocks - 1); }
    b.peek = this.t;
    this.boxSays(['baa!', 'baa!', 'baa!!', 'BAA!!'][b.knocks - 1]);
  }
  // in the air from a hop: how long until it lands, or 0
  boxUp() { const a = this.t - this.box.hop; return a >= 0 && a < 0.55 ? 0.55 - a : 0; }
  // beside it, toward the lighthouse, where the hop doesn't cover it; the newest word replaces the one before
  boxSays(text) {
    const p = this.boxAt(), k = p.k;
    this.doodles = this.doodles.filter(d => d.kind !== 'baa');
    this.doodle('baa', p.x + (BOX.hw + BOX.dx + 6) * k, p.y + (BOX.dy - BOX.hh + 1) * k, { text, align: 'left', life: 1.4 });
  }
  // the sheep is out of the box (or on its way out once the box has landed)
  boxEmpty() { return this.box.out != null && this.t >= this.box.burst; }
  // the fifth knock: once the box is on the ground, the flaps burst open and the sheep jumps out onto the grass a
  // short hop away
  letOut() {
    const b = this.box, g = this.g, u = g.u, p = this.boxAt(true), k = p.k, wait = this.reduced ? 0 : this.boxUp();
    b.out = this.t; b.burst = this.t + wait; b.knocks = 0; b.peek = -9; b.wob = -9;
    b.tw = textW(this, 'a box (empty)', b.size);
    // it lands beside the box, in the same row, on whichever side has grass (the pasture's first)
    const mid = p.x + BOX.dx * k * 0.5, reach = (BOX.hw + 34) * k;
    let spot = null;
    for (const dir of [1, -1]) for (const far of [1, 1.4, 0.8]) {
      const x = mid + dir * reach * far;
      if (!spot && x > 30 * u && x < g.W - 30 * u && this.ridgeY(x) != null && this.isLand(x, b.gy) && this.open(x, b.gy)) spot = { x, y: b.gy };
    }
    spot ||= { x: clamp(mid + reach, 30 * u, g.W - 30 * u), y: b.gy };
    const o = this.spawn(spot.x, spot.y, 'sheep', true);
    b.sheep = o;
    if (!this.reduced) {
      // from all the way down inside (the box is smaller than its sheep), up over the rim and down beside it
      const x0 = p.x + BOX.dx * k * 0.5;
      o.leap = { x0, y0: b.gy - 2 * BOX.hh * k + 30 * u * o.sc, x1: o.x, y1: o.ty, t0: b.burst, dur: 0.85, h: 58 * k };
      o.state = 'leap'; o.flip = o.x < x0; o.x = x0; o.y = o.leap.y0;
    }
    this.boxSays('baa!');
    this.wake();
  }
  // the empty box knocked on: its sheep comes home (or, gone from the hill, is simply back)
  callHome() {
    const b = this.box, o = b.sheep, u = this.g.u;
    if (!o || o.dead || o.dying != null || !this.objs.includes(o)) return this.closeBox();
    // without motion nobody walks: it's simply back in
    if (this.reduced) { this.letGo(o); o.dead = true; this.objs = this.objs.filter(q => q !== o); return this.closeBox(); }
    if (o.state === 'leap' || o.act === 'home') return;
    this.letGo(o);
    o.act = 'home'; o.until = this.t + 9;
    this.doodle('baa', o.x + 14 * u * o.sc, o.y - 34 * u * o.sc, { text: 'baa?', align: 'left', life: 1.2 });
    this.wake();
  }
  // where it goes to hop in: beside the box, on the side it comes from
  homeSpot(o) {
    const b = this.box, p = this.boxAt(true), k = p.k, mid = p.x + BOX.dx * k * 0.5;
    const x = mid + (o.x < mid ? -1 : 1) * (BOX.hw + 22) * k, ry = this.ridgeY(x);
    return ry == null || b.gx == null ? null : { x, d: b.gy - ry };
  }
  hopIn(o) {
    const b = this.box, p = this.boxAt(true), k = p.k;
    this.letGo(o);
    if (this.reduced || b.gx == null) { o.dead = true; this.closeBox(); return; }
    const x1 = p.x + BOX.dx * k * 0.5;
    o.leap = { x0: o.x, y0: o.y, x1, y1: b.gy - 2 * BOX.hh * k + 30 * this.g.u * o.sc, t0: this.t, dur: 0.7, h: 52 * k, in: true };
    o.state = 'leap'; o.act = 'idle'; o.flip = x1 < o.x; o.vx = o.vd = 0;
  }
  // the hop's end: on the grass, one of the flock now; or in the box, which closes over it
  endLeap(o) {
    const L = o.leap;
    o.leap = null;
    if (L.in) { o.dead = true; this.closeBox(); return; }
    o.x = L.x1; o.y = o.ty; o.state = 'land'; o.land = this.t; o.act = null;
  }
  closeBox() {
    const b = this.box;
    b.out = null; b.sheep = null; b.peek = this.t; b.wob = this.t;
    b.tw = textW(this, 'a sheep (in a box)', b.size);
    this.wake();
  }
  updateBox(dt) {
    const b = this.box, rm = this.reduced, t = this.t;
    // (the sheep's box is on the page's hill only)
    if (this.held || this.cur !== this.w0) return;
    if (b.v !== `${this.layoutV}|${this.fontsV}`) this.placeBox();
    if (b.gx == null) return;
    const p = this.boxAt(), lit = this.inBeam(p.x + this.ox, p.y + this.oy);
    b.lit = rm ? lit : lerp(b.lit, lit, Math.min(1, dt * 8));
    // the flaps: open while the sheep is out
    const lid = this.boxEmpty() ? 1 : 0;
    b.lid = rm ? lid : lerp(b.lid, lid, Math.min(1, dt * (lid ? 14 : 9)));
    if (Math.abs(b.lid - lid) < 0.005) b.lid = lid;
    // the eyes come to the holes while the light is on it (and for a moment after a baa), blinking now and then
    const want = b.out == null && (b.lit > 0.4 || t - b.peek < 1.8);
    if (want !== b.open) { b.open = want; b.openAt = t; b.nextBlink = t + 1.4 + Math.random() * 2; }
    if (b.open && !rm && t > b.nextBlink) { b.blinkAt = t; b.nextBlink = t + 1.8 + Math.random() * 2.6; }
    // now and then the sheep inside shifts
    if (!rm && t > b.nextWob) { if (b.out == null) b.wob = t; b.nextWob = t + 7 + Math.random() * 9; }
    // its label, in the first screen while it's in view: looked at a few times a second, faded in and out
    if (t - b.seenAt > 0.3 || rm) { b.seenAt = t; b.side = this.pres.hero > 0.01 ? this.boxSide(this.boxAt(true)) : null; if (b.side) b.lastSide = b.side; }
    b.la = rm ? (b.side ? 1 : 0) : lerp(b.la, b.side ? 1 : 0, Math.min(1, dt * 3));
  }
  // the side of the box its label fits on right now (right, into the pasture, first; then left or below), or null:
  // the box and the label in the window, on the grass, clear of what's in the way, and seen
  boxSide(p) {
    const g = this.g, u = g.u, W = g.W, k = p.k, hard = this.box.hard;
    const r = [p.x - BOX.hw * k - 3, p.y + (BOX.dy - BOX.hh) * k - 3, p.x + (BOX.hw + BOX.dx) * k + 3, p.y + BOX.hh * k + 3];
    if (r[0] < 6 || r[2] > W - 6 || hard.some(q => overlaps(r, q)) || !this.seen(p.x, p.y)) return null;
    for (const side of ['right', 'left', 'below']) {
      const q = boxLabel(p.x, p.y, k, u, this.box.size, this.box.tw, side);
      if (q.x0 < 6 || q.x1 > W - 6 || q.y1 > g.H - 6 || hard.some(h => overlaps([q.x0, q.y0, q.x1, q.y1], h))) continue;
      if (!this.isLand(q.x0 + 4, (q.y0 + q.y1) / 2) || !this.isLand(q.x1 - 4, (q.y0 + q.y1) / 2)) continue;
      if (this.seen((q.x0 + q.x1) / 2, (q.y0 + q.y1) / 2)) return side;
    }
    return null;
  }
  cloudXY(cl, raw) {
    const g = this.g;
    if (cl === g.sheepCloud) return { x: cl.x + (raw ? 0 : cl.ox), y: cl.y + (raw ? 0 : cl.oy) };
    const span = g.W + 360 * g.u;
    let x = (cl.x0 + this.drift * cl.sp * g.u) % span;
    if (x < 0) x += span;
    return { x: x - 180 * g.u + (raw ? 0 : cl.ox), y: cl.y + (raw ? 0 : cl.oy) };
  }
  sunPos() { const g = this.g, k = smooth(0, 0.62, this.d); return { x: g.sun.x, y: lerp(g.sun.y0, g.horizon + 30 * g.u, k), a: 1 - smooth(0.56, 0.66, this.d) }; }
  moonPos() { const g = this.g, k = smooth(0.58, 1, this.d); return { x: g.moon.x, y: lerp(g.horizon + 24 * g.u, g.moon.y1, k), a: smooth(0.56, 0.7, this.d) }; }
  waveY(x, row) {
    const g = this.g, t = this.t, u = g.u, ph = this.reduced ? 0 : t;
    let y = row.y + Math.sin(x * 0.011 / (0.35 + row.f) + ph * 1.15 + row.seed) * (0.5 + row.f * 2.4) * Math.max(u, 0.66) * (0.8 + 0.5 * Math.abs(this.windTotal));
    if (this.ptr.on && !this.reduced) {
      const dx = x - this.ptr.x, dy = (row.y - this.ptr.y) * 2.2, d2 = dx * dx + dy * dy, r = 150 * u;
      if (d2 < r * r) y += Math.sin(Math.sqrt(d2) * 0.085 / u - t * 6) * 5 * u * Math.exp(-d2 / (2 * 3600 * u * u));
    }
    for (const r of this.ripples) {
      const age = t - r.t0, rad = age * 150 * u, dx = x - r.x, dy = (row.y - r.y) * 2.4;
      const dist = Math.sqrt(dx * dx + dy * dy), band = Math.exp(-((dist - rad) ** 2) / (2 * (16 * u) ** 2));
      if (band > 0.01) y += Math.sin(dist * 0.1 / u - age * 9) * 6 * u * r.a * band * (1 - age / 2.8);
    }
    return y;
  }
  squash(o) { if (!(o.land > 0)) return 0; const a = this.t - o.land; return a < 0.3 ? Math.sin(a / 0.3 * Math.PI) * 0.28 * (1 - a / 0.3) : 0; }

  /* ----- drawing ----- */
  render() {
    const c = this.ctx, k = this.dpr, sw = this.swap;
    this.pstep = Math.round(this.d * STEPS);
    this.clock = this.t;
    NAP = this.drowsy() > 0.9;
    this.dress(this.shows);
    c.setTransform(k, 0, 0, k, 0, 0);
    c.globalAlpha = 1; c.globalCompositeOperation = 'source-over'; c.imageSmoothingQuality = 'high';
    this.page(() => this.style.before?.(this, c));
    DRAW.scene(this, c);
    c.setTransform(k, 0, 0, k, 0, 0);
    this.page(() => this.style.after?.(this, c));
    // a new style coming in: the old one where the light hasn't been yet (where it was to begin with, it has)
    const hw = this.g.beamHalf;
    if (sw && sw.a + hw < sw.a0 + TAU - hw) {
      const { x, y } = sw.L;
      c.save(); c.setTransform(1, 0, 0, 1, 0, 0);
      c.beginPath(); c.moveTo(x * k, y * k); c.arc(x * k, y * k, this.diag * 2 * k, sw.a + hw, sw.a0 + TAU - hw); c.closePath(); c.clip();
      c.drawImage(this.was.canvas, 0, 0);
      c.restore();
    }
    this.t = this.clock;
  }
  // draws in the page's theme; in a wipe (see update), in the old one outside its circle and in the new one inside it
  page(draw) {
    const w = this.wipe, c = this.ctx, B = this.back;
    if (!w) return draw();
    for (const out of [true, false]) {
      c.save(); c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      c.beginPath(); c.arc(B.W / 2, B.horizon, w.r, 0, TAU);
      if (out) c.rect(0, 0, B.W, B.H);
      c.clip('evenodd');
      if (!out) this.dress(w.to);
      draw();
      c.restore();
    }
    this.dress(this.shows);
  }
  /* Draws from here on in a theme's style (see STYLES): its levers in the pen's place, its palette at this hour, and
     its time */
  dress(id) {
    const st = this.style = STYLES[id], pw = this.g.pw;
    this.t = st.fps ? Math.floor(this.clock * st.fps) / st.fps : this.clock;
    this.boil = this.reduced || !st.boil ? 0 : Math.floor(this.t * st.boil) % 3;
    TINT = st.tint; C = st.C; HAND = st.hand; WEIGHT = st.weight; CAPS = st.caps; ribbon = st.ribbon; print = st.print; DRAW = st.draw;
    this.P = palAt(st.pal, this.pstep / STEPS);
    BOIL = this.boil; PW = pw * st.pen; INK = rgba(this.P.ink); REGX = st.reg[0] * pw; REGY = st.reg[1] * pw;
  }
  /* A cached layer: one per boil state, redrawn when the hour, the theme or the layout changes, or when it's
     wanted at another resolution (`res` times the screen's: islands far off are drawn small) */
  layer(c, name, rect, draw, res = 1) {
    const key = `${this.layoutV}|${this.pstep}|${this.style.id}|${this.fontsV}|${res}`;
    const L = (this.layers[name] ||= [])[this.boil] ||= { cv: document.createElement('canvas'), key: '' };
    const k = this.dpr * res, x0 = Math.floor(rect.x * k), y0 = Math.floor(rect.y * k), w = Math.ceil(rect.w * k), h = Math.ceil(rect.h * k);
    if (L.key !== key) {
      if (L.cv.width !== w || L.cv.height !== h) { L.cv.width = w; L.cv.height = h; }
      const x = L.cv.getContext('2d');
      x.setTransform(1, 0, 0, 1, 0, 0); x.clearRect(0, 0, w, h);
      x.setTransform(k, 0, 0, k, -x0, -y0);
      draw(x);
      this.style.cached?.(this, x);
      L.key = key;
      this.rebuilds++;
    }
    const m = c.getTransform();
    c.save(); c.setTransform(m.a / k, 0, 0, m.d / k, m.e, m.f); c.drawImage(L.cv, x0, y0); c.restore();
  }
  /* A small cached drawing (a cloud, the sun), drawn around its own origin */
  sprite(name, w, h, x, y, draw) {
    const key = `${name}|${this.style.id}|${this.layoutV}|${this.boil}|${this.pstep}|${this.fontsV}`, k = this.dpr;
    let s = this.sprites.get(key);
    if (!s) {
      const cv = document.createElement('canvas');
      cv.width = Math.ceil(w * k); cv.height = Math.ceil(h * k);
      const c = cv.getContext('2d');
      c.setTransform(k, 0, 0, k, w * k / 2, h * k / 2);
      draw(c);
      this.style.cached?.(this, c);
      s = { cv, w, h };
      this.sprites.set(key, s);
      if (this.sprites.size > 60) this.sprites.delete(this.sprites.keys().next().value);
    }
    const c = this.ctx;
    const m = c.getTransform();
    c.save(); c.setTransform(m.a / k, 0, 0, m.d / k, m.e, m.f);
    c.drawImage(s.cv, Math.round((x - w / 2) * k), Math.round((y - h / 2) * k));
    c.restore();
  }
}

/* =====================================================================
   THE DRAWING
   Back to front: sky and sea, the cached band, stars, the scallops, the
   beam, then the sun, moon, clouds and far island in front of it, the
   cached hill with its cottage and tower, then everything that moves.
   The far island is the first island of the dive, a whole one with its
   own far island, and so on: each island draws in two passes, its light
   behind the clouds and its land in front of them, the farthest first.
   Diving, you go on over the sea toward the horizon, past the islands.
   ===================================================================== */
function drawScene(s, c) {
  const g = s.g, { W, u } = g, shown = s.shown();
  c.lineCap = 'round'; c.lineJoin = 'round';
  // the page's sky and sea, the band cached in each theme it's in (see page)
  s.page(() => {
    DRAW.sky(s, c);
    const bandTop = g.horizon - (g.horizon - g.top) * (g.portrait ? 0.42 : 0.36) - 20 * u;
    s.layer(c, 'back' + s.style.id, { x: 0, y: bandTop, w: W, h: g.horizon - bandTop + 6 * u }, x => DRAW.band(s, x, bandTop));
    DRAW.stars(s, c);
    DRAW.waves(s, c);
    for (const w of shown) { s.enter(w); DRAW.ripples(s, c); }
    c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
    DRAW.sun(s, c);
    DRAW.moon(s, c);
  });
  // an island in a style, its theme's or the page's, and its ground in its theme's colours, as much darker than by day
  // as that style's green is now; the page's hill in the visitor's. Then the style it was drawing in again
  const wear = (w, id, draw) => {
    const was = s.style.id;
    s.dress(w.g.isle ? id : s.theme);
    if (w.g.isle) {
      const P = s.P, day = s.style.pal[0][1], [lit, shady] = w.g.ground;
      P.hill = lit.map((v, i) => v * P.hill[i] / day.hill[i]); P.hill2 = shady.map((v, i) => v * P.hill2[i] / day.hill2[i]);
    }
    draw();
    s.dress(was);
  };
  // an island in a style, laid over at `a`: when that's less than all of it, it's drawn whole on the side first
  const lay = (w, id, a) => {
    const x = a < 0.99 ? s.fade : c;
    if (x !== c) { x.setTransform(1, 0, 0, 1, 0, 0); x.clearRect(0, 0, x.canvas.width, x.canvas.height); x.lineCap = 'round'; x.lineJoin = 'round'; }
    s.enter(w); view(s, x, w.view);
    wear(w, id, () => DRAW.land(s, x, w));
    if (x !== c) { c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.globalAlpha = a; c.drawImage(x.canvas, 0, 0); c.restore(); }
  };
  // an island comes out of the haze far off. Seen from the page it's in the page's style, and as the dive begins its
  // own comes in over it (see OWN)
  const land = w => {
    const a = smooth(FAR, FAR * 1.6, w.view.s), k = w.g.isle ? smooth(0, OWN, s.dive) : 1;
    if (k < 1) lay(w, s.theme, a);
    if (k > 0) lay(w, w.g.theme, a * k);
  };
  // the islands far off, the light over them, the clouds, then the nearest island
  const near = shown.at(-1);
  for (const w of shown) if (w !== near) land(w);
  for (const w of shown) {
    const a = lightK(w.view.s);
    if (a > 0) { s.enter(w); view(s, c, w.view); wear(w, w.g.theme, () => { c.globalAlpha = a; DRAW.halo(s, c); c.globalAlpha = a; DRAW.beam(s, c); c.globalAlpha = 1; }); }
  }
  c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
  s.page(() => {
    for (let i = 0; i < g.clouds.length; i++) DRAW.cloud(s, c, g.clouds[i], 'cloud' + i);
    DRAW.cloud(s, c, g.sheepCloud, 'sheepcloud', true);
  });
  land(near);
  s.enter(s.focus());
}

/* Only the island being looked at has its light on: it comes on as the island comes close, and goes out as the
   island is passed, before it gets too much */
const lightK = sc => smooth(0.45, 0.9, sc) * (1 - smooth(1, 2.2, sc));

/* an island's land and what's on it, back to front */
function drawLand(s, c, w) {
  DRAW.front(s, c, w.view.s);
  c.globalAlpha = lightK(w.view.s); DRAW.hillLight(s, c); c.globalAlpha = 1;
  DRAW.tufts(s, c);
  DRAW.visit(s, c);
  DRAW.smoke(s, c);
  DRAW.eye(s, c);
  DRAW.hat(s, c);
  // animals and the grass on the hill, back to front (a tuft in front of the one eating it)
  const items = [...s.objs.map(o => [o.leap ? s.box.gy + 0.25 : o.y, o]), ...s.meadow.map(m => [m.y + 0.5, m]), ...(s.box.gx != null ? [[s.box.gy, s.box]] : [])].sort((a, b) => a[0] - b[0]);
  const wet = o => o.state === 'float' || o.state === 'swim' || (o.state === 'fall' && s.isSea(o.x, o.ty));
  for (const [, it] of items) {
    if (wet(it)) { c.save(); if (afloat(s, c, it.state === 'fall' ? it.ty : it.y)) DRAW.obj(s, c, it); c.restore(); }
    else it === s.box ? DRAW.box(s, c) : it.blades ? DRAW.meadow(s, c, it) : it.leap ? DRAW.leap(s, c, it) : DRAW.obj(s, c, it);
  }
  // the section's little scenes over them, on the page's hill: animals pass behind the desk, the huts and the keeper
  if (w === s.w0) {
    DRAW.states(s, c);
    const lk = s.labelsK();
    if (s.pres.hero > 0.01 && lk > 0.01 && !s.dive) { c.globalAlpha = lk; DRAW.labels(s, c); c.globalAlpha = 1; }
  }
  DRAW.splashes(s, c);
  DRAW.ball(s, c);
  DRAW.doodles(s, c);
}

/* the hill with its cottage and tower: cached at about the size it's drawn (an island's in each style it's drawn in),
   or drawn as it is when larger than life */
function drawFront(s, c, sc) {
  const g = s.g, { W, H, u } = g, T = g.lh, x0 = g.shore ? g.ridge[0][0] - 8 : Math.max(0, g.ridge[0][0] - 10);
  const x1 = Math.min(W, g.ridge.at(-1)[0] + 8), y0 = Math.min(T.top - T.gal * 1.2, g.cot.base - g.cot.h * 4.2) - 10 * u;
  const y1 = g.shore ? Math.max(...g.shore.map(p => p[1])) + 26 * u : H;
  const draw = x => { DRAW.hill(s, x); DRAW.cottage(s, x); DRAW.tower(s, x); };
  if (sc > 1) draw(c);
  else s.layer(c, 'front' + (g.theme ? g.theme + s.style.id : ''), { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, draw, 2 ** Math.ceil(Math.log2(sc)));
}

/* draws from here on in an island's coordinates: screen = s * point + (x, y) */
function view(s, c, v) {
  const k = s.dpr;
  c.setTransform(k * v.s, 0, 0, k * v.s, k * v.x, k * v.y);
}
/* Something on the sea at y by the island being drawn isn't as far off as the island: it's as deep into the sea as on
   the page (see waveScallops), and as much further as the island is, so it comes on faster. Draws from here on where
   it is, unless it has gone past. */
function afloat(s, c, y) {
  const g = s.g, at = (g.H - g.horizon) / (y - g.horizon), d = at + (1 / s.cur.view.s - 1) / SHORE;
  if (d < 0.2) return false;
  const m = at / d;
  view(s, c, { s: m, x: g.W / 2 * (1 - m), y: g.horizon * (1 - m) });
  return true;
}

/* the sky and the sea, flat */
function drawSky(s, c) {
  const g = s.g, P = s.P;
  c.fillStyle = rgba(P.sky); c.fillRect(0, 0, g.W, g.horizon + 2);
  c.fillStyle = rgba(P.sea); c.fillRect(0, g.horizon, g.W, g.H - g.horizon);
}

/* the lower sky, a lighter band with a soft wave at its top, and the horizon */
function drawBand(s, c, bandTop) {
  const g = s.g, { W, u } = g, P = s.P;
  const by = bandTop + 20 * u, band = [];
  for (let x = -30; x <= W + 30; x += 16 * u) band.push([x, by + Math.sin(x * 0.006 + 1) * 11 * u + Math.sin(x * 0.019 + 2) * 3 * u]);
  band.push([W + 30, g.horizon + 4], [-30, g.horizon + 4]);
  poly(c, band); c.fillStyle = rgba(P.sky2); c.fill();
  c.beginPath(); ribbon(c, dens([[-10, g.horizon], [W + 10, g.horizon]], 8), DET, 2, { amp: 0.6, tin: 1, tout: 1, w0: 1, w1: 1 }); c.fillStyle = INK; c.fill();
}

function drawStars(s, c) {
  const g = s.g, u = g.u, st = smooth(0.55, 0.9, s.d);
  if (st <= 0) return;
  c.beginPath();
  for (const p of g.stars) {
    if (p.s < 0.75) continue;
    const r = p.s * 2.7 * u * (s.reduced ? 1 : 0.78 + 0.22 * Math.sin(s.t * 2 + p.p));
    for (let k = 0; k < 3; k++) {
      const a = k / 3 * Math.PI + p.p + BOIL * 0.07;
      ribbon(c, [[p.x - Math.cos(a) * r, p.y - Math.sin(a) * r], [p.x + Math.cos(a) * r, p.y + Math.sin(a) * r]], 1.7, k, { amp: 0.15, tin: 1, tout: 1, w0: 0.7, w1: 0.6 });
    }
  }
  c.fillStyle = rgba(s.P.beam, st); c.fill();
  // and a few small dots between them
  c.fillStyle = rgba(s.P.beam, st * 0.8);
  for (const p of g.stars) if (p.s < 0.75) { c.beginPath(); c.arc(p.x, p.y, 0.9 * u + 0.4, 0, TAU); c.fill(); }
}

/* a fried-egg sun that sets into the sea, behind the far island */
function drawSun(s, c) {
  const g = s.g, u = g.u, sun = s.sunPos();
  if (sun.a <= 0) return;
  const r = 38 * u, sz = r * 3;
  c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip();
  c.globalAlpha = sun.a;
  s.sprite('sun', sz, sz, sun.x, sun.y, x => {
    const white = [];
    for (let i = 0; i < 48; i++) { const a = i / 48 * TAU; white.push([Math.cos(a) * r * (1 + 0.12 * Math.sin(a * 3 + 1) + 0.06 * Math.sin(a * 5 + 2)), Math.sin(a) * r * 0.86 * (1 + 0.09 * Math.sin(a * 4))]); }
    shape(x, dens(white, 4, true), mul(hex('#FFFFFF'), s.P.paper), DET, 5);
    const yolk = ellipse(3 * u, -3 * u, r * 0.42, r * 0.4, 30);
    shape(x, yolk, C.yolk, DET * 0.9, 7);
    // the shine on the yolk
    x.beginPath(); ribbon(x, ellipse(3 * u, -3 * u, r * 0.27, r * 0.25, 10, Math.PI * 1.1, Math.PI * 1.55), TEX * 1.3, 3, { tin: 2, tout: 2 }); x.fillStyle = '#FFFFFF'; x.fill();
    dot(x, 3 * u - r * 0.12, -3 * u - r * 0.27, 1.3 * u + 0.4, '#FFFFFF');
  });
  c.restore();
}

/* a crescent moon, asleep, with a z */
function drawMoon(s, c) {
  const g = s.g, u = g.u, m = s.moonPos();
  if (m.a <= 0) return;
  const r = 25 * u, sz = r * 3.4;
  c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip();
  c.globalAlpha = m.a;
  s.sprite('moon', sz, sz, m.x, m.y, x => {
    const cres = [];
    for (let i = 0; i <= 26; i++) { const a = -Math.PI / 2 + i / 26 * Math.PI; cres.push([Math.cos(a) * r, Math.sin(a) * r]); }
    for (let i = 25; i >= 1; i--) { const a = -Math.PI / 2 + i / 26 * Math.PI; cres.push([Math.cos(a) * r * 0.38 + r * 0.02, Math.sin(a) * r * 0.97]); }
    shape(x, dens(cres, 3, true), C.moon, DET, 11);
    // a closed eye with lashes, and a small smile
    x.beginPath();
    ribbon(x, ellipse(r * 0.62, -r * 0.2, r * 0.17, r * 0.11, 9, 0.15 * Math.PI, 0.85 * Math.PI), TEX * 1.2, 2, { tin: 2, tout: 2 });
    for (const k of [0.3, 0.5, 0.7]) { const a = k * Math.PI, ex = r * 0.62 + Math.cos(a) * r * 0.17, ey = -r * 0.2 + Math.sin(a) * r * 0.11; ribbon(x, [[ex, ey], [ex + Math.cos(a) * 3 * u, ey + Math.sin(a) * 3 * u]], TEX, k * 9, { tin: 1, tout: 1 }); }
    ribbon(x, ellipse(r * 0.52, r * 0.3, r * 0.15, r * 0.1, 9, 0.2 * Math.PI, 0.8 * Math.PI), TEX * 1.1, 4, { tin: 2, tout: 2 });
    x.fillStyle = INK; x.fill();
  });
  c.restore();
  {
    const zz = s.reduced ? 0.4 : (s.t * 0.4) % 1, col = rgba(mix(s.P.paper, s.P.beam, 0.3), m.a * (1 - zz) * 0.95);
    label(c, 'z', m.x + r * 1.1 + zz * 10 * u, m.y - r * 0.7 - zz * 16 * u, (11 + zz * 5) * u + 3, col, 'left', -0.2);
  }
}

function drawCloud(s, c, cl, name, legs) {
  const g = s.g, u = g.u, P = s.P, p = s.cloudXY(cl), w = cl.w;
  if (p.x < -w || p.x > g.W + w) return;
  if (legs) {
    // four legs, walking when it walks
    const walk = s.reduced ? 0 : s.t * 5;
    c.beginPath();
    const feet = [];
    [-0.24, -0.11, 0.1, 0.23].forEach((lx, i) => {
      const x = p.x + lx * w * (cl.dir < 0 ? -1 : 1), sw = Math.sin(walk + i * 1.7 + (i % 2) * Math.PI) * 2.6 * u;
      ribbon(c, [[x, p.y - 4 * u], [x + sw * 0.5, p.y + 5 * u], [x + sw, p.y + 12 * u]], DET * 1.25, i * 3, { tin: 2, tout: 2, w0: 0.9, w1: 0.9 });
      feet.push([x + sw, p.y + 13 * u]);
    });
    c.fillStyle = INK; c.fill();
    for (const [fx, fy] of feet) { c.beginPath(); c.ellipse(fx + 0.6 * u, fy, 2.6 * u, 1.9 * u, 0, 0, TAU); c.fill(); }
  }
  const sz = w * 1.3;
  s.sprite(name + (legs && cl.dir < 0 ? 'L' : ''), sz, w * 0.75, p.x, p.y - w * 0.12, x => {
    const top = cloudPts(0, w * 0.12, w, cl.seed);
    const pts = dens(top, 5, true);
    print(x, pts, P.cloud);
    x.beginPath();
    loop(x, pts, DET, cl.seed % 13);
    // a curl or two of puff inside, drawn lightly
    const R = rng(cl.seed + 5);
    for (let i = 0; i < 2; i++) {
      const cx = (R() - 0.5) * w * 0.5, cy = w * 0.02 - R() * w * 0.06, rr = w * (0.07 + R() * 0.05);
      ribbon(x, ellipse(cx, cy, rr, rr * 0.8, 10, Math.PI * 1.05, Math.PI * 1.75), TEX, i + 3, { tin: 2, tout: 3 });
    }
    x.fillStyle = INK; x.fill();
    if (legs) {
      // a tail, and the hint of an ear: it might be a sheep
      const f = cl.dir < 0 ? -1 : 1;
      x.beginPath();
      ribbon(x, [[-f * w * 0.5, w * 0.02], [-f * w * 0.57, -w * 0.03], [-f * w * 0.6, w * 0.03]], TEX, 4, { tin: 2, tout: 2 });
      x.fillStyle = INK; x.fill();
    }
  });
}

/* the sheep's box: kraft cardboard, a strip of tape over the flaps, three air holes; while the light is on
   it, eyes in two of them that look at the lamp, blink, and glint at night */
function drawBox(s, c) {
  const b = s.box;
  if (b.gx == null) return;
  const g = s.g, P = s.P, p = s.boxAt(), k = p.k, t = s.t, rm = s.reduced, { hw, hh, dx, dy } = BOX;
  const night = smooth(0.5, 0.9, s.d), card = col => mix(mul(col, P.paper), P.sky, 0.2 * night);
  c.save(); c.translate(p.x, p.y + hh * k); c.rotate(p.rot); c.scale(1 + p.sq * 0.6, 1 - p.sq); c.translate(0, -hh * k);
  const K = q => q.map(([x, y]) => [x * k, y * k]);
  const front = K([[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]]);
  const top = K([[-hw, -hh], [-hw + dx, -hh + dy], [hw + dx, -hh + dy], [hw, -hh]]);
  const side = K([[hw, -hh], [hw + dx, -hh + dy], [hw + dx, hh + dy], [hw, hh]]);
  // with the sheep out the flaps stand open, up from the sides, over the dark inside
  const lid = b.lid, th = lid * 1.95, flaps = [];
  print(c, side, card(C.kraftDark)); print(c, top, lid > 0.01 ? mix(card(C.kraftDark), P.ink, 0.4) : card(C.kraftLit)); print(c, front, card(C.kraft));
  if (lid > 0.01) for (const sd of [-1, 1]) {
    const hx = sd * hw, wx = -sd * hw * Math.cos(th), wy = -hw * Math.sin(th);
    const flap = K([[hx, -hh], [hx + dx, -hh + dy], [hx + dx + wx, -hh + dy + wy], [hx + wx, -hh + wy]]);
    print(c, flap, card(sd < 0 ? C.kraftLit : C.kraft));
    flaps.push(flap);
  } else {
    // tape over the seam between the flaps, front to back, folded a little way down the front
    c.globalAlpha = 0.8;
    print(c, K([[-3.4, -hh], [-3.4 + dx, -hh + dy], [3.4 + dx, -hh + dy], [3.4, -hh], [3.6, -hh + 6.5], [0.4, -hh + 5.8], [-3.6, -hh + 6.8]]), card(C.tape));
    c.globalAlpha = 1;
  }
  // the holes, dark; eyes in two of them while the light is on the box (or just after a baa)
  let open = b.open ? (rm ? 1 : smooth(0, 0.2, t - b.openAt)) : (rm ? 0 : 1 - smooth(0, 0.14, t - b.openAt));
  if (b.open && !rm && t - b.blinkAt < 0.16) open *= Math.abs(Math.cos((t - b.blinkAt) / 0.16 * Math.PI));
  const L = s.g.lamp, look = Math.atan2(L.y - p.y, L.x - p.x), r = 3.4 * k;
  BOX.holes.forEach(([hx, hy], i) => {
    const x = hx * k, y = hy * k;
    dot(c, x, y, r, mix(P.ink, C.kraftDark, 0.18));
    if (i > 1 || open < 0.04) return;
    const ew = r * 0.8, eh = r * 0.8 * open;
    c.beginPath(); c.ellipse(x, y + (1 - open) * r * 0.3, ew, Math.max(0.3, eh), 0, 0, TAU); c.fillStyle = rgba(mix(hex('#FFFFFF'), P.beam, 0.4 * night)); c.fill();
    c.save(); c.clip();
    const px = x + Math.cos(look) * r * 0.32, py = y + Math.sin(look) * r * 0.28;
    dot(c, px, py, r * 0.44, INK);
    dot(c, px - r * 0.16, py - r * 0.2, r * 0.15 + 0.25, '#FFFFFF');
    c.restore();
  });
  // the pen: the outline in one weight, the edges inside lighter, a ring round each hole, and this side up
  c.beginPath();
  edges(c, K([[-hw, hh], [-hw, -hh], [-hw + dx, -hh + dy], [hw + dx, -hh + dy], [hw + dx, hh + dy], [hw, hh]]), DET * 1.05, 3, true, { ov: 1.5 });
  edges(c, K([[-hw, -hh], [hw, -hh], [hw, hh]]), TEX * 1.25, 9, false, { ov: 0.8 });
  edges(c, K([[hw, -hh], [hw + dx, -hh + dy]]), TEX * 1.25, 12, false, { ov: 0.6 });
  flaps.forEach((f, i) => edges(c, f, TEX * 1.25, 40 + i, true, { ov: 0.8 }));
  BOX.holes.forEach(([hx, hy], i) => ribbon(c, ellipse(hx * k, hy * k, r, r, 12, i), TEX, 30 + i, { tin: 1, tout: 1, w0: 1, w1: 1, amp: 0.2, outline: true }));
  for (const ax of [hw + dx * 0.32, hw + dx * 0.7]) {
    const x = ax * k, y0 = (dy * (ax - hw) / dx + 6) * k, y1 = y0 - 7 * k;
    ribbon(c, [[x, y0], [x, y1]], TEX * 0.9, ax, { tin: 1, tout: 1, w0: 0.8, w1: 0.8, amp: 0.1 });
    ribbon(c, [[x - 1.7 * k, y1 + 2.4 * k], [x, y1], [x + 1.7 * k, y1 + 2.4 * k]], TEX * 0.9, ax + 1, { tin: 1, tout: 1, w0: 0.8, w1: 0.8, amp: 0.1 });
  }
  c.fillStyle = INK; c.fill();
  // and at night the eyes glint, a little star at each
  if (open > 0.3 && night > 0.05) {
    c.beginPath();
    for (let i = 0; i < 2; i++) {
      const [hx, hy] = BOX.holes[i], x = hx * k + r * 0.95, y = hy * k - r * 1.05, l = (1.4 + 1.2 * night) * k * open;
      for (const an of [0.2, 0.2 + Math.PI / 2]) ribbon(c, [[x - Math.cos(an) * l, y - Math.sin(an) * l], [x + Math.cos(an) * l, y + Math.sin(an) * l]], TEX * 0.9, i * 2 + an, { tin: 1, tout: 1, w0: 0.5, w1: 0.5, amp: 0.1 });
    }
    c.fillStyle = rgba(P.beam, clamp(night * open * 1.3)); c.fill();
  }
  c.restore();
}

/* a sheep hopping out of its box or back in: in front of the box, and hidden by its front while inside it */
function drawLeap(s, c, o) {
  if (s.t < o.leap.t0) return;
  const L = o.leap, f = clamp((s.t - L.t0) / L.dur), p = s.boxAt(), k = p.k;
  const inside = Math.abs(o.x - (p.x + BOX.dx * k * 0.5)) < BOX.hw * k && (L.in ? f > 0.5 : f < 0.5);
  if (!inside) { DRAW.obj(s, c, o); return; }
  c.save(); c.beginPath(); c.rect(-1e4, -1e4, 2e4, 1e4 + p.y - BOX.hh * k + 1); c.clip();
  DRAW.obj(s, c, o);
  c.restore();
}

/* the sea: scallops on the water as it goes off to the horizon, in rows, closer together and sparser the farther off;
   ripples where things land. Diving, you go over it toward the horizon, as fast as past the islands (an island's shore
   is about a quarter of the way down the sea), and rows and scallops come in between the others as they come close and spread. */
const rank = n => n ? 31 - Math.clz32(n & -n) : 32;
function waveScallops(s, c, lit) {
  const g = s.g, { W, H, u } = g, hz = g.horizon, sea = H - hz, mid = W / 2;
  // depths in rows ROW apart from where you are, 1 at the bottom of the screen; across, scallops ACROSS apart there
  const ROW = 0.02, ACROSS = 4, go = s.dive * DIVE_GAP / SHORE, far = lit ? 0.004 : 0.0175, alpha = c.globalAlpha;
  for (let k = Math.ceil((1 + go) / ROW); ;) {
    const rel = 1 / (k * ROW - go);
    if (rel < far) break;
    // the gap between rows here on the page, and the rows that keep it: the ones `step` apart, those of the finest
    // of them fading in
    const f = rel ** (1 / 1.6), gap = 3.2 * sea * rel ** 0.375 / g.rows, dy = sea * ROW * rel * rel;
    const step = 2 ** Math.max(0, Math.ceil(Math.log2(gap / dy)));
    if (k % step) { k += step - k % step; continue; }
    const a = rank(k) > Math.log2(step) ? 1 : clamp(dy * step / gap - 1);
    k += step;
    if (a <= 0) continue;
    const row = { y: hz + sea * rel, f, seed: (k - step) * 97 + s.o.seed }, q0 = k - step;
    const size = (16 + 34 * f) * Math.max(u, 0.66), across = ACROSS * rel, room = size * 1.7;
    const qs = 2 ** Math.max(0, Math.ceil(Math.log2(room / across))), qa = clamp(across * qs / room - 1);
    const off = hash(q0 * 0.13) * 64 * across;
    c.lineWidth = (0.75 + 1.3 * f) * g.pw * (lit ? 1.15 : 1);
    for (const fading of [false, true]) {
      c.beginPath();
      for (let q = Math.floor((-8 - mid - off) / across / qs) * qs; mid + off + q * across < W + 8 + size; q += qs) {
        if ((rank(Math.abs(q)) === Math.log2(qs)) !== fading || hash(q * 0.37 + q0 * 3.1) < 0.3 - f * 0.12) continue;
        const x = mid + off + q * across - size / 2, y = s.waveY(x, row), y2 = s.waveY(x + size, row);
        c.moveTo(x, y); c.quadraticCurveTo(x + size / 2, (y + y2) / 2 - size * 0.34, x + size, y2);
      }
      c.globalAlpha = alpha * a * (fading ? qa : 1); c.stroke();
    }
  }
  c.globalAlpha = alpha;
}
function drawWaves(s, c) {
  c.strokeStyle = rgba(s.P.sea2); waveScallops(s, c, false);
}
function drawRipples(s, c) {
  const u = s.g.u, P = s.P;
  for (const r of s.ripples) {
    if (!afloat(s, c, r.y)) continue;
    const age = s.t - r.t0, rx = 8 * u + age * 70 * u;
    c.beginPath(); ribbon(c, ellipse(r.x, r.y, rx, rx * 0.3, 40), DET * 0.8, 4, { tin: 1, tout: 1, w0: 1, w1: 1 });
    c.fillStyle = rgba(P.foam, clamp(1 - age / 2.2) * r.a); c.fill();
  }
}

/* the light: a flat yellow fan with felt-pen edges, brighter at night (fainter, pen and all, while it's weak) */
function beamPoly(s) {
  const L = s.g.lamp, B = s.beam, len = B.len * s.diag * 1.05, hw = s.g.beamHalf;
  return { L, len, a0: B.a - hw, a1: B.a + hw };
}
function drawBeam(s, c) {
  const g = s.g, u = g.u, P = s.P, I = s.beamI(), pw = s.lampPower(), { L, len, a0, a1 } = beamPoly(s);
  if (len < 10 || pw < 0.02) return;
  const night = smooth(0.3, 0.8, s.d);
  const e0 = [L.x + Math.cos(a0) * len, L.y + Math.sin(a0) * len], e1 = [L.x + Math.cos(a1) * len, L.y + Math.sin(a1) * len];
  const fan = [[L.x, L.y], e0];
  for (let i = 1; i < 12; i++) { const a = lerp(a0, a1, i / 12); fan.push([L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]); }
  fan.push(e1);
  const col = mix(P.beam, hex('#FFF6C2'), night * 0.45);
  poly(c, fan); c.fillStyle = rgba(col, (0.84 + 0.12 * night * I) * pw); c.fill();
  // the scallops it crosses light up (the sea's, on the screen)
  c.save(); poly(c, fan); c.clip(); c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
  c.strokeStyle = rgba(mix(col, hex('#FFFFFF'), 0.5), 0.95 * pw); waveScallops(s, c, true);
  c.restore();
  // the pen goes along both edges, from just outside the eye
  const r0 = g.lh.er * 2.3;
  c.beginPath();
  for (const [a, sd] of [[a0, 13], [a1, 17]]) ribbon(c, dens([[L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0], [L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]], 9), DET * 0.95, sd, { tin: 20, tout: 1, w0: 0.2, w1: 1 });
  if (s.beam.len < 0.85) ribbon(c, dens(fan.slice(1), 6), DET * 0.9, 19, { tin: 3, tout: 3 });
  c.globalAlpha = 0.3 + 0.7 * pw; c.fillStyle = INK; c.fill(); c.globalAlpha = 1;
}

/* where the light lands on the hill: a flat, lighter print on the grass */
function drawHillLight(s, c) {
  const { L, len, a0, a1 } = beamPoly(s);
  if (len < 10 || Math.sin(s.beam.a) < 0.08) return;
  const night = smooth(0.3, 0.8, s.d);
  c.save(); poly(c, s.g.hillClip); c.clip();
  c.beginPath(); c.moveTo(L.x, L.y);
  for (let i = 0; i <= 12; i++) { const a = lerp(a0, a1, i / 12); c.lineTo(L.x + Math.cos(a) * len, L.y + Math.sin(a) * len); }
  c.closePath(); c.fillStyle = rgba(mix(s.P.hill, s.P.beam, (0.5 + 0.2 * night) * s.lampPower())); c.fill();
  c.restore();
}

/* the lamp's halo at night: hand-drawn rings and short rays, no blur */
function drawHalo(s, c) {
  const g = s.g, u = g.u, P = s.P, L = g.lamp, er = g.lh.er;
  const night = smooth(0.35, 0.85, s.d), f = s.beam.flash, k = Math.max(night * s.beamI(), f * 0.9) * s.lampOn() * s.lampPower();
  if (k < 0.02) return;
  const r1 = er * (2.1 + f * 0.6), r2 = er * (3 + f * 1.4);
  // the lit lantern: a flat disc of light just around the eye
  c.globalAlpha = clamp(k * 1.4);
  print(c, ellipse(L.x, L.y, er * 1.75, er * 1.6, 30), mix(P.beam, hex('#FFFFFF'), 0.25));
  c.globalAlpha = 1;
  c.beginPath();
  ribbon(c, ellipse(L.x, L.y, r1, r1, 30, 0.3, TAU - 0.2), TEX, 7, { tin: 4, tout: 6 });
  ribbon(c, ellipse(L.x, L.y, r2, r2, 40, 1.4, TAU + 0.6), TEX, 9, { tin: 4, tout: 8 });
  const spin = s.reduced ? 0 : s.t * 0.25;
  for (let i = 0; i < 14; i++) {
    const a = i / 14 * TAU + spin + (i % 2) * 0.12, a1 = r2 * (1.15 + (i % 3) * 0.06), a2 = r2 * (1.42 + (i % 2) * 0.22 + f * 0.5);
    ribbon(c, [[L.x + Math.cos(a) * a1, L.y + Math.sin(a) * a1], [L.x + Math.cos(a) * a2, L.y + Math.sin(a) * a2]], TEX, i, { tin: 1, tout: 2, w0: 0.7 });
  }
  c.fillStyle = rgba(P.beam, clamp(k * 1.1)); c.fill();
}

/* the hill: printed green, a shaded flank, the ridge in the heaviest line, a few hatches and flowers */
function drawHill(s, c) {
  const g = s.g, { W, H, u } = g, P = s.P, T = g.lh, rd = g.ridge;
  // an island sits in the water: under its shore, the hill's darker reflection, a few strokes of water across it
  if (g.isle) {
    const sl = g.shore, x0 = sl[0][0], x1 = sl.at(-1)[0], deep = x => Math.sin(Math.PI * (x - x0) / (x1 - x0)) * 18 * u, R = rng(3);
    print(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x, y + deep(x)])], mix(P.sea, P.hill2, 0.45));
    c.beginPath();
    for (let j = 0; j < 4; j++) for (let x = x0 + R() * 30 * u; x < x1 - 20 * u; x += (24 + R() * 30) * u) {
      const y = s.shoreY(x) + deep(x) * (0.25 + j * 0.27) + 2 * u;
      c.moveTo(x, y); c.lineTo(x + (6 + R() * 12) * u * (1 - j * 0.15), y);
    }
    c.strokeStyle = rgba(P.sea2); c.lineWidth = 1.3 * g.pw; c.stroke();
  }
  print(c, g.hillPoly, P.hill);
  // the shady flank, a second flat green
  const sh = [];
  for (const [x, y] of rd) if (x < T.x - T.wB * 2) sh.push([x, y]);
  if (g.shore) {
    // under the headland, a darker band of cliff above the shore
    const sl = g.shore, x0 = sl[0][0];
    print(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x + 4 * u, y - (8 + (x - x0) / W * 26) * u])], P.hill2);
  } else {
    // it narrows to nothing near the top, so it reads as the hill turning away from the light
    const n = sh.length, inner = sh.map(([x, y], i) => { const f = smooth(0, 0.35, (n - 1 - i) / n); return [x + (34 + (H - y) * 0.12) * u * f, y + (16 + (H - y) * 0.05) * u * f]; }).reverse();
    print(c, [...sh, ...inner], P.hill2);
  }
  // hatching on the shady side: a few short groups, lightest line
  c.beginPath();
  const R = rng(5);
  const groups = g.portrait ? 7 : 11;
  for (let i = 0; i < groups; i++) {
    const fx = R(), x = g.portrait ? lerp(rd[0][0] + 20 * u, T.x - T.wB * 3, fx) : lerp(rd[0][0] + 30 * u, T.x - T.wB * 2.2, fx);
    const ry = s.ridgeY(x);
    if (ry == null) continue;
    const y = ry + (14 + R() * (g.portrait ? 26 : 70)) * u;
    if (g.shore && y > s.shoreY(x) - 12 * u) continue;
    const n = 3 + ((R() * 3) | 0), l = (13 + R() * 10) * u;
    for (let k = 0; k < n; k++) {
      const hx = x + k * 5 * u, hy = y + k * 1.6 * u, lk = l * (1 - Math.abs(k - (n - 1) / 2) * 0.16);
      ribbon(c, [[hx, hy], [hx + lk * 0.42, hy + lk]], TEX, i * 5 + k, { tin: 3, tout: 5, w0: 0.45, w1: 0.2, amp: 0.4, hatch: true });
    }
  }
  c.fillStyle = INK; c.fill();
  // foam where the hill meets the sea
  c.beginPath();
  const foam = g.shore || rd.filter(p => p[1] > g.horizon + 3 && p[0] < T.x);
  for (let i = 2; i < foam.length - 2; i += 3) {
    const [x, y] = foam[i], [x2, y2] = foam[i + 2], nx = g.shore ? 0 : -1, ny = g.shore ? 1 : 0;
    const ox = nx * 5 * u, oy = ny * 5 * u, mx = (x + x2) / 2 + ox, my = (y + y2) / 2 + oy;
    if (mx < -10 || mx > W + 10 || my > H + 10 || hash(i * 0.7) < 0.3) continue;
    ribbon(c, [[x + ox, y + oy], [mx + nx * 2 * u - (g.shore ? 0 : 1) * u, my + (g.shore ? 3 : -2) * u], [x2 + ox, y2 + oy]], TEX * 1.1, i, { tin: 1, tout: 1, amp: 0.3 });
  }
  c.fillStyle = rgba(P.foam); c.fill();
  // the ridge, and the shore under it if it has one
  c.beginPath();
  ribbon(c, rd.filter(p => p[0] > -20 && p[0] < W + 20), SIL, 21, { tin: 4, tout: 4, w0: 0.8, w1: 0.8, outline: true });
  if (g.shore) ribbon(c, g.shore.filter(p => p[0] < W + 20), SIL * 0.9, 23, { tin: 30, tout: 4, w0: 0.3, w1: 0.8, outline: true });
  c.fillStyle = INK; c.fill();
  // daisies near the cottage and the tower, where the eye goes
  const D = rng(9);
  for (let i = 0; i < (g.portrait ? 6 : 11); i++) {
    const x = lerp(T.x - T.h * 0.42, Math.min(W - 10, g.cot.x + g.cot.w * 1.6), D()), ry = s.ridgeY(x);
    if (ry == null || Math.abs(x - T.x) < T.wB * 0.8 || Math.abs(x - g.cot.x) < g.cot.w * 0.6) { D(); continue; }
    const y = ry + (8 + D() * (g.portrait ? 20 : 46)) * u, r = 2.2 * u;
    for (let k = 0; k < 5; k++) { const a = k / 5 * TAU; dot(c, x + Math.cos(a) * r + REGX * 0.5, y + Math.sin(a) * r + REGY * 0.5, 1.5 * u, mul(hex('#FFFFFF'), P.paper)); }
    dot(c, x + REGX * 0.5, y + REGY * 0.5, 1.4 * u, C.yolk);
  }
}

function drawCottage(s, c) {
  const g = s.g, u = g.u, P = s.P, k = g.cot, w = k.w, h = k.h, x0 = k.x - w / 2, y0 = k.base - h;
  const paper = mul(hex('#FFFFFF'), P.paper), night = smooth(0.45, 0.75, s.d);
  // the chimney, a little crooked
  const chx = x0 + w * 0.68, chw = w * 0.15, cht = y0 - h * 1.45;
  const chim = [[chx, y0 - h * 0.2], [chx + 1.2 * u, cht], [chx + chw + 1.6 * u, cht], [chx + chw, y0 - h * 0.25]];
  print(c, chim, mul(C.chimney, P.paper));
  c.beginPath(); edges(c, chim, DET, 3, false);
  ribbon(c, dens([[chx - 1.5 * u, cht + 3 * u], [chx + chw + 3 * u, cht + 2.5 * u]], 4), DET * 1.15, 4, { tin: 2, tout: 2 });
  c.fillStyle = INK; c.fill();
  // walls
  const wall = [[x0, k.base], [x0, y0], [x0 + w, y0], [x0 + w, k.base]];
  print(c, wall, paper);
  // the roof, inked solid as felt-pen fills are
  const roof = [[x0 - w * 0.12, y0 + 1 * u], [x0 + w * 0.5, y0 - h * 0.78], [x0 + w * 1.12, y0 + 1 * u]];
  poly(c, roof); c.fillStyle = rgba(C.roof); c.fill();
  c.beginPath(); edges(c, roof, DET * 1.1, 6, true); edges(c, wall, SIL * 0.85, 8, false); c.fillStyle = INK; c.fill();
  // the window: four panes, lit at night
  const wx = x0 + w * 0.14, wy = y0 + h * 0.24, ww = w * 0.27, wh = h * 0.36;
  print(c, [[wx, wy], [wx + ww, wy], [wx + ww, wy + wh], [wx, wy + wh]], night > 0.5 ? P.beam : P.glass);
  c.beginPath(); edges(c, [[wx, wy], [wx + ww, wy], [wx + ww, wy + wh], [wx, wy + wh]], DET * 0.85, 11, true, { ov: 1.2 });
  ribbon(c, [[wx + ww / 2, wy + 1], [wx + ww / 2, wy + wh - 1]], TEX, 12, { tin: 1, tout: 1, w0: 0.8, w1: 0.8 });
  ribbon(c, [[wx + 1, wy + wh / 2], [wx + ww - 1, wy + wh / 2]], TEX, 13, { tin: 1, tout: 1, w0: 0.8, w1: 0.8 });
  c.fillStyle = INK; c.fill();
  // the door (it opens for the keeper: see the states and drawVisit)
  const dx = x0 + w * 0.56, dw = w * 0.24, dh = h * 0.66;
  k.door = { x: dx, y: k.base - dh, w: dw, h: dh };
  drawDoor(s, c);
}

/* the cottage's door, hinged on its right: shut, or swung out (open 1: against the wall), and moved by a knock (jig).
   Shut and still it's the one drawn with the cottage, so the knocks and the keeper's visit draw it the same way. Its
   handle is on the outside: it goes with the door as it opens, out of sight once the door is past square */
function drawDoor(s, c, open = 0, jig = 0) {
  const u = s.g.u, k = s.g.cot, d = k.door, hx = d.x + d.w + jig, fx = lerp(d.x, d.x + d.w * 1.55, open) + jig;
  const door = [[fx, k.base - 1 * u * open], [fx, d.y + 2 * u * open], [hx, d.y], [hx, k.base]];
  print(c, door, mul(C.door, s.P.paper));
  c.beginPath(); edges(c, door, DET * 0.85, 14, false, { ov: 1 }); c.fillStyle = INK; c.fill();
  if (hx - fx > 3 * u) dot(c, lerp(fx, hx, 0.78), k.base - d.h * 0.48, 1.3 * u + 0.4, INK);
}

/* the tower: white with curved stripes in the theme's colours, a door, two windows and a gallery */
function drawTower(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, th = THEMES[g.theme || s.theme];
  const paper = mul(hex('#FFFFFF'), P.paper);
  const half = k => lerp(T.wB, T.wT, k) / 2, yAt = k => T.base - T.h * k;
  const Lp = [], Rp = [];
  for (let i = 0; i <= 20; i++) { const k = i / 20; Lp.push([T.x - half(k), yAt(k)]); Rp.push([T.x + half(k), yAt(k)]); }
  const body = [...Lp, ...Rp.slice().reverse()];
  print(c, body, paper);
  // stripes, seen from below: their edges curve up a little
  const bands = 6, sag = T.wB * 0.09;
  const edge = k => { const hw = half(k), out = []; for (let i = 0; i <= 12; i++) { const f = i / 12 * 2 - 1; out.push([T.x + f * hw, yAt(k) - sag * (1 - f * f)]); } return out; };
  let n = 0;
  for (let j = 1; j < bands; j += 2) {
    const k0 = j / bands, k1 = (j + 1) / bands;
    const lo = edge(k0), hi = j + 1 >= bands ? [[T.x + half(1), yAt(1)], [T.x - half(1), yAt(1)]] : edge(k1).reverse();
    const col = hex(th.stripes[n++ % th.stripes.length]);
    print(c, [...lo, ...hi], mul(col, P.paper));
  }
  // windows and the door
  const win = (k, w, h) => { const y = yAt(k); return [[T.x - w / 2, y - h / 2], [T.x + w / 2, y - h / 2], [T.x + w / 2, y + h / 2], [T.x - w / 2, y + h / 2]]; };
  const night = smooth(0.45, 0.75, s.d);
  const glass = night > 0.5 ? P.beam : rgba(C.roof);
  for (const k of [0.25, 0.58]) { const q = win(k, T.wB * 0.22, T.er * 0.75); poly(c, q); c.fillStyle = typeof glass === 'string' ? glass : rgba(glass); c.fill(); }
  const dw = T.wB * 0.32, dh = T.wB * 0.5, dpts = [[T.x - dw / 2, T.base], ...ellipse(T.x, T.base - dh + dw / 2, dw / 2, dw / 2, 10, Math.PI, TAU).map(p => p), [T.x + dw / 2, T.base]];
  poly(c, dpts); c.fillStyle = rgba(C.roof); c.fill();
  // the outline: two sides and the base, then a few stripe edges and hatches on the shady side
  c.beginPath();
  ribbon(c, dens([[T.x - T.wB / 2 - 1 * u, T.base + 3 * u], [T.x - T.wT / 2, T.top - 1 * u]], 6), SIL, 31, { tin: 6, tout: 4, w0: 0.7, w1: 0.6, outline: true });
  ribbon(c, dens([[T.x + T.wB / 2 + 0.5 * u, T.base + 2 * u], [T.x + T.wT / 2, T.top - 1 * u]], 6), SIL, 33, { tin: 6, tout: 4, w0: 0.7, w1: 0.6, outline: true });
  for (let j = 1; j < bands; j++) {
    const e = edge(j / bands), cut = Math.round(e.length * (0.55 + hash(j) * 0.35));
    ribbon(c, j % 2 ? e.slice(0, cut) : e.slice(e.length - cut), TEX, 40 + j, { tin: 2, tout: 8, w0: 0.6, w1: 0.1 });
  }
  for (let j = 0; j < bands; j++) {
    const k = (j + 0.5) / bands, x = T.x + half(k) - 2.6 * u, y = yAt(k);
    for (let i = 0; i < 3; i++) ribbon(c, [[x - i * 3 * u, y - T.h / bands * 0.32], [x - i * 3 * u - 0.6 * u, y + T.h / bands * 0.3 - i * 2 * u]], TEX * 0.85, j * 3 + i, { tin: 2, tout: 2, amp: 0.3, hatch: true });
  }
  for (const k of [0.25, 0.58]) edges(c, win(k, T.wB * 0.22, T.er * 0.75), TEX, 50 + k * 10, true, { ov: 0.6 });
  ribbon(c, dpts, DET * 0.9, 61, { tin: 2, tout: 2, outline: true });
  c.fillStyle = INK; c.fill();
  // the gallery: a dark deck the eye sits on
  const gw = T.wT * 0.95, gy = T.top;
  const deck = [[T.x - gw, gy + 1 * u], [T.x - gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.05, gy - T.gal * 0.42], [T.x + gw, gy + 1 * u]];
  poly(c, deck); c.fillStyle = INK; c.fill();
}

/* the eye in the lantern: an iris the colour of the light, a pupil that follows the beam (or the ball), a lid.
   It also squints when up to something, goes wide when caught, shuts happily when it got away with it, and squeezes
   shut, trembling, when it strains to light its lamp. */
function drawEye(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, L = g.lamp, er = T.er, B = s.beam;
  const night = smooth(0.35, 0.8, s.d), md = s.mood() || {}, wide = md.wide || 0, sq = md.squint || 0, strain = md.strain || 0;
  const rx = er * 1.32 * (1 + 0.13 * wide), ry = er * 1.08 * (1 + 0.16 * wide);
  const eye = ellipse(L.x, L.y, rx, ry, 40);
  c.save(); c.translate(Math.sin(s.t * 97) * 1.1 * u * strain, 0);
  print(c, eye, mix(mul(hex('#FFFFFF'), P.paper), P.beam, night * 0.25));
  // where it looks: along the beam, or straight at you when the light faces you, or wherever it's busy
  let look = clamp(B.len * 1.3) * (1 - B.flash), pa = B.a;
  if (md.a != null) { pa = md.a; look = md.m; }
  const px = L.x + Math.cos(pa) * rx * 0.42 * look, py = L.y + Math.sin(pa) * ry * 0.36 * look;
  const ir = er * (0.62 + 0.12 * B.flash) * (1 - 0.2 * wide), pr = er * (0.3 - 0.08 * night + 0.1 * B.flash) * (1 - 0.42 * wide);
  c.save(); poly(c, eye, true, REGX, REGY); c.clip();
  dot(c, px + REGX, py + REGY, ir, mix(P.beam, C.iris, 0.35 - 0.2 * night));
  c.restore();
  c.save(); poly(c, eye); c.clip();
  dot(c, px, py, pr, INK);
  dot(c, px - pr * 0.45, py - pr * 0.5, pr * 0.38 + 0.4, '#FFFFFF');
  c.beginPath(); ribbon(c, ellipse(px, py, ir, ir, 22), TEX, 3, { tin: 1, tout: 1, w0: 1, w1: 1, amp: 0.3, outline: true }); c.fillStyle = INK; c.fill();
  // the lid: a little heavy by day, wide awake at night, shut when it blinks or winks
  const bl = s.t - s.blink.at, wk = s.t - s.blink.wink;
  let shut = lerp(lerp(0.2, 0.02, night), 0, wide);
  if (md.shut) shut = Math.max(shut, md.shut);
  shut = Math.max(shut, 0.5 * sq);
  if (bl < 0.18 && !s.bore) shut = Math.max(shut, Math.sin(bl / 0.18 * Math.PI));
  if (wk < 0.6) shut = Math.max(shut, wk < 0.1 ? wk / 0.1 : wk < 0.45 ? 1 : 1 - (wk - 0.45) / 0.15);
  if (s.reduced && wk >= 0.6) shut = lerp(0.2, 0.02, night);
  shut = Math.max(shut, s.drowsy());
  const lidCol = rgba(mul(hex('#FFFFFF'), P.paper));
  if (md.happy) {
    // shut, and pleased with itself: the lid line curves up
    poly(c, eye); c.fillStyle = lidCol; c.fill();
    c.beginPath(); ribbon(c, ellipse(L.x, L.y + ry * 0.38, rx * 0.72, ry * 0.62, 16, 1.18 * Math.PI, 1.82 * Math.PI), DET, 5, { tin: 3, tout: 3 }); c.fillStyle = INK; c.fill();
  } else if (shut > 0.86 && strain > 0.5) {
    // squeezed shut, straining: a tight, crumpled line
    poly(c, eye); c.fillStyle = lidCol; c.fill();
    c.beginPath();
    ribbon(c, [[-0.88, 0.02], [-0.44, 0.13], [0, 0.03], [0.44, 0.13], [0.88, 0.02]].map(([x, y]) => [L.x + x * rx, L.y + y * ry]), DET, 5, { tin: 3, tout: 3 });
    c.fillStyle = INK; c.fill();
  } else if (shut > 0.86) {
    poly(c, eye); c.fillStyle = lidCol; c.fill();
    c.beginPath();
    ribbon(c, ellipse(L.x, L.y - ry * 0.35, rx * 0.78, ry * 0.55, 16, 0.2 * Math.PI, 0.8 * Math.PI), DET, 5, { tin: 3, tout: 3 });
    for (const k of [0.32, 0.5, 0.68]) { const a = k * Math.PI, ex = L.x + Math.cos(a) * rx * 0.78, ey = L.y - ry * 0.35 + Math.sin(a) * ry * 0.55; ribbon(c, [[ex, ey], [ex + Math.cos(a) * er * 0.35, ey + Math.sin(a) * er * 0.35]], TEX, k * 9, { tin: 1, tout: 1 }); }
    c.fillStyle = INK; c.fill();
  } else if (shut > 0.01) {
    const ly = L.y - ry + shut * ry * 1.2, lid = [];
    for (let i = 0; i <= 24; i++) { const a = Math.PI + i / 24 * Math.PI; lid.push([L.x + Math.cos(a) * (rx + 2), L.y + Math.sin(a) * (ry + 2)]); }
    for (let i = 0; i <= 16; i++) { const f = 1 - i / 16, x = L.x - rx + f * 2 * rx; lid.push([x, ly + (1 - ((x - L.x) / rx) ** 2) * ry * 0.22 * shut]); }
    poly(c, lid); c.fillStyle = lidCol; c.fill();
    c.beginPath(); ribbon(c, lid.slice(25), DET, 5, { tin: 3, tout: 3 }); c.fillStyle = INK; c.fill();
  }
  if (sq > 0.01 && !md.happy) {
    // squinting: the lower lid comes up too
    const ly = L.y + ry - sq * ry * 0.62, lid = [];
    for (let i = 0; i <= 24; i++) { const a = i / 24 * Math.PI; lid.push([L.x + Math.cos(a) * (rx + 2), L.y + Math.sin(a) * (ry + 2)]); }
    for (let i = 0; i <= 16; i++) { const x = L.x - rx + i / 16 * 2 * rx; lid.push([x, ly - (1 - ((x - L.x) / rx) ** 2) * ry * 0.16 * sq]); }
    poly(c, lid); c.fillStyle = lidCol; c.fill();
    c.beginPath(); ribbon(c, lid.slice(25), TEX * 1.2, 6, { tin: 3, tout: 3 }); c.fillStyle = INK; c.fill();
  }
  c.restore();
  c.beginPath(); loop(c, eye, SIL * 0.85, 8); c.fillStyle = INK; c.fill();
  // caught: a start, in a few short strokes either side (the same strokes when it strains)
  const marks = Math.max(wide, strain);
  if (marks > 0.05) {
    c.beginPath();
    for (const sx of [-1, 1]) for (const k of [-0.42, 0, 0.42]) {
      const a = (sx < 0 ? Math.PI : 0) + sx * k, r0 = rx * 1.22, r1 = r0 + er * 0.55 * marks;
      ribbon(c, [[L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0 * 0.9], [L.x + Math.cos(a) * r1, L.y + Math.sin(a) * r1 * 0.9]], TEX * 1.1, 20 + k * 7 + sx, { tin: 1, tout: 2 });
    }
    c.fillStyle = INK; c.fill();
  }
  c.restore();
  // the gallery's railing passes in front of the eye
  const gw = T.wT * 0.95, top = T.top - T.gal * 0.42, rail = top - T.gal * 0.62;
  c.beginPath();
  ribbon(c, dens([[L.x - gw * 1.08, rail], [L.x + gw * 1.08, rail]], 4), DET * 0.9, 9, { tin: 2, tout: 2, w0: 0.8, w1: 0.8 });
  for (let i = 0; i <= 6; i++) { const x = L.x - gw + i / 6 * gw * 2; ribbon(c, [[x, top], [x, rail]], TEX * 0.95, 70 + i, { tin: 1, tout: 1, w0: 0.9, w1: 0.9, amp: 0.2 }); }
  c.fillStyle = INK; c.fill();
}

/* The hat right now: where its brim sits and where the cone's tip and the bobble are. It lifts and
   flops when it heads the ball (the ball game reads the bobble's place from here too). */
function hatGeom(s) {
  const g = s.g, L = g.lamp, er = g.lh.er, ry = er * 1.08, ka = s.t - s.hatKick, kicked = !s.reduced && ka >= 0 && ka < 0.7;
  const lift = kicked && ka < 0.3 ? Math.sin(ka / 0.3 * Math.PI) * er * 0.34 : 0;
  const flop = kicked ? Math.sin(ka * 19) * Math.exp(-ka * 6) * 0.34 : 0;
  const sway = s.reduced ? 0.15 : 0.15 + s.windTotal * 0.25 + Math.sin(s.t * 1.3) * 0.05 + flop;
  const by = L.y - ry * 0.62 - lift, pr = er * 0.66;
  const tip = [L.x + er * (0.5 + sway * 2.2), by - er * 3.1 + Math.abs(sway) * er * 0.6];
  return { by, bw: er * 1.5, bh: er * 0.62, sway, tip, pr, bob: [tip[0], tip[1] - pr * 0.6] };
}
/* a pom-pom: a scribbled ball of wool, turning with `spin` */
function bobble(c, x, y, pr, col, spin = 0) {
  const pb = [];
  for (let i = 0; i < 40; i++) { const a = i / 40 * TAU, r = pr * (1 + 0.09 * Math.abs(Math.sin((a - spin) * 5.5 + 1))); pb.push([x + Math.cos(a) * r, y + Math.sin(a) * r]); }
  shape(c, pb, col, DET * 0.95, 16);
  const cs = Math.cos(spin), sn = Math.sin(spin), ox = pr * 0.1, oy = pr * 0.1;
  c.beginPath(); ribbon(c, ellipse(x + ox * cs - oy * sn, y + ox * sn + oy * cs, pr * 0.42, pr * 0.36, 8, 0.2 + spin, 1.9 + spin), TEX * 0.8, 90, { tin: 1, tout: 2 }); c.fillStyle = INK; c.fill();
}

/* a knitted pom-pom hat: a ribbed brim, a long floppy cone in the theme's colour, a white bobble */
function drawHat(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, L = g.lamp, er = T.er, th = THEMES[g.theme || s.theme];
  const col = mul(hex(th.hat), P.paper), h = hatGeom(s), { by, bw, bh, sway, tip, pr } = h;
  const cone = curve([[L.x - bw * 0.92, by - bh * 0.6], [L.x - bw * 0.5, by - er * 1.9], [L.x + er * 0.1 + sway * er, by - er * 2.85], tip, [L.x + er * 0.65 + sway * er * 1.4, by - er * 2.2], [L.x + bw * 0.9, by - bh * 0.6]], 3);
  print(c, cone, col);
  // a white knitted stripe across the cone
  c.save(); poly(c, cone, true, REGX, REGY); c.clip();
  const sy = by - er * 1.55;
  c.beginPath(); c.moveTo(L.x - bw * 2, sy + er * 0.25); c.quadraticCurveTo(L.x, sy - er * 0.05, L.x + bw * 2, sy + er * 0.2); c.lineTo(L.x + bw * 2, sy - er * 0.25); c.quadraticCurveTo(L.x, sy - er * 0.55, L.x - bw * 2, sy - er * 0.25); c.closePath();
  c.fillStyle = rgba(mul(hex('#FFFFFF'), P.paper)); c.fill();
  c.restore();
  const brim = [[L.x - bw, by + bh * 0.45], [L.x - bw * 1.02, by - bh * 0.55], [L.x + bw * 1.02, by - bh * 0.6], [L.x + bw, by + bh * 0.5]];
  print(c, brim, mix(col, hex('#000000'), 0.12));
  c.beginPath();
  loop(c, cone, DET * 1.05, 14, { over: 0.05 });
  edges(c, brim, DET, 15, true, { ov: 1.2 });
  for (let i = 1; i < 7; i++) { const x = L.x - bw + i / 7 * bw * 2; ribbon(c, [[x, by - bh * 0.4], [x + 0.4 * u, by + bh * 0.32]], TEX * 0.8, 80 + i, { tin: 1, tout: 1, amp: 0.2 }); }
  c.fillStyle = INK; c.fill();
  // the bobble, unless it's in play; then a few loose ends of wool, until a new one grows back with a pop
  const k = s.bobbleK();
  if (k < 0.999) {
    c.beginPath();
    for (const a of [-2.3, -1.6, -0.9]) ribbon(c, [[tip[0], tip[1]], [tip[0] + Math.cos(a) * pr * 0.55, tip[1] + Math.sin(a) * pr * 0.55]], TEX, a * 3, { tin: 1, tout: 2 });
    c.fillStyle = INK; c.fill();
  }
  if (k > 0.02) bobble(c, tip[0], tip[1] - pr * 0.6 * k, pr * k, mul(hex('#FFFFFF'), P.paper));
  const ra = s.t - s.regrowAt;
  if (ra > 0.18 && ra < 0.75 && !s.reduced) {
    const f = (ra - 0.18) / 0.57, cx = tip[0], cy = tip[1] - pr * 0.6;
    c.beginPath();
    for (let i = 0; i < 6; i++) { const a = -Math.PI / 2 + (i - 2.5) * 0.62, r0 = pr * (1.35 + f * 0.9), r1 = r0 + pr * 0.55 * (1 - f * 0.6); ribbon(c, [[cx + Math.cos(a) * r0, cy + Math.sin(a) * r0], [cx + Math.cos(a) * r1, cy + Math.sin(a) * r1]], TEX, i, { tin: 1, tout: 1 }); }
    c.fillStyle = rgba(P.ink, 1 - f); c.fill();
  }
}

/* grass along the ridge, leaning with the wind and away from the pointer */
function drawTufts(s, c) {
  const g = s.g, u = g.u;
  c.beginPath();
  for (const b of g.tufts) {
    let a = s.reduced ? 0.12 : Math.sin(s.t * 1.6 + b.p) * 0.14 * (0.6 + s.windAmb) + s.windTotal * 0.36;
    if (s.ptr.on && !s.reduced) {
      const dx = b.x - s.ptr.x, dy = b.y - s.ptr.y, r = 95 * u, d2 = dx * dx + dy * dy;
      if (d2 < r * r) a += Math.sign(dx || 1) * 1.05 * (1 - Math.sqrt(d2) / r);
    }
    a = clamp(a, -1.3, 1.3);
    for (let k = 0; k < b.n + 1; k++) {
      const da = (k - b.n / 2) * 0.42, l = b.l * (k === 1 ? 1.15 : 0.85), x = b.x + (k - b.n / 2) * 1.6 * u, y = b.y + 1.5 * u;
      const tx = x + Math.sin(a + da) * l, ty = y - Math.cos(a + da) * l, w = 1.1 * g.pw;
      c.moveTo(x - w, y); c.quadraticCurveTo(lerp(x, tx, 0.5) - w * 0.4, lerp(y, ty, 0.55), tx, ty); c.quadraticCurveTo(lerp(x, tx, 0.5) + w * 0.4, lerp(y, ty, 0.55), x + w, y); c.closePath();
    }
  }
  c.fillStyle = INK; c.fill();
}

/* a tuft of fresh grass on the hill: blades that rise out of the ground one after another, lean with the wind
   and away from the pointer, part for an animal walking through, and go one by one when something eats them */
function drawMeadow(s, c, m) {
  const g = s.g, u = g.u, P = s.P, t = s.t, rm = s.reduced, age = t - m.t0;
  // a section's props stand in front of the grass (the huts, the desk)
  let alpha = 1;
  if (s.pres.tiling > 0.01) for (const q of hutSpots(s)) if (Math.abs(m.x - q.x) < 34 * u && m.y > q.y - 64 * u && m.y < q.y + 8 * u) alpha = Math.min(alpha, 1 - s.pres.tiling);
  if (s.pres.widgets > 0.01) { const d = deskSpot(s); if (Math.abs(m.x - d.x) < 56 * u && m.y > d.y - 100 * u && m.y < d.y + 8 * u) alpha = Math.min(alpha, 1 - s.pres.widgets); }
  if (alpha <= 0.01) return;
  // the lean: the wind and its gusts, away from the pointer, apart for a passer-by, toward the mouth eating it
  let a = rm ? 0.12 : Math.sin(t * 1.6 + m.ph) * 0.14 * (0.6 + s.windAmb) + s.windTotal * 0.36;
  if (!rm) {
    if (s.ptr.on) { const dx = m.x - s.ptr.x, dy = m.y - 6 * u - s.ptr.y, r = 95 * u, d2 = dx * dx + dy * dy; if (d2 < r * r) a += Math.sign(dx || 1) * 1.05 * (1 - Math.sqrt(d2) / r); }
    for (const o of s.objs) {
      if (!grazer(o) || o === m.by || o.state !== 'land') continue;
      const dx = m.x - o.x, w = 19 * u * o.sc;
      if (Math.abs(dx) < w && Math.abs(m.y - o.y) < 9 * u * o.sc) a += Math.sign(dx || 1) * 0.95 * (1 - Math.abs(dx) / w);
    }
    const e = m.by;
    if (e && e.act === 'eat') a += (e.flip ? 1 : -1) * (0.2 + 0.16 * Math.sin(t * 9 + e.seed)) * e.head;
  }
  const blades = [];
  for (const b of m.blades) {
    const gk = rm ? 1 : pop((age - b.d) / 0.75), ck = b.cut == null ? 1 : 1 - clamp((t - b.cut) / 0.4) ** 2;
    if (gk <= 0.02 || ck <= 0.03) continue;
    const L = b.l * gk * ck, th = clamp(b.a + a * b.flex, -1.45, 1.45), bx = m.x + b.dx, by = m.y + 1.2 * u;
    const mx = bx + Math.sin(th * 0.4 + b.a * 0.3) * L * 0.55, my = by - Math.cos(th * 0.4) * L * 0.55, tx = bx + Math.sin(th) * L, ty = by - Math.cos(th) * L;
    const pts = [];
    for (let i = 0; i <= 6; i++) { const q = i / 6, r = 1 - q; pts.push([r * r * bx + 2 * r * q * mx + q * q * tx, r * r * by + 2 * r * q * my + q * q * ty]); }
    blades.push({ pts, w: (3.9 + 0.6 * ck) * u * m.sc, L, gk: clamp(gk) });
  }
  if (!blades.length) return;
  c.save(); c.globalAlpha = alpha;
  // the green, printed off the line
  const night = smooth(0.4, 0.9, s.d);
  c.beginPath();
  for (const { pts, w } of blades) {
    const l = [], r = [], n = pts.length - 1;
    for (let i = 0; i <= n; i++) {
      const p0 = pts[Math.max(0, i - 1)], p1 = pts[Math.min(n, i + 1)], dx = p1[0] - p0[0], dy = p1[1] - p0[1], dl = Math.hypot(dx, dy) || 1, hw = w * (1 - i / n) * 0.5 + 0.25;
      l.push([pts[i][0] - dy / dl * hw + REGX, pts[i][1] + dx / dl * hw + REGY]); r.push([pts[i][0] + dy / dl * hw + REGX, pts[i][1] - dx / dl * hw + REGY]);
    }
    const ring = [...l, ...r.reverse()];
    c.moveTo(ring[0][0], ring[0][1]);
    for (const p of ring) c.lineTo(p[0], p[1]);
    c.closePath();
  }
  c.fillStyle = rgba(mix(P.hill2, C.sprout, 0.85 * (1 - night))); c.fill();
  // the pen: one stroke a blade, and a little ground under the tuft that grows and goes with it
  c.beginPath();
  blades.forEach(({ pts, L }, i) => ribbon(c, pts, TEX * (L > 6 * u ? 0.8 : 0.65), m.ph * 3 + i, { tin: 1, tout: 6, w0: 0.9, w1: 0.12, amp: 0.25 }));
  const gw = 9 * u * m.sc * Math.min(1, Math.max(...blades.map(b => b.gk)) * 1.4) * Math.max(0.4, blades.length / m.blades.length);
  ribbon(c, [[m.x - gw, m.y + 2.2 * u], [m.x - gw * 0.3, m.y + 1 * u], [m.x + gw * 0.4, m.y + 1.2 * u], [m.x + gw, m.y + 2.4 * u]], TEX, m.ph, { tin: 2, tout: 3, amp: 0.3 });
  c.fillStyle = INK; c.fill();
  c.restore();
}

function drawSmoke(s, c) {
  if (s.reduced) return;
  const g = s.g, u = g.u, k = g.cot, x0 = k.x - k.w / 2 + k.w * 0.68 + k.w * 0.075, y0 = k.base - k.h - k.h * 1.5;
  c.beginPath();
  for (let i = 0; i < 3; i++) {
    const a = (s.t * 0.22 + i / 3) % 1, sx = x0 + s.windTotal * 50 * u * a + Math.sin(a * 6 + i) * 3 * u, sy = y0 - 6 * u - a * 46 * u, r = (2.5 + a * 6) * u;
    const sp = [];
    for (let k2 = 0; k2 <= 16; k2++) { const an = k2 / 16 * TAU * 1.35 + i, rr = r * (0.25 + k2 / 16 * 0.75); sp.push([sx + Math.cos(an) * rr, sy + Math.sin(an) * rr]); }
    ribbon(c, sp, TEX * (1 - a * 0.4), i, { tin: 3, tout: 6 });
  }
  c.fillStyle = rgba(s.P.ink, 0.85); c.fill();
}

/* ---------- scene states: one dry gag per section, drawn where it's seen ---------- */
function drawStates(s, c) {
  const p = s.pres;
  if (p.themes > 0.01) DRAW.washing(s, c, p.themes);
  if (p.tiling > 0.01) DRAW.huts(s, c, p.tiling);
  if (p.widgets > 0.01) DRAW.desk(s, c, p.widgets);
  if (p.install > 0.01) DRAW.doorway(s, c, p.install);
  if (p.edit > 0.01) DRAW.editKeeper(s, c, p.edit);
}
/* pops a prop in from the ground: scale with a little overshoot */
const pop = p => { const t = clamp(p); return t < 1 ? 1 - Math.pow(1 - t, 3) * Math.cos(t * 4.2) : 1; };

function drawKeeper(s, c, x, y, sc, pose, flip, walk) {
  const u = s.g.u * sc, P = s.P, f = flip ? -1 : 1;
  const navy = mul(C.navy, P.paper), skin = mul(C.skin, P.paper), white = mul(hex('#FFFFFF'), P.paper);
  c.save(); c.translate(x, y); c.scale(f, 1);
  // legs
  const st = Math.sin(walk) * 0.45;
  c.beginPath();
  ribbon(c, [[-2 * u, -12 * u], [-2 * u + Math.sin(st) * 9 * u, 0]], DET * 1.5, 1, { tin: 1, tout: 1, w0: 1, w1: 1 });
  ribbon(c, [[2 * u, -12 * u], [2 * u - Math.sin(st) * 9 * u, 0]], DET * 1.5, 2, { tin: 1, tout: 1, w0: 1, w1: 1 });
  c.fillStyle = rgba(navy); c.fill();
  // boots
  dot(c, -2 * u + Math.sin(st) * 9 * u + 1.5 * u, -0.5 * u, 2.2 * u, INK); dot(c, 2 * u - Math.sin(st) * 9 * u + 1.5 * u, -0.5 * u, 2.2 * u, INK);
  // a striped jumper
  const body = [[-5.5 * u, -11 * u], [-6 * u, -24 * u], [6 * u, -24 * u], [5.5 * u, -11 * u]];
  print(c, body, white);
  c.save(); poly(c, body, true, REGX, REGY); c.clip();
  for (let i = 0; i < 3; i++) { c.fillStyle = rgba(navy); c.fillRect(-8 * u + REGX, (-22 + i * 4.2) * u + REGY, 16 * u, 2.1 * u); }
  c.restore();
  c.beginPath(); edges(c, body, DET, 3, true, { ov: 0.6 });
  // arms
  if (pose === 'carry') {
    ribbon(c, [[-5 * u, -22 * u], [-7 * u, -30 * u], [-5 * u, -37 * u]], DET * 1.1, 4, { tin: 1, tout: 1 });
    ribbon(c, [[5 * u, -22 * u], [7 * u, -30 * u], [5 * u, -37 * u]], DET * 1.1, 5, { tin: 1, tout: 1 });
  } else if (pose === 'wave') {
    const wv = s.reduced ? 0 : Math.sin(s.t * 7) * 0.5;
    ribbon(c, [[-5 * u, -22 * u], [-7 * u, -15 * u]], DET * 1.1, 4, { tin: 1, tout: 1 });
    ribbon(c, [[5 * u, -22 * u], [10 * u, -28 * u], [10 * u + Math.sin(wv) * 7 * u, -36 * u]], DET * 1.1, 5, { tin: 1, tout: 1 });
  } else {
    ribbon(c, [[-5 * u, -22 * u], [-6.5 * u - st * 4 * u, -14 * u]], DET * 1.1, 4, { tin: 1, tout: 1 });
    ribbon(c, [[5 * u, -22 * u], [6.5 * u + st * 4 * u, -14 * u]], DET * 1.1, 5, { tin: 1, tout: 1 });
  }
  c.fillStyle = INK; c.fill();
  if (pose === 'back') {
    // seen from behind: white hair under the cap, his ears, no face
    const head = ellipse(0, -29 * u, 5 * u, 5.4 * u, 20);
    for (const sx of [-1, 1]) dot(c, sx * 5 * u, -28.6 * u, 1.3 * u, skin);
    print(c, head, white);
    c.beginPath(); loop(c, head, DET, 6, { over: 0.04 }); c.fillStyle = INK; c.fill();
    const back = [[-5.2 * u, -31.5 * u], [-4.8 * u, -36.2 * u], [4.8 * u, -36.2 * u], [5.2 * u, -31.5 * u]];
    poly(c, back); c.fillStyle = rgba(navy); c.fill();
    c.beginPath(); edges(c, back, DET * 0.9, 8, false, { ov: 0.5 }); c.fillStyle = INK; c.fill();
    c.restore();
    return;
  }
  // head, white beard, cap with a peak
  const head = ellipse(0.5 * u, -29 * u, 5 * u, 5.4 * u, 20);
  print(c, head, skin);
  const beard = [[-4.4 * u, -29 * u], [-3 * u, -23.5 * u], [1 * u, -22.4 * u], [5.2 * u, -24.5 * u], [5.6 * u, -28.5 * u]];
  print(c, curve(beard, 2), white);
  c.beginPath(); loop(c, head, DET, 6, { over: 0.04 }); ribbon(c, curve(beard, 2), TEX, 7, { tin: 1, tout: 1, outline: true }); c.fillStyle = INK; c.fill();
  dot(c, 2.6 * u, -30 * u, 0.9 * u + 0.3, INK);
  dot(c, 5.6 * u, -28.6 * u, 1.3 * u, mix(skin, hex('#E0786A'), 0.5));
  const cap = [[-5 * u, -31.5 * u], [-4.6 * u, -36 * u], [3 * u, -36.4 * u], [5.4 * u, -32 * u]];
  poly(c, cap); c.fillStyle = rgba(navy); c.fill();
  c.beginPath(); edges(c, cap, DET * 0.9, 8, false, { ov: 0.5 }); ribbon(c, [[3 * u, -32 * u], [9 * u, -31 * u]], DET * 1.2, 9, { tin: 1, tout: 2 }); c.fillStyle = INK; c.fill();
  c.restore();
}

function drawTile(s, c, x, y, u) {
  const w = 34 * u, h = 15 * u, r = 5 * u, P = s.P;
  const box = [];
  for (const [cx, cy, a] of [[x + w / 2 - r, y - h / 2 + r, -Math.PI / 2], [x + w / 2 - r, y + h / 2 - r, 0], [x - w / 2 + r, y + h / 2 - r, Math.PI / 2], [x - w / 2 + r, y - h / 2 + r, Math.PI]])
    for (let i = 0; i <= 4; i++) { const an = a + i / 4 * Math.PI / 2; box.push([cx + Math.cos(an) * r, cy + Math.sin(an) * r]); }
  shape(c, box, C.tile, DET, 4, { over: 0.05 });
  label(c, '10:30', x + REGX * 0.5, y + REGY * 0.5 + 0.5, 10 * u + 1.5, rgba(mul(hex('#FFFFFF'), P.paper)), 'center', 0);
}

/* edit: the keeper wanders the ridge with a widget tile ("10:30") */
function drawEditKeeper(s, c, p) {
  const g = s.g, u = g.u, T = g.lh, k = g.cot, sc = g.portrait ? 1.5 : 1.55;
  const t = s.t - s.since.edit;
  const door = k.x - k.w * 0.5 + k.w * 0.68, xL = g.portrait ? g.W * 0.42 : g.W * 0.668, xR = T.x - T.wB * 1.6;
  const v = 32 * u;
  let x, flip;
  const out = (door - xR) / v;
  if (s.reduced) { x = lerp(xL, xR, 0.45); flip = true; }
  else if (t < out) { x = door - t * v; flip = true; }
  else {
    const span = xR - xL, ph = ((t - out) * v) % (span * 2 + 120 * u);
    if (ph < span) { x = xR - ph; flip = true; }
    else if (ph < span + 60 * u) { x = xL; flip = false; }
    else if (ph < span * 2 + 60 * u) { x = xL + (ph - span - 60 * u); flip = false; }
    else { x = xR; flip = true; }
  }
  const ry = s.ridgeY(x) ?? k.base, walking = !s.reduced && t > 0;
  c.globalAlpha = clamp(p * 1.5);
  DRAW.keeper(s, c, x, ry + 2 * u, sc, 'carry', flip, walking ? s.t * 9 : 0);
  DRAW.tile(s, c, x + (flip ? -1 : 1) * 0.5 * u, ry + 2 * u - 42 * u * sc + Math.sin(s.reduced ? 0 : s.t * 9) * 0.6 * u, u * sc);
  c.globalAlpha = 1;
}

/* someone knocked at the cottage (see knock and VISIT): the door jumps under each knock, and at the third swings open
   on a lamp-lit room; the keeper looks out to the left and to the right, sees nobody, turns his back, walks in and shuts it */
function drawVisit(s, c) {
  const v = s.visit, g = s.g, k = g.cot, d = k.door;
  if (!d) return;
  const u = g.u, P = s.P, a = v ? s.t - v.t0 : -1, rm = s.reduced, V = VISIT, sc = g.portrait ? 1.05 : 1.45, ka = s.t - s.knocks.at;
  const open = !v || v.away ? 0 : rm ? (a >= V.open[0] && a < V.shut[1] ? 1 : 0) : smooth(V.open[0], V.open[1], a) * (1 - smooth(V.shut[0], V.shut[1], a));
  // each knock jolts it
  const jig = rm || ka > 0.45 ? 0 : Math.sin(ka * 55) * 0.9 * u * (1 - ka / 0.45);
  if (open < 0.005 && jig === 0) return;
  const night = smooth(0.45, 0.75, s.d);
  const frame = [[d.x, k.base], [d.x, d.y], [d.x + d.w, d.y], [d.x + d.w, k.base]];
  if (open < 0.005) {
    // shut and jumping: the wall where the door was, under it
    poly(c, [[d.x - 2 * u, k.base], [d.x - 2 * u, d.y - 2 * u], [d.x + d.w + 2 * u, d.y - 2 * u], [d.x + d.w + 2 * u, k.base]]);
    c.fillStyle = rgba(mul(hex('#FFFFFF'), P.paper)); c.fill();
  } else {
    // inside, the lamp: the doorway warm, and at night its light spilling onto the grass
    if (night > 0.05) {
      c.globalAlpha = open * night;
      poly(c, [[d.x, k.base], [d.x + d.w, k.base], [d.x + d.w + 44 * u, k.base + 34 * u], [d.x - 34 * u, k.base + 34 * u]]);
      c.fillStyle = rgba(mix(P.hill, C.lamp, 0.62)); c.fill();
      c.globalAlpha = 1;
    }
    poly(c, frame); c.fillStyle = rgba(C.lamp); c.fill();
    // the keeper in the doorway, leaning out the way he looks; then his back, walking in, a little smaller and higher
    // the further in he is, into the lamplight
    const kin = rm ? (a >= V.keeper[0] && a < V.keeper[1] ? 1 : 0) : smooth(V.keeper[0], V.keeper[0] + 0.12, a) * (1 - smooth(V.keeper[1] - 0.14, V.keeper[1], a));
    if (kin > 0.01) {
      const right = a >= V.right, back = a >= V.turn, deep = rm ? 0 : smooth(V.turn + 0.1, V.keeper[1], a);
      const lean = rm ? 0 : (right ? 1 : -1) * 2.5 * u * sc * (1 - smooth(V.turn - 0.05, V.turn + 0.15, a));
      c.globalAlpha = kin;
      DRAW.keeper(s, c, d.x + d.w / 2 + lean, k.base - 5 * u * sc * deep, sc * (1 - 0.15 * deep), back ? 'back' : 'stand', !right && !back, back && !rm ? s.t * 9 : 0);
      c.globalAlpha = 1;
    }
  }
  // the door, swinging out on its right-hand hinge until it lies against the wall
  drawDoor(s, c, open, jig);
}

/* install: night, the cottage door open with warm light, the keeper waving */
function drawDoorway(s, c, p) {
  const g = s.g, u = g.u, P = s.P, k = g.cot, d = k.door;
  if (!d) return;
  c.globalAlpha = clamp(p * 1.4);
  // light spilling onto the grass
  const spill = [[d.x, k.base], [d.x + d.w, k.base], [d.x + d.w + 44 * u, k.base + 34 * u], [d.x - 34 * u, k.base + 34 * u]];
  poly(c, spill); c.fillStyle = rgba(mix(P.hill, C.lamp, 0.62)); c.fill();
  poly(c, [[d.x, k.base], [d.x, d.y], [d.x + d.w, d.y], [d.x + d.w, k.base]]); c.fillStyle = rgba(C.lamp); c.fill();
  // the door swung open against the wall
  const door = [[d.x + d.w, k.base], [d.x + d.w, d.y], [d.x + d.w * 1.55, d.y + 2 * u], [d.x + d.w * 1.55, k.base - 1 * u]];
  print(c, door, mul(C.door, P.paper));
  c.beginPath(); edges(c, door, DET * 0.85, 3, true, { ov: 0.6 }); c.fillStyle = INK; c.fill();
  DRAW.keeper(s, c, d.x + d.w * 0.5, k.base, g.portrait ? 1.05 : 1.45, 'wave', false, 0);
  c.globalAlpha = 1;
}

/* widgets: a sheep at a tiny desk with a laptop, typing */
function drawDesk(s, c, p) {
  const g = s.g, P = s.P, sc = pop(p) * (g.portrait ? 1.75 : 2.1), u = g.u * sc;
  const { x, y } = deskSpot(s);
  if (sc < 0.05) return;
  const typing = s.reduced ? 0 : s.t * 11, wool = mul(C.wool, P.paper), night = smooth(0.4, 0.8, s.d);
  c.save(); c.translate(x, y);
  // the sheep behind the desk, seen from the front
  const bob = s.reduced ? 0 : Math.sin(s.t * 2.4) * 0.6 * u;
  const body = [];
  for (let i = 0; i < 36; i++) { const a = i / 36 * TAU, r = 1 + 0.12 * Math.abs(Math.sin(a * 5)); body.push([Math.cos(a) * 15 * u * r, -27 * u + Math.sin(a) * 12 * u * r]); }
  shape(c, body, wool, DET, 3);
  const face = ellipse(0, -36 * u + bob, 6 * u, 7.5 * u, 20);
  poly(c, face); c.fillStyle = INK; c.fill();
  for (const sx of [-1, 1]) { const ear = ellipse(sx * 8.5 * u, -40 * u + bob, 4.4 * u, 1.9 * u, 12, 0, TAU, sx * 0.35); poly(c, ear); c.fillStyle = INK; c.fill(); }
  const tuft = []; for (let i = 0; i < 14; i++) { const a = Math.PI + i / 13 * Math.PI, r = 1 + 0.2 * Math.abs(Math.sin(a * 4)); tuft.push([Math.cos(a) * 6.5 * u * r, -42 * u + bob + Math.sin(a) * 3.6 * u * r]); }
  shape(c, tuft, wool, TEX, 5);
  // eyes on the screen, lit by it at night
  for (const sx of [-1, 1]) { dot(c, sx * 2.6 * u, -36.5 * u + bob, 1.6 * u, '#FFFFFF'); dot(c, sx * 2.6 * u, -35.8 * u + bob, 0.8 * u, INK); }
  // the desk
  const top = [[-24 * u, -14 * u], [24 * u, -14 * u], [24 * u, -10.5 * u], [-24 * u, -10.5 * u]];
  print(c, top, mul(C.wood, P.paper));
  c.beginPath(); edges(c, top, DET, 7, true, { ov: 1 });
  ribbon(c, [[-20 * u, -10.5 * u], [-21 * u, 0]], DET, 8, { tin: 1, tout: 1 }); ribbon(c, [[20 * u, -10.5 * u], [21 * u, 0]], DET, 9, { tin: 1, tout: 1 });
  c.fillStyle = INK; c.fill();
  // the laptop, seen from the back, with a lighthouse sticker; the screen's glow on the sheep
  if (night > 0.05) { c.beginPath(); c.ellipse(0, -30 * u, 16 * u, 9 * u, 0, 0, TAU); c.fillStyle = rgba(hex('#BFE3FF'), 0.35 * night); c.fill(); }
  const lid = [[-11 * u, -14.5 * u], [-12 * u, -29 * u], [12 * u, -29 * u], [11 * u, -14.5 * u]];
  print(c, lid, mul(C.steel, P.paper));
  c.beginPath(); edges(c, lid, DET, 11, true, { ov: 0.8 }); c.fillStyle = INK; c.fill();
  const st = [[-1.6 * u, -18 * u], [-1.1 * u, -25 * u], [1.1 * u, -25 * u], [1.6 * u, -18 * u]];
  print(c, st, mul(hex('#FFFFFF'), P.paper)); c.fillStyle = rgba(mul(C.chimney, P.paper)); c.fillRect(-1.4 * u + REGX, -22.5 * u + REGY, 2.8 * u, 1.6 * u);
  // hooves on the keys, one and then the other
  c.beginPath();
  for (const sx of [-1, 1]) {
    const up = s.reduced ? 0 : Math.max(0, Math.sin(typing + (sx > 0 ? Math.PI : 0))) * 2.4 * u;
    ribbon(c, [[sx * 10 * u, -22 * u], [sx * 13 * u, -17 * u - up], [sx * 11 * u, -15.5 * u - up]], DET * 1.3, 12 + sx, { tin: 1, tout: 1 });
  }
  c.fillStyle = INK; c.fill();
  // tak tak
  if (!s.reduced) {
    const ph = (s.t * 1.3) % 1;
    label(c, ph < 0.5 ? 'tak' : 'tak tak', 15 * u, -34 * u - ph * 6 * u, 8 * u + 2, rgba(s.d > 0.55 ? P.paper : P.ink, 1 - ph), 'left', -0.15);
  }
  // a mug of something
  const mug = [[16 * u, -14 * u], [16.5 * u, -20 * u], [21 * u, -20 * u], [20.5 * u, -14 * u]];
  print(c, mug, mul(hex('#FF4A36'), P.paper)); c.beginPath(); edges(c, mug, TEX, 13, true, { ov: 0.6 }); ribbon(c, ellipse(21.5 * u, -17 * u, 2 * u, 2 * u, 8, -1.2, 1.2), TEX, 14, { tin: 1, tout: 1 }); c.fillStyle = INK; c.fill();
  c.restore();
}

/* tiling: four numbered beach huts; the focused workspace's hut is lit, its door open */
function hutSpots(s) {
  const g = s.g;
  if (g.portrait) return [0.38, 0.54, 0.7, 0.86].map(fx => { const x = fx * g.W; return { x, y: g.top + (g.H - g.top) * 0.455 + (fx - 0.38) * g.H * 0.05 }; });
  return [0.625, 0.705, 0.785, 0.865].map(fx => ({ x: fx * g.W, y: g.top + (g.H - g.top) * 0.82 }));
}
function drawHuts(s, c, p) {
  const g = s.g, P = s.P, spots = hutSpots(s), white = mul(hex('#FFFFFF'), P.paper);
  const k0 = pop(p) * (g.portrait ? 1.3 : 1.75);
  // the boardwalk they share
  if (k0 > 0.05) {
    const u = g.u * k0, a = spots[0], b = spots[3], walk = [[a.x - 30 * u, a.y], [b.x + 30 * u, b.y], [b.x + 30 * u, b.y + 4 * u], [a.x - 30 * u, a.y + 4 * u]];
    print(c, walk, mul(C.wood, P.paper));
    c.beginPath(); edges(c, walk, TEX * 1.2, 2, true, { ov: 1.2 });
    for (let x = a.x - 22 * u; x < b.x + 30 * u; x += 9 * u) ribbon(c, [[x, a.y + lerp(0, b.y - a.y, (x - a.x) / (b.x - a.x)) + 0.5 * u], [x, a.y + lerp(0, b.y - a.y, (x - a.x) / (b.x - a.x)) + 3.5 * u]], TEX * 0.8, x, { tin: 1, tout: 1, amp: 0.2 });
    c.fillStyle = INK; c.fill();
  }
  spots.forEach((q, i) => {
    const sc = pop(clamp(p * 1.6 - i * 0.15)) * (g.portrait ? 1.3 : 1.75), u = g.u * sc;
    if (sc < 0.05) return;
    const on = s.ws === i + 1, col = mul(C.huts[i], P.paper);
    const w = 26 * u, h = 27 * u, x0 = q.x - w / 2, y0 = q.y - h;
    const body = [[x0, q.y], [x0, y0], [x0 + w, y0], [x0 + w, q.y]];
    print(c, body, white);
    c.save(); poly(c, body, true, REGX, REGY); c.clip(); c.fillStyle = rgba(col);
    for (let k = 0; k < 4; k++) c.fillRect(x0 + REGX + k * w / 4, y0 + REGY - 1, w / 8, h + 2);
    c.restore();
    const roof = [[x0 - 4 * u, y0 + 1 * u], [q.x, y0 - 14 * u], [x0 + w + 4 * u, y0 + 1 * u]];
    print(c, roof, col);
    // the door: shut with its number painted on, or open on a warm room
    const dw = w * 0.5, dh = h * 0.74, dx = q.x - dw / 2, dy = q.y - dh, door = [[dx, q.y], [dx, dy], [dx + dw, dy], [dx + dw, q.y]];
    const lit = mix(P.beam, hex('#FFB84A'), 0.3);
    let num = [q.x, dy + dh * 0.45, 1];
    if (on) {
      poly(c, door); c.fillStyle = rgba(lit); c.fill();
      const leaf = [[dx + dw, q.y], [dx + dw, dy], [dx + dw * 1.55, dy + 2.5 * u], [dx + dw * 1.55, q.y - 1.2 * u]];
      print(c, leaf, mix(col, hex('#000000'), 0.12));
      c.beginPath(); edges(c, leaf, TEX * 1.2, i + 3, true, { ov: 0.4 }); c.fillStyle = INK; c.fill();
      num = [dx + dw * 1.29, dy + dh * 0.45, 0.85];
    } else {
      print(c, door, mix(col, hex('#000000'), 0.12));
    }
    // the round window in the gable
    dot(c, q.x + REGX, y0 - 5 * u + REGY, 3.4 * u, on ? lit : mix(P.sky, P.ink, 0.25 + 0.35 * smooth(0.4, 0.8, s.d)));
    c.beginPath();
    edges(c, roof, DET, i * 7, true, { ov: 1 }); edges(c, body, DET, i * 7 + 2, false, { ov: 0.8 });
    edges(c, door, TEX * 1.2, i * 7 + 4, false, { ov: 0.4 });
    ribbon(c, ellipse(q.x, y0 - 5 * u, 3.4 * u, 3.4 * u, 12), TEX, i, { tin: 1, tout: 1, w0: 1, w1: 1, outline: true });
    c.fillStyle = INK; c.fill();
    label(c, String(i + 1), num[0] + 0.5 * u, num[1], 11 * u * num[2] + 2, rgba(white), 'center', 0);
  });
}

/* themes: the washing line, with the other pyjamas drying */
function drawWashing(s, c, p) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, sc = pop(p);
  if (sc < 0.05) return;
  const px = g.portrait ? g.W * 0.4 : g.W * 0.615, pry = s.ridgeY(px) ?? T.base;
  const ph = (g.portrait ? 48 : 92) * u * sc, top = [px, pry - ph], end = [T.x - lerp(T.wB, T.wT, 0.3) / 2, T.base - T.h * 0.3];
  c.beginPath();
  ribbon(c, dens([[px, pry + 3 * u], top], 5), DET * 1.1, 1, { tin: 2, tout: 2 });
  ribbon(c, [[px - 6 * u, top[1] + 4 * u], [px, top[1] - 1 * u], [px + 6 * u, top[1] + 4 * u]], TEX, 2, { tin: 1, tout: 1 });
  const sag = 16 * u, line = [];
  for (let i = 0; i <= 20; i++) { const f = i / 20; line.push([lerp(top[0], end[0], f), lerp(top[1], end[1], f) + Math.sin(f * Math.PI) * sag]); }
  ribbon(c, line, TEX, 3, { tin: 2, tout: 2 });
  c.fillStyle = INK; c.fill();
  const others = Object.keys(THEMES).filter(k => k !== s.theme);
  const wind = s.reduced ? 0.1 : s.windTotal;
  others.forEach((id, i) => {
    const f = (i + 0.7) / (others.length + 0.4), ax = lerp(top[0], end[0], f), ay = lerp(top[1], end[1], f) + Math.sin(f * Math.PI) * sag;
    const k = sc * (g.portrait ? 1 : 1.45), w = 13 * u * k, h = 14 * u * k, sw = (s.reduced ? 0 : Math.sin(s.t * 2.2 + i) * 0.08) + wind * 0.12;
    c.save(); c.translate(ax, ay); c.rotate(sw);
    const shirt = [[-w / 2, 0], [-w * 0.85, h * 0.25], [-w * 0.62, h * 0.4], [-w * 0.42, h * 0.3], [-w * 0.42, h], [w * 0.42, h], [w * 0.42, h * 0.3], [w * 0.62, h * 0.4], [w * 0.85, h * 0.25], [w / 2, 0]];
    print(c, shirt, mul(hex('#FFFFFF'), P.paper));
    c.save(); poly(c, shirt, true, REGX, REGY); c.clip();
    const st = THEMES[id].stripes;
    for (let j = 0; j < 3; j++) { c.fillStyle = rgba(mul(hex(st[j % st.length]), P.paper)); c.fillRect(-w + REGX, h * (0.18 + j * 0.3) + REGY, w * 2, h * 0.15); }
    c.restore();
    c.beginPath(); edges(c, shirt, TEX, i * 3, true, { ov: 0.3 });
    ribbon(c, [[-w * 0.2, -2 * u], [-w * 0.2, 3 * u]], DET, i, { tin: 1, tout: 1, w0: 1, w1: 1 }); ribbon(c, [[w * 0.2, -2 * u], [w * 0.2, 3 * u]], DET, i + 1, { tin: 1, tout: 1, w0: 1, w1: 1 });
    c.fillStyle = INK; c.fill();
    c.restore();
  });
}

/* ---------- the hero's labels, each with a hand-drawn arrow ---------- */
function arrow(c, pts, w, sd) {
  const p = curve(pts, 4), n = p.length, [x1, y1] = p[n - 1], [x0, y0] = p[Math.max(0, n - 4)], a = Math.atan2(y1 - y0, x1 - x0), h = 8 * PW;
  c.beginPath();
  ribbon(c, p, w, sd, { tin: 4, tout: 2, w0: 0.5, w1: 0.7 });
  ribbon(c, [[x1 + Math.cos(a + 2.6) * h, y1 + Math.sin(a + 2.6) * h], [x1, y1], [x1 + Math.cos(a - 2.5) * h, y1 + Math.sin(a - 2.5) * h]], w, sd + 1, { tin: 2, tout: 2, w0: 0.6, w1: 0.6 });
  c.fill();
}
function drawLabels(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, night = smooth(0.5, 0.7, s.d);
  const col = rgba(mix(P.ink, P.paper, night), s.pres.hero);
  const size = Math.max(13, 17 * u);
  c.fillStyle = col;
  if (g.portrait) {
    // the lighthouse, from the left of its lamp
    const tx = T.x - T.wB * 1.9, ty = T.top + T.h * 0.3;
    label(c, 'a lighthouse (stable)', tx, ty, size, col, 'right');
    c.fillStyle = col; arrow(c, [[tx + 4, ty - 1], [tx + 14, ty - 5], [T.x - T.wB * 0.62, T.top + T.h * 0.2]], TEX * 1.1, 8);
  } else {
    const tipX = T.x - T.wB * 0.62, tipY = T.top + T.h * 0.6, ax = tipX - 88 * u, ay = tipY + 38 * u;
    label(c, 'a lighthouse (stable)', ax, ay, size, col, 'right');
    c.fillStyle = col; arrow(c, [[ax + 6 * u, ay - 3 * u], [ax + 42 * u, ay - 22 * u], [tipX - 6 * u, tipY]], TEX * 1.1, 8);
  }
  // the cloud with legs
  const sc = g.sheepCloud, p = s.cloudXY(sc), w = sc.w;
  const lx = p.x + w * 0.42 + (g.portrait ? 6 : 14 * u), ly = p.y + (g.portrait ? 12 : 22 * u);
  if (lx + 16 * u + textW(s, 'a cloud (or a sheep)', size) < (g.portrait ? g.lamp.x - T.er * 1.7 : T.x - T.er * 3)) {
    label(c, 'a cloud (or a sheep)', lx + 16 * u, ly + 4 * u, size, col, 'left');
    c.fillStyle = col; arrow(c, [[lx + 12 * u, ly + 3 * u], [lx, ly + 2 * u], [p.x + w * 0.36, p.y + 6 * u]], TEX * 1.1, 9);
  }
  // the sheep in its box, where placeBox found room for the label
  const bx = s.box;
  if (bx.lastSide && bx.la > 0.01 && bx.gx != null) {
    const p = s.boxAt(true), q = boxLabel(p.x, p.y, p.k, u, size, bx.tw, bx.lastSide), lc = rgba(mix(P.ink, P.paper, night), s.pres.hero * bx.la);
    label(c, s.boxEmpty() ? 'a box (empty)' : 'a sheep (in a box)', q.tx, q.ty, size, lc, q.align);
    c.fillStyle = lc; arrow(c, q.arrow, TEX * 1.1, 11);
    c.fillStyle = col;
  }
  // the sea
  const sea = seaLabelSpot(s);
  if (sea) {
    const wTxt = textW(s, 'the sea (wet)', size);
    label(c, 'the sea (wet)', sea.x, sea.y, size, rgba(P.paper, s.pres.hero), 'left');
    c.fillStyle = rgba(P.paper, s.pres.hero); arrow(c, [[sea.x + wTxt * 0.62, sea.y + 11 * u], [sea.x + wTxt * 0.5, sea.y + 22 * u], [sea.x + wTxt * 0.3, sea.y + 30 * u]], TEX * 1.1, 10);
  }
}
function textW(s, text, size) { const c = s.ctx; c.save(); c.font = `${WEIGHT} ${size}px ${HAND}`; const w = c.measureText(CAPS ? text.toUpperCase() : text).width; c.restore(); return w; }
// what "a lighthouse (stable)" and its arrow cover (as drawLabels places them), for keeping out of their way
function lighthouseLabelRects(s, w, size) {
  const g = s.g, u = g.u, T = g.lh, h = size * 0.75;
  if (g.portrait) {
    const tx = T.x - T.wB * 1.9, ty = T.top + T.h * 0.3;
    return [[tx - w - 4, ty - h, tx + 4, ty + h], [tx, T.top + T.h * 0.2 - 6, T.x - T.wB * 0.62 + 4, ty + 4]];
  }
  const tipX = T.x - T.wB * 0.62, tipY = T.top + T.h * 0.6, ax = tipX - 88 * u, ay = tipY + 38 * u;
  return [[ax - w - 4, ay - h, ax + 4, ay + h], [ax, tipY - 6, tipX + 4, ay]];
}
/* "a sheep (in a box)" for a box at (x, y): below it, or beside it, with an arrow back to the box;
   the text's anchor and alignment, the arrow, and the rect the two take */
function boxLabel(x, y, k, u, size, tw, side) {
  const h = size * 0.75, R = (BOX.hw + BOX.dx) * k, Lx = BOX.hw * k, B = BOX.hh * k;
  if (side === 'below') {
    const tx = x - Lx * 0.35, ty = y + B + 12 * u + size * 0.55;
    return { tx, ty, align: 'left', arrow: [[tx + 3 * u, ty - h * 1.05], [tx - 3 * u, ty - h * 1.6], [x - Lx * 0.5, y + B + 3 * u]], x0: Math.min(tx, x - Lx) - 4, y0: y + B + 2, x1: tx + tw + 4, y1: ty + h };
  }
  if (side === 'right') {
    const tx = x + R + 22 * u, ty = y + 9 * u;
    return { tx, ty, align: 'left', arrow: [[tx - 3 * u, ty - 1 * u], [tx - 11 * u, ty - 2 * u], [x + R + 4 * u, y + 1 * u]], x0: x + R + 2, y0: ty - h, x1: tx + tw + 4, y1: ty + h };
  }
  const tx = x - Lx - 20 * u, ty = y + 9 * u;
  return { tx, ty, align: 'right', arrow: [[tx + 3 * u, ty - 1 * u], [tx + 11 * u, ty - 2 * u], [x - Lx - 4 * u, y + 1 * u]], x0: tx - tw - 4, y0: ty - h, x1: x - Lx - 2, y1: ty + h };
}
// where the widgets section's sheep sits at its desk
function deskSpot(s) {
  const g = s.g, x = g.portrait ? g.W * 0.5 : g.W * 0.7, ry = s.ridgeY(x);
  return { x, y: g.portrait ? ry + (s.shoreY(x) - ry) * 0.66 : ry + g.H * 0.2 };
}
function seaLabelSpot(s) {
  const g = s.g, u = g.u, wTxt = 112 * u + 10;
  if (g.portrait) { const y = g.horizon + (g.H - g.horizon) * 0.55; return { x: g.W * 0.3, y }; }
  // in the sea, right of the notes or below them, clear of the key
  for (const fy of [0.07, 0.14, 0.3, 0.55, 0.7, 0.85]) {
    const y = g.horizon + (g.H - g.horizon) * fy, right = s.hillLeftX(y + 26 * u) - 10 * u;
    let x0 = 30 * u + 22 * u;
    if (y < g.note.y1) x0 = Math.max(x0, g.note.x1 + 16 * u);
    if (g.key && y + 30 * u > g.key.y0) x0 = Math.max(x0, g.key.x1 + 24 * u);
    if (right - x0 > wTxt) return { x: x0 + Math.min(20 * u, (right - x0 - wTxt) * 0.4), y: y + 8 * u };
  }
  return null;
}

/* ---------- surprises ---------- */
function drawObj(s, c, o) {
  const g = s.g, P = s.P, k = g.u * o.sc, lit = o.lit * s.beamI(), sq = s.squash(o), t = s.reduced ? 0 : s.t;
  if (o.dying != null) c.globalAlpha = clamp(1 - (s.t - o.dying) / 0.7);
  // a sheep pleased with its meal hops, twice
  const ja = t - (o.joy ?? -99), hop = o.kind === 'sheep' && ja >= 0 && ja < 0.8 ? Math.abs(Math.sin(ja / 0.4 * Math.PI)) * 6 * k * (1 - ja / 0.8) : 0;
  c.save(); c.translate(o.x, o.y - hop);
  if (lit > 0.15) {
    // a startled "!", in the pen
    const jy = -40 * k - Math.abs(Math.sin(t * 8)) * 3 * k;
    c.globalAlpha *= clamp(lit * 1.6);
    c.beginPath(); ribbon(c, [[2.6 * k, jy - 15 * k], [2 * k, jy - 6 * k], [1.6 * k, jy - 1 * k]], DET * 1.35, o.seed, { tin: 1, tout: 4, w0: 1, w1: 0.3 }); c.fillStyle = INK; c.fill();
    dot(c, 1.3 * k, jy + 4 * k, 1.7 * PW, INK);
    c.globalAlpha = o.dying != null ? clamp(1 - (s.t - o.dying) / 0.7) : 1;
  }
  c.scale((o.flip ? -1 : 1) * (1 + sq * 0.6), 1 - sq);
  const tint = base => mix(mul(base, P.paper), P.beam, clamp(lit) * 0.75);
  switch (o.kind) {
    case 'sheep': DRAW.sheep(c, k, tint(C.wool), o, t); break;
    case 'cow': DRAW.cow(c, k, tint(hex('#FFFFFF')), P, o, t); break;
    case 'gull': DRAW.gull(c, k, tint(hex('#FFFFFF')), o, t); break;
    case 'duck': DRAW.duck(c, k, tint(C.duck), P, o, t); break;
    case 'monster': DRAW.monster(c, k, tint(C.monster), P, o, t); break;
  }
  c.restore();
  c.globalAlpha = 1;
}
/* a grazer's head: up, or lowered into the grass and chewing; `px, py` is where the neck turns, `to` where it
   goes when the head is down. Draws the head with `draw`, in the head-up coordinates. */
function head(c, u, o, t, px, py, to, turn, draw) {
  const hd = o.head || 0, chew = o.act === 'eat' ? Math.sin(t * 9 + o.seed) * hd : 0;
  c.save();
  c.translate(lerp(px, to[0], hd) * u, (lerp(py, to[1], hd) + chew * 0.55) * u);
  c.rotate(hd * turn + chew * 0.07);
  c.translate(-px * u, -py * u);
  draw(chew);
  c.restore();
}
// asleep: the eye shut, a short curve
function napEye(c, x, y, r, col) {
  c.beginPath(); ribbon(c, ellipse(x, y - r * 0.5, r * 1.2, r * 0.9, 8, Math.PI * 0.1, Math.PI * 0.9), TEX, 4, { tin: 1, tout: 1, w0: 0.9, w1: 0.9, amp: 0.1 });
  c.fillStyle = col; c.fill();
}
// pleased with a meal: a short while after it, eyes shut happily and the tail wags
const joyAt = (o, t) => { const a = t - (o.joy ?? -99); return a >= 0 && a < 1.3 ? a : -1; };
function drawSheep(c, u, wool, o, t) {
  const fall = o.state === 'fall' || o.state === 'leap', step = Math.hypot(o.vx, o.vd || 0) > 2 ? Math.sin(t * 14 + o.seed) * 2 * u : 0;
  c.beginPath();
  [-8, -3, 5, 10].forEach((lx, i) => ribbon(c, [[lx * u, -10 * u], [lx * u + (fall ? 3 * u : (i % 2 ? step : -step)), 0]], DET * 1.05, i, { tin: 1, tout: 1, w0: 0.9, w1: 1 }));
  c.fillStyle = INK; c.fill();
  const body = [];
  for (let i = 0; i < 40; i++) { const a = i / 40 * TAU, r = 1 + 0.13 * Math.abs(Math.sin(a * 5 + o.seed)); body.push([Math.cos(a) * 14 * u * r, -16 * u + Math.sin(a) * 9.5 * u * r]); }
  shape(c, body, wool, DET, o.seed % 7);
  // a stubby tail, wagging when pleased
  const ja = joyAt(o, t);
  c.save(); c.translate(-14 * u, -19 * u); c.rotate(-0.45 + (ja >= 0 ? Math.sin(ja * 24) * 0.6 * (1 - ja / 1.3) : 0));
  shape(c, ellipse(-2.4 * u, 0, 3 * u, 2.2 * u, 12), wool, TEX * 1.15, 5, { over: 0.05 });
  c.restore();
  // black face, an ear, a tuft of wool on top, an eye
  head(c, u, o, t, 15, -19, [19, -7.5], 1.05, chew => {
    poly(c, ellipse(15 * u, -19 * u, 5 * u, 6.4 * u, 18, 0, TAU, -0.35)); c.fillStyle = INK; c.fill();
    poly(c, ellipse(11.5 * u, -23.5 * u, 3.6 * u, 1.6 * u, 10, 0, TAU, 0.5 + chew * 0.25)); c.fill();
    const tuft = []; for (let i = 0; i < 10; i++) { const a = Math.PI * 1.05 + i / 9 * Math.PI * 0.9; tuft.push([13.5 * u + Math.cos(a) * 5 * u, -24 * u + Math.sin(a) * 2.6 * u]); }
    c.beginPath(); ribbon(c, tuft, TEX, 3, { tin: 1, tout: 1 }); c.fillStyle = rgba(wool); c.fill();
    if (ja >= 0) { c.beginPath(); ribbon(c, ellipse(16.6 * u, -19.6 * u, 1.7 * u, 1.3 * u, 8, Math.PI * 1.1, Math.PI * 1.9), TEX, 4, { tin: 1, tout: 1, w0: 0.9, w1: 0.9, amp: 0.1 }); c.fillStyle = '#FFFFFF'; c.fill(); }
    else if (NAP) napEye(c, 16.6 * u, -20.5 * u, 1.5 * u, '#FFFFFF');
    else { dot(c, 16.6 * u, -20.5 * u, 1.5 * u, '#FFFFFF'); dot(c, 17.1 * u, -20.3 * u, 0.75 * u, INK); }
  });
}
function drawCow(c, u, white, P, o, t) {
  const step = Math.hypot(o.vx, o.vd || 0) > 2 ? Math.sin(t * 9 + o.seed) * 2 * u : 0;
  c.beginPath();
  [-12, -7, 8, 13].forEach((lx, i) => ribbon(c, [[lx * u, -11 * u], [lx * u + (i % 2 ? step : -step), 0]], DET * 1.15, i, { tin: 1, tout: 1, w0: 0.9, w1: 1 }));
  c.fillStyle = INK; c.fill();
  // the tail swishes now and then, and wags when pleased
  const ja = joyAt(o, t), wag = ja >= 0 ? Math.sin(ja * 16) * 0.5 * (1 - ja / 1.3) : Math.sin(t * 1.3 + o.seed) * 0.12;
  c.save(); c.translate(-17 * u, -20 * u); c.rotate(wag); c.translate(17 * u, 20 * u);
  c.beginPath(); ribbon(c, [[-17 * u, -20 * u], [-21 * u, -14 * u], [-20 * u, -7 * u]], TEX, 5, { tin: 1, tout: 1 }); c.fillStyle = INK; c.fill();
  dot(c, -20 * u, -6 * u, 2 * u, INK);
  c.restore();
  const body = curve([[-17 * u, -22 * u], [-6 * u, -26.5 * u], [10 * u, -25.5 * u], [17 * u, -20 * u], [15 * u, -11 * u], [0, -10 * u], [-16 * u, -11 * u], [-18.5 * u, -16 * u]], 3, true);
  print(c, body, white);
  // patches, inside the body
  c.save(); poly(c, body, true, REGX, REGY); c.clip();
  const R = rng(o.seed + 3);
  for (let i = 0; i < 3; i++) { const px = (-11 + i * 9 + R() * 4) * u, py = (-21 + R() * 8) * u; poly(c, ellipse(px, py, (3.5 + R() * 3) * u, (2.6 + R() * 2) * u, 12, 0, TAU, R())); c.fillStyle = INK; c.fill(); }
  c.restore();
  c.beginPath(); loop(c, body, DET, 3); c.fillStyle = INK; c.fill();
  // head, muzzle (it chews), horns, an ear
  head(c, u, o, t, 15, -24, [19, -13], 0.95, chew => {
    const face = curve([[15 * u, -29 * u], [21 * u, -31 * u], [24.5 * u, -26 * u], [24.5 * u, -20 * u], [18 * u, -19.5 * u], [15 * u, -24 * u]], 2, true);
    shape(c, face, white, DET, 4);
    const my = (-21 + Math.max(0, chew) * 0.7) * u;
    shape(c, ellipse(23 * u, my, 4 * u, 3 * u, 14), mul(C.pink, P.paper), TEX * 1.2, 2);
    dot(c, 22 * u, my, 0.7 * u, INK); dot(c, 24.6 * u, my - 0.2 * u, 0.7 * u, INK);
    if (ja >= 0) { c.beginPath(); ribbon(c, ellipse(20.2 * u, -25.8 * u, 1.5 * u, 1.1 * u, 8, Math.PI * 1.1, Math.PI * 1.9), TEX, 6, { tin: 1, tout: 1, amp: 0.1 }); c.fillStyle = INK; c.fill(); }
    else if (NAP) napEye(c, 20.2 * u, -26.6 * u, 1.3 * u, INK);
    else dot(c, 20.2 * u, -26.6 * u, 1.05 * u, INK);
    c.beginPath();
    ribbon(c, [[16.5 * u, -29.5 * u], [15 * u, -33.5 * u], [16.5 * u, -36 * u]], TEX * 1.3, 1, { tin: 1, tout: 2 });
    ribbon(c, [[21 * u, -31 * u], [22.5 * u, -34.5 * u], [21.5 * u, -37 * u]], TEX * 1.3, 2, { tin: 1, tout: 2 });
    c.fillStyle = INK; c.fill();
    poly(c, ellipse(13.6 * u, -27.5 * u, 3 * u, 1.5 * u, 10, 0, TAU, 0.4 + chew * 0.2)); c.fillStyle = INK; c.fill();
  });
}
function drawGull(c, u, white, o, t) {
  const fl = o.state === 'hover' ? 2 * u : Math.sin(t * 9 + o.seed) * 6 * u;
  c.beginPath();
  ribbon(c, curve([[-1 * u, -4 * u], [-8 * u, -11 * u - fl * 0.4], [-14 * u, -10 * u - fl], [-20 * u, -6 * u - fl]], 2), DET * 1.15, 3, { tin: 2, tout: 6, w0: 1, w1: 0.2 });
  ribbon(c, curve([[2 * u, -4 * u], [8 * u, -11 * u - fl * 0.4], [14 * u, -10 * u - fl], [20 * u, -6 * u - fl]], 2), DET * 1.15, 4, { tin: 2, tout: 6, w0: 1, w1: 0.2 });
  c.fillStyle = INK; c.fill();
  shape(c, ellipse(0, -2.5 * u, 7.5 * u, 3.6 * u, 18), white, DET * 0.9, 1);
  dot(c, 5 * u, -4 * u, 3 * u + REGX * 0.2, white);
  poly(c, [[7 * u, -4 * u], [12 * u, -3 * u], [7 * u, -1.8 * u]]); c.fillStyle = rgba(C.beak); c.fill();
  dot(c, 5.6 * u, -4.6 * u, 0.8 * u, INK);
}
function drawDuck(c, u, yellow, P, o, t) {
  const body = curve([[-12 * u, -8 * u], [-14 * u, -13 * u], [-8 * u, -10 * u], [2 * u, -10.5 * u], [10 * u, -8 * u], [11 * u, -3 * u], [4 * u, -0.5 * u], [-8 * u, -0.5 * u]], 2, true);
  shape(c, body, yellow, DET, 1);
  const head = ellipse(6.5 * u, -15 * u, 6 * u, 5.6 * u, 22);
  shape(c, head, yellow, DET, 2);
  const beak = [[11.5 * u, -15.5 * u], [17.5 * u, -14 * u], [16 * u, -12 * u], [11.5 * u, -12.2 * u]];
  print(c, beak, C.beak);
  c.beginPath(); loop(c, dens(beak, 2, true), TEX * 1.2, 5); ribbon(c, ellipse(-1 * u, -6 * u, 6 * u, 3 * u, 10, 0.2, 2.2), TEX, 6, { tin: 1, tout: 2 }); c.fillStyle = INK; c.fill();
  if (NAP) napEye(c, 8 * u, -16.5 * u, 1.4 * u, INK);
  else { dot(c, 8 * u, -16.5 * u, 1.35 * u, INK); dot(c, 7.6 * u, -17 * u, 0.45 * u, '#FFFFFF'); }
  // a little water at the waterline
  c.beginPath(); ribbon(c, [[-13 * u, 0.5 * u], [-4 * u, -1.2 * u], [5 * u, 0.6 * u], [13 * u, -0.6 * u]], TEX, 7, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
}
function drawMonster(c, u, pink, P, o, t) {
  const sw = Math.sin(t * 1.6 + o.seed);
  for (let i = 0; i < 3; i++) {
    const hx = (-30 + i * 19) * u, hh = (8 + 2.5 * Math.sin(t * 2 + i * 1.3)) * u * (0.85 + 0.15 * sw);
    const hump = ellipse(hx, 1 * u, 8.5 * u, hh, 14, Math.PI, TAU);
    print(c, [...hump, [hx + 8.5 * u, 1 * u]], pink);
    c.beginPath(); ribbon(c, hump, DET, i, { tin: 2, tout: 2, outline: true }); c.fillStyle = INK; c.fill();
    c.beginPath(); ribbon(c, [[hx - 11 * u, 1.5 * u], [hx, 0], [hx + 11 * u, 1.5 * u]], TEX, i + 4, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
  }
  const neck = curve([[20 * u, 1 * u], [22 * u, -10 * u], [27 * u, -20 * u], [34 * u, -25 * u], [42 * u, -26 * u], [48 * u, -21 * u], [46 * u, -16 * u], [38 * u, -16 * u], [33 * u, -11 * u], [31 * u, 1 * u]], 2);
  print(c, neck, pink);
  c.beginPath(); ribbon(c, neck, DET, 7, { tin: 2, tout: 2, outline: true }); c.fillStyle = INK; c.fill();
  c.beginPath(); ribbon(c, [[16 * u, 1.5 * u], [26 * u, 0], [36 * u, 1.5 * u]], TEX, 8, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
  dot(c, 41 * u, -21.5 * u, 2.6 * u, '#FFFFFF');
  c.beginPath(); ribbon(c, ellipse(41 * u, -21.5 * u, 2.6 * u, 2.6 * u, 10), TEX, 9, { tin: 1, tout: 1, w0: 1, w1: 1, outline: true }); c.fillStyle = INK; c.fill();
  dot(c, 41.8 * u, -21.3 * u, 1.1 * u, INK);
  c.beginPath(); ribbon(c, [[45 * u, -18 * u], [47 * u, -17.6 * u]], TEX, 10, { tin: 1, tout: 1 }); c.fill();
  // its little top hat, with a red band
  const hat = [[36 * u, -25.5 * u], [37 * u, -35 * u], [45 * u, -35.5 * u], [45.5 * u, -26 * u]];
  poly(c, hat); c.fillStyle = INK; c.fill();
  c.fillStyle = rgba(mul(C.chimney, P.paper)); c.fillRect(36.6 * u, -29.5 * u, 8.6 * u, 2 * u);
  c.beginPath(); ribbon(c, [[33 * u, -25.8 * u], [49 * u, -26.4 * u]], DET * 1.2, 2, { tin: 1, tout: 1, w0: 1, w1: 1 }); c.fillStyle = INK; c.fill();
}

/* ---------- the lighthouse plays with the bar: the ball, its doodles and the splash ---------- */
function drawBall(s, c) {
  const b = s.ball;
  if (!b) return;
  const g = s.g, u = g.u, pr = g.lh.er * 0.66, v = Math.hypot(b.vx, b.vy);
  // a couple of speed lines behind it when it's going
  if (v > 240 * u && !s.reduced) {
    const ax = -b.vx / v, ay = -b.vy / v, nx = -ay, ny = ax, l = pr * clamp(v / (700 * u), 0.6, 1.4);
    c.beginPath();
    for (const k of [-0.5, 0.42]) {
      const x0 = b.x + ax * pr * 1.4 + nx * pr * k, y0 = b.y + ay * pr * 1.4 + ny * pr * k;
      ribbon(c, [[x0, y0], [x0 + ax * l * (1 - k * 0.3), y0 + ay * l * (1 - k * 0.3)]], TEX, 30 + k * 5, { tin: 1, tout: 4 });
    }
    c.fillStyle = INK; c.fill();
  }
  // squashed for a moment by a hit or a header
  const q = s.t - b.sq, sq = q < 0.16 ? Math.sin(q / 0.16 * Math.PI) * 0.24 : 0;
  c.save(); c.translate(b.x, b.y); c.scale(1 + sq, 1 - sq);
  bobble(c, 0, 0, pr, mul(hex('#FFFFFF'), s.P.paper), b.spin);
  c.restore();
}

/* a quaver, drawn: a tilted head, a stem and a flag */
function quaver(c, x, y, sz, col, flip) {
  c.beginPath(); c.ellipse(x, y, sz * 0.62, sz * 0.44, -0.45, 0, TAU); c.fillStyle = col; c.fill();
  c.beginPath();
  ribbon(c, [[x + sz * 0.52, y - sz * 0.1], [x + sz * 0.56, y - sz * 2.1]], TEX * 1.2, 3, { tin: 1, tout: 1, w0: 0.9, w1: 0.9 });
  ribbon(c, [[x + sz * 0.56, y - sz * 2.1], [x + sz * (0.56 + 0.6 * flip), y - sz * 1.62], [x + sz * (0.56 + 0.45 * flip), y - sz * 1.0]], TEX * 1.1, 4, { tin: 1, tout: 3 });
  c.fillStyle = col; c.fill();
}

/* "boink!", "pok", "plop", "hehe", the whistled notes, the grazers' "nom"s and the box's "baa!": they pop in,
   drift a little and fade (without motion they just show, and go) */
function drawDoodles(s, c) {
  if (!s.doodles.length) return;
  const g = s.g, u = g.u, P = s.P, rm = s.reduced, ink = rgba(mix(P.ink, P.paper, smooth(0.5, 0.7, s.d)));
  for (const d of s.doodles) {
    const a = s.t - d.t0, k = rm ? 1 : pop(a / 0.24), f = 1 - smooth(d.life - 0.3, d.life, a), col = d.sea ? rgba(P.paper) : ink;
    if (f <= 0 || k <= 0.01) continue;
    c.save(); c.globalAlpha = f;
    if (d.kind === 'note') {
      const sz = 4.2 * u + 1.6;
      quaver(c, d.x + Math.sin(a * 4 + d.seed) * 5 * u, d.y - a * 36 * u, sz * k, col, d.flip);
      c.restore(); continue;
    }
    const munch = d.kind === 'munch', dir = d.align === 'right' ? -1 : 1;
    const size = munch ? Math.max(11, 12 * u + 2.5) : Math.max(d.kind === 'pok' ? 12 : 13.5, (d.kind === 'pok' ? 12 : d.kind === 'boink' ? 16 : 15) * u + 4);
    const shake = d.kind === 'hehe' && !rm ? (Math.floor(a * 9) % 2 ? -1 : 1) * 1.3 * u : 0;
    c.translate(d.x, d.y - (rm ? 0 : a * (d.kind === 'plop' ? 12 : munch ? 7 : 8) * u) + shake); c.scale(k, k);
    const text = d.text || (d.kind === 'boink' ? 'boink!' : d.kind);
    label(c, text, 0, 0, size, col, d.align, d.kind === 'boink' ? -0.09 * dir : d.kind === 'pok' ? 0.12 * dir : munch ? -0.1 * dir : d.kind === 'baa' || d.kind === 'knock' ? 0.1 * dir : -0.06);
    c.beginPath();
    if (d.kind === 'boink') {
      // the knock, in three short strokes toward the widget
      for (const i of [0, 1, 2]) { const an = -Math.PI / 2 - dir * (0.25 + i * 0.42), r0 = size * 0.32, r1 = size * 0.72; ribbon(c, [[Math.cos(an) * r0, -size * 0.3 + Math.sin(an) * r0], [Math.cos(an) * r1, -size * 0.3 + Math.sin(an) * r1]], TEX * 1.1, i + 7, { tin: 1, tout: 2 }); }
    } else if (d.kind === 'baa' || d.kind === 'knock') {
      // two short strokes, from the box (or the door) toward the word
      for (const i of [0, 1]) { const an = Math.PI * (i ? 0.1 : -0.12), x0 = -dir * size * 0.6, r = size * 0.42; ribbon(c, [[x0 - dir * Math.cos(an) * r * 0.2, -size * 0.1 + Math.sin(an) * r * 0.6 + i * size * 0.38 - size * 0.12], [x0 + dir * Math.cos(an) * r * 0.55, -size * 0.1 + i * size * 0.38 - size * 0.12]], TEX * 1.1, i + 5, { tin: 1, tout: 2 }); }
    } else if (d.kind === 'plop') {
      // two drops over the word
      for (const i of [0, 1]) { const x = size * (0.45 + i * 0.85), y = -size * (0.9 + i * 0.2); ribbon(c, ellipse(x, y, size * 0.13, size * 0.18, 10, -0.6, Math.PI * 1.6), TEX, i + 3, { tin: 1, tout: 1 }); }
    }
    c.fillStyle = col; c.fill();
    c.restore();
  }
}

/* where the ball lands: a crown of water and a few drops thrown up and out, in foam with the pen round them */
function drawSplashes(s, c) {
  if (!s.splashes.length) return;
  const g = s.g, u = g.u, P = s.P, foam = rgba(P.foam);
  for (const p of s.splashes) {
    const a = s.t - p.t0, k = clamp(a / 0.7), e = easeOut(k);
    c.globalAlpha = 1 - smooth(0.6, 1, k);
    for (const [w, col] of [[DET * 2.5, INK], [DET * 1.25, foam]]) {
      c.beginPath();
      for (let i = 0; i < 5; i++) {
        const an = -Math.PI / 2 + (i - 2) * 0.46, r0 = 6 * u, r1 = r0 + (8 + 20 * e) * u * (1 - k * 0.55);
        ribbon(c, [[p.x + Math.cos(an) * r0 * 1.5, p.y + Math.sin(an) * r0 * 0.5], [p.x + Math.cos(an) * r1 * 1.5, p.y + Math.sin(an) * r1]], w, i, { tin: 2, tout: 3, amp: 0.4 });
      }
      c.fillStyle = col; c.fill();
    }
    for (let i = 0; i < 4; i++) {
      const dx = (i - 1.5) * (10 + 22 * e) * u, dy = -(30 + i % 2 * 10) * u * e + 70 * u * k * k, x = p.x + dx, y = p.y + dy, r = (2.8 - 1.4 * k) * u + 0.8;
      if (y > p.y + 2) continue;
      dot(c, x, y, r, foam);
      c.beginPath(); ribbon(c, ellipse(x, y, r + 0.6, r + 0.6, 10), TEX * 0.8, i, { tin: 1, tout: 1, w0: 1, w1: 1, outline: true }); c.fillStyle = INK; c.fill();
    }
    c.globalAlpha = 1;
  }
}

window.Hill = {
  Scene, themes: Object.keys(THEMES), states: STATES, islands: ISLANDS.length,
  // for the styles (see STYLES): style registers one, felt is the felt pen's with every lever
  style, felt: FELT, PAL, THEMES, BOX, STEPS, SIL, DET, TEX, DIVE_GAP, SHORE, FAR,

  TAU, clamp, lerp, smooth, easeOut, hash, noise, rng, hex, mix, mul, rgba, angDiff, stops, palAt,
  curve, dens, ellipse, poly, inPoly, cloudPts, ink, loop, edges, shape, dot, label, arrow, quaver, bobble, pop,
  hatGeom, head, napEye, joyAt, beamPoly, waveScallops, rank, lightK, view, afloat, hutSpots, deskSpot, seaLabelSpot, textW,
  // what the style being drawn has on
  get C() { return C; }, get INK() { return INK; }, get PW() { return PW; }, get BOIL() { return BOIL; }, get NAP() { return NAP; },
  get REGX() { return REGX; }, get REGY() { return REGY; }, get HAND() { return HAND; }, get ribbon() { return ribbon; }, get print() { return print; },
};
})();
