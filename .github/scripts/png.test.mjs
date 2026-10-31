import { test } from "node:test";
import assert from "node:assert/strict";
import zlib from "node:zlib";
import { decodePNG, encodePNG } from "./png.mjs";

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body));
  return Buffer.concat([length, body, crc]);
}

function paeth(a, b, c) {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

/** An 8-bit RGB PNG whose every scanline uses `filter`. */
function rgbPNG(width, height, rgb, filter) {
  const stride = width * 3;
  const raw = [];
  for (let y = 0; y < height; y++) {
    raw.push(filter);
    for (let x = 0; x < stride; x++) {
      const a = x >= 3 ? rgb[y * stride + x - 3] : 0;
      const b = y > 0 ? rgb[(y - 1) * stride + x] : 0;
      const c = x >= 3 && y > 0 ? rgb[(y - 1) * stride + x - 3] : 0;
      const predicted = [0, a, b, (a + b) >> 1, paeth(a, b, c)][filter];
      raw.push((rgb[y * stride + x] - predicted) & 255);
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(Buffer.from(raw))), chunk("IEND", Buffer.alloc(0))]);
}

test("encodePNG and decodePNG round-trip RGBA pixels", () => {
  const rgba = Uint8Array.from([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 9, 8, 7, 6, 1, 2, 3, 4, 250, 251, 252, 253]);
  const decoded = decodePNG(encodePNG({ width: 3, height: 2, rgba }));
  assert.equal(decoded.width, 3);
  assert.equal(decoded.height, 2);
  assert.deepEqual([...decoded.rgba], [...rgba]);
});

test("decodePNG reads RGB scanlines with every filter as opaque RGBA", () => {
  const width = 4, height = 3;
  const rgb = Array.from({ length: width * height * 3 }, (_, index) => (index * 37 + 11) % 256);
  const expected = [];
  for (let pixel = 0; pixel < width * height; pixel++) expected.push(...rgb.slice(pixel * 3, pixel * 3 + 3), 255);
  for (const filter of [0, 1, 2, 3, 4]) {
    const decoded = decodePNG(rgbPNG(width, height, rgb, filter));
    assert.deepEqual([...decoded.rgba], expected, `filter ${filter}`);
  }
});

test("decodePNG rejects what isn't an 8-bit RGB or RGBA PNG", () => {
  assert.throws(() => decodePNG(Buffer.from("not a png")), /Unsupported PNG/);
});
