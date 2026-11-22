## The effect channel's request lifecycle as a state machine: request ids,
## the in-flight table, the follow-up queue and the effect counters
## (design.md, "The Effect Channel": "Ids, results and staleness",
## "Bounds", "Disposal and reparenting", "Supersession and asynchronous
## layers" and "Counters").
##
## `Core` owns everything typed: the sites that hold their requests'
## issued-for values and readers, the orphans that carry them to an
## ancestor, the encoding of a request as `FX` and of a stop as `CANCEL`,
## and the crash text of a bound. It asks this module every lifecycle
## decision that needs no site: whether a request is admitted or refused at
## the cap and which id it takes, whether an id given up was in flight or
## queued, which path a result is routed to and whether it retires its id,
## and which follow-up runs next at what chain depth. Each answer is
## returned once, so no caller recomputes it.
##
## Everything here is pure and shares nothing with the sites, so the
## `fuzz/fx-core` target checks it directly against a model of the
## lifecycle with an explicit depth for every follow-up.
##
## Cost: the in-flight table is a list bounded by the cap, so a lookup or a
## removal is O(in-flight); the follow-ups waiting are a set beside the
## queue, so giving one up is an expected O(1) lookup whatever the queue
## holds.
FxCore :: [].{

	## An admitted request in flight: its id, the site path its results
	## route to (an orphan's adopter once it is adopted), whether it is a
	## subscription (a result does not retire it) and whether it asked for
	## transfer progress.
	Live : { id : U32, path : List(U32), sub : Bool, progress : Bool }

	## A follow-up waiting for its turn: a refusal (an id of the request
	## space) or a `Self` (an id of the follow-up space), the path it is
	## delivered to and the result it carries.
	Queued(res) : { id : U32, path : List(U32), res : res }

	## The follow-ups waiting to run, in order, and the ids among them that
	## still will. Giving one up removes its id from `waiting` alone, so
	## finding and dropping it is an expected O(1) lookup whatever the queue
	## holds; the drain skips an entry whose id is no longer waiting. The
	## queue follows the app's data (a refusal for each row that fetches
	## past the in-flight bound), so a scan of it per given-up id would too.
	FollowUps(res) : { entries : List(Queued(res)), waiting : Dict(U32, {}) }

	## The effect counters (design.md, "Counters", which states the law they
	## keep). The work record carries them at indices 32-38, the live gauge
	## (`live.len()`) at 39.
	Counts : { issued : U64, delivered : U64, stale : U64, refused : U64, cancelled : U64, reparented : U64, skipped : U64 }

	## The lifecycle of one instance's requests. `next` is the id the next
	## request takes (admitted or refused), `inner` the id the next `Self`
	## follow-up takes, `live` the in-flight table in issue order, `queue`
	## the follow-ups waiting and `max` the in-flight cap.
	Life(res) : { next : U32, inner : U32, live : List(Live), queue : FollowUps(res), max : U64, counts : Counts }

	## What admitting a request decided: it took a slot and the id, or it
	## was refused at the cap, took the id but no slot, and its refusal is
	## queued as a follow-up.
	Admission : [Admitted(U32), Refused(U32)]

	## What giving up an id found: a request in flight, now cancelled (the
	## caller emits its `CANCEL`); a follow-up still queued, now dropped and
	## counted stale; or nothing, because the id was already answered.
	Gave : [Cancelled, Dropped, Gone]

	## How a result arrives: a final result or subscription message, with
	## whether it ends a subscription (a port's `Closed` or `Threw`), or a
	## transfer progress report.
	Arrival : [Final({ ends : Bool }), Report]

	## Where an arriving result goes: nowhere, since its id is not in flight
	## (counted stale); to `path`, with whether the id stays live after it
	## (a subscription's message or a progress report); or nowhere because a
	## report reached a request that never asked for progress, a contract
	## error the caller raises at `path`.
	Route : [Stale, Deliver({ path : List(U32), live : Bool }), Unasked(List(U32))]

	## The drain's position in one host call: the depth of the follow-ups now
	## running, how many turns of depth 2 or more have run, the id
	## thresholds of both spaces when the current depth began, and the
	## breadth bound fixed at the start of the call.
	Drain : { depth : U64, deep : U64, below_next : U32, below_inner : U32, breadth : U64 }

	## What the drain does next: nothing (the queue is empty); drop an entry
	## that was given up, which takes no turn and no depth; run a follow-up's
	## turn at `depth`; or refuse to, because the chain is deeper than
	## [max_turns] or the turns of depth 2 or more passed `breadth` (each
	## naming the follow-up's path).
	Step(res) : [Idle(Life(res)), Skipped(Life(res), Drain), Run({ entry : Queued(res), depth : U64 }, Life(res), Drain), TooDeep(List(U32)), TooBroad(List(U32))]

	## The first `Self` follow-up id: follow-ups are a space of their own,
	## above every request id.
	inner_base : U32
	inner_base = 2147483648

	## The deepest chain of follow-up turns one host call may run.
	max_turns : U64
	max_turns = 64

	## The most follow-up turns of depth 2 or more one host call may run: 64
	## for each in-flight slot, and at least 64 x 64.
	max_breadth : U64 -> U64
	max_breadth = |inflight| FxCore.max_turns * (if (inflight > FxCore.max_turns) inflight else FxCore.max_turns)

	## No request yet, the default cap of 32.
	empty : {} -> Life(res)
	empty = |{}| { next: 1, inner: FxCore.inner_base, live: [], queue: { entries: [], waiting: Dict.empty() }, max: 32, counts: { issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0 } }

	## Append a follow-up at the end of the queue and mark its id waiting.
	## Appending only at the end is what lets the drain derive each entry's
	## depth from id thresholds instead of storing it ([drain_start]).
	follow_up : FollowUps(res), Queued(res) -> FollowUps(res)
	follow_up = |{ entries, waiting }, entry| { entries: entries.append(entry), waiting: waiting.insert(entry.id, {}) }

	## Admit an awaited request at `path`, or refuse it when the table holds
	## `max`: a refused request takes the next id but no slot, counts
	## `refused`, and its `refusal` result is queued as a follow-up to
	## `path`. An admitted one counts `issued`; its caller emits its `FX`.
	admit : Life(res), { path : List(U32), sub : Bool, progress : Bool }, res -> (Admission, Life(res))
	admit = |{ next: id, inner, live, queue, max, counts }, { path, sub, progress }, refusal| {
		if live.len() >= max {
			(Refused(id), { next: id + 1, inner, live, queue: FxCore.follow_up(queue, { id, path, res: refusal }), max, counts: { ..counts, refused: counts.refused + 1 } })
		} else {
			(Admitted(id), { next: id + 1, inner, live: live.append({ id, path, sub, progress }), queue, max, counts: { ..counts, issued: counts.issued + 1 } })
		}
	}

	## Refuse a request without admitting it (a payload the engine will not
	## write): it takes the next id but no slot, counts `refused`, and `res`
	## is queued as its follow-up, as the cap's refusal is.
	refuse : Life(res), List(U32), res -> (U32, Life(res))
	refuse = |{ next: id, inner, live, queue, max, counts }, path, res| {
		(id, { next: id + 1, inner, live, queue: FxCore.follow_up(queue, { id, path, res }), max, counts: { ..counts, refused: counts.refused + 1 } })
	}

	## Queue a `Self` follow-up for `path` with result `res`, with an id of
	## the follow-up space. It counts nothing until it is delivered.
	follow : Life(res), List(U32), res -> (U32, Life(res))
	follow = |{ next: upcoming, inner: id, live, queue, max, counts }, path, res| {
		(id, { next: upcoming, inner: id + 1, live, queue: FxCore.follow_up(queue, { id, path, res }), max, counts })
	}

	## Whether `id` is in the in-flight table: a scan bounded by the cap,
	## O(in-flight).
	in_flight : Life(res), U32 -> Bool
	in_flight = |life, id| life.live.any(|l| l.id == id)

	## Give up `id` for its owner (supersession, or disposal of a scoped
	## request or a queued follow-up): a request in flight leaves the table
	## and counts `cancelled`; a follow-up still waiting is dropped and
	## counts `stale`; an id already answered costs nothing.
	give_up : Life(res), U32 -> (Gave, Life(res))
	give_up = |{ next: upcoming, inner, live, queue, max, counts }, id| {
		if live.any(|l| l.id == id) {
			(Cancelled, { next: upcoming, inner, live: live.keep_if(|l| l.id != id), queue, max, counts: { ..counts, cancelled: counts.cancelled + 1 } })
		} else if queue.waiting.contains(id) {
			{ entries, waiting } = queue
			(Dropped, { next: upcoming, inner, live, queue: { entries, waiting: waiting.remove(id) }, max, counts: { ..counts, stale: counts.stale + 1 } })
		} else {
			(Gone, { next: upcoming, inner, live, queue, max, counts })
		}
	}

	## A surviving site at `path` takes over the orphans `ids`: their results
	## now route to it. Each adoption counts `reparented`, so an orphan whose
	## adopter is disposed in turn counts again when it is adopted again.
	adopt : Life(res), List(U32), List(U32) -> Life(res)
	adopt = |{ next: upcoming, inner, live, queue, max, counts }, path, ids| {
		if ids.is_empty() {
			{ next: upcoming, inner, live, queue, max, counts }
		} else {
			{ next: upcoming, inner, live: live.map(|l| if (ids.contains(l.id)) { ..l, path } else l), queue, max, counts: { ..counts, reparented: counts.reparented + ids.len() } }
		}
	}

	## A result or a report arrives for `id`. One whose id is not in flight
	## is counted stale here, before any state is touched. A final result
	## retires its id unless it is a subscription's message that does not
	## end it; a report never retires it. The site that receives it counts
	## it delivered (or stale, when it does not hold the id) with [count].
	arrive : Life(res), U32, Arrival -> (Route, Life(res))
	arrive = |{ next: upcoming, inner, live, queue, max, counts }, id, arrival| {
		match live.find_first(|l| l.id == id) {
			Err(_) => (Stale, { next: upcoming, inner, live, queue, max, counts: { ..counts, stale: counts.stale + 1 } })
			Ok(entry) => match arrival {
				Final({ ends }) => {
					stays = entry.sub and !ends
					(Deliver({ path: entry.path, live: stays }), { next: upcoming, inner, live: if (stays) live else live.keep_if(|l| l.id != id), queue, max, counts })
				}
				Report => (if (entry.progress) Deliver({ path: entry.path, live: True }) else Unasked(entry.path), { next: upcoming, inner, live, queue, max, counts })
			}
		}
	}

	## Count an arrival at a site: delivered to a site that holds its id,
	## stale at one that does not (or a reference command that names no live
	## element), and the writes an orphan's reaction made to retired state.
	count : Life(res), [Delivered, Stale, Skipped(U64)] -> Life(res)
	count = |{ next: upcoming, inner, live, queue, max, counts }, what| {
		counted = match what {
			Delivered => { ..counts, delivered: counts.delivered + 1 }
			Stale => { ..counts, stale: counts.stale + 1 }
			Skipped(n) => { ..counts, skipped: counts.skipped + n }
		}
		{ next: upcoming, inner, live, queue, max, counts: counted }
	}

	## The drain of one host call, begun after the external turn.
	##
	## The depth needs no field on an entry. The queue only grows at its
	## end, so entries sit in the order they were queued and turns run in
	## non-decreasing depth. Ids are minted in increasing order, refusals
	## from the request space and `Self` from the follow-up space, and only
	## follow-ups are queued. So when the turns of depth d begin, the
	## counters of both spaces are a threshold: the entry run next has depth
	## d if its id is below the threshold of its space, and otherwise was
	## queued by a depth-d turn and opens depth d + 1, whose threshold is the
	## counters at that moment. O(1) per turn.
	drain_start : Life(res) -> Drain
	drain_start = |life| { depth: 1, deep: 0, below_next: life.next, below_inner: life.inner, breadth: FxCore.max_breadth(life.max) }

	## The drain's next step: take the head of the queue and decide it. An
	## entry given up is skipped; one that is still waiting leaves the queue
	## and `waiting`, and runs at its depth, unless that depth passes
	## [max_turns] or the turns of depth 2 or more of this call pass the
	## breadth bound. Turns of depth 1 are not counted: the external turn
	## queued them itself, so their number follows what it issued.
	next : Life(res), Drain -> Step(res)
	next = |{ next: upcoming, inner, live, queue, max, counts }, drain| {
		{ entries, waiting } = queue
		match entries.first() {
			Err(_) => Idle({ next: upcoming, inner, live, queue: { entries, waiting }, max, counts })
			Ok(q) => {
				if !waiting.contains(q.id) {
					Skipped({ next: upcoming, inner, live, queue: { entries: entries.drop_first(1), waiting }, max, counts }, drain)
				} else {
					deeper = if (q.id >= FxCore.inner_base) q.id >= drain.below_inner else q.id >= drain.below_next
					d1 = if (deeper) { ..drain, depth: drain.depth + 1, below_next: upcoming, below_inner: inner } else drain
					if d1.depth > FxCore.max_turns {
						TooDeep(q.path)
					} else if d1.depth > 1 and d1.deep >= d1.breadth {
						TooBroad(q.path)
					} else {
						d2 = if (d1.depth > 1) { ..d1, deep: d1.deep + 1 } else d1
						Run({ entry: q, depth: d2.depth }, { next: upcoming, inner, live, queue: { entries: entries.drop_first(1), waiting: waiting.remove(q.id) }, max, counts }, d2)
					}
				}
			}
		}
	}
}

