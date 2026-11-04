app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# One closure captures a list. On a message it moves the list into an
# environment record and runs a handler fetched from a list of handler
# records; the handler updates the list and the closure is rebuilt from the
# handler's result. Nothing else references the list.
Env : { value : List(U64) }

Handler : { mask : U64, run : (Env -> Env) }

Inst := [Inst((U64 -> (Inst, U64)))]

state : List(U64), List(Handler) -> Inst
state = |xs, handlers| Inst(|h| {
	match handlers.get(h) {
		Ok(handler) => {
			next = (handler.run)({ value: xs })
			(state(next.value, handlers), handler.mask)
		}
		Err(_) => (state(xs, handlers), 0)
	}
})

call : Inst, U64 -> (Inst, U64)
call = |Inst(f), h| f(h)

poke : List(U64) -> List(U64)
poke = |xs| {
	{ list, prev } = xs.replace(0, 0) ?? crash "empty"
	list.set(0, prev + 1) ?? crash "empty"
}

update : (List(U64) -> List(U64)) -> Handler
update = |f| { mask: 1, run: |e| { value: f(e.value) } }

run! : Str => Str
run! = |input| {
	n = 10_000 + Str.count_utf8_bytes(input)
	before = Host.alloc_count!()
	var $s = state(List.repeat(0, n), [update(poke)])
	setup = Host.alloc_count!() - before
	var $i = 0
	while $i < 1000 {
		(next, _) = call($s, 0)
		$s = next
		$i = $i + 1
	}
	"1000 handler runs: ${(Host.alloc_count!() - before - setup).to_str()} allocations"
}
