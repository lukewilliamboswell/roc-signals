## Summary

Every generated non-wrapper procedure gets the `inlinehint` attribute, and nothing emits `minsize`/`optsize` under `--opt=size`. Under the `Oz` pipeline LLVM still uses the raised inline-hint threshold unless the function has `minsize`, so small helpers are copied into every caller. Source code has no way to keep a function out of line. As a result, code size grows linearly with the number of call sites of a helper, even under `--opt=size`.

This is both a bug report and a feature request: `--opt=size` should emit `minsize` (or omit `inlinehint`), and/or there should be a `noinline` escape hatch.

Compiler: `nightly-2026-11-03-34bd006`, Linux x86_64 (`x64musl`). I used the `test/alloc-count` platform from this repository.

## Where

In `src/backend/llvm/MonoLlvmCodeGen.zig` (checked against `origin/main` at 708ba9557d), both procedure-definition paths (the `(ret, args)` ABI near line 1816 and the fast ABI near line 2476) do:

```zig
if (self.enable_default_platform_diagnostics) {
    try attrs_wip.addFnAttr(.@"noinline", builder);
} else {
    if (self.inlineEverywhere(proc_id)) {
        try attrs_wip.addFnAttr(.alwaysinline, builder);
    } else {
        try attrs_wip.addFnAttr(.inlinehint, builder);
    }
}
```

The only other `noinline` is the internal `markNoInline` used for stack-checked functions. `minsize` and `optsize` appear nowhere in `src/backend/llvm`.

## Reproduction

`inlineN.roc` has one helper and N distinct one-line callers (generated; this is N=4):

```roc
app [run!] { pf: platform "./platform/main.roc" }

# A small helper: four appends plus a marker constant (0x3ADE68B1 = 987654321)
# so each emitted copy can be counted in the disassembly.
put_u32 : List(U8), U64 -> List(U8)
put_u32 = |buf, v| {
	w = (v + 987654321) % 4294967296
	buf
		.append((w % 256).to_u8_wrap())
		.append(((w // 256) % 256).to_u8_wrap())
		.append(((w // 65536) % 256).to_u8_wrap())
		.append((w // 16777216).to_u8_wrap())
}

write_1 : List(U8), U64 -> List(U8)
write_1 = |buf, x| put_u32(buf.append(1), x * 1)

write_2 : List(U8), U64 -> List(U8)
write_2 = |buf, x| put_u32(buf.append(2), x * 2)

write_3 : List(U8), U64 -> List(U8)
write_3 = |buf, x| put_u32(buf.append(3), x * 3)

write_4 : List(U8), U64 -> List(U8)
write_4 = |buf, x| put_u32(buf.append(4), x * 4)

run! : Str => Str
run! = |input| {
	x = input.count_utf8_bytes().to_u64()
	var $b = []
	$b = write_1($b, x)
	$b = write_2($b, x)
	$b = write_3($b, x)
	$b = write_4($b, x)
	$b.len().to_str()
}
```

```sh
ROC=~/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
for n in 1 4 16 64; do
  $ROC build --opt=size --no-cache --output=inline$n.bin inline$n.roc
  echo "N=$n text=$(size inline$n.bin | tail -1 | cut -f1) copies=$(objdump -d inline$n.bin | grep -ci 3ade68b1)"
done
```

## Measured (`--opt=size`)

| N callers | text bytes | copies of `put_u32` |
|---|---|---|
| 1 | 133870 | 1 |
| 4 | 135038 | 4 |
| 16 | 139694 | 16 |
| 64 | 158046 | 64 |

That is about 385 bytes per caller, almost all of it a fresh copy of `put_u32`. `--opt=speed` gives 158967 bytes and 65 copies at N=64, so `--opt=size` barely differs from `--opt=speed` here.

In the reactive UI engine this came from (a Wasm app), a four-`append` `put_u32` was inlined 141 times and a row-creation helper 9 times. The source-level workarounds cost more than they save: calling through a boxed function keeps the helper out of line but marshals every argument through memory (+14 KB), and a self-recursive guard (which LLVM will not inline) cost +36 KB in per-call-site argument marshalling.

## Expected

Under `--opt=size`, a helper with many callers should be emitted once and called. Possible fixes:

- add `minsize` (and `optsize`) to generated functions under `--opt=size`, or drop `inlinehint` in that mode so the `Oz` thresholds apply; and/or
- provide a way for source code to mark a function as not inlined.
