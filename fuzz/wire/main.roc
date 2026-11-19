app [target] {
	cbor: "https://github.com/lukewilliamboswell/roc-cbor/releases/download/0.6.3/J3xX4n61WoMZKK3tdWTnZBdKaVbi8SvXvmtC5i3qDAER.tar.zst",
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import FuzzWireProperty

target = FuzzWireProperty.target
