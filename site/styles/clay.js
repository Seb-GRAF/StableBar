/* Lighthouse Hill in clay stop-motion, for Catppuccin (see the styles in scene.js): a model set in plasticine, lit
   from the upper left and shot on twos. Nothing is outlined: the fills are lumps of clay, lit and thumbed, and the
   lines that are things of their own (legs, grass, the lid, smoke, the arrows) are rolled strands of it. */
(() => {
const H = Hill, { TAU, clamp, lerp, smooth, hash, noise, rng, hex, mix, mul, rgba, poly, ellipse, dens, curve, rank } = H;
const WHITE = hex('#FFFFFF'), DARK = hex('#302D41');
// the fleece's balls, back to front, in the sheep's units
const FLEECE = [[-6, -23.5], [0, -24.5], [6, -23.5], [-11, -18], [-5.5, -18.5], [0.5, -19], [6, -18.5], [11, -17.5], [-8.5, -12], [-3, -11.5], [2.5, -11.5], [8, -12]];

/* the clay's skin, faint, the same all over: smears where a thumb slid, a few whorls of its print pressed in, and
   crumbs; drawn round the tile's edges too, so it repeats without a seam */
const PRINTS = (() => {
  const cv = document.createElement('canvas'), x = cv.getContext('2d'), R = rng(41), S = 200;
  cv.width = cv.height = S;
  const wrap = draw => { for (const dx of [-S, 0, S]) for (const dy of [-S, 0, S]) { x.save(); x.translate(dx, dy); draw(); x.restore(); } };
  x.lineCap = 'round';
  for (let i = 0; i < 70; i++) {
    const cx = R() * S, cy = R() * S, a = R() * TAU, l = 3 + R() * 7, w = 3 + R() * 4, col = R() < 0.5 ? `rgba(48,45,65,${0.025 + R() * 0.03})` : `rgba(255,255,255,${0.05 + R() * 0.05})`;
    wrap(() => { x.beginPath(); x.moveTo(cx, cy); x.quadraticCurveTo(cx + Math.cos(a) * l * 0.5 + Math.sin(a) * 2, cy + Math.sin(a) * l * 0.5 - Math.cos(a) * 2, cx + Math.cos(a) * l, cy + Math.sin(a) * l); x.lineWidth = w; x.strokeStyle = col; x.stroke(); });
  }
  for (let i = 0; i < 3; i++) {
    const cx = R() * S, cy = R() * S, rot = R() * TAU, arcs = [];
    for (let k = 2; k < 7; k++) { const a = R() * TAU; arcs.push([k * 1.5, a, a + 2 + R() * 2.5, 0.04 + R() * 0.04]); }
    wrap(() => { for (const [r, a0, a1, al] of arcs) { x.beginPath(); x.ellipse(cx, cy, r, r * 0.75, rot, a0, a1); x.lineWidth = 0.7; x.strokeStyle = `rgba(48,45,65,${al})`; x.stroke(); } });
  }
  for (let i = 0; i < 260; i++) { x.fillStyle = R() < 0.5 ? 'rgba(48,45,65,0.1)' : 'rgba(255,255,255,0.14)'; x.beginPath(); x.arc(R() * S, R() * S, 0.3 + R() * 0.7, 0, TAU); x.fill(); }
  return x.createPattern(cv, 'repeat');
})();
/* a soft shadow on the ground, under what stands there */
const BLOB = document.createElement('canvas');
BLOB.width = BLOB.height = 64;
{
  const x = BLOB.getContext('2d'), gr = x.createRadialGradient(32, 32, 0, 32, 32, 32);
  gr.addColorStop(0, 'rgba(48,45,65,0.42)'); gr.addColorStop(0.55, 'rgba(48,45,65,0.2)'); gr.addColorStop(1, 'rgba(48,45,65,0)');
  x.fillStyle = gr; x.fillRect(0, 0, 64, 64);
}
const shadow = (c, x, y, rx, ry) => c.drawImage(BLOB, x - rx, y - ry, rx * 2, ry * 2);

/* clay lit from (x, y): a soft highlight there, its own colour, then darker toward the far side */
function lit(c, x, y, r, col) {
  const gr = c.createRadialGradient(x, y, 0, x, y, r);
  gr.addColorStop(0, rgba(mix(col, WHITE, 0.45))); gr.addColorStop(0.15, rgba(mix(col, WHITE, 0.2)));
  gr.addColorStop(0.5, rgba(col)); gr.addColorStop(1, rgba(mix(col, DARK, 0.42)));
  return gr;
}
/* a lump of clay: the shape, nudged a little each frame as by a hand, lit across its size; its edge rounds over,
   lighter where it turns to the light and darker where it turns away; and prints in it */
function lump(c, pts, col) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
  const j = 0.35 * H.PW, b = H.BOIL * 2.3, e = Math.min(2.4 * H.PW, (x1 - x0) * 0.1, (y1 - y0) * 0.1), p = new Path2D();
  pts.forEach(([x, y], i) => p.lineTo(x + noise(i * 0.31 + b) * j, y + noise(i * 0.31 + b + 7) * j));
  p.closePath();
  c.fillStyle = typeof col === 'string' ? col : lit(c, lerp(x0, x1, 0.3), lerp(y0, y1, 0.26), Math.hypot(x1 - x0, y1 - y0) * 0.72, col);
  c.fill(p);
  c.save(); c.clip(p);
  c.lineWidth = e * 2; c.lineJoin = 'round';
  c.translate(e, e); c.strokeStyle = 'rgba(255,255,255,0.28)'; c.stroke(p);
  c.translate(-e * 2, -e * 2); c.strokeStyle = rgba(DARK, 0.2); c.stroke(p);
  c.globalAlpha *= 0.8; c.fillStyle = PRINTS; c.fill(p);
  c.restore();
}
/* a ball of clay */
function ball(c, x, y, r, col) {
  c.beginPath(); c.arc(x, y, r, 0, TAU); c.fillStyle = lit(c, x - r * 0.4, y - r * 0.45, r * 1.6, col); c.fill();
}

/* A rolled strand along a path, W wide: its shadow on what it lies on, the strand, a darker underside and a highlight
   along its top */
function rolled(c, p, W, col) {
  c.save();
  c.shadowColor = 'transparent'; c.lineCap = 'round'; c.lineJoin = 'round';
  c.translate(W * 0.3, W * 0.45); c.lineWidth = W; c.strokeStyle = 'rgba(48,45,65,0.22)'; c.stroke(p);
  c.translate(-W * 0.3, -W * 0.45); c.strokeStyle = col; c.stroke(p);
  c.translate(W * 0.06, W * 0.2); c.lineWidth = W * 0.5; c.strokeStyle = 'rgba(48,45,65,0.22)'; c.stroke(p);
  c.translate(-W * 0.18, -W * 0.44); c.lineWidth = W * 0.3; c.strokeStyle = 'rgba(255,255,255,0.45)'; c.stroke(p);
  c.restore();
}
/* The line, rolled in clay as it comes, in STRAND or the ink ('fill' takes the colour the caller has on), so the
   caller's fill finds nothing. Outlines aren't drawn. */
let STRAND = null;
function strand(c, pts, w, sd = 0, o = {}) {
  if (o.outline) return;
  const p = new Path2D(), j = 0.3 * H.PW, b = H.BOIL * 3.7 + sd;
  pts.forEach(([x, y], i) => p.lineTo(x + noise(i * 0.4 + b) * j, y + noise(i * 0.4 + b + 9) * j));
  rolled(c, p, w * H.PW, STRAND === 'fill' ? c.fillStyle : STRAND || H.INK);
}

/* The sea is a sheet of clay smoothed with a tool: its marks run across in rows, closer together toward the horizon,
   each a ridge lit along its top over a groove. The rows are the felt pen's scallops' (see waveScallops), so diving
   you go over them as fast. */
function ridges(s, c, top, groove) {
  const g = s.g, { W, u } = g, hz = g.horizon, sea = g.H - hz, ROW = 0.02, go = s.dive * H.DIVE_GAP / H.SHORE, alpha = c.globalAlpha;
  for (let k = Math.ceil((1 + go) / ROW); ;) {
    const rel = 1 / (k * ROW - go);
    if (rel < 0.0175) break;
    const f = rel ** (1 / 1.6), gap = 3.2 * sea * rel ** 0.375 / g.rows, dy = sea * ROW * rel * rel;
    const step = 2 ** Math.max(0, Math.ceil(Math.log2(gap / dy)));
    if (k % step) { k += step - k % step; continue; }
    const a = rank(k) > Math.log2(step) ? 1 : clamp(dy * step / gap - 1);
    k += step;
    if (a <= 0) continue;
    const q = k - step, row = { y: hz + sea * rel, f, seed: q * 97 + s.o.seed }, lw = (1.4 + 4.2 * f) * g.pw, hi = new Path2D(), lo = new Path2D();
    for (let i = 0; i < 5 + Math.round(4 * (1 - f)); i++) {
      const x0 = (hash(q * 0.13 + i * 0.71) * 1.3 - 0.15) * W, l = (24 + 150 * f) * Math.max(u, 0.66) * (0.5 + hash(q * 0.29 + i * 1.3));
      for (let m = 0; m <= 6; m++) {
        const x = x0 + l * m / 6, y = s.waveY(x, row) - Math.sin(m / 6 * Math.PI) * l * 0.04, to = m ? 'lineTo' : 'moveTo';
        hi[to](x, y - lw * 0.35); lo[to](x, y + lw * 0.5);
      }
    }
    c.globalAlpha = alpha * a;
    c.lineWidth = lw * 1.2; c.strokeStyle = groove; c.stroke(lo);
    c.lineWidth = lw * 0.75; c.strokeStyle = top; c.stroke(hi);
  }
  c.globalAlpha = alpha;
}

Hill.style('catppuccin', {
  // Latte by day, Mocha at night: pastel clay under a soft sky
  pal: H.stops([
    [0,    { sky: '#A6D8F2', sky2: '#DDE6FA', sea: '#6F9BEF', sea2: '#B0CAFB', foam: '#EFF1F5', hill: '#98D894', hill2: '#76BD7C', ink: '#4C4F69', paper: '#FFFBF8', beam: '#FFDD6E', cloud: '#F4F1F4', far: '#B4BEFE', glass: '#DCE7FA' }],
    [0.2,  { sky: '#B9C2F5', sky2: '#F2D5E3', sea: '#6A8FE6', sea2: '#AEC0F8', foam: '#F5F0F2', hill: '#90D18E', hill2: '#70B878', ink: '#4C4F69', paper: '#FFF7F2', beam: '#FFDD6E', cloud: '#F8EEF0', far: '#C6B9F2', glass: '#F2D5E3' }],
    [0.44, { sky: '#F5AE8A', sky2: '#F5C2E7', sea: '#6B7DE0', sea2: '#B4BEFE', foam: '#F5E0DC', hill: '#84BF88', hill2: '#66A276', ink: '#4A4563', paper: '#FBEDE6', beam: '#FFDD6E', cloud: '#F2CDCD', far: '#D59BC4', glass: '#FAB387' }],
    [0.7,  { sky: '#7F6BC0', sky2: '#C38BB8', sea: '#3E4A9A', sea2: '#7F8BDA', foam: '#D6CCF2', hill: '#4E8463', hill2: '#3E6E55', ink: '#2F2E45', paper: '#E3DCF5', beam: '#F9E2AF', cloud: '#B4A6E6', far: '#5E5594', glass: '#F9D98A' }],
    [1,    { sky: '#272A45', sky2: '#363A5E', sea: '#1F2442', sea2: '#4A5585', foam: '#A6ADC8', hill: '#36594A', hill2: '#2A4839', ink: '#1E1E2E', paper: '#C9CFEA', beam: '#F9E2AF', cloud: '#5B6080', far: '#313457', glass: '#F9E2AF' }],
  ]),
  C: {
    wool: hex('#F5F0EE'), yolk: hex('#F7BE5A'), duck: hex('#F7D774'), beak: hex('#FAB387'), pink: hex('#F5C2E7'),
    monster: hex('#EBA0AC'), chimney: hex('#F38BA8'), roof: hex('#6C6F93'), door: hex('#89B4FA'), skin: hex('#F5D5C0'),
    navy: hex('#5B6BC0'), wood: hex('#D9A27A'), steel: hex('#CCD0DA'), moon: hex('#F9E2AF'), tile: hex('#45475A'),
    huts: ['#F38BA8', '#89B4FA', '#F9E2AF', '#A6E3A1'].map(hex),
    kraft: hex('#E3B98C'), kraftLit: hex('#F0CDA5'), kraftDark: hex('#C69768'), tape: hex('#F9E2AF'), sprout: hex('#7ACB7E'),
  },
  ribbon: strand, print: lump, reg: [0, 0], pen: 1.5, boil: 12, fps: 12,
  hand: 'ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", sans-serif', weight: 700,

  draw: {
    // the backdrop, painted soft, and the sea's clay sheet, darker near
    sky(base, s, c) {
      const g = s.g, P = s.P, sky = c.createLinearGradient(0, g.top, 0, g.horizon), sea = c.createLinearGradient(0, g.horizon, 0, g.H);
      sky.addColorStop(0, rgba(mix(P.sky, DARK, 0.06))); sky.addColorStop(1, rgba(mix(P.sky, P.sky2, 0.45)));
      sea.addColorStop(0, rgba(mix(P.sea, P.sea2, 0.3))); sea.addColorStop(1, rgba(mix(P.sea, DARK, 0.18)));
      c.fillStyle = sky; c.fillRect(0, 0, g.W, g.horizon + 2);
      c.fillStyle = sea; c.fillRect(0, g.horizon, g.W, g.H - g.horizon);
    },
    // the lower sky, a lighter strip of the painted backdrop, and the sea's far edge rolled over
    band(base, s, c, bandTop) {
      const g = s.g, { W, u } = g, P = s.P, by = bandTop + 20 * u, band = [];
      for (let x = -30; x <= W + 30; x += 16 * u) band.push([x, by + Math.sin(x * 0.006 + 1) * 11 * u + Math.sin(x * 0.019 + 2) * 3 * u]);
      band.push([W + 30, g.horizon + 4], [-30, g.horizon + 4]);
      poly(c, band); c.fillStyle = rgba(P.sky2); c.fill();
      STRAND = rgba(mix(P.sea, P.sea2, 0.7)); strand(c, dens([[-10, g.horizon + 1], [W + 10, g.horizon + 1]], 30), H.DET * 1.2); STRAND = null;
    },
    // little stars cut from yellow clay, and crumbs of it between them
    stars(base, s, c) {
      const g = s.g, u = g.u, st = smooth(0.55, 0.9, s.d);
      if (st <= 0) return;
      c.beginPath();
      for (const p of g.stars) {
        if (p.s < 0.75) { c.moveTo(p.x + u, p.y); c.arc(p.x, p.y, 0.9 * u + 0.4, 0, TAU); continue; }
        const r = p.s * 3.4 * u * (s.reduced ? 1 : 0.85 + 0.15 * Math.sin(s.t * 2 + p.p));
        for (let i = 0; i < 10; i++) { const a = p.p + i / 10 * TAU, q = i % 2 ? r * 0.48 : r; c[i ? 'lineTo' : 'moveTo'](p.x + Math.cos(a) * q, p.y + Math.sin(a) * q); }
        c.closePath();
      }
      c.fillStyle = rgba(s.P.beam, st); c.fill();
      c.beginPath();
      for (const p of g.stars) if (p.s >= 0.75) { const r = p.s * 0.9 * u; c.moveTo(p.x - r * 0.5 + r, p.y - r * 0.6); c.arc(p.x - r * 0.5, p.y - r * 0.6, r, 0, TAU); }
      c.fillStyle = `rgba(255,255,255,${0.55 * st})`; c.fill();
    },
    waves(base, s, c) { ridges(s, c, rgba(mix(s.P.sea, s.P.sea2, 0.75)), rgba(mix(s.P.sea, DARK, 0.3))); },
    // where things land: a flattened ring of foam spreading
    ripples(base, s, c) {
      const u = s.g.u, P = s.P;
      for (const r of s.ripples) {
        if (!H.afloat(s, c, r.y)) continue;
        const age = s.t - r.t0, rx = 8 * u + age * 70 * u, p = new Path2D();
        p.ellipse(r.x, r.y, rx, rx * 0.3, 0, 0, TAU);
        c.globalAlpha = clamp(1 - age / 2.2) * r.a; rolled(c, p, H.DET * 0.9 * H.PW, rgba(P.foam)); c.globalAlpha = 1;
      }
    },
    // a fried egg in clay: a flattened white, a domed yolk with its shadow on it, and a shine
    sun(base, s, c) {
      const g = s.g, u = g.u, sun = s.sunPos();
      if (sun.a <= 0) return;
      const r = 38 * u, sz = r * 3;
      c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip();
      c.globalAlpha = sun.a;
      s.sprite('sun', sz, sz, sun.x, sun.y, x => {
        const white = [];
        for (let i = 0; i < 48; i++) { const a = i / 48 * TAU; white.push([Math.cos(a) * r * (1 + 0.12 * Math.sin(a * 3 + 1) + 0.06 * Math.sin(a * 5 + 2)), Math.sin(a) * r * 0.86 * (1 + 0.09 * Math.sin(a * 4))]); }
        lump(x, white, mul(WHITE, s.P.paper));
        shadow(x, 6 * u, 2 * u, r * 0.55, r * 0.5);
        ball(x, 3 * u, -3 * u, r * 0.42, H.C.yolk);
        x.beginPath(); x.ellipse(3 * u - r * 0.15, -3 * u - r * 0.2, r * 0.13, r * 0.08, -0.6, 0, TAU); x.fillStyle = 'rgba(255,255,255,0.75)'; x.fill();
      });
      c.restore();
    },
    // a cloud is lumps of clay pressed together on a flat base, each rounded in the light; the one with legs walks
    cloud(base, s, c, cl, name, legs) {
      const g = s.g, u = g.u, P = s.P, p = s.cloudXY(cl), w = cl.w;
      if (p.x < -w || p.x > g.W + w) return;
      if (legs) {
        const walk = s.reduced ? 0 : s.t * 5, lp = new Path2D();
        [-0.24, -0.11, 0.1, 0.23].forEach((lx, i) => {
          const x = p.x + lx * w * (cl.dir < 0 ? -1 : 1), sw = Math.sin(walk + i * 1.7 + (i % 2) * Math.PI) * 2.6 * u;
          lp.moveTo(x, p.y - 4 * u); lp.lineTo(x + sw * 0.5, p.y + 5 * u); lp.lineTo(x + sw, p.y + 12 * u);
        });
        rolled(c, lp, H.DET * 1.6 * H.PW, H.INK);
      }
      s.sprite(name + (legs && cl.dir < 0 ? 'L' : ''), w * 1.3, w * 0.75, p.x, p.y - w * 0.12, x => {
        const R = rng(cl.seed), n = 4 + ((R() * 2) | 0), lumps = [];
        for (let i = 0; i < n; i++) {
          const fx = (i + 0.5) / n, r = w * (0.12 + R() * 0.07) * (1.3 - Math.abs(fx - 0.5));
          lumps.push([-w / 2 + fx * w + (R() - 0.5) * w * 0.06, w * 0.1 - r * 0.62, r]);
        }
        x.beginPath();
        for (const [cx, cy, r] of lumps) { x.moveTo(cx + r, cy); x.arc(cx, cy, r, 0, TAU); }
        x.moveTo(w * 0.53, w * 0.08); x.ellipse(0, w * 0.08, w * 0.53, w * 0.06, 0, 0, TAU);
        x.fillStyle = lit(x, -w * 0.2, -w * 0.18, w * 0.75, P.cloud); x.fill();
        x.save(); x.globalAlpha = 0.55; x.fillStyle = PRINTS; x.fill(); x.restore();
        for (const [cx, cy, r] of lumps) { x.beginPath(); x.arc(cx - r * 0.3, cy - r * 0.35, r * 0.55, 0, TAU); x.fillStyle = 'rgba(255,255,255,0.16)'; x.fill(); }
        // a tail: it might be a sheep
        if (legs) ball(x, (cl.dir < 0 ? 1 : -1) * w * 0.53, 0, w * 0.05, P.cloud);
      });
    },
    // the light: a cone of yellow cellophane, crinkled into facets that catch it one way or the other, the sea's
    // ridges lit through it
    beam(base, s, c) {
      const P = s.P, I = s.beamI(), pw = s.lampPower(), { L, len, a0, a1 } = H.beamPoly(s);
      if (len < 10 || pw < 0.02) return;
      const night = smooth(0.3, 0.8, s.d), col = mix(P.beam, hex('#FFF6C2'), night * 0.45), n = 7, b = H.BOIL * 0.9;
      const at = (a, r) => [L.x + Math.cos(a) * r, L.y + Math.sin(a) * r];
      const crease = i => { const a = lerp(a0, a1, i / n), k = i % n ? 0.35 / n : 0; return [[L.x, L.y], at(a + noise(i * 1.7 + b) * k * (a1 - a0), len * 0.5), at(a + noise(i * 2.3 + b + 4) * k * (a1 - a0), len)]; };
      const fan = [[L.x, L.y]];
      for (let i = 0; i <= 12; i++) fan.push(at(lerp(a0, a1, i / 12), len));
      for (let i = 0; i < n; i++) {
        poly(c, [...crease(i), ...crease(i + 1).reverse()]);
        c.fillStyle = rgba(i % 2 ? mix(col, WHITE, 0.3) : col, (0.78 + 0.14 * night * I + (i % 2 ? 0.08 : 0) - hash(i) * 0.1) * pw); c.fill();
      }
      c.save(); poly(c, fan); c.clip(); c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
      ridges(s, c, rgba(mix(col, WHITE, 0.6), 0.9 * pw), rgba(mix(col, P.sea, 0.45), 0.5 * pw));
      c.restore();
      // the creases catch the light
      const p = new Path2D();
      for (let i = 1; i < n; i++) if (hash(i * 3.1) > 0.35) { const e = crease(i); p.moveTo(...at(lerp(a0, a1, i / n), s.g.lh.er * 2.4)); p.lineTo(...e[1]); p.lineTo(...e[2]); }
      c.lineWidth = 1.4 * H.PW; c.strokeStyle = `rgba(255,255,255,${0.5 * pw})`; c.stroke(p);
    },
    // the lit lantern at night: a glow round it, and a disc of light round the eye
    halo(base, s, c) {
      const L = s.g.lamp, er = s.g.lh.er, P = s.P, night = smooth(0.35, 0.85, s.d), f = s.beam.flash, k = Math.max(night * s.beamI(), f * 0.9) * s.lampOn() * s.lampPower();
      if (k < 0.02) return;
      const r = er * (4.6 + f * 1.4), gr = c.createRadialGradient(L.x, L.y, er, L.x, L.y, r);
      gr.addColorStop(0, rgba(P.beam, clamp(k * 0.55))); gr.addColorStop(1, rgba(P.beam, 0));
      c.beginPath(); c.arc(L.x, L.y, r, 0, TAU); c.fillStyle = gr; c.fill();
      c.globalAlpha = clamp(k * 1.4);
      lump(c, ellipse(L.x, L.y, er * 1.75, er * 1.6, 30), mix(P.beam, WHITE, 0.25));
      c.globalAlpha = 1;
    },
    // the hill: a big lump of green clay smoothed by thumbs, the shade on its flank toward the sea, a lip of light along
    // its top, a rolled strand of foam where it meets the water, and daisies of little balls
    hill(base, s, c) {
      const g = s.g, { W, u } = g, P = s.P, T = g.lh, rd = g.ridge, R = rng(5);
      if (g.isle) {
        const sl = g.shore, x0 = sl[0][0], x1 = sl.at(-1)[0], deep = x => Math.sin(Math.PI * (x - x0) / (x1 - x0)) * 18 * u;
        lump(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x, y + deep(x)])], mix(P.sea, P.hill2, 0.45));
      }
      lump(c, g.hillPoly, P.hill);
      if (g.shore) {
        const sl = g.shore, x0 = sl[0][0];
        lump(c, [...sl, ...sl.slice().reverse().map(([x, y]) => [x + 4 * u, y - (8 + (x - x0) / W * 26) * u])], P.hill2);
      } else {
        const fl = c.createLinearGradient(rd[0][0], g.H, T.x - T.wB * 2, s.ridgeY(T.x - T.wB * 2));
        fl.addColorStop(0, rgba(P.hill2, 0.95)); fl.addColorStop(0.45, rgba(P.hill2, 0.45)); fl.addColorStop(1, rgba(P.hill2, 0));
        poly(c, g.hillPoly); c.fillStyle = fl; c.fill();
      }
      // thumb marks: a smoothed ridge of clay over a groove
      const hi = new Path2D(), lo = new Path2D();
      for (let i = 0; i < (g.portrait ? 9 : 16); i++) {
        const x = lerp(rd[0][0] + 40 * u, W - 30 * u, R()), ry = s.ridgeY(x), l = (18 + R() * 26) * u;
        if (ry == null) { R(); continue; }
        const y = ry + (16 + R() * (g.portrait ? 40 : 160)) * u;
        if (g.shore && y > s.shoreY(x) - 12 * u) continue;
        hi.moveTo(x, y); hi.quadraticCurveTo(x + l / 2, y - l * 0.16, x + l, y + l * 0.08);
        lo.moveTo(x, y + 2 * u); lo.quadraticCurveTo(x + l / 2, y - l * 0.16 + 2 * u, x + l, y + l * 0.08 + 2 * u);
      }
      c.save(); poly(c, g.hillPoly); c.clip();
      const top = Math.min(...rd.map(p => p[1])), sh = c.createLinearGradient(0, top, 0, g.shore ? s.shoreY(T.x) : g.H);
      sh.addColorStop(0, 'rgba(255,255,255,0.2)'); sh.addColorStop(0.3, 'rgba(255,255,255,0)'); sh.addColorStop(1, rgba(DARK, 0.22));
      c.fillStyle = sh; c.fill();
      c.lineCap = 'round'; c.lineWidth = 2.6 * u;
      c.strokeStyle = rgba(mix(P.hill2, DARK, 0.2), 0.3); c.stroke(lo);
      c.strokeStyle = 'rgba(255,255,255,0.22)'; c.stroke(hi);
      const lip = new Path2D();
      rd.filter(p => p[0] > -20 && p[0] < W + 20).forEach(([x, y], i) => lip[i ? 'lineTo' : 'moveTo'](x, y + 2.4 * u));
      c.lineWidth = 3.4 * u; c.strokeStyle = 'rgba(255,255,255,0.3)'; c.stroke(lip);
      c.restore();
      const foam = g.shore ? g.shore.map(([x, y]) => [x, y + 2 * u]) : rd.filter(p => p[1] > g.horizon + 3 && p[0] < T.x).map(([x, y]) => [x - 2 * u, y]);
      STRAND = rgba(P.foam); strand(c, foam.filter(p => p[0] < W + 20), H.DET * 1.5, 23); STRAND = null;
      const D = rng(9);
      for (let i = 0; i < (g.portrait ? 6 : 11); i++) {
        const x = lerp(T.x - T.h * 0.42, Math.min(W - 10, g.cot.x + g.cot.w * 1.6), D()), ry = s.ridgeY(x);
        if (ry == null || Math.abs(x - T.x) < T.wB * 0.8 || Math.abs(x - g.cot.x) < g.cot.w * 0.6) { D(); continue; }
        const y = ry + (8 + D() * (g.portrait ? 20 : 46)) * u, r = 2.3 * u;
        for (let k = 0; k < 5; k++) { const a = k / 5 * TAU; ball(c, x + Math.cos(a) * r, y + Math.sin(a) * r, 1.6 * u, mul(WHITE, P.paper)); }
        ball(c, x, y, 1.5 * u, H.C.yolk);
      }
    },
    // the cottage stands on the hill; its roof is clay like the rest, not inked
    cottage(base, s, c) {
      const g = s.g, u = g.u, k = g.cot, x0 = k.x - k.w / 2, y0 = k.base - k.h;
      shadow(c, k.x + k.w * 0.1, k.base + 1 * u, k.w * 0.75, 5 * u);
      base(s, c);
      lump(c, [[x0 - k.w * 0.12, y0 + 1 * u], [x0 + k.w * 0.5, y0 - k.h * 0.78], [x0 + k.w * 1.12, y0 + 1 * u]], H.C.roof);
    },
    // the tower: a round column of white clay with bands of the theme's pressed round it, lit down its left side,
    // in shade down its right; dark clay for the door, the windows and the gallery
    tower(base, s, c) {
      const g = s.g, u = g.u, P = s.P, T = g.lh, th = H.THEMES[g.theme || s.theme];
      const half = k => lerp(T.wB, T.wT, k) / 2, yAt = k => T.base - T.h * k, Lp = [], Rp = [];
      for (let i = 0; i <= 20; i++) { const k = i / 20; Lp.push([T.x - half(k), yAt(k)]); Rp.push([T.x + half(k), yAt(k)]); }
      const body = [...Lp, ...Rp.reverse()], box = [T.x - T.wB / 2, T.top - 2, T.wB, T.h + 4];
      shadow(c, T.x + T.wB * 0.3, T.base + 1 * u, T.wB * 1.05, 5.5 * u);
      c.save(); poly(c, body); c.clip();
      c.fillStyle = rgba(mul(WHITE, P.paper)); c.fillRect(...box);
      const bands = 6, sag = T.wB * 0.09, seams = new Path2D();
      const edge = k => { const hw = half(k), out = []; for (let i = 0; i <= 12; i++) { const f = i / 12 * 2 - 1; out.push([T.x + f * hw, yAt(k) - sag * (1 - f * f)]); } return out; };
      for (let j = 1, n = 0; j < bands; j += 2) {
        const lo = edge(j / bands), hi = j + 1 >= bands ? [[T.x + half(1), yAt(1) - 2], [T.x - half(1), yAt(1) - 2]] : edge((j + 1) / bands).reverse();
        poly(c, [...lo, ...hi]); c.fillStyle = rgba(mul(hex(th.stripes[n++ % th.stripes.length]), P.paper)); c.fill();
      }
      for (let j = 1; j < bands; j++) edge(j / bands).forEach(([x, y], i) => seams[i ? 'lineTo' : 'moveTo'](x, y + 0.8 * u));
      c.lineWidth = 1.4 * u; c.strokeStyle = rgba(DARK, 0.14); c.stroke(seams);
      const sh = c.createLinearGradient(T.x - T.wB / 2, 0, T.x + T.wB / 2, 0);
      sh.addColorStop(0, 'rgba(255,255,255,0.32)'); sh.addColorStop(0.3, 'rgba(255,255,255,0)'); sh.addColorStop(0.58, rgba(DARK, 0)); sh.addColorStop(1, rgba(DARK, 0.4));
      c.fillStyle = sh; c.fillRect(...box);
      c.globalAlpha = 0.55; c.fillStyle = PRINTS; c.fillRect(...box);
      c.restore();
      const win = k => { const y = yAt(k), w = T.wB * 0.22, h = T.er * 0.75; return [[T.x - w / 2, y - h / 2], [T.x + w / 2, y - h / 2], [T.x + w / 2, y + h / 2], [T.x - w / 2, y + h / 2]]; };
      for (const k of [0.25, 0.58]) lump(c, win(k), smooth(0.45, 0.75, s.d) > 0.5 ? P.beam : H.C.roof);
      const dw = T.wB * 0.32, dh = T.wB * 0.5;
      lump(c, [[T.x - dw / 2, T.base], ...ellipse(T.x, T.base - dh + dw / 2, dw / 2, dw / 2, 10, Math.PI, TAU), [T.x + dw / 2, T.base]], H.C.roof);
      const gw = T.wT * 0.95;
      lump(c, [[T.x - gw, T.top + 1 * u], [T.x - gw * 1.05, T.top - T.gal * 0.42], [T.x + gw * 1.05, T.top - T.gal * 0.42], [T.x + gw, T.top + 1 * u]], P.ink);
    },
    // grass along the ridge, in rolled strands of darker green
    tufts(base, s, c) {
      const g = s.g, u = g.u, p = new Path2D();
      for (const b of g.tufts) {
        let a = s.reduced ? 0.12 : Math.sin(s.t * 1.6 + b.p) * 0.14 * (0.6 + s.windAmb) + s.windTotal * 0.36;
        if (s.ptr.on && !s.reduced) {
          const dx = b.x - s.ptr.x, dy = b.y - s.ptr.y, r = 95 * u, d2 = dx * dx + dy * dy;
          if (d2 < r * r) a += Math.sign(dx || 1) * 1.05 * (1 - Math.sqrt(d2) / r);
        }
        a = clamp(a, -1.3, 1.3);
        for (let k = 0; k < b.n + 1; k++) {
          const da = (k - b.n / 2) * 0.42, l = b.l * (k === 1 ? 1.15 : 0.85), x = b.x + (k - b.n / 2) * 1.6 * u, y = b.y + 1.5 * u;
          const tx = x + Math.sin(a + da) * l, ty = y - Math.cos(a + da) * l;
          p.moveTo(x, y); p.quadraticCurveTo(lerp(x, tx, 0.5), lerp(y, ty, 0.55), tx, ty);
        }
      }
      rolled(c, p, H.TEX * 1.4 * H.PW, rgba(mix(s.P.hill2, DARK, 0.25)));
    },
    meadow(base, s, c, m) {
      STRAND = rgba(mix(s.P.hill2, H.C.sprout, 0.85 * (1 - smooth(0.4, 0.9, s.d)))); base(s, c, m); STRAND = null;
    },
    smoke(base, s, c) { STRAND = rgba(mix(s.P.cloud, s.P.ink, 0.2), 0.9); base(s, c); STRAND = null; },
    splashes(base, s, c) { STRAND = rgba(s.P.foam); base(s, c); STRAND = null; },
    // what stands on the hill stands in its own shadow
    obj(base, s, c, o) {
      if (o.state === 'land' && (o.kind === 'sheep' || o.kind === 'cow')) { const k = s.g.u * o.sc; shadow(c, o.x + 2 * k, o.y, 19 * k, 3.6 * k); }
      base(s, c, o);
    },
    keeper(base, s, c, x, y, sc, ...rest) { shadow(c, x + 1.5 * s.g.u * sc, y, 9 * s.g.u * sc, 2.4 * s.g.u * sc); base(s, c, x, y, sc, ...rest); },
    // a sheep: a fleece of small clay balls on four strands of legs, a dark clay face
    sheep(base, c, u, wool, o, t) {
      const fall = o.state === 'fall' || o.state === 'leap', step = Math.hypot(o.vx, o.vd || 0) > 2 ? Math.sin(t * 14 + o.seed) * 2 * u : 0, legs = new Path2D();
      [-8, -3, 5, 10].forEach((lx, i) => { legs.moveTo(lx * u, -10 * u); legs.lineTo(lx * u + (fall ? 3 * u : (i % 2 ? step : -step)), 0); });
      rolled(c, legs, H.DET * 1.25 * H.PW, H.INK);
      lump(c, ellipse(0, -16 * u, 13.5 * u, 9 * u, 20), mix(wool, DARK, 0.18));
      const ja = H.joyAt(o, t);
      c.save(); c.translate(-14 * u, -19 * u); c.rotate(-0.45 + (ja >= 0 ? Math.sin(ja * 24) * 0.6 * (1 - ja / 1.3) : 0));
      ball(c, -2.4 * u, 0, 3 * u, wool);
      c.restore();
      for (const [x, y] of FLEECE) ball(c, (x + noise(x + o.seed + H.BOIL) * 0.5) * u, (y + noise(y + o.seed + H.BOIL) * 0.5) * u, 4.3 * u, wool);
      H.head(c, u, o, t, 15, -19, [19, -7.5], 1.05, chew => {
        const face = mul(hex('#585B70'), wool);
        lump(c, ellipse(15 * u, -19 * u, 5 * u, 6.4 * u, 18, 0, TAU, -0.35), face);
        lump(c, ellipse(11.5 * u, -23.5 * u, 3.6 * u, 1.6 * u, 10, 0, TAU, 0.5 + chew * 0.25), face);
        for (const [x, y] of [[11.8, -24.6], [14.6, -25.8], [17.2, -24.6]]) ball(c, x * u, y * u, 2.3 * u, wool);
        STRAND = '#FFFFFF';
        if (ja >= 0) strand(c, ellipse(16.6 * u, -19.6 * u, 1.7 * u, 1.3 * u, 8, Math.PI * 1.1, Math.PI * 1.9), H.TEX, 4);
        else if (H.NAP) H.napEye(c, 16.6 * u, -20.5 * u, 1.5 * u, '#FFFFFF');
        else { H.dot(c, 16.6 * u, -20.5 * u, 1.6 * u, '#FFFFFF'); H.dot(c, 17.1 * u, -20.3 * u, 0.8 * u, H.INK); }
        STRAND = null;
      });
    },
    // the sea monster: humps and a neck of clay, foam rolled round where they go into the water
    monster(base, c, u, pink, P, o, t) {
      const sw = Math.sin(t * 1.6 + o.seed);
      STRAND = rgba(P.foam);
      for (let i = 0; i < 3; i++) {
        const hx = (-30 + i * 19) * u, hh = (8 + 2.5 * Math.sin(t * 2 + i * 1.3)) * u * (0.85 + 0.15 * sw);
        lump(c, [...ellipse(hx, 1 * u, 8.5 * u, hh, 14, Math.PI, TAU), [hx + 8.5 * u, 1 * u]], pink);
        strand(c, [[hx - 11 * u, 1.5 * u], [hx, 0], [hx + 11 * u, 1.5 * u]], H.TEX, i + 4);
      }
      lump(c, curve([[20 * u, 1 * u], [22 * u, -10 * u], [27 * u, -20 * u], [34 * u, -25 * u], [42 * u, -26 * u], [48 * u, -21 * u], [46 * u, -16 * u], [38 * u, -16 * u], [33 * u, -11 * u], [31 * u, 1 * u]], 2), pink);
      strand(c, [[16 * u, 1.5 * u], [26 * u, 0], [36 * u, 1.5 * u]], H.TEX, 8);
      STRAND = null;
      ball(c, 41 * u, -21.5 * u, 2.8 * u, mul(WHITE, P.paper));
      H.dot(c, 41.8 * u, -21.3 * u, 1.1 * u, H.INK);
      strand(c, [[45 * u, -18 * u], [47 * u, -17.6 * u]], H.TEX, 10);
      // its little top hat, with a red band
      lump(c, [[36 * u, -25.5 * u], [37 * u, -35 * u], [45 * u, -35.5 * u], [45.5 * u, -26 * u]], P.ink);
      c.fillStyle = rgba(mul(H.C.chimney, P.paper)); c.fillRect(36.6 * u, -29.5 * u, 8.6 * u, 2 * u);
      strand(c, [[33 * u, -25.8 * u], [49 * u, -26.4 * u]], H.DET * 1.2, 2);
    },
    // the labels and the doodles: letters cut from clay, standing a little off the backdrop
    labels(base, s, c) {
      STRAND = 'fill';
      c.save(); c.shadowColor = rgba(DARK, 0.3); c.shadowOffsetX = c.shadowOffsetY = 1.4 * s.g.pw;
      base(s, c);
      c.restore(); STRAND = null;
    },
    doodles(base, s, c) {
      STRAND = rgba(mix(s.P.ink, s.P.paper, smooth(0.5, 0.7, s.d)));
      c.save(); c.shadowColor = rgba(DARK, 0.3); c.shadowOffsetX = c.shadowOffsetY = 1.2 * s.g.pw;
      base(s, c);
      c.restore(); STRAND = null;
    },
  },
});
})();
