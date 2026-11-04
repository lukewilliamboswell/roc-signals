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
