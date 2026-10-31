// Captures the website for the before/after comparison: node capture-site.mjs SITE OUT
// Each page of the SITE folder at desktop and phone size, full page, in light mode to
// OUT/<page>-<size>.png and in dark mode to OUT/<page>-<size>-dark.png. Requests are answered from
// the folder, without a server, and nothing else is fetched. So that two captures of one commit
// match, motion is reduced, Math.random is seeded, and the page's clock stands at Thursday 22 October
// 2026, 09:41 UTC, moving only when the capture lets 5 seconds of timers and frames run. Playwright
// is resolved from the working folder; STABLEBAR_CAPTURE_CHANNEL=chrome uses the installed Chrome
// instead of Playwright's Chromium.
import { createRequire } from "node:module";
import { mkdirSync, realpathSync, statSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

export const origin = "http://stablebar.test";
const pages = ["index", "privacy", "terms", "404"];
const schemes = { light: "", dark: "-dark" };
const sizes = {
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
};
const fixedTime = new Date("2026-10-22T09:41:00Z");
/** How long the page's timers and animation frames run, on its stopped clock, before the capture. */
const settleTime = 5000;

/** Replaces Math.random with a seeded generator (mulberry32), in every document before its scripts. */
function seedRandom() {
  let seed = 0x5eed;
  Math.random = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let value = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * The real path of the file in the `root` folder that `url` asks for, or null when it asks for none.
 * Symbolic links count only when they lead to a file inside the folder.
 */
export function fileFor(root, url) {
  const { origin: asked, pathname } = new URL(url);
  if (asked !== origin) return null;
  try {
    const folder = realpathSync(root);
    const path = resolve(folder, `.${decodeURIComponent(pathname)}`);
    const file = realpathSync(pathname.endsWith("/") ? join(path, "index.html") : path);
    return file.startsWith(folder + sep) && statSync(file).isFile() ? file : null;
  } catch {
    return null;
  }
}

/**
 * Waits for the fonts and for every image to load and decode. A broken image is the same in every
 * capture, so it only gets a warning, and shows in the comparison.
 */
async function settle(tab) {
  await tab.waitForLoadState("networkidle");
  const broken = await tab.evaluate(async () => {
    await document.fonts.ready;
    const images = [...document.images];
    for (const image of images) image.loading = "eager";
    const results = await Promise.all(images.map((image) => image.decode().then(() => null, () => image.getAttribute("src"))));
    return results.filter(Boolean);
  });
  if (broken.length > 0) console.log(`::warning::${new URL(tab.url()).pathname}: these images don't load: ${broken.join(", ")}`);
}

export async function capture(site, out, { channel } = {}) {
  const root = resolve(site);
  const { chromium } = createRequire(join(process.cwd(), "capture-site.cjs"))("playwright");
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch(channel ? { channel } : {});
  try {
    for (const [size, options] of Object.entries(sizes)) {
      for (const [scheme, suffix] of Object.entries(schemes)) {
        const context = await browser.newContext({ ...options, colorScheme: scheme, reducedMotion: "reduce", locale: "en-US", timezoneId: "UTC" });
        await context.addInitScript(seedRandom);
        await context.route("**/*", (route) => {
          const url = route.request().url();
          const file = fileFor(root, url);
          if (file) return route.fulfill({ path: file });
          return url.startsWith(`${origin}/`) ? route.fulfill({ status: 404, body: "" }) : route.abort();
        });
        for (const page of pages) {
          const tab = await context.newPage();
          await tab.clock.install({ time: fixedTime });
          await tab.clock.pauseAt(fixedTime);
          await tab.goto(`${origin}/${page}.html`, { waitUntil: "load" });
          await settle(tab);
          await tab.clock.runFor(settleTime);
          await settle(tab);
          await tab.screenshot({ path: join(out, `${page}-${size}${suffix}.png`), fullPage: true, animations: "disabled" });
          await tab.close();
        }
        await context.close();
      }
    }
  } finally {
    await browser.close();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const [site, out] = process.argv.slice(2);
  if (!site || !out) {
    console.error("usage: capture-site.mjs SITE OUT");
    process.exit(64);
  }
  await capture(site, out, { channel: process.env.STABLEBAR_CAPTURE_CHANNEL });
}
