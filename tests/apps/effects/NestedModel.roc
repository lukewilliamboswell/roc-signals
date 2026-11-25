import pf.Core
import pf.Dom
import pf.SpecRunner

## Effect sites in nested scopes against an independent model of the
## lifecycle (design.md, "Disposal and reparenting", "Supersession and
## asynchronous layers", "Counters"). The tree is the one the lifecycle's
## rules are hardest on: the root holds a `when` for scope A, whose body
## holds a state, an effect site and a `when` for scope B, whose body holds
## a state and an effect site; beside A, a `when` for scope S holds a state
## and an effect site. The bytes choose each site's policy (`watch`,
## `watch_latest`, `keep_current`) and which state its reaction writes (its
## own scope's, A's for B, or the root's), then a session of value changes
## (each with a plan of a kept request, a scoped timer and a subscription),
## shows and hides, and results from a host that answers any id.
##
## The model knows nothing of the engine's paths, owned lists or table. It
## numbers ids itself and records each request's scope, mount, issuing
## step, kind and holder. After every call the effect commands, the
## counters, the ids in flight and the four states shown must equal the
## model's, and these rules hold:
##
## - `onlyKeptOrphans`: an orphan is always a kept request;
## - `noScopedRunAfterDispose`: a scoped request of a disposed site is
##   cancelled, and its late result is stale;
## - `noWriteToRetired`: an orphan's write to a state its scope's disposal
##   retired is skipped and counted, never applied to a state mounted again
##   in its place;
## - `supersededNeverRuns`: what a `watch_latest` gave up is cancelled;
## - `latestOwnsOnlyCurrent`: a live `watch_latest` site owns only requests
##   of its current value and its own mount;
## - the counter law of design.md, after every call;
## - the table agrees with the sites: through the engine's probe, the ids
##   each effect site owns and each `when` adopted are exactly the model's,
##   every id in flight is held by exactly one of them, and nothing waits.
NestedModel := [].{

	## Run the session the bytes describe and say what it reached.
	run : List(U8) -> Reached
	run = |bytes| run_session(bytes)
}

## What a session reached, so its examples are held to the shapes their
## names say.
Reached : { refused : U64, cancelled : U64, reparented : U64, skipped : U64, stale : U64, readopted : U64 }

Policy : [Watch, Latest, Current]

Kind : [Kept, Scoped, Sub]

## Where a request's results go: its own site, or the `when` of a scope
## that adopted it as an orphan.
Holder : [Own, WhenA, WhenB, WhenS]

## A scope's watched value: a serial and the plan it issues.
V : { n : U64, plan : U64 }

R : { va : V, vb : V, vs : V, shown_a : Bool, shown_b : Bool, shown_s : Bool, log : U64 }

Req : { id : U32, scope : U64, mount : U64, v : V, step : U64, kind : Kind, holder : Holder, eligible : Bool }

M : {
	cap : U64,
	policies : List(Policy),
	writes_to : List(U64),
	shown : List(Bool),
	mounts : List(U64),
	steps : List(U64),
	values : List(V),
	states : List(U64),
	log : U64,
	next : U32,
	live : List(Req),
	fx : List(Dom.FxCmd),
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	cancelled : U64,
	reparented : U64,
	skipped : U64,
	retired : U64,
	readopted : U64,
}

## Scopes are 0 (A), 1 (B, inside A) and 2 (S). A reaction's target is a
## scope's state or 3, the root's.
root_target : U64
root_target = 3

kinds_of : Policy, U64 -> List(Kind)
kinds_of = |policy, plan| {
	kinds = match plan % 5 {
		0 => []
		1 => [Kept]
		2 => [Scoped]
		3 => [Sub]
		_ => [Kept, Sub]
	}
	# A keep_current site cannot issue a subscription (a contract error),
	# so its plans issue a timer instead.
	if (policy == Current) kinds.map(|k| if (k == Sub) Scoped else k) else kinds
}

