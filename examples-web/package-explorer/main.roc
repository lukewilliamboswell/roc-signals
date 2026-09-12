app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.2.0-rc2/AvyUxjkQaEPU7NKikDiz3U48XGMX1fpFgw2bppV87qLA.tar.zst", roc: "nightly-2026-09-11-793f9d8" }

import Load
import pf.Action
import Catalog
import Route
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

# Package Explorer: search a registry, open a package, and watch three panels
# load independently behind a URL that Back and Forward restore exactly.
#
# State separates search and navigation controls from independently retained
# HTTP results. Browser.location() supplies the route. Counts, headings, and
# the document title are derived; result generations reject older responses.
#
# Signal-graph shapes on show:
#
#   fan-in A (3 independent inputs, `Signal.combine`)
#       detail_view.phase ---+
#       versions_view.phase -+--> phases --> panel_summary --> heading text
#       deps_view.phase -----+                       \--> all_settled --> Ui.when
#
#   fan-in B (2 independent sources, `Signal.map2`)
#       route (from Browser.location) --+--> context line
#       search result count ------------+
#
#   chain (4 hops from one result)
#       search state -> search_view -> search_rows -> result_count -> context line

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

list_class = "grid gap-2"

row_class = "grid gap-1 rounded border border-zinc-200 p-3"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

link_class = "text-sm font-medium text-emerald-700 underline"

status_class = "text-sm font-medium text-zinc-900"

note_class = "text-sm text-zinc-700"

# --- navigation intent --------------------------------------------------------

RouteIntent : { serial : U64, path : Str, query : Str, hash : Str }

initial_intent : RouteIntent
initial_intent = { serial: 0, path: "/", query: "", hash: "" }

## The four source-signal handles the page is built from. They are passed as
## one record rather than four positional arguments: `query` and `watched` are
## both `Ui.State(Str)`, so positionally they are indistinguishable.
Handles : {
	intent : Ui.State(RouteIntent),
	query : Ui.State(Str),
	reversed : Ui.State(Bool),
	watched : Ui.State(Str),
}

intent_location : RouteIntent -> Browser.Location
intent_location = |intent| { path: intent.path, query: intent.query, hash: intent.hash }

intent_for : RouteIntent, Browser.Location -> RouteIntent
intent_for = |current, target| {
	serial: current.serial + 1,
	path: target.path,
	query: target.query,
	hash: target.hash,
}

route_link : Str, Browser.Location, Ui.State(RouteIntent) -> Elem
route_link = |label, target, intent|
	Html.link(
		label,
		[
			Html.class_attr(link_class),
			Html.attr("href", target.path),
			Html.on_event("click", Html.event_policy_prevent_default, intent.update(|current| intent_for(current, target))),
		],
	)

## Signal-backed line with a stable test id. Locating dynamic text by its own
## content couples the locator to the value, so a changed value would read as a
## missing element instead of a diff.
line : Signal.Signal(Str), Str, Str -> Elem
line = |signal, classes, id|
	Html.paragraph_s_attrs(signal, [Html.class_attr(classes), Html.test_id(id)])

# --- header -------------------------------------------------------------------

context_text : Route, U64 -> Str
context_text = |route, matches|
	match route {
		Search => "Context: search results (${matches.to_str()} matches)"
		Package(id) => "Context: package ${id} (${matches.to_str()} search matches retained)"
		Unknown => "Context: unknown address (${matches.to_str()} matches)"
	}

hero : Signal.Signal(Str) -> Elem
hero = |context_line|
	Html.section_c(
		"Package Explorer",
		hero_class,
		[
			Html.heading_c("Package Explorer", "text-3xl font-semibold text-zinc-950"),
			Html.paragraph_c(
				"Search the registry, open a package, and watch its overview, versions, and dependencies load as three independent requests. Back and Forward restore the exact view.",
				"max-w-3xl text-sm text-zinc-700",
			),
			line(context_line, status_class, "context"),
		],
	)

