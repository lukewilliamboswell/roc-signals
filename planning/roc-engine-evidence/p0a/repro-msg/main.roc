app [target] { fuzz: platform "../fuzzpf/main.roc" }

import fuzz.Fuzz

# Repro: one closure in a lambda set that reads its site argument and may
# return it unchanged makes a *different* closure in the same set copy the
# site's list, although that closure owns the only reference.

Site := { rows : List(U64), n : U64 }.{
    len : Site -> U64
    len = |site| site.rows.len()

    write : Site, U64 -> Site
    write = |site, k| {
        { rows, n } = site
        Site.{ rows: rows.set(k, n) ?? crash "k", n: n + 1 }
    }
}

Tx : { site : Site, other : Site, tick : U64 }

Msg : [Write(U64), MaybeWrite(U64)]

on_site : Tx, (Site, U64 -> { site : Site, tick : U64 }) -> Tx
on_site = |tx, f| {
    { site, other, tick } = tx
    r = f(site, tick)
    { site: r.site, other, tick: r.tick }
}

upd_ok : Tx, Msg -> Tx
upd_ok = |tx, msg| match msg {
    Write(k) => on_site(tx, |s, t| { site: s.write(k), tick: t + 1 })
    MaybeWrite(k) => on_site(tx, |s, t| { site: s.write(k), tick: t + 1 })
}

# Identical, except MaybeWrite reads `s` and may return it unchanged.
upd_bad : Tx, Msg -> Tx
upd_bad = |tx, msg| match msg {
    Write(k) => on_site(tx, |s, t| { site: s.write(k), tick: t + 1 })
    MaybeWrite(k) => on_site(tx, |s, t| if s.len() > k { site: s.write(k), tick: t + 1 } else { site: s, tick: t })
}

make : U64 -> Tx
make = |size| { site: Site.{ rows: List.repeat(0, size), n: 0 }, other: Site.{ rows: [], n: 0 }, tick: 0 }

test! : U64 => Fuzz.Outcome
test! = |size| {
    if size < 10 or size > 100_000 {
        return Fuzz.reject
    }
    msgs : List(Msg)
    msgs = [Write(1), Write(2)]
    var $a = make(size)
    for m in msgs {
        w = Fuzz.start_measure!("ok-write")
        $a = upd_ok($a, m)
        _ = w.finish!()
    }
    var $b = make(size)
    for m in msgs {
        w = Fuzz.start_measure!("bad-write")
        $b = upd_bad($b, m)
        _ = w.finish!()
    }
    if $a.tick + $b.tick != 4 {
        crash "tick"
    }
    Fuzz.keep
}

target = Fuzz.target_with!({
    name: "repro-lambda-set-borrow",
    examples: [
        Fuzz.example({ name: "1k", revision: "1", make: || 1000 }),
        Fuzz.example({ name: "10k", revision: "1", make: || 10000 }),
    ],
    generator: Fuzz.u64_in(10, 1000),
    test!,
    show: Str.inspect,
})
