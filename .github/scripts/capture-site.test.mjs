import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileFor, origin } from "./capture-site.mjs";

test("fileFor answers requests from the site folder only", () => {
  const root = mkdtempSync(join(tmpdir(), "site-"));
  mkdirSync(join(root, "site", "images"), { recursive: true });
  const site = join(root, "site");
  writeFileSync(join(site, "index.html"), "<p>home</p>");
  writeFileSync(join(site, "images", "a b.webp"), "image");
  writeFileSync(join(root, "secret.txt"), "secret");
  symlinkSync(join(root, "secret.txt"), join(site, "leak.txt"));
  symlinkSync(join(site, "index.html"), join(site, "home.html"));
  const real = realpathSync(site);
  assert.equal(fileFor(site, `${origin}/`), join(real, "index.html"));
  assert.equal(fileFor(site, `${origin}/index.html?x=1#top`), join(real, "index.html"));
  assert.equal(fileFor(site, `${origin}/images/a%20b.webp`), join(real, "images", "a b.webp"));
  assert.equal(fileFor(site, `${origin}/home.html`), join(real, "index.html"));
  assert.equal(fileFor(site, `${origin}/leak.txt`), null);
  assert.equal(fileFor(site, `${origin}/missing.html`), null);
  assert.equal(fileFor(site, `${origin}/images`), null);
  assert.equal(fileFor(site, `${origin}/%2e%2e/secret.txt`), null);
  assert.equal(fileFor(site, `${origin}/..%2fsecret.txt`), null);
  assert.equal(fileFor(site, `${origin}/%E0%A4%A`), null);
  assert.equal(fileFor(site, "https://stablebar.app/index.html"), null);
});
