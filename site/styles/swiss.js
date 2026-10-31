/* Lighthouse Hill in a Swiss travel poster, for Léman (see the styles in scene.js).
   A lithograph of the 1930s: no outlines, flat planes lit from the upper left, each form with its lit side and its
   shady side, under an airbrushed sky. Lake Geneva in flat bands with a few reflections, the Alps across the water,
   and the lettering in bold condensed capitals. */
(() => {
'use strict';
const { TAU, clamp, lerp, smooth, hash, rng, hex, mix, mul, rgba, stops, poly, ellipse, dens, dot, cloudPts, view, afloat, beamPoly, THEMES, TEX, DET, DIVE_GAP, SHORE, FAR } = Hill;
const print = Hill.felt.print;

// the letters: Helvetica's bold condensed where the system has it
document.fonts.add(new FontFace('Leman Poster', 'local("HelveticaNeue-CondensedBold"), local("AvenirNextCondensed-Bold"), local("ArialNarrow-Bold")'));

/* The hours: teal by day, a warm horizon at dusk, a deep teal-blue night with the snow pale under the moon */
const pal = stops([
  [0,    { sky: '#3F9DB0', sky2: '#DCEBE8', sea: '#0E7C7B', sea2: '#8ED8CC', foam: '#EEF6F2', hill: '#9DC36A', hill2: '#4E8A6A', ink: '#12343B', paper: '#FBF4E4', beam: '#FFE08A', cloud: '#FBF7EE', far: '#8DB9BD', glass: '#BFE3DF' }],
  [0.2,  { sky: '#4F98AE', sky2: '#F1E2C6', sea: '#147679', sea2: '#9ADACB', foam: '#F4EEE2', hill: '#96BB64', hill2: '#4A8467', ink: '#12343B', paper: '#FBEFD9', beam: '#FFDD80', cloud: '#FAF0E0', far: '#93B3BA', glass: '#F1E2C6' }],
  [0.44, { sky: '#2F7189', sky2: '#F4B27E', sea: '#1A5E69', sea2: '#F0B184', foam: '#F7DCC2', hill: '#729B5C', hill2: '#3D6B5D', ink: '#12343B', paper: '#F8E1C6', beam: '#FFD66B', cloud: '#F4CDAE', far: '#8C8E9E', glass: '#FFC98A' }],
  [0.7,  { sky: '#174759', sky2: '#4F7F86', sea: '#123C47', sea2: '#5E9C98', foam: '#B6D2CC', hill: '#3E6757', hill2: '#274A44', ink: '#0B262C', paper: '#D9E5E1', beam: '#FFE07A', cloud: '#6E9399', far: '#3A6670', glass: '#FFE07A' }],
  [1,    { sky: '#0A2430', sky2: '#1C4B57', sea: '#0A2129', sea2: '#4E9A95', foam: '#9FC9C2', hill: '#264B43', hill2: '#173630', ink: '#071B20', paper: '#CFE2DD', beam: '#FFE58A', cloud: '#2F5862', far: '#2B5561', glass: '#FFE58A' }],
]);

// the shady side of a colour: toward the deep teal of the ink, as the printer overprints it
const dim = (P, col, k = 0.3) => mix(col, P.ink, k);

/* No outlines, and the lines that are features are thin flat shapes, one width all along */
function flat(c, pts, w, sd, o = {}) {
  if (o.outline) return;
  const n = pts.length, hw = w * Hill.PW * 0.5, l = [], r = [];
  for (let i = 0; i < n; i++) {
    const a = pts[i ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : i], tl = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
    const nx = -(b[1] - a[1]) / tl * hw, ny = (b[0] - a[0]) / tl * hw;
    l.push([pts[i][0] + nx, pts[i][1] + ny]); r.push([pts[i][0] - nx, pts[i][1] - ny]);
  }
  c.moveTo(l[0][0], l[0][1]);
  for (const p of l) c.lineTo(p[0], p[1]);
  for (let i = n - 1; i >= 0; i--) c.lineTo(r[i][0], r[i][1]);
  c.closePath();
}

/* The fill, flat; a rounded form (more than a few corners: a quad is a plane already) also gets its shady side, the
   ink overprinted where the same form a little up and to the left (on the screen) wouldn't cover it */
function plane(c, pts, col) {
  poly(c, pts); c.fillStyle = typeof col === 'string' ? col : rgba(col); c.fill();
  if (pts.length < 9) return;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
  const d = Math.min(x1 - x0, y1 - y0) * 0.16, dx = d * 0.5 * Math.sign(c.getTransform().a);
  c.save(); c.clip();
  c.beginPath(); c.rect(x0, y0, x1 - x0, y1 - y0); c.moveTo(pts[0][0] - dx, pts[0][1] - d);
  for (const [x, y] of pts) c.lineTo(x - dx, y - d);
  c.globalAlpha *= 0.2; c.fillStyle = Hill.INK; c.fill('evenodd');
  c.restore();
}

/* The Alps across the lake: peaks of the range, the tallest by the lake's end, and none where the sun goes down into
   the water */
function alps(g) {
  const { W, u, horizon: hz, top } = g, R = rng(5), sky = hz - top, r = 38 * u, a = g.sun.x - r * 1.25, b = g.sun.x + r * 1.25, peaks = [];
  for (let x = -60 * u; x < W + 60 * u; x += (45 + R() * 80) * u) {
    const h = sky * (0.075 + R() * 0.09) * (1 + 0.6 * Math.exp(-(((x - a) / (160 * u)) ** 2)));
    let wl = h * (1.3 + R() * 0.8), wr = h * (1.4 + R() * 0.9);
    if (x > a - 8 * u && x < b + 8 * u) continue;
    if (x < a) wr = Math.min(wr, a - x); else wl = Math.min(wl, x - b);
    peaks.push({ x, h, wl, wr, sd: R() });
  }
  return { peaks: peaks.sort((p, q) => q.h - p.h), a, b };
}
// the sky above them, for what rises and sets behind them
function behindAlps(s, c) {
  const g = s.g, hz = g.horizon, { peaks } = alps(g), line = [[g.W, 0], [0, 0]];
  for (let x = 0; x < g.W + 3; x += 3) {
    let y = hz;
    for (const p of peaks) y = Math.min(y, hz - p.h + (x < p.x ? (p.x - x) / p.wl : (x - p.x) / p.wr) * p.h);
    line.push([x, y]);
  }
  poly(c, line); c.clip();
}

/* The lake's reflections: short flat strokes in rows to the horizon, the rows closer together and sparser the farther
   off, coming toward you as you dive (the rows are the felt pen's scallops': see waveScallops) */
const ROW = 0.02;
function glints(s, c, col) {
  const g = s.g, { W, H, u } = g, hz = g.horizon, sea = H - hz, go = s.dive * DIVE_GAP / SHORE;
  c.fillStyle = col;
  for (let k = Math.ceil((1 + go) / ROW); ;) {
    const rel = 1 / (k * ROW - go);
    if (rel < 0.012) break;
    const gap = 3.2 * sea * rel ** 0.375 / g.rows, dy = sea * ROW * rel * rel, step = 2 ** Math.max(0, Math.ceil(Math.log2(gap / dy)));
    if (k % step) { k += step - k % step; continue; }
    const y = hz + sea * rel, t = (0.9 + 2.6 * rel) * u, l = (12 + 90 * rel) * u;
    c.globalAlpha = k % (step * 2) ? clamp(dy * step / gap - 1) : 1;
    for (let j = 0; j < 4; j++) {
      const f = hash(k * 7.31 + j * 1.93);
      if (f < 0.35) continue;
      c.fillRect(hash(k * 3.17 + j * 5.3) * (W + l) - l, y, l * (0.4 + f), t);
    }
    k += step;
  }
  c.globalAlpha = 1;
}

Hill.style('leman', {
  pal,
  C: {
    wool: hex('#FBF4E4'), yolk: hex('#F2B33D'), duck: hex('#F2C230'), beak: hex('#E07A2F'), pink: hex('#EFA3A8'),
    monster: hex('#E98FB0'), chimney: hex('#B9573A'), roof: hex('#C8643B'), door: hex('#0E7C7B'), navy: hex('#12343B'),
    tile: hex('#12343B'), moon: hex('#F6E9BE'), sprout: hex('#5E9A45'),
    huts: ['#C8643B', '#0E7C7B', '#E8B04B', '#5CC5B8'].map(hex),
  },
  ribbon: flat, print: plane, pen: 0.9, boil: 0, reg: [0, 0],
  // poster lettering is in capitals
  hand: '"Leman Poster", "Helvetica Neue", "Avenir Next Condensed", "Arial Narrow", sans-serif', caps: true,
  draw: {
    // an airbrushed sky down to the horizon, and the lake in flat bands, lightest far off where it takes the sky
    sky(base, s, c) {
      const g = s.g, P = s.P, hz = g.horizon, sea = g.H - hz, air = c.createLinearGradient(0, g.top, 0, hz);
      air.addColorStop(0, rgba(P.sky)); air.addColorStop(0.55, rgba(mix(P.sky, P.sky2, 0.35))); air.addColorStop(1, rgba(P.sky2));
      c.fillStyle = air; c.fillRect(0, 0, g.W, hz + 2);
      for (const [f, k] of [[1, 0], [0.3, 0.08], [0.13, 0.18], [0.055, 0.3], [0.02, 0.46]]) { c.fillStyle = rgba(mix(P.sea, P.sky2, k)); c.fillRect(0, hz, g.W, sea * f); }
      // the snow of the Alps upside down in the far water, in broken strokes
      c.fillStyle = rgba(mix(P.paper, P.sea, 0.5), 0.8);
      for (const p of alps(g).peaks) for (let i = 0; i < 4; i++) {
        const d = p.h * 0.45 * (0.55 + i * 0.12), w = (p.wl + p.wr) * (1 - d / (p.h * 0.45)), x = p.x - w / 2 + (p.wr - p.wl) * 0.2, cut = hash(p.sd * 9 + i) * w;
        c.fillRect(x, hz + d, cut - 1.5 * g.u, p.h * 0.035); c.fillRect(x + cut + 1.5 * g.u, hz + d, w - cut - 1.5 * g.u, p.h * 0.035);
      }
    },
    // the Alps across the water, each peak a lit face and a shady one, snow down to a ragged line; under them, the far
    // shore, low and dark, open where the lake goes on to the horizon
    band(base, s, c) {
      const g = s.g, { W, u } = g, P = s.P, hz = g.horizon, { peaks, a, b } = alps(g);
      const snow = [P.paper, mix(P.paper, P.sky, 0.42)], rock = [mix(P.far, P.sky2, 0.3), dim(P, P.far, 0.38)];
      for (const p of peaks) {
        const top = [p.x, hz - p.h], spine = [p.x + p.h * 0.22, hz + 1], faces = [[top, [p.x - p.wl, hz + 1], spine], [top, spine, [p.x + p.wr, hz + 1]]];
        const R = rng(p.sd * 1e6), cap = [[p.x - p.wl, hz - p.h * 2]];
        for (let i = 0; i <= 12; i++) cap.push([lerp(p.x - p.wl, p.x + p.wr, i / 12), hz - p.h * (i % 2 ? 0.62 + R() * 0.1 : 0.36 + R() * 0.16)]);
        cap.push([p.x + p.wr, hz - p.h * 2]);
        faces.forEach((f, i) => { print(c, f, rock[i]); c.save(); poly(c, f); c.clip(); print(c, cap, snow[i]); c.restore(); });
      }
      const shore = (x0, x1) => {
        const pts = [[x0, hz + 1]];
        for (let x = x0; x <= x1; x += 8 * u) pts.push([x, hz - (2.5 + 1.8 * Math.sin(x * 0.013) + 1.2 * Math.sin(x * 0.041)) * u * smooth(0, 30 * u, Math.min(x - x0, x1 - x))]);
        pts.push([x1, hz + 1]);
        print(c, pts, dim(P, P.far, 0.6));
      };
      shore(-10, a - 6 * u); shore(b + 6 * u, W + 10);
    },
    stars(base, s, c) { c.save(); behindAlps(s, c); base(s, c); c.restore(); },
    sun(base, s, c) { c.save(); behindAlps(s, c); base(s, c); c.restore(); },
    moon(base, s, c) { c.save(); behindAlps(s, c); base(s, c); c.restore(); },
    // the lamp's halo at night: flat rings of light round the lantern, fainter outward
    halo(base, s, c) {
      const P = s.P, L = s.g.lamp, er = s.g.lh.er, f = s.beam.flash, k = Math.max(smooth(0.35, 0.85, s.d) * s.beamI(), f * 0.9) * s.lampOn() * s.lampPower();
      if (k < 0.02) return;
      for (const [r, a] of [[3.6 + f * 1.4, 0.14], [2.7 + f, 0.2], [1.75, 0.75]]) dot(c, L.x, L.y, er * r, rgba(mix(P.beam, hex('#FFFFFF'), 0.25), clamp(k * a * 1.4)));
    },
    waves(base, s, c) { glints(s, c, rgba(s.P.sea2, 0.75)); },
    // an island's reflection on the lake (or the headland's): under its shore, its hill and its tower upside down in
    // broken strokes, and the lamp's light on the water; then rings where things land
    ripples(base, s, c) {
      const g = s.g, u = g.u, P = s.P, v = s.cur.view;
      if (g.shore) {
        const T = g.lh, L = g.lamp, sl = g.shore, step = 3.2 * u / v.s, K = 0.8, xs = [];
        view(s, c, v); c.globalAlpha = smooth(FAR, FAR * 1.6, v.s);
        for (let x = sl[0][0]; x < sl.at(-1)[0]; x += step * 1.6) { const yw = s.shoreY(x); xs.push([x, yw, yw + (yw - s.ridgeY(x)) * K]); }
        c.fillStyle = rgba(dim(P, P.sea, 0.35));
        for (let y = Math.min(...xs.map(p => p[1])), i = 0; ; y += step, i++) {
          let x0 = null, any = false;
          for (const [x, yw, yd] of xs) {
            const on = y > yw && y < yd && hash(i * 13.1 + x * 0.071) > 0.12;
            any ||= y < yd;
            if (on && x0 == null) x0 = x;
            if (!on && x0 != null) { c.fillRect(x0, y, x - x0, step * 0.55); x0 = null; }
          }
          if (x0 != null) c.fillRect(x0, y, xs.at(-1)[0] - x0, step * 0.55);
          if (!any) break;
        }
        // the tower, from its foot down: white and the theme's stripes, broken across
        const th = THEMES[g.theme || s.theme], yw = s.shoreY(T.x);
        for (let y = yw + (yw - T.base) * K, i = 0; y < yw + (yw - T.top) * K; y += step, i++) {
          const k = (T.base - (yw - (y - yw) / K)) / T.h, hw = lerp(T.wB, T.wT, k) / 2, cut = (hash(i * 3.7) - 0.5) * hw;
          const j = Math.floor(k * 6);
          c.fillStyle = rgba(mix(j % 2 ? hex(th.stripes[(j >> 1) % th.stripes.length]) : P.paper, P.sea, 0.4));
          c.fillRect(T.x - hw, y, hw + cut - step * 0.4, step * 0.55); c.fillRect(T.x + cut + step * 0.4, y, hw - cut - step * 0.4, step * 0.55);
        }
        // the lamp: a glade of light strokes where it shows in the water
        const a = s.lampPower() * s.lampOn() * (0.3 + 0.7 * smooth(0.3, 0.8, s.d)), ly = yw + (yw - L.y) * K, er = T.er;
        c.fillStyle = rgba(P.beam, a);
        if (a >= 0.02) for (let j = -4; j <= 6; j++) {
          const w = er * (2.4 - Math.abs(j) * 0.3) * (0.7 + 0.6 * hash(j + Math.floor(s.t * 3))), y = ly + j * er * 0.42;
          c.fillRect(L.x - w / 2, y, w, step * 0.6);
        }
        c.globalAlpha = 1;
      }
      for (const r of s.ripples) {
        if (!afloat(s, c, r.y)) continue;
        const age = s.t - r.t0, rx = 8 * u + age * 70 * u;
        c.beginPath(); c.ellipse(r.x, r.y, rx, rx * 0.3, 0, 0, TAU); c.lineWidth = 1.6 * g.pw; c.strokeStyle = rgba(P.foam, clamp(1 - age / 2.2) * r.a); c.stroke();
      }
    },
    // the light: a flat fan with a brighter core, and the lake's strokes under it lit
    beam(base, s, c) {
      const P = s.P, I = s.beamI(), pw = s.lampPower(), { L, len, a0, a1 } = beamPoly(s);
      if (len < 10 || pw < 0.02) return;
      const night = smooth(0.3, 0.8, s.d), col = mix(P.beam, hex('#FFF6C2'), night * 0.45);
      const fan = k => { const m = (a0 + a1) / 2, out = [[L.x, L.y]]; for (let i = 0; i <= 12; i++) { const a = m + (a1 - m) * k * (i / 6 - 1); out.push([L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]); } return out; };
      poly(c, fan(1)); c.fillStyle = rgba(col, (0.8 + 0.14 * night * I) * pw); c.fill();
      poly(c, fan(0.4)); c.fillStyle = rgba(mix(col, hex('#FFFFFF'), 0.45), 0.85 * pw); c.fill();
      c.save(); poly(c, fan(1)); c.clip(); c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
      glints(s, c, rgba(mix(col, hex('#FFFFFF'), 0.5), 0.95 * pw));
      c.restore();
    },
    // a cloud lit from above on the left, its underside in shade
    cloud(base, s, c, cl, name, legs) {
      const g = s.g, u = g.u, P = s.P, p = s.cloudXY(cl), w = cl.w;
      if (p.x < -w || p.x > g.W + w) return;
      if (legs) {
        const walk = s.reduced ? 0 : s.t * 5, feet = [];
        c.beginPath();
        [-0.24, -0.11, 0.1, 0.23].forEach((lx, i) => {
          const x = p.x + lx * w * (cl.dir < 0 ? -1 : 1), sw = Math.sin(walk + i * 1.7 + (i % 2) * Math.PI) * 2.6 * u;
          flat(c, [[x, p.y - 4 * u], [x + sw * 0.5, p.y + 5 * u], [x + sw, p.y + 12 * u]], DET * 1.25);
          feet.push([x + sw, p.y + 13 * u]);
        });
        c.fillStyle = Hill.INK; c.fill();
        for (const [fx, fy] of feet) { c.beginPath(); c.ellipse(fx + 0.6 * u, fy, 2.6 * u, 1.9 * u, 0, 0, TAU); c.fill(); }
      }
      s.sprite(name + (legs && cl.dir < 0 ? 'L' : ''), w * 1.3, w * 0.75, p.x, p.y - w * 0.12, x => {
        const pts = dens(cloudPts(0, w * 0.12, w, cl.seed), 5, true);
        plane(x, pts, P.cloud);
        if (legs) {
          const f = cl.dir < 0 ? -1 : 1;
          x.beginPath(); flat(x, [[-f * w * 0.5, w * 0.02], [-f * w * 0.57, -w * 0.03], [-f * w * 0.6, w * 0.03]], TEX * 1.3); x.fillStyle = Hill.INK; x.fill();
        }
      });
    },
    // the hill: the slope down to the water lit, past the top the ground turning away in shade, the cliff over the
    // shore in shade, and the tower's and the cottage's shadows cast across the grass to the right
    hill(base, s, c) {
      const g = s.g, u = g.u, P = s.P, T = g.lh, k = g.cot, rd = g.ridge, top = rd.reduce((a, p) => (p[1] < a[1] ? p : a));
      print(c, g.hillPoly, P.hill);
      c.save(); poly(c, g.hillPoly); c.clip();
      for (const [side, col, f] of [[-1, mix(P.hill, P.paper, 0.2), 0.55], [1, P.hill2, 0.4]]) {
        const sh = rd.filter(([x]) => side * (x - top[0]) > T.wB * 2);
        print(c, [...sh, ...sh.map(([x, y]) => [lerp(x, top[0], f), y + Math.abs(top[0] - x) * 0.12]).reverse()], col);
      }
      if (g.shore) { const sl = g.shore, x0 = sl[0][0]; print(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x + 4 * u, y - (8 + (x - x0) / g.W * 26) * u])], P.hill2); }
      const cast = (x0, x1, y, l, end) => print(c, [[x0, y], [x1, y], [x1 + l * 0.8, y + l * 0.5], [x1 + l * 0.8 - end, y + l * 0.5]], dim(P, P.hill2, 0.12));
      cast(T.x - T.wB / 2, T.x + T.wB / 2, T.base - 2 * u, T.h * 0.32, T.wT);
      cast(k.x - k.w / 2, k.x + k.w / 2, k.base - 3 * u, k.h * 1.1, k.w * 0.4);
      c.restore();
      // the water's edge, a thin line of foam
      c.beginPath();
      flat(c, g.shore ? g.shore.map(([x, y]) => [x, y + 1.5 * u]) : rd.filter(p => p[1] > g.horizon + 3 && p[0] < T.x).map(([x, y]) => [x - 2 * u, y]), 2.2);
      c.fillStyle = rgba(P.foam); c.fill();
    },
    // the cottage: a lit wall with the eaves' shadow under the roof, a roof and a chimney lit on the left
    cottage(base, s, c) {
      const g = s.g, u = g.u, P = s.P, k = g.cot, w = k.w, h = k.h, x0 = k.x - w / 2, y0 = k.base - h;
      const paper = mul(hex('#FFFFFF'), P.paper), night = smooth(0.45, 0.75, s.d), chim = Hill.C.chimney, roof = Hill.C.roof;
      const chx = x0 + w * 0.68, chw = w * 0.15, cht = y0 - h * 1.45;
      print(c, [[chx, y0 - h * 0.2], [chx, cht], [chx + chw, cht], [chx + chw, y0 - h * 0.2]], chim);
      print(c, [[chx + chw * 0.6, y0 - h * 0.2], [chx + chw * 0.6, cht], [chx + chw, cht], [chx + chw, y0 - h * 0.2]], dim(P, chim));
      print(c, [[chx - 1.5 * u, cht + 2 * u], [chx - 1.5 * u, cht - 1.5 * u], [chx + chw + 1.5 * u, cht - 1.5 * u], [chx + chw + 1.5 * u, cht + 2 * u]], dim(P, chim, 0.45));
      print(c, [[x0, k.base], [x0, y0], [x0 + w, y0], [x0 + w, k.base]], paper);
      print(c, [[x0, y0], [x0 + w, y0], [x0 + w, y0 + h * 0.13], [x0, y0 + h * 0.07]], dim(P, paper, 0.22));
      const L = [x0 - w * 0.12, y0 + 1 * u], A = [x0 + w * 0.5, y0 - h * 0.78], Rt = [x0 + w * 1.12, y0 + 1 * u], M = [x0 + w * 0.5, y0 + 1 * u];
      print(c, [L, A, M], roof); print(c, [A, Rt, M], dim(P, roof));
      // the window: four panes, lit at night, the bars between them in the wall's shade
      const wx = x0 + w * 0.14, wy = y0 + h * 0.24, ww = w * 0.27, wh = h * 0.36, bar = 1.4 * u;
      print(c, [[wx, wy], [wx + ww, wy], [wx + ww, wy + wh], [wx, wy + wh]], night > 0.5 ? P.beam : P.glass);
      c.fillStyle = rgba(dim(P, paper, 0.45));
      c.fillRect(wx + ww / 2 - bar / 2, wy, bar, wh); c.fillRect(wx, wy + wh / 2 - bar / 2, ww, bar); c.fillRect(wx - bar, wy + wh, ww + bar * 2, bar * 1.2);
      // the door (it opens for the keeper: see the states)
      const dx = x0 + w * 0.56, dw = w * 0.24, dh = h * 0.66;
      k.door = { x: dx, y: k.base - dh, w: dw, h: dh };
      print(c, [[dx, k.base], [dx, k.base - dh], [dx + dw, k.base - dh], [dx + dw, k.base]], mul(Hill.C.door, P.paper));
      dot(c, dx + dw * 0.78, k.base - dh * 0.48, 1.3 * u + 0.4, Hill.INK);
    },
    // the tower: white with the theme's stripes, its right side in shade; dark windows, lit at night
    tower(base, s, c) {
      const g = s.g, u = g.u, P = s.P, T = g.lh, th = THEMES[g.theme || s.theme], paper = mul(hex('#FFFFFF'), P.paper);
      const half = k => lerp(T.wB, T.wT, k) / 2, yAt = k => T.base - T.h * k, bands = 6, sag = T.wB * 0.09;
      const side = f => { const out = []; for (let i = 0; i <= 20; i++) out.push([T.x + f * half(i / 20), yAt(i / 20)]); return out; };
      print(c, [...side(-1), ...side(1).reverse()], paper);
      const edge = k => { const hw = half(k), out = []; for (let i = 0; i <= 12; i++) { const f = i / 12 * 2 - 1; out.push([T.x + f * hw, yAt(k) - sag * (1 - f * f)]); } return out; };
      let n = 0;
      for (let j = 1; j < bands; j += 2) {
        const hi = j + 1 >= bands ? [[T.x + half(1), yAt(1)], [T.x - half(1), yAt(1)]] : edge((j + 1) / bands).reverse();
        print(c, [...edge(j / bands), ...hi], mul(hex(th.stripes[n++ % th.stripes.length]), P.paper));
      }
      print(c, [...side(0.28), ...side(1).reverse()], rgba(P.ink, 0.3));
      const night = smooth(0.45, 0.75, s.d), glass = night > 0.5 ? P.beam : P.ink;
      for (const k of [0.25, 0.58]) { const y = yAt(k), w = T.wB * 0.22, h = T.er * 0.75; print(c, [[T.x - w / 2, y - h / 2], [T.x + w / 2, y - h / 2], [T.x + w / 2, y + h / 2], [T.x - w / 2, y + h / 2]], glass); }
      const dw = T.wB * 0.32, dh = T.wB * 0.5;
      print(c, [[T.x - dw / 2, T.base], ...ellipse(T.x, T.base - dh + dw / 2, dw / 2, dw / 2, 10, Math.PI, TAU), [T.x + dw / 2, T.base]], P.ink);
      // the gallery: a dark deck the eye sits on, lit along its top
      const gw = T.wT * 0.95, gy = T.top;
      print(c, [[T.x - gw, gy + 1 * u], [T.x - gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.05, gy - T.gal * 0.42], [T.x + gw, gy + 1 * u]], P.ink);
      print(c, [[T.x - gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.05, gy - T.gal * 0.42], [T.x + gw * 1.04, gy - T.gal * 0.3], [T.x - gw * 1.04, gy - T.gal * 0.3]], dim(P, paper, 0.5));
    },
    // grass in a darker green than the hill, not in ink
    tufts(base, s, c) { base(s, c); c.fillStyle = rgba(dim(s.P, s.P.hill2, 0.25)); c.fill(); },
    // smoke in round flat puffs, lit on the left
    smoke(base, s, c) {
      if (s.reduced) return;
      const g = s.g, u = g.u, P = s.P, k = g.cot, x0 = k.x - k.w / 2 + k.w * 0.755, y0 = k.base - k.h * 2.5;
      for (let i = 0; i < 3; i++) {
        const a = (s.t * 0.22 + i / 3) % 1, x = x0 + s.windTotal * 50 * u * a + Math.sin(a * 6 + i) * 3 * u, y = y0 - 6 * u - a * 46 * u, r = (2.5 + a * 6) * u;
        c.globalAlpha = 1 - smooth(0.6, 1, a);
        dot(c, x + r * 0.2, y + r * 0.15, r, dim(P, P.cloud, 0.25)); dot(c, x - r * 0.1, y - r * 0.1, r * 0.82, P.cloud);
      }
      c.globalAlpha = 1;
    },
  },

});
})();
