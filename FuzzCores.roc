## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/table-changes/fuzz-package.roc",
	p1: "fuzz/view-follow/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzTableChangesProperty
import p1.FuzzViewFollowProperty

target = Fuzz.suite([
	FuzzTableChangesProperty.target,
	FuzzViewFollowProperty.target,
])