url_of : U64, V, U64 -> Str
url_of = |scope, v, at| "/n/${scope.to_str()}/${v.n.to_str()}/${at.to_str()}"

request_of : U64, V, U64, Kind -> Core.Request
request_of = |scope, v, at, kind| match kind {
	Kept => Core.http({ url: url_of(scope, v, at) }).sent()
	Scoped => Timer(10)
	Sub => Interval(50)
}

plan_of : Policy, U64 -> (V -> List(Core.Ask(Core.Result, [])))
plan_of = |policy, scope| |v| {
	var $asks = []
	var $at = 0.U64
	for kind in kinds_of(policy, v.plan) {
		$asks = $asks.append(Core.raw(request_of(scope, v, $at, kind)))
		$at = $at + 1
	}
	$asks
}

result_code : Core.Result -> U64
result_code = |res| match res {
	Http(_) => 1
	Timeout => 2
	Fired(_) => 3
	Refused => 4
	_ => 5
}

## What a reaction adds to the state it writes.
code : U64, V, U64 -> U64
code = |scope, v, rc| (scope + 1) * 100000 + v.n * 10 + rc

answer : Try(Core.Result, []) -> Core.Result
answer = |r| match r {
	Ok(res) => res
}

site : Policy, Core.Signal(ctx, V), (V -> List(Core.Ask(Core.Result, []))), Core.Reaction(ctx, V, Try(Core.Result, [])) -> Core.Elem(ctx)
site = |policy, v, plan, react| match policy {
	Watch => Core.watch(v, plan, react)
	Latest => Core.watch_latest(v, plan, react)
	Current => Core.keep_current(v, plan, react)
}

button : Str, Core.HandlerOf(ctx, Str) -> Core.Elem(ctx)
button = |label, handler| Core.element("button", [Core.on("click", handler)], [Core.text(label)])

page : List(Policy), List(U64) -> Core.Elem(Core.Root({}))
page = |policies, writes_to| {
	pol = |scope| policies.get(scope) ?? Watch
	tgt = |scope| writes_to.get(scope) ?? root_target
	bump_by = |r, which| {
		plan = which % 5
		match which // 5 {
			0 => { ..r, va: { n: r.va.n + 1, plan } }
			1 => { ..r, vb: { n: r.vb.n + 1, plan } }
			_ => { ..r, vs: { n: r.vs.n + 1, plan } }
		}
	}
	add = |scope| |s, v, res| s + code(scope, v, result_code(answer(res)))
	log = |scope| |r, v, res| { ..r, log: r.log + code(scope, v, result_code(answer(res))) }
	Core.state(
		{ va: { n: 0, plan: 0 }, vb: { n: 0, plan: 0 }, vs: { n: 0, plan: 0 }, shown_a: True, shown_b: True, shown_s: True, log: 0 },
		|st| Core.element(
			"main",
			[],
			[
				button("bump", st.set_value(|r, payload| bump_by(r, U64.from_str(payload) ?? 0))),
				button("toggle a", st.update(|r| { ..r, shown_a: !r.shown_a })),
				button("toggle b", st.update(|r| { ..r, shown_b: !r.shown_b })),
				button("toggle s", st.update(|r| { ..r, shown_s: !r.shown_s })),
				Core.element("p", [Core.test_id("nr")], [Core.text_s(st.signal().map(|r| "r${r.log.to_str()}"))]),
				Core.when(
					st.signal().map(|r| r.shown_a),
					|| Core.state(
						0.U64,
						|sa| Core.element(
							"section",
							[],
							[
								Core.element("p", [Core.test_id("na")], [Core.text_s(sa.signal().map(|n| "a${n.to_str()}"))]),
								site(pol(0), st.signal().map(|r| r.va).lift(), plan_of(pol(0), 0), if (tgt(0) == 0) sa.on_result(add(0)) else st.lift().on_result(log(0))),
								Core.when(
									st.signal().map(|r| r.shown_b).lift(),
									|| Core.state(
										0.U64,
										|sb| Core.element(
											"section",
											[],
											[
												Core.element("p", [Core.test_id("nb")], [Core.text_s(sb.signal().map(|n| "b${n.to_str()}"))]),
												site(
													pol(1),
													st.signal().map(|r| r.vb).lift().lift(),
													plan_of(pol(1), 1),
													if tgt(1) == 1 {
														sb.on_result(add(1))
													} else if tgt(1) == 0 {
														sa.lift().on_result(add(1))
													} else {
														st.lift().lift().on_result(log(1))
													},
												),
											],
										),
									),
									|| Core.text(""),
								),
							],
						),
					),
					|| Core.text(""),
				),
				Core.when(
					st.signal().map(|r| r.shown_s),
					|| Core.state(
						0.U64,
						|ss| Core.element(
							"section",
							[],
							[
								Core.element("p", [Core.test_id("ns")], [Core.text_s(ss.signal().map(|n| "s${n.to_str()}"))]),
								site(pol(2), st.signal().map(|r| r.vs).lift(), plan_of(pol(2), 2), if (tgt(2) == 2) ss.on_result(add(2)) else st.lift().on_result(log(2))),
							],
						),
					),
					|| Core.text(""),
				),
			],
		),
	)
}

