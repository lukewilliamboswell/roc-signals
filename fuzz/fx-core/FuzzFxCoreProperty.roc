import fz.Fuzz
import pf.FxCore

## The request lifecycle (`FxCore`) against a model of it, with no engine in
## the loop. Bytes drive admissions, refusals, `Self` follow-ups, give-ups,
## adoptions, results and reports from an adversarial host (any id, in any
## order, as often as it likes), and drains whose follow-ups' turns queue
## more. The model is written from design.md ("The Effect Channel") and
## shares no code with `FxCore`: it numbers ids itself, gives every
## follow-up an explicit chain depth when it is queued, and records each
## request's fate. After every step:
##
## - the in-flight table never holds more than the cap, and an admission is
##   refused exactly when the model's table is full (`capHolds`,
##   `refusalExactlyAtCap`);
## - every id the model knows is in the table exactly when its fate is live,
##   among the waiting follow-ups exactly when it is queued, never both
##   (`fatesAgree`);
## - the ids admission gives are the model's, and a result is routed to the
##   path its own request holds, so an old answer never reaches a new
##   request (`noOldAnswerToNewRequest`); a result for an id that is no
##   longer in flight is stale and runs nothing (`noRunAfterEnd`);
## - every counter equals the model's, and with the queue empty the
##   counters keep design.md's law (`countersBalance`);
## - the drain runs follow-ups in order at the depth the model tagged them
##   with, skips those given up, and stops exactly when the next would be
##   deeper than 64 or the turns of depth 2 or more pass 64 per slot, at
##   least 4096 (the depth and breadth bounds).

## What a queued follow-up carries: its kind and the model's nonce for it.
Res : { kind : [Refusal, Again], nonce : U32 }

Fate : [Live, Waiting, Retired, Cancelled, Dropped, Ran]

## A request or follow-up the model has minted. `holder` is the nonce of
## the path its results route to (`[holder]`).
Known : { id : U32, nonce : U32, sub : Bool, progress : Bool, holder : U32, fate : Fate }

## A queued follow-up with the depth the model gave it when it was queued.
Waiting : { id : U32, depth : U64, nonce : U32, holder : U32, kind : [Refusal, Again] }

M : {
	max : U64,
	next : U32,
	inner : U32,
	nonce : U32,
	known : Dict(U32, Known),
	live : List(U32),
	queue : List(Waiting),
	head : U64,
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	cancelled : U64,
	reparented : U64,
	skipped : U64,
	retired : U64,
	messages : U64,
	ran_refusals : U64,
	dropped_refusals : U64,
	deepest : U64,
}

## The first follow-up id, as design.md states it: a space of its own from
## 2³¹.
first_inner : U32
first_inner = 2147483648

model_new : U64 -> M
model_new = |max| { max, next: 1, inner: first_inner, nonce: 1, known: Dict.empty(), live: [], queue: [], head: 0, issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, retired: 0, messages: 0, ran_refusals: 0, dropped_refusals: 0, deepest: 0 }

## design.md, "Bounds": 64 deep, and 64 turns of depth 2 or more per
## in-flight slot, at least 4096.
model_breadth : U64 -> U64
model_breadth = |max| 64 * (if (max > 64) max else 64)

find_known : M, U32 -> Try(Known, [Unknown])
find_known = |m, id| match m.known.get(id) {
	Ok(k) => Ok(k)
	Err(_) => Err(Unknown)
}

set_fate : M, U32, Fate -> M
set_fate = |{ max, next, inner, nonce, known, live, queue, head, issued, delivered, stale, refused, cancelled, reparented, skipped, retired, messages, ran_refusals, dropped_refusals, deepest }, id, fate| {
	changed = match known.get(id) {
		Ok(k) => known.insert(id, { ..k, fate })
		Err(_) => known
	}
	{ max, next, inner, nonce, known: changed, live, queue, head, issued, delivered, stale, refused, cancelled, reparented, skipped, retired, messages, ran_refusals, dropped_refusals, deepest }
}

is_waiting : M, U32 -> Bool
is_waiting = |m, id| match m.known.get(id) {
	Ok(k) => k.fate == Waiting
	Err(_) => False
}

waiting_count : M -> U64
waiting_count = |m| m.known.values().count_if(|k| k.fate == Waiting)

## The implementation's state, read only to compare it with the model.
Life : FxCore.Life(Res)

S : { life : Life, m : M }

fail : Str -> a
fail = |what| crash "fx-core: ${what}"

