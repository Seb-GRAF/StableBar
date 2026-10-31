/* stablebar.app: the bar demos, the paper notes, and the drawing behind them (scene.js).
   Everything here works without the drawing; the drawing only adds to it. */
(() => {
"use strict";
const root = document.documentElement;
const THEMES = [
  ["built-in", "Built-in", "ws-fill"],
  ["catppuccin", "Catppuccin", "ws-fill"],
  ["gruvbox", "Gruvbox", "ws-text"],
  ["leman", "Léman", "ws-fill"],
  ["nord", "Nord", "ws-under"],
  ["notch", "Notch", "ws-text"],
  ["phosphor", "Phosphor", "ws-fill"],
];
const dock = document.getElementById("dock");
const bar = document.getElementById("bar");
const gl = document.getElementById("gl");
const gc = document.getElementById("gc");
const gr = document.getElementById("gr");
const more = bar.querySelector(".more");
const pop = document.getElementById("pop");
const panes = [...pop.querySelectorAll(".pane")];
const menu = pop.querySelector('[data-id="more"]');
const heroNote = document.querySelector(".hero-note");
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
let openId = null;
let editing = false;

/* The drawing, if scene.js is there. Every call goes through S, so a scene that fails never takes the page with it. */
let scene = null;
let sceneFailed = false;
function S(method, ...args) {
  if (!scene || typeof scene[method] !== "function") return undefined;
  try { return scene[method](...args); } catch (err) {
    if (!sceneFailed) { sceneFailed = true; console.warn("The drawing failed:", err); }
    return undefined;
  }
}
/* The bar's height when it isn't being edited; Nord is shorter */
const restHeight = () => parseFloat(getComputedStyle(dock).getPropertyValue("--rest-h")) || 40;

/* Now playing: the track moves on while it plays */
const track = { at: 87, length: 243, playing: true };
const trackAt = document.getElementById("np-at");
const trackBar = document.getElementById("np-bar");
document.getElementById("np-play").addEventListener("click", e => {
  track.playing = !track.playing;
  dock.classList.toggle("paused", !track.playing);
  e.currentTarget.setAttribute("aria-label", track.playing ? "Pause" : "Play");
});

/* Clocks show the visitor's real time */
function tick() {
  const d = new Date();
  const hm = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const day = `${d.toLocaleDateString("en-GB", { weekday: "short" })} ${d.getDate()} ${d.toLocaleDateString("en-GB", { month: "short" })}`;
  for (const c of document.querySelectorAll(".clock")) {
    if (c.dataset.format === "full") c.innerHTML = `<span class="day">${day}&nbsp;&nbsp;</span>${hm}`;
    else if (c.dataset.format === "seconds") c.textContent = d.toLocaleTimeString("en-GB");
    else c.textContent = hm;
  }
  if (track.playing) track.at = (track.at + 1) % track.length;
  trackAt.textContent = `${Math.floor(track.at / 60)}:${String(track.at % 60).padStart(2, "0")}`;
  trackBar.style.width = `${track.at / track.length * 100}%`;
}
tick();
setInterval(tick, 1000);

/* Themes: the tags on the washing line restyle the bar, and the drawing: each theme draws the scene in its own style
   (styles/), which the lighthouse's light brings in as it turns once round, the lighthouse in the theme's pyjamas */
function setTheme(id) {
  barTheme(id);
  for (const b of document.querySelectorAll("[data-theme-pick]")) {
    b.classList.toggle("on", b.dataset.themePick === id);
    b.setAttribute("aria-pressed", b.dataset.themePick === id);
  }
  S("setTheme", id);
  requestAnimationFrame(() => {
    fit();
    S("setTopInset", restHeight());
  });
}
// the bar alone; out at sea it takes the theme of the island ahead (see onBar)
function barTheme(id) {
  dock.dataset.theme = id;
  bar.className = `bar ${THEMES.find(t => t[0] === id)[2]}`;
}
for (const b of document.querySelectorAll("[data-theme-pick]")) b.addEventListener("click", () => setTheme(b.dataset.themePick));

/* Overflow, as the real bar does it: lower priority first, equal priorities from the end */
const needed = () => gl.scrollWidth + gc.scrollWidth + gr.scrollWidth + 36 + (gc.offsetWidth ? 12 : 0);
function fit() {
  const widgets = [...bar.querySelectorAll("[data-pri]")].filter(w => w.dataset.pri !== "never");
  widgets.forEach(w => w.classList.remove("over"));
  more.hidden = true;
  if (editing) { fades(); sendBar(); return; }
  const order = widgets.map((w, i) => ({ w, p: Number(w.dataset.pri), i })).sort((a, b) => a.p - b.p || b.i - a.i).map(o => o.w);
  const shown = order.filter(w => w.offsetWidth > 0);
  for (const w of shown) {
    if (needed() <= bar.clientWidth) break;
    w.classList.add("over");
    more.hidden = false;
  }
  for (const w of [...shown].reverse()) {
    if (!w.classList.contains("over")) continue;
    w.classList.remove("over");
    if (needed() > bar.clientWidth) w.classList.add("over");
  }
  more.hidden = !bar.querySelector(".over");
  for (const b of menu.querySelectorAll("[data-for]")) {
    b.classList.toggle("over-off", !bar.querySelector(`[data-key="${b.dataset.for}"]`)?.classList.contains("over"));
  }
  place();
  slide();
  sendBar();
}

/* The bar's visible widgets, for the lighthouse's ball game (scene.setBar): each workspace number is
   its own target, and the ball bounces on the line under them: the widgets' bottom edge, the bar's
   when it has a strip, or the strip's pen line once the page has scrolled. Measured when the bar
   changes (fit, the header swap, resizing, themes, scrolling past the top), never every frame. */
function barTargets() {
  if (editing) return [];
  // from the theme's tokens rather than the bar's box, which may still be easing into a new theme
  const cs = getComputedStyle(bar), strip = cs.getPropertyValue("--strip-bg").trim() !== "transparent";
  const line = dock.classList.contains("scrolled") ? restHeight() + 3.5 : strip ? restHeight() - (parseFloat(cs.getPropertyValue("--strip-m")) || 0) : null;
  const out = [];
  const add = (key, el) => {
    const r = el.getBoundingClientRect();
    if (r.width > 3 && r.right > 0 && r.left < innerWidth) out.push({ key, x0: r.left, x1: r.right, y: line ?? r.bottom });
  };
  for (const w of bar.querySelectorAll(":scope > .g > .w[data-key]")) {
    if (w.hidden || w.classList.contains("over") || getComputedStyle(w).visibility === "hidden") continue;
    if (w.dataset.key === "ws") for (const b of w.querySelectorAll(".wsi")) add(`ws:${b.dataset.ws}`, b);
    else add(w.dataset.key, w);
  }
  return out;
}
function sendBar() { if (scene) S("setBar", barTargets()); }

/* Popups open below their widget, or from More widgets when the widget is hidden */
function anchorFor(id) {
  if (id === "more") return more;
  const w = bar.querySelector(`[data-pop="${id}"]`);
  return w.classList.contains("over") ? more : w;
}
function place() {
  if (!openId) return;
  const pane = panes.find(p => p.dataset.id === openId);
  const dr = dock.getBoundingClientRect();
  const a = anchorFor(openId).getBoundingClientRect();
  let left = a.left - dr.left + a.width / 2 - pane.offsetWidth / 2;
  if (openId !== "more" && anchorFor(openId) === more) left = a.right - dr.left - pane.offsetWidth;
  pop.style.left = `${clamp(left, 8, dr.width - pane.offsetWidth - 8)}px`;
  pop.style.top = `${bar.getBoundingClientRect().bottom - dr.top + 6}px`;
  pop.style.width = `${pane.offsetWidth}px`;
  pop.style.height = `${pane.offsetHeight}px`;
}
/* The control that opens a widget's popup: the widget itself, or the app name in StableBar's menus */
const popButton = w => w.matches("button") ? w : w.querySelector(":scope > button");
/* Opening another widget's popup morphs the open one into it, as the app does */
function open(id) {
  if (id !== openId && anchorFor(id).hidden) return;
  hideTour();
  const from = openId;
  openId = openId === id ? null : id;
  pop.classList.toggle("morph", Boolean(from && openId));
  pop.classList.toggle("open", Boolean(openId));
  for (const p of panes) p.classList.toggle("on", p.dataset.id === openId);
  for (const w of bar.querySelectorAll("[data-pop]")) {
    w.classList.toggle("open", w.dataset.pop === openId || Boolean(openId && anchorFor(openId) === w));
    popButton(w)?.setAttribute("aria-expanded", w.classList.contains("open"));
  }
  place();
}
for (const w of bar.querySelectorAll("[data-pop]")) w.addEventListener("click", e => {
  if (e.target.closest("a")) return;
  e.stopPropagation();
  open(w.dataset.pop);
});
for (const b of menu.querySelectorAll("[data-open]")) b.addEventListener("click", e => { e.stopPropagation(); open(b.dataset.open); });
document.addEventListener("click", e => { if (openId && !e.target.closest(".pop, .win, .tag, .w")) open(openId); });
/* Escape closes the popup and returns focus to its widget */
document.addEventListener("keydown", e => {
  if (e.key !== "Escape" || !openId) return;
  const from = pop.contains(document.activeElement) && anchorFor(openId);
  open(openId);
  if (from) (popButton(from) || from).focus();
});

/* Workspaces: the focus highlight slides to the one you click, as on the real bar.
   The postcard's large widget is the same four workspaces, and the drawing's beach huts follow. */
const ind = bar.querySelector(".ind");
function slide() {
  const on = bar.querySelector(".wsi.on");
  ind.style.setProperty("--x", `${on.offsetLeft}px`);
  ind.style.setProperty("--w", `${on.offsetWidth}px`);
}
function focusWorkspace(n) {
  for (const e of document.querySelectorAll(".wsi[data-ws]")) {
    const on = e.dataset.ws === String(n);
    e.classList.toggle("on", on);
    e.setAttribute("aria-pressed", on);
  }
  slide();
  S("setWorkspace", n);
}
for (const el of document.querySelectorAll(".wsi[data-ws]")) el.addEventListener("click", () => focusWorkspace(Number(el.dataset.ws)));

/* The app's menus open on hover when the bar has room for them */
const finder = bar.querySelector(".finder");
finder.addEventListener("mouseenter", () => {
  if (needed() + finder.querySelector(".menus > span").scrollWidth <= bar.clientWidth) finder.classList.add("expand");
  setTimeout(place, 320);
});
finder.addEventListener("mouseleave", () => { finder.classList.remove("expand"); setTimeout(place, 320); });

/* Sound opens its volume slider on hover, when the bar has room for it */
const sound = bar.querySelector(".snd");
const volume = sound.querySelector("input");
function expandSound(open) {
  sound.classList.toggle("expand", open && needed() + sound.querySelector(".slide > span").scrollWidth + 7 <= bar.clientWidth);
  setTimeout(place, 320);
}
sound.addEventListener("mouseenter", () => expandSound(true));
sound.addEventListener("mouseleave", () => { if (!sound.querySelector(":focus-visible")) expandSound(false); });
sound.addEventListener("focusin", () => expandSound(true));
sound.addEventListener("focusout", () => { if (!sound.matches(":hover")) expandSound(false); });
volume.addEventListener("input", () => {
  sound.querySelector(".pct").textContent = `${volume.value}%`;
  volume.style.setProperty("--v", `${volume.value}%`);
});
/* Those two change the widgets' widths, and a new theme the bar's height: the ball game measures the bar again once they settle */
bar.addEventListener("transitionend", e => { if ((e.propertyName === "grid-template-columns" || e.target === bar && e.propertyName === "height") && !editing) sendBar(); });

/* Once the page scrolls, a strip of sky slides in behind the bar. Once the headline has gone
   under it, the bar becomes the page's header. While the bar is being edited it stays the demo. */
let swapAt = 0;
function wantHeader() {
  const line = restHeight() + 56, bottom = heroNote.getBoundingClientRect().bottom;
  // once it's the header it stays so until the headline is well back in view, so small scrolls don't flip it
  return !editing && bottom < (dock.classList.contains("header") ? line + 120 : line);
}
function setHeader(header) {
  hideTour();
  dock.classList.add("measure");
  dock.classList.toggle("header", header);
  fit();
  dock.offsetWidth;
  dock.classList.remove("measure");
  if (openId) open(openId);
}
/* Scrolling swaps the bar's contents in one step behind a short fade, as macOS swaps an app's menus,
   instead of letting widgets slide over one another. Editing, resizing and loading swap at once. */
function dockState(fade = false) {
  if (dock.classList.contains("scrolled") !== scrollY > 2) {
    dock.classList.toggle("scrolled", scrollY > 2);
    sendBar();
  }
  if (swapAt && fade) return;
  swapAt = 0;
  bar.classList.remove("swap");
  const header = wantHeader();
  if (header === dock.classList.contains("header")) return;
  if (!fade || reduce.matches) return setHeader(header);
  // fade out, then swap on the first frame after the fade (frames, not a timer, so a busy page can't hold it)
  bar.classList.add("swap");
  const at = swapAt = performance.now() + 130;
  const step = now => {
    if (swapAt !== at) return;
    if (now < at) return requestAnimationFrame(step);
    swapAt = 0;
    setHeader(wantHeader());
    bar.classList.remove("swap");
  };
  requestAnimationFrame(step);
}

/* Edit Bar in Place: the bar becomes its own editor, as in the app. Each position gets a tray,
   widgets keep their look, − takes one off, + adds one where it sits, and Undo and Done wait below. */
const trays = [gl, gc, gr];
const TRAYS = ["Left", "Center", "Right"];
const NAMES = { apple: "Apple menu", ws: "Workspaces", app: "App menus", np: "Now playing", meeting: "Calendar", system: "System monitor", sound: "Sound", battery: "Battery", clock: "Clock & date" };
const ease = "cubic-bezier(.22, 1, .36, 1)";
const editCtl = document.getElementById("edit-ctl");
const undoButton = document.getElementById("edit-undo");
const tryEdit = document.getElementById("try-edit");
const addPop = document.getElementById("addpop");
const ctx = document.getElementById("ctx");
const live = document.getElementById("edit-live");
let past = [], future = [], drag = null, adding = null, made = 0, opener = null;

const lane = i => trays[i].querySelector(".lane");
const tilesIn = (i, except) => [...lane(i).querySelectorAll(":scope > .tile:not([hidden])")].filter(t => t !== except);
const trayOf = t => trays.indexOf(t.closest(".g"));
const nameOf = t => t.dataset.name;
const snap = () => trays.map((g, i) => tilesIn(i));
const same = (a, b) => a.every((tiles, i) => tiles.length === b[i].length && tiles.every((t, k) => t === b[i][k]));
const say = text => { live.textContent = text; };

function tile(w) {
  const t = document.createElement("div");
  t.className = "tile";
  t.tabIndex = 0;
  t.hidden = w.hidden;
  t.dataset.name = w.dataset.name || NAMES[w.dataset.key];
  t.setAttribute("role", "button");
  t.setAttribute("aria-label", t.dataset.name);
  t.setAttribute("aria-describedby", "edit-help");
  w.hidden = false;
  w.inert = true;
  const minus = document.createElement("button");
  minus.className = "minus";
  minus.tabIndex = -1;
  minus.title = minus.ariaLabel = `Remove ${t.dataset.name}`;
  t.append(w, minus);
  return t;
}

function beginEditing(from) {
  if (editing) return;
  if (openId) open(openId);
  closeMenu();
  opener = from || (bar.contains(document.activeElement) ? document.activeElement : null);
  hideTour();
  editing = true;
  dockState();
  past = [];
  future = [];
  sound.classList.remove("expand");
  finder.classList.remove("expand");
  for (const [i, g] of trays.entries()) {
    const l = document.createElement("div");
    l.className = "lane";
    for (const w of [...g.children].filter(w => w.dataset.key && !w.matches(".more, .dl, .site, .moon"))) l.append(tile(w));
    const add = document.createElement("button");
    add.className = "add";
    add.title = add.ariaLabel = `Add a widget to ${TRAYS[i]}`;
    add.innerHTML = '<svg aria-hidden="true"><use href="#i-plus"/></svg>';
    add.addEventListener("click", e => { e.stopPropagation(); adding?.i === i ? closeAdd() : openAdd(i, add); });
    i === 2 ? l.prepend(add) : l.append(add);
    l.addEventListener("scroll", fades, { passive: true });
    l.addEventListener("wheel", e => {
      if (l.scrollWidth <= l.clientWidth || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      l.scrollLeft += e.deltaY;
      e.preventDefault();
    }, { passive: false });
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.textContent = TRAYS[i];
    chip.ariaHidden = "true";
    g.append(chip, l);
    g.setAttribute("role", "group");
    g.ariaLabel = TRAYS[i];
  }
  dock.classList.add("editing");
  updateControls();
  fit();
  say("Editing the bar. Done or Escape finishes.");
}

function endEditing() {
  if (!editing) return;
  if (drag?.started) {
    settle(false);
    drag.ghost.remove();
  }
  drag = null;
  closeAdd();
  closeMenu();
  for (const g of trays) {
    const end = g.querySelector(":scope > .dl, :scope > .site");
    for (const t of g.querySelectorAll(".lane > .tile")) {
      const w = t.firstElementChild;
      w.inert = false;
      w.hidden = t.hidden;
      g.insertBefore(w, end);
    }
    g.querySelector(".lane").remove();
    g.querySelector(".chip").remove();
    g.removeAttribute("role");
    g.removeAttribute("aria-label");
  }
  editing = false;
  dock.classList.remove("editing", "dragging");
  updateControls();
  requestAnimationFrame(() => { fit(); slide(); dockState(); });
  say("Finished editing the bar.");
}
/* Done and Escape hand focus back to whatever started editing */
function finishEditing() {
  const back = opener;
  opener = null;
  endEditing();
  if (back?.isConnected && !back.closest("[inert]")) back.focus({ preventScroll: true });
}

function updateControls() {
  undoButton.disabled = !past.length;
}

/* Lanes too crowded for their tray scroll sideways, with faded edges */
function fades() {
  for (const l of bar.querySelectorAll(".lane")) {
    l.classList.toggle("fl", l.scrollLeft > 1);
    l.classList.toggle("fr", l.scrollLeft + l.clientWidth < l.scrollWidth - 1);
  }
}

/* Widgets slide aside to make room: each one glides from where it was to where it lands */
function rearrange(change) {
  const items = [...bar.querySelectorAll(".lane > *")];
  const first = new Map(items.map(e => [e, e.getBoundingClientRect()]));
  change();
  fades();
  if (reduce.matches) return;
  for (const e of items) {
    e.getAnimations().forEach(a => a.cancel());
    const a = first.get(e), b = e.getBoundingClientRect();
    if (e.hidden || !a.width || !b.width) continue;
    const dx = a.left - b.left, dy = a.top - b.top;
    if (Math.abs(dx) + Math.abs(dy) > .5) e.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { duration: 300, easing: ease });
  }
}

/* Put a widget at a place among the shown widgets of a position; the + keeps its end */
function putAt(i, t, index) {
  const tiles = tilesIn(i, t);
  if (tiles[index]) tiles[index].before(t);
  else if (tiles.length) tiles.at(-1).after(t);
  else i === 2 ? lane(i).append(t) : lane(i).prepend(t);
}

function record(before, message) {
  if (same(before, snap())) return;
  past.push(before);
  future = [];
  updateControls();
  say(message);
}

function restore(state) {
  rearrange(() => {
    const kept = new Set(state.flat());
    for (const t of bar.querySelectorAll(".lane > .tile")) t.hidden = !kept.has(t);
    state.forEach((tiles, i) => tiles.forEach((t, k) => putAt(i, t, k)));
  });
}
function undo() {
  if (!past.length) return;
  future.push(snap());
  restore(past.pop());
  updateControls();
  say("Undone.");
}
function redo() {
  if (!future.length) return;
  past.push(snap());
  restore(future.pop());
  updateControls();
  say("Redone.");
}

function step(t, by) {
  const before = snap(), i = trayOf(t), tiles = tilesIn(i), k = tiles.indexOf(t);
  if (!tiles[k + by] && !trays[i + by]) return;
  rearrange(() => {
    if (tiles[k + by]) putAt(i, t, k + by);
    else putAt(i + by, t, by < 0 ? Infinity : 0);
  });
  t.focus();
  t.scrollIntoView({ block: "nearest", inline: "nearest" });
  record(before, `Moved ${nameOf(t)} to ${TRAYS[trayOf(t)]}, position ${tilesIn(trayOf(t)).indexOf(t) + 1}.`);
}

function remove(t) {
  const before = snap();
  const next = t.nextElementSibling?.matches(".tile:not([hidden])") ? t.nextElementSibling : t.previousElementSibling;
  rearrange(() => { t.hidden = true; });
  (next?.matches(".tile, .add") ? next : editCtl.querySelector(".done")).focus();
  record(before, `Removed ${nameOf(t)}.`);
}

/* Dragging: the widget lifts off the bar, the others make room, and it settles into the gap */
function trayAt(x, y) {
  const b = bar.getBoundingClientRect();
  if (y < b.top - 40 || y > b.bottom + 70) return -1;
  let best = -1, gap = Infinity;
  trays.forEach((g, i) => {
    const r = g.getBoundingClientRect();
    const d = x < r.left ? r.left - x : x > r.right ? x - r.right : 0;
    if (r.width && d < gap) { best = i; gap = d; }
  });
  return best;
}
function indexAt(i, x, t) {
  const tiles = tilesIn(i, t);
  const k = tiles.findIndex(o => { const r = o.getBoundingClientRect(); return x < r.left + r.width / 2; });
  return k < 0 ? tiles.length : k;
}
function lift(e) {
  const t = drag.t, r = t.getBoundingClientRect();
  drag.started = true;
  drag.before = snap();
  drag.home = [trayOf(t), tilesIn(trayOf(t)).indexOf(t)];
  drag.dx = e.clientX - r.left;
  drag.dy = e.clientY - r.top;
  const ghost = document.createElement("div");
  ghost.className = `ghost ${[...bar.classList].filter(c => c.startsWith("ws-")).join(" ")}`;
  const copy = t.firstElementChild.cloneNode(true);
  copy.querySelector(".ind")?.remove();
  ghost.append(copy);
  dock.append(ghost);
  drag.ghost = ghost;
  t.classList.add("lifted");
  dock.classList.add("dragging");
  closeAdd();
  closeMenu();
}
function follow(e) {
  const { t, ghost } = drag;
  ghost.style.left = `${e.clientX - drag.dx}px`;
  ghost.style.top = `${e.clientY - drag.dy}px`;
  const i = trayAt(e.clientX, e.clientY);
  drag.target = i;
  trays.forEach((g, k) => g.classList.toggle("target", k === i));
  if (i < 0) return;
  const l = lane(i), r = l.getBoundingClientRect();
  if (e.clientX < r.left + 24) l.scrollLeft -= 8;
  else if (e.clientX > r.right - 24) l.scrollLeft += 8;
  const index = indexAt(i, e.clientX, t);
  if (trayOf(t) !== i || tilesIn(i).indexOf(t) !== index) rearrange(() => putAt(i, t, index));
}
function settle(dropped) {
  const { t, ghost, before, home } = drag;
  if (!dropped) rearrange(() => putAt(home[0], t, home[1]));
  trays.forEach(g => g.classList.remove("target"));
  dock.classList.remove("dragging");
  const r = t.getBoundingClientRect(), from = ghost.getBoundingClientRect();
  const done = () => { ghost.remove(); t.classList.remove("lifted"); };
  if (reduce.matches) done();
  else ghost.animate([{ left: `${from.left}px`, top: `${from.top}px`, scale: 1.04 }, { left: `${r.left}px`, top: `${r.top}px`, scale: 1 }], { duration: 260, easing: ease, fill: "forwards" }).finished.then(done);
  if (dropped) record(before, `Moved ${nameOf(t)} to ${TRAYS[trayOf(t)]}.`);
}
bar.addEventListener("pointerdown", e => {
  const t = editing && e.button === 0 && e.target.closest(".tile");
  if (!t || e.target.closest(".minus")) return;
  e.preventDefault();
  t.focus({ preventScroll: true });
  t.setPointerCapture(e.pointerId);
  drag = { t, x: e.clientX, y: e.clientY, started: false };
});
bar.addEventListener("pointermove", e => {
  if (!drag) return;
  if (!drag.started) {
    if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < 4) return;
    lift(e);
  }
  follow(e);
});
bar.addEventListener("pointerup", () => {
  if (drag?.started) settle(drag.target >= 0);
  drag = null;
});
bar.addEventListener("pointercancel", () => {
  if (drag?.started) settle(false);
  drag = null;
});
bar.addEventListener("click", e => {
  const minus = editing && e.target.closest(".minus");
  if (minus) { e.stopPropagation(); remove(minus.closest(".tile")); }
});
bar.addEventListener("keydown", e => {
  const t = editing && e.target.closest?.(".tile");
  if (!t) return;
  if (e.key === "ArrowLeft" || e.key === "ArrowRight") { e.preventDefault(); step(t, e.key === "ArrowLeft" ? -1 : 1); }
  else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); remove(t); }
});

