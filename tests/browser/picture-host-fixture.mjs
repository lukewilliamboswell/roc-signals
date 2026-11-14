// Test-owned declarations and a tiny real Wasm module. No Roc compiler or app
// supplies these protocol18 fixtures or the observable init-call counter.
import { protocolFixtureSection } from "./protocol-fixture.mjs";
export const word = n => [n & 255, n >>> 8 & 255, n >>> 16 & 255, n >>> 24];
const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
export const pictureDeclarations = [section(2, word(0)), section(5, word(0)), section(6, word(0)), section(10, [110, 1]), section(11, word(0)), [...protocolFixtureSection]].flat();
const leb = n => { const out = []; do { const byte = n & 127; n >>>= 7; out.push(byte | (n ? 128 : 0)); } while (n); return out; };
const text = value => { const b = [...new TextEncoder().encode(value)]; return [...leb(b.length), ...b]; };
const vector = values => [...leb(values.length), ...values.flat()];
const part = (tag, bytes) => [tag, ...leb(bytes.length), ...bytes];
export function pictureHostModule({ dropTrap = false } = {}) {
  const names = ["protocol_version", "boot_keys", "cmd_ptr", "cmd_len", "payload_reserve", "init", "files_released", "fault", "work_len", "metric", "drop", "init_calls"];
  const bodies = [[0x41, 18], [0x41, 0, 0x24, 0, 0x41, ...leb(pictureDeclarations.length), 0x24, 1], [0x23, 0], [0x23, 1], [0x41, ...leb(65536)],
    [0x23, 2, 0x41, 1, 0x6a, 0x24, 2, 0x41, ...leb(16384), 0x24, 0, 0x41, 1, 0x24, 1], [0x41, 0], [0x41, 0], [0x41, 0], [0x42, 0], dropTrap ? [0x00] : [], [0x23, 2]].map(code => { const body = [0, ...code, 0x0b]; return [...leb(body.length), ...body]; });
  const bytes = Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0,
    ...part(1, vector([[0x60, 0, 1, 0x7f], [0x60, 0, 0], [0x60, 1, 0x7f, 1, 0x7f], [0x60, 0, 1, 0x7e]])),
    ...part(3, vector([0, 1, 0, 0, 2, 1, 0, 0, 0, 3, 1, 0].map(n => [n]))), ...part(5, [1, 0, 2]),
    ...part(6, vector([0, 0, 0].map(() => [0x7f, 1, 0x41, 0, 0x0b]))),
    ...part(7, vector([...names.map((name, i) => [...text(name), 0, ...leb(i)]), [...text("memory"), 2, 0]])), ...part(10, vector(bodies)),
    ...part(11, [1, 0, 0x41, 0, 0x0b, ...leb(pictureDeclarations.length), ...pictureDeclarations]),
  ]);
  if (!WebAssembly.validate(bytes)) throw new Error("invalid test-owned picture module");
  return bytes;
}
