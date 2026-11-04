app [target] { fuzz: platform "../fuzzpf/main.roc" }

import fuzz.Fuzz

Input : { rep : U8, n : U64 }

put_str_concat : List(U8), Str -> List(U8)
put_str_concat = |buf, s| buf.concat(s.to_utf8())

put_str_iter : List(U8), Str -> List(U8)
put_str_iter = |buf, s| {
    var $b = buf
    for byte in s.iter_utf8() {
        $b = $b.append(byte)
    }
    $b
}

put_u32 : List(U8), U32 -> List(U8)
put_u32 = |buf, v| buf.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

test! : Input => Fuzz.Outcome
test! = |{ rep, n }| {
    small = "short ${n.to_str()}"
    big = "a much longer label that will not fit inline ${n.to_str()}"
    buf0 = List.with_capacity(4096)
    if rep == 0 {
        w = Fuzz.start_measure!("concat-small")
        b1 = put_str_concat(buf0, small)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("concat-big")
        b2 = put_str_concat(b1, big)
        _ = w2.finish!()
        if b2.len() == 0 { crash "x" }
        Fuzz.keep
    } else if rep == 1 {
        w = Fuzz.start_measure!("iter-small")
        b1 = put_str_iter(buf0, small)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("iter-big")
        b2 = put_str_iter(b1, big)
        _ = w2.finish!()
        if b2.len() == 0 { crash "x" }
        Fuzz.keep
    } else {
        w = Fuzz.start_measure!("u32")
        b1 = put_u32(buf0, n.to_u32_wrap())
        _ = w.finish!()
        if b1.len() != 4 { crash "x" }
        Fuzz.keep
    }
}

target = Fuzz.target_with!({
    name: "probe2",
    examples: [
        Fuzz.example({ name: "concat", revision: "1", make: || { rep: 0, n: 5 } }),
        Fuzz.example({ name: "iter", revision: "1", make: || { rep: 1, n: 5 } }),
        Fuzz.example({ name: "u32", revision: "1", make: || { rep: 2, n: 5 } }),
    ],
    generator: { rep: Fuzz.u8_in(0, 2), n: Fuzz.u64 }.Fuzz,
    test!,
    show: Str.inspect,
})