get_or : List(a), U64, a -> a
get_or = |list, i, fallback| list.get(i) ?? fallback

policy : M, U64 -> Policy
policy = |m, scope| get_or(m.policies, scope, Watch)

## Whether scope `scope`'s site is mounted: B only inside a shown A.
alive : M, U64 -> Bool
alive = |m, scope| match scope {
	1 => get_or(m.shown, 0, False) and get_or(m.shown, 1, False)
	_ => get_or(m.shown, scope, False)
}

## Which states an orphan's write finds retired: those of the scopes whose
## disposal it was handed up through to its holder.
retired_for : U64, Holder -> List(U64)
retired_for = |scope, holder| match (scope, holder) {
	(1, WhenA) => [1, 0]
	(_, Own) => []
	_ => [scope]
}

## Run a reaction of `req` with result code `rc`: its own site's in place,
## an orphan's at its holder, where a write to a retired state is skipped.
react : M, Req, U64 -> M
react = |m, req, rc| {
	target = get_or(m.writes_to, req.scope, root_target)
	added = code(req.scope, req.v, rc)
	if target == root_target {
		{ ..m, log: m.log + added }
	} else if req.holder != Own and retired_for(req.scope, req.holder).contains(target) {
		{ ..m, skipped: m.skipped + 1 }
	} else {
		{ ..m, states: m.states.update(target, |s| s + added) ?? m.states }
	}
}

## Whether a result for `req` runs its reaction: a `keep_current` site
## runs only its latest step's, and its orphan only one current when it was
## disposed whose question still has the value it was issued for.
runs : M, Req -> Bool
runs = |m, req| match policy(m, req.scope) {
	Current =>
		if req.holder == Own {
			req.step == get_or(m.steps, req.scope, 0)
		} else {
			req.eligible and get_or(m.values, req.scope, { n: 0, plan: 0 }) == req.v
		}
	_ => True
}

## One site's issuing step for its current value, refusals run at once
## (they are the call's follow-ups, delivered after its turn).
issue : M, U64 -> M
issue = |m0, scope| {
	m = { ..m0, steps: m0.steps.update(scope, |s| s + 1) ?? m0.steps }
	v = get_or(m.values, scope, { n: 0, plan: 0 })
	mount = get_or(m.mounts, scope, 0)
	step = get_or(m.steps, scope, 0)
	var $m = m
	var $refusals = []
	var $at = 0.U64
	for kind in kinds_of(policy(m, scope), v.plan) {
		id = $m.next
		req = { id, scope, mount, v, step, kind, holder: Own, eligible: True }
		if $m.live.len().to_u64() >= $m.cap {
			$m = { ..$m, next: id + 1, refused: $m.refused + 1 }
			$refusals = $refusals.append(req)
		} else {
			cmd = match kind {
				Kept => Http(id, "GET", url_of(scope, v, $at), [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 })
				Scoped => Timer(id, 10)
				Sub => Interval(id, 50)
			}
			$m = { ..$m, next: id + 1, issued: $m.issued + 1, live: $m.live.append(req), fx: $m.fx.append(cmd) }
		}
		$at = $at + 1
	}
	$refusals.fold($m, |acc, req| react({ ..acc, delivered: acc.delivered + 1 }, req, 4))
}