## The rules that hold after every step (see the module comment): the full
## agreement of every id's fate with the table and the queue.
check : S, Str -> {}
check = |s, what| {
	{ life, m } = s
	check_counts(s, what)
	for k in m.known.values() {
		in_table = life.live.any(|l| l.id == k.id)
		in_queue = life.queue.waiting.contains(k.id)
		if in_table != (k.fate == Live) or in_queue != (k.fate == Waiting) or (in_table and in_queue) {
			fail("${what}: id ${k.id.to_str()} has fate ${Str.inspect(k.fate)} but is in flight ${Str.inspect(in_table)}, waiting ${Str.inspect(in_queue)}")
		}
		if in_table {
			path = life.live.find_first(|l| l.id == k.id).map_ok(|l| l.path) ?? []
			if path != [k.holder] {
				fail("${what}: id ${k.id.to_str()} routes to ${Str.inspect(path)}, its request holds ${k.holder.to_str()}")
			}
		}
	}
	{}
}

## The rules cheap enough to check after every follow-up's turn: the cap,
## the table's ids in order, the number waiting, every counter and the ids
## the next request and follow-up take.
check_counts : S, Str -> {}
check_counts = |{ life, m }, what| {
	if life.live.len() > m.max {
		fail("${what}: ${life.live.len().to_str()} in flight past the cap ${m.max.to_str()}")
	}
	if life.live.map(|l| l.id) != m.live {
		fail("${what}: in flight ${Str.inspect(life.live.map(|l| l.id))}, model ${Str.inspect(m.live)}")
	}
	if life.queue.waiting.len() != waiting_count(m) {
		fail("${what}: ${life.queue.waiting.len().to_str()} follow-ups waiting, model ${waiting_count(m).to_str()}")
	}
	got = life.counts
	want = { issued: m.issued, delivered: m.delivered, stale: m.stale, refused: m.refused, cancelled: m.cancelled, reparented: m.reparented, skipped: m.skipped }
	if got != want {
		fail("${what}: counters ${Str.inspect(got)}, model ${Str.inspect(want)}")
	}
	if life.next != m.next or life.inner != m.inner {
		fail("${what}: next ids ${life.next.to_str()}/${life.inner.to_str()}, model ${m.next.to_str()}/${m.inner.to_str()}")
	}
	{}
}

## design.md's counter law, which holds when the follow-up queue is empty:
## every id is issued or refused; every issued request is live, cancelled
## or retired; and in the counters alone, delivered + stale is at least
## refused + (issued − live − cancelled).
check_law : S, Str -> {}
check_law = |{ life, m }, what| {
	if waiting_count(m) == 0 {
		c = life.counts
		live = life.live.len()
		if (life.next - 1).to_u64() != c.issued + c.refused {
			fail("${what}: the next id is ${life.next.to_str()}, but ${c.issued.to_str()} issued and ${c.refused.to_str()} refused")
		}
		if c.issued != live + c.cancelled + m.retired {
			fail("${what}: ${c.issued.to_str()} issued is not ${live.to_str()} live + ${c.cancelled.to_str()} cancelled + ${m.retired.to_str()} retired")
		}
		if c.delivered + c.stale < c.refused + (c.issued - live - c.cancelled) {
			fail("${what}: delivered ${c.delivered.to_str()} + stale ${c.stale.to_str()} is below refused ${c.refused.to_str()} + retired ${(c.issued - live - c.cancelled).to_str()}")
		}
		if c.refused != m.ran_refusals + m.dropped_refusals {
			fail("${what}: ${c.refused.to_str()} refused, but ${m.ran_refusals.to_str()} ran and ${m.dropped_refusals.to_str()} were dropped")
		}
	}
	{}
}

## One admission at `depth` (0 outside a drain): the model refuses exactly
## at its own cap.
admit : S, { sub : Bool, progress : Bool, depth : U64 } -> S
admit = |{ life, m }, { sub, progress, depth }| {
	holder = m.nonce
	(got, life2) = FxCore.admit(life, { path: [holder], sub, progress }, { kind: Refusal, nonce: holder })
	id = m.next
	full = m.live.len() >= m.max
	want = if (full) Refused(id) else Admitted(id)
	if got != want {
		fail("admit: ${Str.inspect(got)}, model ${Str.inspect(want)} (${m.live.len().to_str()} in flight, cap ${m.max.to_str()})")
	}
	known = { id, nonce: holder, sub, progress, holder, fate: if (full) Waiting else Live }
	m2 = { ..m, next: id + 1, nonce: holder + 1, known: m.known.insert(id, known) }
	m3 = if full {
		{ ..m2, refused: m2.refused + 1, queue: m2.queue.append({ id, depth: depth + 1, nonce: holder, holder, kind: Refusal }) }
	} else {
		{ ..m2, issued: m2.issued + 1, live: m2.live.append(id) }
	}
	{ life: life2, m: m3 }
}

