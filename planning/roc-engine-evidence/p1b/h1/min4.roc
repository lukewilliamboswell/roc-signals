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
