app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# A list captured by a closure, updated through the closure.
Erased := [Erased({ set : U64 -> Erased, len : () -> U64 })]

erased : List(U64) -> Erased
erased = |xs| Erased.Erased({ set: |i| erased(xs.set(i, 7) ?? xs), len: || xs.len() })

erased_set : Erased, U64 -> Erased
erased_set = |Erased(fs), i| (fs.set)(i)

# The same list held in a tag union.
Plain := [Plain(List(U64))]

plain_set : Plain, U64 -> Plain
plain_set = |Plain(xs), i| Plain.Plain(xs.set(i, 7) ?? xs)

run! : Str => Str
run! = |input| {
    n = 10_000 + Str.count_utf8_bytes(input)

    xs = List.repeat(0.U64, n)
    before_erased = Host.alloc_count!()
    var $e = erased(xs)
    var $i = 0
    while $i < 1000 {
        $e = erased_set($e, $i)
        $i = $i + 1
    }
    erased_allocs = Host.alloc_count!() - before_erased

    ys = List.repeat(0.U64, n)
    before_plain = Host.alloc_count!()
    var $p = Plain.Plain(ys)
    var $j = 0
    while $j < 1000 {
        $p = plain_set($p, $j)
        $j = $j + 1
    }
    plain_allocs = Host.alloc_count!() - before_plain

    "1000 updates: erased ${erased_allocs.to_str()} allocations, plain ${plain_allocs.to_str()} allocations"
}