refuse : S, U64 -> S
refuse = |{ life, m }, depth| {
	holder = m.nonce
	(got, life2) = FxCore.refuse(life, [holder], { kind: Refusal, nonce: holder })
	if got != m.next {
		fail("refuse: id ${got.to_str()}, model ${m.next.to_str()}")
	}
	id = m.next
	{ life: life2, m: { ..m, next: id + 1, nonce: holder + 1, refused: m.refused + 1, known: m.known.insert(id, { id, nonce: holder, sub: False, progress: False, holder, fate: Waiting }), queue: m.queue.append({ id, depth: depth + 1, nonce: holder, holder, kind: Refusal }) } }
}

follow : S, U64 -> S
follow = |{ life, m }, depth| {
	holder = m.nonce
	(got, life2) = FxCore.follow(life, [holder], { kind: Again, nonce: holder })
	if got != m.inner {
		fail("follow: id ${got.to_str()}, model ${m.inner.to_str()}")
	}
	id = m.inner
	{ life: life2, m: { ..m, inner: id + 1, nonce: holder + 1, known: m.known.insert(id, { id, nonce: holder, sub: False, progress: False, holder, fate: Waiting }), queue: m.queue.append({ id, depth: depth + 1, nonce: holder, holder, kind: Again }) } }
}

