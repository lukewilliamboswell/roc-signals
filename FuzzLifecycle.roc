## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/startup-placeholders/fuzz-package.roc",
	p1: "fuzz/table-view/fuzz-package.roc",
	p2: "tests/apps/effects/fuzz-package.roc",
	p3: "tests/apps/controls/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzStartupPlaceholdersProperty
import p1.FuzzTableViewProperty
import p2.FuzzFxChannelProperty
import p3.FuzzControlsProperty

target = Fuzz.suite([
	FuzzStartupPlaceholdersProperty.target,
	FuzzTableViewProperty.target,
	FuzzFxChannelProperty.target,
	FuzzControlsProperty.target,
])
