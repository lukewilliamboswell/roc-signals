## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/masks/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzMasksProperty

target = Fuzz.suite([
	FuzzMasksProperty.target,
])