## A `watch_latest` site gives up what it owns before issuing for a new
## value: every request of its mount still in flight is cancelled.
supersede : M, U64 -> M
supersede = |m, scope| {
	mount = get_or(m.mounts, scope, 0)
	given = m.live.keep_if(|r| r.scope == scope and r.mount == mount and r.holder == Own)
	{
		..m,
		live: m.live.drop_if(|r| r.scope == scope and r.mount == mount and r.holder == Own),
		fx: m.fx.concat(given.map(|r| Cancel(r.id))),
		cancelled: m.cancelled + given.len().to_u64(),
	}
}

bump : M, U64, U64 -> M
bump = |m, scope, plan| {
	old = get_or(m.values, scope, { n: 0, plan: 0 })
	m1 = { ..m, values: m.values.set(scope, { n: old.n + 1, plan }) ?? m.values }
	if !alive(m1, scope) {
		m1
	} else if policy(m1, scope) == Latest {
		issue(supersede(m1, scope), scope)
	} else {
		issue(m1, scope)
	}
}

## Dispose scope `scope`'s site, its kept requests adopted by `adopter`:
## scoped requests are cancelled, in the order they were issued.
dispose_site : M, U64, Holder -> M
dispose_site = |m, scope, adopter| {
	mount = get_or(m.mounts, scope, 0)
	step = get_or(m.steps, scope, 0)
	var $m = m
	for r in m.live {
		if r.scope == scope and r.mount == mount and r.holder == Own {
			if r.kind == Kept {
				$m = { ..$m, reparented: $m.reparented + 1, live: $m.live.map(|x| if (x.id == r.id) { ..x, holder: adopter, eligible: r.step == step } else x) }
			} else {
				$m = { ..$m, cancelled: $m.cancelled + 1, fx: $m.fx.append(Cancel(r.id)), live: $m.live.drop_if(|x| x.id == r.id) }
			}
		}
	}
	$m
}

mount_scope : M, U64 -> M
mount_scope = |m, scope| issue({ ..m, mounts: m.mounts.update(scope, |n| n + 1) ?? m.mounts, states: m.states.set(scope, 0) ?? m.states }, scope)

toggle : M, U64 -> M
toggle = |m, scope| {
	shown = get_or(m.shown, scope, False)
	flipped = { ..m, shown: m.shown.set(scope, !shown) ?? m.shown }
	match scope {
		0 =>
			if shown {
				# A's body goes, B's with it: both sites' orphans, and those B's
				# `when` had adopted, are adopted by A's `when`.
				m1 = dispose_site(m, 0, WhenA)
				m2 = if (get_or(m.shown, 1, False)) dispose_site(m1, 1, WhenA) else m1
				readopted = m2.live.count_if(|r| r.holder == WhenB).to_u64()
				{ ..m2, shown: flipped.shown, reparented: m2.reparented + readopted, readopted: m2.readopted + readopted, live: m2.live.map(|r| if (r.holder == WhenB) { ..r, holder: WhenA } else r) }
			} else {
				m1 = mount_scope(flipped, 0)
				if (get_or(m.shown, 1, False)) mount_scope(m1, 1) else m1
			}
		1 =>
			if !get_or(m.shown, 0, False) {
				flipped
			} else if shown {
				{ ..dispose_site(m, 1, WhenB), shown: flipped.shown }
			} else {
				mount_scope(flipped, 1)
			}
		_ => if (shown) { ..dispose_site(m, 2, WhenS), shown: flipped.shown } else mount_scope(flipped, 2)
	}
}