## The cap decides admission: below it a request takes a slot and its id,
## at it the id is taken with no slot and the refusal queued.
expect {
	life = { ..FxCore.empty({}), max: 1 }
	(first, l1) = FxCore.admit(life, { path: [0], sub: False, progress: False }, "refused")
	(second, l2) = FxCore.admit(l1, { path: [1], sub: False, progress: False }, "refused")
	first == Admitted(1) and second == Refused(2) and l2.live.map(|l| l.id) == [1] and l2.queue.entries.map(|q| q.id) == [2] and l2.counts.issued == 1 and l2.counts.refused == 1 and l2.next == 3
}

## Giving up finds a request in flight, then a queued follow-up, then
## nothing; each is counted once.
expect {
	life = { ..FxCore.empty({}), max: 1 }
	(_, l1) = FxCore.admit(life, { path: [0], sub: False, progress: False }, "refused")
	(_, l2) = FxCore.admit(l1, { path: [0], sub: False, progress: False }, "refused")
	(a, l3) = FxCore.give_up(l2, 1)
	(b, l4) = FxCore.give_up(l3, 2)
	(c, l5) = FxCore.give_up(l4, 1)
	(a, b, c) == (Cancelled, Dropped, Gone) and l5.live.is_empty() and l5.queue.waiting.len() == 0 and l5.counts.cancelled == 1 and l5.counts.stale == 1
}

