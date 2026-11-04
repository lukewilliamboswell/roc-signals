app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# Two closures that capture the same list.
Site := [Site({ set : U64 -> Site, len : () -> U64 })]

site : List(U64) -> Site
site = |xs| Site.Site({ set: |i| site(xs.set(i, 7) ?? xs), len: || xs.len() })

site_set : Site, U64 -> Site
site_set = |Site(fs), i| (fs.set)(i)

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

    "1000 updates: inline loop ${inline_allocs.to_str()} allocations"
}
