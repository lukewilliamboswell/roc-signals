import { readFileSync } from "node:fs";
import { gzipSync, brotliCompressSync, constants } from "node:zlib";

// This helper only measures bytes. Roc owns the inventory, recorded figures,
// tolerance, build decisions and diagnostics. Files are compressed as shipped.
// Brotli is the checked figure; gzip is reported only, because its output
// depends on the deflate library this Node was built with. The libraries are
// named on stderr so a reader can tell two measurements apart.
process.stderr.write(
  `compressor: node ${process.version}, brotli ${process.versions.brotli}, zlib ${process.versions.zlib}\n`,
);
for (const file of process.argv.slice(2)) {
  const bytes = readFileSync(file);
  const gzip = gzipSync(bytes, { level: 9 });
  const brotli = brotliCompressSync(bytes, {
    params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
  });
  process.stdout.write(`${file}\t${bytes.length}\t${gzip.length}\t${brotli.length}\n`);
}
