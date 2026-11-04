## Summary

A tag holds a record of two closures that both capture the same list. Calling one of them consumes the tag and rebuilds it from the updated list. Under `--opt=speed`, whether that update happens in place depends on code elsewhere in the program. Adding a second, separate caller of the same function makes every update copy the whole list, including the updates in a loop that did not change.

The other build modes are consistent with themselves but disagree with each other: `--opt=dev` updates in place both times, and `--opt=interpreter` copies both times.

The same sharing in plain data, a record whose two fields hold the same list, updates in place in every mode. So does the closure version when only one closure captures the list.

Compiler: `nightly-2026-11-03-34bd006`, Linux x86_64, using the `test/alloc-count` platform from this repository.

## Reproduction

`min4.roc`, next to `test/alloc-count/platform`:

```roc
app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# Two closures that capture the same list.
Site := [Site({ set : U64 -> Site, len : () -> U64 })]

site : List(U64) -> Site
site = |xs| Site.Site({ set: |i| site(xs.set(i, 7) ?? xs), len: || xs.len() })

site_set : Site, U64 -> Site
site_set = |Site(fs), i| (fs.set)(i)

# Updates the site in slot 0 of a list.
update : List(Site), U64 -> List(Site)
update = |sites, i| {
    { list, prev } = sites.replace(0, site([])) ?? crash "missing"
    list.set(0, site_set(prev, i)) ?? crash "missing"
}

run! : Str => Str
run! = |input| {
    n = 10_000 + Str.count_utf8_bytes(input)

    before_inline = Host.alloc_count!()
    var $sites = [site(List.repeat(0, n))]
    var $i = 0
    while $i < 1000 {
        { list, prev } = $sites.replace(0, site([])) ?? crash "missing"
        $sites = list.set(0, site_set(prev, $i)) ?? crash "missing"
        $i = $i + 1
    }
    inline_allocs = Host.alloc_count!() - before_inline

    before_fn = Host.alloc_count!()
    var $s = [site(List.repeat(0, n))]
    var $j = 0
    while $j < 1000 {
        $s = update($s, $j)
        $j = $j + 1
    }
    fn_allocs = Host.alloc_count!() - before_fn

    "1000 updates: inline loop ${inline_allocs.to_str()} allocations, through update ${fn_allocs.to_str()} allocations"
}
```

`min4b.roc` is the same file with `update` and the second loop deleted.

```
$ roc build min4.roc --opt=speed --output=a && ./a hi
1000 updates: inline loop 1002 allocations, through update 1002 allocations
$ roc build min4b.roc --opt=speed --output=b && ./b hi
1000 updates: inline loop 2 allocations
```

| Build | `min4` inline loop | `min4` through `update` | `min4b` inline loop |
|---|---:|---:|---:|
| `--opt=speed` | 1002 | 1002 | 2 |
| `--opt=size` | 1002 | 1002 | |
| `--opt=dev` | 2 | 2 | 2 |
| `--opt=interpreter` | 1002 | 1002 | 1002 |
| `--opt=speed --specialize=no` | 6004 | 6004 | |

Each extra allocation is a full copy of the captured list. With a `List({ id : U64, label : Str })` of 10,000 rows, measured with roc-fuzz's requested-bytes counter, one update requests 320,061 bytes instead of 45. The cost grows with the list on every update.

## Controls, all updating in place in every mode

- `len: || 0`, so only `set` captures the list: 2 allocations in all three modes.
- `Pair := [Pair({ a : List(U64), b : List(U64) })]`, built with both fields holding the same list, and updated with `|Pair({ a, b }), i| { _ = b; Pair.Pair({ a: a.set(i, 7) ?? a, b: [] }) }` through the same `replace` loop: 1 allocation, which is the first update un-sharing the list.

## Expected

When `site_set` consumes the `Site` and calls `fs.set`, the sibling `fs.len` is dead. If it were released before the call, as the unused `b` field of `Pair` is, the call would own the only reference to the list and could update it in place. At the least, the result should not change because of an unrelated caller elsewhere in the program, and the modes should agree.

This pattern is how a platform erases values of different types behind one record of operations: one record of closures per value, rebuilt on each update. As things stand, such a platform cannot rely on in-place updates.
