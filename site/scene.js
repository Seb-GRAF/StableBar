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
const rgba = (c, a = 1) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;
const angDiff = (a, b) => { let d = (a - b) % TAU; if (d > Math.PI) d -= TAU; if (d < -Math.PI) d += TAU; return d; };
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
const C = {
  wool: hex('#FFFFFF'), yolk: hex('#FFC21A'), duck: hex('#FFD21F'), beak: hex('#FF7A1A'), pink: hex('#FF9CB0'),
  monster: hex('#FF8FC0'), chimney: hex('#E8452F'), roof: hex('#2B2B36'), door: hex('#2E58D8'), skin: hex('#F6C9A6'),
  navy: hex('#25305E'), wood: hex('#C98B4A'), steel: hex('#D8DCE6'), moon: hex('#FFE89A'), tile: hex('#1D1D24'),
  huts: ['#FF4A36', '#2E58D8', '#FFC21A', '#36A852'].map(hex),
};
const HAND = '"Shantell Sans Hand", "Shantell Sans", "Chalkboard SE", sans-serif';

/* ---------- the pen ----------
   One felt pen in three weights. Every stroke is a filled ribbon whose width follows the pen's
   pressure: thin where it lands and lifts, a little uneven along the way. The line boils between
   three states; the printed fills don't boil and sit one constant vector off the line. */
let BOIL = 0, PW = 1, INK = '#111', REGX = 2.6, REGY = 1.9;
const SIL = 3.2, DET = 2.1, TEX = 1.35;

function ribbon(c, pts, w, sd = 0, o = {}) {
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
  ribbon(c, out, w, sd, { tin: 5, tout: 12, w0: 0.55, w1: 0.12, ...o });
}
/* Straight edges, each its own stroke running a little past the corners */
function edges(c, corners, w, sd = 0, closed = true, o = {}) {
  const m = corners.length, ov = (o.ov ?? 2.6) * PW;
  for (let i = 0; i < (closed ? m : m - 1); i++) {
    const [x0, y0] = corners[i], [x1, y1] = corners[(i + 1) % m], l = Math.hypot(x1 - x0, y1 - y0) || 1, ux = (x1 - x0) / l, uy = (y1 - y0) / l;
    const a = hash(sd * 3.1 + i) * ov, b = hash(sd * 5.7 + i + 0.5) * ov;
    ribbon(c, dens([[x0 - ux * a, y0 - uy * a], [x1 + ux * b, y1 + uy * b]], 5), w, sd + i * 1.7, { tin: 4, tout: 6, w0: 0.6, w1: 0.45, ...o });
  }
}
/* A printed fill, off the line by the register vector */
function print(c, pts, col) { poly(c, pts, true, REGX, REGY); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill(); }
function shape(c, pts, col, w = DET, sd = 0, o) { print(c, pts, col); c.beginPath(); loop(c, pts, w, sd, o); c.fillStyle = INK; c.fill(); }
function dot(c, x, y, r, col) { c.beginPath(); c.arc(x, y, r, 0, TAU); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill(); }
function label(c, text, x, y, size, col, align = 'left', rot = -0.035) {
  c.save(); c.translate(x, y); c.rotate(rot);
  c.font = `400 ${size}px ${HAND}`; c.textAlign = align; c.textBaseline = 'middle'; c.fillStyle = col;
  c.fillText(text, 0, 0); c.restore();
}

/* ---------- the scene: geometry, state, input and time ---------- */
const IDLE_AFTER = 4000, IDLE_FPS = 14, BOIL_FPS = 7, MAX_OBJS = 36;

class Scene {
  constructor(host, opts = {}) {
    this.o = Object.assign({ topInset: 0, dusk: 0, seed: 11 }, opts);
    this.host = host;
    const cv = this.canvas = document.createElement('canvas');
    cv.setAttribute('aria-hidden', 'true');
    cv.style.cssText = 'position:absolute;left:0;top:0;display:block;pointer-events:none';
    host.appendChild(cv);
    this.ctx = cv.getContext('2d');
    this.top = Math.max(0, +this.o.topInset || 0);
    this.t = 0; this.d = this.dTarget = clamp(+this.o.dusk || 0);
    this.state = 'hero'; this.theme = 'built-in'; this.ws = 1;
    this.pres = Object.fromEntries(STATES.map(k => [k, k === 'hero' ? 1 : 0]));
    this.since = Object.fromEntries(STATES.map(k => [k, 0]));
    this.ptr = { x: 0, y: 0, on: false, last: -1e9, kind: 'mouse' };
    this.vel = { x: 0, y: 0 };
    this.wind = 0; this.windAmb = 0.3; this.windTotal = 0.3; this.drift = 0;
    this.beam = { a: Math.PI * 0.96, len: 1, flash: 0, phi: Math.PI * 0.96, steer: 0, sa: Math.PI * 0.96 };
    this.blink = { next: 2.5, at: -9, wink: -9 };
    this.ripples = []; this.objs = [];
    this.layers = { back: [], front: [] };
    this.sprites = new Map();
    this.fontsV = 0; this.layoutV = 0; this.sparkle = -9; this.rebuilds = 0;
    this.onFrame = null;
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
    this.onVis = () => { if (document.hidden) this.sleep(); else { this.last = null; this.wake(); } };
    document.addEventListener('visibilitychange', this.onVis);
    const fontsIn = () => { this.fontsV++; this.wake(); };
    if (document.fonts) {
      document.fonts.load(`400 16px ${HAND}`).then(fontsIn, () => {});
      document.fonts.addEventListener?.('loadingdone', fontsIn);
    }
    this.wake();
  }

  /* ----- page state ----- */
  setDusk(d) { this.dTarget = clamp(+d || 0); if (this.reduced) this.d = this.dTarget; this.wake(); }
  setState(name) {
    if (!STATES.includes(name)) return;
    if (name !== this.state) { this.state = name; this.since[name] = this.t; }
    this.wake();
  }
  setTheme(id) {
    if (!THEMES[id]) return;
    if (id !== this.theme) { this.theme = id; if (this.t > 0.5) this.sparkle = this.t; }
    this.wake();
  }
  setWorkspace(n) { this.ws = clamp(Math.round(+n || 1), 1, 4); this.wake(); }
  setTopInset(px) { const v = Math.max(0, +px || 0); if (v !== this.top) { this.top = v; this.layout(); } this.wake(); }
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
  sky() { const c = this.P?.sky; return c ? '#' + c.map(v => Math.round(v).toString(16).padStart(2, '0')).join('') : null; }

  /* ----- input, in client coordinates ----- */
  pointer(x, y, kind = 'mouse') {
    x -= this.ox; y -= this.oy;
    const now = performance.now() / 1000;
    if (this.ptr.on && now - this.ptr.last < 0.25) {
      const dt = Math.max(0.008, now - this.ptr.last);
      this.vel.x = lerp(this.vel.x, (x - this.ptr.x) / dt, 0.35);
      this.vel.y = lerp(this.vel.y, (y - this.ptr.y) / dt, 0.35);
    }
    Object.assign(this.ptr, { x, y, on: true, last: now, kind: kind || 'mouse' });
    const sp = Math.hypot(this.vel.x, this.vel.y);
    if (!this.reduced && sp > 650 && this.isSea(x, y) && now - (this.lastRip || 0) > 0.11) {
      this.lastRip = now;
      this.ripples.push({ x, y, t0: this.t, a: Math.min(1, sp / 2400) * 0.9 });
    }
    if (this.reduced) this.aim(x, y);
    this.wake();
  }
  release() { this.ptr.on = false; this.wake(); }
  tap(x, y) {
    x -= this.ox; y -= this.oy;
    this.aim(x, y);
    this.wake();
    const g = this.g, T = g.lh;
    if (y < this.top) return false;
    // the lighthouse winks instead of catching things
    if (Math.abs(x - T.x) < T.wB * 0.75 && y > T.hatTop && y < T.base) { this.blink.wink = this.t; return false; }
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
    this.canvas.width = Math.round(W * this.dpr); this.canvas.height = Math.round(H * this.dpr);
    this.canvas.style.width = W + 'px'; this.canvas.style.height = H + 'px';
    this.layout();
    return true;
  }

