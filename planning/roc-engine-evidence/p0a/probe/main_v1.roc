app [target] { fuzz: platform "../fuzzpf/main.roc" }

import fuzz.Fuzz

Row : { id : U64, label : Str, selected : Bool }
Todo : { done : Bool, title : Str, n : U64 }

# Representation A: one erased record of closures per site, capturing typed rows.
Site := [Site({ set_label : U64, Str -> Site, len : () -> U64 })]

bench_site : List(Row) -> Site
bench_site = |rows| Site.Site({
    set_label: |i, label| {
        row = rows.get(i) ?? crash "missing row"
        bench_site(rows.set(i, { ..row, label }) ?? crash "missing row")
    },
    len: || rows.len(),
})

todo_site : List(Todo) -> Site
todo_site = |todos| Site.Site({
    set_label: |i, title| {
        t = todos.get(i) ?? crash "missing todo"
        todo_site(todos.set(i, { ..t, title }) ?? crash "missing todo")
    },
    len: || todos.len(),
})

site_set : Site, U64, Str -> Site
site_set = |Site(fns), i, label| (fns.set_label)(i, label)

# Representation B: hand-written union.
USite : [Bench(List(Row)), Todos(List(Todo))]

usite_set : USite, U64, Str -> USite
usite_set = |site, i, label| match site {
    Bench(rows) => {
        row = rows.get(i) ?? crash "missing row"
        Bench(rows.set(i, { ..row, label }) ?? crash "missing row")
    }
    Todos(todos) => {
        t = todos.get(i) ?? crash "missing"
        Todos(todos.set(i, { ..t, title: label }) ?? crash "missing")
    }
}

make_rows : U64 -> List(Row)
make_rows = |n| {
    var $rows = List.with_capacity(n)
    var $i = 0.U64
    while $i < n {
        $rows = $rows.append({ id: $i, label: "row label number ${$i.to_str()}", selected: False })
        $i = $i + 1
    }
    $rows
}

make_todos : U64 -> List(Todo)
make_todos = |n| {
    var $t = List.with_capacity(n)
    var $i = 0.U64
    while $i < n {
        $t = $t.append({ done: False, title: "todo", n: $i })
        $i = $i + 1
    }
    $t
}

ErasedState : { sites : List(Site), tick : U64 }
UnionState : { sites : List(USite), tick : U64 }

erased_update : ErasedState, U64, U64, Str -> ErasedState
erased_update = |{ sites, tick }, s, i, label| {
    taken = sites.replace(s, todo_site([])) ?? crash "missing site"
    next = site_set(taken.prev, i, label)
    { sites: taken.list.set(s, next) ?? crash "missing site", tick: tick + 1 }
}

union_update : UnionState, U64, U64, Str -> UnionState
union_update = |{ sites, tick }, s, i, label| {
    taken = sites.replace(s, Todos([])) ?? crash "missing site"
    next = usite_set(taken.prev, i, label)
    { sites: taken.list.set(s, next) ?? crash "missing site", tick: tick + 1 }
}

Input : { rep : U8, size : U64 }

test! : Input => Fuzz.Outcome
test! = |{ rep, size }| {
    if size > 200_000 or size < 2 { return Fuzz.reject }
    label = "a label longer than twenty-four bytes"
    if rep == 0 {
        state0 = { sites: [bench_site(make_rows(size)), todo_site(make_todos(size))], tick: 0 }
        w = Fuzz.start_measure!("erased-update-1")
        s1 = erased_update(state0, 0, 1, label)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("erased-update-2")
        s2 = erased_update(s1, 1, 1, label)
        _ = w2.finish!()
        w3 = Fuzz.start_measure!("erased-update-3")
        s3 = erased_update(s2, 0, 1, label)
        _ = w3.finish!()
        if s3.sites.len() != 2 { crash "bad" }
        Fuzz.keep
    } else if rep == 1 {
        state0 = { sites: [Bench(make_rows(size)), Todos(make_todos(size))], tick: 0 }
        w = Fuzz.start_measure!("union-update-1")
        s1 = union_update(state0, 0, 1, label)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("union-update-2")
        s2 = union_update(s1, 1, 1, label)
        _ = w2.finish!()
        w3 = Fuzz.start_measure!("union-update-3")
        s3 = union_update(s2, 0, 1, label)
        _ = w3.finish!()
        if s3.sites.len() != 2 { crash "bad" }
        Fuzz.keep
    } else {
        rows0 = make_rows(size)
        w = Fuzz.start_measure!("plain-update-1")
        row = rows0.get(1) ?? crash "x"
        rows1 = rows0.set(1, { ..row, label }) ?? crash "x"
        _ = w.finish!()
        if rows1.len() != size { crash "bad" }
        Fuzz.keep
    }
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, rep, size| Fuzz.example({ name, revision: "1", make: || { rep, size } })

target = Fuzz.target_with!({
    name: "erasure-probe",
    examples: [
        ex("erased-1k", 0, 1000), ex("erased-10k", 0, 10000), ex("erased-100k", 0, 100000),
        ex("union-1k", 1, 1000), ex("union-10k", 1, 10000), ex("union-100k", 1, 100000),
        ex("plain-1k", 2, 1000), ex("plain-10k", 2, 10000), ex("plain-100k", 2, 100000),
    ],
    generator: { rep: Fuzz.u8_in(0, 2), size: Fuzz.u64_in(2, 2000) }.Fuzz,
    test!,
    show: Str.inspect,
})
