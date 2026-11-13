import cli.Env
import cli.Sleep
import cli.Cmd
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout

## Running child processes and reporting progress, for the Roc scripts.
Proc := [].{

	## A program and its arguments, run from `cwd`.
	Job : { program : Str, args : List(Str), cwd : Str }

	show : Job -> Str
	show = |{ program, args, cwd }| "(cd ${cwd} && ${Str.join_with([program].concat(args), " ")})"

	cmd : Job -> Cmd.Command
	cmd = |{ program, args, cwd }| Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str)).cwd(Path.utf8(cwd))

	## Run with the terminal inherited; a non-zero exit is an error.
	run! : Job => Try({}, [CommandFailed(Str)])
	run! = |job| {
		Stdout.line!("RUN ${Proc.show(job)}") ?? {}
		output = Proc.cmd(job).inherit_stdio().run!() ? |e| CommandFailed("${Proc.show(job)}: ${Str.inspect(e)}")
		match output.status {
			Exited(0) => Ok({})
			Exited(code) => Err(CommandFailed("${Proc.show(job)} exited with ${code.to_str()}"))
			Signaled(signal) => Err(CommandFailed("${Proc.show(job)} ended by signal ${signal.to_str()}"))
		}
	}

	## Run with the terminal inherited and return the exit code, for a caller
	## that judges the result itself.
	status! : Job => Try(I32, [CommandFailed(Str)])
	status! = |job| {
		Stdout.line!("RUN ${Proc.show(job)}") ?? {}
		output = Proc.cmd(job).inherit_stdio().run!() ? |e| CommandFailed("${Proc.show(job)}: ${Str.inspect(e)}")
		match output.status {
			Exited(code) => Ok(code)
			Signaled(signal) => Err(CommandFailed("${Proc.show(job)} ended by signal ${signal.to_str()}"))
		}
	}

	## Run and return the exit code and captured stdout, with stderr passed
	## through, for a caller that judges the result itself.
	output! : Job => Try({ code : I32, stdout : List(U8) }, [CommandFailed(Str)])
	output! = |job| {
		output = Proc.cmd(job).stderr(Inherit).output_limit(MaxBytes(256 * 1024 * 1024)).run!() ? |e| CommandFailed("${Proc.show(job)}: ${Str.inspect(e)}")
		match output.status {
			Exited(code) => Ok({ code, stdout: output.stdout_bytes })
			Signaled(signal) => Err(CommandFailed("${Proc.show(job)} ended by signal ${signal.to_str()}"))
		}
	}

	## Run and return the exit code and stdout and stderr together, in order.
	merged! : Job => Try({ code : I32, stdout : List(U8) }, [CommandFailed(Str)])
	merged! = |job| {
		output = Proc.cmd(job).stderr(MergeWithStdout).output_limit(MaxBytes(256 * 1024 * 1024)).run!() ? |e| CommandFailed("${Proc.show(job)}: ${Str.inspect(e)}")
		match output.status {
			Exited(code) => Ok({ code, stdout: output.stdout_bytes })
			Signaled(signal) => Err(CommandFailed("${Proc.show(job)} ended by signal ${signal.to_str()}"))
		}
	}

	## Run at most limit children, replacing a finished child immediately.
	## Captured output is printed whole in input order; results retain that
	## order too. Finished output may wait for an earlier job, but a vacant
	## process slot never waits for the rest of a batch. Child handles stay
	## owned until polling reports completion; an observation error fails the
	## batch and normal handle cleanup reaps its remaining children.
	parallel! : List(Job), U64 => Try(List({ code : I32, output : Str }), [CommandFailed(Str)])
	parallel! = |jobs, limit| {
		capacity = if limit == 0 {
			1
		} else {
			limit
		}
		var $next = 0.U64
		var $complete = 0.U64
		var $reported = 0.U64
		var $running = []
		var $finished = List.repeat(None, jobs.len())
		while $complete < jobs.len() {
			while $running.len() < capacity and $next < jobs.len() {
				job = jobs.get($next) ?? crash "internal: parallel job index"
				child = Proc.cmd(job).stdout(Capture).stderr(MergeWithStdout).spawn!() ? |error| CommandFailed("${Proc.show(job)}: ${Str.inspect(error)}")
				$running = $running.append({ job, index: $next, child })
				$next = $next + 1
			}
			var $waiting = []
			for running in $running {
				match running.child.poll!() ? |error| CommandFailed("${Proc.show(running.job)}: ${Str.inspect(error)}") {
					Running => {
						$waiting = $waiting.append(running)
					}
					Finished(output) => {
						code = match output.status {
							Exited(value) => value
							Signaled(_) => -1
						}
						value = { code, output: Str.from_utf8_lossy(output.stdout_bytes), bytes: output.stdout_bytes }
						$finished = $finished.set(running.index, Some(value)) ?? crash "internal: parallel result index"
						$complete = $complete + 1
					}
				}
			}
			$running = $waiting
			var $blocked = False
			while $reported < jobs.len() and !$blocked {
				match $finished.get($reported) ?? crash "internal: parallel report index" {
					None => {
						$blocked = True
					}
					Some(result) => {
						job = jobs.get($reported) ?? crash "internal: parallel reported job"
						Stdout.line!("RUN ${Proc.show(job)}") ?? {}
						Stdout.write_bytes!(result.bytes) ?? {}
						$finished = $finished.set($reported, Some({ ..result, bytes: [] })) ?? crash "internal: parallel reported result"
						$reported = $reported + 1
					}
				}
			}
			if $complete < jobs.len() and ($running.len() == capacity or $next == jobs.len()) {
				Sleep.millis!(10) ? |_| CommandFailed("parallel job polling was interrupted")
			}
		}
		Ok(
			$finished.map(
				|item| match item {
					Some(result) => { code: result.code, output: result.output }
					None => crash "internal: parallel result missing after completion"
				},
			),
		)
	}

	## Limit compiler processes by CPU and memory capacity, reserving 16 GiB
	## per process by default. This is scheduling headroom, not a compiler
	## memory guarantee. ROC_SIGNALS_BUILD_JOBS explicitly overrides the memory
	## choice, still capped by available CPUs. Runtime replays use cpus! instead.
	compiler_jobs! : () => Try(U64, _)
	compiler_jobs! = || {
		probe = Proc.capture!({ program: "node", args: ["-p", "const os = require('node:os'); const bound = process.constrainedMemory(); [os.availableParallelism(), Math.min(os.totalmem(), bound || Infinity)].join(' ')"], cwd: "." })?
		(cpus, memory) = match Str.from_utf8_lossy(probe).trim().split_on(" ") {
			[cores, bytes] => (
				U64.from_str(cores).map_err(|_| CapacityProbeFailed)?,
				U64.from_str(bytes).map_err(|_| CapacityProbeFailed)?,
			)
			_ => return Err(CapacityProbeFailed)
		}
		if cpus == 0 or memory == 0 {
			return Err(CapacityProbeFailed)
		}
		requested = match Env.var_str!("ROC_SIGNALS_BUILD_JOBS") {
			Err(VarNotFound(_)) => (memory // 17179869184).max(1)
			Err(_) => return Err(InvalidBuildJobs)
			Ok(text) => {
				if text.is_empty() or !text.to_utf8().all(|byte| byte >= '0' and byte <= '9') {
					return Err(InvalidBuildJobs)
				}
				value = U64.from_str(text).map_err(|_| InvalidBuildJobs)?
				if value == 0 {
					return Err(InvalidBuildJobs)
				}
				value
			}
		}
		Ok(requested.min(cpus))
	}

	## How many jobs to run at once: the machine's online CPUs.
	cpus! : () => U64
	cpus! = || {
		out = Proc.cmd({ program: "getconf", args: ["_NPROCESSORS_ONLN"], cwd: "." }).run!() ?? crash "getconf"
		U64.from_str(Str.from_utf8_lossy(out.stdout_bytes).trim()) ?? 1
	}

	## Run and return stdout; a non-zero exit is an error.
	capture! : Job => Try(List(U8), [CommandFailed(Str)])
	capture! = |job| {
		{ code, stdout } = Proc.output!(job)?
		if (code == 0) Ok(stdout) else Err(CommandFailed("${Proc.show(job)} exited with ${code.to_str()}"))
	}

	note! : Str => {}
	note! = |line| Stdout.line!(line) ?? {}

	warn! : Str => {}
	warn! = |line| Stderr.line!(line) ?? {}
}
