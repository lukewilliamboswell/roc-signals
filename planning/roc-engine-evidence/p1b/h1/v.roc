app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Row : { id : U64, label : Str }

# V1: one constructor, record of two closures both capturing rows, get then set.
S1 := [S1({ set : U64, Str -> S1, len : () -> U64 })]
s1 : List(Row) -> S1
s1 = |rows| S1.S1({
    set: |i, label| {
        row = rows.get(i) ?? { id: 0, label: "" }
        s1(rows.set(i, { ..row, label }) ?? rows)
    },
    len: || rows.len(),
})
s1_set : S1, U64, Str -> S1
s1_set = |S1(fs), i, l| (fs.set)(i, l)

# V2: like V1 but only one closure, no get.
S2 := [S2((U64, Str -> S2))]
s2 : List(Row) -> S2
s2 = |rows| S2.S2(|i, label| s2(rows.set(i, { id: i, label }) ?? rows))
s2_set : S2, U64, Str -> S2
s2_set = |S2(f), i, l| f(i, l)

# V3: like V2 with get then set.
S3 := [S3((U64, Str -> S3))]
s3 : List(Row) -> S3
s3 = |rows| S3.S3(|i, label| {
    row = rows.get(i) ?? { id: 0, label: "" }
    s3(rows.set(i, { ..row, label }) ?? rows)
})
s3_set : S3, U64, Str -> S3
s3_set = |S3(f), i, l| f(i, l)

# V4: like V2 but two constructors of different element types share the lambda set.
S4 := [S4((U64, Str -> S4))]
s4 : List(Row) -> S4
s4 = |rows| S4.S4(|i, label| s4(rows.set(i, { id: i, label }) ?? rows))
s4b : List(Str) -> S4
s4b = |strs| S4.S4(|i, label| s4b(strs.set(i, label) ?? strs))
s4_set : S4, U64, Str -> S4
s4_set = |S4(f), i, l| f(i, l)

make : U64 -> List(Row)
make = |n| {
    var $rows = List.with_capacity(n)
    var $i = 0.U64
    while $i < n {
        $rows = $rows.append({ id: $i, label: "row label number ${$i.to_str()}" })
        $i = $i + 1
    }
    $rows
}

run! : Str => Str
run! = |input| {
    n = 10_000 + Str.count_utf8_bytes(input)
    label = "a label longer than twenty-four bytes"

    r1 = make(n)
    b1 = Host.alloc_count!()
    var $a = s1(r1)
    var $i = 0
    while $i < 100 {
        $a = s1_set($a, $i, label)
        $i = $i + 1
    }
    c1 = Host.alloc_count!() - b1

    r2 = make(n)
    b2 = Host.alloc_count!()
    var $b = s2(r2)
    $i = 0
    while $i < 100 {
        $b = s2_set($b, $i, label)
        $i = $i + 1
    }
    c2 = Host.alloc_count!() - b2

    r3 = make(n)
    b3 = Host.alloc_count!()
    var $c = s3(r3)
    $i = 0
    while $i < 100 {
        $c = s3_set($c, $i, label)
        $i = $i + 1
    }
    c3 = Host.alloc_count!() - b3

    r4 = make(n)
    b4 = Host.alloc_count!()
    var $d = if n > 5 { s4(r4) } else { s4b([]) }
    $i = 0
    while $i < 100 {
        $d = s4_set($d, $i, label)
        $i = $i + 1
    }
    c4 = Host.alloc_count!() - b4

    "100 updates each: V1 ${c1.to_str()}, V2 ${c2.to_str()}, V3 ${c3.to_str()}, V4 ${c4.to_str()}"
}
