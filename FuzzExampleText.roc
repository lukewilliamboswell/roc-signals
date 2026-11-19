## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "examples/csv-converter/fuzz-package.roc",
	p1: "examples/markdown-editor/fuzz-package.roc",
	p2: "examples/conduit/fuzz-package.roc",
	p3: "examples/field-notes/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzCsvConverterProperty
import p1.FuzzMarkdownEditorProperty
import p1.FuzzMarkdownHtmlProperty
import p2.FuzzConduitProperty
import p3.FuzzFieldNotesProperty

target = Fuzz.suite([
	FuzzCsvConverterProperty.target,
	FuzzMarkdownEditorProperty.target,
	FuzzMarkdownHtmlProperty.target,
	FuzzConduitProperty.target,
	FuzzFieldNotesProperty.target,
])
