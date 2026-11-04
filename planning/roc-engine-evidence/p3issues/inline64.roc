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

write_5 : List(U8), U64 -> List(U8)
write_5 = |buf, x| put_u32(buf.append(5), x * 5)

write_6 : List(U8), U64 -> List(U8)
write_6 = |buf, x| put_u32(buf.append(6), x * 6)

write_7 : List(U8), U64 -> List(U8)
write_7 = |buf, x| put_u32(buf.append(7), x * 7)

write_8 : List(U8), U64 -> List(U8)
write_8 = |buf, x| put_u32(buf.append(8), x * 8)

write_9 : List(U8), U64 -> List(U8)
write_9 = |buf, x| put_u32(buf.append(9), x * 9)

write_10 : List(U8), U64 -> List(U8)
write_10 = |buf, x| put_u32(buf.append(10), x * 10)

write_11 : List(U8), U64 -> List(U8)
write_11 = |buf, x| put_u32(buf.append(11), x * 11)

write_12 : List(U8), U64 -> List(U8)
write_12 = |buf, x| put_u32(buf.append(12), x * 12)

write_13 : List(U8), U64 -> List(U8)
write_13 = |buf, x| put_u32(buf.append(13), x * 13)

write_14 : List(U8), U64 -> List(U8)
write_14 = |buf, x| put_u32(buf.append(14), x * 14)

write_15 : List(U8), U64 -> List(U8)
write_15 = |buf, x| put_u32(buf.append(15), x * 15)

write_16 : List(U8), U64 -> List(U8)
write_16 = |buf, x| put_u32(buf.append(16), x * 16)

write_17 : List(U8), U64 -> List(U8)
write_17 = |buf, x| put_u32(buf.append(17), x * 17)

write_18 : List(U8), U64 -> List(U8)
write_18 = |buf, x| put_u32(buf.append(18), x * 18)

write_19 : List(U8), U64 -> List(U8)
write_19 = |buf, x| put_u32(buf.append(19), x * 19)

write_20 : List(U8), U64 -> List(U8)
write_20 = |buf, x| put_u32(buf.append(20), x * 20)

write_21 : List(U8), U64 -> List(U8)
write_21 = |buf, x| put_u32(buf.append(21), x * 21)

write_22 : List(U8), U64 -> List(U8)
write_22 = |buf, x| put_u32(buf.append(22), x * 22)

write_23 : List(U8), U64 -> List(U8)
write_23 = |buf, x| put_u32(buf.append(23), x * 23)

write_24 : List(U8), U64 -> List(U8)
write_24 = |buf, x| put_u32(buf.append(24), x * 24)

write_25 : List(U8), U64 -> List(U8)
write_25 = |buf, x| put_u32(buf.append(25), x * 25)

write_26 : List(U8), U64 -> List(U8)
write_26 = |buf, x| put_u32(buf.append(26), x * 26)

write_27 : List(U8), U64 -> List(U8)
write_27 = |buf, x| put_u32(buf.append(27), x * 27)

write_28 : List(U8), U64 -> List(U8)
write_28 = |buf, x| put_u32(buf.append(28), x * 28)

write_29 : List(U8), U64 -> List(U8)
write_29 = |buf, x| put_u32(buf.append(29), x * 29)

write_30 : List(U8), U64 -> List(U8)
write_30 = |buf, x| put_u32(buf.append(30), x * 30)

write_31 : List(U8), U64 -> List(U8)
write_31 = |buf, x| put_u32(buf.append(31), x * 31)

write_32 : List(U8), U64 -> List(U8)
write_32 = |buf, x| put_u32(buf.append(32), x * 32)

write_33 : List(U8), U64 -> List(U8)
write_33 = |buf, x| put_u32(buf.append(33), x * 33)

write_34 : List(U8), U64 -> List(U8)
write_34 = |buf, x| put_u32(buf.append(34), x * 34)

write_35 : List(U8), U64 -> List(U8)
write_35 = |buf, x| put_u32(buf.append(35), x * 35)

write_36 : List(U8), U64 -> List(U8)
write_36 = |buf, x| put_u32(buf.append(36), x * 36)

write_37 : List(U8), U64 -> List(U8)
write_37 = |buf, x| put_u32(buf.append(37), x * 37)

write_38 : List(U8), U64 -> List(U8)
write_38 = |buf, x| put_u32(buf.append(38), x * 38)

write_39 : List(U8), U64 -> List(U8)
write_39 = |buf, x| put_u32(buf.append(39), x * 39)

write_40 : List(U8), U64 -> List(U8)
write_40 = |buf, x| put_u32(buf.append(40), x * 40)

write_41 : List(U8), U64 -> List(U8)
write_41 = |buf, x| put_u32(buf.append(41), x * 41)

write_42 : List(U8), U64 -> List(U8)
write_42 = |buf, x| put_u32(buf.append(42), x * 42)

write_43 : List(U8), U64 -> List(U8)
write_43 = |buf, x| put_u32(buf.append(43), x * 43)

