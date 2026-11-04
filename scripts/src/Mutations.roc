import cli.Path
import Proc
import SpecSuite
import Targets

## The mutation gate: each mutation breaks `platform/Engine.roc` in one
## place, and the named fuzz target must reject the broken engine, through
## its declared examples, its exact allocation baseline or a bounded
## exploration. A target that never rejects a mutation is not evidence.
##
## Each mutant is built in its own copy of `platform/`, `test-support/` and
## the target's directory under the build directory; the working tree is
## never modified.
Mutations := [].{
	Mutation : { name : Str, target : Str, from : Str, to : Str }

	all : List(Mutation)
	all = [
		{ name: "hole-no-update", target: "form-builder", from: "\t\t\t\tif v == last {\n\t\t\t\t\t\$holes = list.set(\$i, { node, mask: m, attr, read, last }) ?? crash \"hole\"", to: "\t\t\t\tif True {\n\t\t\t\t\t\$holes = list.set(\$i, { node, mask: m, attr, read, last }) ?? crash \"hole\"" },
		{ name: "derive-stuck", target: "form-builder", from: "\t\t\t\t\t\tif v2 == v {\n\t\t\t\t\t\t\t(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, t1)", to: "\t\t\t\t\t\tif True {\n\t\t\t\t\t\t\t(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, t1)" },
		{ name: "no-root-settle", target: "form-builder", from: "\t\tif mask == 0 {\n\t\t\t{ root: root2, tx: Engine.flush_focus(tx2) }", to: "\t\tif True {\n\t\t\t{ root: root2, tx: Engine.flush_focus(tx2) }" },
		{ name: "row-kids-skip", target: "form-builder", from: "\t\t\tif cfg.dynamic and kid_mask.bitwise_and(m) != 0 {", to: "\t\t\tif False {" },
		{ name: "cancels-on-dispose", target: "fx-channel", from: "\t\t\t\tif o.keep {", to: "\t\t\t\tif o.keep and o.id == 0 {" },
		{ name: "subscriptions-survive-dispose", target: "fx-channel", from: "\t\t\t\tif o.keep {", to: "\t\t\t\tif o.keep or o.id != 0 {" },
		{ name: "no-reparent-route", target: "fx-channel", from: "\t\t\t\tlive: fx.live.map(|l| if ids.contains(l.id) { id: l.id, path, sub: l.sub } else l),", to: "\t\t\t\tlive: fx.live.map(|l| if ids.contains(l.id) { id: l.id, path: l.path.concat(path).drop_last(path.len()), sub: l.sub } else l)," },
		{ name: "retired-write-uncounted", target: "fx-channel", from: "\t\t\t\t\t{ outer, value: _ } = inner\n\t\t\t\t\t(outer, m.bitwise_and(keep), if m.bitwise_and(keep.bitwise_not()) != 0 sk + 1 else sk)", to: "\t\t\t\t\t{ outer, value: _ } = inner\n\t\t\t\t\t(outer, m.bitwise_and(keep), sk)" },
		{ name: "result-keeps-live", target: "fx-channel", from: "tx1 = if entry.sub tx else Engine.with_fx(tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id) })", to: "tx1 = tx" },
		{ name: "no-bound", target: "fx-channel", from: "\t\tif live.len() >= max {", to: "\t\tif live.len() >= max + 1000 {" },
		{ name: "followups-lifo", target: "fx-channel", from: "\t\t\tq = tx.fx.queue.first() ?? crash \"queue\"\n\t\t\ttx1 = Engine.with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_first(1) })", to: "\t\t\tq = tx.fx.queue.last() ?? crash \"queue\"\n\t\t\ttx1 = Engine.with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_last(1) })" },
		{ name: "no-queue-purge", target: "fx-channel", from: "\t\t\t} else if \$tx.fx.queue.any(|q| q.id == id) {", to: "\t\t\t} else if \$tx.fx.queue.len() > 1000000 {" },
		{ name: "site-keeps-owned", target: "fx-channel", from: "kept = if entry.sub owned else owned.drop_at(i)", to: "kept = owned" },
		{ name: "timeout-uncapped", target: "fx-channel", from: "Engine.put_u32(Engine.put_str(\$b, body), Engine.min_u32(timeout_ms, Engine.max_timeout_ms))", to: "Engine.put_u32(Engine.put_str(\$b, body), timeout_ms)" },
		{ name: "header-value-lost", target: "fx-channel", from: "\t\t\t\t\$hs = \$hs.append((k, v))", to: "\t\t\t\t\$hs = \$hs.append((k, Str.concat(v, \"x\")))" },
		{ name: "timeout-as-network", target: "fx-channel", from: "\t\t} else if tag == 7 {\n\t\t\tTimeout", to: "\t\t} else if tag == 7 {\n\t\t\tNetwork(\"Timeout\")" },
	]

	## Run every mutation; returns the problems (survivors and stale patterns).
	run! : SpecSuite.Options, Str => Try(List(Str), _)
	run! = |o, only| {
		var $problems = []
		for m in Mutations.all.keep_if(|m| only == "" or m.name == only) {
			$problems = $problems.concat(Mutations.one!(o, m)?)
		}
		Ok($problems)
	}

	one! : SpecSuite.Options, Mutation => Try(List(Str), _)
	one! = |o, m| {
		target = Targets.fuzz_targets.find_first(|t| t.name == m.target) ? |_| UnknownTarget(m.target)
		engine = Path.read_utf8!(Path.utf8("${o.root}/platform/Engine.roc"))?
		if engine.split_on(m.from).len() != 2 {
			return Ok(["mutation ${m.name}: its pattern no longer occurs exactly once in platform/Engine.roc; update scripts/src/Mutations.roc"])
		}
		tree = "${o.build_dir}/mutate/${m.name}"
		SpecSuite.fresh_dir!(tree)?
		app_dir = Str.join_with(target.main.split_on("/").drop_last(1), "/")
		for dir in ["platform", "test-support", app_dir] {
			Path.create_all!(Path.utf8("${tree}/${dir}"))?
			Path.copy_dir_with!(Path.utf8("${o.root}/${dir}"), Path.utf8("${tree}/${dir}"), { symlinks: Preserve, destination: Merge })?
		}
		Path.write_utf8!(Path.utf8("${tree}/platform/Engine.roc"), engine.replace_each(m.from, m.to))?
		exe = "${tree}/target"
		built = Proc.output!({ program: o.compiler, args: ["build", "--fuzz", "--opt=speed", target.main, "--output=${exe}"], cwd: tree })?
		if built.code != 0 {
			return Ok(["mutation ${m.name}: the mutant does not build; update scripts/src/Mutations.roc"])
		}
		baseline = "--baseline=${o.root}/${Targets.baseline(target.name)}"
		checked = Proc.output!({ program: exe, args: ["check", baseline, "--timeout=1800"], cwd: tree })?
		check_out = Str.from_utf8_lossy(checked.stdout)
		survived_check = checked.code == 0 and check_out.contains("passed; baseline matched")
		if !survived_check {
			Proc.note!("mutation ${m.name}: rejected by ${target.name} check: ${check_out.trim()}")
			return Ok([])
		}
		explored = Proc.output!({ program: exe, args: ["run", baseline, "--time=30", "--timeout=60"], cwd: tree })?
		run_out = Str.from_utf8_lossy(explored.stdout)
		if explored.code == 0 and run_out.contains("exploration passed") {
			Ok(["mutation ${m.name}: survived ${target.name} (check and 30 s of exploration)"])
		} else {
			Proc.note!("mutation ${m.name}: rejected by ${target.name} exploration: ${run_out.trim()}")
			Ok([])
		}
	}
}
