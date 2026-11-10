import pf.Engine
import pf.Worker

## Worker Lab's model: the parameters a person sets, the jobs of a run and
## their phases, the pure kernels the workers run, and the totals.
##
## A run is a list of jobs, one per row, each with its task. A job is
## `Waiting` until the page admits it, `Running` while its request is in
## flight, and then `Done` with its answer, `TimedOut`, `Lost` (its worker
## crashed) or `Cancelled`. The page admits jobs in index order and keeps at
## most `window` of them in flight: the program's in-flight bound
## (`max_inflight`) less the one slot the heartbeat's interval holds. So a
## run never meets the bound by its own scheduling, and a person sees the
## jobs beyond the window waiting. A job that is refused at the bound anyway
## (a restart can issue a new run's jobs before the old run's rows have
## given up theirs) goes back to `Waiting` with its attempt counted and is
## admitted again as soon as a slot is free; the totals count the refusals.
##
## Nothing in here builds markup.
Lab := [].{

	## The awaited requests the program allows in flight at once.
	max_inflight : U64
	max_inflight = 16

	## Jobs in flight at once: the bound less the heartbeat's interval.
	window : U64
	window = Lab.max_inflight - 1

	## The most jobs a run can have.
	max_jobs : U64
	max_jobs = 64

	## The heaviest weight a job can have.
	max_weight : U64
	max_weight = 256

	## The longest deadline the platform honours (ten minutes).
	max_deadline_ms : U64
	max_deadline_ms = 600000

	## The workloads a run can be made of. `Faulty` is `Primes` with every
	## fourth job sent to a program that always crashes, to show that a
	## crashed worker loses only its own job.
	Workload : [Primes, Tiles, Faulty]

	## A half-open range of numbers to count primes in.
	Span : { lo : U64, hi : U64 }

	## One tile of the escape-time image of the Mandelbrot set, in 16.16
	## fixed point: the top-left point, the distance between pixels, the side
	## in pixels and the iteration limit. Integer arithmetic makes every
	## pixel exactly reproducible by an independent implementation.
	TileSpec : { x0 : I64, y0 : I64, step : I64, side : U64, iters : U64 }

	## What one job asks a worker to do.
	Task : [Count(Span), Crash(Span), Tile(TileSpec)]

	## A tile as the page keeps it: its size, the sum of its escape counts,
	## and the FNV-1a hash of its bytes. The bytes themselves are not kept.
	TileSummary : { bytes : U64, escapes : U64, hash : U32 }

	## A job's answer.
	Answer : [Primes(U64), Tile(TileSummary)]

	## Where a job is.
	Phase : [Waiting, Running, Done(Answer), TimedOut, Lost(Engine.WorkFault), Cancelled]

	## One job of a run. `run` and `attempt` make each request distinct: a new
	## run, or another attempt after a refusal, is a new value for the row's
	## effect site, which then issues again.
	Job : { index : U64, run : U64, attempt : U64, deadline_ms : U32, task : Task, phase : Phase }

	## The validated parameters of a run.
	Params : { workload : Workload, jobs : U64, weight : U64, deadline_ms : U32 }

	## The page's state: the parameters as typed, the run's serial, its jobs
	## and the refusals counted since the last reset.
	S : { workload : Workload, jobs_text : Str, weight_text : Str, deadline_text : Str, run : U64, jobs : List(Job), refused : U64 }

	## What a row's effect site wants: a run of its job's task, or nothing.
	Want : [Run({ run : U64, index : U64, attempt : U64, deadline_ms : U32, task : Task }), Hold]

	## The totals over a run's jobs.
	Tally : { total : U64, waiting : U64, running : U64, done : U64, timed_out : U64, lost : U64, cancelled : U64, primes : U64, tile_bytes : U64, checksum : U32 }

	initial : S
	initial = { workload: Primes, jobs_text: "8", weight_text: "4", deadline_text: "0", run: 0, jobs: [], refused: 0 }

	# ------------------------------------------------------------ parameters

	workload_from_str : Str -> Workload
	workload_from_str = |text|
		match text {
			"tiles" => Tiles
			"faulty" => Faulty
			_ => Primes
		}

	## The `select` value, and the only place it is spelled.
	workload_to_str : Workload -> Str
	workload_to_str = |workload|
		match workload {
			Primes => "primes"
			Tiles => "tiles"
			Faulty => "faulty"
		}

	## A whole number from `lo` to `hi`, or `Err` for anything else.
	bounded : Str, U64, U64 -> Try(U64, [OutOfRange])
	bounded = |text, lo, hi|
		match U64.from_str(text.trim()) {
			Ok(n) if n >= lo and n <= hi => Ok(n)
			_ => Err(OutOfRange)
		}

	## The parameters as typed, if every field is valid.
	params : S -> Try(Params, [Invalid(Str)])
	params = |s| {
		jobs = Lab.bounded(s.jobs_text, 1, Lab.max_jobs) ? |_| Invalid("Jobs must be a whole number from 1 to ${Lab.max_jobs.to_str()}.")
		weight = Lab.bounded(s.weight_text, 1, Lab.max_weight) ? |_| Invalid("Weight must be a whole number from 1 to ${Lab.max_weight.to_str()}.")
		deadline = Lab.bounded(s.deadline_text, 0, Lab.max_deadline_ms) ? |_| Invalid("Deadline must be a number of milliseconds from 0 (none) to ${Lab.max_deadline_ms.to_str()}.")
		Ok({ workload: s.workload, jobs, weight, deadline_ms: deadline.to_u32_wrap() })
	}

	## Why the parameters cannot start a run, or `""`.
	problem : S -> Str
	problem = |s|
		match Lab.params(s) {
			Ok(_) => ""
			Err(Invalid(message)) => message
		}

	# ----------------------------------------------------------------- tasks

	## Numbers counted per unit of weight.
	numbers_per_weight : U64
	numbers_per_weight = 2000

	## Where the first job's range starts.
	first_number : U64
	first_number = 1000000

	## Pixels along a tile's side per unit of weight.
	pixels_per_weight : U64
	pixels_per_weight = 4

	tile_iters : U64
	tile_iters = 96

	## One fixed-point unit: 1.0 in 16.16.
	one : I64
	one = 65536

	## The smallest `c` with `c * c >= n`.
	ceil_sqrt : U64 -> U64
	ceil_sqrt = |n| {
		var $c = 1.U64
		while $c * $c < n {
			$c = $c + 1
		}
		$c
	}

	## Job `index`'s task in a run with parameters `p`. Prime ranges are
	## consecutive blocks of `weight * 2000` numbers from one million. Tiles
	## cut the square from (-2, -1.5) to (1, 1.5) into a grid of as many
	## columns as rows, each tile `weight * 4` pixels on a side.
	task_of : Params, U64 -> Task
	task_of = |{ workload, jobs, weight, .. }, index| {
		width = weight * Lab.numbers_per_weight
		lo = Lab.first_number + index * width
		range = { lo, hi: lo + width }
		match workload {
			Primes => Count(range)
			Faulty => if (index % 4 == 3) Crash(range) else Count(range)
			Tiles => {
				cols = Lab.ceil_sqrt(jobs)
				side = weight * Lab.pixels_per_weight
				step = (3 * Lab.one) // (cols * side).to_i64_wrap()
				col = (index % cols).to_i64_wrap()
				row = (index // cols).to_i64_wrap()
				span = side.to_i64_wrap() * step
				Tile({ x0: -2 * Lab.one + col * span, y0: -3 * Lab.one // 2 + row * span, step, side, iters: Lab.tile_iters })
			}
		}
	}

	# --------------------------------------------------------------- kernels

	is_prime : U64 -> Bool
	is_prime = |n|
		if n < 2 {
			False
		} else if n % 2 == 0 {
			n == 2
		} else {
			var $d = 3.U64
			var $prime = True
			while $prime and $d * $d <= n {
				if n % $d == 0 {
					$prime = False
				}
				$d = $d + 2
			}
			$prime
		}

	## How many primes are in the range, by trial division: deliberately
	## plain, so its cost grows with the range and the answer is easy to
	## check.
	count_primes : Span -> U64
	count_primes = |{ lo, hi }| {
		var $n = lo
		var $count = 0.U64
		while $n < hi {
			if Lab.is_prime($n) {
				$count = $count + 1
			}
			$n = $n + 1
		}
		$count
	}

	## The iterations before the point `c` escapes the radius-2 disk, at most
	## `iters`. `z` stays below 7 in magnitude before every test, so every
	## product fits in 38 bits.
	escape : I64, I64, U64 -> U8
	escape = |cr, ci, iters| {
		var $zr = 0.I64
		var $zi = 0.I64
		var $n = 0.U64
		var $going = True
		while $going and $n < iters {
			zr2 = ($zr * $zr).shr_wrap(16)
			zi2 = ($zi * $zi).shr_wrap(16)
			if zr2 + zi2 > 4 * Lab.one {
				$going = False
			} else {
				$zi = (2 * $zr * $zi).shr_wrap(16) + ci
				$zr = zr2 - zi2 + cr
				$n = $n + 1
			}
		}
		$n.to_u8_wrap()
	}

	## The tile's escape counts, one byte per pixel, row by row.
	tile : TileSpec -> List(U8)
	tile = |{ x0, y0, step, side, iters }| {
		var $out = List.with_capacity(side * side)
		var $py = 0.U64
		while $py < side {
			ci = y0 + $py.to_i64_wrap() * step
			var $px = 0.U64
			while $px < side {
				$out = $out.append(Lab.escape(x0 + $px.to_i64_wrap() * step, ci, iters))
				$px = $px + 1
			}
			$py = $py + 1
		}
		$out
	}

	fnv_offset : U32
	fnv_offset = 2166136261

	fnv_prime : U32
	fnv_prime = 16777619

	fnv_byte : U32, U8 -> U32
	fnv_byte = |h, b| h.bitwise_xor(b.to_u32()).times_wrap(Lab.fnv_prime)

	## The 32-bit FNV-1a hash of some bytes.
	fnv : List(U8) -> U32
	fnv = |bytes| bytes.fold(Lab.fnv_offset, Lab.fnv_byte)

	## What the page keeps of a tile.
	summarize : List(U8) -> TileSummary
	summarize = |bytes| { bytes: bytes.len(), escapes: bytes.fold(0, |sum, b| sum + b.to_u64()), hash: Lab.fnv(bytes) }

	# ------------------------------------------------------------------ runs

	## The jobs of run `run` with parameters `p`, the first `window` admitted.
	jobs_for : Params, U64 -> List(Job)
	jobs_for = |p, run| {
		var $jobs = List.with_capacity(p.jobs)
		var $i = 0.U64
		while $i < p.jobs {
			$jobs = $jobs.append({ index: $i, run, attempt: 0, deadline_ms: p.deadline_ms, task: Lab.task_of(p, $i), phase: Waiting })
			$i = $i + 1
		}
		Lab.admit($jobs)
	}

	is_running : Job -> Bool
	is_running = |job|
		match job.phase {
			Running => True
			_ => False
		}

	is_waiting : Job -> Bool
	is_waiting = |job|
		match job.phase {
			Waiting => True
			_ => False
		}

	## Admit waiting jobs, lowest index first, while fewer than `window` are
	## running. Linear in the run's jobs.
	admit : List(Job) -> List(Job)
	admit = |jobs| {
		var $running = jobs.count_if(Lab.is_running)
		var $out = jobs
		var $i = 0.U64
		while $running < Lab.window and $i < jobs.len() {
			match $out.get($i) {
				Ok(job) if Lab.is_waiting(job) => {
					$out = $out.set($i, { ..job, phase: Running }) ?? $out
					$running = $running + 1
				}
				_ => {}
			}
			$i = $i + 1
		}
		$out
	}

	## Whether any job is still waiting or running.
	active : S -> Bool
	active = |s| s.jobs.any(|j| Lab.is_running(j) or Lab.is_waiting(j))

	## Start a run with the current parameters; one already going is
	## superseded. Invalid parameters start nothing.
	start : S -> S
	start = |s|
		match Lab.params(s) {
			Ok(p) => {
				run = s.run + 1
				{ ..s, run, jobs: Lab.jobs_for(p, run) }
			}
			Err(_) => s
		}

	## Stop every job that has not finished. Finished jobs keep their answers.
	cancel : S -> S
	cancel = |s| {
		..s,
		jobs: s.jobs.map(
			|j| match j.phase {
				Waiting | Running => { ..j, phase: Cancelled }
				_ => j
			},
		),
	}

	## Drop the run and its jobs.
	reset : S -> S
	reset = |s| { ..s, jobs: [], refused: 0 }

	## A parameter changed: while a run is going, it restarts with the new
	## parameters (when they are valid), superseding the old run's jobs.
	edited : S -> S
	edited = |s| if (Lab.active(s) and Lab.problem(s) == "") Lab.start(s) else s

	## What job `job`'s effect site wants.
	want_of : Job -> Want
	want_of = |job|
		match job.phase {
			Running => Run({ run: job.run, index: job.index, attempt: job.attempt, deadline_ms: job.deadline_ms, task: job.task })
			_ => Hold
		}

	## A job's request came back. A refusal sends the job back to waiting
	## for another attempt; anything else finishes it and admits the next
	## waiting job.
	finish : S, { run : U64, index : U64, attempt : U64 }, Try(Answer, Worker.Error) -> S
	finish = |s, { run, index, attempt }, outcome|
		match s.jobs.get(index) {
			Ok(job) if job.run == run and job.attempt == attempt and Lab.is_running(job) => {
				(next, refused) =
					match outcome {
						Ok(answer) => ({ ..job, phase: Done(answer) }, 0)
						Err(Timeout) => ({ ..job, phase: TimedOut }, 0)
						Err(Lost(fault)) => ({ ..job, phase: Lost(fault) }, 0)
						Err(Refused) => ({ ..job, phase: Waiting, attempt: attempt + 1 }, 1)
					}
				{ ..s, jobs: Lab.admit(s.jobs.set(index, next) ?? s.jobs), refused: s.refused + refused }
			}
			_ => s
		}

	# ---------------------------------------------------------------- totals

	## A job's contribution to the checksum.
	digest : Answer -> U32
	digest = |answer|
		match answer {
			Primes(n) => n.to_u32_wrap()
			Tile({ hash, .. }) => hash
		}

	empty_tally : Tally
	empty_tally = { total: 0, waiting: 0, running: 0, done: 0, timed_out: 0, lost: 0, cancelled: 0, primes: 0, tile_bytes: 0, checksum: Lab.fnv_offset }

	## Count a run's jobs by phase and fold the answers. The checksum is the
	## FNV-1a hash of every answer's digest (a prime count, or a tile's hash)
	## as four little-endian bytes, in job order, so it does not depend on
	## the order the answers arrived in.
	tally : List(Job) -> Tally
	tally = |jobs|
		jobs.fold(
			Lab.empty_tally,
			|t0, job| {
				t = { ..t0, total: t0.total + 1 }
				match job.phase {
					Waiting => { ..t, waiting: t.waiting + 1 }
					Running => { ..t, running: t.running + 1 }
					TimedOut => { ..t, timed_out: t.timed_out + 1 }
					Lost(_) => { ..t, lost: t.lost + 1 }
					Cancelled => { ..t, cancelled: t.cancelled + 1 }
					Done(answer) => {
						d = Lab.digest(answer)
						h = [0, 8, 16, 24].fold(t.checksum, |acc, shift| Lab.fnv_byte(acc, d.shr_zf_wrap(shift).to_u8_wrap()))
						match answer {
							Primes(n) => { ..t, done: t.done + 1, primes: t.primes + n, checksum: h }
							Tile({ bytes, .. }) => { ..t, done: t.done + 1, tile_bytes: t.tile_bytes + bytes, checksum: h }
						}
					}
				}
			},
		)

	# --------------------------------------------------------------- display

	hex_digit : U32 -> Str
	hex_digit = |d| ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"].get(d.to_u64()) ?? "?"

	## Eight lower-case hex digits.
	hex : U32 -> Str
	hex = |n| [28, 24, 20, 16, 12, 8, 4, 0].fold("", |acc, shift| Str.concat(acc, Lab.hex_digit(n.shr_zf_wrap(shift).bitwise_and(15))))

	checksum_text : Tally -> Str
	checksum_text = |t|
		if t.total == 0 {
			"no run"
		} else if t.done == t.total {
			Lab.hex(t.checksum)
		} else if t.waiting + t.running > 0 {
			"pending"
		} else {
			"incomplete"
		}

	progress_text : Tally -> Str
	progress_text = |t| "${t.done.to_str()} of ${t.total.to_str()} done"

	describe : Task -> Str
	describe = |task|
		match task {
			Count({ lo, hi }) => "primes in [${lo.to_str()}, ${hi.to_str()})"
			Crash({ lo, hi }) => "primes in [${lo.to_str()}, ${hi.to_str()}), crashing program"
			Tile({ side, .. }) => "tile of ${side.to_str()} by ${side.to_str()} pixels"
		}

	fault_text : Engine.WorkFault -> Str
	fault_text = |fault|
		match fault {
			Contract => "contract"
			ResourceLimit => "resource limit"
			OutOfMemory => "out of memory"
			AppCrash => "app crash"
			ExpectFailed => "expect failed"
			Unavailable => "no workers"
			Executor => "worker failed"
		}

	phase_text : Phase -> Str
	phase_text = |phase|
		match phase {
			Waiting => "waiting"
			Running => "running"
			Done(Primes(n)) => "done: ${n.to_str()} primes"
			Done(Tile({ bytes, hash, .. })) => "done: ${bytes.to_str()} bytes, hash ${Lab.hex(hash)}"
			TimedOut => "timed out"
			Lost(fault) => "lost: ${Lab.fault_text(fault)}"
			Cancelled => "cancelled"
		}

	## The badge tone, a second projection of the phase.
	phase_class : Phase -> Str
	phase_class = |phase|
		match phase {
			Waiting => "badge badge-neutral"
			Running => "badge badge-info"
			Done(_) => "badge badge-ok"
			TimedOut => "badge badge-warn"
			Lost(_) => "badge badge-danger"
			Cancelled => "badge badge-neutral"
		}
}

## The first primes from one million, and the edges of a range.
expect {
	actual = [Lab.count_primes({ lo: 0, hi: 30 }), Lab.count_primes({ lo: 1000000, hi: 1002000 }), Lab.count_primes({ lo: 2, hi: 3 })]
	actual == [10, 152, 1]
}

## Arithmetic shifts of negative fixed-point products round down, like a
## floor division.
expect (-5.I64).shr_wrap(1) == -3

## The origin never escapes; a point far outside escapes at once.
expect [Lab.escape(0, 0, 96), Lab.escape(2 * Lab.one, 2 * Lab.one, 96)] == [96, 1]

## FNV-1a of the empty input and of "a".
expect [Lab.fnv([]), Lab.fnv([97])] == [2166136261, 3826002220]

## Hex is eight lower-case digits.
expect [Lab.hex(0), Lab.hex(3826002220)] == ["00000000", "e40c292c"]

## A run admits `window` jobs and keeps the rest waiting; a finished job
## admits the next.
expect {
	s0 = Lab.start({ ..Lab.initial, jobs_text: "20", weight_text: "1" })
	t0 = Lab.tally(s0.jobs)
	s1 = Lab.finish(s0, { run: 1, index: 3, attempt: 0 }, Ok(Primes(7)))
	t1 = Lab.tally(s1.jobs)
	actual = [t0.running, t0.waiting, t1.running, t1.waiting, t1.done]
	actual == [15, 5, 15, 4, 1]
}

## A refused job waits for another attempt, and a stale answer changes
## nothing.
expect {
	s0 = Lab.start({ ..Lab.initial, jobs_text: "2", weight_text: "1" })
	s1 = Lab.finish(s0, { run: 1, index: 1, attempt: 0 }, Err(Refused))
	job = s1.jobs.get(1) ?? crash "no job"
	stale = Lab.finish(s1, { run: 1, index: 1, attempt: 0 }, Ok(Primes(1)))
	[job.attempt, s1.refused, Lab.tally(stale.jobs).done] == [1, 1, 0]
}

## Invalid parameters are explained and start nothing.
expect {
	s = { ..Lab.initial, jobs_text: "65" }
	[Lab.problem(s), Str.inspect(Lab.start(s).run)] == ["Jobs must be a whole number from 1 to 64.", "0"]
}
