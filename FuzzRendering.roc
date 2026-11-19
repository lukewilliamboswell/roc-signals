## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/structure/fuzz-package.roc",
	p1: "fuzz/dom/fuzz-package.roc",
	p2: "fuzz/markup/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzStructureProperty
import p1.FuzzDomProperty
import p2.FuzzMarkupProperty

target = Fuzz.suite([
	FuzzStructureProperty.target,
	FuzzDomProperty.target,
	FuzzMarkupProperty.target,
])
