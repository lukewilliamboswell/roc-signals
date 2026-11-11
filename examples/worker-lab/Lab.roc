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
## The `Draw` workload draws the Mandelbrot set as horizontal strips, one
## job each. A strip's job answers a small BMP file; the page asks for a URL
## to show each strip as it arrives, and once every strip is drawn a last job
## composes them into one picture to show and save. A drawn strip waiting
## for its URL still holds a slot of the bound, and while strips are drawn
## the page's clock holds another, so admission counts both.
##
## Nothing in here builds markup.
Lab := [].{

	## The awaited requests the program allows in flight at once.
	max_inflight : U64
	max_inflight = 16

	## Jobs in flight at once: the bound less the heartbeat's interval.
	window : U64
	window = Lab.max_inflight - 1

	## The most jobs a run can have: enough rows to keep the window busy for
	## a long while, few enough that the job grid stays readable and each
	## finished job's admission scan stays cheap.
	max_jobs : U64
	max_jobs = 256

	## The heaviest weight a job can have.
	max_weight : U64
	max_weight = 256

	## The longest deadline the platform honours (ten minutes).
	max_deadline_ms : U64
	max_deadline_ms = 600000

	## The most strips a picture has. The page holds every strip and the
	## composed picture as files, and an app holds at most 64 files at once;
	## the job that composes them holds every strip and its builder, under
	## the same bound. Sixty leaves room for a picture kept to save.
	max_strips : U64
	max_strips = 60

	## The heaviest weight a picture can have: 2048 pixels wide.
	max_draw_weight : U64
	max_draw_weight = 16

	## The workloads a run can be made of. `Faulty` is `Primes` with every
	## fourth job sent to a task that always crashes, to show that a
	## crashed worker loses only its own job. `Draw` draws one picture of the
	## Mandelbrot set, a strip per job.
	Workload : [Primes, Tiles, Faulty, Draw]

	## A half-open range of numbers to count primes in.
	Span : { lo : U64, hi : U64 }

	## One tile of the escape-time image of the Mandelbrot set, in 16.16
	## fixed point: the top-left point, the distance between pixels, the side
	## in pixels and the iteration limit. Integer arithmetic makes every
	## pixel exactly reproducible by an independent implementation.
	TileSpec : { x0 : I64, y0 : I64, step : I64, side : U64, iters : U64 }

	## One horizontal strip of a picture, in the same fixed point as a tile:
	## its place from the top, the top-left point, the distance between
	## pixels, its width and rows in pixels, and the iteration limit.
	StripSpec : { index : U64, x0 : I64, y0 : I64, step : I64, width : U64, rows : U64, iters : U64 }

	## What one job asks a worker to do.
	Task : [Count(Span), Crash(Span), Tile(TileSpec), Strip(StripSpec)]

	## A tile as the page keeps it: its size, the sum of its escape counts,
	## and the FNV-1a hash of its bytes. The bytes themselves are not kept.
	TileSummary : { bytes : U64, escapes : U64, hash : U32 }

	## A strip's answer: the strip as a BMP file the page can show, and the
	## FNV-1a hash and the sum of its escape counts, which the worker
	## computed. The pixels never enter the page's memory.
	Drawn : { file : Engine.File, hash : U32, escapes : U64 }

	## Whether a drawn strip can be shown: its URL is being asked for, it
	## has one, or the page could not make one.
	Shown : [Asking, Shown(Str), Unshown(Str)]

	## A job's answer.
	Answer : [Primes(U64), Tile(TileSummary), Strip({ drawn : Drawn, shown : Shown })]

	## Where a job is. `Failed` is a task's own error, described: a strip
	## over the output bound, say.
	Phase : [Waiting, Running, Done(Answer), TimedOut, Lost(Engine.WorkFault), Failed(Str), Cancelled]

	## Why a job gave no answer: what every task can end with, and a task's
	## own error, described.
	Ended : [Timeout, Refused, Lost(Engine.WorkFault), Failed(Str)]

	## The strips of a finished drawing, in order, and the picture they make.
	Composition : { name : Str, width : U64, height : U64, strips : List(Engine.File) }

	## A strip as the picture shows it: waiting for a worker, being drawn
	## (or waiting for its URL), drawn at a URL, or missing and why.
	Look : [Waiting, Drawing, Drawn(Str), Missing(Str)]

	## One band of the picture: its strip's place, size and look.
	Band : { index : U64, width : U64, rows : U64, look : Look }

	## One job of a run. `run` and `attempt` make each request distinct: a new
	## run, or another attempt after a refusal, is a new value for the row's
	## effect site, which then issues again.
	Job : { index : U64, run : U64, attempt : U64, deadline : [Unlimited, Ms(U32)], task : Task, phase : Phase }

	## The validated parameters of a run.
	Params : { workload : Workload, jobs : U64, weight : U64, deadline : [Unlimited, Ms(U32)] }

	## The page's state: the parameters as typed, the run's serial, its jobs,
	## the refusals counted since the last reset, the ticks of the page's
	## clock counted while strips were drawn, and the picture the user last
	## asked to save.
	S : { workload : Workload, jobs_text : Str, weight_text : Str, deadline_text : Str, run : U64, jobs : List(Job), refused : U64, ticks : U64, save : Engine.Outbox(Engine.File) }

	## What a row's effect site wants: a run of its job's task, or nothing.
	Want : [Run({ run : U64, index : U64, attempt : U64, deadline : [Unlimited, Ms(U32)], task : Task }), Hold]

	## What a row's URL site wants: a URL for its drawn strip, or nothing.
	UrlWant : [Show({ run : U64, index : U64, attempt : U64, file : Engine.File }), Hold]

	## The totals over a run's jobs.
	Tally : { total : U64, waiting : U64, running : U64, done : U64, timed_out : U64, lost : U64, failed : U64, cancelled : U64, primes : U64, tile_bytes : U64, checksum : U32 }

	initial : S
	initial = { workload: Primes, jobs_text: "8", weight_text: "4", deadline_text: "0", run: 0, jobs: [], refused: 0, ticks: 0, save: Engine.outbox({}) }

	# ------------------------------------------------------------ parameters

	workload_from_str : Str -> Workload
	workload_from_str = |text|
		match text {
			"tiles" => Tiles
			"faulty" => Faulty
			"draw" => Draw
			_ => Primes
		}

	## The `select` value, and the only place it is spelled.
	workload_to_str : Workload -> Str
	workload_to_str = |workload|
		match workload {
			Primes => "primes"
			Tiles => "tiles"
			Faulty => "faulty"
			Draw => "draw"
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
		jobs =
			if s.workload == Draw {
				Lab.bounded(s.jobs_text, 1, Lab.max_strips) ? |_| Invalid("A picture has from 1 to ${Lab.max_strips.to_str()} strips: the page holds every strip, and the picture, as a file.")
			} else {
				Lab.bounded(s.jobs_text, 1, Lab.max_jobs) ? |_| Invalid("Jobs must be a whole number from 1 to ${Lab.max_jobs.to_str()}.")
			}
		weight =
			if s.workload == Draw {
				Lab.bounded(s.weight_text, 1, Lab.max_draw_weight) ? |_| Invalid("A picture's weight is from 1 to ${Lab.max_draw_weight.to_str()}, ${Lab.pixels_per_draw_weight.to_str()} pixels of width each.")
			} else {
				Lab.bounded(s.weight_text, 1, Lab.max_weight) ? |_| Invalid("Weight must be a whole number from 1 to ${Lab.max_weight.to_str()}.")
			}
		deadline = Lab.bounded(s.deadline_text, 0, Lab.max_deadline_ms) ? |_| Invalid("Deadline must be a number of milliseconds from 0 (none) to ${Lab.max_deadline_ms.to_str()}.")
		Ok({ workload: s.workload, jobs, weight, deadline: if (deadline == 0) Unlimited else Ms(deadline.to_u32_wrap()) })
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

	## Pixels of a picture's width per unit of weight; a multiple of 4, so
	## a BMP row of one byte per pixel needs no padding.
	pixels_per_draw_weight : U64
	pixels_per_draw_weight = 128

	## A picture's iteration limit: the most an escape count's byte holds.
	draw_iters : U64
	draw_iters = 255

	## The name of the task that draws a strip.
	strip_task : Str
	strip_task = "roc-signals.example/worker-lab/strip"

	## The name of the task that composes a drawing's strips.
	compose_task : Str
	compose_task = "roc-signals.example/worker-lab/compose"

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
	## columns as rows, each tile `weight * 4` pixels on a side. A picture
	## spans x from -2.25 to 0.75, `weight * 128` pixels, and about two
	## thirds as many rows, centred on the real axis, cut into `jobs` strips
	## of equal height from the top.
	task_of : Params, U64 -> Task
	task_of = |{ workload, jobs, weight, .. }, index| {
		width = weight * Lab.numbers_per_weight
		lo = Lab.first_number + index * width
		range = { lo, hi: lo + width }
		match workload {
			Primes => Count(range)
			Faulty => if (index % 4 == 3) Crash(range) else Count(range)
			Draw => {
				pixels = weight * Lab.pixels_per_draw_weight
				rows = ((pixels * 2) // 3 + jobs - 1) // jobs
				step = (3 * Lab.one) // pixels.to_i64_wrap()
				top = 0 - (rows * jobs).to_i64_wrap() * step // 2
				Strip({ index, x0: -9 * Lab.one // 4, y0: top + (index * rows).to_i64_wrap() * step, step, width: pixels, rows, iters: Lab.draw_iters })
			}
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

	## The escape counts of a rectangle of pixels, one byte per pixel, row
	## by row from the top-left point.
	escapes : { x0 : I64, y0 : I64, step : I64, width : U64, rows : U64, iters : U64 } -> List(U8)
	escapes = |{ x0, y0, step, width, rows, iters }| {
		var $out = List.with_capacity(width * rows)
		var $py = 0.U64
		while $py < rows {
			ci = y0 + $py.to_i64_wrap() * step
			var $px = 0.U64
			while $px < width {
				$out = $out.append(Lab.escape(x0 + $px.to_i64_wrap() * step, ci, iters))
				$px = $px + 1
			}
			$py = $py + 1
		}
		$out
	}

	## The tile's escape counts, one byte per pixel, row by row.
	tile : TileSpec -> List(U8)
	tile = |{ x0, y0, step, side, iters }| Lab.escapes({ x0, y0, step, width: side, rows: side, iters })

	## A strip's escape counts, which are also its pixels: each byte is an
	## index into the palette.
	strip : StripSpec -> List(U8)
	strip = |{ x0, y0, step, width, rows, iters, .. }| Lab.escapes({ x0, y0, step, width, rows, iters })

	# ------------------------------------------------------------- pictures

	## The bytes of a BMP file before its pixels: the file header, the
	## information header and the palette. Every strip and the picture
	## start with one.
	bmp_header_bytes : U64
	bmp_header_bytes = 1078

	## `n` as `count` little-endian bytes.
	little_endian : U64, U64 -> List(U8)
	little_endian = |n, count| {
		var $out = List.with_capacity(count)
		var $rest = n
		var $i = 0.U64
		while $i < count {
			$out = $out.append(($rest % 256).to_u8_wrap())
			$rest = $rest // 256
			$i = $i + 1
		}
		$out
	}

	## The header of an 8-bit palette BMP of `width` by `height` pixels,
	## stored top row first (a negative height), so strips appended in
	## order make the picture. `width` is a multiple of 4, so its rows need
	## no padding. The palette is `Lab.palette`.
	bmp_header : { width : U64, height : U64 } -> List(U8)
	bmp_header = |{ width, height }| {
		pixels = width * height
		[66, 77]
			.concat(Lab.little_endian(Lab.bmp_header_bytes + pixels, 4))
			.concat(Lab.little_endian(0, 4))
			.concat(Lab.little_endian(Lab.bmp_header_bytes, 4))
			.concat(Lab.little_endian(40, 4))
			.concat(Lab.little_endian(width, 4))
			.concat(Lab.little_endian(4294967296 - height, 4))
			.concat(Lab.little_endian(1, 2))
			.concat(Lab.little_endian(8, 2))
			.concat(Lab.little_endian(0, 4))
			.concat(Lab.little_endian(pixels, 4))
			.concat(Lab.little_endian(2835, 4))
			.concat(Lab.little_endian(2835, 4))
			.concat(Lab.little_endian(256, 4))
			.concat(Lab.little_endian(0, 4))
			.concat(Lab.palette({}))
	}

	## The colours an escape count cycles through, every 64 counts: dark
	## blue, blue, white, gold, near black, and back.
	stops : List({ at : U64, r : U64, g : U64, b : U64 })
	stops = [
		{ at: 0, r: 0, g: 7, b: 100 },
		{ at: 41, r: 32, g: 107, b: 203 },
		{ at: 107, r: 237, g: 255, b: 255 },
		{ at: 164, r: 255, g: 170, b: 0 },
		{ at: 219, r: 0, g: 2, b: 0 },
		{ at: 256, r: 0, g: 7, b: 100 },
	]

	black : { r : U64, g : U64, b : U64 }
	black = { r: 0, g: 0, b: 0 }

	## Between `a` and `b`, `num` parts of `den` of the way.
	between : U64, U64, U64, U64 -> U64
	between = |a, b, num, den| (a * (den - num) + b * num) // den

	## The colour at position `at` (0 to 255) of the cycle.
	colour : U64 -> { r : U64, g : U64, b : U64 }
	colour = |at| {
		var $i = 0.U64
		var $found = { r: 0, g: 0, b: 0 }
		while $i + 1 < Lab.stops.len() {
			lo = Lab.stops.get($i) ?? { at: 0, r: 0, g: 0, b: 0 }
			hi = Lab.stops.get($i + 1) ?? lo
			if at >= lo.at and at < hi.at {
				num = at - lo.at
				den = hi.at - lo.at
				$found = { r: Lab.between(lo.r, hi.r, num, den), g: Lab.between(lo.g, hi.g, num, den), b: Lab.between(lo.b, hi.b, num, den) }
			}
			$i = $i + 1
		}
		$found
	}

	## The 256 palette entries, blue, green, red and a zero byte each: a
	## point that never escaped (`draw_iters` counts) is black.
	palette : {} -> List(U8)
	palette = |_| {
		var $out = List.with_capacity(1024)
		var $n = 0.U64
		while $n < 256 {
			{ r, g, b } = if ($n >= Lab.draw_iters) Lab.black else Lab.colour(($n * 4) % 256)
			$out = $out.append(b.to_u8_wrap()).append(g.to_u8_wrap()).append(r.to_u8_wrap()).append(0)
			$n = $n + 1
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
			$jobs = $jobs.append({ index: $i, run, attempt: 0, deadline: p.deadline, task: Lab.task_of(p, $i), phase: Waiting })
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

	is_strip : Job -> Bool
	is_strip = |job|
		match job.task {
			Strip(_) => True
			_ => False
		}

	## Whether a job holds a slot of the in-flight bound: it is running, or
	## it is a drawn strip whose URL the page is asking for.
	occupies : Job -> Bool
	occupies = |job|
		match job.phase {
			Running => True
			Done(Strip({ shown: Asking, .. })) => True
			_ => False
		}

	## The slots a run's jobs may hold: the window, less one for the page's
	## clock while a picture is drawn.
	window_of : List(Job) -> U64
	window_of = |jobs| if (jobs.any(Lab.is_strip)) Lab.window - 1 else Lab.window

	## Admit waiting jobs, lowest index first, while fewer than the run's
	## window hold slots. Linear in the run's jobs.
	admit : List(Job) -> List(Job)
	admit = |jobs| {
		slots = Lab.window_of(jobs)
		var $running = jobs.count_if(Lab.occupies)
		var $out = jobs
		var $i = 0.U64
		while $running < slots and $i < jobs.len() {
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
				{ ..s, run, jobs: Lab.jobs_for(p, run), ticks: 0 }
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

	## Whether a job ended without an answer, so it can be asked again.
	is_stopped : Job -> Bool
	is_stopped = |job|
		match job.phase {
			TimedOut | Lost(_) | Failed(_) | Cancelled => True
			_ => False
		}

	## A stopped job as a new attempt, waiting; any other job as it is.
	again : Job -> Job
	again = |job|
		if Lab.is_stopped(job) {
			{ ..job, phase: Waiting, attempt: job.attempt + 1 }
		} else {
			job
		}

	## Ask again for every job that ended without an answer: each goes back
	## to waiting as a new attempt, and the answers so far are kept. A
	## picture with a lost or cancelled strip is finished this way.
	retry : S -> S
	retry = |s| {
		..s,
		jobs: Lab.admit(s.jobs.map(Lab.again)),
	}

	## Drop the run and its jobs, and the picture kept to save.
	reset : S -> S
	reset = |s| { ..s, jobs: [], refused: 0, ticks: 0, save: Engine.outbox({}) }

	## A parameter changed: while a run is going, it restarts with the new
	## parameters (when they are valid), superseding the old run's jobs.
	edited : S -> S
	edited = |s| if (Lab.active(s) and Lab.problem(s) == "") Lab.start(s) else s

	## What job `job`'s effect site wants.
	want_of : Job -> Want
	want_of = |job|
		match job.phase {
			Running => Run({ run: job.run, index: job.index, attempt: job.attempt, deadline: job.deadline, task: job.task })
			_ => Hold
		}

	## A job's request came back. A refusal sends the job back to waiting
	## for another attempt; anything else finishes it and admits the next
	## waiting job. A drawn strip keeps its slot until its URL comes back.
	finish : S, { run : U64, index : U64, attempt : U64 }, Try(Answer, Ended) -> S
	finish = |s, { run, index, attempt }, outcome|
		match s.jobs.get(index) {
			Ok(job) if job.run == run and job.attempt == attempt and Lab.is_running(job) => {
				(next, refused) =
					match outcome {
						Ok(answer) => ({ ..job, phase: Done(answer) }, 0)
						Err(Timeout) => ({ ..job, phase: TimedOut }, 0)
						Err(Lost(fault)) => ({ ..job, phase: Lost(fault) }, 0)
						Err(Failed(why)) => ({ ..job, phase: Failed(why) }, 0)
						Err(Refused) => ({ ..job, phase: Waiting, attempt: attempt + 1 }, 1)
					}
				{ ..s, jobs: Lab.admit(s.jobs.set(index, next) ?? s.jobs), refused: s.refused + refused }
			}
			_ => s
		}

	## The outcomes of a task that has no error of its own, as `Ended`.
	ended : Worker.Error(Worker.Never) -> Ended
	ended = |error|
		match error {
			Timeout => Timeout
			Refused => Refused
			Lost(fault) => Lost(fault)
		}

	## A strip's answer, waiting for its URL.
	drawn : Drawn -> Answer
	drawn = |d| Strip({ drawn: d, shown: Asking })

	## What job `job`'s URL site wants: a URL for the strip it drew.
	url_want : Job -> UrlWant
	url_want = |job|
		match job.phase {
			Done(Strip({ drawn: { file, .. }, shown: Asking })) => Show({ run: job.run, index: job.index, attempt: job.attempt, file })
			_ => Hold
		}

	## A strip's URL came back, or why there is none; either way its slot
	## is free, and the next waiting strip is admitted.
	shown : S, { run : U64, index : U64, attempt : U64 }, Try(Str, Str) -> S
	shown = |s, { run, index, attempt }, outcome|
		match s.jobs.get(index) {
			Ok(job) if job.run == run and job.attempt == attempt =>
				match job.phase {
					Done(Strip({ drawn: d, shown: Asking })) => {
						look = match outcome {
							Ok(url) => Shown(url)
							Err(why) => Unshown(why)
						}
						{ ..s, jobs: Lab.admit(s.jobs.set(index, { ..job, phase: Done(Strip({ drawn: d, shown: look })) }) ?? s.jobs) }
					}
					_ => s
				}
			_ => s
		}

	# -------------------------------------------------------------- pictures

	## Whether strips are being drawn: some strip waits or runs. The page's
	## clock ticks only then.
	drawing : S -> Bool
	drawing = |s| s.jobs.any(|j| Lab.is_strip(j) and (Lab.is_running(j) or Lab.is_waiting(j)))

	## One tick of the page's clock while strips are drawn.
	tick : S -> S
	tick = |s|
		if Lab.drawing(s) {
			{ ..s, ticks: s.ticks + 1 }
		} else {
			s
		}

	## The composition of a run whose every job drew its strip, or `Skip`.
	composition : S -> [Run(Composition), Skip]
	composition = |s| {
		files = s.jobs.fold(
			[],
			|acc, j| match j.phase {
				Done(Strip({ drawn: { file, .. }, .. })) => acc.append(file)
				_ => acc
			},
		)
		match s.jobs.first() {
			Ok({ task: Strip({ width, rows, .. }), .. }) if files.len() == s.jobs.len() => {
				height = rows * files.len()
				Run({ name: "mandelbrot-${width.to_str()}x${height.to_str()}.bmp", width, height, strips: files })
			}
			_ => Skip
		}
	}

	## How a job's strip looks in the picture.
	look_of : Phase -> Look
	look_of = |phase|
		match phase {
			Waiting => Waiting
			Running => Drawing
			Done(Strip({ shown: Asking, .. })) => Drawing
			Done(Strip({ shown: Shown(url), .. })) => Drawn(url)
			Done(Strip({ shown: Unshown(why), .. })) => Missing("drawn, but not shown: ${why}")
			Done(_) => Missing("not a strip")
			TimedOut => Missing("timed out")
			Lost(fault) => Missing("lost: ${Lab.fault_text(fault)}")
			Failed(why) => Missing("failed: ${why}")
			Cancelled => Missing("cancelled")
		}

	## The picture's bands, one per strip of the run, top first.
	bands : List(Job) -> List(Band)
	bands = |jobs|
		jobs.fold(
			[],
			|acc, j| match j.task {
				Strip({ width, rows, .. }) => acc.append({ index: j.index, width, rows, look: Lab.look_of(j.phase) })
				_ => acc
			},
		)

	## What the picture says about its strips.
	picture_text : S -> Str
	picture_text = |s| {
		strips = s.jobs.count_if(Lab.is_strip)
		finished = s.jobs.count_if(|j| Lab.is_strip(j) and Lab.is_done(j))
		left = s.jobs.count_if(|j| Lab.is_strip(j) and (Lab.is_running(j) or Lab.is_waiting(j)))
		if strips == 0 {
			"Choose \"Draw the Mandelbrot set\" and press Start."
		} else if left > 0 {
			"${finished.to_str()} of ${strips.to_str()} strips drawn"
		} else if finished < strips {
			"${finished.to_str()} of ${strips.to_str()} strips drawn; retry the others to finish the picture"
		} else {
			"All ${strips.to_str()} strips drawn"
		}
	}

	is_done : Job -> Bool
	is_done = |job|
		match job.phase {
			Done(_) => True
			_ => False
		}

	## The ticks of the page's clock counted while strips were drawn.
	ticks_text : S -> Str
	ticks_text = |s| if (s.jobs.any(Lab.is_strip)) s.ticks.to_str() else "–"

	## The URL a band shows, or `""` while it has none.
	look_url : Look -> Str
	look_url = |look|
		match look {
			Drawn(url) => url
			_ => ""
		}

	## Why an operation on a file gave nothing, in words.
	file_error_text : Engine.FileError -> Str
	file_error_text = |error|
		match error {
			Unreadable => "the browser could not read the file"
			TooLarge => "the file is too large"
			InvalidUtf8 => "the file is not text"
			Unavailable => "the browser cannot do that here"
			Refused => "too many requests were in flight"
		}

	## Keep `file`, the picture, for the save the user asked for.
	keep_to_save : S, Engine.File -> S
	keep_to_save = |s, file| { ..s, save: s.save.post(file) }

	# ---------------------------------------------------------------- totals

	## A job's contribution to the checksum.
	digest : Answer -> U32
	digest = |answer|
		match answer {
			Primes(n) => n.to_u32_wrap()
			Tile({ hash, .. }) => hash
			Strip({ drawn: { hash, .. }, .. }) => hash
		}

	empty_tally : Tally
	empty_tally = { total: 0, waiting: 0, running: 0, done: 0, timed_out: 0, lost: 0, failed: 0, cancelled: 0, primes: 0, tile_bytes: 0, checksum: Lab.fnv_offset }

	## Count a run's jobs by phase and fold the answers. The checksum is the
	## FNV-1a hash of every answer's digest (a prime count, or a tile's or
	## strip's hash)
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
					Failed(_) => { ..t, failed: t.failed + 1 }
					Cancelled => { ..t, cancelled: t.cancelled + 1 }
					Done(answer) => {
						d = Lab.digest(answer)
						h = [0, 8, 16, 24].fold(t.checksum, |acc, shift| Lab.fnv_byte(acc, d.shr_zf_wrap(shift).to_u8_wrap()))
						match answer {
							Primes(n) => { ..t, done: t.done + 1, primes: t.primes + n, checksum: h }
							Tile({ bytes, .. }) => { ..t, done: t.done + 1, tile_bytes: t.tile_bytes + bytes, checksum: h }
							Strip(_) => { ..t, done: t.done + 1, checksum: h }
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

	## Two lower-case hex digits per byte.
	hex_bytes : List(U8) -> Str
	hex_bytes = |bytes| bytes.fold("", |acc, b| Str.concat(Str.concat(acc, Lab.hex_digit(b.to_u32().shr_zf_wrap(4))), Lab.hex_digit(b.to_u32().bitwise_and(15))))

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
			Crash({ lo, hi }) => "primes in [${lo.to_str()}, ${hi.to_str()}), crashing task"
			Tile({ side, .. }) => "tile of ${side.to_str()} by ${side.to_str()} pixels"
			Strip({ index, width, rows, .. }) => "strip of ${width.to_str()} by ${rows.to_str()} pixels, rows ${(index * rows + 1).to_str()} to ${((index + 1) * rows).to_str()}"
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
			Done(Strip({ drawn: { file, hash, .. }, .. })) => "done: ${file.size().to_str()}-byte strip, hash ${Lab.hex(hash)}"
			TimedOut => "timed out"
			Lost(fault) => "lost: ${Lab.fault_text(fault)}"
			Failed(why) => "failed: ${why}"
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
			Failed(_) => "badge badge-danger"
			Cancelled => "badge badge-neutral"
		}

	## A band's classes: a placeholder of the strip's shape until it is
	## drawn, tinted by where its strip is.
	look_class : Look -> Str
	look_class = |look|
		match look {
			Waiting => "flex items-center justify-center bg-zinc-100 text-xs text-zinc-500"
			Drawing => "flex items-center justify-center bg-sky-100 text-xs text-sky-700 animate-pulse"
			Drawn(_) => "block"
			Missing(_) => "flex items-center justify-center bg-red-50 text-xs text-red-700"
		}

	## What a band says while it has no picture.
	look_text : Look -> Str
	look_text = |look|
		match look {
			Waiting => "waiting"
			Drawing => "drawing"
			Drawn(_) => ""
			Missing(why) => why
		}

	## A band's shape, so a placeholder takes the room its strip will.
	look_style : Band -> Str
	look_style = |{ width, rows, .. }| "aspect-ratio: ${width.to_str()} / ${rows.to_str()}"
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
	s = { ..Lab.initial, jobs_text: "257" }
	[Lab.problem(s), Str.inspect(Lab.start(s).run)] == ["Jobs must be a whole number from 1 to 256.", "0"]
}

## A BMP header is 1078 bytes: its size, pixel offset, width and a negative
## (top row first) height in place, the cycle's first colour first, and
## black for a point that never escaped.
expect {
	h = Lab.bmp_header({ width: 128, height: 87 })
	actual = {
		len: h.len(),
		magic: h.sublist({ start: 0, len: 2 }),
		size: h.sublist({ start: 2, len: 4 }),
		offset: h.sublist({ start: 10, len: 4 }),
		width: h.sublist({ start: 18, len: 4 }),
		height: h.sublist({ start: 22, len: 4 }),
		first_colour: h.sublist({ start: 54, len: 4 }),
		never_escaped: h.sublist({ start: 54 + 255 * 4, len: 4 }),
	}
	actual == { len: 1078, magic: [66, 77], size: [182, 47, 0, 0], offset: [54, 4, 0, 0], width: [128, 0, 0, 0], height: [169, 255, 255, 255], first_colour: [100, 7, 0, 0], never_escaped: [0, 0, 0, 0] }
}

## A picture's strips are of equal height and stack from the top: the
## second starts where the first ends.
expect {
	p = { workload: Draw, jobs: 3, weight: 1, deadline: Unlimited }
	match (Lab.task_of(p, 0), Lab.task_of(p, 1)) {
		(Strip(a), Strip(b)) => [a.width, a.rows, b.index, (b.y0 - a.y0).to_u64_wrap()] == [128, 29, 1, 29 * 1536]
		_ => Bool.False
	}
}

## A drawing admits one strip fewer than the window, since the page's
## clock holds a slot, and composes nothing until every strip is drawn.
expect {
	s = Lab.start({ ..Lab.initial, workload: Draw, jobs_text: "20", weight_text: "1" })
	actual = { running: Lab.tally(s.jobs).running, drawing: Lab.drawing(s), composed: Lab.composition(s) == Skip, bands: Lab.bands(s.jobs).len() }
	actual == { running: 14, drawing: Bool.True, composed: Bool.True, bands: 20 }
}

## A picture's limits are explained.
expect {
	s = { ..Lab.initial, workload: Draw, jobs_text: "61" }
	Lab.problem(s) == "A picture has from 1 to 60 strips: the page holds every strip, and the picture, as a file."
}
