## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "fuzz/links/fuzz-package.roc",
	p1: "fuzz/base64/fuzz-package.roc",
	p10: "fuzz/reconcile/fuzz-package.roc",
	p2: "fuzz/scm-parse/fuzz-package.roc",
	p3: "fuzz/protocol-facts/fuzz-package.roc",
	p4: "fuzz/url/fuzz-package.roc",
	p5: "fuzz/names/fuzz-package.roc",
	p6: "fuzz/masks/fuzz-package.roc",
	p7: "fuzz/table-changes/fuzz-package.roc",
	p8: "fuzz/view-follow/fuzz-package.roc",
	p9: "fuzz/fx-core/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzLinksProperty
import p1.FuzzBase64Property
import p2.FuzzScmParseProperty
import p3.FuzzProtocolFactsProperty
import p4.FuzzUrlProperty
import p5.FuzzNamesProperty
import p6.FuzzMasksProperty
import p7.FuzzTableChangesProperty
import p8.FuzzViewFollowProperty
import p9.FuzzFxCoreProperty
import p10.FuzzReconcileProperty

target = Fuzz.suite([
	FuzzLinksProperty.target,
	FuzzBase64Property.target,
	FuzzScmParseProperty.target,
	FuzzProtocolFactsProperty.target,
	FuzzUrlProperty.target,
	FuzzNamesProperty.target,
	FuzzMasksProperty.target,
	FuzzTableChangesProperty.target,
	FuzzViewFollowProperty.target,
	FuzzFxCoreProperty.target,
	FuzzReconcileProperty.target,
])
