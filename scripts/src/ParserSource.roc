import cli.Env
import cli.Path
import Proc

## Prepare the source dependency before compiling scripts that import it.
## An existing sibling belongs to its contributor: verify it without updating
## its index, fetching, checking out or discarding any of its files.
ParserSource := [].{
	revision = "883ecd7d7565d9caa0e7e391dffdcd57b4a9b3e6"
	repository = "https://github.com/lukewilliamboswell/roc-parser.git"

	inspect! = |directory| {
		head = Proc.capture!({ program: "git", args: ["--no-optional-locks", "-C", directory, "rev-parse", "HEAD"], cwd: "." })?
		status = Proc.capture!({ program: "git", args: ["--no-optional-locks", "-C", directory, "status", "--porcelain=v1", "--untracked-files=all"], cwd: "." })?
		if !(Path.is_file!(Path.utf8("${directory}/package/main.roc"))?) {
			return Err(ParserSourceInvalid("${directory}: missing package/main.roc; existing files left unchanged"))
		}
		actual = Str.from_utf8_lossy(head).trim()
		state = if (status.is_empty()) "clean" else "with local changes"
		Proc.note!("Using roc-parser ${actual} (${state}) at ${directory}; existing checkout left unchanged")
		Ok(actual)
	}

	## Publish only a complete, verified checkout. The temporary directory is
	## ours to remove on failure; the destination is never removed or reset.
	prepare! = |root| {
		parent = Path.utf8("${root}/..")
		directory = "${root}/../roc-parser"
		if Path.exists!(Path.utf8(directory))? {
			_ = inspect!(directory)?
		} else {
			stage = Env.create_temp_dir_in!(parent, ".roc-parser-")?
			result = install!(root, stage, directory)
			# Cleanup must run after an error as well as after publication.
			if Path.exists!(stage)? {
				Path.delete_all!(stage)?
			}
			result?
		}
		Ok(directory)
	}

	install! = |root, stage, directory| {
		stage_text = Path.display(stage)
		Proc.run!({ program: "git", args: ["init", stage_text], cwd: root })?
		Proc.run!({ program: "git", args: ["-C", stage_text, "remote", "add", "origin", repository], cwd: root })?
		Proc.run!({ program: "git", args: ["-C", stage_text, "fetch", "--depth=1", "origin", revision], cwd: root })?
		Proc.run!({ program: "git", args: ["-C", stage_text, "checkout", "--detach", revision], cwd: root })?
		actual = inspect!(stage_text)?
		if actual != revision {
			return Err(ParserSourceInvalid("Fetched roc-parser did not match ${revision}"))
		}
		if Path.exists!(Path.utf8(directory))? {
			Err(ParserSourceInvalid("${directory}: appeared during setup; left unchanged, rerun to verify"))
		} else {
			Path.rename!(stage, Path.utf8(directory))
		}
	}

}
