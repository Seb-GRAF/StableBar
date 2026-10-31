/* Lighthouse Hill on a vector screen, for Phosphor (see the styles in scene.js): by night an amber vector monitor, one
   thin glowing beam for every line, the shapes black inside so they hide what's behind them, scanlines over it all
   and the light a radar's sweep; by day the same lines on a pen plotter, brown and amber ink on cream, hatched for
   shade. The screen comes on with the hour. */
(() => {
const { lerp, smooth, hex, rgba, angDiff, poly, ellipse, curve, dens, edges, beamPoly, waveScallops, hatGeom, head, joyAt, napEye, dot, shape, THEMES, TAU, DET, TEX } = Hill;

// what hides what's behind a shape: the screen, or the paper, at this hour (each frame, and for each island)
let screen = '#0A0703';
const glowAt = d => smooth(0.45, 0.9, d);

/* The beam (or the pen) at one width all along, round at both ends: the outline, for the caller to fill */
function line(c, pts) {
  const n = pts.length, h = 0.62 * Hill.PW;
  if (n < 2) return;
  const A = [], B = [];
  for (let i = 0; i < n; i++) {
    const a = pts[i > 0 ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : n - 1], l = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
    const tx = (b[0] - a[0]) / l * h, ty = (b[1] - a[1]) / l * h, [x, y] = pts[i];
    A.push([x + ty, y - tx]); B.push([x - ty, y + tx]);
  }
  const e0 = Math.atan2(pts[1][1] - pts[0][1], pts[1][0] - pts[0][0]), e1 = Math.atan2(pts[n - 1][1] - pts[n - 2][1], pts[n - 1][0] - pts[n - 2][0]);
  c.moveTo(A[0][0], A[0][1]);
  for (let i = 1; i < n; i++) c.lineTo(A[i][0], A[i][1]);
  c.arc(pts[n - 1][0], pts[n - 1][1], h, e1 - Math.PI / 2, e1 + Math.PI / 2);
  for (let i = n - 1; i >= 0; i--) c.lineTo(B[i][0], B[i][1]);
  c.arc(pts[0][0], pts[0][1], h, e0 + Math.PI / 2, e0 + Math.PI * 1.5);
  c.closePath();
}
/* A shape is only its outline: inside, the screen (or the paper) */
function blank(c, pts) { poly(c, pts); c.fillStyle = screen; c.fill(); }

/* Parallel strokes across the path on the canvas, `gap` apart and tilted by `a`, inside `box`: the plotter's shading,
   and the screen's */
function hatch(c, box, gap, a, col) {
  const [x0, y0, x1, y1] = box, cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, r = Math.hypot(x1 - x0, y1 - y0) / 2, ca = Math.cos(a), sa = Math.sin(a);
  c.save(); c.clip(); c.beginPath();
  for (let k = -r; k <= r; k += gap) { c.moveTo(cx - ca * r - sa * k, cy - sa * r + ca * k); c.lineTo(cx + ca * r - sa * k, cy + sa * r + ca * k); }
  c.strokeStyle = col; c.lineWidth = 0.9 * Hill.PW; c.stroke();
  c.restore();
}

/* The light: lines out from the lamp across its fan, brightest on the edge that leads as it turns; behind it, at
   night, the lines it drew a moment ago, fading as the phosphor lets them go */
const trails = new WeakMap();
function fan(s, c, alpha) {
  const g = s.g, P = s.P, { L, len, a0, a1 } = beamPoly(s), glow = glowAt(s.d), r0 = g.lh.er * 2.3, tr = trails.get(s.beam) || [];
  const lead = tr.length > 1 && angDiff(s.beam.a, tr[0].a) < 0 ? 0 : 1;
  const ray = a => { c.moveTo(L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0); c.lineTo(L.x + Math.cos(a) * len, L.y + Math.sin(a) * len); };
  // at night the lines glow: the same lines under them, wide and faint
  c.strokeStyle = rgba(P.beam); c.lineWidth = 6 * Hill.PW; c.globalAlpha = alpha * glow * 0.12;
  c.beginPath(); for (let i = 0; i <= 8; i++) ray(lerp(a0, a1, i / 8)); c.stroke();
  c.lineWidth = 1.1 * Hill.PW;
  for (const p of tr) {
    const k = 1 - (s.t - p.t) / 0.7;
    if (k <= 0 || p.a === s.beam.a) continue;
    c.globalAlpha = alpha * glow * k * k * 0.6;
    c.beginPath(); ray(p.a + (lead ? g.beamHalf : -g.beamHalf)); c.stroke();
  }
  for (let i = 0; i <= 8; i++) {
    const f = i / 8, w = lead ? f : 1 - f;
    c.globalAlpha = alpha * lerp(0.6, 0.12 + 0.88 * w ** 2.5, glow);
    c.beginPath(); ray(lerp(a0, a1, f)); c.stroke();
  }
  c.globalAlpha = alpha;
}

/* The hours: paper by day, a warmer paper at dusk, then the screen comes on */
const pal = Hill.stops([
  [0,    { sky: '#F6F1E6', sky2: '#D8C49C', sea: '#F6F1E6', sea2: '#A86400', foam: '#A86400', hill: '#F6F1E6', hill2: '#F6F1E6', ink: '#5C3A00', paper: '#A86400', beam: '#A86400', cloud: '#F6F1E6', far: '#D8C49C', glass: '#F6F1E6' }],
  [0.2,  { sky: '#F2EAD9', sky2: '#D2BB8F', sea: '#F2EAD9', sea2: '#A86400', foam: '#A86400', hill: '#F2EAD9', hill2: '#F2EAD9', ink: '#5C3A00', paper: '#A86400', beam: '#A86400', cloud: '#F2EAD9', far: '#D2BB8F', glass: '#F2EAD9' }],
  [0.42, { sky: '#E7D5B0', sky2: '#C4A06A', sea: '#E7D5B0', sea2: '#9A5800', foam: '#9A5800', hill: '#E7D5B0', hill2: '#E7D5B0', ink: '#563300', paper: '#9A5800', beam: '#9A5800', cloud: '#E7D5B0', far: '#C4A06A', glass: '#E7D5B0' }],
  [0.58, { sky: '#1A1208', sky2: '#4E340A', sea: '#1A1208', sea2: '#8A5E10', foam: '#D89500', hill: '#1A1208', hill2: '#1A1208', ink: '#E09A00', paper: '#E09A00', beam: '#FFBE3A', cloud: '#1A1208', far: '#4E340A', glass: '#1A1208' }],
  [1,    { sky: '#080603', sky2: '#4A3206', sea: '#080603', sea2: '#9A6A08', foam: '#FFB000', hill: '#080603', hill2: '#080603', ink: '#FFB000', paper: '#FFB000', beam: '#FFC24A', cloud: '#080603', far: '#4A3206', glass: '#080603' }],
]);

// the scanlines
let rows = null;

Hill.style('phosphor', {
  pal,
  // the colours the felt pen fills with are the pen's own ink here
  C: Object.fromEntries([...['wool', 'duck', 'pink', 'monster', 'chimney', 'door', 'skin', 'navy', 'wood', 'steel', 'kraft', 'kraftLit', 'kraftDark', 'tape', 'sprout'].map(k => [k, hex('#FFFFFF')]), ...['yolk', 'beak', 'lamp'].map(k => [k, hex('#FFB000')]), ['huts', Array(4).fill(hex('#FFFFFF'))]]),
  ribbon: line, print: blank, boil: 0, reg: [0, 0],
  // labels and doodles in capitals, as the vector games lettered them
  hand: '"Monaco", "Menlo", ui-monospace, monospace', caps: true,
  before(s) { screen = rgba(s.P.sky); },
  // the glow, baked into the cached layers and sprites: each blurred and laid back over itself in light
  cached(s, c) {
    const k = glowAt(s.d);
    if (k < 0.01) return;
    const b = 6 * c.getTransform().a;
    c.save(); c.setTransform(1, 0, 0, 1, 0, 0);
    c.filter = `blur(${b}px)`; c.globalCompositeOperation = 'lighter'; c.globalAlpha = k;
    c.drawImage(c.canvas, 0, 0);
    c.restore();
  },
  after(s, c) {
    const k = glowAt(s.d);
    if (k < 0.01) return;
    if (!rows) {
      const x = document.createElement('canvas').getContext('2d');
      x.canvas.width = 1; x.canvas.height = 3; x.fillStyle = '#000'; x.fillRect(0, 2, 1, 1);
      rows = x.createPattern(x.canvas, 'repeat');
    }
    c.globalAlpha = k * 0.35; c.fillStyle = rows; c.fillRect(0, 0, s.g.W, s.g.H); c.globalAlpha = 1;
  },
  draw: {
    land(base, s, c, w) { screen = rgba(s.P.sky); base(s, c, w); },
    sky(base, s, c) { c.fillStyle = screen; c.fillRect(0, 0, s.g.W, s.g.H); },
    // the lower sky's soft wave, a dim line, and the horizon
    band(base, s, c, bandTop) {
      const g = s.g, { W, u } = g, by = bandTop + 20 * u, top = [];
      for (let x = -30; x <= W + 30; x += 16 * u) top.push([x, by + Math.sin(x * 0.006 + 1) * 11 * u + Math.sin(x * 0.019 + 2) * 3 * u]);
      c.beginPath(); line(c, top); c.fillStyle = rgba(s.P.sky2); c.fill();
      c.beginPath(); line(c, [[-10, g.horizon], [W + 10, g.horizon]]); c.fillStyle = Hill.INK; c.fill();
    },
    // stars are points, the bigger ones brighter, twinkling
    stars(base, s, c) {
      const g = s.g, st = smooth(0.55, 0.9, s.d);
      if (st <= 0) return;
      c.fillStyle = rgba(s.P.beam);
      for (const p of g.stars) {
        const r = (0.5 + p.s * 0.6) * g.pw;
        c.globalAlpha = st * Math.min(1, p.s * 0.8) * (s.reduced ? 1 : 0.7 + 0.3 * Math.sin(s.t * 2 + p.p));
        c.fillRect(p.x - r, p.y - r, r * 2, r * 2);
      }
      c.globalAlpha = 1;
    },
    waves(base, s, c) { c.setLineDash([4 * s.g.pw, 3 * s.g.pw]); base(s, c); c.setLineDash([]); },
    beam(base, s, c) {
      const { L, len, a0, a1 } = beamPoly(s), pw = s.lampPower(), tr = trails.get(s.beam) || [];
      trails.set(s.beam, tr);
      if (tr.at(-1)?.t !== s.t) tr.push({ a: s.beam.a, t: s.t });
      while (s.t - tr[0].t > 0.7) tr.shift();
      if (len < 10 || pw < 0.02) return;
      fan(s, c, c.globalAlpha * (0.3 + 0.7 * pw));
      // the scallops it crosses light up, dashed like the rest of the sea
      c.save(); c.beginPath(); c.moveTo(L.x, L.y); c.arc(L.x, L.y, len, a0, a1); c.closePath(); c.clip();
      c.setTransform(s.dpr, 0, 0, s.dpr, 0, 0); c.setLineDash([4 * s.g.pw, 3 * s.g.pw]);
      c.strokeStyle = rgba(s.P.beam); waveScallops(s, c, true);
      c.restore();
    },
    hillLight(base, s, c) {
      const { len } = beamPoly(s);
      if (len < 10 || Math.sin(s.beam.a) < 0.08) return;
      c.save(); poly(c, s.g.hillClip); c.clip();
      fan(s, c, c.globalAlpha * 0.6 * s.lampPower());
      c.restore();
    },
    // the roof hatched, as the dark parts are
    cottage(base, s, c) {
      base(s, c);
      const g = s.g, k = g.cot, w = k.w, h = k.h, x0 = k.x - w / 2, y0 = k.base - h;
      const roof = [[x0 - w * 0.12, y0 + 1 * g.u], [x0 + w * 0.5, y0 - h * 0.78], [x0 + w * 1.12, y0 + 1 * g.u]];
      blank(c, roof);
      hatch(c, [x0 - w * 0.12, y0 - h * 0.78, x0 + w * 1.12, y0], 3 * g.pw, -0.6, Hill.INK);
      c.beginPath(); edges(c, roof, DET); c.fillStyle = Hill.INK; c.fill();
    },
    /* the tower: its outline, the stripes hatched in the theme's colour, the windows lit at night with a few lines */
    tower(base, s, c) {
      const g = s.g, u = g.u, T = g.lh, th = THEMES[g.theme || s.theme], night = smooth(0.45, 0.75, s.d), gap = 2.6 * g.pw;
      const half = k => lerp(T.wB, T.wT, k) / 2, yAt = k => T.base - T.h * k;
      const Lp = [], Rp = [];
      for (let i = 0; i <= 20; i++) { const k = i / 20; Lp.push([T.x - half(k), yAt(k)]); Rp.push([T.x + half(k), yAt(k)]); }
      blank(c, [...Lp, ...Rp.reverse()]);
      const bands = 6, sag = T.wB * 0.09;
      const edge = k => { const hw = half(k), out = []; for (let i = 0; i <= 12; i++) { const f = i / 12 * 2 - 1; out.push([T.x + f * hw, yAt(k) - sag * (1 - f * f)]); } return out; };
      c.beginPath();
      for (let j = 1; j < bands; j += 2) {
        const hi = j + 1 >= bands ? [[T.x + half(1), yAt(1)], [T.x - half(1), yAt(1)]] : edge((j + 1) / bands).reverse();
        [...edge(j / bands), ...hi].forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y));
        c.closePath();
      }
      hatch(c, [T.x - T.wB, T.top, T.x + T.wB, T.base], gap, 0, rgba(hex(th.stripes[0])));
      const win = k => { const y = yAt(k), w = T.wB * 0.11, h = T.er * 0.375; return [[T.x - w, y - h], [T.x + w, y - h], [T.x + w, y + h], [T.x - w, y + h]]; };
      const dw = T.wB * 0.32, dh = T.wB * 0.5, door = [[T.x - dw / 2, T.base], ...ellipse(T.x, T.base - dh + dw / 2, dw / 2, dw / 2, 10, Math.PI, TAU), [T.x + dw / 2, T.base]];
      for (const k of [0.25, 0.58]) blank(c, win(k));
      blank(c, door);
      c.beginPath();
      line(c, dens([[T.x - T.wB / 2, T.base], [T.x - T.wT / 2, T.top]], 6));
      line(c, dens([[T.x + T.wB / 2, T.base], [T.x + T.wT / 2, T.top]], 6));
      for (let j = 1; j < bands; j++) line(c, edge(j / bands));
      for (const k of [0.25, 0.58]) edges(c, win(k), TEX);
      line(c, door);
      c.fillStyle = Hill.INK; c.fill();
      if (night > 0.5) for (const k of [0.25, 0.58]) { poly(c, win(k)); hatch(c, [T.x - T.wB, yAt(k) - T.er, T.x + T.wB, yAt(k) + T.er], gap * 0.8, 0, rgba(s.P.beam)); }
      const gw = T.wT * 0.95, deck = [[T.x - gw, T.top + 1 * u], [T.x - gw * 1.05, T.top - T.gal * 0.42], [T.x + gw * 1.05, T.top - T.gal * 0.42], [T.x + gw, T.top + 1 * u]];
      blank(c, deck); c.beginPath(); edges(c, deck, DET); c.fillStyle = Hill.INK; c.fill();
    },
    // the eye's lid hides what it covers, and its iris is only its outline, the screen inside
    eye(base, s, c) { const P = s.P, { paper, beam } = P; P.paper = P.beam = Hill.C.iris = P.sky; base(s, c); P.paper = paper; P.beam = beam; },

    // the hat's white stripe left blank, the rest of the cone hatched in the theme's colour
    hat(base, s, c) {
      const P = s.P, paper = P.paper;
      P.paper = P.sky; base(s, c); P.paper = paper;
      const g = s.g, L = g.lamp, er = g.lh.er, { by, bw, bh, sway, tip, pr } = hatGeom(s), k = s.bobbleK(), sy = by - er * 1.55;
      poly(c, curve([[L.x - bw * 0.92, by - bh * 0.6], [L.x - bw * 0.5, by - er * 1.9], [L.x + er * 0.1 + sway * er, by - er * 2.85], tip, [L.x + er * 0.65 + sway * er * 1.4, by - er * 2.2], [L.x + bw * 0.9, by - bh * 0.6]], 3));
      c.save(); c.clip();
      c.beginPath(); c.rect(L.x - bw * 3, tip[1] - pr * 3, bw * 7, by - tip[1] + pr * 3);
      c.moveTo(L.x - bw * 2, sy + er * 0.25); c.quadraticCurveTo(L.x, sy - er * 0.05, L.x + bw * 2, sy + er * 0.2); c.lineTo(L.x + bw * 2, sy - er * 0.25); c.quadraticCurveTo(L.x, sy - er * 0.55, L.x - bw * 2, sy - er * 0.25); c.closePath();
      if (k > 0.02) { c.moveTo(tip[0] + pr * k, tip[1] - pr * 0.6 * k); c.arc(tip[0], tip[1] - pr * 0.6 * k, pr * k, 0, TAU); }
      c.clip('evenodd');
      c.beginPath(); for (let y = tip[1] - pr * 2; y < by; y += 2.6 * g.pw) { c.moveTo(L.x - bw * 3, y); c.lineTo(L.x + bw * 4, y); }
      c.strokeStyle = rgba(hex(THEMES[g.theme || s.theme].hat)); c.lineWidth = 0.9 * Hill.PW; c.stroke();
      c.restore();
    },
    // its black face and ear drawn round, as everything is
    sheep(base, c, u, wool, o, t) {
      const fall = o.state === 'fall' || o.state === 'leap', step = Math.hypot(o.vx, o.vd || 0) > 2 ? Math.sin(t * 14 + o.seed) * 2 * u : 0;
      c.beginPath();
      [-8, -3, 5, 10].forEach((lx, i) => line(c, [[lx * u, -10 * u], [lx * u + (fall ? 3 * u : (i % 2 ? step : -step)), 0]]));
      c.fillStyle = Hill.INK; c.fill();
      const body = [];
      for (let i = 0; i < 40; i++) { const a = i / 40 * TAU, r = 1 + 0.13 * Math.abs(Math.sin(a * 5 + o.seed)); body.push([Math.cos(a) * 14 * u * r, -16 * u + Math.sin(a) * 9.5 * u * r]); }
      shape(c, body, wool);
      const ja = joyAt(o, t);
      c.save(); c.translate(-14 * u, -19 * u); c.rotate(-0.45 + (ja >= 0 ? Math.sin(ja * 24) * 0.6 * (1 - ja / 1.3) : 0));
      shape(c, ellipse(-2.4 * u, 0, 3 * u, 2.2 * u, 12), wool);
      c.restore();
      head(c, u, o, t, 15, -19, [19, -7.5], 1.05, chew => {
        shape(c, ellipse(11.5 * u, -23.5 * u, 3.6 * u, 1.6 * u, 10, 0, TAU, 0.5 + chew * 0.25), wool);
        shape(c, ellipse(15 * u, -19 * u, 5 * u, 6.4 * u, 18, 0, TAU, -0.35), wool);
        c.beginPath(); line(c, ellipse(13.5 * u, -24 * u, 5 * u, 2.6 * u, 10, Math.PI * 1.05, Math.PI * 1.95)); c.fillStyle = Hill.INK; c.fill();
        if (ja >= 0) { c.beginPath(); line(c, ellipse(16.6 * u, -19.6 * u, 1.7 * u, 1.3 * u, 8, Math.PI * 1.1, Math.PI * 1.9)); c.fillStyle = Hill.INK; c.fill(); }
        else if (Hill.NAP) napEye(c, 16.6 * u, -20.5 * u, 1.5 * u, Hill.INK);
        else dot(c, 16.8 * u, -20.5 * u, 1.1 * u, Hill.INK);
      });
    },
    // its patches hatched, and its ear drawn round
    cow(base, c, u, white, P, o, t) {
      const INK = Hill.INK, step = Math.hypot(o.vx, o.vd || 0) > 2 ? Math.sin(t * 9 + o.seed) * 2 * u : 0;
      c.beginPath();
      [-12, -7, 8, 13].forEach((lx, i) => line(c, [[lx * u, -11 * u], [lx * u + (i % 2 ? step : -step), 0]]));
      c.fillStyle = INK; c.fill();
      const ja = joyAt(o, t), wag = ja >= 0 ? Math.sin(ja * 16) * 0.5 * (1 - ja / 1.3) : Math.sin(t * 1.3 + o.seed) * 0.12;
      c.save(); c.translate(-17 * u, -20 * u); c.rotate(wag); c.translate(17 * u, 20 * u);
      c.beginPath(); line(c, [[-17 * u, -20 * u], [-21 * u, -14 * u], [-20 * u, -7 * u]]); c.fill();
      dot(c, -20 * u, -6 * u, 2 * u, INK);
      c.restore();
      const body = curve([[-17 * u, -22 * u], [-6 * u, -26.5 * u], [10 * u, -25.5 * u], [17 * u, -20 * u], [15 * u, -11 * u], [0, -10 * u], [-16 * u, -11 * u], [-18.5 * u, -16 * u]], 3, true);
      blank(c, body);
      c.save(); c.clip();
      const R = Hill.rng(o.seed + 3);
      c.beginPath();
      for (let i = 0; i < 3; i++) ellipse((-11 + i * 9 + R() * 4) * u, (-21 + R() * 8) * u, (3.5 + R() * 3) * u, (2.6 + R() * 2) * u, 12, 0, TAU, R()).forEach(([x, y], j) => j ? c.lineTo(x, y) : c.moveTo(x, y));
      hatch(c, [-20 * u, -30 * u, 20 * u, -8 * u], 1.8 * Hill.PW, -0.9, INK);
      c.restore();
      c.beginPath(); Hill.loop(c, body); c.fillStyle = INK; c.fill();
      head(c, u, o, t, 15, -24, [19, -13], 0.95, chew => {
        shape(c, ellipse(13.6 * u, -27.5 * u, 3 * u, 1.5 * u, 10, 0, TAU, 0.4 + chew * 0.2), white);
        shape(c, curve([[15 * u, -29 * u], [21 * u, -31 * u], [24.5 * u, -26 * u], [24.5 * u, -20 * u], [18 * u, -19.5 * u], [15 * u, -24 * u]], 2, true), white);
        const my = (-21 + Math.max(0, chew) * 0.7) * u;
        shape(c, ellipse(23 * u, my, 4 * u, 3 * u, 14), white);
        dot(c, 22 * u, my, 0.7 * u, INK); dot(c, 24.6 * u, my - 0.2 * u, 0.7 * u, INK);
        if (ja >= 0) { c.beginPath(); line(c, ellipse(20.2 * u, -25.8 * u, 1.5 * u, 1.1 * u, 8, Math.PI * 1.1, Math.PI * 1.9)); c.fillStyle = INK; c.fill(); }
        else if (Hill.NAP) napEye(c, 20.2 * u, -26.6 * u, 1.3 * u, INK);
        else dot(c, 20.2 * u, -26.6 * u, 1.05 * u, INK);
        c.beginPath(); line(c, [[16.5 * u, -29.5 * u], [15 * u, -33.5 * u], [16.5 * u, -36 * u]]); line(c, [[21 * u, -31 * u], [22.5 * u, -34.5 * u], [21.5 * u, -37 * u]]); c.fillStyle = INK; c.fill();
      });
    },
    // the sheep at its desk, its face drawn round
    desk(base, s, c, p) {
      const g = s.g, sc = Hill.pop(p) * (g.portrait ? 1.75 : 2.1), u = g.u * sc, INK = Hill.INK, { x, y } = Hill.deskSpot(s);
      if (sc < 0.05) return;
      const typing = s.reduced ? 0 : s.t * 11, bob = s.reduced ? 0 : Math.sin(s.t * 2.4) * 0.6 * u;
      c.save(); c.translate(x, y);
      const body = [];
      for (let i = 0; i < 36; i++) { const a = i / 36 * TAU, r = 1 + 0.12 * Math.abs(Math.sin(a * 5)); body.push([Math.cos(a) * 15 * u * r, -27 * u + Math.sin(a) * 12 * u * r]); }
      shape(c, body);
      for (const sx of [-1, 1]) shape(c, ellipse(sx * 8.5 * u, -40 * u + bob, 4.4 * u, 1.9 * u, 12, 0, TAU, sx * 0.35));
      shape(c, ellipse(0, -36 * u + bob, 6 * u, 7.5 * u, 20));
      c.beginPath(); line(c, ellipse(0, -42 * u + bob, 6.5 * u, 3.6 * u, 12, Math.PI, TAU)); c.fillStyle = INK; c.fill();
      for (const sx of [-1, 1]) dot(c, sx * 2.6 * u, -35.8 * u + bob, 0.9 * u, INK);
      const top = [[-24 * u, -14 * u], [24 * u, -14 * u], [24 * u, -10.5 * u], [-24 * u, -10.5 * u]];
      blank(c, top);
      c.beginPath(); edges(c, top); line(c, [[-20 * u, -10.5 * u], [-21 * u, 0]]); line(c, [[20 * u, -10.5 * u], [21 * u, 0]]); c.fillStyle = INK; c.fill();
      const lid = [[-11 * u, -14.5 * u], [-12 * u, -29 * u], [12 * u, -29 * u], [11 * u, -14.5 * u]];
      shape(c, lid);
      shape(c, [[-1.6 * u, -18 * u], [-1.1 * u, -25 * u], [1.1 * u, -25 * u], [1.6 * u, -18 * u]]);
      c.beginPath();
      for (const sx of [-1, 1]) {
        const up = s.reduced ? 0 : Math.max(0, Math.sin(typing + (sx > 0 ? Math.PI : 0))) * 2.4 * u;
        line(c, [[sx * 10 * u, -22 * u], [sx * 13 * u, -17 * u - up], [sx * 11 * u, -15.5 * u - up]]);
      }
      c.fillStyle = INK; c.fill();
      if (!s.reduced) {
        const ph = (s.t * 1.3) % 1;
        Hill.label(c, ph < 0.5 ? 'tak' : 'tak tak', 15 * u, -34 * u - ph * 6 * u, 8 * u + 2, rgba(s.P.ink, 1 - ph), 'left', -0.15);
      }
      const mug = [[16 * u, -14 * u], [16.5 * u, -20 * u], [21 * u, -20 * u], [20.5 * u, -14 * u]];
      blank(c, mug); c.beginPath(); edges(c, mug); line(c, ellipse(21.5 * u, -17 * u, 2 * u, 2 * u, 8, -1.2, 1.2)); c.fillStyle = INK; c.fill();
      c.restore();
    },
    // the other pyjamas drying, their stripes a line each
    washing(base, s, c, p) {
      const g = s.g, u = g.u, T = g.lh, sc = Hill.pop(p), INK = Hill.INK;
      if (sc < 0.05) return;
      const px = g.portrait ? g.W * 0.4 : g.W * 0.615, pry = s.ridgeY(px) ?? T.base;
      const top = [px, pry - (g.portrait ? 48 : 92) * u * sc], end = [T.x - lerp(T.wB, T.wT, 0.3) / 2, T.base - T.h * 0.3], sag = 16 * u, rope = [];
      for (let i = 0; i <= 20; i++) { const f = i / 20; rope.push([lerp(top[0], end[0], f), lerp(top[1], end[1], f) + Math.sin(f * Math.PI) * sag]); }
      c.beginPath();
      line(c, [[px, pry + 3 * u], top]);
      line(c, [[px - 6 * u, top[1] + 4 * u], [px, top[1] - 1 * u], [px + 6 * u, top[1] + 4 * u]]);
      line(c, rope);
      c.fillStyle = INK; c.fill();
      const others = Object.keys(THEMES).filter(k => k !== s.theme);
      const wind = s.reduced ? 0.1 : s.windTotal;
      others.forEach((id, i) => {
        const f = (i + 0.7) / (others.length + 0.4), ax = lerp(top[0], end[0], f), ay = lerp(top[1], end[1], f) + Math.sin(f * Math.PI) * sag;
        const k = sc * (g.portrait ? 1 : 1.45), w = 13 * u * k, h = 14 * u * k, sw = (s.reduced ? 0 : Math.sin(s.t * 2.2 + i) * 0.08) + wind * 0.12;
        c.save(); c.translate(ax, ay); c.rotate(sw);
        const shirt = [[-w / 2, 0], [-w * 0.85, h * 0.25], [-w * 0.62, h * 0.4], [-w * 0.42, h * 0.3], [-w * 0.42, h], [w * 0.42, h], [w * 0.42, h * 0.3], [w * 0.62, h * 0.4], [w * 0.85, h * 0.25], [w / 2, 0]];
        blank(c, shirt);
        c.save(); c.clip(); c.beginPath();
        for (let j = 0; j < 3; j++) line(c, [[-w, h * (0.25 + j * 0.3)], [w, h * (0.25 + j * 0.3)]]);
        c.fillStyle = rgba(s.P.paper); c.fill(); c.restore();
        c.beginPath(); edges(c, shirt); line(c, [[-w * 0.2, -2 * u], [-w * 0.2, 3 * u]]); line(c, [[w * 0.2, -2 * u], [w * 0.2, 3 * u]]); c.fillStyle = INK; c.fill();
        c.restore();
      });
    },
    // the huts: their stripes and roofs hatched, the open one's doorway full of lamplight in lines
    huts(base, s, c, p) {
      const g = s.g, spots = Hill.hutSpots(s), INK = Hill.INK, k0 = Hill.pop(p) * (g.portrait ? 1.3 : 1.75);
      if (k0 > 0.05) {
        const u = g.u * k0, a = spots[0], b = spots[3], walk = [[a.x - 30 * u, a.y], [b.x + 30 * u, b.y], [b.x + 30 * u, b.y + 4 * u], [a.x - 30 * u, a.y + 4 * u]];
        blank(c, walk);
        c.beginPath(); edges(c, walk);
        for (let x = a.x - 22 * u; x < b.x + 30 * u; x += 9 * u) { const y = a.y + lerp(0, b.y - a.y, (x - a.x) / (b.x - a.x)); line(c, [[x, y + 0.5 * u], [x, y + 3.5 * u]]); }
        c.fillStyle = INK; c.fill();
      }
      spots.forEach((q, i) => {
        const sc = Hill.pop(Hill.clamp(p * 1.6 - i * 0.15)) * (g.portrait ? 1.3 : 1.75), u = g.u * sc, gap = 2.4 * g.pw;
        if (sc < 0.05) return;
        const on = s.ws === i + 1, w = 26 * u, h = 27 * u, x0 = q.x - w / 2, y0 = q.y - h;
        const body = [[x0, q.y], [x0, y0], [x0 + w, y0], [x0 + w, q.y]], roof = [[x0 - 4 * u, y0 + 1 * u], [q.x, y0 - 14 * u], [x0 + w + 4 * u, y0 + 1 * u]];
        const dw = w * 0.5, dh = h * 0.74, dx = q.x - dw / 2, dy = q.y - dh, door = [[dx, q.y], [dx, dy], [dx + dw, dy], [dx + dw, q.y]];
        blank(c, body);
        c.beginPath(); for (let j = 0; j < 4; j++) c.rect(x0 + j * w / 4, y0, w / 8, h);
        hatch(c, [x0, y0, x0 + w, q.y], gap, Math.PI / 2, INK);
        blank(c, roof); hatch(c, [x0 - 4 * u, y0 - 14 * u, x0 + w + 4 * u, y0], gap, -0.6, INK);
        blank(c, door);
        let num = [q.x, dy + dh * 0.45, 1];
        c.beginPath(); edges(c, roof); edges(c, body, DET, 0, false); edges(c, door, TEX, 0, false);
        line(c, ellipse(q.x, y0 - 5 * u, 3.4 * u, 3.4 * u, 12, 0, TAU * 1.05));
        if (on) {
          const leaf = [[dx + dw, q.y], [dx + dw, dy], [dx + dw * 1.55, dy + 2.5 * u], [dx + dw * 1.55, q.y - 1.2 * u]];
          edges(c, leaf);
          num = [dx + dw * 1.29, dy + dh * 0.45, 0.85];
        }
        c.fillStyle = INK; c.fill();
        if (on) { poly(c, door); hatch(c, [dx, dy, dx + dw, q.y], gap * 0.8, 0, rgba(s.P.beam)); dot(c, q.x, y0 - 5 * u, 2 * u, rgba(s.P.beam)); }
        Hill.label(c, String(i + 1), num[0] + 0.5 * u, num[1], 11 * u * num[2] + 2, INK, 'center', 0);
      });
    },
    // install: the cottage door open on the lamp, its light on the grass in lines
    doorway(base, s, c, p) {
      const g = s.g, u = g.u, k = g.cot, d = k.door, INK = Hill.INK, beam = rgba(s.P.beam);
      if (!d) return;
      c.globalAlpha = Hill.clamp(p * 1.4);
      c.beginPath();
      for (let i = 0; i <= 6; i++) { const f = i / 6, x = lerp(d.x, d.x + d.w, f); line(c, [[x, k.base + 3 * u], [lerp(d.x - 30 * u, d.x + d.w + 40 * u, f), k.base + 32 * u]]); }
      c.fillStyle = beam; c.fill();
      poly(c, [[d.x, k.base], [d.x, d.y], [d.x + d.w, d.y], [d.x + d.w, k.base]]);
      hatch(c, [d.x, d.y, d.x + d.w, k.base], 2 * g.pw, 0, beam);
      const door = [[d.x + d.w, k.base], [d.x + d.w, d.y], [d.x + d.w * 1.55, d.y + 2 * u], [d.x + d.w * 1.55, k.base - 1 * u]];
      blank(c, door); c.beginPath(); edges(c, door); c.fillStyle = INK; c.fill();
      s.style.draw.keeper(s, c, d.x + d.w * 0.5, k.base, g.portrait ? 1.05 : 1.45, 'wave', false, 0);
      c.globalAlpha = 1;
    },
  },
});
})();
