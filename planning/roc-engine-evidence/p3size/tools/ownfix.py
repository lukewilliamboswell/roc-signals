"""ownfix.py IN OUT -- dispose_block calls its children owned (replace) instead of
iterating them borrowed: a borrowed closure call makes Roc emit a second
(borrowed-capture) specialisation of every site closure body."""
import sys
s = open(sys.argv[1]).read()
a = """		var $j = 0.U64
		for kid in kids {
			kt = core.ktop.get($j) ?? False
			(_, _, t1) = Engine.call(kid, env, Dispose(remove and kt), $tx)
			$tx = t1
			$j = $j + 1
		}"""
b = """		var $j = 0.U64
		var $ks = kids
		while $j < $ks.len() {
			kt = core.ktop.get($j) ?? False
			{ list, prev } = $ks.replace($j, Engine.noop({})) ?? crash "child"
			(_, _, t1) = Engine.call(prev, env, Dispose(remove and kt), $tx)
			$ks = list
			$tx = t1
			$j = $j + 1
		}"""
assert a in s, "pattern"
open(sys.argv[2], "w").write(s.replace(a, b))
