/* Lighthouse Hill in a magazine cartoon, for Notch (see the styles in scene.js): a brush pen held still, no colour,
   grey washes on white paper that pool at their edges and sit off the line, and a caption in Caslon italic under the
   drawing, one per section */
(() => {
const { clamp, lerp, smooth, easeOut, noise, hash, rng, mix, rgba, poly, dens, SIL, TEX } = Hill;
const PAPER = [251, 248, 241], INK = [24, 22, 20], paper = `rgb(${PAPER})`, ink = `rgb(${INK})`;
const lum = c => (c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114) / 255;
const CASLON = '"Libre Caslon Text", Georgia, serif';
document.fonts.add(new FontFace('Libre Caslon Text', 'url(fonts/libre-caslon-text-italic.woff2)', { style: 'italic', weight: '400' }));

/* The wash: ink thinned with water, laid on unevenly, a little more of it here and less there. One tile, made once:
   the ink's colour, more or less opaque in soft blots. The sea's is the same, drawn out sideways in streaks. */
const tile = document.createElement('canvas');
tile.width = tile.height = 512;
{
  const x = tile.getContext('2d'), R = rng(5);
  x.fillStyle = `rgba(${INK},0.72)`; x.fillRect(0, 0, 512, 512);
  for (let i = 0; i < 140; i++) {
    const px = R() * 512, py = R() * 512, r = 14 + R() ** 2 * 130, a = 0.1 + R() * 0.16;
    x.globalCompositeOperation = R() < 0.5 ? 'source-over' : 'destination-out';
    for (const ox of [-512, 0, 512]) for (const oy of [-512, 0, 512]) {
      const gr = x.createRadialGradient(px + ox, py + oy, 0, px + ox, py + oy, r);
      gr.addColorStop(0, `rgba(${INK},${a})`); gr.addColorStop(1, `rgba(${INK},0)`);
      x.fillStyle = gr; x.fillRect(px + ox - r, py + oy - r, r * 2, r * 2);
    }
  }
}
const WASH = tile.getContext('2d').createPattern(tile, 'repeat'), SEA = tile.getContext('2d').createPattern(tile, 'repeat');
WASH.setTransform(new DOMMatrix([1.5, 0, 0, 0.8, 0, 0])); SEA.setTransform(new DOMMatrix([3.2, 0, 0, 0.45, 0, 0]));

/* A shape on the paper: white paper up to the line, so it hides what's behind it; then, unless it's white, a wash
   as dark as its colour, off the line, darker where it dried at its edges. The near-blacks are filled in solid. */
function wash(c, pts, col, pat = WASH) {
  const k = lum(col), ga = c.globalAlpha;
  poly(c, pts); c.fillStyle = paper; c.fill();
  if (k > 0.92) return;
  if (k < 0.2) { c.fillStyle = rgba(col); c.fill(); return; }
  c.save();
  poly(c, pts, true, Hill.REGX, Hill.REGY);
  c.globalAlpha = ga * Math.min(1, (1 - k) / 0.72); c.fillStyle = pat; c.fill();
  c.globalAlpha = ga * (1 - k) * 0.45; c.strokeStyle = ink; c.lineWidth = 1.5 * Hill.PW; c.stroke();
  c.restore();
}

/* The brush pen: thick where the stroke runs across the nib and thin along it, swelling from a fine start to a fine
   end, steady. The outlines come out heavier than the felt pen's, the hatching and small marks lighter. */
const NIB = -0.7;
function brush(c, pts, w, sd = 0, o = {}) {
  const n = pts.length;
  if (n < 2) return;
  const PW = Hill.PW, len = [0];
  for (let i = 1; i < n; i++) len.push(len[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]));
  const total = len[n - 1] || 1, tin = Math.min(total * 0.45, (o.tin ?? 9) * PW * 1.6), tout = Math.min(total * 0.5, (o.tout ?? 15) * PW * 1.6);
  const w0 = (o.w0 ?? 0.4) * 0.5, w1 = (o.w1 ?? 0.22) * 0.5, hw0 = w * PW * 0.5 * (w >= SIL * 0.8 ? 1.2 : w <= TEX * 1.2 ? 0.6 : 1);
  const L = [], R = [];
  let sx, sy, ex, ey;
  for (let i = 0; i < n; i++) {
    const a = pts[i > 0 ? i - 1 : 0], b = pts[i < n - 1 ? i + 1 : n - 1];
    const tl = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1, tx = (b[0] - a[0]) / tl, ty = (b[1] - a[1]) / tl;
    const s = len[i], off = (o.amp ?? 0.85) * PW * 0.3 * noise(s / 110 + sd * 3.71);
    const x = pts[i][0] - ty * off, y = pts[i][1] + tx * off;
    const p = lerp(w0, 1, easeOut(clamp(s / tin))) * lerp(w1, 1, easeOut(clamp((total - s) / tout)));
    const hw = hw0 * p * (0.4 + 0.8 * Math.abs(ty * Math.cos(NIB) - tx * Math.sin(NIB)));
    L.push([x - ty * hw, y + tx * hw]); R.push([x + ty * hw, y - tx * hw]);
    if (i === 0) { sx = x - tx * hw; sy = y - ty * hw; }
    if (i === n - 1) { ex = x + tx * hw; ey = y + ty * hw; }
  }
  c.moveTo(sx, sy);
  for (const [x, y] of L) c.lineTo(x, y);
  c.lineTo(ex, ey);
  for (let i = n - 1; i >= 0; i--) c.lineTo(R[i][0], R[i][1]);
  c.closePath();
}

/* The captions, one a section, said by someone in it */
const CAPTIONS = {
  hero: '“He’s very stable. He hasn’t moved in forty years.”',
  edit: '“A little to the left. No, my left.”',
  themes: '“He changes every evening. It’s always stripes.”',
  widgets: '“It shows how full the disk is. I find it calming.”',
  tiling: '“We each have our own workspace now. It’s done wonders for the marriage.”',
  install: '“Come in. I’ve only just set it up, so don’t touch anything.”',
};
/* Where the caption goes: under the hill, on the white (on a phone, under the sky, left of the lighthouse, above
   where the notes begin), in lines `lh` apart up from `foot`, at most three */
function captionAt(g) {
  const T = g.lh, size = Math.max(15, 21 * g.u), lh = size * 1.32;
  const x0 = g.portrait ? 0 : Math.max(g.note.x1, g.ridge[0][0]), x1 = g.portrait ? T.x - T.wB * 0.55 : g.W;
  const foot = g.portrait ? g.note.y0 - 10 : g.H - 26 * g.u;
  return { size, lh, x0, x1, foot, top: foot - lh * (g.portrait ? 3 : 2) };
}
// the washes lifted off there, the paper coming back over a short way above it
function lift(c, g, a) {
  const z = captionAt(g), yA = z.top - 50 * g.u, yB = g.portrait ? z.foot + 40 : g.H, at = y => (y - yA) / (yB - yA);
  const gr = c.createLinearGradient(0, yA, 0, yB);
  gr.addColorStop(0, `rgba(${PAPER},0)`); gr.addColorStop(at(z.top), paper); gr.addColorStop(at(z.foot + 6), paper); gr.addColorStop(1, `rgba(${PAPER},${g.portrait ? 0 : 1})`);
  c.globalAlpha = a; c.fillStyle = gr; c.fillRect(0, yA, g.W, yB - yA); c.globalAlpha = 1;
}
Hill.style('notch', {
  // white paper by day and at night, the sky washed darker with the hour, the light left as paper
  pal: Hill.stops([
    [0,    { sky: '#FFFFFF', sky2: '#FFFFFF', sea: '#D2D2D2', sea2: '#111111', foam: '#FFFFFF', hill: '#E4E4E4', hill2: '#C2C2C2', ink: '#000000', paper: '#FFFFFF', beam: '#FFFFFF', cloud: '#FFFFFF', far: '#DDDDDD', glass: '#C8C8C8' }],
    [0.2,  { sky: '#F2F2F2', sky2: '#FFFFFF', sea: '#CACACA', sea2: '#111111', foam: '#FFFFFF', hill: '#DDDDDD', hill2: '#BCBCBC', ink: '#000000', paper: '#FFFFFF', beam: '#FFFFFF', cloud: '#FFFFFF', far: '#D6D6D6', glass: '#C8C8C8' }],
    [0.44, { sky: '#D4D4D4', sky2: '#EAEAEA', sea: '#B4B4B4', sea2: '#111111', foam: '#FFFFFF', hill: '#CDCDCD', hill2: '#ADADAD', ink: '#000000', paper: '#FFFFFF', beam: '#FFFFFF', cloud: '#F4F4F4', far: '#C4C4C4', glass: '#C0C0C0' }],
    [0.7,  { sky: '#A4A4A4', sky2: '#C2C2C2', sea: '#929292', sea2: '#111111', foam: '#F4F4F4', hill: '#B2B2B2', hill2: '#999999', ink: '#000000', paper: '#FFFFFF', beam: '#FFFFFF', cloud: '#D8D8D8', far: '#A0A0A0', glass: '#FFFFFF' }],
    [1,    { sky: '#7E7E7E', sky2: '#9C9C9C', sea: '#727272', sea2: '#111111', foam: '#E8E8E8', hill: '#A0A0A0', hill2: '#878787', ink: '#000000', paper: '#FFFFFF', beam: '#FFFFFF', cloud: '#C4C4C4', far: '#868686', glass: '#FFFFFF' }],
  ]),
  // every colour becomes a grey between the ink and the paper, as light as it was
  tint: c => mix(INK, PAPER, lum(c)),
  ribbon: brush, print: wash, boil: 0, reg: [2.2, 1.7],
  // the section's caption, over everything; out at sea and under the page's title card there's none
  after(s, c) {
    const g = s.back, z = captionAt(g), out = (1 - smooth(0, 0.15, s.dive)) * s.labelsK();
    if (out <= 0.01) return;
    c.font = `italic 400 ${z.size}px ${CASLON}`; c.textAlign = 'center'; c.textBaseline = 'alphabetic'; c.fillStyle = ink;
    for (const k of Hill.states) {
      if (s.pres[k] < 0.01) continue;
      // in as few lines as fit, about as long as each other
      const text = CAPTIONS[k], all = c.measureText(text).width, n = Math.ceil(all / (z.x1 - z.x0 - 48 * g.u)), ls = [''];
      for (const w of text.split(' ')) {
        const line = ls.at(-1);
        if (line && ls.length < n && c.measureText(line + ' ' + w).width > all / n * 1.1) ls.push(w);
        else ls[ls.length - 1] = line ? line + ' ' + w : w;
      }
      c.globalAlpha = out * s.pres[k];
      ls.forEach((l, i) => c.fillText(l, (z.x0 + z.x1) / 2, z.foot - (ls.length - 1 - i) * z.lh));
    }
    c.globalAlpha = 1;
  },
  draw: {
    // the paper, the sky's wash and the sea's, streaked sideways
    sky(base, s, c) {
      const g = s.g, { W, H } = g;
      wash(c, [[-20, -20], [W + 20, -20], [W + 20, g.horizon + 2], [-20, g.horizon + 2]], s.P.sky);
      wash(c, [[-20, g.horizon], [W + 20, g.horizon], [W + 20, H + 20], [-20, H + 20]], s.P.sea, SEA);
    },
    // the lower sky, washed lighter, and the horizon in one stroke
    band(base, s, c, bandTop) {
      const g = s.g, { W, u } = g, by = bandTop + 20 * u, band = [];
      for (let x = -30; x <= W + 30; x += 16 * u) band.push([x, by + Math.sin(x * 0.006 + 1) * 11 * u + Math.sin(x * 0.019 + 2) * 3 * u]);
      band.push([W + 30, g.horizon + 4], [-30, g.horizon + 4]);
      // (on the line, with no white between it and the sky's)
      poly(c, band); c.fillStyle = paper; c.fill();
      c.globalAlpha = Math.min(1, (1 - lum(s.P.sky2)) / 0.72); c.fillStyle = WASH; c.fill(); c.globalAlpha = 1;
      c.beginPath(); brush(c, dens([[-10, g.horizon], [W + 10, g.horizon]], 8), Hill.DET, 2, { tin: 40, tout: 40, w0: 1, w1: 1 }); c.fillStyle = Hill.INK; c.fill();
    },
    // a few stars, left white
    stars(base, s, c) {
      const g = s.g, u = g.u, st = smooth(0.55, 0.9, s.d);
      if (st <= 0) return;
      c.beginPath();
      for (const p of g.stars) {
        if (p.s < 1.15) continue;
        const r = p.s * 2.4 * u;
        for (const a of [p.p, p.p + Math.PI / 2]) brush(c, [[p.x - Math.cos(a) * r, p.y - Math.sin(a) * r], [p.x + Math.cos(a) * r, p.y + Math.sin(a) * r]], 1.7, 0, { tin: 1, tout: 1, w0: 1, w1: 1 });
      }
      c.fillStyle = rgba(s.P.beam, st); c.fill();
    },
    // the sea: a few strokes of the pen across the water, longer and further apart as they come closer, each the
    // brush's sliver: pointed, thin where it lands, thinnest where it lifts. Far off, where they're a hair thick, a
    // plain dash, all of them in one path of rectangles
    waves(base, s, c) {
      const g = s.g, { W, H, u } = g, hz = g.horizon, sea = H - hz, mid = W / 2, go = s.dive * Hill.DIVE_GAP / Hill.SHORE, ROW = 0.11, span = 150 * u, PW = Hill.PW;
      const near = new Path2D(), far = new Path2D();
      for (let k = Math.ceil((1 + go) / ROW); ; k++) {
        const rel = 1 / (k * ROW - go);
        if (rel < 0.035) break;
        const y = hz + sea * rel, keep = 0.75 * rel ** 1.5, q = k % 128, w = Hill.DET * Math.max(0.5, rel), hw = w * PW * (w <= TEX * 1.2 ? 0.28 : 0.46), dy = 0.6 * u * rel;
        for (let j = Math.floor(-mid / rel / span) - 1; j * span * rel < mid; j++) {
          if (hash(q * 31.7 + j * 7.3) > keep) continue;
          const x = mid + (j + hash(j * 3.1 + q)) * span * rel, l = Math.max(4, (30 + 60 * hash(q + j * 1.7)) * u * rel);
          if (rel < 0.25) { far.rect(x, y + dy / 2 - hw * 0.7, l, hw * 1.4); continue; }
          const a = Math.min(l * 0.45, 9.6 * PW), b = l - Math.min(l * 0.5, 19.2 * PW), ya = y + dy * a / l, yb = y + dy * b / l;
          near.moveTo(x - hw * 0.3, y); near.lineTo(x, y - hw * 0.3); near.lineTo(x + a, ya - hw); near.lineTo(x + b, yb - hw); near.lineTo(x + l, y + dy - hw * 0.1);
          near.lineTo(x + l + hw * 0.1, y + dy); near.lineTo(x + l, y + dy + hw * 0.1); near.lineTo(x + b, yb + hw); near.lineTo(x + a, ya + hw); near.lineTo(x, y + hw * 0.3);
          near.closePath();
        }
      }
      c.fillStyle = Hill.INK; c.fill(near); c.fill(far);
      // and none of it where the caption goes, while there is one
      const out = 1 - smooth(0, 0.15, s.dive);
      if (out > 0) lift(c, s.back, out);
    },
    // the page's hill, its washes lifted off under the caption
    hill(base, s, c) {
      base(s, c);
      if (s.g.isle || s.g.portrait) return;
      c.save(); poly(c, s.g.hillClip); c.clip(); lift(c, s.g, 1); c.restore();
    },
    // the light: two strokes, and between them paper the wash was kept off
    beam(base, s, c) {
      const g = s.g, pw = s.lampPower(), ga = c.globalAlpha, { L, len, a0, a1 } = Hill.beamPoly(s);
      if (len < 10 || pw < 0.02) return;
      const fan = [[L.x, L.y]];
      for (let i = 0; i <= 12; i++) { const a = lerp(a0, a1, i / 12); fan.push([L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]); }
      poly(c, fan); c.fillStyle = paper; c.globalAlpha = ga * 0.95 * pw; c.fill();
      const r0 = g.lh.er * 2.3;
      c.beginPath();
      for (const [a, sd] of [[a0, 13], [a1, 17]]) brush(c, dens([[L.x + Math.cos(a) * r0, L.y + Math.sin(a) * r0], [L.x + Math.cos(a) * len, L.y + Math.sin(a) * len]], 9), Hill.DET, sd, { tin: 20, tout: 60, w0: 0.4, w1: 0.4 });
      c.globalAlpha = ga * (0.3 + 0.7 * pw); c.fillStyle = Hill.INK; c.fill(); c.globalAlpha = 1;
    },
    // where the light lands on the hill, the wash lifted off it
    hillLight(base, s, c) {
      const { L, len, a0, a1 } = Hill.beamPoly(s);
      if (len < 10 || Math.sin(s.beam.a) < 0.08) return;
      c.save(); poly(c, s.g.hillClip); c.clip();
      c.beginPath(); c.moveTo(L.x, L.y);
      for (let i = 0; i <= 12; i++) { const a = lerp(a0, a1, i / 12); c.lineTo(L.x + Math.cos(a) * len, L.y + Math.sin(a) * len); }
      c.closePath(); c.globalAlpha *= (0.4 + 0.5 * smooth(0.3, 0.8, s.d)) * s.lampPower(); c.fillStyle = paper; c.fill();
      c.restore();
    },
    // grass along the ridge near the lighthouse and past it; down the long slope a cartoonist leaves it out
    tufts(base, s, c) {
      const T = s.g.lh;
      c.save(); c.beginPath(); c.rect(T.x - T.h * 0.6, 0, s.g.W, s.g.H); c.clip(); base(s, c); c.restore();
    },
    // the arrowed labels give way to the captions
    labels() {},
    // the sounds in small capitals, lettered by hand; the grazers chew without comment
    doodles(base, s, c) {
      const u = s.g.u;
      for (const d of s.doodles) {
        const a = s.t - d.t0, f = 1 - smooth(d.life - 0.3, d.life, a);
        if (f <= 0 || d.kind === 'munch') continue;
        c.globalAlpha = f;
        if (d.kind === 'note') Hill.quaver(c, d.x + Math.sin(a * 4 + d.seed) * 5 * u, d.y - a * 36 * u, 3.6 * u + 1.4, Hill.INK, d.flip);
        else Hill.label(c, (d.text || d.kind).toUpperCase(), d.x, d.y - (s.reduced ? 0 : a * 6 * u), Math.max(10, 11 * u + 2), Hill.INK, d.align, -0.04);
      }
      c.globalAlpha = 1;
    },
  },
});
})();
