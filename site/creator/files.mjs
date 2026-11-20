import { RESERVED_IDS, fileText, isVersion, validateThemeColors } from "./theme.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const linkPrefix = "stablebar://theme?";
const maximumLength = 65_536;
const maximumFileBytes = 32_768;
const maximumDepth = 32;
const maximumProfiles = 16;
const maximumValues = 372;
export const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/;
const themeKeys = new Set(["tokens", "defaults", "popupDefaults", "groupDefaults", "roles", "workspaceDefaults", "bar", "groups", "profiles"]);
// Keep this list aligned with ThemeLinkCandidate’s appearance-only bar properties.
const barProperties = new Set([
  "height", "margin", "inset", "spacing", "background", "style", "divider", "notchWidth", "notchSpacing", "fillNotch", "popupOffset", "glass",
]);
const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const withoutBOM = text => text.startsWith("\ufeff") ? text.slice(1) : text;
const fail = reason => { throw new Error(reason); };

function checkID(id, { allowReserved = false } = {}) {
  if (typeof id !== "string" || !ID_PATTERN.test(id)) {
    fail("invalidID");
  }
  if (!allowReserved && RESERVED_IDS.has(id.toLowerCase())) fail("reservedID");
}

function checkManifest(manifest, options) {
  checkID(manifest.id, options);
  if (typeof manifest.name !== "string" || !manifest.name.trim()) fail("invalidName");
  if (!isVersion(manifest.version)) fail("invalidVersion");
  for (const key of ["description", "author", "screenshot", "minimumVersion"]) {
    if (manifest[key] != null && typeof manifest[key] !== "string") fail(key === "minimumVersion" ? "invalidMinimumVersion" : "damaged");
  }
  if (manifest.repository != null) {
    try {
      // The app compares the scheme case by case, so "HTTPS://" is refused there too.
      if (typeof manifest.repository !== "string" || !manifest.repository.startsWith("https:")
        || new URL(manifest.repository).protocol !== "https:") fail("invalidRepository");
    } catch { fail("invalidRepository"); }
  }
}

export function themeFiles({ manifest, config }, { validate = true } = {}) {
  if (validate) checkManifest(manifest);
  const fresh = {
    id: manifest.id, name: manifest.name, version: manifest.version, kind: "theme", entry: "config.json",
  };
  for (const key of ["description", "author", "minimumVersion", "repository"]) {
    if (manifest[key] != null) fresh[key] = manifest[key];
  }
  return { manifestText: fileText(fresh), configText: fileText(config) };
}

export function parseTheme(files) {
  const manifest = parseObject(files.manifestText), config = parseObject(files.configText);
  if (manifest.kind !== "theme") fail("notTheme");
  checkManifest(manifest, { allowReserved: true });
  function check(document) {
    if (!isObject(document)) fail("damaged");
    if (Object.hasOwn(document, "includes")) fail("extraFiles");
    if (Object.keys(document).some(key => !themeKeys.has(key))) fail("notTheme");
    if (Object.hasOwn(document, "profiles")) {
      if (!Array.isArray(document.profiles)) fail("damaged");
      for (const profile of document.profiles) {
        if (!isObject(profile) || typeof profile.name !== "string" || Object.keys(profile).some(key => !["name", "enabled", "when", "configuration"].includes(key))) fail("damaged");
        if (Object.hasOwn(profile, "configuration")) check(profile.configuration);
      }
    }
  }
  check(config);
  validateThemeColors(config);
  return { manifest, config };
}

function textBytes(text) {
  if (typeof text !== "string") fail("damaged");
  const bytes = encoder.encode(text);
  if (decoder.decode(bytes) !== text) fail("damaged");
  return bytes;
}

function parseObject(text) {
  let object;
  try { object = JSON.parse(withoutBOM(text)); }
  catch { fail("damaged"); }
  if (!isObject(object)) fail("damaged");
  return object;
}