deliver : M, U32, Core.Result -> M
deliver = |m, id, res| match m.live.find_first(|r| r.id == id) {
	Err(_) => { ..m, stale: m.stale + 1 }
	Ok(req) => {
		m1 = if req.kind == Sub {
			{ ..m, delivered: m.delivered + 1 }
		} else {
			{ ..m, delivered: m.delivered + 1, retired: m.retired + 1, live: m.live.drop_if(|r| r.id == id) }
		}
		if (runs(m1, req)) react(m1, req, result_code(res)) else m1
	}
}

## The ids the probe shows each effect site owning and each `when` having
## adopted, in document order, and what is queued and in flight.
Held : { owns : List(List(U32)), adopted : List(List(U32)), waiting : List(U32), live : List(U32) }

held_of : List(Core.Fact) -> Held
held_of = |facts| {
	var $kind = Root
	var $held = { owns: [], adopted: [], waiting: [], live: [] }
	for fact in facts {
		match fact {
			AtSite({ kind, .. }) => {
				$kind = kind
			}
			Owns(ids) => {
				$held = { ..$held, owns: $held.owns.append(ids) }
			}
			Adopted(ids) => {
				if $kind == When {
					$held = { ..$held, adopted: $held.adopted.append(ids) }
				}
			}
			Queued({ follow_ups, live }) => {
				$held = { ..$held, waiting: follow_ups, live }
			}
			_ => {}
		}
	}
	$held
}

sorted : List(U32) -> List(U32)
sorted = |ids| ids.sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)

## The table agrees with the sites (design.md, "Ids, results and
## staleness": a site checks that it holds an id, so the table and the
## sites must agree on who holds what).
check_probe : Core.App({}), M, Str -> {}
check_probe = |engine, m, what| {
	held = held_of(Core.probe_tree(engine))
	ids_of = |reqs| sorted(reqs.map(|r| r.id))
	want_owns = [0, 1, 2].keep_if(|scope| alive(m, scope)).map(|scope| ids_of(m.live.keep_if(|r| r.scope == scope and r.holder == Own)))
	got_owns = held.owns.map(sorted)
	if got_owns != want_owns {
		crash "nested: ${what}: effect sites own ${Str.inspect(got_owns)}, model ${Str.inspect(want_owns)}"
	}
	whens = if (get_or(m.shown, 0, False)) [WhenA, WhenB, WhenS] else [WhenA, WhenS]
	want_adopted = whens.map(|h| ids_of(m.live.keep_if(|r| r.holder == h)))
	got_adopted = held.adopted.map(sorted)
	if got_adopted != want_adopted {
		crash "nested: ${what}: whens adopted ${Str.inspect(got_adopted)}, model ${Str.inspect(want_adopted)}"
	}
	if !held.waiting.is_empty() {
		crash "nested: ${what}: follow-ups ${Str.inspect(held.waiting)} still wait after the call"
	}
	everyone = sorted(held.owns.join().concat(held.adopted.join()))
	if everyone != sorted(held.live) {
		crash "nested: ${what}: the sites hold ${Str.inspect(everyone)}, the table has ${Str.inspect(held.live)} in flight"
	}
	# onlyKeptOrphans
	for id in held.adopted.join() {
		match m.live.find_first(|r| r.id == id) {
			Ok(r) if r.kind == Kept => {}
			_ => crash "nested: ${what}: orphan ${id.to_str()} is not a kept request"
		}
	}
	# latestOwnsOnlyCurrent
	for scope in [0, 1, 2] {
		if alive(m, scope) and policy(m, scope) == Latest {
			v = get_or(m.values, scope, { n: 0, plan: 0 })
			mount = get_or(m.mounts, scope, 0)
			for r in m.live.keep_if(|x| x.scope == scope and x.holder == Own) {
				if r.v != v or r.mount != mount {
					crash "nested: ${what}: the watch_latest site of scope ${scope.to_str()} owns ${r.id.to_str()}, issued for an earlier value or mount"
				}
			}
		}
	}
	{}
}