  layout() {
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
    const T = g.lh = { x: lx };
    if (portrait) {
      T.base = top + Hs * 0.31 + 2 * u;
      T.er = clamp(W * 0.036, 11.5, 22);
      const lampY = top + H * 0.1;
      T.gal = T.er * 0.62;
      T.top = lampY + T.er * 1.02 + T.gal;
      T.h = T.base - T.top;
    } else {
      T.base = this.ridgeY(lx) + 2 * u;
      T.h = Math.min(Hs * 0.27 * 1.32, W * 0.3);
      T.er = T.h * 0.062;
      T.gal = T.er * 0.62;
      T.top = T.base - T.h;
    }
    T.wT = T.er * 1.62; T.wB = T.er * 2.6;
    g.lamp = { x: lx, y: T.top - T.gal - T.er * 1.02 };
    T.hatTop = g.lamp.y - T.er * 3.6;
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
    // the far island and its smaller lighthouse
    g.isle = portrait ? { x0: 0.03 * W, x1: 0.24 * W, h: 20 * u + 8 } : { x0: 0.49 * W, x1: 0.585 * W, h: 22 * u };
    g.sun = portrait ? { x: 0.3 * W, y0: top + H * 0.115 } : { x: 0.57 * W, y0: top + sky * 0.3 };
    g.moon = portrait ? { x: 0.08 * W + 6, y1: top + H * 0.15 } : { x: 0.6 * W, y1: top + sky * 0.44 };

    // the sea: rows of scallops, sparse and small near the horizon
    const rows = portrait ? Math.round(clamp((H - g.horizon) / 11, 26, 60)) : Math.round(18 + 14 * Math.min(1, u));
    g.rows = [];
    for (let i = 1; i <= rows; i++) {
      const f = i / rows, y = g.horizon + (H - g.horizon) * Math.pow(f, 1.6);
      g.rows.push({ y, f, seed: i * 97 + this.o.seed, spans: this.seaSpans(y) });
    }
    // grass tufts along the ridge, a few
    g.tufts = [];
    for (let x = g.ridge[0][0] + 14 * u; x < W; x += (26 + R() * 30) * u) {
      const y = this.ridgeY(x);
      if (y == null || y > H + 4 || Math.abs(x - lx) < T.wB * 0.7 || (x > g.cot.x - g.cot.w * 0.55 && x < g.cot.x + g.cot.w * 0.5)) continue;
      g.tufts.push({ x, y, l: (8 + R() * 7) * Math.max(u, 0.62), p: R() * TAU, n: 2 + ((R() * 2.2) | 0) });
    }
    // where the page's notes sit (a guess, for placing labels and surprises)
    g.note = portrait ? { x0: 0, x1: W, y0: top + Hs * 0.24, y1: H } : { x0: 0, x1: W * 0.05 + Math.min(W * 0.46, 620) + 12, y0: top, y1: H * 0.84 };
    g.key = portrait ? null : { x0: 0, x1: W * 0.05 + 440, y0: H - 160, y1: H };
    this.layoutV++;
    for (const o of this.objs) this.settle(o);
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
        x = g.portrait ? lerp(0.36, 0.95, R()) * W : lerp(0.56, 0.97, R()) * W;
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
      const riders = cl => this.objs.filter(o => o.ride === cl && o.dying == null).length + R() * 0.5;
      for (const cl of [...g.clouds, g.sheepCloud].sort((a, b) => riders(a) - riders(b))) {
        const p = this.cloudXY(cl);
        if (p.x > 40 * u && p.x < W - 40 * u && Math.hypot(p.x - g.lamp.x, p.y - g.lamp.y) > T.er * 5 && this.seen(p.x, p.y - cl.w * 0.2)) return { x: p.x, y: p.y, cloud: cl };
      }
    }
    // nothing visible: drop it where it belongs anyway, falling from the sky
    const p = tries[0] || { x: W * 0.8, y: H * 0.8 };
    return { ...p, fromSky: true };
  }

  spawn(x, y, kind, settled, fromSky) {
    const g = this.g, u = g.u, R = Math.random;
    const land = this.isLand(x, y), sea = this.isSea(x, y);
    const o = { x, y, vx: 0, vy: 0, t0: this.t, flip: R() < 0.5, seed: (R() * 1e4) | 0, lit: 0, kind };
    if (!o.kind) {
      if (land) o.kind = R() < 0.6 ? 'sheep' : 'cow';
      else if (sea) o.kind = R() < 0.55 ? 'duck' : 'monster';
      else if (y < lerp(g.top, g.horizon, 0.55) && R() < 0.45) o.kind = 'gull';
      else o.kind = this.ridgeY(x) != null && y < this.shoreY(x) && x > (g.portrait ? 0 : this.hillLeftX(g.horizon) - 20 * u) ? (R() < 0.6 ? 'sheep' : 'cow') : (R() < 0.6 ? 'duck' : 'monster');
    }
    const still = settled || this.reduced;
    if (o.kind === 'gull') {
      o.state = 'fly'; o.vx = (o.flip ? -1 : 1) * (60 + R() * 60) * u; o.vy = -(6 + R() * 18) * u; o.sc = 1.15;
      if (this.reduced) { o.vx = 0; o.vy = 0; o.state = 'hover'; }
    } else if (o.kind === 'sheep' || o.kind === 'cow') {
      let ry = this.ridgeY(x);
      if (ry == null) { o.x = x = clamp(x, g.ridge[0][0] + 20 * u, g.W - 14 * u); ry = this.ridgeY(x); }
      const room = this.shoreY(x) - ry - 14 * u;
      o.depth = land ? clamp(y - ry, 3 * u, Math.min(room, g.H - ry - 24 * u)) : clamp((6 + R() * 40) * u, 3 * u, room);
      o.ty = ry + o.depth;
      if (still || land && !fromSky) { o.state = 'land'; o.y = o.ty; o.land = still ? -9 : this.t; }
      else { o.state = 'fall'; if (fromSky) o.y = Math.min(o.ty - 120 * u, g.top - 20); }
      o.sc = this.depthScale(o.ty);
    } else {
      o.ty = sea ? y : g.horizon + (g.H - g.horizon) * (0.16 + R() * 0.55);
      if (!sea) { const sp = this.seaSpans(o.ty); const s = sp.find(q => q[0] <= x && x <= q[1]) || sp[0]; if (s) o.x = clamp(x, s[0] + 24 * u, s[1] - 30 * u); }
      if (o.kind === 'monster' || still || sea && !fromSky) { o.y = o.ty; o.state = o.kind === 'monster' ? 'swim' : 'float'; if (!this.reduced) this.ripples.push({ x: o.x, y: o.ty, t0: this.t, a: 0.8 }); }
      else { o.state = 'fall'; if (fromSky) o.y = Math.min(o.ty - 120 * u, g.top - 20); }
      o.sc = this.depthScale(o.ty);
    }
    this.objs.push(o);
    const live = this.objs.filter(q => q.dying == null);
    if (live.length > MAX_OBJS) live[0].dying = this.t;
    return o;
  }
  ride(kind, cl) {
    const g = this.g, R = Math.random, p = this.cloudXY(cl);
    const o = { kind, ride: cl, dx: (R() - 0.5) * cl.w * 0.3, x: p.x, y: 0, vx: 0, vy: 0, t0: this.t, flip: R() < 0.5, seed: (R() * 1e4) | 0, lit: 0, sc: 0.85 * (g.portrait ? 1.1 : 1) };
    o.x = p.x + o.dx; o.ty = this.rideY(o);
    if (this.reduced) { o.state = 'ride'; o.y = o.ty; o.land = -9; } else { o.state = 'fall'; o.y = g.top - 30; }
    this.objs.push(o);
    const live = this.objs.filter(q => q.dying == null);
    if (live.length > MAX_OBJS) live[0].dying = this.t;
    return o;
  }
  rideY(o) { const p = this.cloudXY(o.ride); return p.y - o.ride.w * 0.17; }
  // reduced motion switched on: whatever is moving stops where it is
  still() {
    for (const o of this.objs) {
      if (o.state === 'fly') { o.state = 'hover'; o.vx = o.vy = 0; }
      else if (o.state === 'fall') { o.y = o.ty; o.vy = 0; o.state = o.ride ? 'ride' : o.kind === 'duck' ? 'float' : 'land'; }
      o.land = -9;
      if (o.dying != null) o.dead = true;
    }
    this.objs = this.objs.filter(o => !o.dead);
    this.ripples = [];
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
    const active = this.kick > 0 || performance.now() < this.awake || this.busy();
    if (active) this.raf = requestAnimationFrame(this.frame);
    else if (!this.reduced) this.timer = setTimeout(() => { this.timer = 0; this.raf = requestAnimationFrame(this.frame); }, 1000 / IDLE_FPS - 6);
    // reduced motion and nothing moving: the scene sleeps until the next call or input
  }
  busy() {
    if (this.d !== (this.dEff ?? this.dTarget) || (this.state === 'install') !== (this.pres.install > 0.999)) return true;
    for (const k of STATES) { const p = this.pres[k]; if (p > 0.001 && p < 0.999) return true; }
    if (this.ripples.length) return true;
    for (const o of this.objs) if (o.state === 'fall' || (o.state === 'fly' && !this.reduced) || o.dying != null || (o.land > 0 && this.t - o.land < 0.4)) return true;
    return this.beam.steer > 0.01 && this.beam.steer < 0.99 && !this.reduced;
  }
  frame(now) {
    this.raf = 0;
    if (this.dead || document.hidden) return;
    this.kick--;
    const dt = this.last == null ? 1 / 60 : Math.min(0.1, Math.max(0, (now - this.last) / 1000));
    this.last = now;
    this.update(dt);
    const t0 = performance.now();
    this.render();
    this.times.push(performance.now() - t0);
    if (this.times.length > 240) this.times.shift();
    this.onFrame?.(this);
    this.schedule();
  }
  update(dt) {
    const g = this.g, u = g.u, rm = this.reduced;
    this.t += dt;
    for (const k of STATES) {
      const want = k === this.state ? 1 : 0;
      this.pres[k] = rm ? want : clamp(this.pres[k] + Math.sign(want - this.pres[k]) * dt * 1.8);
    }
    // the install state brings the night with it
    const dTarget = this.dEff = Math.max(this.dTarget, this.pres.install > 0 ? lerp(this.dTarget, 1, this.pres.install) : 0);
    this.d = rm ? dTarget : this.d + (dTarget - this.d) * Math.min(1, dt * 2.4);
    if (Math.abs(dTarget - this.d) < 0.0005) this.d = dTarget;
    this.boil = rm ? 0 : Math.floor(this.t * BOIL_FPS) % 3;
    this.vel.x *= Math.exp(-dt * 2.5); this.vel.y *= Math.exp(-dt * 2.5);
    this.windAmb = rm ? 0.2 : 0.28 + 0.22 * noise(this.t * 0.13 + 3);
    this.wind = lerp(this.wind, clamp(this.vel.x / 1300, -1.5, 1.5), Math.min(1, dt * 1.8));
    this.windTotal = this.windAmb + this.wind;
    if (!rm) this.drift += dt * (1 + this.windTotal * 2.4);
    // clouds lean away from the pointer
    for (const cl of [...g.clouds, g.sheepCloud]) {
      let tx = 0, ty = 0;
      if (this.ptr.on && !rm) {
        const p = this.cloudXY(cl, true), dx = p.x - this.ptr.x, dy = p.y - this.ptr.y, r = 170 * u, dd = Math.hypot(dx, dy);
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
    this.updateBeam(dt);
    this.ripples = this.ripples.filter(r => this.t - r.t0 < 2.2);
    this.updateObjs(dt);
  }
  updateBeam(dt) {
    const b = this.beam, L = this.g.lamp, now = performance.now() / 1000, rm = this.reduced;
    const quiet = this.ptr.kind === 'touch' ? 3.2 : 5;
    const steering = this.ptr.on && now - this.ptr.last < quiet;
    b.steer = rm ? (steering || b.steer > 0.5 ? 1 : 0) : lerp(b.steer, steering ? 1 : 0, Math.min(1, dt * (steering ? 4 : 0.7)));
    if (!rm) b.phi += dt * TAU / 15;
    const c = Math.cos(b.phi), sn = Math.sin(b.phi);
    if (this.ptr.on && steering) {
      const want = this.clampAim(Math.atan2(this.ptr.y - L.y, this.ptr.x - L.x));
      b.sa = rm ? want : b.sa + angDiff(want, b.sa) * Math.min(1, dt * 5);
    }
    const vx = lerp(c, Math.cos(b.sa), b.steer), vy = lerp(0.03 * Math.abs(c), Math.sin(b.sa), b.steer);
    b.a = Math.atan2(vy, vx);
    b.len = clamp(Math.hypot(vx, vy));
    b.flash = Math.pow(Math.max(0, sn), 14) * (1 - b.steer);
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
      if (o.state === 'fall') {
        o.vy += G * dt; o.y += o.vy * dt;
        if (o.y >= o.ty) {
          o.y = o.ty; o.vy = 0; o.land = this.t;
          o.state = o.kind === 'duck' ? 'float' : 'land';
          if (o.kind === 'duck') this.ripples.push({ x: o.x, y: o.ty, t0: this.t, a: 1 });
        }
      } else if (rm) {
        // reduced motion: everything holds still where it appeared
      } else if (o.state === 'land') {
        const dx = o.x - this.ptr.x, dy = o.y - this.ptr.y, near = this.ptr.on && o.kind === 'sheep' && dx * dx + dy * dy < (110 * u) ** 2;
        const stroll = Math.sin(this.t * 0.35 + o.seed) > 0.8 ? (o.flip ? -1 : 1) * (o.kind === 'cow' ? 7 : 12) * u : 0;
        o.vx = lerp(o.vx, near ? Math.sign(dx || 1) * 70 * u : stroll, Math.min(1, dt * 3));
        if (Math.abs(o.vx) > 3 * u) o.flip = o.vx < 0;
        const nx = o.x + o.vx * dt, ry = this.ridgeY(nx);
        if (ry == null || ry + o.depth > Math.min(g.H - 8 * u, this.shoreY(nx) - 12 * u) || nx > g.W - 12 * u || Math.abs(nx - g.lh.x) < g.lh.wB * 0.6) o.vx = 0;
        else { o.x = nx; o.y = ry + o.depth; }
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
    this.objs = this.objs.filter(o => !o.dead);
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
    const c = this.ctx, g = this.g, k = this.dpr;
    const step = Math.round(this.d * STEPS);
    this.P = palAt(PAL, step / STEPS);
    this.pstep = step;
    BOIL = this.boil; PW = g.pw; INK = rgba(this.P.ink); REGX = 2.6 * g.pw; REGY = 1.9 * g.pw;
    c.setTransform(k, 0, 0, k, 0, 0);
    c.globalAlpha = 1; c.globalCompositeOperation = 'source-over';
    drawScene(this, c);
  }
  /* A cached layer: one per boil state, redrawn when the hour, the theme or the layout changes */
  layer(name, rect, draw) {
    const key = `${this.layoutV}|${this.pstep}|${this.theme}|${this.fontsV}`;
    const L = this.layers[name][this.boil] ||= { cv: document.createElement('canvas'), key: '' };
    const k = this.dpr, x0 = Math.floor(rect.x * k), y0 = Math.floor(rect.y * k), w = Math.ceil(rect.w * k), h = Math.ceil(rect.h * k);
    if (L.key !== key) {
      if (L.cv.width !== w || L.cv.height !== h) { L.cv.width = w; L.cv.height = h; }
      const c = L.cv.getContext('2d');
      c.setTransform(1, 0, 0, 1, 0, 0); c.clearRect(0, 0, w, h);
      c.setTransform(k, 0, 0, k, -x0, -y0);
      draw(c);
      L.key = key;
      this.rebuilds++;
    }
    const c = this.ctx;
    c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.drawImage(L.cv, x0, y0); c.restore();
  }
  /* A small cached drawing (a cloud, the sun), drawn around its own origin */
  sprite(name, w, h, x, y, draw) {
    const key = `${name}|${this.layoutV}|${this.boil}|${this.pstep}|${this.fontsV}`, k = this.dpr;
    let s = this.sprites.get(key);
    if (!s) {
      const cv = document.createElement('canvas');
      cv.width = Math.ceil(w * k); cv.height = Math.ceil(h * k);
      const c = cv.getContext('2d');
      c.setTransform(k, 0, 0, k, w * k / 2, h * k / 2);
      draw(c);
      s = { cv, w, h };
      this.sprites.set(key, s);
      if (this.sprites.size > 60) this.sprites.delete(this.sprites.keys().next().value);
    }
    const c = this.ctx;
    c.save(); c.setTransform(1, 0, 0, 1, 0, 0);
    c.drawImage(s.cv, Math.round((x - w / 2) * k), Math.round((y - h / 2) * k));
    c.restore();
  }
}

/* =====================================================================
   THE DRAWING
   Back to front: sky and sea, the cached band, stars, the scallops, the
   beam, then the sun, moon, clouds and far island in front of it, the
   cached hill with its cottage and tower, then everything that moves.
   ===================================================================== */
function drawScene(s, c) {
  const g = s.g, { W, H, u } = g, P = s.P;
  c.lineCap = 'round'; c.lineJoin = 'round';
  c.fillStyle = rgba(P.sky); c.fillRect(0, 0, W, g.horizon + 2);
  c.fillStyle = rgba(P.sea); c.fillRect(0, g.horizon, W, H - g.horizon);
  const bandTop = g.horizon - (g.horizon - g.top) * (g.portrait ? 0.42 : 0.36) - 20 * u;
  s.layer('back', { x: 0, y: bandTop, w: W, h: g.horizon - bandTop + 6 * u }, x => drawBand(s, x, bandTop));
  drawStars(s, c);
  drawWaves(s, c);
  drawHalo(s, c);
  drawBeam(s, c);
  drawSun(s, c);
  drawMoon(s, c);
  for (let i = 0; i < g.clouds.length; i++) drawCloud(s, c, g.clouds[i], 'cloud' + i);
  drawCloud(s, c, g.sheepCloud, 'sheepcloud', true);
  drawIsle(s, c);
  const T = g.lh, x0 = g.portrait ? g.ridge[0][0] - 8 : Math.max(0, g.ridge[0][0] - 10);
  const y0 = Math.min(T.top - T.gal * 1.2, g.cot.base - g.cot.h * 4.2) - 10 * u;
  const y1 = g.portrait ? Math.max(...g.shore.map(p => p[1])) + 14 * u : H;
  s.layer('front', { x: x0, y: y0, w: W - x0, h: y1 - y0 }, x => { drawHill(s, x); drawCottage(s, x); drawTower(s, x); });
  drawHillLight(s, c);
  drawTufts(s, c);
  drawSmoke(s, c);
  drawEye(s, c);
  drawHat(s, c);
  drawStates(s, c);
  const objs = s.objs.slice().sort((a, b) => a.y - b.y);
  for (const o of objs) drawObj(s, c, o);
  if (s.pres.hero > 0.01) drawLabels(s, c);
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

/* the competition: a much smaller lighthouse on a far island */
function drawIsle(s, c) {
  const g = s.g, u = g.u, P = s.P, I = g.isle, hz = g.horizon;
  const w = I.x1 - I.x0, h = I.h, cx = (I.x0 + I.x1) / 2, lx = I.x0 + w * 0.4, ltop = hz - h * 0.86 - 24 * u;
  s.sprite('isle', w + 30 * u, (h + 44 * u) * 2, cx, hz, x => {
    const hump = curve([[-w / 2, 0.5], [-w * 0.32, -h * 0.5], [-w * 0.08, -h * 0.86], [w * 0.16, -h * 0.8], [w * 0.38, -h * 0.4], [w / 2, 0.5]], 4);
    print(x, [...hump, [w / 2, 3], [-w / 2, 3]], P.far);
    x.beginPath(); ribbon(x, hump, DET * 0.9, 21, { tin: 3, tout: 3 }); x.fillStyle = INK; x.fill();
    // the little tower: white, two stripes, a lamp
    const tx = lx - cx, by = -h * 0.84, th = 24 * u, bw = 5.5 * u, tw = 3.6 * u;
    const body = [[tx - bw / 2, by], [tx - tw / 2, by - th], [tx + tw / 2, by - th], [tx + bw / 2, by]];
    print(x, body, mul(hex('#FFFFFF'), P.paper));
    for (const k of [0.3, 0.68]) {
      const y0 = by - th * k, y1 = by - th * (k + 0.16), w0 = lerp(bw, tw, k) / 2, w1 = lerp(bw, tw, k + 0.16) / 2;
      print(x, [[tx - w0, y0], [tx - w1, y1], [tx + w1, y1], [tx + w0, y0]], hex('#FF4A36'));
    }
    x.beginPath(); edges(x, body, TEX * 1.1, 4, false, { ov: 1 }); x.fillStyle = INK; x.fill();
  });
  // its lamp, which blinks at night in a hurry
  const night = smooth(0.4, 0.75, s.d), on = s.reduced ? 1 : (Math.sin(s.t * 3.1) > 0.2 ? 1 : 0.35);
  const ly = ltop - 3 * u;
  if (night > 0.05) { c.beginPath(); c.arc(lx, ly, (5 + 5 * on) * u, 0, TAU); c.fillStyle = rgba(P.beam, 0.35 * night * on); c.fill(); }
  dot(c, lx, ly, 2.9 * u, rgba(mix(mul(hex('#FFFFFF'), P.paper), P.beam, Math.max(0.5, night * on))));
  c.beginPath(); ribbon(c, ellipse(lx, ly, 3.2 * u, 3.2 * u, 12), TEX, 5, { tin: 1, tout: 1, w0: 1, w1: 1 }); c.fillStyle = INK; c.fill();
}

/* the sea: rows of scallops, thinning toward the horizon; ripples where things land */
function waveScallops(s, c, lit) {
  const g = s.g, u = g.u;
  for (let i = 0; i < g.rows.length; i += 2) {
    const row = g.rows[i], step = (16 + 34 * row.f) * Math.max(u, 0.66), w = (0.75 + 1.3 * row.f) * g.pw * (lit ? 1.15 : 1);
    if (row.f < 0.08 && !lit) continue;
    c.beginPath();
    for (const [a, b] of row.spans) {
      for (let x = a + hash(i) * step; x < b - step; x += step * (1.3 + hash(x * 0.1 + i) * 0.8)) {
        if (hash(x * 0.37 + i * 3.1) < 0.18 - row.f * 0.2) continue;
        const y = s.waveY(x, row), y2 = s.waveY(x + step, row);
        c.moveTo(x, y); c.quadraticCurveTo(x + step / 2, (y + y2) / 2 - step * 0.34, x + step, y2);
      }
    }
    c.lineWidth = w; c.stroke();
  }
}
function drawWaves(s, c) {
  const g = s.g, u = g.u, P = s.P;
  c.strokeStyle = rgba(P.sea2); waveScallops(s, c, false);
  for (const r of s.ripples) {
    const age = s.t - r.t0, rx = 8 * u + age * 70 * u;
    c.beginPath(); ribbon(c, ellipse(r.x, r.y, rx, rx * 0.3, 40), DET * 0.8, 4, { tin: 1, tout: 1, w0: 1, w1: 1 });
    c.fillStyle = rgba(P.foam, clamp(1 - age / 2.2) * r.a); c.fill();
  }
}

/* the light: a flat yellow fan with felt-pen edges, brighter at night */
function beamPoly(s) {
  const L = s.g.lamp, B = s.beam, len = B.len * s.diag * 1.05, hw = s.g.beamHalf;
  return { L, len, a0: B.a - hw, a1: B.a + hw };
}
function drawBeam(s, c) {
  const g = s.g, u = g.u, P = s.P, I = s.beamI(), { L, len, a0, a1 } = beamPoly(s);
  if (len < 10) return;
  const night = smooth(0.3, 0.8, s.d);
  const e0 = [L.x + Math.cos(a0) * len, L.y + Math.sin(a0) * len], e1 = [L.x + Math.cos(a1) * len, L.y + Math.sin(a1) * len];
  const fan = [[L.x, L.y], e0];
  for (let i = 1; i < 12; i++) { const a = lerp(a0, a1, i / 12); fan.push([L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]); }
  fan.push(e1);
  const col = mix(P.beam, hex('#FFF6C2'), night * 0.45);
  poly(c, fan); c.fillStyle = rgba(col, 0.84 + 0.12 * night * I); c.fill();
  // the scallops it crosses light up
  c.save(); poly(c, fan); c.clip();
  c.strokeStyle = rgba(mix(col, hex('#FFFFFF'), 0.5), 0.95); waveScallops(s, c, true);
  c.restore();
  // the pen goes along both edges, from just outside the eye
  const r0 = g.lh.er * 2.3;
  c.beginPath();
  for (const [a, sd] of [[a0, 13], [a1, 17]]) ribbon(c, dens([[L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0], [L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]], 9), DET * 0.95, sd, { tin: 20, tout: 1, w0: 0.2, w1: 1 });
  if (s.beam.len < 0.85) ribbon(c, dens(fan.slice(1), 6), DET * 0.9, 19, { tin: 3, tout: 3 });
  c.fillStyle = INK; c.fill();
}

/* where the light lands on the hill: a flat, lighter print on the grass */
function drawHillLight(s, c) {
  const { L, len, a0, a1 } = beamPoly(s);
  if (len < 10 || Math.sin(s.beam.a) < 0.08) return;
  const night = smooth(0.3, 0.8, s.d);
  c.save(); poly(c, s.g.hillClip); c.clip();
  c.beginPath(); c.moveTo(L.x, L.y);
  for (let i = 0; i <= 12; i++) { const a = lerp(a0, a1, i / 12); c.lineTo(L.x + Math.cos(a) * len, L.y + Math.sin(a) * len); }
  c.closePath(); c.fillStyle = rgba(mix(s.P.hill, s.P.beam, 0.5 + 0.2 * night)); c.fill();
  c.restore();
}

/* the lamp's halo at night: hand-drawn rings and short rays, no blur */
function drawHalo(s, c) {
  const g = s.g, u = g.u, P = s.P, L = g.lamp, er = g.lh.er;
  const night = smooth(0.35, 0.85, s.d), f = s.beam.flash, k = Math.max(night * s.beamI(), f * 0.9);
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
  print(c, g.hillPoly, P.hill);
  // the shady flank, a second flat green
  const sh = [];
  for (const [x, y] of rd) if (x < T.x - T.wB * 2) sh.push([x, y]);
  if (g.portrait) {
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
    if (g.portrait && y > s.shoreY(x) - 12 * u) continue;
    const n = 3 + ((R() * 3) | 0), l = (13 + R() * 10) * u;
    for (let k = 0; k < n; k++) {
      const hx = x + k * 5 * u, hy = y + k * 1.6 * u, lk = l * (1 - Math.abs(k - (n - 1) / 2) * 0.16);
      ribbon(c, [[hx, hy], [hx + lk * 0.42, hy + lk]], TEX, i * 5 + k, { tin: 3, tout: 5, w0: 0.45, w1: 0.2, amp: 0.4 });
    }
  }
  c.fillStyle = INK; c.fill();
  // foam where the hill meets the sea
  c.beginPath();
  const foam = g.portrait ? g.shore : rd.filter(p => p[1] > g.horizon + 3 && p[0] < T.x);
  for (let i = 2; i < foam.length - 2; i += 3) {
    const [x, y] = foam[i], [x2, y2] = foam[i + 2], nx = g.portrait ? 0 : -1, ny = g.portrait ? 1 : 0;
    const ox = nx * 5 * u, oy = ny * 5 * u, mx = (x + x2) / 2 + ox, my = (y + y2) / 2 + oy;
    if (mx < -10 || mx > W + 10 || my > H + 10 || hash(i * 0.7) < 0.3) continue;
    ribbon(c, [[x + ox, y + oy], [mx + nx * 2 * u - (g.portrait ? 0 : 1) * u, my + (g.portrait ? 3 : -2) * u], [x2 + ox, y2 + oy]], TEX * 1.1, i, { tin: 1, tout: 1, amp: 0.3 });
  }
  c.fillStyle = rgba(P.foam); c.fill();
  // the ridge, and in portrait the shore under it
  c.beginPath();
  ribbon(c, rd.filter(p => p[0] > -20 && p[0] < W + 20), SIL, 21, { tin: 4, tout: 4, w0: 0.8, w1: 0.8 });
  if (g.portrait) ribbon(c, g.shore.filter(p => p[0] < W + 20), SIL * 0.9, 23, { tin: 30, tout: 4, w0: 0.3, w1: 0.8 });
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
  // the door (it opens for the keeper: see the states)
  const dx = x0 + w * 0.56, dw = w * 0.24, dh = h * 0.66;
  k.door = { x: dx, y: k.base - dh, w: dw, h: dh };
  print(c, [[dx, k.base], [dx, k.base - dh], [dx + dw, k.base - dh], [dx + dw, k.base]], mul(C.door, P.paper));
  c.beginPath(); edges(c, [[dx, k.base], [dx, k.base - dh], [dx + dw, k.base - dh], [dx + dw, k.base]], DET * 0.85, 14, false, { ov: 1 });
  c.fillStyle = INK; c.fill();
  dot(c, dx + dw * 0.78, k.base - dh * 0.48, 1.3 * u + 0.4, INK);
}

/* the tower: white with curved stripes in the theme's colours, a door, two windows and a gallery */
function drawTower(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, th = THEMES[s.theme];
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
  ribbon(c, dens([[T.x - T.wB / 2 - 1 * u, T.base + 3 * u], [T.x - T.wT / 2, T.top - 1 * u]], 6), SIL, 31, { tin: 6, tout: 4, w0: 0.7, w1: 0.6 });
  ribbon(c, dens([[T.x + T.wB / 2 + 0.5 * u, T.base + 2 * u], [T.x + T.wT / 2, T.top - 1 * u]], 6), SIL, 33, { tin: 6, tout: 4, w0: 0.7, w1: 0.6 });
  for (let j = 1; j < bands; j++) {
    const e = edge(j / bands), cut = Math.round(e.length * (0.55 + hash(j) * 0.35));
    ribbon(c, j % 2 ? e.slice(0, cut) : e.slice(e.length - cut), TEX, 40 + j, { tin: 2, tout: 8, w0: 0.6, w1: 0.1 });
  }
  for (let j = 0; j < bands; j++) {
    const k = (j + 0.5) / bands, x = T.x + half(k) - 2.6 * u, y = yAt(k);
    for (let i = 0; i < 3; i++) ribbon(c, [[x - i * 3 * u, y - T.h / bands * 0.32], [x - i * 3 * u - 0.6 * u, y + T.h / bands * 0.3 - i * 2 * u]], TEX * 0.85, j * 3 + i, { tin: 2, tout: 2, amp: 0.3 });
  }
  for (const k of [0.25, 0.58]) edges(c, win(k, T.wB * 0.22, T.er * 0.75), TEX, 50 + k * 10, true, { ov: 0.6 });
  ribbon(c, dpts, DET * 0.9, 61, { tin: 2, tout: 2 });
  c.fillStyle = INK; c.fill();
  // the gallery: a dark deck the eye sits on
  const gw = T.wT * 0.95, gy = T.top;
  const deck = [[T.x - gw, gy + 1 * u], [T.x - gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.05, gy - T.gal * 0.42], [T.x + gw, gy + 1 * u]];
  poly(c, deck); c.fillStyle = INK; c.fill();
}

/* the eye in the lantern: an iris the colour of the light, a pupil that follows the beam, a lid */
function drawEye(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, L = g.lamp, er = T.er, B = s.beam;
  const night = smooth(0.35, 0.8, s.d);
  const rx = er * 1.32, ry = er * 1.08;
  const eye = ellipse(L.x, L.y, rx, ry, 40);
  print(c, eye, mix(mul(hex('#FFFFFF'), P.paper), P.beam, night * 0.25));
  // where it looks: along the beam, or straight at you when the light faces you
  const look = clamp(B.len * 1.3) * (1 - B.flash), pa = B.a;
  const px = L.x + Math.cos(pa) * rx * 0.42 * look, py = L.y + Math.sin(pa) * ry * 0.36 * look;
  const ir = er * (0.62 + 0.12 * B.flash), pr = er * (0.3 - 0.08 * night + 0.1 * B.flash);
  c.save(); poly(c, eye, true, REGX, REGY); c.clip();
  dot(c, px + REGX, py + REGY, ir, mix(P.beam, hex('#FFB52E'), 0.35 - 0.2 * night));
  c.restore();
  c.save(); poly(c, eye); c.clip();
  dot(c, px, py, pr, INK);
  dot(c, px - pr * 0.45, py - pr * 0.5, pr * 0.38 + 0.4, '#FFFFFF');
  c.beginPath(); ribbon(c, ellipse(px, py, ir, ir, 22), TEX, 3, { tin: 1, tout: 1, w0: 1, w1: 1, amp: 0.3 }); c.fillStyle = INK; c.fill();
  // the lid: a little heavy by day, wide awake at night, shut when it blinks or winks
  const bl = s.t - s.blink.at, wk = s.t - s.blink.wink;
  let shut = lerp(0.2, 0.02, night);
  if (bl < 0.18) shut = Math.max(shut, Math.sin(bl / 0.18 * Math.PI));
  if (wk < 0.6) shut = Math.max(shut, wk < 0.1 ? wk / 0.1 : wk < 0.45 ? 1 : 1 - (wk - 0.45) / 0.15);
  if (s.reduced && wk >= 0.6) shut = lerp(0.2, 0.02, night);
  const lidCol = rgba(mul(hex('#FFFFFF'), P.paper));
  if (shut > 0.86) {
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
  c.restore();
  c.beginPath(); loop(c, eye, SIL * 0.85, 8); c.fillStyle = INK; c.fill();
  // the gallery's railing passes in front of the eye
  const gw = T.wT * 0.95, top = T.top - T.gal * 0.42, rail = top - T.gal * 0.62;
  c.beginPath();
  ribbon(c, dens([[L.x - gw * 1.08, rail], [L.x + gw * 1.08, rail]], 4), DET * 0.9, 9, { tin: 2, tout: 2, w0: 0.8, w1: 0.8 });
  for (let i = 0; i <= 6; i++) { const x = L.x - gw + i / 6 * gw * 2; ribbon(c, [[x, top], [x, rail]], TEX * 0.95, 70 + i, { tin: 1, tout: 1, w0: 0.9, w1: 0.9, amp: 0.2 }); }
  c.fillStyle = INK; c.fill();
}

/* a knitted pom-pom hat: a ribbed brim, a long floppy cone in the theme's colour, a white bobble */
function drawHat(s, c) {
  const g = s.g, u = g.u, P = s.P, T = g.lh, L = g.lamp, er = T.er, th = THEMES[s.theme];
  const col = mul(hex(th.hat), P.paper), ry = er * 1.08;
  const sway = s.reduced ? 0.15 : 0.15 + s.windTotal * 0.25 + Math.sin(s.t * 1.3) * 0.05;
  const by = L.y - ry * 0.62, bw = er * 1.5, bh = er * 0.62;
  const tip = [L.x + er * (0.5 + sway * 2.2), by - er * 3.1 + Math.abs(sway) * er * 0.6];
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
  // the bobble: a scribbled ball of wool
  const pr = er * 0.66, pb = [];
  for (let i = 0; i < 40; i++) { const a = i / 40 * TAU, r = pr * (1 + 0.09 * Math.abs(Math.sin(a * 5.5 + 1))); pb.push([tip[0] + Math.cos(a) * r, tip[1] - pr * 0.6 + Math.sin(a) * r]); }
  shape(c, pb, mul(hex('#FFFFFF'), P.paper), DET * 0.95, 16);
  c.beginPath(); ribbon(c, ellipse(tip[0] + pr * 0.1, tip[1] - pr * 0.5, pr * 0.42, pr * 0.36, 8, 0.2, 1.9), TEX * 0.8, 90, { tin: 1, tout: 2 }); c.fillStyle = INK; c.fill();
  // a sparkle or two after changing into new pyjamas
  const sp = s.t - s.sparkle;
  if (sp < 1.2 && !s.reduced) {
    c.beginPath();
    for (let i = 0; i < 6; i++) {
      const a = -Math.PI / 2 + (i - 2.5) * 0.55, r1 = T.wB * (0.9 + sp * 1.4), r2 = r1 + 7 * u;
      const cx = T.x, cy = T.top + T.h * 0.3;
      ribbon(c, [[cx + Math.cos(a) * r1 * 1.4, cy + Math.sin(a) * r1 * 2], [cx + Math.cos(a) * r2 * 1.4, cy + Math.sin(a) * r2 * 2]], DET, i, { tin: 1, tout: 1 });
    }
    c.fillStyle = rgba(P.ink, 1 - sp / 1.2); c.fill();
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
  if (p.themes > 0.01) drawWashing(s, c, p.themes);
  if (p.tiling > 0.01) drawHuts(s, c, p.tiling);
  if (p.widgets > 0.01) drawDesk(s, c, p.widgets);
  if (p.install > 0.01) drawDoorway(s, c, p.install);
  if (p.edit > 0.01) drawEditKeeper(s, c, p.edit);
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
  // head, white beard, cap with a peak
  const head = ellipse(0.5 * u, -29 * u, 5 * u, 5.4 * u, 20);
  print(c, head, skin);
  const beard = [[-4.4 * u, -29 * u], [-3 * u, -23.5 * u], [1 * u, -22.4 * u], [5.2 * u, -24.5 * u], [5.6 * u, -28.5 * u]];
  print(c, curve(beard, 2), white);
  c.beginPath(); loop(c, head, DET, 6, { over: 0.04 }); ribbon(c, curve(beard, 2), TEX, 7, { tin: 1, tout: 1 }); c.fillStyle = INK; c.fill();
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
  drawKeeper(s, c, x, ry + 2 * u, sc, 'carry', flip, walking ? s.t * 9 : 0);
  drawTile(s, c, x + (flip ? -1 : 1) * 0.5 * u, ry + 2 * u - 42 * u * sc + Math.sin(s.reduced ? 0 : s.t * 9) * 0.6 * u, u * sc);
  c.globalAlpha = 1;
}

/* install: night, the cottage door open with warm light, the keeper waving */
function drawDoorway(s, c, p) {
  const g = s.g, u = g.u, P = s.P, k = g.cot, d = k.door;
  if (!d) return;
  const warm = hex('#FFD45C');
  c.globalAlpha = clamp(p * 1.4);
  // light spilling onto the grass
  const spill = [[d.x, k.base], [d.x + d.w, k.base], [d.x + d.w + 44 * u, k.base + 34 * u], [d.x - 34 * u, k.base + 34 * u]];
  poly(c, spill); c.fillStyle = rgba(mix(P.hill, warm, 0.62)); c.fill();
  poly(c, [[d.x, k.base], [d.x, d.y], [d.x + d.w, d.y], [d.x + d.w, k.base]]); c.fillStyle = rgba(warm); c.fill();
  // the door swung open against the wall
  const door = [[d.x + d.w, k.base], [d.x + d.w, d.y], [d.x + d.w * 1.55, d.y + 2 * u], [d.x + d.w * 1.55, k.base - 1 * u]];
  print(c, door, mul(C.door, P.paper));
  c.beginPath(); edges(c, door, DET * 0.85, 3, true, { ov: 0.6 }); c.fillStyle = INK; c.fill();
  drawKeeper(s, c, d.x + d.w * 0.5, k.base, g.portrait ? 1.05 : 1.45, 'wave', false, 0);
  c.globalAlpha = 1;
}

/* widgets: a sheep at a tiny desk with a laptop, typing */
function drawDesk(s, c, p) {
  const g = s.g, P = s.P, sc = pop(p) * (g.portrait ? 1.75 : 2.1), u = g.u * sc;
  const x = g.portrait ? g.W * 0.5 : g.W * 0.7, ry = s.ridgeY(x), y = g.portrait ? ry + (s.shoreY(x) - ry) * 0.66 : ry + g.H * 0.2;
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
    ribbon(c, ellipse(q.x, y0 - 5 * u, 3.4 * u, 3.4 * u, 12), TEX, i, { tin: 1, tout: 1, w0: 1, w1: 1 });
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
  c.font = `400 ${size}px ${HAND}`;
  if (lx + 16 * u + c.measureText('a cloud (or a sheep)').width < (g.portrait ? g.lamp.x - T.er * 1.7 : T.x - T.er * 3)) {
    label(c, 'a cloud (or a sheep)', lx + 16 * u, ly + 4 * u, size, col, 'left');
    c.fillStyle = col; arrow(c, [[lx + 12 * u, ly + 3 * u], [lx, ly + 2 * u], [p.x + w * 0.36, p.y + 6 * u]], TEX * 1.1, 9);
  }
  // the sea
  const sea = seaLabelSpot(s);
  if (sea) {
    const wTxt = c.measureText ? (c.font = `400 ${size}px ${HAND}`, c.measureText('the sea (wet)').width) : 100;
    label(c, 'the sea (wet)', sea.x, sea.y, size, rgba(P.paper, s.pres.hero), 'left');
    c.fillStyle = rgba(P.paper, s.pres.hero); arrow(c, [[sea.x + wTxt * 0.62, sea.y + 11 * u], [sea.x + wTxt * 0.5, sea.y + 22 * u], [sea.x + wTxt * 0.3, sea.y + 30 * u]], TEX * 1.1, 10);
  }
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
  c.save(); c.translate(o.x, o.y);
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
    case 'sheep': drawSheep(c, k, tint(C.wool), o, t); break;
    case 'cow': drawCow(c, k, tint(hex('#FFFFFF')), P, o, t); break;
    case 'gull': drawGull(c, k, tint(hex('#FFFFFF')), o, t); break;
    case 'duck': drawDuck(c, k, tint(C.duck), P, o, t); break;
    case 'monster': drawMonster(c, k, tint(C.monster), P, o, t); break;
  }
  c.restore();
  c.globalAlpha = 1;
}
function drawSheep(c, u, wool, o, t) {
  const fall = o.state === 'fall', step = Math.abs(o.vx) > 2 ? Math.sin(t * 14 + o.seed) * 2 * u : 0;
  c.beginPath();
  [-8, -3, 5, 10].forEach((lx, i) => ribbon(c, [[lx * u, -10 * u], [lx * u + (fall ? 3 * u : (i % 2 ? step : -step)), 0]], DET * 1.05, i, { tin: 1, tout: 1, w0: 0.9, w1: 1 }));
  c.fillStyle = INK; c.fill();
  const body = [];
  for (let i = 0; i < 40; i++) { const a = i / 40 * TAU, r = 1 + 0.13 * Math.abs(Math.sin(a * 5 + o.seed)); body.push([Math.cos(a) * 14 * u * r, -16 * u + Math.sin(a) * 9.5 * u * r]); }
  shape(c, body, wool, DET, o.seed % 7);
  // tail puff, black face, an ear, an eye
  const head = ellipse(15 * u, -19 * u, 5 * u, 6.4 * u, 18, 0, TAU, -0.35);
  poly(c, head); c.fillStyle = INK; c.fill();
  const ear = ellipse(11.5 * u, -23.5 * u, 3.6 * u, 1.6 * u, 10, 0, TAU, 0.5);
  poly(c, ear); c.fill();
  const tuft = []; for (let i = 0; i < 10; i++) { const a = Math.PI * 1.05 + i / 9 * Math.PI * 0.9; tuft.push([13.5 * u + Math.cos(a) * 5 * u, -24 * u + Math.sin(a) * 2.6 * u]); }
  c.beginPath(); ribbon(c, tuft, TEX, 3, { tin: 1, tout: 1, color: rgba(wool) }); c.fillStyle = rgba(wool); c.fill();
  dot(c, 16.6 * u, -20.5 * u, 1.5 * u, '#FFFFFF'); dot(c, 17.1 * u, -20.3 * u, 0.75 * u, INK);
}
function drawCow(c, u, white, P, o, t) {
  const step = Math.abs(o.vx) > 2 ? Math.sin(t * 9 + o.seed) * 2 * u : 0;
  c.beginPath();
  [-12, -7, 8, 13].forEach((lx, i) => ribbon(c, [[lx * u, -11 * u], [lx * u + (i % 2 ? step : -step), 0]], DET * 1.15, i, { tin: 1, tout: 1, w0: 0.9, w1: 1 }));
  ribbon(c, [[-17 * u, -20 * u], [-21 * u, -14 * u], [-20 * u, -7 * u]], TEX, 5, { tin: 1, tout: 1 });
  c.fillStyle = INK; c.fill();
  dot(c, -20 * u, -6 * u, 2 * u, INK);
  const body = curve([[-17 * u, -22 * u], [-6 * u, -26.5 * u], [10 * u, -25.5 * u], [17 * u, -20 * u], [15 * u, -11 * u], [0, -10 * u], [-16 * u, -11 * u], [-18.5 * u, -16 * u]], 3, true);
  print(c, body, white);
  // patches, inside the body
  c.save(); poly(c, body, true, REGX, REGY); c.clip();
  const R = rng(o.seed + 3);
  for (let i = 0; i < 3; i++) { const px = (-11 + i * 9 + R() * 4) * u, py = (-21 + R() * 8) * u; poly(c, ellipse(px, py, (3.5 + R() * 3) * u, (2.6 + R() * 2) * u, 12, 0, TAU, R())); c.fillStyle = INK; c.fill(); }
  c.restore();
  c.beginPath(); loop(c, body, DET, 3); c.fillStyle = INK; c.fill();
  // head, muzzle, horns, an ear
  const head = curve([[15 * u, -29 * u], [21 * u, -31 * u], [24.5 * u, -26 * u], [24.5 * u, -20 * u], [18 * u, -19.5 * u], [15 * u, -24 * u]], 2, true);
  shape(c, head, white, DET, 4);
  const muzzle = ellipse(23 * u, -21 * u, 4 * u, 3 * u, 14);
  shape(c, muzzle, mul(C.pink, P.paper), TEX * 1.2, 2);
  dot(c, 22 * u, -21 * u, 0.7 * u, INK); dot(c, 24.6 * u, -21.2 * u, 0.7 * u, INK);
  dot(c, 20.2 * u, -26.6 * u, 1.05 * u, INK);
  c.beginPath();
  ribbon(c, [[16.5 * u, -29.5 * u], [15 * u, -33.5 * u], [16.5 * u, -36 * u]], TEX * 1.3, 1, { tin: 1, tout: 2 });
  ribbon(c, [[21 * u, -31 * u], [22.5 * u, -34.5 * u], [21.5 * u, -37 * u]], TEX * 1.3, 2, { tin: 1, tout: 2 });
  c.fillStyle = INK; c.fill();
  poly(c, ellipse(13.6 * u, -27.5 * u, 3 * u, 1.5 * u, 10, 0, TAU, 0.4)); c.fillStyle = INK; c.fill();
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
  dot(c, 8 * u, -16.5 * u, 1.35 * u, INK); dot(c, 7.6 * u, -17 * u, 0.45 * u, '#FFFFFF');
  // a little water at the waterline
  c.beginPath(); ribbon(c, [[-13 * u, 0.5 * u], [-4 * u, -1.2 * u], [5 * u, 0.6 * u], [13 * u, -0.6 * u]], TEX, 7, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
}
function drawMonster(c, u, pink, P, o, t) {
  const sw = Math.sin(t * 1.6 + o.seed);
  for (let i = 0; i < 3; i++) {
    const hx = (-30 + i * 19) * u, hh = (8 + 2.5 * Math.sin(t * 2 + i * 1.3)) * u * (0.85 + 0.15 * sw);
    const hump = ellipse(hx, 1 * u, 8.5 * u, hh, 14, Math.PI, TAU);
    print(c, [...hump, [hx + 8.5 * u, 1 * u]], pink);
    c.beginPath(); ribbon(c, hump, DET, i, { tin: 2, tout: 2 }); c.fillStyle = INK; c.fill();
    c.beginPath(); ribbon(c, [[hx - 11 * u, 1.5 * u], [hx, 0], [hx + 11 * u, 1.5 * u]], TEX, i + 4, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
  }
  const neck = curve([[20 * u, 1 * u], [22 * u, -10 * u], [27 * u, -20 * u], [34 * u, -25 * u], [42 * u, -26 * u], [48 * u, -21 * u], [46 * u, -16 * u], [38 * u, -16 * u], [33 * u, -11 * u], [31 * u, 1 * u]], 2);
  print(c, neck, pink);
  c.beginPath(); ribbon(c, neck, DET, 7, { tin: 2, tout: 2 }); c.fillStyle = INK; c.fill();
  c.beginPath(); ribbon(c, [[16 * u, 1.5 * u], [26 * u, 0], [36 * u, 1.5 * u]], TEX, 8, { tin: 2, tout: 2 }); c.fillStyle = rgba(P.foam); c.fill();
  dot(c, 41 * u, -21.5 * u, 2.6 * u, '#FFFFFF');
  c.beginPath(); ribbon(c, ellipse(41 * u, -21.5 * u, 2.6 * u, 2.6 * u, 10), TEX, 9, { tin: 1, tout: 1, w0: 1, w1: 1 }); c.fillStyle = INK; c.fill();
  dot(c, 41.8 * u, -21.3 * u, 1.1 * u, INK);
  c.beginPath(); ribbon(c, [[45 * u, -18 * u], [47 * u, -17.6 * u]], TEX, 10, { tin: 1, tout: 1 }); c.fill();
  // its little top hat, with a red band
  const hat = [[36 * u, -25.5 * u], [37 * u, -35 * u], [45 * u, -35.5 * u], [45.5 * u, -26 * u]];
  poly(c, hat); c.fillStyle = INK; c.fill();
  c.fillStyle = rgba(mul(C.chimney, P.paper)); c.fillRect(36.6 * u, -29.5 * u, 8.6 * u, 2 * u);
  c.beginPath(); ribbon(c, [[33 * u, -25.8 * u], [49 * u, -26.4 * u]], DET * 1.2, 2, { tin: 1, tout: 1, w0: 1, w1: 1 }); c.fillStyle = INK; c.fill();
}

window.Hill = { Scene, themes: Object.keys(THEMES), states: STATES };
})();