function scanJSON(text, limitProfiles, count) {
  text = withoutBOM(text);
  if (text.includes("\0") || !/^[\t\n\r ]*\{/.test(text)) fail("damaged");
  let depth = 0, inString = false, escaped = false, expectingKey = true;
  let keyStart = -1, key, inProfiles = false, profileCount = 0, inProfile = false;
  let stringStart = 0, invalidValue = false, expectingValue = true;
  const containers = [];

  // JSON.parse drops duplicate keys and accepts unpaired surrogates and overflowing numbers.
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') {
        inString = false;
        let value;
        try { value = JSON.parse(text.slice(stringStart, index + 1)); }
        catch { fail("damaged"); }
        if (decoder.decode(encoder.encode(value)) !== value) invalidValue = true;
        if (keyStart !== -1) {
          key = value;
          keyStart = -1;
        }
      }
      continue;
    }
    if (inProfiles && depth === 2) {
      if (char === ",") inProfile = false;
      else if (!/[\t\n\r \]]/.test(char) && !inProfile) {
        if (++profileCount > maximumProfiles) fail("tooManyProfiles");
        inProfile = true;
      }
    }
    if (char === '"') {
      inString = true;
      stringStart = index;
      if (expectingValue) { count.values++; expectingValue = false; }
      if (limitProfiles && depth === 1 && expectingKey) {
        keyStart = index;
        expectingKey = false;
      }
    } else if (char === "{" || char === "[") {
      count.values++;
      containers.push(char);
      expectingValue = char === "[";
      if (++depth > maximumDepth) fail("tooDeep");
      if (limitProfiles && depth === 2 && char === "[" && key === "profiles") {
        inProfiles = true;
        profileCount = 0;
        inProfile = false;
      }
    } else if (char === "}" || char === "]") {
      containers.pop();
      expectingValue = false;
      if (depth === 2 && char === "]") inProfiles = false;
      depth--;
    } else if (char === ",") {
      expectingValue = containers.at(-1) === "[";
      if (depth === 1) { expectingKey = true; key = undefined; }
    } else if (char === ":") expectingValue = true;
    else if (char === "-" || /[0-9]/.test(char)) {
      if (expectingValue) { count.values++; expectingValue = false; }
      const start = index;
      while (index + 1 < text.length && /[0-9eE+.\-]/.test(text[index + 1])) index++;
      if (!Number.isFinite(Number(text.slice(start, index + 1)))) invalidValue = true;
    } else if (!/[\t\n\r ]/.test(char) && expectingValue) {
      count.values++;
      expectingValue = false;
    }
    if (count.values > maximumValues) fail("tooManySettings");
  }
  if (depth !== 0 || inString || invalidValue) fail("damaged");
}

function checkDocuments(document, count = { profiles: 0 }) {
  if (Object.hasOwn(document, "bar")) {
    if (!isObject(document.bar)) fail("barProperty");
    if (Object.keys(document.bar).some(key => !barProperties.has(key))) fail("barProperty");
  }
  if (Object.hasOwn(document, "includes")) fail("extraFiles");
  const profiles = Object.hasOwn(document, "profiles") ? document.profiles : [];
  if (!Array.isArray(profiles)) fail("damaged");
  count.profiles += profiles.length;
  if (count.profiles > maximumProfiles) fail("tooManyProfiles");
  for (const profile of profiles) {
    if (!isObject(profile) || typeof profile.name !== "string" ||
        Object.keys(profile).some(key => !["name", "enabled", "when", "configuration"].includes(key))) fail("damaged");
    if (Object.hasOwn(profile, "configuration") && !isObject(profile.configuration)) fail("damaged");
    checkDocuments(profile.configuration ?? {}, count);
  }
}

function validateFiles(manifest, config) {
  if (manifest.length + config.length > maximumFileBytes) fail("tooLarge");
  let manifestText, configText;
  try { manifestText = decoder.decode(manifest); configText = decoder.decode(config); }
  catch { fail("damaged"); }
  const count = { values: 0 };
  scanJSON(manifestText, false, count);
  scanJSON(configText, true, count);
  parseObject(manifestText);
  checkDocuments(parseObject(configText));
  return { manifestText, configText };
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function unbase64url(text) {
  const match = /^([A-Za-z0-9_-]*)(=*)$/.exec(text);
  if (!match) fail("damaged");
  const [, value, suffix] = match;
  const padding = (4 - value.length % 4) % 4;
  if (padding === 3 || (suffix.length !== 0 && suffix.length !== padding)) fail("damaged");
  let binary;
  try { binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat(padding)); }
  catch { fail("damaged"); }
  return Uint8Array.from(binary, char => char.charCodeAt(0));
}

export function encodeLink({ manifestText, configText }) {
  const manifest = textBytes(manifestText), config = textBytes(configText);
  validateFiles(manifest, config);
  const link = `${linkPrefix}v=1&package=${base64url(manifest)}&config=${base64url(config)}`;
  if (encoder.encode(link).length > maximumLength) fail("tooLong");
  return link;
}

