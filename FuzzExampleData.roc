## Independently selectable properties sharing one native build.
app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
	p0: "examples/form-builder/fuzz-package.roc",
	p1: "examples/kanban-board/fuzz-package.roc",
	p2: "examples/data-grid/fuzz-package.roc",
	p3: "examples/spreadsheet-lite/fuzz-package.roc",
	p4: "examples/log-explorer/fuzz-package.roc",
	p5: "examples/million-row-explorer/fuzz-package.roc",
}

import fz.Fuzz
import p0.FuzzFormBuilderProperty
import p1.FuzzKanbanBoardProperty
import p2.FuzzDataGridProperty
import p3.FuzzSpreadsheetLiteProperty
import p4.FuzzLogExplorerProperty
import p4.FuzzLogScrollMapProperty
import p5.FuzzMillionRowExplorerAggregatesProperty

target = Fuzz.suite([
	FuzzFormBuilderProperty.target,
	FuzzKanbanBoardProperty.target,
	FuzzDataGridProperty.target,
	FuzzSpreadsheetLiteProperty.target,
	FuzzLogExplorerProperty.target,
	FuzzLogScrollMapProperty.target,
	FuzzMillionRowExplorerAggregatesProperty.target,
])