/* Add here: the app's list of widgets, then a review for a Store package before it's added */
const CHOICES = [
  { id: "clock", name: "Clock & date", icon: "i-clock", key: "clock", html: '<div class="w num clock" data-format="time"></div>' },
  { id: "activeApp", name: "Active app", icon: "i-window", html: '<div class="w app"><img class="ai" src="images/apps/finder.svg" alt="" width="16" height="16" style="width:16px;height:16px"><span class="name">Finder</span></div>' },
  { id: "appleMenu", name: "Apple menu", icon: "i-apple", key: "apple", html: '<div class="w apple"><svg style="width:13px;height:15px;fill:currentColor"><use href="#i-apple"/></svg></div>' },
  { id: "appMenu", name: "App menus", icon: "i-menubar", key: "app", html: '<div class="w app"><span class="name">Finder</span></div>' },
  { id: "controlCenter", name: "Control Center", icon: "i-switch", html: '<div class="w"><svg><use href="#i-switch"/></svg></div>' },
  { id: "menuBarItems", name: "Menu bar items", icon: "i-grid", html: '<div class="w"><svg><use href="#i-grid"/></svg></div>' },
  { id: "battery", name: "Battery", icon: "i-bat", key: "battery", html: '<div class="w"><svg style="width:19px"><use href="#i-bat"/></svg>82%</div>' },
  { id: "audio", name: "Sound", icon: "i-snd", key: "sound", html: '<div class="w"><svg><use href="#i-snd"/></svg></div>' },
  { id: "system", name: "System monitor", icon: "i-cpu", key: "system", html: '<div class="w"><svg><use href="#i-cpu"/></svg>18%&nbsp;&nbsp;<svg><use href="#i-mem"/></svg>54%</div>' },
  { id: "network", name: "Network", icon: "i-globe", html: '<div class="w num">↓ 2.4 MB/s&nbsp;&nbsp;↑ 180 KB/s</div>' },
  { id: "calendar", name: "Calendar", icon: "i-cal", key: "meeting", html: '<div class="w"><svg><use href="#i-cal"/></svg>Design review&nbsp;&nbsp;10:30</div>' },
  { id: "workspaces", name: "Workspaces", icon: "i-group", key: "ws", html: '<div class="w ws copy"><span class="wsi on">1</span><span class="wsi">2</span><span class="wsi">3</span></div>' },
  { id: "text", name: "Text", icon: "i-text", html: '<div class="w">New widget</div>' },
  { id: "spacer", name: "Spacer", icon: "i-spacer", html: '<div class="w spacer"></div>' },
  { id: "ai-usage", name: "AI usage", version: "1.2.5", commands: 1, hosts: ["api.anthropic.com", "chatgpt.com"], description: "Shows your Claude Code and Codex limits in one widget, with reset countdowns and weekly pace, using the sign-ins those tools already keep.", html: '<div class="w"><svg><use href="#i-asterisk"/></svg><span class="gauge"><i style="--p:42%"></i><i style="--p:64%"></i></span>42%&nbsp;&nbsp;<svg><use href="#i-term"/></svg><span class="gauge"><i style="--p:18%"></i><i style="--p:30%"></i></span>18%</div>' },
  { id: "agent-status", name: "Agent status", version: "1.0.4", commands: 1, requires: ["jq"], description: "Shows Claude Code waiting or finishing and Codex finishing.", html: '<div class="w"><svg><use href="#i-term"/></svg>1</div>' },
  { id: "amphetamine", name: "Amphetamine", version: "1.1.1", commands: 5, permissions: ["Automation"], description: "Toggle Amphetamine from the bar, adjust its timer with an inline hover slider, and see the time remaining.", html: '<div class="w"><svg><use href="#i-pill"/></svg>Off</div>' },
  { id: "dev-servers", name: "Development servers", version: "1.0.2", commands: 2, requires: ["jq"], description: "Lists your listening TCP ports and their processes, with actions to open localhost or stop a process.", html: '<div class="w"><svg><use href="#i-server"/></svg>3</div>' },
  { id: "dock-badges", name: "Dock badges", version: "1.0.2", commands: 1, requires: ["jq"], description: "Shows the total unread count from running apps' Dock badges, with a popup that opens each app.", html: '<div class="w"><svg><use href="#i-badge"/></svg>2</div>' },
  { id: "github-notifications", name: "GitHub notifications", version: "1.0.2", commands: 1, hosts: ["api.github.com"], description: "Shows your unread GitHub notification count and lists the latest ones, each opening on GitHub.", html: '<div class="w"><svg><use href="#i-bell"/></svg>3</div>' },
  { id: "homebrew-outdated", name: "Homebrew outdated", version: "1.0.3", commands: 1, requires: ["brew"], description: "Shows how many Homebrew formulae and casks are outdated, and lists them.", html: '<div class="w"><svg><use href="#i-box"/></svg>4</div>' },
  { id: "now-playing", name: "Now playing", version: "1.2.2", commands: 11, hosts: ["i.scdn.co"], permissions: ["Automation"], key: "np", description: "Shows the playing or paused track from Music or Spotify with its artwork and bouncing bars while it plays, and a popup with seeking, volume, shuffle, repeat and favorites.", html: '<div class="w"><i class="art"></i>Midnight City · M83</div>' },
  { id: "quick-ask", name: "Quick ask", version: "1.0.0", commands: 12, hosts: ["api.anthropic.com", "chatgpt.com", "api.openai.com"], requires: ["jq"], description: "Ask Claude Code or Codex from the bar. Choose the model and effort, follow up, retry, and drag the chat anywhere to keep it on screen.", html: '<div class="w"><svg><use href="#i-sparkles"/></svg></div>' },
  { id: "weather", name: "Weather", version: "1.0.3", commands: 1, hosts: ["wttr.in"], description: "Shows the current temperature and conditions from wttr.in, with feels-like, humidity, wind and today's high and low.", html: '<div class="w"><svg><use href="#i-weather"/></svg>14°</div>' },
  { id: "script", name: "Script", icon: "i-term", html: '<div class="w num clock" data-format="time"></div>' },
];
const list = (items, last) => items.length > 1 ? `${items.slice(0, -1).join(", ")} ${last} ${items.at(-1)}` : items[0];

