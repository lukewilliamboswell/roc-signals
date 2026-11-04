app [main] { pf: platform "platform/main.roc" }

import pf.Erased

roundtrip : U64 -> U64
roundtrip = |n| {
	hidden = Erased.erase!(Box.box(|| n))
	getter : Box((() -> U64))
	getter = Erased.restore!(hidden)
	(Box.unbox(getter))()
}

main : () -> U64
main = || roundtrip(41)
