app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz

## Phase 1b representation probe. Every representation stores two sites with
## different row types (bench rows and todos) in one state and updates one row of
## one site. Measured: requested bytes and allocations for one update at 1k, 10k
## and 100k rows; anything proportional to the row count is a column copy.

Row : { id : U64, label : Str, selected : Bool }
Todo : { done : Bool, title : Str, n : U64 }

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

## ---------------------------------------------------------------------------
## A. 0a's erased site: a record of closures that all capture the column.
SiteA := [SiteA({ set : U64, Str -> SiteA, len : () -> U64 })]

site_a_bench : List(Row) -> SiteA
site_a_bench = |rows| SiteA.SiteA({
    set: |i, label| {
        row = rows.get(i) ?? crash "missing row"
        site_a_bench(rows.set(i, { ..row, label }) ?? crash "missing row")
    },
    len: || rows.len(),
})

site_a_todo : List(Todo) -> SiteA
site_a_todo = |todos| SiteA.SiteA({
    set: |i, title| {
        t = todos.get(i) ?? crash "missing todo"
        site_a_todo(todos.set(i, { ..t, title }) ?? crash "missing todo")
    },
    len: || todos.len(),
})

a_set : SiteA, U64, Str -> SiteA
a_set = |SiteA(fs), i, l| (fs.set)(i, l)

a_update : List(SiteA), U64, U64, Str -> List(SiteA)
a_update = |sites, s, i, label| {
    { list, prev } = sites.replace(s, site_a_todo([])) ?? crash "missing site"
    list.set(s, a_set(prev, i, label)) ?? crash "missing site"
}

## ---------------------------------------------------------------------------
## D. One closure per site. The closure captures the site's typed state and
## takes an operation; every query and update goes through it, so exactly one
## closure ever references the column. Sites nest: a group site owns a list of
## child sites and forwards a path-addressed operation.
Op := [SetLabel(U64, Str), Len, Child(U64, Box(Op))]

SiteD := [SiteD((Op -> (SiteD, U64)))]

site_d_bench : List(Row) -> SiteD
site_d_bench = |rows| SiteD.SiteD(|op|
    match op {
        SetLabel(i, label) => {
            row = rows.get(i) ?? crash "missing row"
            (site_d_bench(rows.set(i, { ..row, label }) ?? crash "missing row"), 1)
        }
        Len => {
            n = rows.len()
            (site_d_bench(rows), n)
        }
        Child(_, _) => crash "bench site has no children"
    })

site_d_todo : List(Todo) -> SiteD
site_d_todo = |todos| SiteD.SiteD(|op|
    match op {
        SetLabel(i, title) => {
            t = todos.get(i) ?? crash "missing todo"
            (site_d_todo(todos.set(i, { ..t, title }) ?? crash "missing todo"), 1)
        }
        Len => {
            n = todos.len()
            (site_d_todo(todos), n)
        }
        Child(_, _) => crash "todo site has no children"
    })

## A group site: owns heterogeneous children and its own typed counter.
site_d_group : List(SiteD), U64 -> SiteD
site_d_group = |children, hits| SiteD.SiteD(|op|
    match op {
        Child(k, inner) => {
            { list, prev } = children.replace(k, site_d_todo([])) ?? crash "missing child"
            (next, out) = d_call(prev, Box.unbox(inner))
            (site_d_group(list.set(k, next) ?? crash "missing child", hits + 1), out)
        }
        Len => (site_d_group(children, hits), children.len())
        SetLabel(_, _) => crash "group has no rows"
    })

d_call : SiteD, Op -> (SiteD, U64)
d_call = |SiteD(f), op| f(op)

d_update : List(SiteD), U64, Op -> List(SiteD)
d_update = |sites, s, op| {
    { list, prev } = sites.replace(s, site_d_todo([])) ?? crash "missing site"
    (next, _) = d_call(prev, op)
    list.set(s, next) ?? crash "missing site"
}

## ---------------------------------------------------------------------------
## C. Static composition (0a's engine): the site set is a nested generic type.
BenchC := { rows : List(Row) }.{
    site_set : BenchC, U64, U64, Str -> BenchC
    site_set = |site, _s, i, label| {
        { rows } = site
        row = rows.get(i) ?? crash "missing row"
        BenchC.{ rows: rows.set(i, { ..row, label }) ?? crash "missing row" }
    }
}

TodoC := { todos : List(Todo) }.{
    site_set : TodoC, U64, U64, Str -> TodoC
    site_set = |site, _s, i, title| {
        { todos } = site
        t = todos.get(i) ?? crash "missing"
        TodoC.{ todos: todos.set(i, { ..t, title }) ?? crash "missing" }
    }
}

Both(a, b) := { left : a, right : b }.{
    site_set : Both(a, b), U64, U64, Str -> Both(a, b)
        where [a.site_set : a, U64, U64, Str -> a, b.site_set : b, U64, U64, Str -> b]
    site_set = |both, s, i, label| {
        { left, right } = both
        if s == 0 {
            Both.{ left: left.site_set(0, i, label), right }
        } else {
            Both.{ left, right: right.site_set(s - 1, i, label) }
        }
    }
}

## ---------------------------------------------------------------------------
## E. Typed store keyed by site with a universal value type. Only the
## (rarely changing) codec is typed and erased; columns are plain data.
Value := [I(U64), S(Str), B(Bool), Rec(List(Value))]

