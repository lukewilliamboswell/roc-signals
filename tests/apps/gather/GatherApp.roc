import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Gather test app: `Worker.gather`, with specs in `specs/` run natively
## and in Chrome. The primes below 2000 are counted in shards, one job per
## shard: each shard's count is shown as it arrives, and the total once
## every shard has answered. A checkbox makes the second shard's job fail
## with the task's own error, so the whole answer fails with it.
GatherApp := [].{

	## The app's state: how many shards to split the question into, and
	## whether the second shard's job fails.
	S : { shards : U64, second : [Counts, Fails] }

	## One shard of the question: count the primes in [lo, hi), or fail.
	Span : { lo : U64, hi : U64, outcome : [Count, Fail] }

	count : Worker.Task(Span, U64, [Unlucky])
	count = Worker.task({ name: "test.roc-signals/gather/count", run!: |span| GatherApp.primes(span) })

	primes : Span -> Try(U64, [Unlucky])
	primes = |{ lo, hi, outcome }| match outcome {
		Fail => Err(Unlucky)
		Count => {
			var $found = 0
			for k in lo..<hi {
				if GatherApp.is_prime(k) {
					$found = $found + 1
				}
			}
			Ok($found)
		}
	}

	is_prime : U64 -> Bool
	is_prime = |k| {
		if k < 2 {
			return False
		}
		var $d = 2
		while $d * $d <= k {
			if k % $d == 0 {
				return False
			}
			$d = $d + 1
		}
		True
	}

	## The question as shards: equal spans of [0, 2000), the last taking
	## the remainder.
	spans : S -> List(Span)
	spans = |{ shards, second }| {
		size = 2000 // shards
		var $out = []
		for i in 0..<shards {
			outcome = if (i == 1 and second == Fails) Fail else Count
			$out = $out.append({ lo: i * size, hi: if (i + 1 == shards) 2000 else (i + 1) * size, outcome })
		}
		$out
	}

	## A job as the page shows it.
	job_text : Engine.JobState(U64, Worker.Error([Unlucky])) -> Str
	job_text = |job| match job {
		Working => "…"
		Answered(n) => n.to_str()
		Failed(error) => GatherApp.error_text(error)
	}

	error_text : Worker.Error([Unlucky]) -> Str
	error_text = |error| match error {
		Failed(Unlucky) => "unlucky"
		Timeout => "timeout"
		Refused => "refused"
		Lost(_) => "lost"
	}

	## The total, or what stands in its way; while a new question is
	## working, the previous total.
	total_text : Engine.Gathered(U64, Worker.Error([Unlucky])) -> Str
	total_text = |gathered| {
		previous = gathered.all.answered().map_ok(|counts| counts.sum().to_str()) ?? "none"
		match Worker.status(gathered.all) {
			Working => "working (previous: ${previous})"
			Answered(counts) => counts.sum().to_str()
			Unasked => "none"
			Failed(Unlucky) => "failed: unlucky"
			Timeout => "failed: timeout"
			Refused => "failed: refused"
			Lost(_) => "failed: lost"
		}
	}

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| Html.div(
		"gather",
		[
			Html.number_input(Engine.const("Shards"), st.val().map(|s| s.shards.to_str()), [], st.set_value(|s, text| { ..s, shards: U64.from_str(text) ?? s.shards })),
			Html.checkbox(
				Engine.const("Fail the second shard"),
				st.val().map(|s| s.second == Fails),
				[],
				st.set_value(|s, checked| { ..s, second: if (checked == "true") Fails else Counts }),
			),
			Worker.gather(
				GatherApp.count,
				st.val().map(GatherApp.spans),
				|g| Html.div(
					"result",
					[
						Html.p_v(g.map(|gathered| Str.join_with(gathered.jobs.map(GatherApp.job_text), " ")), [Engine.test_id("jobs")]),
						Html.p_v(g.map(GatherApp.total_text), [Engine.test_id("total")]),
					],
				),
			),
		],
	)

	program : Engine.Program
	program = Engine.program(|| Engine.state({ shards: 2, second: Counts }, GatherApp.view)).with_workers([GatherApp.count.registration()])
}

## The shards cover the question without a gap, the last taking the
## remainder, and only the second shard fails when asked to.
expect {
	actual =
		\\two: ${Str.inspect(GatherApp.spans({ shards: 2, second: Counts }))}
		\\three: ${Str.inspect(GatherApp.spans({ shards: 3, second: Fails }).map(|s| (s.lo, s.hi, s.outcome)))}
		\\primes: ${Str.inspect(GatherApp.primes({ lo: 0, hi: 2000, outcome: Count }))}
	expected =
		\\two: [{ hi: 1000, lo: 0, outcome: Count }, { hi: 2000, lo: 1000, outcome: Count }]
		\\three: [(0, 666, Count), (666, 1332, Fail), (1332, 2000, Count)]
		\\primes: Ok(303)
	actual == expected
}