export function decodeLink(stringOrHash) {
  if (typeof stringOrHash !== "string") fail("damaged");
  const link = stringOrHash.startsWith("#") ? linkPrefix + stringOrHash.slice(1) : stringOrHash;
  const authority = /^stablebar:\/\/([^/?#]*)/i.exec(link)?.[1];
  if (authority === undefined) fail("damaged");
  let url, host;
  try {
    // Foundation escapes invalid URL characters instead of dropping them.
    const escaped = link.replace(/%(?![a-f0-9]{2})/gi, "%25")
      .replace(/[\u0000-\u0020\u007f]/g, char => encodeURIComponent(char));
    url = new URL(escaped);
    host = decodeURIComponent(url.hostname).toLowerCase();
  } catch { fail("damaged"); }
  if (host !== "theme") fail("damaged");
  // WHATWG URL drops an empty port separator; Foundation counts it in the link length.
  const length = encoder.encode(url.href).length + (authority.endsWith(":") ? 1 : 0);
  if (length > maximumLength) fail("tooLong");
  if (url.pathname || link.includes("#") || authority.includes("@") || url.port) fail("damaged");
  const items = new Map(["v", "package", "config"].map(name => [name, []]));
  // URLSearchParams treats '+' as a space; URLComponents keeps the literal plus.
  for (const queryItem of url.search.slice(1).split("&")) {
    const equals = queryItem.indexOf("=");
    let name, value;
    try { name = decodeURIComponent(equals < 0 ? queryItem : queryItem.slice(0, equals)); }
    catch { continue; }
    if (!items.has(name)) continue;
    try { value = equals < 0 ? null : decodeURIComponent(queryItem.slice(equals + 1)); }
    catch { value = null; }
    items.get(name).push(value);
  }
  function item(name) {
    const values = items.get(name);
    if (values.length !== 1 || values[0] === null) fail("damaged");
    return values[0];
  }
  const version = item("v");
  if (version !== "1") {
    const integer = /^[+-]?\d+$/.test(version) ? BigInt(version) : 0n;
    if (integer > 1n && integer <= 9_223_372_036_854_775_807n) fail("unsupportedVersion");
    fail("damaged");
  }
  return validateFiles(unbase64url(item("package")), unbase64url(item("config")));
}

export function shareURL(base, files) {
  return base.split("#", 1)[0] + "#" + encodeLink(files).slice(linkPrefix.length);
}

const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});

export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function writeZip(id, { manifestText, configText }) {
  checkID(id);
  const entries = [["package.json", manifestText], ["config.json", configText]].map(([name, text]) => {
    const data = textBytes(text);
    return { name: encoder.encode(`${id}/${name}`), data, crc: crc32(data) };
  });
  const dataSize = entries.reduce((sum, entry) => sum + 30 + entry.name.length + entry.data.length, 0);
  const directorySize = entries.reduce((sum, entry) => sum + 46 + entry.name.length, 0);
  if (dataSize + directorySize + 22 > 0xffffffff || entries.some(entry => entry.name.length > 0xffff)) fail("zipTooLarge");
  const bytes = new Uint8Array(dataSize + directorySize + 22);
  const view = new DataView(bytes.buffer);
  let offset = 0;
  for (const entry of entries) {
    entry.offset = offset;
    view.setUint32(offset, 0x04034b50, true);
    view.setUint16(offset + 4, 20, true);
    view.setUint16(offset + 6, 0x0800, true);
    view.setUint16(offset + 12, 33, true);
    view.setUint32(offset + 14, entry.crc, true);
    view.setUint32(offset + 18, entry.data.length, true);
    view.setUint32(offset + 22, entry.data.length, true);
    view.setUint16(offset + 26, entry.name.length, true);
    bytes.set(entry.name, offset + 30);
    bytes.set(entry.data, offset + 30 + entry.name.length);
    offset += 30 + entry.name.length + entry.data.length;
  }
  for (const entry of entries) {
    view.setUint32(offset, 0x02014b50, true);
    view.setUint16(offset + 4, 20, true);
    view.setUint16(offset + 6, 20, true);
    view.setUint16(offset + 8, 0x0800, true);
    view.setUint16(offset + 14, 33, true);
    view.setUint32(offset + 16, entry.crc, true);
    view.setUint32(offset + 20, entry.data.length, true);
    view.setUint32(offset + 24, entry.data.length, true);
    view.setUint16(offset + 28, entry.name.length, true);
    view.setUint32(offset + 42, entry.offset, true);
    bytes.set(entry.name, offset + 46);
    offset += 46 + entry.name.length;
  }
  view.setUint32(offset, 0x06054b50, true);
  view.setUint16(offset + 8, entries.length, true);
  view.setUint16(offset + 10, entries.length, true);
  view.setUint32(offset + 12, directorySize, true);
  view.setUint32(offset + 16, dataSize, true);
  return bytes;
}

function safePath(path) {
  return typeof path === "string" && path.length > 0 && !path.startsWith("/") && !path.includes("\\") &&
    path.split("/").every(part => part.length > 0 && part !== "." && part !== "..");
}

export async function readZip(bytes) {
  try { return await zipFiles(bytes); }
  catch { fail("damagedZip"); }
}