# --- search page --------------------------------------------------------------

## One result row. The watch flag lives in the parent (one `Ui.state(Str)` for
## the whole list), so a row is a pure function of two signals: its own item and
## the shared watched id.
search_result_row : Str, Signal.Signal(Catalog.PackageRow), Ui.State(RouteIntent), Ui.State(Str) -> Elem
search_result_row = |key, row, intent, watched| {
	summary = Signal.map(row, |value| value.summary)
	watch_line = Signal.map2(row, watched.signal(), Catalog.watch_text)

	Html.div_c(
		row_class,
		[
			route_link("Open ${key}", Route.package_location(key), intent),
			line(summary, note_class, "summary-${key}"),
			line(watch_line, note_class, "watch-${key}"),
			Html.button_c("Watch ${key}", link_class, watched.update(|_current| key)),
		],
	)
}

search_page : Handles, Signal.Signal(Catalog.SearchView), Signal.Signal(List(Catalog.PackageRow)) -> Elem
search_page = |handles, search_view, ordered_rows| {
	status_line = Signal.map(search_view, Catalog.search_status_text)
	has_rows = Signal.map(ordered_rows, |rows| rows.len() > 0)
	order_line = Signal.map(handles.reversed.signal(), Catalog.order_label)

	Html.section_c(
		"Package search",
		panel_class,
		[
			Html.heading_c("Package search", "text-xl font-semibold text-zinc-950"),
			Html.text_input_c("Search packages", handles.query.signal(), input_class, handles.query.update_str(|_, value| value)),
			line(status_line, status_class, "search-status"),
			Html.checkbox("Reverse order", handles.reversed.signal(), handles.reversed.update_bool(|_current, value| value)),
			line(order_line, status_class, "order"),
			Ui.when(
				has_rows,
				|| Html.section_c(
					"Search results",
					list_class,
					[Ui.each(Signal.map(ordered_rows, |rows_items| Rows.from_list(rows_items, |row| row.id) ?? crash "duplicate row key"), |each_row| search_result_row(each_row.key(), each_row.signal(), handles.intent, handles.watched))],
				),
				|| Html.section_c(
					"Search results",
					list_class,
					[line(Signal.map(search_view, Catalog.search_empty_text), note_class, "search-empty")],
				),
			),
		],
	)
}

# --- package detail panels ----------------------------------------------------

overview_panel : Signal.Signal(Catalog.DetailView) -> Elem
overview_panel = |detail_view| {
	is_ready = Signal.map(detail_view, |view| Catalog.is_ready(view.phase))

	Html.section_c(
		"Overview",
		panel_class,
		[
			Html.heading_c("Overview", "text-lg font-semibold text-zinc-950"),
			line(Signal.map(detail_view, Catalog.detail_status_text), status_class, "overview-status"),
			Ui.when(
				is_ready,
				|| Html.div_c(
					list_class,
					[
						line(Signal.map(detail_view, Catalog.detail_summary_text), note_class, "overview-summary"),
						line(Signal.map(detail_view, Catalog.detail_license_text), note_class, "overview-license"),
						line(Signal.map(detail_view, Catalog.detail_downloads_text), note_class, "overview-downloads"),
					],
				),
				|| line(Signal.map(detail_view, Catalog.detail_empty_text), note_class, "overview-empty"),
			),
		],
	)
}

version_row : Str, Signal.Signal(Catalog.VersionRow) -> Elem
version_row = |key, row|
	Html.div_c(row_class, [line(Signal.map(row, Catalog.version_row_text), note_class, "version-${key}")])

