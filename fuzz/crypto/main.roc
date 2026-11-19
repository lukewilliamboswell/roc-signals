app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import FuzzCryptoProperty

target = FuzzCryptoProperty.target