## A subscription's message keeps its id; a message that ends it, or a
## one-shot result, retires it; a later result is stale.
expect {
	(_, l1) = FxCore.admit(FxCore.empty({}), { path: [3], sub: True, progress: False }, "refused")
	(r1, l2) = FxCore.arrive(l1, 1, Final({ ends: False }))
	(r2, l3) = FxCore.arrive(l2, 1, Final({ ends: True }))
	(r3, l4) = FxCore.arrive(l3, 1, Final({ ends: False }))
	r1 == Deliver({ path: [3], live: True }) and r2 == Deliver({ path: [3], live: False }) and r3 == Stale and l4.live.is_empty() and l4.counts.stale == 1
}

## A follow-up queued while a follow-up of depth d runs has depth d + 1;
## a given-up entry is skipped without a turn.
expect {
	(a, l1) = FxCore.follow(FxCore.empty({}), [0], "now")
	(b, l2) = FxCore.follow(l1, [0], "now")
	(_, l3) = FxCore.give_up(l2, b)
	d0 = FxCore.drain_start(l3)
	match FxCore.next(l3, d0) {
		Run({ entry, depth }, l4, d1) => {
			(_, l5) = FxCore.follow(l4, [0], "now")
			match FxCore.next(l5, d1) {
				Skipped(l6, d2) => match FxCore.next(l6, d2) {
					Run({ depth: deeper, .. }, l7, d3) => entry.id == a and depth == 1 and deeper == 2 and FxCore.next(l7, d3) == Idle(l7)
					_ => False
				}
				_ => False
			}
		}
		_ => False
	}
}