addPop.addEventListener("click", e => e.stopPropagation());
function openAdd(i, button) {
  closeMenu();
  adding = { i, button };
  bar.querySelectorAll(".add").forEach(b => b.classList.toggle("on", b === button));
  dock.classList.add("adding");
  showChoices("");
}
function closeAdd() {
  if (!adding) return;
  const { button } = adding;
  adding = null;
  addPop.hidden = true;
  addPop.classList.remove("review");
  dock.classList.remove("adding");
  bar.querySelectorAll(".add").forEach(b => b.classList.remove("on"));
  if (addPop.contains(document.activeElement)) button.focus();
}
function placeAdd() {
  const dr = dock.getBoundingClientRect(), a = adding.button.getBoundingClientRect();
  const left = clamp(a.left - dr.left + a.width / 2 - 30, 8, dr.width - addPop.offsetWidth - 8);
  addPop.style.left = `${left}px`;
  addPop.style.top = `${a.bottom - dr.top + 13}px`;
  addPop.style.setProperty("--ax", `${a.left - dr.left + a.width / 2 - left - 6}px`);
}
function showChoices(query) {
  addPop.classList.remove("review");
  addPop.innerHTML = '<p class="t">ADD HERE</p><input class="find" type="search" placeholder="Search widgets" aria-label="Search widgets"><div class="list"></div>';
  const find = addPop.querySelector(".find"), grid = addPop.querySelector(".list");
  find.value = query;
  const fill = () => {
    const q = find.value.trim().toLowerCase();
    const shown = CHOICES.filter(c => c.name.toLowerCase().includes(q));
    grid.innerHTML = shown.map(c => `<button class="ch" data-id="${c.id}" title="${c.description || ""}"><svg class="ic" aria-hidden="true"><use href="#${c.version ? "i-box" : c.icon}"/></svg><span><b>${c.name}</b><small>${c.version ? "Store" : "Built-in"}</small></span>${c.version ? '<svg class="from-store" role="img" aria-label="Downloads from Store"><use href="#i-get"/></svg>' : ""}</button>`).join("") || '<p class="none">No widgets found.</p>';
    placeAdd();
  };
  find.addEventListener("input", fill);
  find.addEventListener("keydown", e => { if (e.key === "Enter") grid.querySelector(".ch")?.click(); });
  grid.addEventListener("click", e => {
    const c = CHOICES.find(c => c.id === e.target.closest(".ch")?.dataset.id);
    if (c) c.version ? review(c, find.value) : add(c);
  });
  addPop.hidden = false;
  fill();
  find.focus({ preventScroll: true });
}
/* A Store package's review: what it can do, before it's added */
function reviewHTML(c, back, go) {
  const can = [
    ["i-term", `Runs ${c.commands} command${c.commands === 1 ? "" : "s"} while it’s on your bar`],
    ["i-lock", c.permissions ? `Uses ${list(c.permissions, "and")} access` : "Needs no macOS permissions"],
    ["i-globe", c.hosts ? `Connects to ${list(c.hosts, "and")}` : "Doesn’t go online"],
    ...(c.requires || []).map(tool => ["i-tool", `Needs ${tool}`]),
  ];
  return `<button class="back">${back}</button><h4>${c.name}</h4><p class="d">${c.description}</p><p class="m">${c.id} · Version ${c.version} · StableBar Store</p>
    <ul class="can">${can.map(([icon, text]) => `<li><svg aria-hidden="true"><use href="#${icon}"/></svg>${text}</li>`).join("")}</ul>
    <div class="foot"><span>A maintainer read this package before the Store published it.</span><button class="go">${go}</button></div>`;
}
function review(c, query) {
  addPop.classList.add("review");
  addPop.innerHTML = reviewHTML(c, "Back", "Add widget");
  addPop.querySelector(".back").addEventListener("click", () => showChoices(query));
  addPop.querySelector(".go").addEventListener("click", () => add(c));
  placeAdd();
  addPop.querySelector(".go").focus({ preventScroll: true });
}
/* A new widget from a choice, listed in More widgets in case the bar runs out of room */
function make(c) {
  const holder = document.createElement("div");
  holder.innerHTML = c.html;
  const w = holder.firstElementChild;
  w.dataset.key = `added-${++made}`;
  w.dataset.pri = "2";
  w.dataset.name = c.name;
  menu.insertAdjacentHTML("beforeend", `<button data-for="${w.dataset.key}">${c.name}</button>`);
  if (c.version) installed(c.id);
  return w;
}
function add(c) {
  const { i } = adding, before = snap();
  let t = c.key && [...bar.querySelectorAll(".lane > .tile[hidden]")].find(o => o.firstElementChild.dataset.key === c.key);
  if (!t) {
    t = tile(make(c));
    t.hidden = true;
    lane(i).append(t);
    tick();
  }
  rearrange(() => {
    t.hidden = false;
    putAt(i, t, i === 2 ? 0 : Infinity);
  });
  if (!reduce.matches) t.animate([{ opacity: 0, scale: .85 }, { opacity: 1, scale: 1 }], { duration: 220, easing: ease });
  closeAdd();
  t.focus({ preventScroll: true });
  t.scrollIntoView({ block: "nearest", inline: "nearest" });
  record(before, `Added ${c.name} to ${TRAYS[i]}.`);
}