versions_panel : Signal.Signal(Catalog.VersionsView) -> Elem
versions_panel = |versions_view| {
	rows = Signal.map(versions_view, |view| view.rows)
	has_rows = Signal.map(rows, |value| value.len() > 0)

	Html.section_c(
		"Versions",
		panel_class,
		[
			Html.heading_c("Versions", "text-lg font-semibold text-zinc-950"),
			line(Signal.map(versions_view, Catalog.versions_status_text), status_class, "versions-status"),
			Ui.when(
				has_rows,
				|| Html.section_c("Version history", list_class, [Ui.each(Signal.map(rows, |rows_items| Rows.from_list(rows_items, |row| row.version) ?? crash "duplicate row key"), |each_row| version_row(each_row.key(), each_row.signal()))]),
				|| Html.section_c("Version history", list_class, [line(Signal.map(versions_view, Catalog.versions_empty_text), note_class, "versions-empty")]),
			),
		],
	)
}

dep_row : Str, Signal.Signal(Catalog.DepRow) -> Elem
dep_row = |key, row|
	Html.div_c(row_class, [line(Signal.map(row, Catalog.dep_row_text), note_class, "dep-${key}")])

deps_panel : Signal.Signal(Catalog.DepsView) -> Elem
deps_panel = |deps_view| {
	rows = Signal.map(deps_view, |view| view.rows)
	has_rows = Signal.map(rows, |value| value.len() > 0)

	Html.section_c(
		"Dependencies",
		panel_class,
		[
			Html.heading_c("Dependencies", "text-lg font-semibold text-zinc-950"),
			line(Signal.map(deps_view, Catalog.deps_status_text), status_class, "deps-status"),
			Ui.when(
				has_rows,
				|| Html.section_c("Dependency list", list_class, [Ui.each(Signal.map(rows, |rows_items| Rows.from_list(rows_items, |row| row.id) ?? crash "duplicate row key"), |each_row| dep_row(each_row.key(), each_row.signal()))]),
				|| Html.section_c("Dependency list", list_class, [line(Signal.map(deps_view, Catalog.deps_empty_text), note_class, "deps-empty")]),
			),
		],
	)
}

## Each panel owns its retained result inside the package-page scope.
## Admitted effects survive navigation; writes to disposed state are skipped.
package_page : Signal.Signal(Route), Ui.State(RouteIntent) -> Elem
package_page = |route, intent|
	Ui.state({ generation: 0.U64, value: Catalog.detail_loading }, |detail|
		Ui.state({ generation: 0.U64, value: Catalog.versions_loading }, |versions|
			Ui.state({ generation: 0.U64, value: Catalog.deps_loading }, |deps|
				package_panels(route, intent, detail, versions, deps))))

