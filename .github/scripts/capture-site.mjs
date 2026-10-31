// Captures the website for the before/after comparison: node capture-site.mjs SITE OUT
// Each page of the SITE folder at desktop and phone size, full page, to OUT/<page>-<size>.png, and the
// home page in dark mode too, to OUT/index-<size>-dark.png. Requests are answered from the folder,
// without a server, and nothing else is fetched. Motion is reduced and the clock is fixed at Thursday
// 22 October 2026, 09:41 UTC, so two captures of one commit match. Playwright is resolved from the
// working folder; STABLEBAR_CAPTURE_CHANNEL=chrome uses the installed Chrome instead of its Chromium.
import { createRequire } from "node:module";
import { mkdirSync, statSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

export const origin = "http://stablebar.test";
const shots = [
  ...["index", "privacy", "terms", "404"].map((page) => ({ page, scheme: "light", suffix: "" })),
  { page: "index", scheme: "dark", suffix: "-dark" },
];
const sizes = {
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
};
const fixedTime = new Date("2026-10-22T09:41:00Z");

/** The file in the `root` folder that `url` asks for, or null when it asks for none. */
export function fileFor(root, url) {
  const { origin: asked, pathname } = new URL(url);
  if (asked !== origin) return null;
  let path;
  try {
    path = resolve(root, `.${decodeURIComponent(pathname)}`);
  } catch {
    return null;
  }
  const file = pathname.endsWith("/") ? join(path, "index.html") : path;
  if (!file.startsWith(resolve(root) + sep)) return null;
  try {
    return statSync(file).isFile() ? file : null;
  } catch {
    return null;
  }
}

/** Waits for the fonts and for every image to load and decode; a broken image fails the capture. */
async function settle(tab) {
  await tab.waitForLoadState("networkidle");
  const broken = await tab.evaluate(async () => {
    await document.fonts.ready;
    const images = [...document.images];
    for (const image of images) image.loading = "eager";
    const results = await Promise.all(images.map((image) => image.decode().then(() => null, () => image.getAttribute("src"))));
    return results.filter(Boolean);
  });
  if (broken.length > 0) throw new Error(`${tab.url()}: these images didn't load: ${broken.join(", ")}`);
}

export async function capture(site, out, { channel } = {}) {
  const root = resolve(site);
  const { chromium } = createRequire(join(process.cwd(), "capture-site.cjs"))("playwright");
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch(channel ? { channel } : {});
  try {
    for (const [size, options] of Object.entries(sizes)) {
      for (const scheme of ["light", "dark"]) {
        const context = await browser.newContext({ ...options, colorScheme: scheme, reducedMotion: "reduce", locale: "en-US", timezoneId: "UTC" });
        await context.route("**/*", (route) => {
          const url = route.request().url();
          const file = fileFor(root, url);
          if (file) return route.fulfill({ path: file });
          return url.startsWith(`${origin}/`) ? route.fulfill({ status: 404, body: "" }) : route.abort();
        });
        for (const { page, suffix } of shots.filter((shot) => shot.scheme === scheme)) {
          const tab = await context.newPage();
          await tab.clock.setFixedTime(fixedTime);
          await tab.goto(`${origin}/${page}.html`, { waitUntil: "load" });
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