async function zipFiles(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = bytes.length - 22;
  const lastPossible = Math.max(0, end - 0xffff);
  for (; end >= lastPossible; end--) {
    if (view.getUint32(end, true) === 0x06054b50 && end + 22 + view.getUint16(end + 20, true) === bytes.length) break;
  }
  if (end < lastPossible) fail("damagedZip");
  if (view.getUint16(end + 4, true) !== 0 || view.getUint16(end + 6, true) !== 0) fail("damagedZip");
  const count = view.getUint16(end + 10, true);
  if (count !== view.getUint16(end + 8, true)) fail("damagedZip");
  const directorySize = view.getUint32(end + 12, true), directoryOffset = view.getUint32(end + 16, true);
  if (directoryOffset + directorySize !== end) fail("damagedZip");
  const entries = new Map();
  let offset = directoryOffset;
  for (let index = 0; index < count; index++) {
    if (offset + 46 > end || view.getUint32(offset, true) !== 0x02014b50) fail("damagedZip");
    const nameLength = view.getUint16(offset + 28, true);
    const next = offset + 46 + nameLength + view.getUint16(offset + 30, true) + view.getUint16(offset + 32, true);
    if (next > end || view.getUint16(offset + 34, true) !== 0) fail("damagedZip");
    const name = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    if (!name.endsWith("/") && !name.split("/").some(part => part === "__MACOSX" || part.startsWith("."))) {
      if (!safePath(name) || entries.has(name)) fail("damagedZip");
      entries.set(name, {
        flags: view.getUint16(offset + 8, true), method: view.getUint16(offset + 10, true),
        crc: view.getUint32(offset + 16, true), compressedSize: view.getUint32(offset + 20, true),
        size: view.getUint32(offset + 24, true), offset: view.getUint32(offset + 42, true),
      });
    }
    offset = next;
  }
  if (offset !== end) fail("damagedZip");

  async function extract(name) {
    const entry = entries.get(name);
    if (!entry || entry.flags & 1 || ![0, 8].includes(entry.method)) fail("damagedZip");
    // Store files are limited to 1 MiB; leave room for larger local themes without unbounded inflation.
    if (entry.size > 16 * 1024 * 1024) fail("damagedZip");
    const local = entry.offset;
    if (local + 30 > directoryOffset || view.getUint32(local, true) !== 0x04034b50) fail("damagedZip");
    if (view.getUint16(local + 8, true) !== entry.method) fail("damagedZip");
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    if (start + entry.compressedSize > directoryOffset) fail("damagedZip");
    let content = bytes.slice(start, start + entry.compressedSize);
    if (entry.method === 8) {
      const stream = new Blob([content]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      const reader = stream.getReader(), chunks = [];
      let length = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.length;
          if (length > entry.size) fail("damagedZip");
          chunks.push(value);
        }
      } finally { await reader.cancel(); }
      content = new Uint8Array(length);
      let position = 0;
      for (const chunk of chunks) { content.set(chunk, position); position += chunk.length; }
    }
    if (content.length !== entry.size || crc32(content) !== entry.crc) fail("damagedZip");
    return decoder.decode(content);
  }

  return packageFiles(entries.keys(), extract);
}

async function packageFiles(paths, readText) {
  const visible = [...paths].filter(path => !path.split("/").some(part => part.startsWith(".") || part === "__MACOSX"));
  const manifests = visible.filter(path => path.split("/").at(-1) === "package.json");
  if (manifests.length !== 1) fail("damaged");
  const path = manifests[0], manifestText = await readText(path);
  const { entry } = parseObject(manifestText);
  if (!safePath(entry)) fail("damaged");
  const entryPath = path.slice(0, path.lastIndexOf("/") + 1) + entry;
  if (visible.filter(path => path === entryPath).length !== 1) fail("damaged");
  return { manifestText, configText: await readText(entryPath) };
}

export async function folderFiles(files) {
  return packageFiles(files.map(file => file.name), async name => {
    const { file } = files.find(file => file.name === name);
    if (file.size > 16 * 1024 * 1024) fail("importTooLarge");
    return file.text();
  });
}

export function readmeRow({ id, name, description }) {
  if (typeof description !== "string" || !description.trim()) fail("descriptionRequired");
  return `|  | **[${name}](packages/${id})**<br>${description} | No commands |`;
}

export async function storeManifest(id, fetchImpl = fetch) {
  checkID(id);
  try {
    const response = await fetchImpl(`https://raw.githubusercontent.com/stablebox/stablebar-packages/main/packages/${id}/package.json`);
    if (response.status === 404) return null;
    if (!response.ok) fail("storeUnavailable");
    const manifest = await response.json();
    if (!isObject(manifest) || !isVersion(manifest.version)) fail("storeUnavailable");
    return manifest;
  } catch { fail("storeUnavailable"); }
}
