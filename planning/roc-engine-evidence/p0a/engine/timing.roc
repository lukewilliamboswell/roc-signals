app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import Bench

## Wall-clock timing of single engine transactions (apply only; command bytes
## are produced into the reused buffer, not delivered anywhere). Each run uses a
## fresh State. Output: one line per (run, op): "op micros cmd_bytes".
time_apply! : Str, Bench.App, Engine.Input(Bench.Msg) => Bench.App
time_apply! = |name, st, input| {
	t0 = Monotonic.now!()
	next = st.apply(input, Bench.update)
	d = Monotonic.since(Monotonic.now!(), t0)
	bytes = next.commands().len()
	_ = Stdout.line!("${name} ${(d.to_nanos() // 1000).to_str()} ${bytes.to_str()}")
	next
}

main! : List(_) => Try({}, [Exit(I32), Interrupted])
main! = |_args| {
	var $run = 0.U64
	while $run < 11 {
		a0 = Bench.init(False)
		a1 = time_apply!("create-1k", a0, Msg(Run(1000)))
		a2 = time_apply!("clear-1k", a1, Msg(Clear))
		b1 = time_apply!("create-10k", a2, Msg(Run(10000)))
		b2 = time_apply!("update-every-10th-10k", b1, Msg(UpdateEvery10))
		b3 = time_apply!("select-10k", b2, Msg(Select(1005)))
		b4 = time_apply!("swap-10k", b3, Msg(SwapRows))
		b5 = time_apply!("remove-10k", b4, Msg(Remove(1007)))
		b6 = time_apply!("append-1k-to-10k", b5, Msg(Add(1000)))
		b7 = time_apply!("clear-11k", b6, Msg(Clear))
		_ = b7
		$run = $run + 1
	}
	Ok({})
}