/* The Store: Get reviews a package, and Add to bar puts it on the bar at the top of the page */
const pkgReview = document.getElementById("pkg-review");
const storeWin = document.querySelector(".store-win");
let reviewing = null;
function installed(id) {
  const state = document.querySelector(`.pkg[data-id="${id}"] .pkg-get`);
  state?.replaceWith(Object.assign(document.createElement("span"), { className: "state", innerHTML: '<svg viewBox="0 0 12 12" aria-hidden="true"><use href="#p-check"/></svg>Installed' }));
}
function closeReview() {
  if (!reviewing) return;
  const get = reviewing;
  reviewing = null;
  pkgReview.hidden = true;
  storeWin.classList.remove("sheet");
  storeWin.inert = false;
  if (pkgReview.contains(document.activeElement) && get.isConnected) get.focus({ preventScroll: true });
}
document.querySelector(".pkgs").addEventListener("click", e => {
  const get = e.target.closest(".pkg-get");
  if (!get) return;
  e.stopPropagation();
  if (reviewing === get) return closeReview();
  const c = CHOICES.find(c => c.id === get.closest(".pkg").dataset.id);
  reviewing = get;
  pkgReview.innerHTML = reviewHTML(c, "Cancel", "Add to bar");
  pkgReview.hidden = false;
  storeWin.classList.add("sheet");
  // the sheet covers the window, as on the Mac: what's under it can't take focus until it closes
  storeWin.inert = true;
  pkgReview.querySelector(".back").addEventListener("click", closeReview);
  pkgReview.querySelector(".go").addEventListener("click", () => {
    closeReview();
    const w = make(c);
    if (editing) {
      const t = tile(w);
      t.hidden = true;
      lane(2).append(t);
      const before = snap();
      rearrange(() => { t.hidden = false; putAt(2, t, 0); });
      record(before, `Added ${c.name} to Right.`);
    } else {
      gr.insertBefore(w, more.nextElementSibling);
      fit();
      if (!reduce.matches) w.animate([{ opacity: 0, scale: .85 }, { opacity: 1, scale: 1 }], { duration: 260, easing: ease });
    }
    say(`Added ${c.name} to the bar.`);
  });
  pkgReview.querySelector(".go").focus({ preventScroll: true });
});
pkgReview.addEventListener("click", e => e.stopPropagation());

