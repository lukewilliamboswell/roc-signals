app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Tx : { rows : List(U64), n : U64 }

# One higher-order function that every message goes through.
on_rows : Tx, (List(U64), U64 -> { rows : List(U64), n : U64 }) -> Tx
on_rows = |tx, f| {
    { rows, n } = tx
    f(rows, n)
}

Msg : [Touch(U64), Swap]

step : Tx, Msg -> Tx
step = |tx, msg| match msg {
    Touch(k) => on_rows(tx, |rows, n| { rows: rows.set(k, n) ?? rows, n: n + 1 })
    Swap => on_rows(tx, |rows, n| if rows.len() > 998 { rows: (rows.set(1, 9) ?? rows), n } else { rows, n })
}

step2 : Tx, Msg -> Tx
step2 = |tx, msg| match msg {
    Touch(k) => on_rows(tx, |rows, n| { rows: rows.set(k, n) ?? rows, n: n + 1 })
    Swap => on_rows(tx, |rows, n| { rows: (rows.set(1, 9) ?? rows), n })
}

run! : Str => Str
run! = |input| {
    len = 10_000 + Str.count_utf8_bytes(input)
    msg = if Str.count_utf8_bytes(input) > 100 { Swap } else { Touch(3) }

    b1 = Host.alloc_count!()
    var $a = { rows: List.repeat(0, len), n: 0 }
    var $i = 0
    while $i < 1000 {
        $a = step($a, msg)
        $i = $i + 1
    }
    c1 = Host.alloc_count!() - b1

    b2 = Host.alloc_count!()
    var $b = { rows: List.repeat(0, len), n: 0 }
    $i = 0
    while $i < 1000 {
        $b = step2($b, msg)
        $i = $i + 1
    }
    c2 = Host.alloc_count!() - b2

    "1000 Touch messages: with conditional sibling ${c1.to_str()} allocations, without ${c2.to_str()} allocations"
}
