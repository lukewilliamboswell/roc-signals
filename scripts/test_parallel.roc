#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.Env
import cli.Path
import src/Proc

## A two-slot dependency barrier proves that finishing the second job admits
## the third while the first is still waiting. Results and failure codes must
## retain input order even though completion order differs. No speed threshold
## is asserted; the child's deadline only prevents a broken scheduler hanging.
main! = |_args| {
	capacity = Proc.compiler_jobs!()?
	root = Path.display(Env.cwd!()?)
	dir = "${root}/.build/parallel-contract"
	if Path.exists!(Path.utf8(dir))? {
		Path.delete_all!(Path.utf8(dir))?
	}
	Path.create_all!(Path.utf8(dir))?
	child = "${dir}/child.mjs"
	source =
		\\import fs from 'node:fs';
		\\import path from 'node:path';
		\\const [dir, id] = process.argv.slice(2);
		\\const release = path.join(dir, 'release');
		\\if (id === '0') {
		\\  const deadline = Date.now() + 30000;
		\\  while (!fs.existsSync(release)) {
		\\    if (Date.now() > deadline) process.exit(73);
		\\    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
		\\  }
		\\}
		\\if (id === '2') fs.writeFileSync(release, 'ready');
		\\process.stdout.write(id + String.fromCharCode(10), () => process.exit(id === '3' ? 7 : 0));
	Path.write_utf8!(Path.utf8(child), source)?
	jobs = [0.U64, 1, 2, 3].map(|id| { program: "node", args: [child, dir, id.to_str()], cwd: root })
	results = Proc.parallel!(jobs, 2)?
	if results.map(|result| result.code) != [0, 0, 0, 7] or results.map(|result| result.output) != ["0\n", "1\n", "2\n", "3\n"] {
		return Err(ParallelContractFailed(results))
	}
	if !(Proc.parallel!([], 0)?).is_empty() {
		return Err(EmptyQueueFailed)
	}
	one = Proc.parallel!(jobs.sublist({ start: 1, len: 1 }), 0)?
	if one.map(|result| result.code) != [0] {
		return Err(ZeroLimitFailed)
	}
	Proc.note!("Parallel queue contract passed; compiler capacity ${capacity.to_str()}")
	Ok({})
}
