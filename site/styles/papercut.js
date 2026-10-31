/* Lighthouse Hill in paper cut, for Nord (see the styles in scene.js): a diorama of cut paper photographed straight
   on. No lines: every shape is a flat colour with a scissor-cut edge, casting a soft shadow down and to the right on
   whatever is behind it, all on a faint paper fibre. A stroke that stands on its own (a leg, a blade of grass, a bar,
   an arrow) is a thin strip of paper; one that goes round a shape is that shape's edge and goes. The layers shift a
   few pixels with the pointer, the near ones most. */
(() => {
const { TAU, clamp, lerp, smooth, hash, noise, rng, hex, mix, mul, rgba, ellipse, poly, cloudPts, dens, dot, label, beamPoly, waveScallops } = Hill;
const MOSS = hex('#A3BE8C'), AURORA = [MOSS, hex('#8FBCBB'), hex('#B48EAD')], VELLUM = hex('#FFF7DA');
const SHADOW = 'rgba(14,18,28,0.15)';

/* ---------- the paper ---------- */
// the polygon added to the path, moved by (dx, dy)
function trace(c, pts, dx, dy) {
  c.moveTo(pts[0][0] + dx, pts[0][1] + dy);
  for (let i = 1; i < pts.length; i++) c.lineTo(pts[i][0] + dx, pts[i][1] + dy);
  c.closePath();
}
// the edge the scissors left: each corner a hair off where it was meant to be
const snip = pts => { const n = pts.length, j = Hill.PW * 0.9; return pts.map(([x, y], i) => [x + (hash(i * 1.3 + n) - 0.5) * j, y + (hash(i * 2.1 + n) - 0.5) * j]); };
/* A shape cut out of paper and laid on, `deep` layers above what's behind it: its shadow is two copies, a little and
   a little more down and to the right, darker where they overlap */
function paper(c, pts, col, deep = 1) {
  const k = Hill.PW * deep, cut = snip(pts);
  c.beginPath(); trace(c, cut, k, k * 1.5); c.fillStyle = SHADOW; c.fill();
  c.beginPath(); trace(c, cut, k * 2.2, k * 3.3); c.fill();
  c.beginPath(); trace(c, cut, 0, 0); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill();
}
/* The same in the cached layers, where a blurred shadow costs nothing after the first time; it shows a little above a
   top edge too. The canvas's shadow is in device pixels, so it's scaled by the layer's. */
function soft(c, pts, col, deep = 1, holes = []) {
  const m = c.getTransform().a, k = Hill.PW * deep * m;
  c.save();
  c.shadowColor = 'rgba(14,18,28,0.4)'; c.shadowBlur = 3 * k + 2 * m; c.shadowOffsetX = 1.3 * k; c.shadowOffsetY = 2 * k;
  c.beginPath(); trace(c, snip(pts), 0, 0);
  for (const h of holes) trace(c, h, 0, 0);
  c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill('evenodd');
  c.restore();
}
/* a strip of paper along the points, w wide (times PW), added to the path for the caller to fill; its shadow is laid
   down at once */
function strip(c, pts, w) {
  const n = pts.length, hw = w * Hill.PW * 0.55, ring = new Array(n * 2);
  for (let i = 0; i < n; i++) {
    const a = pts[i > 0 ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : n - 1];
    let tx = b[0] - a[0], ty = b[1] - a[1];
    const tl = Math.hypot(tx, ty) || 1; tx /= tl; ty /= tl;
    ring[i] = [pts[i][0] - ty * hw, pts[i][1] + tx * hw]; ring[n * 2 - 1 - i] = [pts[i][0] + ty * hw, pts[i][1] - tx * hw];
  }
  const sh = new Path2D(), k = Hill.PW, fill = c.fillStyle;
  trace(sh, ring, k * 0.9, k * 1.4);
  c.fillStyle = SHADOW; c.fill(sh); c.fillStyle = fill;
  trace(c, ring, 0, 0);
}
/* The felt pen's lines, in paper: an outline is the cut itself, the others are strips */
let bare = false;
function ribbon(c, pts, w, sd, o = {}) {
  if (!bare && !o.outline) strip(c, pts, w);
}
// letters cut out of paper: a crisp shadow just under them
function lift(s, c) { const k = s.dpr; c.shadowColor = 'rgba(14,18,28,0.4)'; c.shadowBlur = 1.5 * k; c.shadowOffsetX = 0.8 * k; c.shadowOffsetY = 1.2 * k; }

/* The diorama's depth: each layer moves with the pointer as far as it's near, from the sky (still) to the hill. Every
   layer goes right and down only, so none leaves a gap at the screen's right or bottom edge. */
const lean = { x: 0, y: 0 }, STARS = 0.3, SEA = 0.45, CLOUDS = 0.6, LAND = 1;
const shift = (c, s, depth) => { const a = 3.2 * s.g.u * depth; c.translate(a * (1 - lean.x), a * 0.6 * (1 - lean.y)); };

/* The paper's fibre: a tile of short curled hairs, lighter and darker, laid over the whole diorama */
const FIBRE = (() => {
  const cv = document.createElement('canvas'), x = cv.getContext('2d'), n = 256, R = rng(19);
  cv.width = cv.height = n;
  x.lineWidth = 0.6;
  for (let i = 0; i < 900; i++) {
    const px = R() * n, py = R() * n, a = R() * TAU, l = 3 + R() * 9;
    x.strokeStyle = R() < 0.5 ? 'rgba(255,255,255,0.06)' : 'rgba(20,24,36,0.06)';
    x.beginPath(); x.moveTo(px, py); x.quadraticCurveTo(px + Math.cos(a + 0.6) * l * 0.5, py + Math.sin(a + 0.6) * l * 0.5, px + Math.cos(a) * l, py + Math.sin(a) * l); x.stroke();
  }
  return x.createPattern(cv, 'repeat');
})();

Hill.style('nord', {
  pal: Hill.stops([
    [0,    { sky: '#B8D6E0', sky2: '#E5E9F0', sea: '#5E81AC', sea2: '#88C0D0', foam: '#ECEFF4', hill: '#ECEFF4', hill2: '#C6D0DE', ink: '#3B4252', paper: '#F4F6F9', beam: '#EBCB8B', cloud: '#F4F6F9', far: '#A9C7D3', glass: '#8FBCBB' }],
    [0.2,  { sky: '#B3CAD8', sky2: '#E8E1E7', sea: '#5A7BA6', sea2: '#8BB4CA', foam: '#ECEFF4', hill: '#E9EAF0', hill2: '#C3C9D8', ink: '#3B4252', paper: '#F2F0F2', beam: '#EBCB8B', cloud: '#F2EFF2', far: '#B3BCD3', glass: '#A9C4D2' }],
    [0.44, { sky: '#B48EAD', sky2: '#D08770', sea: '#4C6A92', sea2: '#A08FB2', foam: '#E8D9E2', hill: '#E6D6D8', hill2: '#BFAFC0', ink: '#3B4252', paper: '#F0DEDA', beam: '#EBCB8B', cloud: '#EBD0CF', far: '#A58AA6', glass: '#EBCB8B' }],
    [0.7,  { sky: '#4C566A', sky2: '#6A6B88', sea: '#3B4A63', sea2: '#6C86AE', foam: '#B9C3D6', hill: '#A6AFC2', hill2: '#7F889E', ink: '#2E3440', paper: '#BAC2D1', beam: '#EBCB8B', cloud: '#677189', far: '#4C566A', glass: '#EBCB8B' }],
    [1,    { sky: '#2E3440', sky2: '#3B4252', sea: '#36405A', sea2: '#5E81AC', foam: '#81A1C1', hill: '#76819A', hill2: '#56607A', ink: '#242933', paper: '#9AA5BA', beam: '#EBCB8B', cloud: '#4C566A', far: '#3B4252', glass: '#EBCB8B' }],
  ]),
  C: {
    wool: hex('#FFFFFF'), yolk: hex('#EBCB8B'), duck: hex('#EBCB8B'), beak: hex('#D08770'), pink: hex('#E3A9A9'),
    monster: hex('#B48EAD'), chimney: hex('#BF616A'), roof: hex('#3B4252'), door: hex('#5E81AC'), skin: hex('#EAC6AA'),
    navy: hex('#434C5E'), wood: hex('#C9A57A'), steel: hex('#D8DEE9'), moon: hex('#EBCB8B'), tile: hex('#2E3440'),
    huts: ['#BF616A', '#5E81AC', '#EBCB8B', '#A3BE8C'].map(hex),
    kraft: hex('#C9A57A'), kraftLit: hex('#DDBF97'), kraftDark: hex('#A8865E'), tape: hex('#EBCB8B'), sprout: hex('#A3BE8C'),
  },
  ribbon, print: paper, boil: 0, reg: [0, 0],
  // the labels and doodles in Nord's bar font, medium
  hand: '"Avenir Next", "Avenir", "Helvetica Neue", sans-serif', weight: 500,
  before(s) {
    const p = s.cursor, on = p.on && !s.reduced;
    lean.x = lerp(lean.x, on ? clamp(p.x / s.W * 2 - 1, -1, 1) : 0, 0.1);
    lean.y = lerp(lean.y, on ? clamp(p.y / s.H * 2 - 1, -1, 1) : 0, 0.1);
  },

  after(s, c) { c.fillStyle = FIBRE; c.fillRect(0, 0, s.W, s.H); },
  draw: {
    /* the sky, and at night an aurora: three long strips of paper, green, teal and violet, waving slowly */
    sky(base, s, c) {
      base(s, c);
      const g = s.g, { W, u, top } = g, k = smooth(0.6, 0.95, s.d), t = s.reduced ? 0 : s.t, sky = g.horizon - top;
      if (k <= 0) return;
      c.save(); shift(c, s, STARS); c.globalAlpha = k;
      AURORA.forEach((col, i) => {
        const x0 = g.portrait ? -20 : W * 0.3, y0 = top + sky * (g.portrait ? 0.2 + i * 0.07 : 0.1 + i * 0.075), ring = new Array(98);
        for (let j = 0; j <= 48; j++) {
          const f = j / 48, x = lerp(x0, W + 20, f), y = y0 + Math.sin(f * 5 + i * 1.7 + t * 0.35) * 16 * u + Math.sin(f * 11 - t * 0.5 + i) * 5 * u - f * sky * 0.08;
          const hw = (5 + 4 * Math.sin(f * 7 + i * 2 + t * 0.6)) * u * Math.sin(Math.PI * f) ** 0.4 + 1;
          ring[j] = [x, y - hw]; ring[97 - j] = [x, y + hw];
        }
        paper(c, ring, mix(col, s.P.sky, 0.25));
      });
      c.restore();
    },
    /* the lower sky: two lighter sheets cut in soft waves, and the sea's edge laid over them at the horizon */
    band(base, s, c, bandTop) {
      const g = s.g, { W, u } = g, P = s.P, by = bandTop + 20 * u, band = [], low = [];
      for (let x = -30; x <= W + 30; x += 12 * u) {
        band.push([x, by + Math.sin(x * 0.006 + 1) * 11 * u + Math.sin(x * 0.019 + 2) * 3 * u]);
        low.push([x, lerp(by, g.horizon, 0.55) + Math.sin(x * 0.011 + 4) * 6 * u + Math.sin(x * 0.027) * 2 * u]);
      }
      band.push([W + 30, g.horizon + 4], [-30, g.horizon + 4]);
      low.push([W + 30, g.horizon + 4], [-30, g.horizon + 4]);
      soft(c, band, P.sky2, 2);
      soft(c, low, mix(P.sky2, P.far, 0.35), 1.5);
      c.fillStyle = rgba(P.sea); c.fillRect(-1, g.horizon, W + 2, 8 * u);
      c.fillStyle = rgba(mix(P.sea, P.foam, 0.45)); c.fillRect(-1, g.horizon, W + 2, Hill.PW);
    },
    /* small paper stars, five points each, that swell and shrink a little */
    stars(base, s, c) {
      const g = s.g, u = g.u, st = smooth(0.55, 0.9, s.d);
      if (st <= 0) return;
      const sh = new Path2D(), star = new Path2D(), k = Hill.PW;
      for (const p of g.stars) {
        const r = p.s * (p.s < 0.75 ? 1.6 : 3.2) * u * (s.reduced ? 1 : 0.8 + 0.2 * Math.sin(s.t * 2 + p.p)), pts = [];
        for (let i = 0; i < 10; i++) { const a = i / 10 * TAU + p.p, rr = i % 2 ? r * 0.45 : r; pts.push([p.x + Math.sin(a) * rr, p.y - Math.cos(a) * rr]); }
        trace(sh, pts, k * 0.8, k * 1.2); trace(star, pts, 0, 0);
      }
      c.save(); shift(c, s, STARS); c.globalAlpha = st;
      c.fillStyle = SHADOW; c.fill(sh);
      c.fillStyle = rgba(mix(s.P.beam, VELLUM, 0.4)); c.fill(star);
      c.restore();
    },
    /* the waves: thin strips of paper laid on the sea */
    waves(base, s, c) {
      const k = Hill.PW;
      c.save(); c.lineCap = 'butt'; shift(c, s, SEA);
      c.translate(k * 0.8, k * 1.3); c.strokeStyle = SHADOW; waveScallops(s, c, false);
      c.translate(-k * 0.8, -k * 1.3); c.strokeStyle = rgba(s.P.sea2); waveScallops(s, c, false);
      c.restore();
    },
    /* rings of paper where things land */
    ripples(base, s, c) {
      const u = s.g.u, k = Hill.PW;
      c.lineWidth = 2 * k;
      for (const r of s.ripples) {
        if (!Hill.afloat(s, c, r.y)) continue;
        const age = s.t - r.t0, rx = 8 * u + age * 70 * u;
        c.globalAlpha = clamp(1 - age / 2.2) * r.a;
        c.beginPath(); c.ellipse(r.x + k, r.y + k * 1.5, rx, rx * 0.3, 0, 0, TAU); c.strokeStyle = SHADOW; c.stroke();
        c.beginPath(); c.ellipse(r.x, r.y, rx, rx * 0.3, 0, 0, TAU); c.strokeStyle = rgba(s.P.foam); c.stroke();
      }
      c.globalAlpha = 1;
    },
    /* the fried egg, cut out: the white, the yolk on it, a sliver of shine */
    sun(base, s, c) {
      const g = s.g, u = g.u, sun = s.sunPos();
      if (sun.a <= 0) return;
      const r = 38 * u, sz = r * 3;
      c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip(); shift(c, s, STARS);
      c.globalAlpha = sun.a;
      s.sprite('sun', sz, sz, sun.x, sun.y, x => {
        const white = [];
        for (let i = 0; i < 48; i++) { const a = i / 48 * TAU; white.push([Math.cos(a) * r * (1 + 0.12 * Math.sin(a * 3 + 1) + 0.06 * Math.sin(a * 5 + 2)), Math.sin(a) * r * 0.86 * (1 + 0.09 * Math.sin(a * 4))]); }
        soft(x, white, mul(hex('#FFFFFF'), s.P.paper), 2);
        soft(x, ellipse(3 * u, -3 * u, r * 0.42, r * 0.4, 30), mul(Hill.C.yolk, s.P.paper), 1.2);
        x.beginPath(); strip(x, ellipse(3 * u, -3 * u, r * 0.27, r * 0.25, 10, Math.PI * 1.15, Math.PI * 1.5), 2.2); x.fillStyle = '#FFFFFF'; x.fill();
      });
      c.restore();
    },
    /* the crescent moon, asleep: its shut eye and its smile are strips of paper; a z drifts off */
    moon(base, s, c) {
      const g = s.g, u = g.u, m = s.moonPos();
      if (m.a <= 0) return;
      const r = 25 * u, sz = r * 3.4;
      c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip(); shift(c, s, STARS);
      c.globalAlpha = m.a;
      s.sprite('moon', sz, sz, m.x, m.y, x => {
        const cres = [];
        for (let i = 0; i <= 26; i++) { const a = -Math.PI / 2 + i / 26 * Math.PI; cres.push([Math.cos(a) * r, Math.sin(a) * r]); }
        for (let i = 25; i >= 1; i--) { const a = -Math.PI / 2 + i / 26 * Math.PI; cres.push([Math.cos(a) * r * 0.38 + r * 0.02, Math.sin(a) * r * 0.97]); }
        soft(x, cres, Hill.C.moon, 2);
        x.beginPath();
        strip(x, ellipse(r * 0.62, -r * 0.2, r * 0.17, r * 0.11, 9, 0.15 * Math.PI, 0.85 * Math.PI), 1.6);
        strip(x, ellipse(r * 0.52, r * 0.3, r * 0.15, r * 0.1, 9, 0.2 * Math.PI, 0.8 * Math.PI), 1.5);
        x.fillStyle = Hill.INK; x.fill();
      });
      const zz = s.reduced ? 0.4 : (s.t * 0.4) % 1;
      label(c, 'z', m.x + r * 1.1 + zz * 10 * u, m.y - r * 0.7 - zz * 16 * u, (11 + zz * 5) * u + 3, rgba(mix(s.P.paper, s.P.beam, 0.3), m.a * (1 - zz) * 0.95), 'left', -0.2);
      c.restore();
    },
    /* a cloud: two sheets, the one behind a shade cooler; the one with legs walks on strips of paper */
    cloud(base, s, c, cl, name, legs) {
      const g = s.g, u = g.u, P = s.P, p = s.cloudXY(cl), w = cl.w;
      if (p.x < -w || p.x > g.W + w) return;
      c.save(); shift(c, s, CLOUDS);
      if (legs) {
        const walk = s.reduced ? 0 : s.t * 5;
        c.beginPath();
        [-0.24, -0.11, 0.1, 0.23].forEach((lx, i) => {
          const x = p.x + lx * w * (cl.dir < 0 ? -1 : 1), sw = Math.sin(walk + i * 1.7 + (i % 2) * Math.PI) * 2.6 * u;
          strip(c, [[x, p.y - 4 * u], [x + sw * 0.5, p.y + 5 * u], [x + sw, p.y + 12 * u]], Hill.DET * 1.25);
        });
        c.fillStyle = Hill.INK; c.fill();
      }
      s.sprite(name + (legs && cl.dir < 0 ? 'L' : ''), w * 1.3, w * 0.75, p.x, p.y - w * 0.12, x => {
        soft(x, dens(cloudPts(-w * 0.06, w * 0.06, w * 0.8, cl.seed + 1), 5, true), mix(P.cloud, P.sky, 0.3), 1.5);
        soft(x, dens(cloudPts(0, w * 0.12, w, cl.seed), 5, true), P.cloud, 2);
        if (legs) {
          // a tail: it might be a sheep
          const f = cl.dir < 0 ? -1 : 1;
          soft(x, ellipse(-f * w * 0.5, w * 0.05, w * 0.045, w * 0.035, 12), P.cloud);
        }
      });
      c.restore();
    },
    /* the light: a wedge of pale yellow vellum, the sea's strips showing through it a little lighter; in the dark the
       vellum is paler and the night shows through it */
    beam(base, s, c) {
      const P = s.P, pw = s.lampPower(), { L, len, a0, a1 } = beamPoly(s);
      if (len < 10 || pw < 0.02) return;
      const night = smooth(0.3, 0.8, s.d), fan = [[L.x, L.y]], k = Hill.PW, a = c.globalAlpha, col = mix(P.beam, VELLUM, 0.4 + 0.35 * night);
      for (let i = 0; i <= 12; i++) { const an = lerp(a0, a1, i / 12); fan.push([L.x + Math.cos(an) * len, L.y + Math.sin(an) * len]); }
      c.save(); shift(c, s, LAND);
      c.globalAlpha = a * pw * 0.3; poly(c, fan, true, k * 2, k * 3); c.fillStyle = SHADOW; c.fill();
      c.globalAlpha = a * pw * (0.6 - 0.38 * night); poly(c, fan); c.fillStyle = rgba(col); c.fill();

      c.globalAlpha = a;
      poly(c, fan); c.clip(); c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0); shift(c, s, SEA);
      c.lineCap = 'butt'; c.strokeStyle = rgba(mix(col, hex('#FFFFFF'), 0.4), 0.9 * pw); waveScallops(s, c, true);
      c.restore();
    },
    /* the lamp lit at night: two discs of vellum round the eye */
    halo(base, s, c) {
      const g = s.g, L = g.lamp, er = g.lh.er, night = smooth(0.35, 0.85, s.d), f = s.beam.flash;
      const k = Math.max(night * s.beamI(), f * 0.9) * s.lampOn() * s.lampPower(), a = c.globalAlpha;
      if (k < 0.02) return;
      c.save(); shift(c, s, LAND); c.fillStyle = rgba(mix(s.P.beam, VELLUM, 0.5));
      for (const [r, o] of [[3.4 + f * 1.4, 0.28], [2.3 + f * 0.6, 0.4]]) {
        c.globalAlpha = a * clamp(k) * o;
        poly(c, snip(ellipse(L.x, L.y, er * r, er * r, 40))); c.fill();
      }
      c.restore();
    },
    /* where the light lands on the hill, the vellum over the snow */
    hillLight(base, s, c) {
      const { L, len, a0, a1 } = beamPoly(s);
      if (len < 10 || Math.sin(s.beam.a) < 0.08) return;
      c.save(); poly(c, s.g.hillClip); c.clip();
      c.beginPath(); c.moveTo(L.x, L.y);
      for (let i = 0; i <= 12; i++) { const a = lerp(a0, a1, i / 12); c.lineTo(L.x + Math.cos(a) * len, L.y + Math.sin(a) * len); }
      c.closePath(); c.fillStyle = rgba(mix(s.P.beam, VELLUM, 0.4), (0.4 + 0.15 * smooth(0.3, 0.8, s.d)) * s.lampPower()); c.fill();
      c.restore();
    },
    land(base, s, c, w) { c.save(); shift(c, s, LAND); base(s, c, w); c.restore(); },
    /* the hill: green paper under a sheet of snow, the snow torn open here and there; a shady sheet over its flank, a
       band of rock under a headland's edge, and strips of foam where it meets the sea */
    hill(base, s, c) {
      const g = s.g, { W, H, u } = g, P = s.P, T = g.lh, rd = g.ridge;
      if (g.isle) {
        const sl = g.shore, x0 = sl[0][0], x1 = sl.at(-1)[0], deep = x => Math.sin(Math.PI * (x - x0) / (x1 - x0)) * 18 * u, R = rng(3);
        poly(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x, y + deep(x)])]); c.fillStyle = rgba(mix(P.sea, P.hill2, 0.35)); c.fill();
        c.beginPath();
        for (let j = 0; j < 4; j++) for (let x = x0 + R() * 30 * u; x < x1 - 20 * u; x += (24 + R() * 30) * u) {
          const y = s.shoreY(x) + deep(x) * (0.25 + j * 0.27) + 2 * u;
          strip(c, [[x, y], [x + (6 + R() * 12) * u * (1 - j * 0.15), y]], 1.2);
        }
        c.fillStyle = rgba(P.sea2); c.fill();
      }
      soft(c, g.hillPoly, mul(MOSS, P.paper), 3);
      // the holes in the snow, where the grass shows: under the ridge, clear of the tower and the shore
      const R = rng(7), holes = [];
      for (let i = 0; i < (g.isle ? 4 : g.portrait ? 5 : 7); i++) {
        const x = lerp(rd[0][0] + 30 * u, Math.min(W, rd.at(-1)[0]) - 20 * u, R()), y = s.ridgeY(x) + (g.isle ? 14 + R() * 18 : 26 + R() * (g.portrait ? 40 : 150)) * u;
        const rx = (g.isle ? 10 : 18 + R() * 26) * u, hole = [];
        if (Math.abs(x - T.x) < T.wB * 1.4 || y + rx * 0.4 > s.shoreY(x) - 6 * u) continue;
        for (let k = 0; k < 28; k++) { const a = k / 28 * TAU, rr = 1 + 0.32 * noise(k * 0.45 + i * 7) + 0.06 * noise(k * 1.7 + i); hole.push([x + Math.cos(a) * rx * rr, y + Math.sin(a) * rx * 0.45 * rr]); }
        holes.push(hole);
      }
      c.save(); poly(c, g.hillPoly); c.clip();
      soft(c, g.hillPoly, P.hill, 2, holes);
      c.restore();
      if (g.shore) {
        const sl = g.shore, x0 = sl[0][0];
        soft(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x + 4 * u, y - (8 + (x - x0) / W * 26) * u])], mix(P.hill2, P.ink, 0.3), 1.5);
      } else {
        const sh = rd.filter(([x]) => x < T.x - T.wB * 2), n = sh.length;
        const inner = sh.map(([x, y], i) => { const f = smooth(0, 0.35, (n - 1 - i) / n); return [x + (34 + (H - y) * 0.12) * u * f, y + (16 + (H - y) * 0.05) * u * f]; }).reverse();
        soft(c, [...sh, ...inner], P.hill2, 1.5);
      }
      c.beginPath();
      const foam = g.shore || rd.filter(p => p[1] > g.horizon + 3 && p[0] < T.x), ox = g.shore ? 0 : -4 * u, oy = g.shore ? 4 * u : 0;
      for (let i = 0; i < foam.length - 4; i += 6) {
        const [x, y] = foam[i + 2];
        if (x < -10 || x > W + 10 || y > H + 10 || hash(i * 0.7) < 0.3) continue;
        strip(c, foam.slice(i, i + 4).map(([x, y]) => [x + ox, y + oy]), 1.8);
      }
      c.fillStyle = rgba(P.foam); c.fill();
    },
    /* a red cottage with white corners, snow along its roof, a stone chimney */
    cottage(base, s, c) {
      const g = s.g, u = g.u, P = s.P, C = Hill.C, k = g.cot, w = k.w, h = k.h, x0 = k.x - w / 2, y0 = k.base - h;
      const white = mul(hex('#FFFFFF'), P.paper), night = smooth(0.45, 0.75, s.d);
      const chx = x0 + w * 0.68, chw = w * 0.15, cht = y0 - h * 1.45;
      soft(c, [[chx, y0 - h * 0.2], [chx + 1.2 * u, cht], [chx + chw + 1.6 * u, cht], [chx + chw, y0 - h * 0.25]], mul(mix(C.steel, C.roof, 0.45), P.paper));
      soft(c, [[x0, k.base], [x0, y0], [x0 + w, y0], [x0 + w, k.base]], mul(C.chimney, P.paper), 1.5);
      const ax = x0 + w * 0.5, ay = y0 - h * 0.78, roofY = x => ay + Math.abs(x - ax) / (w * 0.62) * (y0 + 1 * u - ay);
      soft(c, [[x0 - w * 0.12, y0 + 1 * u], [ax, ay], [x0 + w * 1.12, y0 + 1 * u]], mul(C.roof, P.paper), 1.5);
      const snow = [[x0 - w * 0.13, y0 + 0.5 * u], [ax, ay - 1.2 * u], [x0 + w * 1.13, y0 + 0.5 * u]];
      for (let i = 12; i >= 0; i--) { const x = lerp(x0 - w * 0.08, x0 + w * 1.08, i / 12); snow.push([x, roofY(x) + h * (0.13 + 0.05 * Math.sin(i * 1.9))]); }
      soft(c, snow, white);
      // the window: a white frame, the glass (lit at night), white bars
      const wx = x0 + w * 0.14, wy = y0 + h * 0.24, ww = w * 0.27, wh = h * 0.36, f = 1.5 * u;
      soft(c, [[wx - f, wy - f], [wx + ww + f, wy - f], [wx + ww + f, wy + wh + f], [wx - f, wy + wh + f]], white);
      soft(c, [[wx, wy], [wx + ww, wy], [wx + ww, wy + wh], [wx, wy + wh]], night > 0.5 ? P.beam : P.glass, 0.5);
      c.beginPath();
      strip(c, [[wx + ww / 2, wy], [wx + ww / 2, wy + wh]], 1.3);
      strip(c, [[wx, wy + wh / 2], [wx + ww, wy + wh / 2]], 1.3);
      strip(c, [[x0 + 1 * u, k.base], [x0 + 1 * u, y0]], 2.4);
      strip(c, [[x0 + w - 1 * u, k.base], [x0 + w - 1 * u, y0]], 2.4);
      c.fillStyle = rgba(white); c.fill();
      // the door (it opens for the keeper: see the states)
      const dx = x0 + w * 0.56, dw = w * 0.24, dh = h * 0.66;
      k.door = { x: dx, y: k.base - dh, w: dw, h: dh };
      soft(c, [[dx, k.base], [dx, k.base - dh], [dx + dw, k.base - dh], [dx + dw, k.base]], mul(C.door, P.paper));
      dot(c, dx + dw * 0.78, k.base - dh * 0.48, 1.3 * u + 0.4, Hill.INK);
    },
    /* the tower: white paper, its stripes bands of the theme's paper laid on, curving up a little as seen from below */
    tower(base, s, c) {
      const g = s.g, u = g.u, P = s.P, T = g.lh, th = Hill.THEMES[g.theme || s.theme], C = Hill.C;
      const half = k => lerp(T.wB, T.wT, k) / 2, yAt = k => T.base - T.h * k, Lp = [], Rp = [];
      for (let i = 0; i <= 20; i++) { const k = i / 20; Lp.push([T.x - half(k), yAt(k)]); Rp.push([T.x + half(k), yAt(k)]); }
      soft(c, [...Lp, ...Rp.reverse()], mul(hex('#FFFFFF'), P.paper), 2);
      const bands = 6, sag = T.wB * 0.09;
      const edge = k => { const hw = half(k), out = []; for (let i = 0; i <= 12; i++) { const f = i / 12 * 2 - 1; out.push([T.x + f * hw, yAt(k) - sag * (1 - f * f)]); } return out; };
      let n = 0;
      for (let j = 1; j < bands; j += 2) {
        const hi = j + 1 >= bands ? [[T.x + half(1), yAt(1)], [T.x - half(1), yAt(1)]] : edge((j + 1) / bands).reverse();
        soft(c, [...edge(j / bands), ...hi], mul(hex(th.stripes[n++ % th.stripes.length]), P.paper));
      }
      const night = smooth(0.45, 0.75, s.d), ww = T.wB * 0.22, wh = T.er * 0.75;
      for (const k of [0.25, 0.58]) { const y = yAt(k); soft(c, [[T.x - ww / 2, y - wh / 2], [T.x + ww / 2, y - wh / 2], [T.x + ww / 2, y + wh / 2], [T.x - ww / 2, y + wh / 2]], night > 0.5 ? P.beam : mul(C.roof, P.paper), 0.5); }
      const dw = T.wB * 0.32, dh = T.wB * 0.5;
      soft(c, [[T.x - dw / 2, T.base], ...ellipse(T.x, T.base - dh + dw / 2, dw / 2, dw / 2, 10, Math.PI, TAU), [T.x + dw / 2, T.base]], mul(C.roof, P.paper), 0.5);
      // the gallery: a dark deck the eye sits on
      const gw = T.wT * 0.95, gy = T.top;
      soft(c, [[T.x - gw, gy + 1 * u], [T.x - gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.05, gy - T.gal * 0.42], [T.x + gw, gy + 1 * u]], Hill.INK);
    },
    /* grass along the ridge: slivers of green paper, leaning with the wind and away from the pointer */
    tufts(base, s, c) {
      const g = s.g, u = g.u, k = Hill.PW, blades = new Path2D();
      for (const b of g.tufts) {
        let a = s.reduced ? 0.12 : Math.sin(s.t * 1.6 + b.p) * 0.14 * (0.6 + s.windAmb) + s.windTotal * 0.36;
        if (s.ptr.on && !s.reduced) {
          const dx = b.x - s.ptr.x, dy = b.y - s.ptr.y, r = 95 * u, d2 = dx * dx + dy * dy;
          if (d2 < r * r) a += Math.sign(dx || 1) * 1.05 * (1 - Math.sqrt(d2) / r);
        }
        a = clamp(a, -1.3, 1.3);
        for (let j = 0; j < b.n + 1; j++) {
          const da = (j - b.n / 2) * 0.42, l = b.l * (j === 1 ? 1.15 : 0.85), x = b.x + (j - b.n / 2) * 1.6 * u, y = b.y + 1.5 * u;
          const tx = x + Math.sin(a + da) * l, ty = y - Math.cos(a + da) * l, w = 1.5 * g.pw;
          blades.moveTo(x - w, y); blades.quadraticCurveTo(lerp(x, tx, 0.5) - w * 0.4, lerp(y, ty, 0.55), tx, ty); blades.quadraticCurveTo(lerp(x, tx, 0.5) + w * 0.4, lerp(y, ty, 0.55), x + w, y); blades.closePath();
        }
      }
      c.save(); c.translate(k * 0.8, k * 1.2); c.fillStyle = SHADOW; c.fill(blades); c.restore();
      c.fillStyle = rgba(mul(MOSS, s.P.paper)); c.fill(blades);
    },
    /* smoke from the chimney: little puffs of paper that rise, swell and fade */
    smoke(base, s, c) {
      if (s.reduced) return;
      const g = s.g, u = g.u, k = g.cot, x0 = k.x - k.w / 2 + k.w * 0.68 + k.w * 0.075, y0 = k.base - k.h - k.h * 1.5;
      for (let i = 0; i < 3; i++) {
        const a = (s.t * 0.22 + i / 3) % 1, r = (2.5 + a * 6) * u;
        c.globalAlpha = smooth(0, 0.08, a) * (1 - smooth(0.55, 1, a));
        paper(c, ellipse(x0 + s.windTotal * 50 * u * a + Math.sin(a * 6 + i) * 3 * u, y0 - 6 * u - a * 46 * u, r, r * 0.82, 14), mix(s.P.cloud, s.P.sky, 0.15));
      }
      c.globalAlpha = 1;
    },
    // the blades are paper already: the pen's strokes over them go
    meadow(base, s, c, m) { bare = true; base(s, c, m); bare = false; },
    labels(base, s, c) { c.save(); lift(s, c); base(s, c); c.restore(); },
    doodles(base, s, c) { c.save(); lift(s, c); base(s, c); c.restore(); },
  },
});
})();