/* Right-click the bar, as in the app: Edit Bar in Place, or a widget's moves while editing */
function showMenu(x, y, items) {
  closeAdd();
  ctx.innerHTML = items.map(item => item ? `<button role="menuitem">${item[0]}</button>` : "<hr>").join("");
  const actions = items.filter(Boolean).map(item => item[1]);
  ctx.querySelectorAll("button").forEach((b, k) => b.addEventListener("click", e => { e.stopPropagation(); closeMenu(); actions[k](); }));
  ctx.hidden = false;
  const dr = dock.getBoundingClientRect();
  ctx.style.left = `${clamp(x - dr.left, 4, dr.width - ctx.offsetWidth - 4)}px`;
  ctx.style.top = `${y - dr.top + 2}px`;
  ctx.querySelector("button").focus({ preventScroll: true });
}
function closeMenu() { ctx.hidden = true; }
bar.addEventListener("contextmenu", e => {
  if (innerWidth < 720 || e.target.closest(".menus a")) return;
  e.preventDefault();
  const t = editing && e.target.closest(".tile");
  if (!editing) showMenu(e.clientX, e.clientY, [["Edit Bar in Place", () => beginEditing(opener)]]);
  else if (t) showMenu(e.clientX, e.clientY, [["Move Left", () => step(t, -1)], ["Move Right", () => step(t, 1)], ["Remove Widget", () => remove(t)], null, ["Finish Editing Bar", finishEditing]]);
  else showMenu(e.clientX, e.clientY, [["Finish Editing Bar", finishEditing]]);
});
bar.addEventListener("contextmenu", () => { if (!editing && bar.contains(document.activeElement)) opener = document.activeElement; }, true);
ctx.addEventListener("keydown", e => {
  const items = [...ctx.querySelectorAll("button")], k = items.indexOf(document.activeElement);
  if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); items[(k + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length].focus(); }
});

/* From the Edit section: the bar above turns into its own editor, right where you are */
tryEdit.addEventListener("click", e => {
  e.stopPropagation();
  beginEditing(tryEdit);
  bar.querySelector(".tile")?.focus({ preventScroll: true });
});
undoButton.addEventListener("click", e => { e.stopPropagation(); undo(); });
document.getElementById("edit-done").addEventListener("click", e => {
  e.stopPropagation();
  finishEditing();
});
document.addEventListener("click", e => {
  if (!ctx.hidden && !e.target.closest(".ctx")) closeMenu();
  if (adding && !e.target.closest(".addpop, .add")) closeAdd();
  if (reviewing) closeReview();
});
document.addEventListener("keydown", e => {
  if (e.key === "Escape") {
    if (reviewing) { closeReview(); return; }
    if (!ctx.hidden) { closeMenu(); return; }
    if (adding) { closeAdd(); return; }
    if (drag?.started) { settle(false); drag = null; return; }
    if (editing) finishEditing();
  } else if (editing && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z" && !e.target.closest("input")) {
    e.preventDefault();
    e.shiftKey ? redo() : undo();
  }
});
addEventListener("scroll", closeMenu, { passive: true });

/* ---------- The drawing ---------- */

/* Scrolling brings the evening: each section holds its own hour, and the hours blend in between.
   The night switch brings the night at once and keeps it. */
const sections = [...document.querySelectorAll("main > section[data-state]")];
let marks = [];
function measureMarks() {
  marks = sections.map(s => {
    const r = s.getBoundingClientRect(), top = r.top + scrollY, h = r.height, pad = Math.min(h * .25, innerHeight * .4);
    return { name: s.dataset.state, d: Number(s.dataset.dusk), top, bottom: top + h, a: top + pad, b: top + h - pad };
  });
}
const smooth = t => t * t * (3 - 2 * t);
// past the last note, the dive (see below), in laps of one island each: there is room for twelve
const dive = document.getElementById("dive"), lap = () => dive.offsetHeight / 12, laps = () => (scrollY - dive.offsetTop) / lap();
function hour() {
  // out at sea: from the night the page ends on, round to day and back to night once a round of islands
  if (!dive.hidden && laps() > 0) return { d: (1 + Math.cos(2 * Math.PI * laps() / window.Hill.islands)) / 2, name: "hero" };
  const y = scrollY + innerHeight / 2;
  let d = marks[0].d, name = marks[0].name;
  for (let i = 0; i < marks.length; i++) {
    const m = marks[i], n = marks[i + 1];
    if (y >= m.top) name = m.name;
    if (y >= m.a) d = m.d;
    if (n && y > m.b && y < n.a) d = m.d + (n.d - m.d) * smooth((y - m.b) / (n.a - m.b));
  }
  return { d, name };
}
let lastDusk = -1, lastState = "";
function updateDusk(dur) {
  if (!marks.length) return;
  const { d, name } = hour();
  const dusk = root.dataset.mode === "dark" ? 1 : d;
  if (Math.abs(dusk - lastDusk) > .001) { lastDusk = dusk; S("setDusk", dusk, dur); }
  if (name !== lastState) { lastState = name; S("setState", name); }
}

/* Words in the headline light up when the beam crosses them */
const lumens = [...document.querySelectorAll(".lumen")];
let lumRects = null;
function measureLumens() {
  lumRects = lumens.map(el => {
    const r = el.getBoundingClientRect();
    return { el, x: r.left + r.width / 2, y: r.top + r.height / 2, on: el.classList.contains("lit"), seen: r.bottom > 0 && r.top < innerHeight };
  });
}
function lightWords(s) {
  if (!lumRects) measureLumens();
  // (while the lighthouse reads the headline after the opening, the words it has lit stay lit; its weak light as it
  // wakes lights none)
  const I = s.beamI(), keep = s.readingWords(), lamp = s.lampOn() > .6 && s.lampPower() > .8;
  for (const r of lumRects) {
    const on = lamp && r.seen && s.inBeam(r.x, r.y) * (.45 + .55 * I) > .35;
    if (on !== r.on && (on || !keep)) { r.on = on; r.el.classList.toggle("lit", on); }
  }
}

/* The night switch: the moon tile on the bar and the key's Night. Starts from the system setting,
   remembers the visitor's choice, shared with the privacy and terms pages. */
const themeColor = document.querySelector('meta[name="theme-color"]');
const nightSwitches = [document.getElementById("night"), document.querySelector(".key .night")];
// (over a few seconds for the opening's sunrise: the drawing follows, and the browser's colour changes halfway)
function setMode(mode, dur) {
  root.dataset.mode = mode;
  const color = mode === "light" ? "#86cbf2" : "#232662";
  if (dur) setTimeout(() => { themeColor.content = color; }, dur * 500);
  else themeColor.content = color;
  for (const b of nightSwitches) b.setAttribute("aria-pressed", mode === "dark");
  updateDusk(dur);
}
for (const b of nightSwitches) b.addEventListener("click", e => {
  e.stopPropagation();
  const mode = root.dataset.mode === "light" ? "dark" : "light";
  localStorage.setItem("mode", mode);
  setMode(mode);
});

measureMarks();
try {
  if (window.Hill?.Scene) scene = new window.Hill.Scene(document.getElementById("scene"), { topInset: restHeight(), dusk: root.dataset.mode === "dark" ? 1 : hour().d });
} catch (err) {
  console.warn("The drawing didn't start:", err);
  scene = null;
}
root.classList.toggle("has-scene", Boolean(scene));

