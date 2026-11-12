import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Counting the primes below a limit, split into shards that run as
## separate jobs: each shard's count shows as it arrives, and the total
## once every shard has answered.
Primes := [].{

	# region task
	## One shard of the question: the numbers from `start` up to `end`.
	Shard : { start : U64, end : U64 }

	## How many primes a shard holds.
	count : Worker.Task(Shard, U64, Worker.Never)
	count = Worker.task({ name: "example.org/primes/count", run!: |shard| Ok(Primes.primes_in(shard)) })

	## The question split into `shards` equal ranges below `limit`, the
	## last taking the remainder. Keep `shards` within the in-flight bound
	## (32 by default): a job beyond it is refused.
	split : { limit : U64, shards : U64 } -> List(Shard)
	split = |{ limit, shards }| {
		size = limit // shards
		var $out = []
		for i in 0..<shards {
			$out = $out.append({ start: i * size, end: if (i + 1 == shards) limit else (i + 1) * size })
		}
		$out
	}
	# endregion task

	primes_in : Shard -> U64
	primes_in = |{ start, end }| {
		var $found = 0
		for n in start..<end {
			if Primes.is_prime(n) {
				$found = $found + 1
			}
		}
		$found
	}

	is_prime : U64 -> Bool
	is_prime = |n| {
		if n < 2 {
			return False
		}
		var $d = 2
		while $d * $d <= n {
			if n % $d == 0 {
				return False
			}
			$d = $d + 1
		}
		True
	}

	S : { limit : U64, shards : U64 }

	Ctx : In(Root, S)

	# region gather
	## One job per shard. `jobs` shows each shard as it settles; `all`
	## answers once every shard has, and keeps the previous total while a
	## new question works.
	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"primes",
			[
				Html.number_input(Engine.const("Shards"), v.map(|s| s.shards.to_str()), [], st.set_value(|s, text| { ..s, shards: U64.from_str(text) ?? s.shards })),
				Worker.gather(
					Primes.count,
					v.map(|s| Primes.split(s)),
					|gathered| Html.div(
						"result",
						[
							Html.p_s(gathered.map(|g| Str.join_with(g.jobs.map(Primes.show_job), " ")), [Engine.test_id("shards")]),
							Html.p_s(gathered.map(|g| Primes.show_total(g.all)), [Engine.test_id("total")]),
						],
					),
				),
			],
		)
	}

	show_job : Engine.JobState(U64, Worker.Error(Worker.Never)) -> Str
	show_job = |job|
		match job {
			Working => "…"
			Answered(n) => n.to_str()
			Failed(_) => "failed"
		}

	## The whole answer as one flat match, and the previous total while a
	## new question works.
	show_total : Engine.Remote(List(U64), Worker.Error(Worker.Never)) -> Str
	show_total = |all|
		match Worker.status(all) {
			Unasked => ""
			Working => all.answered().map_ok(|counts| "${counts.sum().to_str()} (counting…)") ?? "Counting…"
			Answered(counts) => "${counts.sum().to_str()} primes"
			Timeout | Refused | Lost(_) => "The count failed."
		}
	# endregion gather

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ limit: 2000, shards: 2 }, Primes.view))
			.with_workers([Primes.count.registration()])
}

## The shards cover the question with no gap or overlap.
expect Primes.split({ limit: 10, shards: 3 }) == [{ start: 0, end: 3 }, { start: 3, end: 6 }, { start: 6, end: 10 }]