package_panels : Signal.Signal(Route), Ui.State(RouteIntent), Ui.State(Load.State(Catalog.DetailView)), Ui.State(Load.State(Catalog.VersionsView)), Ui.State(Load.State(Catalog.DepsView)) -> Elem
package_panels = |route, intent, detail, versions, deps| {
	package_id = Signal.map(route, Route.package_id)
	detail_view = detail.signal().map(|current| current.value)
	versions_view = versions.signal().map(|current| current.value)
	deps_view = deps.signal().map(|current| current.value)

	# Fan-in A: three independent panel phases feed one combined signal. Each
	# input owns its own capability, which is exactly the case `Signal.combine`
	# is for.
	phases =
		Signal.combine([
			Signal.map(detail_view, |view| view.phase),
			Signal.map(versions_view, |view| view.phase),
			Signal.map(deps_view, |view| view.phase),
		])
	panel_summary = Signal.map(phases, Catalog.panel_summary)
	settled = Signal.map(phases, Catalog.all_settled)

	Html.section_c(
		"Package detail",
		panel_class,
		[
			Html.heading_c("Package detail", "text-2xl font-semibold text-zinc-950"),
			line(Signal.map(package_id, |id| "Package: ${id}"), status_class, "package-id"),
			line(panel_summary, status_class, "panel-summary"),
			Ui.when(
				settled,
				|| Html.paragraph_c("All panels settled.", note_class),
				|| Html.paragraph_c("Some panels are still loading.", note_class),
			),
			Html.div_c("justify-self-start", [route_link("Back to search", Route.search_location, intent)]),
			overview_panel(detail_view),
			versions_panel(versions_view),
			deps_panel(deps_view),
			# Snapshot each request with its panel's current generation.
			Action.on_change_initial(
				Action.sampled(package_id, { query: package_id, current: detail.signal() }.Signal),
				|read|
					if read.query.is_empty() {
						Action.none
					} else {
						Load.start(detail, "detail", { loading: Catalog.detail_loading, ready: Catalog.detail_ready, failed: Catalog.detail_failed }, read)
					},
			),
			Action.on_change_initial(
				Action.sampled(package_id, { query: package_id, current: versions.signal() }.Signal),
				|read|
					if read.query.is_empty() {
						Action.none
					} else {
						Load.start(versions, "versions", { loading: Catalog.versions_loading, ready: Catalog.versions_ready, failed: Catalog.versions_failed }, read)
					},
			),
			Action.on_change_initial(
				Action.sampled(package_id, { query: package_id, current: deps.signal() }.Signal),
				|read|
					if read.query.is_empty() {
						Action.none
					} else {
						Load.start(deps, "deps", { loading: Catalog.deps_loading, ready: Catalog.deps_ready, failed: Catalog.deps_failed }, read)
					},
			),
			Ui.on_cleanup(Signal.cleanup("package detail panels")),
		],
	)
}

# --- app ----------------------------------------------------------------------

## Four small source signals -- navigation intent, search query, list order,
## watched package -- plus one host-owned environment source. Everything the
## page shows combines these controls with the independently retained results.
main : () -> Elem
main = ||
	Ui.state(
		initial_intent,
		|intent|
			Ui.state(
				"",
				|query|
					Ui.state(
						False,
						|reversed|
							Ui.state(
								"",
								|watched| app_shell({ intent, query, reversed, watched }),
							),
					),
			),
	)

app_shell : Handles -> Elem
app_shell = |handles|
	Ui.state({ generation: 0.U64, value: Catalog.search_loading }, |search| explorer(handles, search))

explorer : Handles, Ui.State(Load.State(Catalog.SearchView)) -> Elem
explorer = |handles, search| {
	location = Browser.location()
	route = Signal.map(location, Route.from_location)
	is_package = Signal.map(route, Route.is_package)
	document_title = Signal.map(route, Route.title)

	search_view = search.signal().map(|current| current.value)

	# Chain: result state -> view -> rows -> count -> context line.
	search_rows = Signal.map(search_view, |view| view.rows)
	result_count = Signal.map(search_rows, |rows| rows.len())

	# Fan-in C: server rows and the client-side order toggle. Reordering here
	# never starts an HTTP effect, so keyed rows keep their scopes.
	ordered_rows = Signal.map2(search_rows, handles.reversed.signal(), Catalog.order_rows)

	# Fan-in B: the route source and the search result count are completely
	# independent, and both feed this one line.
	context_line = Signal.map2(route, result_count, context_text)

	Html.div_c(
		page_class,
		[
			Ui.on_change(handles.intent.signal(), |value| Browser.push_state(intent_location(value))),
			Ui.on_change_initial(
				route,
				|value|
					match value {
						Unknown => Browser.replace_state(Route.search_location)
						_ => Signal.noop
					},
			),
			Ui.on_change_initial(document_title, Browser.set_title),
			Action.on_change_initial(Action.sampled(handles.query.signal(), { query: handles.query.signal(), current: search.signal() }.Signal), |read| Load.start(search, "search", { loading: Catalog.search_loading, ready: Catalog.search_ready, failed: Catalog.search_failed }, read)),
			hero(context_line),
			Ui.when(
				is_package,
				|| package_page(route, handles.intent),
				|| search_page(handles, search_view, ordered_rows),
			),
		],
	)
}