if (scene) {
  /* The strip behind the bar takes the colour of the sky it covers, so the bar reads over it as it does over the drawing */
  let lastSky = "";
  const lum = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255).map(c => c <= .03928 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4).reduce((a, c, i) => a + c * [.2126, .7152, .0722][i], 0);
  const skyStrip = s => {
    const sky = s.sky?.();
    if (!sky || sky === lastSky) return;
    lastSky = sky;
    dock.style.setProperty("--strip", sky);
    dock.dataset.sky = lum(sky) < .18 ? "dark" : "light";
  };
  scene.onFrame = s => {
    try { if (woken) lightWords(s); else placeSnore(s); if (woken && !rose) glowBar(s); sweepGlow(s); skyStrip(s); if (lit && s.playing) hideTour(); } catch (err) {
      if (!sceneFailed) { sceneFailed = true; console.warn("The drawing failed:", err); }
    }
  };

  /* The pointer and a finger steer the light and stir the grass, clouds and water, once the opening is over.
     On touch only a sideways drag steers; the page keeps its vertical scrolling (touch-action: pan-y). */
  addEventListener("pointermove", e => { if (landed) S("pointer", e.clientX, e.clientY, e.pointerType); }, { passive: true });
  addEventListener("pointerdown", e => { if (landed) S("pointer", e.clientX, e.clientY, e.pointerType); }, { passive: true });
  addEventListener("pointerup", e => { if (e.pointerType !== "mouse") S("release"); }, { passive: true });
  addEventListener("pointercancel", () => S("release"), { passive: true });
  let swipe = null;
  addEventListener("touchstart", e => { const t = e.touches[0]; swipe = t && { x: t.clientX, y: t.clientY, side: null }; }, { passive: true });
  addEventListener("touchmove", e => {
    const t = e.touches[0];
    if (!t || !swipe) return;
    if (swipe.side === null && Math.hypot(t.clientX - swipe.x, t.clientY - swipe.y) > 8) swipe.side = Math.abs(t.clientX - swipe.x) > Math.abs(t.clientY - swipe.y);
    if (swipe.side && landed) S("pointer", t.clientX, t.clientY, "touch");
  }, { passive: true });
  addEventListener("touchend", () => { swipe = null; S("release"); }, { passive: true });
  addEventListener("touchcancel", () => { swipe = null; S("release"); }, { passive: true });
  root.addEventListener("mouseleave", () => S("release"));
  addEventListener("blur", () => S("release"));

  /* A click or tap on the landscape, not on the page, drops something there.
     A click that only closes a popup or a menu doesn't, nor one that ends the opening. */
  let overlay = false, pressedInOpening = false;
  addEventListener("pointerdown", () => { pressedInOpening = !landed; }, true);
  document.addEventListener("click", () => { overlay = Boolean(openId || adding || !ctx.hidden || reviewing); }, true);
  document.addEventListener("click", e => {
    if (overlay || editing || e.detail === 0 || !landed || pressedInOpening) return;
    if (e.target.closest("a, button, input, label, pre, .note, .dock, [role='dialog']")) return;
    if (String(getSelection?.() || "")) return;
    S("tap", e.clientX, e.clientY);
  });

  /* The key's buttons drop the same surprises, for keyboards and screen readers too; Play ball starts the game */
  for (const b of document.querySelectorAll("[data-drop]")) b.addEventListener("click", () => S("surprise", b.dataset.drop));
  for (const b of document.querySelectorAll("[data-play]")) b.addEventListener("click", () => { hideTour(); S("play"); });
  scene.onBar = onBar;

  /* Past the last note the page goes on: once it has gone, scrolling takes you on over the sea, past the far island
     and the ones beyond it (see ISLANDS in scene.js), through day and night (see hour). Well into the second round
     of islands the page steps back a round, which looks the same, so it never ends; and as soon as you turn back, it
     steps back to have its own hill just behind you, so the page is never more than an island away. The drawing and
     the bar take the theme of the island you're heading to (onBar), and the visitor's again back on the page. */
  if (!reduce.matches) {
    const round = window.Hill.islands;
    let was = scrollY;
    const diving = () => {
      const n = laps(), back = n >= round + 2 ? round : scrollY < was ? S("behind") : 0;
      if (back) scrollTo(0, scrollY - back * lap());
      was = scrollY;
      S("setDive", Math.max(0, n - back), back);
    };
    dive.hidden = false;
    addEventListener("scroll", diving, { passive: true });
    diving();
  }
}

/* ---------- The lighthouse plays with the bar ----------
   The ball hits a widget and it hops; a workspace number also takes the focus, as a click would, which lights
   its beach hut. The bored lighthouse shoves one widget aside and puts it back. Nothing else changes:
   Download never navigates, the night switch never toggles, and every hop is gone in half a second. */
const widgetFor = key => key.startsWith("ws:") ? bar.querySelector(`#gl .wsi[data-ws="${key.slice(3)}"]`) : bar.querySelector(`:scope > .g > .w[data-key="${CSS.escape(key)}"]`);
let shove = null;
function unshove(quick) {
  const s = shove;
  if (!s) return;
  shove = null;
  if (!reduce.matches && s.el.isConnected) s.el.animate([{ transform: s.to }, { transform: "none" }], { duration: quick ? 240 : 760, easing: quick ? "cubic-bezier(.3, 0, .2, 1)" : "cubic-bezier(.45, 0, .25, 1)" }).finished.then(() => { if (shove?.el !== s.el) s.el.style.zIndex = ""; }, () => {});
  else s.el.style.zIndex = "";
  s.a.cancel();
}
function onBar(event, key, info = {}) {
  if (event === "release") return unshove(info.caught);
  // out at sea, the bar goes over to the next island's theme as the drawing's does, the visitor's pick left alone
  if (event === "theme") { barTheme(key); return fit(); }
  const el = !editing && widgetFor(key);
  if (!el) return;
  if (event === "bump") {
    if (key.startsWith("ws:")) focusWorkspace(Number(key.slice(3)));
    if (!reduce.matches) el.animate([
      { transform: "none" },
      { transform: "translateY(-6px) rotate(-3deg)", offset: .26, easing: "ease-in" },
      { transform: "translateY(1px) scale(1.04, .94)", offset: .52 },
      { transform: "translateY(-1.5px) rotate(.6deg)", offset: .74 },
      { transform: "none" },
    ], { duration: 520, easing: "ease-out" });
  } else if (event === "nudge" && !reduce.matches) {
    unshove(true);
    const dx = info.dx || 14, to = `translateX(${dx}px) rotate(${Math.sign(dx) * 3}deg)`;
    el.style.zIndex = "3";
    shove = { el, to, a: el.animate([{ transform: "none" }, { transform: to }], { duration: 620, easing: "cubic-bezier(.3, 1.5, .5, 1)", fill: "forwards" }) };
  }
}

/* The opening: a title card over the whole drawing with the bar big in the middle of it, at night, the lighthouse
   asleep and the drawing still. After a while it wakes up and strains to light its lamp, and its light finds the
   card's bar, weak and unsteady, and crosses it. Then the day comes, and with it the page: the card's bar stretches up
   into its place at the top, the card drifts away and the notes come in, while the lighthouse blinks its light out
   and strains again.
   Its light comes on for good as the headline comes in: it reads it, sweeps along the bar and looks at you (WAKE in
   scene.js). On every load at the top, with motion allowed (the class and the night come from the page's head); until
   the page has come in, a scroll, a key, a click or a tap hurries it in, the lighthouse awake. */
let landed = !root.classList.contains("intro"), woken = landed, rose = landed, runTimer = 0, landTimer = 0, barIn = null;
const swept = new Map();
const opening = document.getElementById("opening"), snore = document.getElementById("snore");
const LAND_SKIP = ["wheel", "keydown", "pointerdown", "touchstart", "scroll"];
const DAWN = 1.6; // seconds from night to day
const HURRY = 2; // times as fast as the show plays once hurried
const WAKE_AT = 1100, RISE_AFTER = 3600; // ms: asleep for a while, then awake at night, until the day comes
// it wakes into the day, or into the night when that's the visitor's choice on the night switch
const dayMode = () => localStorage.getItem("mode") === "dark" ? "dark" : "light";
// the page has come in: at the end of the sunrise, or at once with the lighthouse awake
function land(skip) {
  if (landed) return;
  landed = true;
  clearTimeout(runTimer);
  clearTimeout(landTimer);
  for (const type of LAND_SKIP) removeEventListener(type, hurry, true);
  removeEventListener("visibilitychange", skipHidden);
  if (skip) { root.classList.add("intro-skip"); setMode(dayMode()); }
  root.classList.remove("intro", "op-bar-in", "op-page-in");
  opening.remove();
  measureMarks();
  lumRects = null;
  sendBar(); // the bar's widgets where they stand, for the sweep and the ball game
  S("labels", true);
  if (skip) { wakeUp(true); requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove("intro-skip"))); }
  setTimeout(quietSpell); // the bored lighthouse's quiet spell starts now (not before the page's script has run)
}
// hurried: the lighthouse is awake at once and the rest of the show plays HURRY times as fast, the bar easing out at
// once if it hasn't left yet; once it's at the top, only its fade into the real bar is left, which keeps its pace
// (a click or a tap that hurries it doesn't also drop something on the landscape: see pressedInOpening)
function hurry() {
  for (const type of LAND_SKIP) removeEventListener(type, hurry, true);
  clearTimeout(runTimer);
  wakeUp(true);
  if (!rose) rise(true);
  clearTimeout(landTimer);
  if (!root.classList.contains("op-bar-in")) for (const a of opening.getAnimations({ subtree: true })) a.updatePlaybackRate(HURRY);
  root.classList.add("op-page-in");
  barIn.then(() => land(false));
}
// nobody watching: it comes in rather than play on unseen
function skipHidden() { if (document.hidden) land(true); }
// it wakes up: the z's go, the drawing comes to life, the eye opens and it strains to light its lamp on the card's
// bar, until the day comes (WAKE in scene.js); brought in at once (now), it's simply awake, even halfway through the
// show
function wakeUp(now) {
  if (woken) { if (now === true) S("doze", false, true); return; }
  woken = true;
  snore.classList.add("gone");
  setTimeout(() => { root.classList.remove("asleep"); snore.remove(); }, 400);
  S("freeze", false);
  S("doze", false, now === true);
  if (now === true) return;
  const tiles = [...opening.querySelectorAll(".op-bar .w")].map(el => el.getBoundingClientRect()).filter(r => r.width), a = tiles[0], b = tiles.at(-1);
  if (a) S("lightBar", a.left + a.width / 2, a.top + a.height / 2, b.left + b.width / 2, b.top + b.height / 2);
  runTimer = setTimeout(rise, RISE_AFTER);
}
// then the day comes, and with it the page: the bar rises into place while the sky, the sun and the moon turn and the
// card changes with them; the lighthouse puts its weak light out, and its light comes on for good on the headline
function rise(fast) {
  if (landed) return;
  if (document.hidden) return land(true);
  const ends = headlineEnds();
  rose = true;
  for (const t of glowTiles || []) t.el.style.removeProperty("--glow"); // (its weak light goes out: see glowBar)
  expandOpening(fast);
  setMode(dayMode(), fast ? DAWN / HURRY : DAWN);
  S("rising", ...(ends || []));
  landTimer = setTimeout(() => land(false), DAWN * 1000 + 100);
}
// the headline's first and last words in view, where they'll stand once the notes are in (they come in from a
// little lower: .intro .hero in style.css)
function headlineEnds() {
  const note = lumens[0]?.closest(".hero > *"), dy = note ? parseFloat(getComputedStyle(note).translate.split(" ")[1]) || 0 : 0;
  const seen = lumens.map(el => el.getBoundingClientRect()).filter(r => r.bottom - dy > 0 && r.top - dy < innerHeight);
  if (!seen.length) return null;
  const a = seen[0], b = seen.at(-1);
  return [a.left + a.width / 2 - 10, a.top + a.height / 2 - dy, b.left + b.width / 2 + 10, b.top + b.height / 2 - dy];
}
/* The card's bar at night: each of its widgets glows as brightly as the lighthouse's weak light on it, fading just
   after the light has passed (--glow, in style.css) */