check : { engine : Core.App({}), dom : Dom.Model, effects : List(Dom.FxCmd) }, M, Str -> {}
check = |{ engine, dom, effects }, m, what| {
	if effects != m.fx {
		crash "nested: ${what}: effect commands ${Str.inspect(effects)}, model ${Str.inspect(m.fx)}"
	}
	stats = Core.fx_stats(engine)
	got = [stats.issued, stats.delivered, stats.stale, stats.refused, stats.cancelled, stats.live, stats.reparented, stats.skipped]
	want = [m.issued, m.delivered, m.stale, m.refused, m.cancelled, m.live.len().to_u64(), m.reparented, m.skipped]
	if got != want {
		crash "nested: ${what}: counters ${Str.inspect(got)} (issued delivered stale refused cancelled live reparented skipped), model ${Str.inspect(want)}"
	}
	if Core.fx_live(engine) != m.live.map(|r| r.id) {
		crash "nested: ${what}: in flight ${Str.inspect(Core.fx_live(engine))}, model ${Str.inspect(m.live.map(|r| r.id))}"
	}
	# The counter law (design.md, "Counters"): every id issued or refused,
	# every issued request live, cancelled or retired, and in the counters
	# alone delivered + stale >= refused + (issued - live - cancelled).
	if (m.next - 1).to_u64() != stats.issued + stats.refused {
		crash "nested: ${what}: ${(m.next - 1).to_str()} ids taken, ${stats.issued.to_str()} issued and ${stats.refused.to_str()} refused"
	}
	if stats.issued != stats.live + stats.cancelled + m.retired {
		crash "nested: ${what}: issued ${stats.issued.to_str()} is not live ${stats.live.to_str()} + cancelled ${stats.cancelled.to_str()} + retired ${m.retired.to_str()}"
	}
	if stats.delivered + stats.stale < stats.refused + (stats.issued - stats.live - stats.cancelled) {
		crash "nested: ${what}: the counters break the law: ${Str.inspect(got)}"
	}
	shown = |id| match SpecRunner.find(dom, TestId(id)) {
		Ok(i) => Ok(Dom.text_of(dom, i))
		Err(_) => Err(Hidden)
	}
	state_text = |scope, prefix| if (alive(m, scope)) Ok("${prefix}${get_or(m.states, scope, 0).to_str()}") else Err(Hidden)
	got_text = [shown("nr"), shown("na"), shown("nb"), shown("ns")]
	want_text = [Ok("r${m.log.to_str()}"), state_text(0, "a"), state_text(1, "b"), state_text(2, "s")]
	if got_text != want_text {
		crash "nested: ${what}: states shown ${Str.inspect(got_text)}, model ${Str.inspect(want_text)}"
	}
	if Core.settled(engine).is_err() {
		crash "nested: ${what}: a reader was left stale"
	}
	check_probe(engine, m, what)
}

