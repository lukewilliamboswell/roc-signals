## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/wire/fuzz-package.roc",
	p1: "fuzz/port-json/fuzz-package.roc",
	p2: "fuzz/boot/fuzz-package.roc",
	p3: "fuzz/result-readers/fuzz-package.roc",
	p4: "fuzz/crypto/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzWireProperty
import p1.FuzzPortJsonProperty
import p2.FuzzBootProperty
import p3.FuzzResultReadersProperty
import p4.FuzzCryptoProperty

target = Fuzz.suite([
	FuzzWireProperty.target,
	FuzzPortJsonProperty.target,
	FuzzBootProperty.target,
	FuzzResultReadersProperty.target,
	FuzzCryptoProperty.target,
])
