## Package registry catalog.
##
## This module owns every payload format the four independently loaded panels
## receive, and the small presentation records the UI derives from them. It has
## no CSS and no Elem: parsing and status wording only, so the app module stays
## signal wiring.
##
## Payload grammar (records separated by ";", fields by "|"):
##
##   search      "roc-json|JSON codec;roc-http|HTTP client"
##   detail      "roc-json|JSON codec|Apache-2.0|18422"
##   versions    "1.2.0|2026-05-02;1.1.0|2026-03-14"
##   deps        "roc-parser|0.4.0;roc-bytes|1.1.0"
##
## An empty payload is a legitimate answer everywhere: no matches, no published
## versions, no dependencies.
Catalog := {}.{
	PackageRow : { id : Str, summary : Str }

	VersionRow : { version : Str, released : Str }

	DepRow : { id : Str, requirement : Str }

	DetailData : { id : Str, summary : Str, license : Str, downloads : Str }

	## Every panel folds its task into the same shape: a phase string, an error
	## string, and the panel payload. Structural records give us `is_eq` for
	## free, so each panel is its own independent cutoff point in the graph.
	SearchView : { phase : Str, error : Str, rows : List(Catalog.PackageRow) }

	DetailView : { phase : Str, error : Str, data : Catalog.DetailData }

	VersionsView : { phase : Str, error : Str, rows : List(Catalog.VersionRow) }

	DepsView : { phase : Str, error : Str, rows : List(Catalog.DepRow) }

	# --- payload parsing ------------------------------------------------------

	records : Str -> List(Str)
	records = |payload|
		payload.split_on(";").fold(
			[],
			|acc, record|
				if record.is_empty() {
					acc
				} else {
					acc.append(record)
				},
		)

	field_pair : Str -> { before : Str, after : Str }
	field_pair = |text|
		match text.split_first("|") {
			Ok(split) => { before: split.before, after: split.after }
			Err(_) => { before: text, after: "" }
		}

	package_rows : Str -> List(Catalog.PackageRow)
	package_rows = |payload|
		Catalog.records(payload).fold(
			[],
			|acc, record| {
				parts = Catalog.field_pair(record)
				acc.append({ id: parts.before, summary: parts.after })
			},
		)

	version_rows : Str -> List(Catalog.VersionRow)
	version_rows = |payload|
		Catalog.records(payload).fold(
			[],
			|acc, record| {
				parts = Catalog.field_pair(record)
				acc.append({ version: parts.before, released: parts.after })
			},
		)

	dep_rows : Str -> List(Catalog.DepRow)
	dep_rows = |payload|
		Catalog.records(payload).fold(
			[],
			|acc, record| {
				parts = Catalog.field_pair(record)
				acc.append({ id: parts.before, requirement: parts.after })
			},
		)

	detail_data : Str -> Catalog.DetailData
	detail_data = |payload| {
		first = Catalog.field_pair(payload)
		second = Catalog.field_pair(first.after)
		third = Catalog.field_pair(second.after)
		{
			id: first.before,
			summary: second.before,
			license: third.before,
			downloads: third.after,
		}
	}

	# --- panel view constructors ---------------------------------------------

	empty_detail : Catalog.DetailData
	empty_detail = { id: "", summary: "", license: "", downloads: "" }

	search_loading : Catalog.SearchView
	search_loading = { phase: "loading", error: "", rows: [] }

	search_ready : Str -> Catalog.SearchView
	search_ready = |payload| { phase: "ready", error: "", rows: Catalog.package_rows(payload) }

	search_failed : Str -> Catalog.SearchView
	search_failed = |message| { phase: "failed", error: message, rows: [] }

	detail_loading : Catalog.DetailView
	detail_loading = { phase: "loading", error: "", data: Catalog.empty_detail }

	detail_ready : Str -> Catalog.DetailView
	detail_ready = |payload| { phase: "ready", error: "", data: Catalog.detail_data(payload) }

	detail_failed : Str -> Catalog.DetailView
	detail_failed = |message| { phase: "failed", error: message, data: Catalog.empty_detail }

	versions_loading : Catalog.VersionsView
	versions_loading = { phase: "loading", error: "", rows: [] }

	versions_ready : Str -> Catalog.VersionsView
	versions_ready = |payload| { phase: "ready", error: "", rows: Catalog.version_rows(payload) }

	versions_failed : Str -> Catalog.VersionsView
	versions_failed = |message| { phase: "failed", error: message, rows: [] }

	deps_loading : Catalog.DepsView
	deps_loading = { phase: "loading", error: "", rows: [] }

	deps_ready : Str -> Catalog.DepsView
	deps_ready = |payload| { phase: "ready", error: "", rows: Catalog.dep_rows(payload) }

	deps_failed : Str -> Catalog.DepsView
	deps_failed = |message| { phase: "failed", error: message, rows: [] }

	# --- status wording -------------------------------------------------------

	count_text : U64 -> Str
	count_text = |n| n.to_str()

	search_status_text : Catalog.SearchView -> Str
	search_status_text = |view|
		if view.phase == "loading" {
			"Search status: searching"
		} else if view.phase == "failed" {
			"Search status: failed - ${view.error}"
		} else if view.rows.len() == 0 {
			"Search status: no packages match"
		} else if view.rows.len() == 1 {
			"Search status: 1 package"
		} else {
			"Search status: ${Catalog.count_text(view.rows.len())} packages"
		}

	## Placeholder wording for the empty branch of each list. The branch itself
	## exists for the "no rows" case, but loading and failure land there too, so
	## the copy is derived rather than hard-coded.
	search_empty_text : Catalog.SearchView -> Str
	search_empty_text = |view|
		if view.phase == "loading" {
			"Loading packages..."
		} else if view.phase == "failed" {
			"Search unavailable."
		} else {
			"No packages match this search."
		}

	versions_empty_text : Catalog.VersionsView -> Str
	versions_empty_text = |view|
		if view.phase == "loading" {
			"Version history pending."
		} else if view.phase == "failed" {
			"Version history unavailable."
		} else {
			"No versions published yet."
		}

	deps_empty_text : Catalog.DepsView -> Str
	deps_empty_text = |view|
		if view.phase == "loading" {
			"Dependency list pending."
		} else if view.phase == "failed" {
			"Dependency list unavailable."
		} else {
			"This package has no dependencies."
		}

	detail_empty_text : Catalog.DetailView -> Str
	detail_empty_text = |view|
		if view.phase == "loading" {
			"Overview details pending."
		} else {
			"Overview details unavailable."
		}

	detail_status_text : Catalog.DetailView -> Str
	detail_status_text = |view|
		if view.phase == "loading" {
			"Overview: loading"
		} else if view.phase == "failed" {
			"Overview: failed - ${view.error}"
		} else {
			"Overview: ready"
		}

	detail_summary_text : Catalog.DetailView -> Str
	detail_summary_text = |view| "Summary: ${view.data.summary}"

	detail_license_text : Catalog.DetailView -> Str
	detail_license_text = |view| "License: ${view.data.license}"

	detail_downloads_text : Catalog.DetailView -> Str
	detail_downloads_text = |view| "Downloads: ${view.data.downloads}"

	versions_status_text : Catalog.VersionsView -> Str
	versions_status_text = |view|
		if view.phase == "loading" {
			"Versions: loading"
		} else if view.phase == "failed" {
			"Versions: failed - ${view.error}"
		} else if view.rows.len() == 0 {
			"Versions: none published"
		} else {
			"Versions: ${Catalog.count_text(view.rows.len())} released"
		}

	deps_status_text : Catalog.DepsView -> Str
	deps_status_text = |view|
		if view.phase == "loading" {
			"Dependencies: loading"
		} else if view.phase == "failed" {
			"Dependencies: failed - ${view.error}"
		} else if view.rows.len() == 0 {
			"Dependencies: none"
		} else {
			"Dependencies: ${Catalog.count_text(view.rows.len())} required"
		}

	## Client-side ordering. The rows keep their identity; only their order
	## changes, which is what makes the keyed-row budget in the spec meaningful.
	order_rows : List(Catalog.PackageRow), Bool -> List(Catalog.PackageRow)
	order_rows = |rows, reversed|
		if reversed {
			rows.fold([], |acc, row| [row].concat(acc))
		} else {
			rows
		}

	order_label : Bool -> Str
	order_label = |reversed|
		if reversed {
			"Order: Z to A"
		} else {
			"Order: A to Z"
		}

	watch_text : Catalog.PackageRow, Str -> Str
	watch_text = |row, watched|
		if row.id == watched {
			"${row.id}: watching"
		} else {
			"${row.id}: not watching"
		}

	version_row_text : Catalog.VersionRow -> Str
	version_row_text = |row| "${row.version} released ${row.released}"

	dep_row_text : Catalog.DepRow -> Str
	dep_row_text = |row| "${row.id} requires ${row.requirement}"

	## Fan-in readout: the three panel phases arrive as one list from
	## `Signal.combine`, so this is the only place that counts panels.
	panel_summary : List(Str) -> Str
	panel_summary = |phases| {
		ready = phases.keep_if(|phase| phase == "ready").len()
		loading = phases.keep_if(|phase| phase == "loading").len()
		failed = phases.keep_if(|phase| phase == "failed").len()
		"Panels: ${Catalog.count_text(ready)} ready, ${Catalog.count_text(loading)} loading, ${Catalog.count_text(failed)} failed"
	}

	all_settled : List(Str) -> Bool
	all_settled = |phases| phases.keep_if(|phase| phase == "loading").len() == 0
}