StoreSite : { cols : List(List(Value)), arity : U64 }

row_to_cols : List(Row) -> List(List(Value))
row_to_cols = |rows| {
    var $id = List.with_capacity(rows.len())
    var $label = List.with_capacity(rows.len())
    var $sel = List.with_capacity(rows.len())
    for r in rows {
        $id = $id.append(I(r.id))
        $label = $label.append(S(r.label))
        $sel = $sel.append(B(r.selected))
    }
    [$id, $label, $sel]
}

todo_to_cols : List(Todo) -> List(List(Value))
todo_to_cols = |todos| {
    var $done = List.with_capacity(todos.len())
    var $title = List.with_capacity(todos.len())
    var $n = List.with_capacity(todos.len())
    for t in todos {
        $done = $done.append(B(t.done))
        $title = $title.append(S(t.title))
        $n = $n.append(I(t.n))
    }
    [$done, $title, $n]
}

## Column index of the label/title field for each site kind.
e_update : List(StoreSite), U64, U64, U64, Str -> List(StoreSite)
e_update = |sites, s, col, i, label| {
    { list, prev } = sites.replace(s, { cols: [], arity: 0 }) ?? crash "missing site"
    { cols, arity } = prev
    { list: cols2, prev: column } = cols.replace(col, []) ?? crash "missing column"
    column2 = column.set(i, S(label)) ?? crash "missing row"
    list.set(s, { cols: cols2.set(col, column2) ?? crash "missing column", arity }) ?? crash "missing site"
}

## ---------------------------------------------------------------------------
Input : { rep : U8, size : U64 }

test! : Input => Fuzz.Outcome
test! = |{ rep, size }| {
    if size > 200_000 or size < 2 { return Fuzz.reject }
    label = "a label longer than twenty-four bytes"
    if rep == 0 {
        s0 = [site_a_bench(make_rows(size)), site_a_todo(make_todos(size))]
        w = Fuzz.start_measure!("A-update")
        s1 = a_update(s0, 0, 1, label)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("A-update-other-site")
        s2 = a_update(s1, 1, 1, label)
        _ = w2.finish!()
        if s2.len() != 2 { crash "bad" }
        Fuzz.keep
    } else if rep == 1 {
        wc = Fuzz.start_measure!("D-create")
        s0 = [site_d_bench(make_rows(size)), site_d_todo(make_todos(size)), site_d_group([site_d_todo(make_todos(4)), site_d_bench(make_rows(size))], 0)]
        _ = wc.finish!()
        w = Fuzz.start_measure!("D-update")
        s1 = d_update(s0, 0, SetLabel(1, label))
        _ = w.finish!()
        w2 = Fuzz.start_measure!("D-update-other-site")
        s2 = d_update(s1, 1, SetLabel(1, label))
        _ = w2.finish!()
        w3 = Fuzz.start_measure!("D-update-nested")
        s3 = d_update(s2, 2, Child(1, Box.box(SetLabel(1, label))))
        _ = w3.finish!()
        w4 = Fuzz.start_measure!("D-query")
        s4 = d_update(s3, 0, Len)
        _ = w4.finish!()
        if s4.len() != 3 { crash "bad" }
        Fuzz.keep
    } else if rep == 2 {
        wc = Fuzz.start_measure!("C-create")
        s0 = Both.{ left: BenchC.{ rows: make_rows(size) }, right: TodoC.{ todos: make_todos(size) } }
        _ = wc.finish!()
        w = Fuzz.start_measure!("C-update")
        s1 = s0.site_set(0, 1, label)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("C-update-other-site")
        s2 = s1.site_set(1, 1, label)
        _ = w2.finish!()
        _ = s2
        Fuzz.keep
    } else if rep == 3 {
        wc = Fuzz.start_measure!("E-create")
        s0 = [{ cols: row_to_cols(make_rows(size)), arity: 3 }, { cols: todo_to_cols(make_todos(size)), arity: 3 }]
        _ = wc.finish!()
        w = Fuzz.start_measure!("E-update")
        s1 = e_update(s0, 0, 1, 1, label)
        _ = w.finish!()
        w2 = Fuzz.start_measure!("E-update-other-site")
        s2 = e_update(s1, 1, 1, 1, label)
        _ = w2.finish!()
        if s2.len() != 2 { crash "bad" }
        Fuzz.keep
    } else {
        Fuzz.keep
    }
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, rep, size| Fuzz.example({ name, revision: "1", make: || { rep, size } })

target = Fuzz.target_with!({
    name: "p1b-representations",
    examples: [
        ex("A-1k", 0, 1000), ex("A-10k", 0, 10000), ex("A-100k", 0, 100000),
        ex("D-1k", 1, 1000), ex("D-10k", 1, 10000), ex("D-100k", 1, 100000),
        ex("C-1k", 2, 1000), ex("C-10k", 2, 10000), ex("C-100k", 2, 100000),
        ex("E-1k", 3, 1000), ex("E-10k", 3, 10000), ex("E-100k", 3, 100000),
    ],
    generator: { rep: Fuzz.u8_in(0, 3), size: Fuzz.u64_in(2, 2000) }.Fuzz,
    test!,
    show: Str.inspect,
})
