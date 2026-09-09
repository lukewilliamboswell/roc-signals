## Shared navigation intent: every in-app link routes through one Ui.state
## so history push_state stays a single app-owned effect in main.roc.
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Nav := {}.{
	RouteIntent : { serial : U64, path : Str, query : Str, hash : Str }

	initial : Nav.RouteIntent
	initial = { serial: 0, path: "/", query: "", hash: "" }

	for_target : Nav.RouteIntent, Browser.Location -> Nav.RouteIntent
	for_target = |current, target| {
		{
			serial: current.serial + 1,
			path: target.path,
			query: target.query,
			hash: target.hash,
		}
	}

	location : Nav.RouteIntent -> Browser.Location
	location = |intent| { path: intent.path, query: intent.query, hash: intent.hash }

	link : Str, Str, Browser.Location, Ui.State(Nav.RouteIntent) -> Elem
	link = |label, classes, target, intent| {
		Html.link(
			label,
			[
				Html.class_attr(classes),
				Html.attr("href", href(target)),
				Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| for_target(current, target))),
			],
		)
	}

	link_c : Str, Signal.Signal(Str), Browser.Location, Ui.State(Nav.RouteIntent) -> Elem
	link_c = |label, classes, target, intent| {
		Html.link(
			label,
			[
				Html.class_attr_s(classes),
				Html.attr("href", href(target)),
				Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| for_target(current, target))),
			],
		)
	}

	href : Browser.Location -> Str
	href = |target| {
		with_query =
			if target.query.is_empty() {
				target.path
			} else {
				"${target.path}?${target.query}"
			}
		if target.hash.is_empty() {
			with_query
		} else {
			"${with_query}#${target.hash}"
		}
	}
}