let glowTiles = null;
function glowBar(s) {
  const p = s.lampOn() * s.lampPower();
  if (!glowTiles) {
    if (p <= 0) return;
    glowTiles = [...opening.querySelectorAll(".op-bar .w")].map(el => { const r = el.getBoundingClientRect(); return { el, x: r.left + r.width / 2, y: r.top + r.height / 2, trail: 0, k: 0 }; });
  }
  for (const t of glowTiles) {
    t.trail = Math.max(s.inBeam(t.x, t.y), t.trail * .9);
    const k = Math.round(Math.min(1, t.trail * p * 1.6) * 50) / 50;
    if (k !== t.k) { t.k = k; t.el.style.setProperty("--glow", k); }
  }
}
// the sleeper's z's, by its lamp wherever the drawing has put it
let snoreAt = "";
function placeSnore(s) {
  const p = s.lampAt(), size = Math.max(12, p.r * 1.1), key = `${Math.round(p.x)} ${Math.round(p.y)} ${Math.round(size)}`;
  if (key === snoreAt) return;
  snoreAt = key;
  snore.style.cssText = `left: ${p.x + p.r * 2}px; top: ${p.y - p.r * 0.4 - size / 2}px; --zs: ${size}px`;
}
/* The card's bar stretches into the real one, as the day comes: a copy of it leaves the card and grows to the
   window's width as it rises to the top, shrinking to the real bar's height, its widgets sliding apart as it widens.
   The card's words drift away, the notes come in while it rises, and at the top the real bar fades in under it and
   the copy fades away. The copy is made before the day comes, so its colours change with the sky's */
function expandOpening(fast) {
  const pill = opening.querySelector(".op-bar"), a = pill.getBoundingClientRect(), b = bar.getBoundingClientRect(), k = b.height / a.height;
  const fly = pill.cloneNode(true);
  fly.classList.add("op-fly");
  opening.append(fly);
  getComputedStyle(fly).backgroundColor;
  pill.style.visibility = "hidden";
  const grow = fly.animate([
    { left: `${a.left}px`, top: `${a.top}px`, width: `${a.width}px`, transform: "scale(1)", borderRadius: "22px" },
    { left: `${b.left}px`, top: `${b.top}px`, width: `${b.width / k}px`, transform: `scale(${k})`, borderRadius: "0px" },
  ], { duration: 1100, easing: fast ? ease : "cubic-bezier(.45, 0, .25, 1)", fill: "forwards" });
  for (const el of opening.querySelectorAll(".op-mark, .op-line")) el.animate([{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(-28px)" }], { duration: 600, easing: "ease-in", fill: "forwards" });
  setTimeout(() => { if (!landed) root.classList.add("op-page-in"); }, 650);
  barIn = grow.finished.then(() => {
    if (landed) return;
    root.classList.add("op-bar-in");
    return fly.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 340, fill: "forwards" }).finished;
  }, () => {});
}
/* While the light sweeps the bar, each widget it passes glows for a moment */
function sweepGlow(s) {
  const now = performance.now();
  if (s.sweepingBar()) for (const w of bar.querySelectorAll(".w[data-key]")) {
    if (w.hidden || w.classList.contains("over") || !w.offsetWidth) continue;
    const r = w.getBoundingClientRect();
    if (s.inBeam(r.left + r.width / 2, r.top + r.height / 2) > .45) { w.classList.add("swept"); swept.set(w, now + 420); }
  }
  for (const [w, until] of swept) if (now > until) { w.classList.remove("swept"); swept.delete(w); }
}
if (!landed) {
  if (scrollY > 0 || document.hidden) land(true);
  else {
    for (const type of LAND_SKIP) addEventListener(type, hurry, { capture: true, passive: true });
    addEventListener("visibilitychange", skipHidden);
    S("labels", false);
    S("doze", true); // asleep, its eye shut and its lamp out,
    S("freeze", true); // and the whole drawing still,
    runTimer = setTimeout(wakeUp, WAKE_AT); // for a moment
  }
} else { opening.remove(); snore.remove(); }

/* The lamp-lit tour, for pointers that hover: the widget under the pointer takes the lamp's glow (the beam
   already follows the pointer) and a paper tag hangs under it on a string. Keyboard focus shows it too.
   It waits while the ball is in play, and never shows while editing, dragging or a popup is open. */
const tag = document.getElementById("lamp-tag");
const tagPaper = tag.querySelector(".lt-p"), tagText = tag.querySelector(".lt-t"), tagString = [...tag.querySelectorAll(".lt-s path")];
const TAGS = {
  ws: "four little rooms", apple: "still there", app: "Finder’s, for now", site: "this website, dressed as an app",
  np: "the lighthouse hums along", meeting: "the keeper is late", system: "all calm", sound: "shh, the sheep are asleep",
  battery: "the lamp runs on oil", clock: "always on time, unlike the keeper", dl: "the only serious button",
  moon: "the lamp’s favourite", more: "the ones that didn’t fit",
};
const canHover = matchMedia("(hover: hover)");
let lit = null, tourShow = 0, tourHide = 0;
const tourWidget = el => { const w = el?.closest?.(".w[data-key]"); return w && bar.contains(w) && !w.closest(".lane") && TAGS[w.dataset.key] ? w : null; };
const tourOK = () => scene && !editing && !openId && !drag && !adding && ctx.hidden && !scene.playing && !bar.classList.contains("swap");
function showTour(w) {
  clearTimeout(tourShow);
  clearTimeout(tourHide);
  if (!tourOK()) return;
  const again = Boolean(lit);
  lit?.classList.remove("lamp");
  lit = w;
  w.classList.add("lamp");
  tagText.textContent = TAGS[w.dataset.key];
  tagPaper.style.setProperty("--r", `${(w.dataset.key.length * 7 % 5 - 2) * .7}deg`);
  tag.hidden = false;
  placeTag();
  if (!reduce.matches) tag.animate(again
    ? [{ transform: "rotate(7deg)" }, { transform: "rotate(-3deg)", offset: .45 }, { transform: "none" }]
    : [{ transform: "rotate(-16deg)", opacity: 0 }, { transform: "rotate(10deg)", opacity: 1, offset: .28 }, { transform: "rotate(-5deg)", offset: .52 }, { transform: "rotate(2deg)", offset: .76 }, { transform: "none" }],
  { duration: again ? 420 : 850, easing: "ease-out" });
}
/* The tag hangs from the middle of the widget's bottom edge; the paper keeps inside the window and the
   string goes through a hole above the widget, wherever the paper ends up */
function placeTag() {
  const r = lit.getBoundingClientRect(), cx = r.left + r.width / 2, len = 13, pw = tagPaper.offsetWidth;
  const left = clamp(cx - pw / 2, 8, innerWidth - pw - 8) - cx, hole = clamp(-left, 14, pw - 14);
  tag.style.left = `${cx}px`;
  tag.style.top = `${r.bottom - 1}px`;
  tagPaper.style.left = `${left}px`;
  tagPaper.style.top = `${len}px`;
  tagPaper.style.setProperty("--hole", `${hole}px`);
  const hx = left + hole, hy = len + 7.5;
  for (const p of tagString) p.setAttribute("d", `M0 -1C${hx * .2 + 1.8} ${hy * .4} ${hx * .75 - 1.4} ${hy * .62} ${hx} ${hy}`);
}
function hideTour() {
  clearTimeout(tourShow);
  clearTimeout(tourHide);
  if (!lit) return;
  lit.classList.remove("lamp");
  lit = null;
  tag.hidden = true;
}
bar.addEventListener("pointerover", e => {
  if (e.pointerType === "touch" || !canHover.matches) return;
  const w = tourWidget(e.target);
  if (!w) return;
  clearTimeout(tourHide);
  if (w === lit) return;
  clearTimeout(tourShow);
  if (lit) showTour(w);
  else tourShow = setTimeout(() => showTour(w), 240);
});
bar.addEventListener("pointerout", e => {
  const w = tourWidget(e.target);
  if (!w || w.contains(e.relatedTarget)) return;
  clearTimeout(tourShow);
  if (w === lit) tourHide = setTimeout(hideTour, 140);
});
bar.addEventListener("focusin", e => { const w = tourWidget(e.target); if (w && e.target.matches(":focus-visible")) showTour(w); });
bar.addEventListener("focusout", e => { if (lit && !lit.contains(e.relatedTarget) && !lit.matches(":hover")) hideTour(); });

/* The bored lighthouse: once a visit, after a quiet spell with no pointer, scroll or key, and nothing open,
   counted from the end of the opening. The scene checks the rest (motion allowed, the lamp in view, no game on,
   its light not busy); any input catches it. */
let boredTimer = 0, boredDone = false;
function quietSpell() {
  clearTimeout(boredTimer);
  if (!scene || boredDone || !landed) return;
  boredTimer = setTimeout(function check() {
    const calm = !editing && !openId && !adding && ctx.hidden && !reviewing && !lit && !document.hidden && !reduce.matches;
    if (calm && S("bored")) boredDone = true;
    else boredTimer = setTimeout(check, 4000);
  }, 12000);
}

/* ---------- The pen: every note, Download button, tag and key button gets a felt-pen outline,
   drawn at its size in three slightly different states that the CSS steps through (the boil).
   Inline SVG paths rather than images, so an outline never counts as the page's largest paint. ---------- */
const INK = ".note, .cta, .tag, .keys button, .w.dl, .lt-p";
const hash = n => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
const noise = x => { const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return (hash(i) + (hash(i + 1) - hash(i)) * u) * 2 - 1; };
const r1 = v => Math.round(v * 10) / 10;
const PAD = 8;

/* The torn top of the notebook page: one tooth every 12 px or so, the same each time */
function teeth(W, seed) {
  const n = Math.max(6, Math.round(W / 12)), out = [];
  for (let i = 0; i <= n; i++) out.push([W * i / n, 2 + 8 * hash(seed + i * 1.7) * (i % 2 ? 1 : .45)]);
  return out;
}
/* The centre line of an outline, clockwise, starting a little way along the top */
function perimeter(W, H, shape, radii, seed) {
  const pts = [], step = 6;
  const seg = (ax, ay, bx, by) => {
    const n = Math.max(1, Math.round(Math.hypot(bx - ax, by - ay) / step));
    for (let i = 0; i < n; i++) pts.push([ax + (bx - ax) * i / n, ay + (by - ay) * i / n]);
  };
  const arc = (cx, cy, r, a0, a1) => {
    const n = Math.max(2, Math.round(r * Math.abs(a1 - a0) / step));
    for (let i = 0; i < n; i++) { const a = a0 + (a1 - a0) * i / n; pts.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]); }
  };
  const [tl, tr, br, bl] = radii.map(r => Math.min(r, W / 2, H / 2));
  const x0 = PAD, y0 = PAD, x1 = PAD + W, y1 = PAD + H, Q = Math.PI / 2;
  if (shape === "torn") {
    const top = teeth(W, seed).map(([x, y]) => [x0 + x, y0 + y]);
    for (let i = 0; i < top.length - 1; i++) seg(...top[i], ...top[i + 1]);
    seg(x1, top.at(-1)[1], x1, y1 - br); arc(x1 - br, y1 - br, br, 0, Q);
    seg(x1 - br, y1, x0 + bl, y1); arc(x0 + bl, y1 - bl, bl, Q, 2 * Q);
    seg(x0, y1 - bl, x0, top[0][1]);
    for (let i = 0; i < 3; i++) pts.push(top[i]);
    return pts;
  }
  const sx = x0 + tl + (W - tl - tr) * (.12 + .2 * hash(seed));
  seg(sx, y0, x1 - tr, y0); arc(x1 - tr, y0 + tr, tr, -Q, 0);
  seg(x1, y0 + tr, x1, y1 - br); arc(x1 - br, y1 - br, br, 0, Q);
  seg(x1 - br, y1, x0 + bl, y1); arc(x0 + bl, y1 - bl, bl, Q, 2 * Q);
  seg(x0, y1 - bl, x0, y0 + tl); arc(x0 + tl, y0 + tl, tl, 2 * Q, 3 * Q);
  seg(x0 + tl, y0, Math.min(sx + 26, x1 - tr), y0);
  return pts;
}
/* A felt-pen stroke: a ribbon that wobbles a little, swells and thins, and tapers where the pen lifts.
   The three boil states share the shape and differ only in the fine jitter. */
