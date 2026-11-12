import pf.Engine
import pf.Table
import pf.Worker

## Worker Lab's model: the parameters a person sets, the jobs of a run and
## their phases, the pure kernels the workers run, and the totals.
##
## A run is a table of jobs by index, one per row, each with its task. A
## job is `Waiting` until the page admits it, `Running` while its request is in
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

	## The longest timeout the platform honours (ten minutes).
	max_timeout_ms : U64
	max_timeout_ms = 600000

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

	## One job of a run. `run` and `attempt` make each request distinct: a new
	## run, or another attempt after a refusal, is a new value for the row's
	## effect site, which then issues again.
	Job : { index : U64, run : U64, attempt : U64, timeout : [Unlimited, Ms(U32)], task : Task, phase : Phase }

	## A run's jobs, by index: the keys of a run of `n` jobs are 0 to `n - 1`.
	Jobs : Table(U64, Job)

	## Which of a run's jobs a list shows: every job, or the strips of a
	## picture. Both lists are in index order.
	Listing : [Every, Strips]

	## The validated parameters of a run.
	Params : { workload : Workload, jobs : U64, weight : U64, timeout : [Unlimited, Ms(U32)] }

	## The parameters as typed.
	Form : { workload : Workload, jobs_text : Str, weight_text : Str, timeout_text : Str }

	## What a row's effect site wants: a run of its job's task, or nothing.
	Want : [Run({ run : U64, index : U64, attempt : U64, timeout : [Unlimited, Ms(U32)], task : Task }), Hold]

	## What a row's URL site wants: a URL for its drawn strip, or nothing.
	UrlWant : [Show({ run : U64, index : U64, attempt : U64, file : Engine.File }), Hold]

	## The totals over a run's jobs.
	Tally : { total : U64, waiting : U64, running : U64, done : U64, timed_out : U64, lost : U64, failed : U64, cancelled : U64, primes : U64, tile_bytes : U64, checksum : U32 }

	## The parameters a page starts with.
	form : Form
	form = { workload: Primes, jobs_text: "8", weight_text: "4", timeout_text: "0" }

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
	params : Form -> Try(Params, [Invalid(Str)])
	params = |typed| {
		jobs =
			if typed.workload == Draw {
				Lab.bounded(typed.jobs_text, 1, Lab.max_strips) ? |_| Invalid("A picture has from 1 to ${Lab.max_strips.to_str()} strips: the page holds every strip, and the picture, as a file.")
			} else {
				Lab.bounded(typed.jobs_text, 1, Lab.max_jobs) ? |_| Invalid("Jobs must be a whole number from 1 to ${Lab.max_jobs.to_str()}.")
			}
		weight =
			if typed.workload == Draw {
				Lab.bounded(typed.weight_text, 1, Lab.max_draw_weight) ? |_| Invalid("A picture's weight is from 1 to ${Lab.max_draw_weight.to_str()}, ${Lab.pixels_per_draw_weight.to_str()} pixels of width each.")
			} else {
				Lab.bounded(typed.weight_text, 1, Lab.max_weight) ? |_| Invalid("Weight must be a whole number from 1 to ${Lab.max_weight.to_str()}.")
			}
		timeout = Lab.bounded(typed.timeout_text, 0, Lab.max_timeout_ms) ? |_| Invalid("Timeout must be a number of milliseconds from 0 (none) to ${Lab.max_timeout_ms.to_str()}.")
		Ok({ workload: typed.workload, jobs, weight, timeout: if (timeout == 0) Unlimited else Ms(timeout.to_u32_wrap()) })
	}

	## Why the parameters cannot start a run, or `""`.
	problem : Form -> Str
	problem = |typed|
		match Lab.params(typed) {
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

	## The jobs of run `run` with parameters `p`, every one waiting: the
	## rows a run's table is loaded with.
	jobs_for : Params, U64 -> List({ key : U64, row : Job })
	jobs_for = |p, run| {
		var $rows = List.with_capacity(p.jobs)
		var $i = 0.U64
		while $i < p.jobs {
			$rows = $rows.append({ key: $i, row: { index: $i, run, attempt: 0, timeout: p.timeout, task: Lab.task_of(p, $i), phase: Waiting } })
			$i = $i + 1
		}
		$rows
	}

	## How a listing selects and orders a run's jobs: the `plan` of both
	## views of the run, the job grid and the picture's bands.
	listed : Listing -> Engine.QueryPlan(U64, Job, U64)
	listed = |listing| {
		keep: |_, job| match listing {
			Every => True
			Strips => Lab.is_strip(job)
		},
		sort: |index, _| index,
		compare: |a, b| if (a < b) Before else if (a > b) After else Same,
	}

	## Fold over a run's jobs in index order.
	fold_jobs : Jobs, state, (state, Job -> state) -> state
	fold_jobs = |jobs, init, step| {
		var $state = init
		var $index = 0.U64
		while $index < jobs.len() {
			match jobs.get($index) {
				Ok(job) => {
					$state = step($state, job)
				}
				Err(Missing) => {}
			}
			$index = $index + 1
		}
		$state
	}

	## How many of a run's jobs `test` holds for.
	count_jobs : Jobs, (Job -> Bool) -> U64
	count_jobs = |jobs, test| jobs.fold(0, |n, _, job| if (test(job)) n + 1 else n)

	## Whether `test` holds for any of a run's jobs.
	any_job : Jobs, (Job -> Bool) -> Bool
	any_job = |jobs, test| Lab.count_jobs(jobs, test) > 0

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

	## Admit waiting jobs, lowest index first, while fewer than the run's
	## slots are held: the window, less one for the page's clock while a
	## picture is drawn. Linear in the run's jobs.
	admit : Jobs -> Jobs
	admit = |jobs| {
		seen = Lab.fold_jobs(
			jobs,
			{ held: 0.U64, strips: Bool.False, waiting: [] },
			|acc, job| {
				held: if (Lab.occupies(job)) acc.held + 1 else acc.held,
				strips: acc.strips or Lab.is_strip(job),
				waiting: if (Lab.is_waiting(job)) acc.waiting.append(job.index) else acc.waiting,
			},
		)
		slots = if (seen.strips) Lab.window - 1 else Lab.window
		free = if (slots > seen.held) slots - seen.held else 0
		# A fold over the keys to admit rather than a `while` loop over a
		# `var` holding the table, which copies the table on every
		# iteration in optimised builds (roc-lang/roc#12971).
		seen.waiting.take_first(free).fold(jobs, |table, index| table.update(index, |job| { ..job, phase: Running }))
	}

	## Whether any job is still waiting or running.
	active : Jobs -> Bool
	active = |jobs| Lab.any_job(jobs, |job| Lab.is_running(job) or Lab.is_waiting(job))

	## A job that has not finished, stopped. A finished job keeps its answer.
	cancelled : Job -> Job
	cancelled = |job|
		match job.phase {
			Waiting | Running => { ..job, phase: Cancelled }
			_ => job
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

	## What job `job`'s effect site wants.
	want_of : Job -> Want
	want_of = |job|
		match job.phase {
			Running => Run({ run: job.run, index: job.index, attempt: job.attempt, timeout: job.timeout, task: job.task })
			_ => Hold
		}

	## Whether a job is still the attempt a request was issued for. A new
	## run, or another attempt, is another request.
	is_attempt : Job, { run : U64, attempt : U64 } -> Bool
	is_attempt = |job, { run, attempt }| job.run == run and job.attempt == attempt

	## A job whose request came back: done with its answer, or how it ended.
	## A refusal sends it back to waiting for another attempt.
	settled : Job, Try(Answer, Ended) -> Job
	settled = |job, outcome|
		match outcome {
			Ok(answer) => { ..job, phase: Done(answer) }
			Err(Timeout) => { ..job, phase: TimedOut }
			Err(Lost(fault)) => { ..job, phase: Lost(fault) }
			Err(Failed(why)) => { ..job, phase: Failed(why) }
			Err(Refused) => { ..job, phase: Waiting, attempt: job.attempt + 1 }
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

	## Whether a job is a drawn strip waiting for its URL.
	awaits_url : Job -> Bool
	awaits_url = |job|
		match job.phase {
			Done(Strip({ shown: Asking, .. })) => True
			_ => False
		}

	## A drawn strip whose URL came back, or why there is none. Any other
	## job as it is.
	linked : Job, Try(Str, Str) -> Job
	linked = |job, outcome|
		match job.phase {
			Done(Strip({ drawn: d, shown: Asking })) => {
				look = match outcome {
					Ok(url) => Shown(url)
					Err(why) => Unshown(why)
				}
				{ ..job, phase: Done(Strip({ drawn: d, shown: look })) }
			}
			_ => job
		}

	# -------------------------------------------------------------- pictures

	## Whether strips are being drawn: some strip waits or runs. The page's
	## clock ticks only then.
	drawing : Jobs -> Bool
	drawing = |jobs| Lab.any_job(jobs, |job| Lab.is_strip(job) and (Lab.is_running(job) or Lab.is_waiting(job)))

	## The composition of a run whose every job drew its strip, or `Skip`.
	composition : Jobs -> [Run(Composition), Skip]
	composition = |jobs| {
		files = Lab.fold_jobs(
			jobs,
			[],
			|acc, job| match job.phase {
				Done(Strip({ drawn: { file, .. }, .. })) => acc.append(file)
				_ => acc
			},
		)
		match jobs.get(0) {
			Ok({ task: Strip({ width, rows, .. }), .. }) if files.len() == jobs.len() => {
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

	## What the picture says about its strips.
	picture_text : Jobs -> Str
	picture_text = |jobs| {
		strips = Lab.count_jobs(jobs, Lab.is_strip)
		finished = Lab.count_jobs(jobs, |job| Lab.is_strip(job) and Lab.is_done(job))
		left = Lab.count_jobs(jobs, |job| Lab.is_strip(job) and (Lab.is_running(job) or Lab.is_waiting(job)))
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
	ticks_text : Jobs, U64 -> Str
	ticks_text = |jobs, ticks| if (Lab.any_job(jobs, Lab.is_strip)) ticks.to_str() else "–"

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
	tally : Jobs -> Tally
	tally = |jobs|
		Lab.fold_jobs(
			jobs,
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

	## A strip's shape, so its band's placeholder takes the room the strip
	## will. A job that draws no strip has none.
	strip_style : Job -> Str
	strip_style = |job|
		match job.task {
			Strip({ width, rows, .. }) => "aspect-ratio: ${width.to_str()} / ${rows.to_str()}"
			_ => ""
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

## Invalid parameters are explained.
expect Lab.problem({ ..Lab.form, jobs_text: "257" }) == "Jobs must be a whole number from 1 to 256."

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
	p = { workload: Draw, jobs: 3, weight: 1, timeout: Unlimited }
	match (Lab.task_of(p, 0), Lab.task_of(p, 1)) {
		(Strip(a), Strip(b)) => [a.width, a.rows, b.index, (b.y0 - a.y0).to_u64_wrap()] == [128, 29, 1, 29 * 1536]
		_ => Bool.False
	}
}

## A picture's limits are explained.
expect {
	typed = { ..Lab.form, workload: Draw, jobs_text: "61" }
	Lab.problem(typed) == "A picture has from 1 to 60 strips: the page holds every strip, and the picture, as a file."
}