## Pick an id for a give-up: one in flight, one waiting, or any minted.
pick_given : M, U8 -> U32
pick_given = |m, b| {
	which = b % 3
	at = (b // 3).to_u64()
	waiting = m.queue.drop_first(m.head).keep_if(|w| is_waiting(m, w.id))
	if which == 0 and !m.live.is_empty() {
		m.live.get(at % m.live.len()) ?? 0
	} else if which == 1 and !waiting.is_empty() {
		(waiting.get(at % waiting.len()) ?? { id: 0, depth: 0, nonce: 0, holder: 0, kind: Again }).id
	} else if m.next > 1 and at % 2 == 0 {
		1 + (at % (m.next - 1).to_u64()).to_u32_wrap()
	} else {
		m.inner - 1 - (at % 3).to_u32_wrap()
	}
}

give_up : S, U32 -> S
give_up = |{ life, m }, id| {
	(got, life2) = FxCore.give_up(life, id)
	(want, m2) = match find_known(m, id) {
		Ok({ fate: Live, .. }) => (Cancelled, set_fate({ ..m, cancelled: m.cancelled + 1, live: m.live.drop_if(|x| x == id) }, id, Cancelled))
		Ok({ fate: Waiting, .. }) => {
			refusal = id < first_inner
			(Dropped, set_fate({ ..m, stale: m.stale + 1, dropped_refusals: if (refusal) m.dropped_refusals + 1 else m.dropped_refusals }, id, Dropped))
		}
		_ => (Gone, m)
	}
	if got != want {
		fail("give up ${id.to_str()}: ${Str.inspect(got)}, model ${Str.inspect(want)}")
	}
	{ life: life2, m: m2 }
}

## A surviving site takes over some of the requests in flight (chosen by
## the bits of `mask`) at a path of its own.
adopt : S, U8 -> S
adopt = |{ life, m }, mask| {
	var $ids = []
	var $i = 0.U64
	for id in m.live {
		if $i < 8 and mask.to_u64().shr_zf_wrap($i.to_u8_wrap()).bitwise_and(1) == 1 {
			$ids = $ids.append(id)
		}
		$i = $i + 1
	}
	holder = m.nonce
	life2 = FxCore.adopt(life, [holder], $ids)
	ids = $ids
	known = ids.fold(
		m.known,
		|acc, id| match acc.get(id) {
			Ok(k) => acc.insert(id, { ..k, holder })
			Err(_) => acc
		},
	)
	{ life: life2, m: { ..m, nonce: holder + 1, reparented: m.reparented + ids.len(), known } }
}

## Pick an id for a result from a host that answers anything: one in
## flight, any request id minted (a late answer), one never issued, or a
## follow-up's id.
pick_arriving : M, U8 -> U32
pick_arriving = |m, b| {
	which = b % 4
	at = (b // 4).to_u64()
	if which == 0 and !m.live.is_empty() {
		m.live.get(at % m.live.len()) ?? 0
	} else if which == 1 and m.next > 1 {
		1 + (at % (m.next - 1).to_u64()).to_u32_wrap()
	} else if which == 3 {
		m.inner - 1 - (at % 4).to_u32_wrap()
	} else {
		m.next + (at % 3).to_u32_wrap()
	}
}

## Whether the arrival poisons the instance (a report no request asked for).
Arrived : [Going(S), Poisoned]

arrive : S, U32, FxCore.Arrival -> Arrived
arrive = |{ life, m }, id, arrival| {
	(got, life2) = FxCore.arrive(life, id, arrival)
	known = find_known(m, id)
	live = match known {
		Ok(k) => k.fate == Live
		Err(_) => False
	}
	if !live {
		if got != Stale {
			fail("a result for id ${id.to_str()}, which is not in flight (${Str.inspect(known.map_ok(|k| k.fate))}), was routed: ${Str.inspect(got)}")
		}
		Going({ life: life2, m: { ..m, stale: m.stale + 1 } })
	} else {
		k = known ?? fail("live id")
		match arrival {
			Report => {
				want = if (k.progress) Deliver({ path: [k.holder], live: True }) else Unasked([k.holder])
				if got != want {
					fail("report for ${id.to_str()}: ${Str.inspect(got)}, model ${Str.inspect(want)}")
				}
				if (k.progress) Going({ life: life2, m }) else Poisoned
			}
			Final({ ends }) => {
				stays = k.sub and !ends
				want = Deliver({ path: [k.holder], live: stays })
				if got != want {
					fail("result for ${id.to_str()}: ${Str.inspect(got)}, model ${Str.inspect(want)}")
				}
				# The site that holds the id counts it delivered.
				life3 = FxCore.count(life2, Delivered)
				m2 = { ..m, delivered: m.delivered + 1 }
				m3 = if stays {
					{ ..m2, messages: m2.messages + 1 }
				} else {
					set_fate({ ..m2, retired: m2.retired + 1, live: m2.live.drop_if(|x| x == id) }, id, Retired)
				}
				Going({ life: life3, m: m3 })
			}
		}
	}
}

## What a drain did: it ran out, or it stopped at a bound (which poisons).
Drained : [Done(S, U64), Bounded([Deep, Broad], U64)]

## Drain the queue. `fan` follow-ups are queued by the turn of each of the
## first `budget` follow-ups run (every one when `budget` is 255), and the
## bytes from `at` give each turn one more operation of its own.
drain : S, { fan : U64, budget : U64, bytes : List(U8), at : U64 } -> Drained
drain = |s0, { fan, budget, bytes, at }| {
	var $s = s0
	var $d = FxCore.drain_start(s0.life)
	var $deep = 0.U64
	var $runs = 0.U64
	var $at = at
	var $outcome = Draining
	var $deepest = s0.m.deepest
	while $outcome == Draining {
		{ life, m } = $s
		step = FxCore.next(life, $d)
		match m.queue.get(m.head) {
			Err(_) => {
				match step {
					Idle(l) => {
						$s = { life: l, m }
						$outcome = Finished
					}
					_ => fail("drain: the model's queue is empty, the lifecycle went on: ${Str.inspect(step_name(step))}")
				}
			}
			Ok(head) => {
				m1 = { ..m, head: m.head + 1 }
				if !is_waiting(m, head.id) {
					match step {
						Skipped(l, d) => {
							$s = { life: l, m: m1 }
							$d = d
						}
						_ => fail("drain: follow-up ${head.id.to_str()} was given up, the lifecycle did ${Str.inspect(step_name(step))}")
					}
				} else if head.depth > 64 {
					if step != TooDeep([head.holder]) {
						fail("drain: follow-up ${head.id.to_str()} is ${head.depth.to_str()} deep, the lifecycle did ${Str.inspect(step_name(step))}")
					}
					$outcome = Stopped(Deep)
				} else if head.depth > 1 and $deep >= model_breadth(m.max) {
					if step != TooBroad([head.holder]) {
						fail("drain: ${$deep.to_str()} turns of depth 2 or more ran, the lifecycle did ${Str.inspect(step_name(step))}")
					}
					$outcome = Stopped(Broad)
				} else {
					match step {
						Run({ entry, depth }, l, d) => {
							if entry.id != head.id or entry.path != [head.holder] or entry.res != { kind: head.kind, nonce: head.nonce } or depth != head.depth {
								fail("drain: ran ${entry.id.to_str()} at depth ${depth.to_str()} for ${Str.inspect(entry.path)}, model ${head.id.to_str()} at depth ${head.depth.to_str()} for [${head.holder.to_str()}]")
							}
							$deep = if (head.depth > 1) $deep + 1 else $deep
							$deepest = if (head.depth > $deepest) head.depth else $deepest
							$d = d
							# The follow-up's turn: its site counts it delivered.
							m2 = set_fate({ ..m1, delivered: m1.delivered + 1, ran_refusals: if (head.kind == Refusal) m1.ran_refusals + 1 else m1.ran_refusals }, head.id, Ran)
							var $t = { life: FxCore.count(l, Delivered), m: m2 }
							if budget == 255 or $runs < budget {
								var $k = 0.U64
								while $k < fan {
									$t = follow($t, head.depth)
									$k = $k + 1
								}
							}
							$runs = $runs + 1
							match bytes.get($at) {
								Ok(b) => {
									$at = $at + 1
									arg = bytes.get($at) ?? 0
									$t = match b % 6 {
										0 => admit($t, { sub: arg % 2 == 1, progress: arg % 4 >= 2, depth: head.depth })
										1 => refuse($t, head.depth)
										2 => follow($t, head.depth)
										3 => give_up($t, pick_given($t.m, arg))
										4 => adopt($t, arg)
										_ => $t
									}
									$at = $at + 1
								}
								Err(_) => {}
							}
							check_counts($t, "follow-up ${head.id.to_str()}")
							$s = $t
						}
						_ => fail("drain: follow-up ${head.id.to_str()} should run at depth ${head.depth.to_str()}, the lifecycle did ${Str.inspect(step_name(step))}")
					}
				}
			}
		}
	}
	match $outcome {
		Stopped(bound) => Bounded(bound, $deepest)
		_ => {
			done = { ..$s, m: { ..$s.m, deepest: $deepest } }
			check(done, "drain")
			Done(done, $at)
		}
	}
}

step_name : FxCore.Step(Res) -> Str
step_name = |step| match step {
	Idle(_) => "idle"
	Skipped(_, _) => "skip"
	Run({ entry, depth }, _, _) => "run ${entry.id.to_str()} at depth ${depth.to_str()}"
	TooDeep(path) => "too deep at ${Str.inspect(path)}"
	TooBroad(path) => "too broad at ${Str.inspect(path)}"
}

Input : { cap : U8, ops : List(U8) }

## Each step is an operation byte and an argument byte; a drain's turns
## take their own operations from the bytes after it.
## What a session reached, for the `expect`s that keep the examples
## honest: how it ended, the deepest follow-up it ran, and how many
## refusals and retirements it saw.
Reached : { ended : [Ran, Deep, Broad, Unasked], deepest : U64, refused : U64, retired : U64, cancelled : U64, stale : U64, reparented : U64 }

test : Input -> Fuzz.Outcome
test = |input| {
	_ = run(input)
	Fuzz.keep
}

run : Input -> Reached
run = |{ cap, ops }| {
	var $ended = Ran
	max = (cap % 6).to_u64()
	var $s = { life: { ..FxCore.empty({}), max }, m: model_new(max) }
	var $i = 0.U64
	var $going = True
	while $going and $i + 1 < ops.len() {
		op = ops.get($i) ?? 0
		arg = ops.get($i + 1) ?? 0
		$i = $i + 2
		s = $s
		what = "step ${($i // 2).to_str()} (op ${(op % 9).to_str()} ${arg.to_str()})"
		match op % 9 {
			0 => {
				$s = admit(s, { sub: arg % 2 == 1, progress: arg % 4 >= 2, depth: 0 })
			}
			1 => {
				$s = refuse(s, 0)
			}
			2 => {
				$s = follow(s, 0)
			}
			3 => {
				$s = give_up(s, pick_given(s.m, arg))
			}
			4 => {
				$s = adopt(s, arg)
			}
			5 => match arrive(s, pick_arriving(s.m, arg), Final({ ends: arg % 8 == 7 })) {
				Going(t) => {
					$s = t
				}
				Poisoned => {
					$going = False
					$ended = Unasked
				}
			}
			6 => match arrive(s, pick_arriving(s.m, arg), Report) {
				Going(t) => {
					$s = t
				}
				Poisoned => {
					$going = False
					$ended = Unasked
				}
			}
			7 => match drain(s, { fan: (arg % 3).to_u64(), budget: if (arg >= 252) 255 else (arg // 3).to_u64(), bytes: ops, at: $i }) {
				Done(t, at) => {
					$s = t
					$i = at
				}
				Bounded(bound, deepest) => {
					$going = False
					$ended = if (bound == Deep) Deep else Broad
					$s = { ..s, m: { ..s.m, deepest } }
				}
			}
			_ => {
				n = (arg % 3).to_u64()
				$s = { life: FxCore.count(s.life, Skipped(n)), m: { ..s.m, skipped: s.m.skipped + n } }
			}
		}
		if $going {
			check($s, what)
			check_law($s, what)
		}
	}
	m = $s.m
	{ ended: $ended, deepest: m.deepest, refused: m.refused, retired: m.retired, cancelled: m.cancelled, stale: m.stale, reparented: m.reparented }
}

example : Str, Input -> Fuzz.Example(Input)
example = |name, input| Fuzz.example({ name, revision: "1", make: || input })

fuzz_target = Fuzz.target_with({
	name: "fx-core",
	generator: { cap: Fuzz.u8, ops: Fuzz.list(Fuzz.u8, 256) }.Fuzz,
	test,
	show: Str.inspect,
	examples: [
		# Cap 2: three admissions (the third refused), a drain that runs the
		# refusal, then results for a live id, a retired one and one never
		# issued.
		example("refusal-at-the-cap", { cap: 2, ops: [0, 0, 0, 0, 0, 0, 7, 0, 5, 0, 5, 4, 5, 2] }),
		# Give up a request in flight, a queued refusal and an answered id.
		example("give-up-each-fate", { cap: 1, ops: [0, 0, 0, 0, 3, 0, 3, 1, 3, 2, 7, 0] }),
		# A subscription's messages keep its id; one that ends it retires it.
		example("subscription-ends", { cap: 3, ops: [0, 1, 5, 0, 5, 0, 5, 7, 5, 0] }),
		# Adopt two requests, then answer them at their adopter's path.
		example("adopt-then-answer", { cap: 4, ops: [0, 0, 0, 0, 0, 2, 4, 3, 5, 0, 5, 4, 6, 8] }),
		# A report for a request that asked for none poisons.
		example("unasked-report", { cap: 2, ops: [0, 0, 6, 0] }),
		# A chain of follow-ups, each queuing one: stopped at depth 65.
		example("chain-too-deep", { cap: 0, ops: [2, 0, 7, 253] }),
		# Each follow-up queues two: stopped by the breadth bound first.
		example("fan-too-broad", { cap: 0, ops: [2, 0, 7, 254] }),
		# Follow-ups whose turns admit, refuse and give up, at depths 1 to 3.
		example("nested-turns", { cap: 2, ops: [0, 0, 2, 0, 1, 0, 7, 10, 0, 0, 1, 0, 3, 1, 2, 0, 0, 1, 5, 0] }),
		# Cap 0: every admission is refused and its follow-up runs.
		example("cap-zero", { cap: 0, ops: [0, 0, 0, 1, 7, 0, 5, 1, 5, 5] }),
	],
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzFxCoreProperty := [].{
	target = fuzz_target
}

## The examples reach what their names say, so none of them passes
## vacuously.
expect run({ cap: 2, ops: [0, 0, 0, 0, 0, 0, 7, 0, 5, 0, 5, 4, 5, 2] }).refused == 1
expect {
	r = run({ cap: 1, ops: [0, 0, 0, 0, 3, 0, 3, 1, 3, 2, 7, 0] })
	r.cancelled == 1 and r.stale == 1
}
expect run({ cap: 4, ops: [0, 0, 0, 0, 0, 2, 4, 3, 5, 0, 5, 4, 6, 8] }).reparented == 2
expect run({ cap: 2, ops: [0, 0, 6, 0] }).ended == Unasked
expect {
	r = run({ cap: 0, ops: [2, 0, 7, 253] })
	r.ended == Deep and r.deepest == 64
}
expect {
	r = run({ cap: 0, ops: [2, 0, 7, 254] })
	r.ended == Broad and r.deepest > 2 and r.deepest < 64
}
expect run({ cap: 2, ops: [0, 0, 2, 0, 1, 0, 7, 10, 0, 0, 1, 0, 3, 1, 2, 0, 0, 1, 5, 0] }).deepest >= 3
