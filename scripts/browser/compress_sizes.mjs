// Report compressed sizes for files using Node's bundled zlib.
//
// The size baseline fixes the compression implementation as well as the
// levels: Python's zlib and Node's zlib produce different gzip streams at the
// same level, so mixing them would make small artifact deltas meaningless.
// Usage: node compress_sizes.mjs FILE... -> JSON {file: {gzip, brotli}}.

import { readFileSync } from "node:fs";
import zlib from "node:zlib";

export const GZIP_LEVEL = 9;
export const BROTLI_QUALITY = 11;

export function compressedSizes(data) {
  const gzip = zlib.gzipSync(data, { level: GZIP_LEVEL }).length;
  const brotli = zlib.brotliCompressSync(data, {
    params: {
      [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_GENERIC,
      [zlib.constants.BROTLI_PARAM_QUALITY]: BROTLI_QUALITY,
    },
  }).length;
  return { gzip, brotli };
}

const files = process.argv.slice(2);
const result = {};
for (const file of files) {
  result[file] = compressedSizes(readFileSync(file));
}
process.stdout.write(JSON.stringify({
  implementation: "node-zlib",
  node: process.version,
  gzip_level: GZIP_LEVEL,
  brotli_quality: BROTLI_QUALITY,
  files: result,
}));
