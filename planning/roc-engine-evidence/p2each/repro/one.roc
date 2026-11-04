app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# One closure per site (representation D). The closure captures a list and
# a fixed config record, and takes a message; every update consumes the
# closure and rebuilds it from the updated list.
Msg := [Set(U64), Len]

Inst := [Inst((Msg -> (Inst, U64)))]

Cfg : { scale : U64, f : (U64 -> U64) }

site : Cfg, List(U64) -> Inst
site = |cfg, xs| Inst(|msg| {
	match msg {
		Set(i) => {
			v = (cfg.f)(i)
			(site(cfg, xs.set(i, v) ?? xs), 1)
		}
		Len => {
			n = xs.len()
			(site(cfg, xs), n * cfg.scale)
		}
	}
})

call : Inst, Msg -> (Inst, U64)
call = |Inst(f), msg| f(msg)

# Variant B: the closure also reads a field of its list before updating.
site_b : Cfg, List(U64) -> Inst
site_b = |cfg, xs| Inst(|msg| {
	n = xs.len()
	match msg {
		Set(i) => (site_b(cfg, xs.set(i % n, 7) ?? xs), 1)
		Len => (site_b(cfg, xs), n)
	}
})

bump : List(U64), U64 -> List(U64)
bump = |xs, i| xs.set(i, 9) ?? xs

# Variant C: the update is conditional; the other branch keeps the list.
site_c : Cfg, List(U64) -> Inst
site_c = |cfg, xs| Inst(|msg| {
	match msg {
		Set(i) => {
			ys = if i % 2 == 0 bump(xs, i) else xs
			(site_c(cfg, bump(ys, i + 1)), 1)
		}
		Len => (site_c(cfg, xs), xs.len())
	}
})

# Variant D: app-style reducer that returns its input on a miss.
remove_at : List(U64), U64 -> List(U64)
remove_at = |xs, k| match xs.find_first_index(|x| x == k) {
	Ok(i) => xs.drop_at(i)
	Err(_) => xs
}

site_d : Cfg, List(U64) -> Inst
site_d = |cfg, xs| Inst(|msg| {
	match msg {
		Set(i) => (site_d(cfg, remove_at(xs, 99999).append(i)), 1)
		Len => (site_d(cfg, xs), xs.len())
	}
})

measure! : Inst, U64 => U64
measure! = |inst0, k| {
	before = Host.alloc_count!()
	var $sites = [inst0]
	var $i = 0
	while $i < k {
		{ list, prev } = $sites.replace(0, site({ scale: 0, f: |x| x }, [])) ?? crash "missing"
		(next, _) = call(prev, Set($i))
		$sites = list.set(0, next) ?? crash "missing"
		$i = $i + 1
	}
	Host.alloc_count!() - before
}

run! : Str => Str
run! = |input| {
	n = 10_000 + Str.count_utf8_bytes(input)
	cfg = { scale: 2, f: |x| x + 1 }
	a = measure!(site(cfg, List.repeat(0, n)), 1000)
	b = measure!(site_b(cfg, List.repeat(0, n)), 1000)
	c = measure!(site_c(cfg, List.repeat(0, n)), 1000)
	d = measure!(site_d(cfg, List.repeat(0, n)), 1000)
	"1000 updates: A ${a.to_str()} allocations, B ${b.to_str()}, C (conditional update) ${c.to_str()}, D (reducer returns input on miss) ${d.to_str()}"
}