function outline(W, H, shape, radii, seed, boil, weight) {
  const c = perimeter(W, H, shape, radii, seed), n = c.length, L = [], R = [], j = seed + boil * 9.1;
  for (let i = 0; i < n; i++) {
    const [ax, ay] = c[Math.max(0, i - 1)], [bx, by] = c[Math.min(n - 1, i + 1)];
    const len = Math.hypot(bx - ax, by - ay) || 1, nx = -(by - ay) / len, ny = (bx - ax) / len;
    const off = noise(i * .031 + seed * 7.7) * 1.4 + noise(i * .21 + j * 3.1) * .55;
    const ends = Math.min(1, (i + 1) / 7, (n - i) / 6);
    const w = weight * (.8 + .22 * noise(i * .07 + seed * 5.3 + 40) + .1 * noise(i * .3 + j * 2.3)) * (.3 + .7 * ends) / 2;
    const [x, y] = c[i];
    L.push([x + nx * (off + w), y + ny * (off + w)]);
    R.push([x + nx * (off - w), y + ny * (off - w)]);
  }
  const ring = [...L, ...R.reverse()];
  let d = `M${r1(ring[0][0])} ${r1(ring[0][1])}`;
  for (let i = 1; i < ring.length; i++) {
    const [x, y] = ring[i], [nx, ny] = ring[(i + 1) % ring.length];
    d += `Q${r1(x)} ${r1(y)} ${r1((x + nx) / 2)} ${r1((y + ny) / 2)}`;
  }
  return `${d}Z`;
}
function ink(el, seed) {
  const W = el.offsetWidth, H = el.offsetHeight;
  if (!W || !H || el.dataset.inkSize === `${W}x${H}`) return;
  el.dataset.inkSize = `${W}x${H}`;
  const shape = el.dataset.ink === "torn" ? "torn" : el.matches(".cta, .keys button, .w.dl") ? "pill" : "rect";
  const cs = getComputedStyle(el);
  const radii = shape === "pill" ? [H / 2, H / 2, H / 2, H / 2]
    : [cs.borderTopLeftRadius, cs.borderTopRightRadius, cs.borderBottomRightRadius, cs.borderBottomLeftRadius].map(v => parseFloat(v) || 0);
  const weight = el.matches(".note") ? 2.9 : el.matches(".w.dl, .lt-p") ? 2.1 : 2.5;
  let svg = el.querySelector(":scope > .pen");
  if (!svg) {
    svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "pen");
    svg.setAttribute("aria-hidden", "true");
    el.append(svg);
  }
  svg.setAttribute("viewBox", `0 0 ${W + PAD * 2} ${H + PAD * 2}`);
  svg.innerHTML = [0, 1, 2].map(k => `<path class="p${k}" d="${outline(W, H, shape, radii, seed, k, weight)}"/>`).join("");
  if (shape === "torn") el.style.setProperty("--torn", `polygon(${teeth(W, seed).map(([x, y]) => `${r1(x)}px ${r1(y)}px`).join(", ")}, 100% 100%, 0 100%)`);
  el.classList.add("inked");
}
const inked = [...document.querySelectorAll(INK)];
const seeds = new Map(inked.map((el, i) => [el, 1 + i * 2.3]));
const pen = new ResizeObserver(entries => { for (const e of entries) ink(e.target, seeds.get(e.target)); });
for (const el of inked) pen.observe(el);

/* The boil rests after a few quiet seconds, like the drawing */
let idleTimer = 0, lastWake = -1e9;
function wake() {
  const now = performance.now();
  if (now - lastWake < 250) return;
  lastWake = now;
  root.classList.remove("idle");
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => root.classList.add("idle"), 6000);
  S("poke");
  quietSpell();
}
for (const type of ["pointermove", "pointerdown", "keydown", "scroll", "wheel", "touchstart"]) addEventListener(type, wake, { passive: true });
wake();

/* ---------- Start ---------- */
let queued = false;
addEventListener("scroll", () => {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    dockState(true);
    updateDusk();
    lumRects = null;
  });
}, { passive: true });
addEventListener("resize", () => {
  hideTour();
  fit();
  dockState();
  measureMarks();
  updateDusk();
  lumRects = null;
  S("setTopInset", restHeight());
});
document.fonts.ready.then(() => {
  fit();
  measureMarks();
  updateDusk();
  lumRects = null;
});
setMode(root.dataset.mode);
setTheme("built-in");
focusWorkspace(2);
fit();
dockState();
updateDusk();
})();