pick : M, U8 -> U32
pick = |m, b| {
	at = (b // 3).to_u64()
	match b % 3 {
		0 if !m.live.is_empty() => (m.live.get(at % m.live.len()) ?? { id: 0, scope: 0, mount: 0, v: { n: 0, plan: 0 }, step: 0, kind: Kept, holder: Own, eligible: False }).id
		1 if m.next > 1 => 1 + (at % (m.next - 1).to_u64()).to_u32_wrap()
		_ => m.next + (at % 2).to_u32_wrap()
	}
}

run_session : List(U8) -> Reached
run_session = |bytes| {
	setup = |i| (bytes.get(i) ?? 0).to_u64()
	cap = 1 + setup(0) % 4
	policies = [setup(1) % 3, (setup(1) // 3) % 3, (setup(1) // 9) % 3].map(|p| if (p == 0) Watch else if (p == 1) Latest else Current)
	t = setup(2)
	writes_to = [if (t % 2 == 0) 0 else root_target, if (t // 2 % 3 == 0) 1 else if (t // 2 % 3 == 1) 0 else root_target, if (t // 6 % 2 == 0) 2 else root_target]
	(initial, mounted) = Core.take_cmds(Core.mount_with(cap, page(policies, writes_to)), [])
	(dom0, _, fx0) = Dom.apply_fx(Dom.new({}), mounted)
	m0 = { cap, policies, writes_to, shown: [True, True, True], mounts: [1, 1, 1], steps: [1, 1, 1], values: List.repeat({ n: 0, plan: 0 }, 3), states: [0, 0, 0], log: 0, next: 1, live: [], fx: [], issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, retired: 0, readopted: 0 }
	check({ engine: initial, dom: dom0, effects: fx0 }, m0, "mount")
	var $engine = initial
	var $dom = dom0
	var $m = m0
	var $i = 3.U64
	while $i + 1 < bytes.len() {
		op = (bytes.get($i) ?? 0) % 5
		arg = bytes.get($i + 1) ?? 0
		$i = $i + 2
		m = { ..$m, fx: [] }
		scope = (arg % 3).to_u64()
		(engine, next, what) = if op == 0 {
			plan = (arg // 3 % 5).to_u64()
			(click($engine, $dom, "bump", (scope * 5 + plan).to_str()), bump(m, scope, plan), "bump ${scope.to_str()} with plan ${plan.to_str()}")
		} else if op == 1 {
			label = match scope {
				0 => "toggle a"
				1 => "toggle b"
				_ => "toggle s"
			}
			(click($engine, $dom, label, ""), toggle(m, scope), label)
		} else {
			id = pick(m, arg // 3)
			res = if (op == 2) Http({ status: 200, headers: [], body: "" }) else if (op == 3) Timeout else Fired(arg.to_i64())
			(Core.result($engine, id, res), deliver(m, id, res), "result ${result_code(res).to_str()} for ${id.to_str()}")
		}
		(taken, commands) = Core.take_cmds(engine, [])
		(dom, _, effects) = Dom.apply_fx($dom, commands)
		check({ engine: taken, dom, effects }, next, "step ${($i // 2).to_str()} ${what}")
		$engine = taken
		$dom = dom
		$m = next
	}
	{ refused: $m.refused, cancelled: $m.cancelled, reparented: $m.reparented, skipped: $m.skipped, stale: $m.stale, readopted: $m.readopted }
}

click : Core.App({}), Dom.Model, Str, Str -> Core.App({})
click = |engine, dom, label, payload| {
	index = SpecRunner.find(dom, Text(label)) ?? crash "nested: no button ${label}"
	route = Dom.target(dom, index, "click", True) ?? crash "nested: button ${label} has no handler"
	Core.event(engine, route.node, route.handler, payload)
}

## Watch everywhere, orphans written to their own scopes: hide B with a
## kept request in flight, then hide A, so B's `when` hands it up to A's,
## which adopts it again; its answer is a write to B's retired state.
expect {
	r = NestedModel.run([3, 0, 0, 0, 4, 1, 1, 1, 0, 2, 0])
	r.reparented == 2 and r.readopted == 1 and r.skipped == 1
}

## watch_latest everywhere, writing the root: supersede a kept request and
## a subscription, then dispose with both in flight (the subscription is
## cancelled, the kept request's answer still reaches the root).
expect {
	r = NestedModel.run([3, 13, 11, 0, 12, 0, 12, 1, 0, 2, 0])
	r.cancelled == 3 and r.reparented == 1 and r.skipped == 0
}

## keep_current everywhere: an older step's answer is delivered but does
## not run; the current step's request, orphaned, runs while its value
## stands, and its write to A's retired state is skipped.
expect {
	r = NestedModel.run([3, 26, 0, 0, 3, 0, 3, 2, 0, 1, 0, 2, 0])
	r.skipped == 1 and r.reparented == 1
}

## At a cap of one, a plan's second request is refused, and its refusal
## reaches the reaction in the same call.
expect NestedModel.run([0, 0, 0, 0, 12, 0, 12]).refused >= 1
