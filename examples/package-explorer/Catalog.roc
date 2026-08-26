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

	## Where one panel's request has got to. The failure message rides on the
	## `Failed` tag, so there is no "which fields are meaningful right now?"
	## question to answer at every use site.
	Phase := [Loading, Ready, Failed(Str)].{
		is_eq : Catalog.Phase, Catalog.Phase -> Bool
		is_eq = |left, right|
			match left {
				Loading => match right {
					Loading => True
					_ => False
				}
				Ready => match right {
					Ready => True
					_ => False
				}
				Failed(left_error) => match right {
					Failed(right_error) => left_error == right_error
					_ => False
				}
			}
	}

	## Every panel folds its task into the same shape: a phase and the panel
	## payload. Structural records give us `is_eq` for free once `Phase` has
	## one, so each panel is its own independent cutoff point in the graph.
	SearchView : { phase : Catalog.Phase, rows : List(Catalog.PackageRow) }

	DetailView : { phase : Catalog.Phase, data : Catalog.DetailData }

	VersionsView : { phase : Catalog.Phase, rows : List(Catalog.VersionRow) }

	DepsView : { phase : Catalog.Phase, rows : List(Catalog.DepRow) }

	# --- payload parsing ------------------------------------------------------

	records : Str -> List(Str)
	records = |payload| payload.split_on(";").keep_if(|record| !record.is_empty())

	## One field split. A record with no separator is all `before` and no
	## `after`, which is what the trailing-field cases below rely on.
	field_pair : Str -> { before : Str, after : Str }
	field_pair = |text|
		match text.split_first("|") {
			Ok(split) => split
			Err(_) => { before: text, after: "" }
		}

	package_rows : Str -> List(Catalog.PackageRow)
	package_rows = |payload|
		Catalog.records(payload).map(
			|record| {
				parts = Catalog.field_pair(record)
				{ id: parts.before, summary: parts.after }
			},
		)

	version_rows : Str -> List(Catalog.VersionRow)
	version_rows = |payload|
		Catalog.records(payload).map(
			|record| {
				parts = Catalog.field_pair(record)
				{ version: parts.before, released: parts.after }
			},
		)

	dep_rows : Str -> List(Catalog.DepRow)
	dep_rows = |payload|
		Catalog.records(payload).map(
			|record| {
				parts = Catalog.field_pair(record)
				{ id: parts.before, requirement: parts.after }
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
	search_loading = { phase: Catalog.Phase.Loading, rows: [] }

	search_ready : Str -> Catalog.SearchView
	search_ready = |payload| { phase: Catalog.Phase.Ready, rows: Catalog.package_rows(payload) }

	search_failed : Str -> Catalog.SearchView
	search_failed = |message| { phase: Catalog.Phase.Failed(message), rows: [] }

	detail_loading : Catalog.DetailView
	detail_loading = { phase: Catalog.Phase.Loading, data: Catalog.empty_detail }

	detail_ready : Str -> Catalog.DetailView
	detail_ready = |payload| { phase: Catalog.Phase.Ready, data: Catalog.detail_data(payload) }

	detail_failed : Str -> Catalog.DetailView
	detail_failed = |message| { phase: Catalog.Phase.Failed(message), data: Catalog.empty_detail }

	versions_loading : Catalog.VersionsView
	versions_loading = { phase: Catalog.Phase.Loading, rows: [] }

	versions_ready : Str -> Catalog.VersionsView
	versions_ready = |payload| { phase: Catalog.Phase.Ready, rows: Catalog.version_rows(payload) }

	versions_failed : Str -> Catalog.VersionsView
	versions_failed = |message| { phase: Catalog.Phase.Failed(message), rows: [] }

	deps_loading : Catalog.DepsView
	deps_loading = { phase: Catalog.Phase.Loading, rows: [] }

	deps_ready : Str -> Catalog.DepsView
	deps_ready = |payload| { phase: Catalog.Phase.Ready, rows: Catalog.dep_rows(payload) }

	deps_failed : Str -> Catalog.DepsView
	deps_failed = |message| { phase: Catalog.Phase.Failed(message), rows: [] }

	# --- status wording -------------------------------------------------------

	count_text : U64 -> Str
	count_text = |n| n.to_str()

	search_status_text : Catalog.SearchView -> Str
	search_status_text = |view|
		match view.phase {
			Loading => "Search status: searching"
			Failed(message) => "Search status: failed - ${message}"
			Ready =>
				if view.rows.len() == 0 {
					"Search status: no packages match"
				} else if view.rows.len() == 1 {
					"Search status: 1 package"
				} else {
					"Search status: ${Catalog.count_text(view.rows.len())} packages"
				}
		}

	## Placeholder wording for the empty branch of each list. The branch itself
	## exists for the "no rows" case, but loading and failure land there too, so
	## the copy is derived rather than hard-coded.
	search_empty_text : Catalog.SearchView -> Str
	search_empty_text = |view|
		match view.phase {
			Loading => "Loading packages..."
			Failed(_) => "Search unavailable."
			Ready => "No packages match this search."
		}

	versions_empty_text : Catalog.VersionsView -> Str
	versions_empty_text = |view|
		match view.phase {
			Loading => "Version history pending."
			Failed(_) => "Version history unavailable."
			Ready => "No versions published yet."
		}

	deps_empty_text : Catalog.DepsView -> Str
	deps_empty_text = |view|
		match view.phase {
			Loading => "Dependency list pending."
			Failed(_) => "Dependency list unavailable."
			Ready => "This package has no dependencies."
		}

	detail_empty_text : Catalog.DetailView -> Str
	detail_empty_text = |view|
		match view.phase {
			Loading => "Overview details pending."
			_ => "Overview details unavailable."
		}

	detail_status_text : Catalog.DetailView -> Str
	detail_status_text = |view|
		match view.phase {
			Loading => "Overview: loading"
			Failed(message) => "Overview: failed - ${message}"
			Ready => "Overview: ready"
		}

	detail_summary_text : Catalog.DetailView -> Str
	detail_summary_text = |view| "Summary: ${view.data.summary}"

	detail_license_text : Catalog.DetailView -> Str
	detail_license_text = |view| "License: ${view.data.license}"

	detail_downloads_text : Catalog.DetailView -> Str
	detail_downloads_text = |view| "Downloads: ${view.data.downloads}"

	versions_status_text : Catalog.VersionsView -> Str
	versions_status_text = |view|
		match view.phase {
			Loading => "Versions: loading"
			Failed(message) => "Versions: failed - ${message}"
			Ready =>
				if view.rows.len() == 0 {
					"Versions: none published"
				} else {
					"Versions: ${Catalog.count_text(view.rows.len())} released"
				}
		}

	deps_status_text : Catalog.DepsView -> Str
	deps_status_text = |view|
		match view.phase {
			Loading => "Dependencies: loading"
			Failed(message) => "Dependencies: failed - ${message}"
			Ready =>
				if view.rows.len() == 0 {
					"Dependencies: none"
				} else {
					"Dependencies: ${Catalog.count_text(view.rows.len())} required"
				}
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
	panel_summary : List(Catalog.Phase) -> Str
	panel_summary = |phases| {
		ready = phases.keep_if(Catalog.is_ready).len()
		loading = phases.keep_if(Catalog.is_loading).len()
		failed = phases.keep_if(Catalog.is_failed).len()
		"Panels: ${Catalog.count_text(ready)} ready, ${Catalog.count_text(loading)} loading, ${Catalog.count_text(failed)} failed"
	}

	is_loading : Catalog.Phase -> Bool
	is_loading = |phase|
		match phase {
			Loading => True
			_ => False
		}

	is_ready : Catalog.Phase -> Bool
	is_ready = |phase|
		match phase {
			Ready => True
			_ => False
		}

	is_failed : Catalog.Phase -> Bool
	is_failed = |phase|
		match phase {
			Failed(_) => True
			_ => False
		}

	all_settled : List(Catalog.Phase) -> Bool
	all_settled = |phases| phases.keep_if(Catalog.is_loading).len() == 0
}

expect Catalog.package_rows("roc-json|JSON codec;roc-http|HTTP client") == [{ id: "roc-json", summary: "JSON codec" }, { id: "roc-http", summary: "HTTP client" }]
expect Catalog.package_rows("") == []
expect Catalog.detail_data("roc-json|JSON codec|Apache-2.0|18422") == { id: "roc-json", summary: "JSON codec", license: "Apache-2.0", downloads: "18422" }
expect Catalog.search_status_text(Catalog.search_loading) == "Search status: searching"
expect Catalog.search_status_text(Catalog.search_failed("offline")) == "Search status: failed - offline"
expect Catalog.search_status_text(Catalog.search_ready("")) == "Search status: no packages match"
expect Catalog.search_status_text(Catalog.search_ready("roc-json|JSON codec")) == "Search status: 1 package"
expect Catalog.search_status_text(Catalog.search_ready("roc-json|a;roc-http|b")) == "Search status: 2 packages"
expect Catalog.versions_status_text(Catalog.versions_ready("1.0.0|2026-01-01")) == "Versions: 1 released"
expect Catalog.deps_status_text(Catalog.deps_ready("")) == "Dependencies: none"
expect Catalog.detail_status_text(Catalog.detail_failed("gone")) == "Overview: failed - gone"
expect Catalog.panel_summary([Catalog.Phase.Ready, Catalog.Phase.Loading, Catalog.Phase.Failed("gone")]) == "Panels: 1 ready, 1 loading, 1 failed"
expect Catalog.all_settled([Catalog.Phase.Ready, Catalog.Phase.Failed("gone")])
expect !Catalog.all_settled([Catalog.Phase.Ready, Catalog.Phase.Loading])
expect Catalog.order_rows([{ id: "a", summary: "" }, { id: "b", summary: "" }], True) == [{ id: "b", summary: "" }, { id: "a", summary: "" }]
