/* Lighthouse Hill in a screen-printed poster, for Gruvbox (see the styles in scene.js): a fat round brush line held
   still, a few flat inks printed off the line, halftone dots for shade, and paper grain over it all */
(() => {
const { clamp, lerp, smooth, noise, rng, hex, mix, mul, rgba, ellipse, poly, dens, dot, beamPoly, waveScallops, TAU } = Hill;
const RED = hex('#FB4934'), ORANGE = hex('#FE8019'), YELLOW = hex('#FABD2F'), CREAM = hex('#FBF1C7');

/* The dot screens: dark ink dots on a 45° grid, small, middling and heavy, drawn at four times the size and
   shrunk back so they stay crisp on a sharp screen */
const SCREEN = 7;
const screen = r => {
  const cv = document.createElement('canvas'), x = cv.getContext('2d'), k = 4;
  cv.width = cv.height = SCREEN * k;
  x.fillStyle = '#282828';
  for (const [cx, cy] of [[0, 0], [SCREEN, 0], [0, SCREEN], [SCREEN, SCREEN], [SCREEN / 2, SCREEN / 2]]) { x.beginPath(); x.arc(cx * k, cy * k, r * k, 0, TAU); x.fill(); }
  const p = x.createPattern(cv, 'repeat');
  p.setTransform(new DOMMatrix([1 / k, 0, 0, 1 / k, 0, 0]));
  return p;
};
const DOTS = { light: screen(0.8), mid: screen(1.3), deep: screen(1.8) };
// a dot screen printed over the polygon, off the line like the other inks
function shade(c, pts, dots) { poly(c, pts, true, Hill.REGX, Hill.REGY); c.fillStyle = dots; c.fill(); }
// an animal's shady underside: light dots in the lower part of an ellipse round its body
function belly(c, cx, cy, rx, ry, y) {
  c.save(); poly(c, ellipse(cx, cy, rx, ry, 24), true, Hill.REGX, Hill.REGY); c.clip();
  c.fillStyle = DOTS.light; c.fillRect(cx - rx, y, rx * 2, cy + ry - y + Hill.REGY); c.restore();
}

/* The paper: a tile of specks, lighter and darker, laid over the whole print */
const GRAIN = (() => {
  const cv = document.createElement('canvas'), x = cv.getContext('2d'), n = 256, R = rng(70);
  cv.width = cv.height = n;
  const im = x.createImageData(n, n), d = im.data;
  for (let i = 0; i < n * n; i++) {
    const r = R(), j = i * 4;
    if (r < 0.1) { d[j] = 40; d[j + 1] = 36; d[j + 2] = 30; d[j + 3] = 16 + R() * 22; }
    else if (r < 0.2) { d[j] = 251; d[j + 1] = 241; d[j + 2] = 199; d[j + 3] = 14 + R() * 20; }
  }
  x.putImageData(im, 0, 0);
  return x.createPattern(cv, 'repeat');
})();

/* The line: a fat round brush, the same width all along, with a little of the hand in it but no boil, and no
   hatching (the dots shade) */
function brush(c, pts, w, sd = 0, o = {}) {
  const n = pts.length;
  if (n < 2 || o.hatch) return;
  const hw = w * Hill.PW * 0.5, l = [], r = [];
  let s = 0;
  for (let i = 0; i < n; i++) {
    const a = pts[i > 0 ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : n - 1];
    let tx = b[0] - a[0], ty = b[1] - a[1];
    const tl = Math.hypot(tx, ty) || 1; tx /= tl; ty /= tl;
    if (i) s += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    const off = 0.3 * Hill.PW * noise(s / 80 + sd * 3.71), x = pts[i][0] - ty * off, y = pts[i][1] + tx * off;
    l.push([x - ty * hw, y + tx * hw]); r.push([x + ty * hw, y - tx * hw]);
  }
  // round ends: half a turn from one side to the other
  const cap = (p, q) => {
    const cx = (p[0] + q[0]) / 2, cy = (p[1] + q[1]) / 2, a0 = Math.atan2(p[1] - cy, p[0] - cx);
    for (let k = 1; k < 6; k++) c.lineTo(cx + Math.cos(a0 - k / 6 * Math.PI) * hw, cy + Math.sin(a0 - k / 6 * Math.PI) * hw);
  };
  c.moveTo(l[0][0], l[0][1]);
  for (let i = 1; i < n; i++) c.lineTo(l[i][0], l[i][1]);
  cap(l[n - 1], r[n - 1]);
  for (let i = n - 1; i >= 0; i--) c.lineTo(r[i][0], r[i][1]);
  cap(r[0], l[0]);
  c.closePath();
}

Hill.style('gruvbox', {
  pal: Hill.stops([
    [0,    { sky: '#EBDBB2', sky2: '#F7D488', sea: '#458588', sea2: '#83A598', foam: '#FBF1C7', hill: '#B8BB26', hill2: '#98971A', ink: '#282828', paper: '#FBF1C7', beam: '#FABD2F', cloud: '#FBF1C7', far: '#A89984', glass: '#83A598' }],
    [0.2,  { sky: '#F2CF8C', sky2: '#F6B860', sea: '#3F7A80', sea2: '#83A598', foam: '#FBF1C7', hill: '#AEAF24', hill2: '#8F8C19', ink: '#282828', paper: '#FBEBC0', beam: '#FABD2F', cloud: '#FBE6B4', far: '#B88A6A', glass: '#F7D488' }],
    [0.44, { sky: '#D65D0E', sky2: '#FABD2F', sea: '#356A70', sea2: '#83A598', foam: '#F2DFB4', hill: '#98971A', hill2: '#7A7614', ink: '#282828', paper: '#F6E3B6', beam: '#FABD2F', cloud: '#F4B860', far: '#A85A3A', glass: '#FABD2F' }],
    [0.7,  { sky: '#8F3F71', sky2: '#CC241D', sea: '#2A4A50', sea2: '#5F8A86', foam: '#D5C4A1', hill: '#606114', hill2: '#4E4D0D', ink: '#1D2021', paper: '#EBDBB2', beam: '#FABD2F', cloud: '#B16286', far: '#5C3450', glass: '#FABD2F' }],
    [1,    { sky: '#282828', sky2: '#3C3836', sea: '#253A3C', sea2: '#458588', foam: '#A89984', hill: '#3F400D', hill2: '#343309', ink: '#1D2021', paper: '#D5C4A1', beam: '#FABD2F', cloud: '#504945', far: '#32302F', glass: '#FABD2F' }],
  ]),
  C: {
    wool: hex('#FBF1C7'), yolk: hex('#FABD2F'), duck: hex('#FABD2F'), beak: hex('#FE8019'), pink: hex('#D3869B'),
    monster: hex('#D3869B'), chimney: hex('#CC241D'), roof: hex('#3C3836'), door: hex('#458588'), skin: hex('#F2C48D'),
    navy: hex('#3C3836'), wood: hex('#D65D0E'), steel: hex('#BDAE93'), moon: hex('#FABD2F'), tile: hex('#282828'),
    huts: ['#CC241D', '#458588', '#D79921', '#98971A'].map(hex),
    kraft: hex('#D79921'), kraftLit: hex('#FABD2F'), kraftDark: hex('#B57614'), tape: hex('#FB4934'), sprout: hex('#98971A'),
  },
  ribbon: brush, pen: 1.6, boil: 0, reg: [3.4, 2.6],
  hand: '"Rockwell", "Cooper Black", "Cooper", serif',
  after(s, c) { c.fillStyle = GRAIN; c.fillRect(0, 0, s.g.W, s.g.H); },
  draw: {
    // the sea goes darker in dots as it comes toward you
    sky(base, s, c) {
      base(s, c);
      const g = s.g, sea = g.H - g.horizon;
      [DOTS.light, DOTS.mid, DOTS.deep].forEach((d, i) => { c.fillStyle = d; c.fillRect(0, g.horizon + sea * (0.36 + i * 0.22), g.W, sea * 0.22); });
    },
    // the striped sunset: a disc in yellow, orange and red, cut by bands of sky that widen as it goes down
    sun(base, s, c) {
      const g = s.g, u = g.u, P = s.P, sun = s.sunPos();
      if (sun.a <= 0) return;
      const r = 40 * u, sz = r * 2.4, inks = [YELLOW, YELLOW, ORANGE, ORANGE, RED, RED, RED];
      c.save(); c.beginPath(); c.rect(0, 0, g.W, g.horizon); c.clip();
      c.globalAlpha = sun.a;
      s.sprite('sun', sz, sz, sun.x, sun.y, x => {
        x.save(); poly(x, ellipse(0, 0, r, r, 64)); x.clip();
        const h = r * 2 / inks.length;
        inks.forEach((col, i) => {
          const gap = Math.max(0, i - 2) * 0.13 * h;
          x.fillStyle = rgba(mul(col, P.paper)); x.fillRect(-r, -r + i * h + gap, r * 2, h - gap + 0.5);
        });
        x.restore();
      });
      c.restore();
    },
    // the light in bands of yellow and orange, like the stripes under the bar
    beam(base, s, c) {
      const g = s.g, P = s.P, I = s.beamI(), pw = s.lampPower(), { L, len, a0, a1 } = beamPoly(s);
      if (len < 10 || pw < 0.02) return;
      const night = smooth(0.3, 0.8, s.d), al = (0.86 + 0.12 * night * I) * pw;
      const fan = (b0, b1) => { const f = [[L.x, L.y]]; for (let i = 0; i <= 8; i++) { const a = lerp(b0, b1, i / 8); f.push([L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]); } return f; };
      const all = fan(a0, a1);
      poly(c, all); c.fillStyle = rgba(mix(P.beam, CREAM, night * 0.3), al); c.fill();
      for (const k of [1, 3]) { poly(c, fan(lerp(a0, a1, k / 5), lerp(a0, a1, (k + 1) / 5))); c.fillStyle = rgba(ORANGE, al); c.fill(); }
      c.save(); poly(c, all); c.clip(); c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0);
      c.strokeStyle = rgba(CREAM, 0.9 * pw); waveScallops(s, c, true);
      c.restore();
      const r0 = g.lh.er * 2.3;
      c.beginPath();
      for (const a of [a0, a1]) brush(c, dens([[L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0], [L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]], 9), Hill.DET);
      if (s.beam.len < 0.85) brush(c, dens(all.slice(1), 6), Hill.DET);
      c.globalAlpha = 0.3 + 0.7 * pw; c.fillStyle = Hill.INK; c.fill(); c.globalAlpha = 1;
    },
    cloud(base, s, c, cl, name, legs) {
      const g = s.g, u = g.u, P = s.P, p = s.cloudXY(cl), w = cl.w, { DET, TEX } = Hill;
      if (p.x < -w || p.x > g.W + w) return;
      if (legs) {
        // four legs, walking when it walks
        const walk = s.reduced ? 0 : s.t * 5;
        c.beginPath();
        [-0.24, -0.11, 0.1, 0.23].forEach((lx, i) => {
          const x = p.x + lx * w * (cl.dir < 0 ? -1 : 1), sw = Math.sin(walk + i * 1.7 + (i % 2) * Math.PI) * 2.6 * u;
          brush(c, [[x, p.y - 4 * u], [x + sw * 0.5, p.y + 5 * u], [x + sw, p.y + 12 * u]], DET * 1.25, i);
        });
        c.fillStyle = Hill.INK; c.fill();
      }
      s.sprite(name + (legs && cl.dir < 0 ? 'L' : ''), w * 1.5, w * 0.9, p.x, p.y - w * 0.12, x => {
        // round puffs standing on a flat base
        const R = rng(cl.seed), n = 3 + ((R() * 2) | 0), by = w * 0.12, puffs = [], top = [];
        for (let i = 0; i < n; i++) { const fx = (i + 0.5) / n; puffs.push([-w / 2 + fx * w, w * (0.2 + R() * 0.08) * (1.25 - Math.abs(fx - 0.5) * 0.9)]); }
        for (let i = 0; i <= 72; i++) {
          const px = lerp(-w * 0.62, w * 0.62, i / 72);
          let py = by;
          for (const [bx, r] of puffs) if (Math.abs(px - bx) < r) py = Math.min(py, by - Math.sqrt(r * r - (px - bx) ** 2));
          if (py < by) top.push([px, py]);
        }
        const pts = dens([...top, [top.at(-1)[0], by], [top[0][0], by]], 4, true);
        Hill.print(x, pts, P.cloud);
        // dots along its underside
        x.save(); poly(x, pts, true, Hill.REGX, Hill.REGY); x.clip(); x.fillStyle = DOTS.light; x.fillRect(-w, by - w * 0.09, w * 2, w * 0.1); x.restore();
        x.beginPath(); Hill.loop(x, pts, DET, cl.seed % 13);
        // a curl inside each puff, where it catches the light
        puffs.forEach(([bx, r], i) => brush(x, ellipse(bx, by, r * 0.66, r * 0.66, 10, Math.PI * 1.18, Math.PI * 1.48), TEX, i));
        x.fillStyle = Hill.INK; x.fill();
      });
    },
    // the shady flank of the hill in dots, middling on it and light in a band round it that thins out into the lit
    // side, in place of the felt pen's hatching
    hill(base, s, c) {
      base(s, c);
      const g = s.g, { W, H, u } = g, T = g.lh, sh = g.ridge.filter(([x]) => x < T.x - T.wB * 2), n = sh.length, x0 = g.shore?.[0][0];
      // f times as wide as the felt pen's: a cliff band above the shore, or the side turning away from the light
      const flank = f => g.shore
        ? [...g.shore, ...g.shore.slice().reverse().map(([x, y]) => [x + 4 * u, y - (8 + (x - x0) / W * 26) * u * f])]
        : [...sh, ...sh.map(([x, y], i) => { const k = smooth(0, 0.35, (n - 1 - i) / n) * f; return [x + (34 + (H - y) * 0.12) * u * k, y + (16 + (H - y) * 0.05) * u * k]; }).reverse()];
      c.save(); poly(c, flank(1), true, Hill.REGX, Hill.REGY); c.rect(0, 0, W, H); c.clip('evenodd');
      shade(c, flank(2.2), DOTS.light);
      c.restore();
      shade(c, flank(1), DOTS.mid);
    },
    // the tower's shady side in dots, in place of the felt pen's hatching
    tower(base, s, c) {
      base(s, c);
      const T = s.g.lh, half = k => lerp(T.wB, T.wT, k) / 2, Sp = [], Rp = [];
      for (let i = 0; i <= 20; i++) { const k = i / 20; Sp.push([T.x + half(k) * 0.3, T.base - T.h * k]); Rp.push([T.x + half(k), T.base - T.h * k]); }
      shade(c, [...Sp, ...Rp.reverse()], DOTS.mid);
    },
    // grass along the ridge in fat blades, leaning with the wind and away from the pointer
    tufts(base, s, c) {
      const g = s.g, u = g.u;
      c.beginPath();
      for (const b of g.tufts) {
        let a = s.reduced ? 0.12 : Math.sin(s.t * 1.6 + b.p) * 0.14 * (0.6 + s.windAmb) + s.windTotal * 0.36;
        if (s.ptr.on && !s.reduced) {
          const dx = b.x - s.ptr.x, dy = b.y - s.ptr.y, r = 95 * u, d2 = dx * dx + dy * dy;
          if (d2 < r * r) a += Math.sign(dx || 1) * 1.05 * (1 - Math.sqrt(d2) / r);
        }
        a = clamp(a, -1.3, 1.3);
        for (let k = 0; k < b.n; k++) {
          const da = (k - (b.n - 1) / 2) * 0.5, l = b.l * (k === 1 ? 1.1 : 0.8), x = b.x + (k - (b.n - 1) / 2) * 2.6 * u, y = b.y + 1.5 * u;
          const tx = x + Math.sin(a + da) * l, ty = y - Math.cos(a + da) * l, w = 2 * g.pw;
          c.moveTo(x - w, y); c.quadraticCurveTo(lerp(x, tx, 0.5) - w * 0.5, lerp(y, ty, 0.55), tx, ty); c.quadraticCurveTo(lerp(x, tx, 0.5) + w * 0.5, lerp(y, ty, 0.55), x + w, y); c.closePath();
        }
      }
      c.fillStyle = Hill.INK; c.fill();
    },
    // the shadow of the eaves across the top of the wall
    cottage(base, s, c) {
      base(s, c);
      const k = s.g.cot, x0 = k.x - k.w / 2, y0 = k.base - k.h;
      shade(c, [[x0, y0], [x0 + k.w, y0], [x0 + k.w, y0 + k.h * 0.18], [x0, y0 + k.h * 0.18]], DOTS.mid);
    },
    sheep(base, c, u, wool, o, t) { base(c, u, wool, o, t); belly(c, 0, -16 * u, 14 * u, 9.5 * u, -14 * u); },
    cow(base, c, u, white, P, o, t) { base(c, u, white, P, o, t); belly(c, -0.75 * u, -18 * u, 17.5 * u, 8 * u, -15 * u); },
    duck(base, c, u, yellow, P, o, t) { base(c, u, yellow, P, o, t); belly(c, -1.5 * u, -5.5 * u, 12 * u, 5.5 * u, -5 * u); },
  },
});
})();
