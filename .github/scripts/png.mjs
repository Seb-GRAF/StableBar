// Reads and writes the PNG files the before/after screens compare: 8-bit RGB or RGBA without
// interlacing, which is what StableBar's renders and headless Chrome write. No dependencies.
import zlib from "node:zlib";

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
/** The largest image decodePNG takes, before inflating anything: a long website page is about 2880 by 12000. */
const limits = { maxWidth: 20000, maxHeight: 100000, maxPixels: 80_000_000 };

function paeth(a, b, c) {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body));
  return Buffer.concat([length, body, crc]);
}

/**
 * The pixels of a PNG as `{width, height, rgba}`, every pixel four bytes. It throws for an image larger
 * than its limits, a chunk cut short, or image data that doesn't inflate to exactly the image's size.
 */
export function decodePNG(input, { maxWidth = limits.maxWidth, maxHeight = limits.maxHeight, maxPixels = limits.maxPixels } = {}) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
  if (buffer.length < 8 || !buffer.subarray(0, 8).equals(signature)) throw new Error("Unsupported PNG: no PNG signature.");
  let offset = 8, width = 0, height = 0, bitDepth = 0, colorType = -1, interlace = -1;
  const data = [];
  while (offset + 8 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    if (offset + 12 + length > buffer.length) throw new Error("Unsupported PNG: a chunk is cut short.");
    const type = buffer.toString("latin1", offset + 4, offset + 8);
    const body = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      bitDepth = body[8];
      colorType = body[9];
      interlace = body[12];
    } else if (type === "IDAT") {
      data.push(body);
    } else if (type === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  if (!width || !height || bitDepth !== 8 || (colorType !== 2 && colorType !== 6) || interlace !== 0) {
    throw new Error("Unsupported PNG: only 8-bit RGB or RGBA without interlacing.");
  }
  if (width > maxWidth || height > maxHeight || width * height > maxPixels) {
    throw new Error(`Unsupported PNG: ${width}×${height} is larger than it takes.`);
  }
  const channels = colorType === 6 ? 4 : 3;
  const stride = width * channels;
  let raw;
  try {
    raw = zlib.inflateSync(Buffer.concat(data), { maxOutputLength: height * (stride + 1) });
  } catch (error) {
    throw new Error(`Unsupported PNG: its image data doesn't inflate to its size (${error.code ?? error.message}).`);
  }
  if (raw.length < height * (stride + 1)) throw new Error("Unsupported PNG: the image data is cut short.");
  const pixels = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    if (filter > 4) throw new Error(`Unsupported PNG: unknown filter ${filter}.`);
    const line = y * (stride + 1) + 1;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? pixels[y * stride + x - channels] : 0;
      const b = y > 0 ? pixels[(y - 1) * stride + x] : 0;
      const c = x >= channels && y > 0 ? pixels[(y - 1) * stride + x - channels] : 0;
      const predicted = filter === 0 ? 0 : filter === 1 ? a : filter === 2 ? b : filter === 3 ? (a + b) >> 1 : paeth(a, b, c);
      pixels[y * stride + x] = (raw[line + x] + predicted) & 255;
    }
  }
  if (channels === 4) return { width, height, rgba: pixels };
  const rgba = new Uint8Array(width * height * 4);
  for (let index = 0; index < width * height; index++) {
    rgba[index * 4] = pixels[index * 3];
    rgba[index * 4 + 1] = pixels[index * 3 + 1];
    rgba[index * 4 + 2] = pixels[index * 3 + 2];
    rgba[index * 4 + 3] = 255;
  }
  return { width, height, rgba };
}

/** An RGBA PNG of `{width, height, rgba}`. */
export function encodePNG({ width, height, rgba }) {
  const stride = width * 4;
  const raw = Buffer.alloc(height * (stride + 1));
  for (let y = 0; y < height; y++) {
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([signature, chunk("IHDR", header), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}
