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
