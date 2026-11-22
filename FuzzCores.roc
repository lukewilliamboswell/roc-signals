## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/masks/fuzz-package.roc",
	p1: "fuzz/table-changes/fuzz-package.roc",
	p2: "fuzz/view-follow/fuzz-package.roc",
	p3: "fuzz/fx-core/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzMasksProperty
import p1.FuzzTableChangesProperty
import p2.FuzzViewFollowProperty
import p3.FuzzFxCoreProperty

target = Fuzz.suite([
	FuzzMasksProperty.target,
	FuzzTableChangesProperty.target,
	FuzzViewFollowProperty.target,
	FuzzFxCoreProperty.target,
])