write_44 : List(U8), U64 -> List(U8)
write_44 = |buf, x| put_u32(buf.append(44), x * 44)

write_45 : List(U8), U64 -> List(U8)
write_45 = |buf, x| put_u32(buf.append(45), x * 45)

write_46 : List(U8), U64 -> List(U8)
write_46 = |buf, x| put_u32(buf.append(46), x * 46)

write_47 : List(U8), U64 -> List(U8)
write_47 = |buf, x| put_u32(buf.append(47), x * 47)

write_48 : List(U8), U64 -> List(U8)
write_48 = |buf, x| put_u32(buf.append(48), x * 48)

write_49 : List(U8), U64 -> List(U8)
write_49 = |buf, x| put_u32(buf.append(49), x * 49)

write_50 : List(U8), U64 -> List(U8)
write_50 = |buf, x| put_u32(buf.append(50), x * 50)

write_51 : List(U8), U64 -> List(U8)
write_51 = |buf, x| put_u32(buf.append(51), x * 51)

write_52 : List(U8), U64 -> List(U8)
write_52 = |buf, x| put_u32(buf.append(52), x * 52)

write_53 : List(U8), U64 -> List(U8)
write_53 = |buf, x| put_u32(buf.append(53), x * 53)

write_54 : List(U8), U64 -> List(U8)
write_54 = |buf, x| put_u32(buf.append(54), x * 54)

write_55 : List(U8), U64 -> List(U8)
write_55 = |buf, x| put_u32(buf.append(55), x * 55)

write_56 : List(U8), U64 -> List(U8)
write_56 = |buf, x| put_u32(buf.append(56), x * 56)

write_57 : List(U8), U64 -> List(U8)
write_57 = |buf, x| put_u32(buf.append(57), x * 57)

write_58 : List(U8), U64 -> List(U8)
write_58 = |buf, x| put_u32(buf.append(58), x * 58)

write_59 : List(U8), U64 -> List(U8)
write_59 = |buf, x| put_u32(buf.append(59), x * 59)

write_60 : List(U8), U64 -> List(U8)
write_60 = |buf, x| put_u32(buf.append(60), x * 60)

write_61 : List(U8), U64 -> List(U8)
write_61 = |buf, x| put_u32(buf.append(61), x * 61)

write_62 : List(U8), U64 -> List(U8)
write_62 = |buf, x| put_u32(buf.append(62), x * 62)

write_63 : List(U8), U64 -> List(U8)
write_63 = |buf, x| put_u32(buf.append(63), x * 63)

write_64 : List(U8), U64 -> List(U8)
write_64 = |buf, x| put_u32(buf.append(64), x * 64)

run! : Str => Str
run! = |input| {
	x = input.count_utf8_bytes().to_u64()
	var $b = []
	$b = write_1($b, x)
	$b = write_2($b, x)
	$b = write_3($b, x)
	$b = write_4($b, x)
	$b = write_5($b, x)
	$b = write_6($b, x)
	$b = write_7($b, x)
	$b = write_8($b, x)
	$b = write_9($b, x)
	$b = write_10($b, x)
	$b = write_11($b, x)
	$b = write_12($b, x)
	$b = write_13($b, x)
	$b = write_14($b, x)
	$b = write_15($b, x)
	$b = write_16($b, x)
	$b = write_17($b, x)
	$b = write_18($b, x)
	$b = write_19($b, x)
	$b = write_20($b, x)
	$b = write_21($b, x)
	$b = write_22($b, x)
	$b = write_23($b, x)
	$b = write_24($b, x)
	$b = write_25($b, x)
	$b = write_26($b, x)
	$b = write_27($b, x)
	$b = write_28($b, x)
	$b = write_29($b, x)
	$b = write_30($b, x)
	$b = write_31($b, x)
	$b = write_32($b, x)
	$b = write_33($b, x)
	$b = write_34($b, x)
	$b = write_35($b, x)
	$b = write_36($b, x)
	$b = write_37($b, x)
	$b = write_38($b, x)
	$b = write_39($b, x)
	$b = write_40($b, x)
	$b = write_41($b, x)
	$b = write_42($b, x)
	$b = write_43($b, x)
	$b = write_44($b, x)
	$b = write_45($b, x)
	$b = write_46($b, x)
	$b = write_47($b, x)
	$b = write_48($b, x)
	$b = write_49($b, x)
	$b = write_50($b, x)
	$b = write_51($b, x)
	$b = write_52($b, x)
	$b = write_53($b, x)
	$b = write_54($b, x)
	$b = write_55($b, x)
	$b = write_56($b, x)
	$b = write_57($b, x)
	$b = write_58($b, x)
	$b = write_59($b, x)
	$b = write_60($b, x)
	$b = write_61($b, x)
	$b = write_62($b, x)
	$b = write_63($b, x)
	$b = write_64($b, x)
	$b.len().to_str()
}
